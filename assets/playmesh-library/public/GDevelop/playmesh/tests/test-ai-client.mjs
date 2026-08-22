import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi'
);
const dataModule = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const sourceOf = name => readFile(path.join(overlayDirectory, name), 'utf8');
const jsonResponse = (value, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

const protocolSource = await sourceOf('PlaymeshAiProtocol.js');
const protocolUrl = `data:text/javascript;base64,${Buffer.from(
  protocolSource
).toString('base64')}`;
const protocol = await import(protocolUrl);

assert.equal(protocol.PLAYMESH_AI_SESSION_PROTOCOL_VERSION, '4.0.0');
assert.equal(protocol.validatePlaymeshAiClientId('a'.repeat(128)), 'a'.repeat(128));
for (const invalidId of ['bad:id', 'bad id', 'a'.repeat(129)]) {
  assert.throws(
    () => protocol.validatePlaymeshAiClientId(invalidId),
    error => error && error.code === 'invalid_ai_response'
  );
}
assert.doesNotMatch(
  protocolSource,
  /baseRevision|baseProjectContentHash|commitEvidence|projectRevision|projectContentHash|rolled_back|committing/
);

const session = protocol.validatePlaymeshAiSession({
  editorSessionId: 'session-live-1',
  gameId: 'com.playmesh.game.live001',
  mode: 'agent',
  approvalMode: 'request_approval',
  locale: 'zh-CN',
  projectContext: {
    schemaVersion: '1.0.0',
    contentHash: 'a'.repeat(64),
    size: 32,
    selectedSceneName: 'Game',
  },
  sequence: 1,
  closed: false,
});
assert.equal(session.projectContext.selectedSceneName, 'Game');
assert.equal(session.approvalMode, 'request_approval');
for (const invalidApprovalMode of [undefined, null, 'always', 'request']) {
  assert.throws(
    () => {
      const candidate = { ...session, approvalMode: invalidApprovalMode };
      if (invalidApprovalMode === undefined) delete candidate.approvalMode;
      protocol.validatePlaymeshAiSession(candidate);
    },
    error => error && error.code === 'invalid_ai_response'
  );
}
assert.throws(
  () =>
    protocol.validatePlaymeshAiSession({
      ...session,
      editorSessionId: 's'.repeat(129),
    }),
  error => error && error.code === 'invalid_ai_response'
);
assert.deepEqual(
  protocol.validatePlaymeshAiTurn({
    turnId: 'turn-agent-without-echo',
    editorSessionId: session.editorSessionId,
    sequence: 2,
  }),
  {
    turnId: 'turn-agent-without-echo',
    editorSessionId: session.editorSessionId,
    sequence: 2,
  }
);
assert.deepEqual(
  protocol.validatePlaymeshAiTurn({
    turnId: 'turn-chat-with-echo',
    editorSessionId: session.editorSessionId,
    echo: 7,
    sequence: 3,
    createdAt: '2026-08-19T12:00:00.000Z',
    clientMessageId: 'message-chat-7',
    unvalidatedFutureField: { unsafe: true },
  }),
  {
    turnId: 'turn-chat-with-echo',
    editorSessionId: session.editorSessionId,
    sequence: 3,
    echo: 7,
    createdAt: '2026-08-19T12:00:00.000Z',
    clientMessageId: 'message-chat-7',
  }
);
for (const invalidField of [
  { createdAt: 42 },
  { clientMessageId: 'bad:message' },
]) {
  assert.throws(
    () =>
      protocol.validatePlaymeshAiTurn({
        turnId: 'turn-invalid-optional-field',
        editorSessionId: session.editorSessionId,
        sequence: 4,
        ...invalidField,
      }),
    error => error && error.code === 'invalid_ai_response'
  );
}
assert.throws(
  () =>
    protocol.validatePlaymeshAiTurn({
      turnId: 'bad:turn',
      editorSessionId: session.editorSessionId,
      echo: 1,
      sequence: 1,
    }),
  error => error && error.code === 'invalid_ai_response'
);

const parsedManualCalls = protocol.parsePlaymeshManualToolCalls(
  JSON.stringify({
    echo: 1,
    calls: [
      {
        name: 'create_scene',
        arguments: { scene_name: 'Level2' },
      },
    ],
  }),
  [{ name: 'create_scene' }]
);
assert.deepEqual(parsedManualCalls, {
  echo: 1,
  calls: [
    {
      toolName: 'create_scene',
      arguments: { scene_name: 'Level2' },
    },
  ],
});
for (const invalidEcho of [undefined, 0, -1, Number.MAX_SAFE_INTEGER + 1]) {
  assert.throws(
    () =>
      protocol.parsePlaymeshManualToolCalls(
        JSON.stringify({
          calls: [
            {
              name: 'create_scene',
              arguments: { scene_name: 'Level2' },
            },
          ],
          ...(invalidEcho === undefined ? {} : { echo: invalidEcho }),
        }),
        [{ name: 'create_scene' }]
      ),
    error => error && error.code === 'manual_submission_echo_required'
  );
}
assert.throws(
  () =>
    protocol.parsePlaymeshManualToolCalls(
      JSON.stringify({
        echo: 2,
        calls: [
          { name: 'create_scene', arguments: { scene_name: 'A' } },
        ],
      }),
      [{ name: 'create_scene' }],
      2
    ),
  error =>
    error &&
    error.code === 'manual_submission_echo_not_monotonic' &&
    error.echo === 2
);
for (const legacyEnvelope of [
  [{ name: 'create_scene', arguments: {} }],
  { echo: 3, name: 'create_scene', arguments: {} },
  { echo: 3, toolCalls: [{ name: 'create_scene', arguments: {} }] },
  {
    echo: 3,
    calls: [{ function: { name: 'create_scene', arguments: {} } }],
  },
  {
    echo: 3,
    calls: [{ toolName: 'create_scene', arguments: {} }],
  },
  {
    echo: 3,
    calls: [{ name: 'create_scene', arguments: '{}' }],
  },
  {
    echo: 3,
    calls: [{ echo: 3, name: 'create_scene', arguments: {} }],
  },
]) {
  assert.throws(() =>
    protocol.parsePlaymeshManualToolCalls(
      JSON.stringify(legacyEnvelope),
      [{ name: 'create_scene' }]
    )
  );
}

const enqueueRequests = protocol.buildPlaymeshAiEnqueueRequests({
  calls: [
    { toolName: 'create_scene', arguments: { scene_name: 'Level2' } },
  ],
  turnId: 'turn-live-1',
  session,
  tools: [{ name: 'create_scene' }],
});
assert.deepEqual(
  Object.keys(enqueueRequests[0]).sort(),
  ['arguments', 'callId', 'idempotencyKey', 'toolName', 'turnId']
);
assert.throws(
  () =>
    protocol.validatePlaymeshAiCall({
      callId: 'call-legacy-echo',
      editorSessionId: session.editorSessionId,
      turnId: 'turn-live-1',
      echo: 1,
      toolName: 'create_scene',
      arguments: {},
      idempotencyKey: 'key-legacy-echo',
      state: 'running',
      sequence: 1,
    }),
  error => error && error.code === 'invalid_ai_response'
);
assert.throws(
  () =>
    protocol.validatePlaymeshAiCall({
      callId: 'call-old-state',
      editorSessionId: session.editorSessionId,
      turnId: 'turn-live-1',
      toolName: 'create_scene',
      arguments: {},
      idempotencyKey: 'key-old-state',
      state: 'committing',
      sequence: 1,
    }),
  error => error && error.code === 'invalid_ai_response'
);

let clipboardSource = await sourceOf('PlaymeshAiClipboard.js');
const clipboardUrl = `data:text/javascript;base64,${Buffer.from(
  clipboardSource
).toString('base64')}`;
globalThis.__playmeshAiTestSha256Hex = async input => {
  const bytes =
    input instanceof ArrayBuffer
      ? input
      : input.buffer.slice(input.byteOffset, input.byteOffset + input.byteLength);
  return Buffer.from(await crypto.subtle.digest('SHA-256', bytes)).toString(
    'hex'
  );
};
let clientSource = await sourceOf('PlaymeshAiClient.js');
clientSource = clientSource
  .replace("from './PlaymeshAiProtocol';", `from '${protocolUrl}';`)
  .replace("from './PlaymeshAiClipboard';", `from '${clipboardUrl}';`)
  .replace(
    "import { sha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';",
    'const sha256Hex = globalThis.__playmeshAiTestSha256Hex;'
  );
const clientModule = await dataModule(clientSource);

const gameId = session.gameId;
const requests = [];
const longApprovalGrantId = 'A'.repeat(134);
const eventPayload = {
  schemaVersion: '1.0.0',
  sceneName: 'Game',
  changes: [],
};
const eventEnqueueRequests = protocol.buildPlaymeshAiEnqueueRequests({
  calls: [
    {
      toolName: 'add_scene_events',
      arguments: { scene_name: 'Game' },
      eventPayload,
    },
  ],
  turnId: 'turn-live-event-1',
  session,
  tools: [
    {
      name: 'add_scene_events',
      executionKind: 'event_payload',
      executionConfig: { sceneArgument: 'scene_name' },
    },
  ],
});
assert.deepEqual(eventEnqueueRequests[0].input, { eventPayload });
assert.throws(
  () =>
    protocol.buildPlaymeshAiEnqueueRequests({
      calls: [
        {
          toolName: 'create_scene',
          arguments: { scene_name: 'Game' },
          eventPayload,
        },
      ],
      turnId: 'turn-invalid-event-input',
      session,
      tools: [
        {
          name: 'create_scene',
          executionKind: 'editor_function',
          executionConfig: {},
        },
      ],
    }),
  error => error && error.code === 'event_payload_not_allowed'
);
const runningCall = {
  callId: 'call-inline-event',
  editorSessionId: session.editorSessionId,
  turnId: 'turn-live-1',
  toolName: 'add_scene_events',
  arguments: { scene_name: 'Game' },
  idempotencyKey: 'key-inline-event',
  state: 'running',
  sequence: 2,
  input: { eventPayload },
};
const approvalPolicy = await dataModule(
  await sourceOf('PlaymeshAiApprovalPolicy.js')
);
const approvalEventPayload = {
  ...eventPayload,
  changes: [
    { operationName: 'replace_all_conditions' },
    { operationName: 'insert_after_event' },
  ],
};
const approvalPresentation = approvalPolicy.buildPlaymeshAiApprovalPresentations({
  approvals: [
    {
      approvalId: 'approval-inline-event',
      operationId: 'gdevelop.tool.add_scene_events',
      editorSessionId: session.editorSessionId,
      callId: runningCall.callId,
    },
  ],
  calls: [
    {
      ...runningCall,
      input: { eventPayload: approvalEventPayload },
    },
  ],
  tools: [
    {
      name: 'add_scene_events',
      risk: 'high',
      modifiesProject: true,
      summary: 'Modify scene events.',
    },
  ],
})[0];
assert.ok(approvalPresentation);
assert.deepEqual(approvalPresentation.affectedSceneIds, ['Game']);
assert.deepEqual(
  approvalPresentation.arguments.filter(argument =>
    argument.name.startsWith('event_')
  ),
  [
    { name: 'event_scene', value: 'Game' },
    { name: 'event_changes', value: '2' },
    {
      name: 'event_operations',
      value: 'replace_all_conditions, insert_after_event',
    },
  ]
);
const fetchImplementation = async (url, options = {}) => {
  requests.push({ url, options });
  if (url.endsWith('/editor-sessions')) {
    return jsonResponse({ protocolVersion: '4.0.0', session });
  }
  if (
    url.endsWith(
      `/editor-settings/${session.editorSessionId}/approval-mode`
    )
  ) {
    const body = JSON.parse(options.body);
    return jsonResponse({
      session: {
        ...session,
        approvalMode: body.approvalMode,
        sequence: session.sequence + 1,
      },
    });
  }
  if (url.endsWith('/turns')) {
    const body = JSON.parse(options.body);
    return jsonResponse({
      turn: {
        turnId: 'turn-live-event-1',
        editorSessionId: session.editorSessionId,
        echo: body.echo,
        sequence: 2,
      },
    });
  }
  if (url.endsWith('/calls')) {
    return jsonResponse({ call: runningCall });
  }
  if (url.includes('/resource-staging/')) {
    return new Response(new Uint8Array([1, 2, 3]), {
      headers: { 'Content-Type': 'application/octet-stream' },
    });
  }
  if (url === '/dev/api/ai-approval-grants') {
    return jsonResponse({
      grants: [
        {
          grantId: longApprovalGrantId,
          scopeKind: 'gdevelop',
          scopeId: gameId,
          operationId:
            'gdevelop.tool.change_scene_properties_layers_effects_groups',
          gameId,
        },
      ],
    });
  }
  if (
    url ===
    `/dev/api/ai-approval-grants/${encodeURIComponent(longApprovalGrantId)}`
  ) {
    return jsonResponse({ grantId: longApprovalGrantId, revoked: true });
  }
  if (url.endsWith('/execution')) {
    const body = JSON.parse(options.body);
    const { input: _input, ...terminalCall } = runningCall;
    return jsonResponse({
      call: {
        ...terminalCall,
        state: body.success ? 'finished' : 'failed',
        output: body.output,
      },
    });
  }
  throw new Error(`Unexpected test URL: ${url}`);
};
const aiClient = new clientModule.PlaymeshAiClient({
  fetchImplementation,
  timeoutMs: 5000,
});

const longApprovalGrants = await aiClient.listApprovalGrants(undefined);
assert.equal(longApprovalGrants.length, 1);
assert.equal(longApprovalGrants[0].grantId, longApprovalGrantId);
assert.deepEqual(
  await aiClient.revokeApprovalGrant(longApprovalGrantId, undefined),
  { grantId: longApprovalGrantId, revoked: true }
);
const requestCountBeforeInvalidGrantId = requests.length;
await assert.rejects(
  aiClient.revokeApprovalGrant('bad:grant', undefined),
  error => error && error.code === 'invalid_ai_approval_grant_id'
);
assert.equal(requests.length, requestCountBeforeInvalidGrantId);

const requestCountBeforeInvalidIds = requests.length;
await assert.rejects(
  aiClient.listCalls(gameId, 's'.repeat(129), 0, undefined),
  error => error && error.code === 'invalid_editor_session_id'
);
await assert.rejects(
  aiClient.cancelCall(
    gameId,
    session.editorSessionId,
    'c'.repeat(129),
    undefined
  ),
  error => error && error.code === 'invalid_call_id'
);
assert.equal(requests.length, requestCountBeforeInvalidIds);

await aiClient.openSession(
  gameId,
  { mode: 'agent', locale: 'zh-CN', context: { selectedSceneName: 'Game' } },
  undefined
);
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  mode: 'agent',
  locale: 'zh-CN',
  context: { selectedSceneName: 'Game' },
});
const approvalModeRequestCount = requests.length;
const approvalModeSession = await aiClient.updateApprovalMode(
  gameId,
  session.editorSessionId,
  'always_allow',
  undefined
);
assert.equal(approvalModeSession.approvalMode, 'always_allow');
assert.equal(requests.length, approvalModeRequestCount + 1);
assert.equal(
  requests.at(-1).url,
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    gameId
  )}/ai/editor-settings/${session.editorSessionId}/approval-mode`
);
assert.equal(requests.at(-1).options.method, 'PUT');
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  approvalMode: 'always_allow',
});
const requestCountBeforeInvalidApprovalMode = requests.length;
await assert.rejects(
  aiClient.updateApprovalMode(
    gameId,
    session.editorSessionId,
    'always',
    undefined
  ),
  error => error && error.code === 'invalid_approval_mode'
);
assert.equal(requests.length, requestCountBeforeInvalidApprovalMode);

const sessionControllerDependencies = {
  playmeshAiClient: null,
  buildPlaymeshAiProjectContext: () => ({}),
  completePlaymeshAiFailureDiagnostics: error => error,
  createPlaymeshAiLocalRequestId: () => 'local-request-controller',
};
globalThis.__playmeshAiSessionControllerDependencies = sessionControllerDependencies;
let approvalModeControllerSource = await sourceOf(
  'PlaymeshAiSessionController.js'
);
approvalModeControllerSource = approvalModeControllerSource
  .replace(
    "import { playmeshAiClient } from './PlaymeshAiClient';",
    'const { playmeshAiClient } = globalThis.__playmeshAiSessionControllerDependencies;'
  )
  .replace(
    "import { buildPlaymeshAiProjectContext } from './PlaymeshAiProjectContext';",
    'const { buildPlaymeshAiProjectContext } = globalThis.__playmeshAiSessionControllerDependencies;'
  )
  .replace(
    /import \{\s*completePlaymeshAiFailureDiagnostics,\s*createPlaymeshAiLocalRequestId,\s*\} from '\.\/PlaymeshAiDiagnostics';/,
    'const { completePlaymeshAiFailureDiagnostics, createPlaymeshAiLocalRequestId } = globalThis.__playmeshAiSessionControllerDependencies;'
  );
const approvalModeControllerModule = await dataModule(
  approvalModeControllerSource
);
let controllerUpdateBehavior = async approvalMode => ({
  ...session,
  approvalMode,
  sequence: session.sequence + 1,
});
let controllerGetBehavior = async () => session;
const controllerClient = {
  updateApprovalMode: (...args) => controllerUpdateBehavior(...args.slice(2)),
  getSession: (...args) => controllerGetBehavior(...args),
};
const approvalModeController =
  new approvalModeControllerModule.PlaymeshAiSessionController({
    client: controllerClient,
    buildProjectContext: () => ({}),
  });
approvalModeController.session = session;
approvalModeController.gameId = gameId;
approvalModeController.mode = 'agent';
approvalModeController.tools = {};
let controllerNotifications = 0;
approvalModeController.subscribe(() => controllerNotifications++);

await approvalModeController.updateApprovalMode('always_allow');
assert.equal(approvalModeController.session.approvalMode, 'always_allow');
assert.equal(controllerNotifications, 2);

controllerUpdateBehavior = async () => {
  throw new TypeError('response lost after apply');
};
controllerGetBehavior = async () => ({
  ...session,
  approvalMode: 'request_approval',
  sequence: session.sequence + 2,
});
await approvalModeController.updateApprovalMode('request_approval');
assert.equal(approvalModeController.session.approvalMode, 'request_approval');
assert.equal(controllerNotifications, 3);

controllerGetBehavior = async () => ({
  ...session,
  approvalMode: 'request_approval',
  sequence: session.sequence + 3,
});
await assert.rejects(
  approvalModeController.updateApprovalMode('always_allow'),
  error => error && error.code === 'approval_mode_update_not_applied'
);
assert.equal(
  approvalModeController.session.approvalMode,
  'request_approval',
  'a failed PUT must display the reconciled authoritative mode'
);

controllerGetBehavior = async () => {
  throw new TypeError('reconciliation failed');
};
await assert.rejects(
  approvalModeController.updateApprovalMode('always_allow'),
  error => error && error.code === 'approval_mode_state_uncertain'
);
assert.equal(
  approvalModeController.session.approvalMode,
  'request_approval',
  'an uncertain update must not optimistically overwrite the last authoritative session'
);

controllerGetBehavior = async () => ({
  ...session,
  approvalMode: 'always_allow',
  sequence: session.sequence + 4,
});
await approvalModeController.reconcileApprovalMode();
assert.equal(approvalModeController.session.approvalMode, 'always_allow');

const stalePutResponse = deferred();
const stalePutStarted = deferred();
let stalePutReconciliationCalls = 0;
const stalePutController =
  new approvalModeControllerModule.PlaymeshAiSessionController({
    client: {
      updateApprovalMode: async () => {
        stalePutStarted.resolve();
        return stalePutResponse.promise;
      },
      getSession: async () => {
        stalePutReconciliationCalls++;
        return session;
      },
    },
    buildProjectContext: () => ({}),
  });
stalePutController.session = session;
stalePutController.gameId = gameId;
stalePutController.mode = 'agent';
stalePutController.tools = {};
let stalePutNotifications = 0;
stalePutController.subscribe(() => stalePutNotifications++);
const stalePutOperation = stalePutController.updateApprovalMode('always_allow');
await stalePutStarted.promise;
stalePutController.abandon();
const notificationsAfterPutAbandon = stalePutNotifications;
stalePutResponse.resolve({
  ...session,
  approvalMode: 'always_allow',
  sequence: session.sequence + 5,
});
await assert.rejects(
  stalePutOperation,
  error => error && error.code === 'approval_mode_operation_stale'
);
assert.equal(stalePutController.session, null);
assert.equal(stalePutNotifications, notificationsAfterPutAbandon);
assert.equal(stalePutReconciliationCalls, 0);

const staleGetResponse = deferred();
const staleGetStarted = deferred();
const staleGetController =
  new approvalModeControllerModule.PlaymeshAiSessionController({
    client: {
      getSession: async () => {
        staleGetStarted.resolve();
        return staleGetResponse.promise;
      },
    },
    buildProjectContext: () => ({}),
  });
staleGetController.session = session;
staleGetController.gameId = gameId;
staleGetController.mode = 'agent';
staleGetController.tools = {};
let staleGetNotifications = 0;
staleGetController.subscribe(() => staleGetNotifications++);
const staleGetOperation = staleGetController.reconcileApprovalMode();
await staleGetStarted.promise;
staleGetController.abandon();
const replacementSession = {
  ...session,
  editorSessionId: 'session-live-2',
  gameId: 'com.playmesh.game.live002',
  approvalMode: 'request_approval',
};
staleGetController.session = replacementSession;
staleGetController.gameId = replacementSession.gameId;
staleGetController.mode = 'agent';
staleGetController.tools = {};
staleGetController.sessionEpoch++;
staleGetController._notify();
const notificationsAfterGetSwitch = staleGetNotifications;
staleGetResponse.resolve({
  ...session,
  approvalMode: 'always_allow',
  sequence: session.sequence + 6,
});
await assert.rejects(
  staleGetOperation,
  error => error && error.code === 'approval_mode_operation_stale'
);
assert.equal(staleGetController.session, replacementSession);
assert.equal(staleGetController.gameId, replacementSession.gameId);
assert.equal(staleGetNotifications, notificationsAfterGetSwitch);
assert.doesNotMatch(approvalModeControllerSource, /localStorage|sessionStorage/);

const createdTurn = await aiClient.createTurn(
  gameId,
  session.editorSessionId,
  'message-live-event-1',
  2,
  undefined
);
assert.equal(createdTurn.echo, 2);
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  clientMessageId: 'message-live-event-1',
  echo: 2,
});
const enqueuedCall = await aiClient.enqueueCall(
  gameId,
  session.editorSessionId,
  eventEnqueueRequests[0],
  undefined
);
assert.equal(enqueuedCall.echo, undefined);
assert.deepEqual(
  JSON.parse(requests.at(-1).options.body),
  eventEnqueueRequests[0]
);
for (const fetchImplementation of [
  async () => jsonResponse({ error: { code: 'rejected_call' } }, 409),
  async () => {
    throw new TypeError('request failed');
  },
]) {
  const failingClient = new clientModule.PlaymeshAiClient({
    fetchImplementation,
    timeoutMs: 5000,
  });
  await assert.rejects(
    failingClient.createTurn(
      gameId,
      session.editorSessionId,
      'message-failing-1',
      3,
      undefined
    ),
    error => error && error.echo === 3
  );
}
const mismatchedEchoClient = new clientModule.PlaymeshAiClient({
  fetchImplementation: async () =>
    jsonResponse({
      turn: {
        turnId: 'turn-mismatch-1',
        editorSessionId: session.editorSessionId,
        echo: 999,
        sequence: 3,
      },
    }),
  timeoutMs: 5000,
});
await assert.rejects(
  mismatchedEchoClient.createTurn(
    gameId,
    session.editorSessionId,
    'message-mismatch-1',
    4,
    undefined
  ),
  error =>
    error &&
    error.code === 'turn_echo_mismatch' &&
    error.echo === 4
);
const missingEchoClient = new clientModule.PlaymeshAiClient({
  fetchImplementation: async () =>
    jsonResponse({
      turn: {
        turnId: 'turn-missing-echo-1',
        editorSessionId: session.editorSessionId,
        sequence: 4,
      },
    }),
  timeoutMs: 5000,
});
await assert.rejects(
  missingEchoClient.createTurn(
    gameId,
    session.editorSessionId,
    'message-missing-echo-1',
    5,
    undefined
  ),
  error =>
    error && error.code === 'turn_echo_mismatch' && error.echo === 5
);
const resourceBlob = await aiClient.getSessionStagedResource(
  gameId,
  session.editorSessionId,
  'b'.repeat(64),
  3,
  undefined
);
assert.equal(resourceBlob.size, 3);
assert.match(requests.at(-1).url, /\/editor-sessions\/session-live-1\/resource-staging\/b{64}\?size=3$/);
await aiClient.finishExecution(
  gameId,
  session.editorSessionId,
  runningCall.callId,
  { success: true, output: { applied: 1 } },
  undefined
);
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  success: true,
  output: { applied: 1 },
});
await assert.rejects(
  aiClient.finishExecution(
      gameId,
      session.editorSessionId,
      runningCall.callId,
      { success: true, output: {}, afterProject: {} },
      undefined
    ),
  error => error && error.code === 'invalid_execution_result'
);
assert.doesNotMatch(
  clientSource,
  /\/project-objects|commitEvidence|getCurrent\(|\/event-payload|\/correction|provideEventPayload|requestEventCorrection/
);

let adapterSource = await sourceOf('PlaymeshAiEditorFunctionAdapter.js');
adapterSource = adapterSource
  .replace(
    "import { processEditorFunctionCalls } from '../EditorFunctions/EditorFunctionCallRunner';",
    'const processEditorFunctionCalls = globalThis.__playmeshAiOfficialRunner;'
  )
  .replace(
    "import { AI_ORCHESTRATOR_TOOLS_VERSION } from '../AiGeneration/Utils';",
    "const AI_ORCHESTRATOR_TOOLS_VERSION = 'v12';"
  );
const adapterModule = await dataModule(adapterSource);
const liveProject = {
  mutations: 0,
  getCurrentPlatform: () => ({ isExtensionLoaded: () => true }),
  hasEventsFunctionsExtensionNamed: () => false,
};
const outsideCounts = { events: 0, instances: 0, objects: 0, groups: 0 };
const officialEnsureExtensionInstalled = async () => {};
const runnerOptions = {
  onSceneEventsModifiedOutsideEditor: () => outsideCounts.events++,
  onInstancesModifiedOutsideEditor: () => outsideCounts.instances++,
  onObjectsModifiedOutsideEditor: () => outsideCounts.objects++,
  onObjectGroupsModifiedOutsideEditor: () => outsideCounts.groups++,
  onProjectItemRenamedOutsideEditor: () => {},
  onWillDeleteScene: async () => {},
  onWillDeleteObject: () => {},
  onWillInstallExtension: () => {},
  onExtensionInstalled: () => {},
  ensureExtensionInstalled: officialEnsureExtensionInstalled,
};
globalThis.__playmeshAiOfficialRunner = async options => {
  assert.equal(options.project, liveProject);
  assert.equal(options.toolsVersion, 'v12');
  assert.equal(
    options.ensureExtensionInstalled,
    officialEnsureExtensionInstalled,
    'the official session hook must cross the adapter by object identity'
  );
  liveProject.mutations++;
  options.onSceneEventsModifiedOutsideEditor({});
  options.onInstancesModifiedOutsideEditor({});
  options.onObjectsModifiedOutsideEditor({});
  options.onObjectGroupsModifiedOutsideEditor({});
  return {
    results: [{ status: 'finished', success: true, output: { ok: true } }],
    createdSceneNames: [],
    createdProject: null,
  };
};
await adapterModule.runGDevelopEditorFunctionCall({
  project: liveProject,
  functionCall: { name: 'create_scene', arguments: '{}', call_id: 'runner-1' },
  runnerOptions,
  runner: globalThis.__playmeshAiOfficialRunner,
});
assert.equal(liveProject.mutations, 1);
assert.deepEqual(outsideCounts, { events: 1, instances: 1, objects: 1, groups: 1 });
assert.doesNotMatch(adapterSource, /noEditorNotification/);

globalThis.__playmeshAiExecutorImports = {
  playmeshAiClient: null,
  executePlaymeshAiEditorFunction: null,
  createPlaymeshAiLocalToolWrappers: () => ({}),
  isPlaymeshAiTerminalCall: protocol.isPlaymeshAiTerminalCall,
  validatePlaymeshAiEventPayload: protocol.validatePlaymeshAiEventPayload,
  sha256Hex: globalThis.__playmeshAiTestSha256Hex,
};
let executorSource = await sourceOf('PlaymeshAiExecutor.js');
executorSource = executorSource
  .replace(
    "import { playmeshAiClient } from './PlaymeshAiClient';",
    'const { playmeshAiClient } = globalThis.__playmeshAiExecutorImports;'
  )
  .replace(
    "import { executePlaymeshAiEditorFunction } from './PlaymeshAiEditorFunctionAdapter';",
    'const { executePlaymeshAiEditorFunction } = globalThis.__playmeshAiExecutorImports;'
  )
  .replace(
    "import { createPlaymeshAiLocalToolWrappers } from './PlaymeshAiLocalToolWrappers';",
    'const { createPlaymeshAiLocalToolWrappers } = globalThis.__playmeshAiExecutorImports;'
  )
  .replace(
    /import \{\s*isPlaymeshAiTerminalCall,\s*validatePlaymeshAiEventPayload,\s*\} from '\.\/PlaymeshAiProtocol';/,
    'const { isPlaymeshAiTerminalCall, validatePlaymeshAiEventPayload } = globalThis.__playmeshAiExecutorImports;'
  )
  .replace(
    "import { sha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';",
    'const { sha256Hex } = globalThis.__playmeshAiExecutorImports;'
  );
const executorModule = await dataModule(executorSource);
const makeCall = callId => ({
  callId,
  editorSessionId: session.editorSessionId,
  turnId: `turn-${callId}`,
  toolName: 'mutate_live_project',
  arguments: {},
  idempotencyKey: `key-${callId}`,
  state: 'running',
  sequence: 1,
});
const mutationToolContract = {
  tools: [
    {
      name: 'mutate_live_project',
      modifiesProject: true,
      executionKind: 'editor_function',
    },
  ],
};
const fileMetadata = { gameId, fileIdentifier: 'live-project.json' };
const project = { value: 0, getPackageName: () => gameId };
let executeCount = 0;
let dirtyCount = 0;
let outsideCount = 0;
let finishCount = 0;
const submittedExecutions = [];
const retryClient = {
  finishExecution: async (_gameId, _sessionId, callId, execution) => {
    assert.equal(
      dirtyCount,
      1,
      'the live project must be marked dirty before finishExecution'
    );
    finishCount++;
    submittedExecutions.push(execution);
    if (finishCount === 1) throw new Error('response_lost');
    return { call: { ...makeCall(callId), state: 'finished', output: execution.output } };
  },
};
const executeEditorFunction = async options => {
  executeCount++;
  assert.equal(options.project, project);
  project.value++;
  options.runnerOptions.onObjectsModifiedOutsideEditor({ scene: null });
  return {
    result: {
      status: 'finished',
      success: true,
      output: { value: project.value },
    },
    createdProject: null,
    transientObjectUrls: [],
  };
};
let firstLocalWrapperOptions = null;
const onFetchNewlyAddedResources = async () => {};
const onNewResourcesAdded = () => {};
const eventsFunctionsExtensionsState = {};
const onPreviewOrRefresh = async () => {};
const executor = new executorModule.PlaymeshAiExecutor({
  client: retryClient,
  executeEditorFunction,
  createLocalWrappers: options => {
    firstLocalWrapperOptions = options;
    return {};
  },
  onProjectModified: () => dirtyCount++,
  onFetchNewlyAddedResources,
  onNewResourcesAdded,
  eventsFunctionsExtensionsState,
  onPreviewOrRefresh,
});
const executeOptions = {
  gameId,
  sessionId: session.editorSessionId,
  sessionEpoch: 1,
  isSessionEpochCurrent: epoch => epoch === 1,
  call: makeCall('live-retry-1'),
  project,
  selectedSceneName: 'Game',
  fileMetadata,
  toolsContract: mutationToolContract,
  runnerOptions: {
    onObjectsModifiedOutsideEditor: () => outsideCount++,
  },
};
await assert.rejects(executor.executeCall(executeOptions), /response_lost/);
assert.equal(
  firstLocalWrapperOptions.onFetchNewlyAddedResources,
  onFetchNewlyAddedResources
);
assert.equal(
  firstLocalWrapperOptions.onNewResourcesAdded,
  onNewResourcesAdded
);
assert.equal(
  firstLocalWrapperOptions.eventsFunctionsExtensionsState,
  eventsFunctionsExtensionsState
);
assert.equal(firstLocalWrapperOptions.onPreviewOrRefresh, onPreviewOrRefresh);
const pendingRegistry = new executorModule.PlaymeshAiExecutionAbortRegistry();
let cancellationPosts = 0;
if (
  pendingRegistry.abortCall(
    gameId,
    session.editorSessionId,
    executeOptions.call.callId
  )
) {
  cancellationPosts++;
}
if (
  !pendingRegistry.hasNonCancellableExecutionForTurn(
    gameId,
    session.editorSessionId,
    executeOptions.call.turnId
  )
) {
  cancellationPosts++;
}
assert.equal(
  pendingRegistry.abortTurn(
    gameId,
    session.editorSessionId,
    executeOptions.call.turnId
  ),
  0
);
assert.equal(cancellationPosts, 0, 'result-pending calls and turns cannot cancel');
assert.equal(
  pendingRegistry.abortCall(
    'com.playmesh.game.other',
    'other-session',
    executeOptions.call.callId
  ),
  true,
  'the same callId in another game/session must not collide'
);
const retried = await executor.executeCall(executeOptions);
assert.equal(retried.status, 'finished');
assert.equal(executeCount, 1, 'finish retry must not rerun the EditorFunction');
assert.equal(project.value, 1);
assert.equal(dirtyCount, 1);
assert.equal(outsideCount, 1);
assert.equal(finishCount, 2);
assert.deepEqual(submittedExecutions[0], { success: true, output: { value: 1 } });
assert.deepEqual(submittedExecutions[1], submittedExecutions[0]);
assert.equal(
  pendingRegistry.hasNonCancellableExecutionForCall(
    gameId,
    session.editorSessionId,
    executeOptions.call.callId
  ),
  false,
  'a terminal finish acknowledgement must release the pending result'
);
assert.deepEqual(Object.keys(submittedExecutions[0]).sort(), ['output', 'success']);

let circularExecuteCount = 0;
let circularFinishCount = 0;
let circularDirtyCount = 0;
const circularSubmissions = [];
const circularExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      assert.equal(circularDirtyCount, 1);
      circularFinishCount++;
      circularSubmissions.push(execution);
      if (circularFinishCount === 1) throw new Error('response_lost');
      return { call: { ...makeCall(callId), state: 'failed' } };
    },
  },
  executeEditorFunction: async ({ project: sameProject }) => {
    circularExecuteCount++;
    assert.equal(sameProject, project);
    sameProject.value++;
    const output = {};
    output.circular = output;
    return {
      result: { status: 'finished', success: true, output },
      createdProject: null,
      transientObjectUrls: [],
    };
  },
  createLocalWrappers: () => ({}),
  onProjectModified: () => circularDirtyCount++,
});
const circularOptions = {
  ...executeOptions,
  call: makeCall('live-circular-output-1'),
};
await assert.rejects(
  circularExecutor.executeCall(circularOptions),
  /response_lost/
);
const circularRetried = await circularExecutor.executeCall(circularOptions);
assert.equal(circularRetried.status, 'failed');
assert.equal(
  circularExecuteCount,
  1,
  'non-serializable output retry must not rerun the EditorFunction'
);
assert.equal(circularFinishCount, 2);
assert.equal(circularDirtyCount, 1);
assert.deepEqual(circularSubmissions[0], {
  success: false,
  output: {},
  errorCode: 'editor_function_output_invalid',
  errorMessage: 'The local GDevelop AI tool failed.',
});
assert.deepEqual(circularSubmissions[1], circularSubmissions[0]);

let exceptionalExecuteCount = 0;
let exceptionalFinishCount = 0;
let exceptionalDirtyCount = 0;
const exceptionalSubmissions = [];
const exceptionalExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      assert.equal(exceptionalDirtyCount, 1);
      exceptionalFinishCount++;
      exceptionalSubmissions.push(execution);
      if (exceptionalFinishCount === 1) throw new Error('response_lost');
      return { call: { ...makeCall(callId), state: 'failed' } };
    },
  },
  executeEditorFunction: async ({ project: sameProject }) => {
    exceptionalExecuteCount++;
    assert.equal(sameProject, project);
    sameProject.value++;
    return {
      get result() {
        throw Object.assign(new Error('result getter failed'), {
          code: 'editor_function_result_invalid',
        });
      },
      createdProject: null,
      transientObjectUrls: [],
    };
  },
  createLocalWrappers: () => ({}),
  onProjectModified: () => exceptionalDirtyCount++,
});
const exceptionalOptions = {
  ...executeOptions,
  call: makeCall('live-exceptional-output-1'),
};
await assert.rejects(
  exceptionalExecutor.executeCall(exceptionalOptions),
  /response_lost/
);
const exceptionalRetried = await exceptionalExecutor.executeCall(
  exceptionalOptions
);
assert.equal(exceptionalRetried.status, 'failed');
assert.equal(
  exceptionalExecuteCount,
  1,
  'exceptional result retry must not rerun the EditorFunction'
);
assert.equal(exceptionalFinishCount, 2);
assert.equal(exceptionalDirtyCount, 1);
assert.deepEqual(exceptionalSubmissions[0], {
  success: false,
  output: {},
  errorCode: 'editor_function_result_invalid',
  errorMessage: 'The local GDevelop AI tool failed.',
});
assert.deepEqual(exceptionalSubmissions[1], exceptionalSubmissions[0]);

let failedDirtyCount = 0;
let failedExecution;
const failedExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      assert.equal(
        failedDirtyCount,
        1,
        'a thrown live mutation must be marked dirty before finishExecution'
      );
      failedExecution = execution;
      return { call: { ...makeCall(callId), state: 'failed' } };
    },
  },
  executeEditorFunction: async ({ project: sameProject }) => {
    assert.equal(sameProject, project);
    sameProject.value++;
    throw Object.assign(new Error('official failure'), { code: 'official_failed' });
  },
  createLocalWrappers: () => ({}),
  onProjectModified: () => failedDirtyCount++,
});
const failedResult = await failedExecutor.executeCall({
  ...executeOptions,
  call: makeCall('live-failure-1'),
});
assert.equal(failedResult.status, 'failed');
assert.equal(failedDirtyCount, 1, 'a partial mutation must still mark dirty');
assert.deepEqual(failedExecution, {
  success: false,
  output: {
    code: 'official_failed',
    message: 'official failure',
    errorType: 'Error',
  },
  errorCode: 'official_failed',
  errorMessage: 'official failure',
});

let reportedFailureExecution;
const officialFailureOutput = {
  message: 'Scene Player is missing a required behavior.',
  error: {
    code: 'official_behavior_missing',
    type: 'GDevelopBehaviorValidationError',
    message: 'Add the required platform behavior first.',
  },
  warnings: ['No fallback was applied.'],
};
const reportedFailureExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      reportedFailureExecution = execution;
      return { call: { ...makeCall(callId), state: 'failed', output: execution.output } };
    },
  },
  executeEditorFunction: async () => ({
    result: {
      status: 'finished',
      success: false,
      output: officialFailureOutput,
      didModifyProject: true,
    },
    createdProject: null,
    transientObjectUrls: [],
  }),
  createLocalWrappers: () => ({}),
  onProjectModified: () => {},
});
const reportedFailureResult = await reportedFailureExecutor.executeCall({
  ...executeOptions,
  call: makeCall('live-reported-failure-1'),
});
assert.equal(reportedFailureResult.status, 'failed');
assert.deepEqual(reportedFailureExecution, {
  success: false,
  output: {
    ...officialFailureOutput,
    didModifyProject: true,
  },
  errorCode: 'official_behavior_missing',
  errorMessage: 'Scene Player is missing a required behavior.',
});

let invalidEventExecution;
let invalidEventEditorCalls = 0;
const invalidEventExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      invalidEventExecution = execution;
      return { call: { ...makeCall(callId), state: 'failed' } };
    },
  },
  executeEditorFunction: async () => {
    invalidEventEditorCalls++;
    throw new Error('invalid event input must not reach the editor function');
  },
  createLocalWrappers: () => ({}),
});
const invalidEventResult = await invalidEventExecutor.executeCall({
  ...executeOptions,
  call: {
    ...makeCall('invalid-inline-event-1'),
    toolName: 'add_scene_events',
    arguments: { scene_name: 'Game' },
    input: { eventPayload: { schemaVersion: 'invalid' } },
  },
  toolsContract: {
    tools: [
      {
        name: 'add_scene_events',
        modifiesProject: true,
        executionKind: 'event_payload',
        executionConfig: { sceneArgument: 'scene_name' },
      },
    ],
  },
});
assert.equal(invalidEventResult.status, 'failed');
assert.equal(invalidEventEditorCalls, 0);
assert.deepEqual(invalidEventExecution, {
  success: false,
  output: {},
  errorCode: 'event_payload_schema_invalid',
  errorMessage: 'The local GDevelop AI tool failed.',
});

const cancelledController = new AbortController();
cancelledController.abort();
const cancelled = await executor.executeCall({
  ...executeOptions,
  call: makeCall('cancel-before-live-1'),
  signal: cancelledController.signal,
});
assert.equal(cancelled.status, 'cancelled');
assert.equal(executeCount, 1);

const deferredExternalToolContract = {
  tools: [
    {
      name: 'create_or_update_jfxr_sound',
      modifiesProject: true,
      executionKind: 'editor_function',
    },
  ],
};
const runDeferredExternalWrapper = ({
  call,
  project: liveProject,
  playmeshWrappers,
  runnerOptions,
}) =>
  playmeshWrappers.create_or_update_jfxr_sound({
    call,
    project: liveProject,
    runnerOptions,
  });

const abortedRunnerStarted = deferred();
const abortedRunnerRelease = deferred();
const abortedController = new AbortController();
let abortedMutationCount = 0;
let abortedDirtyCount = 0;
let abortedFinishCount = 0;
let abortedProjectIdentityReads = 0;
let abortedProjectResourceReads = 0;
let abortedProjectDeleted = false;
const abortedProject = {
  getPackageName: () => {
    abortedProjectIdentityReads++;
    if (abortedProjectDeleted) {
      throw new Error('an aborted runner must not touch the deleted project');
    }
    return gameId;
  },
  getResourcesManager: () => {
    abortedProjectResourceReads++;
    throw new Error('an aborted runner must not read project resources');
  },
};
const abortedExternalExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async () => {
      abortedFinishCount++;
      throw new Error('an aborted pre-commit runner must not report a result');
    },
  },
  executeEditorFunction: runDeferredExternalWrapper,
  createLocalWrappers: options => ({
    create_or_update_jfxr_sound: async ({ call, project: wrapperProject }) => {
      abortedRunnerStarted.resolve();
      await abortedRunnerRelease.promise;
      options.beforeProjectMutation();
      wrapperProject.getResourcesManager();
      abortedMutationCount++;
      return {
        result: {
          status: 'finished',
          success: true,
          output: { callId: call.callId },
        },
        createdProject: null,
        transientObjectUrls: [],
      };
    },
  }),
  onProjectModified: () => abortedDirtyCount++,
});
const abortedExternalCall = {
  ...makeCall('deferred-external-abort-1'),
  toolName: 'create_or_update_jfxr_sound',
};
const abortedExternalOperation = abortedExternalExecutor.executeCall({
  ...executeOptions,
  call: abortedExternalCall,
  project: abortedProject,
  toolsContract: deferredExternalToolContract,
  signal: abortedController.signal,
});
await abortedRunnerStarted.promise;
abortedProjectDeleted = true;
abortedController.abort();
abortedRunnerRelease.resolve();
const abortedExternalResult = await abortedExternalOperation;
assert.equal(abortedExternalResult.status, 'cancelled');
assert.equal(abortedMutationCount, 0);
assert.equal(abortedDirtyCount, 0);
assert.equal(abortedFinishCount, 0);
assert.equal(abortedProjectIdentityReads, 1);
assert.equal(abortedProjectResourceReads, 0);

const staleRunnerStarted = deferred();
const staleRunnerRelease = deferred();
let currentExternalEpoch = 1;
let staleMutationCount = 0;
let staleDirtyCount = 0;
let staleExecution = null;
let staleProjectIdentityReads = 0;
let staleProjectResourceReads = 0;
let staleProjectDeleted = false;
const staleProject = {
  getPackageName: () => {
    staleProjectIdentityReads++;
    if (staleProjectDeleted) {
      throw new Error('a stale runner must not touch the deleted project');
    }
    return gameId;
  },
  getResourcesManager: () => {
    staleProjectResourceReads++;
    throw new Error('a stale runner must not read project resources');
  },
};
const staleExternalExecutor = new executorModule.PlaymeshAiExecutor({
  client: {
    finishExecution: async (_gameId, _sessionId, callId, execution) => {
      staleExecution = execution;
      return { call: { ...makeCall(callId), state: 'failed' } };
    },
  },
  executeEditorFunction: runDeferredExternalWrapper,
  createLocalWrappers: options => ({
    create_or_update_jfxr_sound: async ({ call, project: wrapperProject }) => {
      staleRunnerStarted.resolve();
      await staleRunnerRelease.promise;
      options.beforeProjectMutation();
      wrapperProject.getResourcesManager();
      staleMutationCount++;
      return {
        result: {
          status: 'finished',
          success: true,
          output: { callId: call.callId },
        },
        createdProject: null,
        transientObjectUrls: [],
      };
    },
  }),
  onProjectModified: () => staleDirtyCount++,
});
const staleExternalOperation = staleExternalExecutor.executeCall({
  ...executeOptions,
  call: {
    ...makeCall('deferred-external-stale-1'),
    toolName: 'create_or_update_jfxr_sound',
  },
  project: staleProject,
  toolsContract: deferredExternalToolContract,
  isSessionEpochCurrent: epoch => epoch === currentExternalEpoch,
});
await staleRunnerStarted.promise;
currentExternalEpoch = 2;
staleProjectDeleted = true;
staleRunnerRelease.resolve();
const staleExternalResult = await staleExternalOperation;
assert.equal(staleExternalResult.status, 'failed');
assert.equal(staleMutationCount, 0);
assert.equal(staleDirtyCount, 0);
assert.equal(staleProjectIdentityReads, 1);
assert.equal(staleProjectResourceReads, 0);
assert.deepEqual(staleExecution, {
  success: false,
  output: {
    code: 'editor_session_epoch_mismatch',
    message: 'The local GDevelop AI call could not be completed.',
    errorType: 'PlaymeshAiExecutionError',
  },
  errorCode: 'editor_session_epoch_mismatch',
  errorMessage: 'The local GDevelop AI call could not be completed.',
});

globalThis.__playmeshAiSessionImports = {
  playmeshAiClient: null,
  buildPlaymeshAiProjectContext: () => ({}),
  completePlaymeshAiFailureDiagnostics: error => error,
  createPlaymeshAiLocalRequestId: () => 'local-request-1',
};
let sessionControllerSource = await sourceOf('PlaymeshAiSessionController.js');
sessionControllerSource = sessionControllerSource
  .replace(
    "import { playmeshAiClient } from './PlaymeshAiClient';",
    'const { playmeshAiClient } = globalThis.__playmeshAiSessionImports;'
  )
  .replace(
    "import { buildPlaymeshAiProjectContext } from './PlaymeshAiProjectContext';",
    'const { buildPlaymeshAiProjectContext } = globalThis.__playmeshAiSessionImports;'
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshAiDiagnostics';/,
    `const {
      completePlaymeshAiFailureDiagnostics,
      createPlaymeshAiLocalRequestId,
    } = globalThis.__playmeshAiSessionImports;`
  );
const sessionControllerModule = await dataModule(sessionControllerSource);
const sessionRequests = [];
const sessionClient = {
  getTools: async () => ({ capabilitiesReference: {}, tools: [] }),
  openSession: async (_gameId, request) => {
    sessionRequests.push(['open', request]);
    return { session };
  },
  getSessionTools: async () => ({ capabilitiesReference: {}, tools: [] }),
  updateSession: async (_gameId, _sessionId, request) => {
    sessionRequests.push(['update', request]);
    return { ...session, locale: request.locale };
  },
  closeSession: async () => ({}),
};
const sessionController = new sessionControllerModule.PlaymeshAiSessionController({
  client: sessionClient,
  buildProjectContext: ({ selectedSceneName }) => ({ selectedSceneName }),
});
await sessionController.open({
  mode: 'agent',
  project,
  fileMetadata,
  locale: 'zh-CN',
  selectedSceneName: 'Game',
});
assert.deepEqual(sessionRequests[0], [
  'open',
  { mode: 'agent', locale: 'zh-CN', context: { selectedSceneName: 'Game' } },
]);
await sessionController.refresh({
  project,
  fileMetadata,
  locale: 'en-US',
  selectedSceneName: 'Game2',
});
assert.deepEqual(sessionRequests[1], [
  'update',
  { locale: 'en-US', context: { selectedSceneName: 'Game2' } },
]);

const productionFiles = await readdir(overlayDirectory);
for (const removed of [
  'PlaymeshAiPendingJournal.js',
  'PlaymeshAiRecoveryCoordinator.js',
  'PlaymeshAiProjectClone.js',
  'PlaymeshAiProjectObjectStager.js',
  'PlaymeshAiChatEventPayloadController.js',
]) {
  assert.equal(productionFiles.includes(removed), false, `${removed} must be deleted`);
}
const productionSource = (
  await Promise.all(
    productionFiles
      .filter(name => name.endsWith('.js'))
      .map(name => sourceOf(name))
  )
).join('\n');
assert.doesNotMatch(
  productionSource,
  /syncPlaymeshHistory|createProjectSnapshot|persistRestoredProject|runPlaymeshProjectMutation|\/project-objects|commitEvidence|pending_journal_mismatch|baseProjectContentHash|awaiting_event_payload|awaiting_correction|correctionCount|provideEventPayload|requestEventCorrection/
);
assert.match(executorSource, /project,\s*selectedSceneName/);
assert.doesNotMatch(executorSource, /cloneProject|stageProjectObjects|persistAfter|reload\(/);

console.log('PlayMesh GDevelop AI live-project client tests passed.');
