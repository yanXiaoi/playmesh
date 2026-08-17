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

const protocolSource = await sourceOf('PlaymeshAiProtocol.js');
const protocolUrl = `data:text/javascript;base64,${Buffer.from(
  protocolSource
).toString('base64')}`;
const protocol = await import(protocolUrl);

assert.equal(protocol.PLAYMESH_AI_SESSION_PROTOCOL_VERSION, '2.0.0');
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
assert.throws(
  () =>
    protocol.validatePlaymeshAiSession({
      ...session,
      editorSessionId: 's'.repeat(129),
    }),
  error => error && error.code === 'invalid_ai_response'
);
assert.throws(
  () =>
    protocol.validatePlaymeshAiTurn({
      turnId: 'bad:turn',
      editorSessionId: session.editorSessionId,
      sequence: 1,
    }),
  error => error && error.code === 'invalid_ai_response'
);

const enqueueRequests = protocol.buildPlaymeshAiEnqueueRequests({
  calls: [{ toolName: 'create_scene', arguments: { scene_name: 'Level2' } }],
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
    return jsonResponse({ protocolVersion: '2.0.0', session });
  }
  if (url.endsWith('/calls')) {
    return jsonResponse({ call: runningCall });
  }
  if (url.includes('/resource-staging/')) {
    return new Response(new Uint8Array([1, 2, 3]), {
      headers: { 'Content-Type': 'application/octet-stream' },
    });
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
await aiClient.enqueueCall(
  gameId,
  session.editorSessionId,
  eventEnqueueRequests[0],
  undefined
);
assert.deepEqual(
  JSON.parse(requests.at(-1).options.body),
  eventEnqueueRequests[0]
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
adapterSource = adapterSource.replace(
  "import { processEditorFunctionCalls } from '../EditorFunctions/EditorFunctionCallRunner';",
  'const processEditorFunctionCalls = globalThis.__playmeshAiOfficialRunner;'
);
const adapterModule = await dataModule(adapterSource);
const liveProject = {
  mutations: 0,
  getCurrentPlatform: () => ({ isExtensionLoaded: () => true }),
  hasEventsFunctionsExtensionNamed: () => false,
};
const outsideCounts = { events: 0, instances: 0, objects: 0, groups: 0 };
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
};
globalThis.__playmeshAiOfficialRunner = async options => {
  assert.equal(options.project, liveProject);
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
const executor = new executorModule.PlaymeshAiExecutor({
  client: retryClient,
  executeEditorFunction,
  createLocalWrappers: () => ({}),
  onProjectModified: () => dirtyCount++,
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
  output: {},
  errorCode: 'official_failed',
  errorMessage: 'The local GDevelop AI tool failed.',
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
