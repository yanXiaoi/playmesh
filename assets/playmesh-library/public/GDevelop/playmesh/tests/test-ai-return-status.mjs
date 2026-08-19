import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiReturnStatus.js'
  ),
  'utf8'
);
const panelSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiPanel.js'
  ),
  'utf8'
);
const editorContainerSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiEditorContainer.js'
  ),
  'utf8'
);
assert.doesNotMatch(
  `${source}\n${panelSource}\n${editorContainerSource}`,
  /awaiting_event_payload|awaiting_correction|correctionCount|provide_corrected_event_payload|recoveryStatus|PlaymeshAiRecoveryStatus|EVENT_PAYLOAD_RECOVERY/
);
assert.match(
  panelSource,
  /disabled=\{\s*busy \|\| isCallCancellationDisabled\(call\.callId\)\s*\}/
);
assert.match(
  panelSource,
  /disabled=\{\s*busy \|\| isTurnCancellationDisabled\(call\.turnId\)\s*\}/
);
const transformedSource = transformFlow(source);
const statusModule = await import(
  `data:text/javascript;base64,${Buffer.from(transformedSource).toString(
    'base64'
  )}`
);

const session = {
  editorSessionId: 'editor-session-1',
  gameId: 'com.playmesh.game.demo',
  mode: 'agent',
  locale: 'zh-CN',
  sequence: 7,
  closed: false,
};
const baseCall = {
  callId: 'call-1',
  editorSessionId: session.editorSessionId,
  turnId: 'turn-1',
  toolName: 'create_scene',
  arguments: { scene_name: 'Secret scene text must not be copied' },
  idempotencyKey: 'idempotency-secret',
  sequence: 8,
};
const chatOperation = { echo: 37, turnId: baseCall.turnId };

assert.match(
  panelSource,
  /\{view === 'chat' && session && \(\s*<>[\s\S]*?<CompactTextAreaField[\s\S]*?playmeshMessages\.aiPasteAndExecute[\s\S]*?onCopyReturnStatus\(returnStatusText\)[\s\S]*?playmeshMessages\.aiClearInput[\s\S]*?<\/>\s*\)\}/,
  'Chat input, paste/send, copy response, and clear must share one Chat-only boundary.'
);
assert.match(
  panelSource,
  /\{view === 'chat' && session && \(\s*<Accordion[\s\S]*?aiReturnStatusTitle[\s\S]*?returnStatusText/,
  'Only Chat may expose the compact return-status view.'
);
assert.equal(
  panelSource.match(/onCopyReturnStatus\(returnStatusText\)/g)?.length,
  1,
  'Agent must not expose a second manual copy-return-status action.'
);

const addSceneEventsToolDetails = {
  name: 'add_scene_events',
  summary: 'Generate and add standard GDevelop events to a scene.',
  argumentsSchema: {
    type: 'object',
    additionalProperties: false,
    required: ['scene_name', 'events_description', 'extension_names_list'],
    properties: {
      scene_name: { type: 'string', minLength: 1, maxLength: 255 },
      events_description: { type: 'string', minLength: 1, maxLength: 131072 },
      extension_names_list: { type: 'string', maxLength: 32768 },
      objects_list: { type: 'string', maxLength: 131072 },
      estimated_complexity: { type: 'number', minimum: 0 },
      placement_hint: { type: 'string', maxLength: 65536 },
    },
  },
  eventPayloadSchema: {
    $id: 'playmesh.gdevelop.event-payload/1.0.0',
    title: 'GDevelopEventPayload',
    type: 'object',
    additionalProperties: false,
    required: ['schemaVersion', 'sceneName', 'changes'],
    properties: {
      schemaVersion: { type: 'string', const: '1.0.0' },
      sceneName: { type: 'string', minLength: 1, maxLength: 255 },
      changes: {
        type: 'array',
        minItems: 1,
        items: {
          type: 'object',
          additionalProperties: false,
          required: [
            'operationName',
            'operationTargetEvent',
            'isEventsJsonValid',
            'generatedEvents',
            'areEventsValid',
            'extensionNames',
            'diagnosticLines',
            'undeclaredVariables',
            'undeclaredObjectVariables',
            'missingObjectBehaviors',
            'missingResources',
          ],
          properties: {
            operationName: {
              type: 'string',
              enum: [
                'delete_event',
                'insert_and_replace_event',
                'replace_entire_event_and_sub_events',
                'replace_event_but_keep_existing_sub_events',
                'insert_before_event',
                'insert_after_event',
                'insert_as_sub_event',
                'insert_actions_conditions_at_end',
                'insert_actions_conditions_at_start',
                'replace_all_actions',
                'replace_all_conditions',
                'insert_at_end',
              ],
            },
            operationTargetEvent: { type: ['string', 'null'] },
            isEventsJsonValid: { type: ['boolean', 'null'] },
            generatedEvents: {
              type: ['string', 'null'],
              description:
                'Official serialized gd.EventsList JSON consumed by applyEventsChanges.',
            },
            areEventsValid: { type: ['boolean', 'null'] },
            extensionNames: {
              type: ['array', 'null'],
              items: { type: 'string' },
            },
            diagnosticLines: {
              type: 'array',
              items: { type: 'string' },
            },
            undeclaredVariables: {
              type: 'array',
              items: { type: 'object' },
            },
            undeclaredObjectVariables: {
              type: 'object',
              additionalProperties: {
                type: 'array',
                items: { type: 'object' },
              },
            },
            missingObjectBehaviors: {
              type: 'object',
              additionalProperties: {
                type: 'array',
                items: { type: 'object' },
              },
            },
            missingResources: {
              type: 'array',
              items: { type: 'object' },
            },
          },
        },
      },
    },
  },
  risk: 'high',
  modifiesProject: true,
  approvalRequired: true,
  implementation: 'playmesh_wrapper',
  officialImplementationName: 'add_scene_events',
  chatEnabled: true,
  agentEnabled: true,
  timeoutMs: 90000,
};

const changeSceneToolDetails = {
  name: 'change_scene_properties_layers_effects_groups',
  summary: 'Change or delete a scene.',
  argumentsSchema: {
    type: 'object',
    additionalProperties: false,
    required: ['scene_name'],
    properties: {
      scene_name: { type: 'string', minLength: 1, maxLength: 255 },
      delete_this_scene: { type: 'boolean' },
    },
  },
  risk: 'high',
  modifiesProject: true,
  approvalRequired: true,
  implementation: 'official_editor_function',
  officialImplementationName: 'change_scene_properties_layers_effects_groups',
  chatEnabled: true,
  agentEnabled: true,
  timeoutMs: 30000,
};

const importProjectResourceToolDetails = {
  name: 'import_project_resource',
  summary:
    'Import an Agent-staged resource through the pinned GDevelop ResourceSource creation seam without adding Playmesh format rules.',
  argumentsSchema: {
    type: 'object',
    additionalProperties: false,
    required: ['resource_name', 'resource_kind', 'content_hash', 'mime', 'size'],
    properties: {
      resource_name: { type: 'string' },
      resource_kind: { type: 'string' },
      content_hash: { type: 'string', pattern: '^[a-f0-9]{64}$' },
      mime: { type: 'string' },
      size: { type: 'integer', minimum: 1 },
    },
  },
  risk: 'medium',
  modifiesProject: true,
  approvalRequired: true,
  implementation: 'playmesh_wrapper',
  officialImplementationName: 'import_project_resource',
  chatEnabled: false,
  agentEnabled: true,
  timeoutMs: 60000,
  binaryStaging: {
    method: 'PUT',
    path:
      '/dev/api/gdevelop/projects/{gameId}/ai/editor-sessions/{editorSessionId}/resource-staging/{contentHash}',
    body: 'raw-binary',
    channel: 'agent',
    loopbackOnly: false,
    requiresForegroundView: true,
    requiredHeaders: [
      'Authorization: Bearer <developer-token>',
      'X-Playmesh-AI-Channel: agent',
      'Content-Type: <resource-mime>',
    ],
  },
};

{
  const statusText = statusModule.serializePlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation,
    calls: [
      {
        ...baseCall,
        state: 'finished',
        output: {
          createdScene: 'Level 1',
          endpoint: 'https://example.invalid/result?token=root-secret-value',
          authorization: 'Bearer root-secret-value',
          commit: {
            state: 'business_commit',
          },
          commitEvidence: { source: 'business_output' },
          historyTransaction: { source: 'business_output' },
        },
      },
    ],
    approvals: [],
    failure: null,
    connectionStatus: 'online',
  });
  const status = JSON.parse(statusText);
  assert.equal(status.schemaVersion, 'playmesh.gdevelop.ai.return-status.v3');
  assert.equal(status.echo, chatOperation.echo);
  assert.equal(status.recoveryStatus, undefined);
  assert.equal(status.editorSession, undefined);
  assert.equal(status.latestTurn.turnId, undefined);
  assert.equal(status.latestTurn.calls[0].callId, undefined);
  assert.equal(status.latestTurn.calls[0].sequence, undefined);
  assert.equal(status.latestTurn.calls[0].baseRevision, undefined);
  assert.equal(status.latestTurn.calls[0].correctionCount, undefined);
  assert.equal(status.latestTurn.calls[0].echo, undefined);
  assert.equal(status.latestTurn.calls[0].result.createdScene, 'Level 1');
  assert.deepEqual(status.latestTurn.calls[0].result.commit, {
    state: 'business_commit',
  });
  assert.deepEqual(
    status.latestTurn.calls[0].result.commitEvidence,
    { source: 'business_output' }
  );
  assert.deepEqual(
    status.latestTurn.calls[0].result.historyTransaction,
    { source: 'business_output' }
  );
  assert.equal(status.latestTurn.calls[0].commitEvidence, undefined);
  assert.equal(
    status.latestTurn.calls[0].result.endpoint,
    'https://example.invalid/result?token=root-secret-value'
  );
  assert.equal(
    status.latestTurn.calls[0].result.authorization,
    'Bearer root-secret-value'
  );
  assert.equal(status.shouldContinuePolling, false);
  assert.equal(status.nextAction, 'copy_status_to_ai_for_next_turn');
  assert.match(statusText, /root-secret-value/);
  assert.doesNotMatch(statusText, /Secret scene text/);
  assert.doesNotMatch(statusText, /idempotency-secret/);
  assert.match(statusText, /\?token=root-secret-value/);
  assert.doesNotMatch(statusText, /editor-session-1/);
  assert.doesNotMatch(statusText, /com\.playmesh\.game\.demo/);
  assert.doesNotMatch(statusText, /turn-1/);
  assert.doesNotMatch(statusText, /call-1/);

  const agentStatus = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'agent',
    session,
    calls: [
      {
        ...baseCall,
        state: 'finished',
        output: { commit: { state: 'business_commit' } },
      },
    ],
    approvals: [],
    failure: null,
    connectionStatus: 'online',
  });
  assert.equal(agentStatus.editorSession.sequence, session.sequence);
  assert.equal(agentStatus.schemaVersion, 'playmesh.gdevelop.ai.return-status.v1');
  assert.equal(agentStatus.echo, undefined);
  assert.equal(agentStatus.latestTurn.calls[0].echo, undefined);
  assert.deepEqual(
    agentStatus.latestTurn.calls[0].result,
    { commit: { state: 'business_commit' } }
  );
  assert.equal(agentStatus.latestTurn.calls[0].commitEvidence, undefined);
}

{
  const requestFailure = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation: { echo: 41, turnId: null },
    calls: [],
    approvals: [],
    failure: {
      stage: 'response',
      operation: 'gdevelop.ai.call.enqueue',
      status: 409,
      code: 'ai_conflict',
      reason: 'The call was rejected.',
      requestId: 'request-echo-41',
      errorType: 'PlaymeshAiRequestError',
    },
    connectionStatus: 'online',
  });
  assert.equal(requestFailure.echo, 41);
  assert.equal(requestFailure.failure.echo, undefined);

  const turnRequestFailure = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation: { echo: 42, turnId: null },
    calls: [],
    approvals: [],
    failure: {
      stage: 'request',
      operation: 'gdevelop.ai.turn.create',
      status: 0,
      code: 'ai_unavailable',
      reason: 'The turn request failed.',
      requestId: 'request-echoes-42-43',
      errorType: 'PlaymeshAiRequestError',
    },
    connectionStatus: 'offline',
  });
  assert.equal(turnRequestFailure.echo, 42);
  assert.equal(turnRequestFailure.failure.echo, undefined);

  const agentFailure = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'agent',
    session,
    calls: [],
    approvals: [],
    failure: {
      stage: 'response',
      operation: 'gdevelop.ai.call.enqueue',
      status: 409,
      code: 'ai_conflict',
      reason: 'The call was rejected.',
      requestId: 'request-echo-44',
      errorType: 'PlaymeshAiRequestError',
    },
    connectionStatus: 'online',
  });
  assert.equal(agentFailure.failure.echo, undefined);
}

{
  const longEvents = Array.from(
    { length: 240 },
    (_, index) =>
      `<event-${index}>Conditions: scene event ${index}; Actions: keep full output ${index}.</event-${index}>`
  ).join('\n');
  const completeArray = Array.from({ length: 125 }, (_, index) => ({
    index,
    label: `item-${index}`,
  }));
  const completeObject = Object.fromEntries(
    Array.from({ length: 175 }, (_, index) => [
      `field_${index}`,
      `value-${index}`,
    ])
  );
  const sharedMetadata = { label: 'shared-value' };
  const deeplyNested = { level: 0 };
  let nestedCursor = deeplyNested;
  for (let level = 1; level <= 150; level += 1) {
    nestedCursor.next = { level };
    nestedCursor = nestedCursor.next;
  }
  const circular = { label: 'cycle-root' };
  circular.self = circular;
  const status = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation,
    calls: [
      {
        ...baseCall,
        toolName: 'read_scene_events',
        state: 'finished',
        output: {
          eventsAsText: longEvents,
          eventsForSceneNamed: 'Game',
          completeArray,
          completeObject,
          firstSharedReference: sharedMetadata,
          secondSharedReference: sharedMetadata,
          deeplyNested,
          circular,
          authorization: 'Bearer root-secret-value',
        },
      },
    ],
    approvals: [],
    failure: null,
    connectionStatus: 'online',
  });
  const result = status.latestTurn.calls[0].result;
  assert.equal(result.eventsAsText, longEvents);
  assert.equal(result.eventsAsText.length > 1024, true);
  assert.deepEqual(result.completeArray, completeArray);
  assert.deepEqual(result.completeObject, completeObject);
  assert.deepEqual(result.firstSharedReference, sharedMetadata);
  assert.deepEqual(result.secondSharedReference, sharedMetadata);
  assert.deepEqual(result.deeplyNested, deeplyNested);
  assert.equal(result.circular.label, 'cycle-root');
  assert.equal(result.circular.self, '[OMITTED]');
  assert.equal(result.authorization, 'Bearer root-secret-value');
}

for (const mode of ['chat', 'agent']) {
  for (const toolDetails of [
    addSceneEventsToolDetails,
    changeSceneToolDetails,
    importProjectResourceToolDetails,
  ]) {
    const statusText = statusModule.serializePlaymeshAiReturnStatus({
      mode,
      session,
      calls: [
        {
          ...baseCall,
          toolName: 'get_gdevelop_tool_details',
          arguments: {
            tool_name: toolDetails.name,
            secret: 'must-not-copy',
          },
          state: 'finished',
          output: {
            status: 'available',
            tool: toolDetails,
          },
        },
      ],
      approvals: [],
      failure: null,
      connectionStatus: 'online',
    });
    const status = JSON.parse(statusText);
    const result = status.latestTurn.calls[0].result;
    assert.equal(result.status, 'available');
    assert.deepEqual(result.tool, toolDetails);
    assert.doesNotMatch(JSON.stringify(result.tool), /\[REDACTED\]|\[OMITTED\]/);
    assert.doesNotMatch(statusText, /must-not-copy/);
    assert.doesNotMatch(statusText, /idempotency-secret/);
    assert.doesNotMatch(statusText, /"arguments":/);
  }
}

assert.equal(
  addSceneEventsToolDetails.eventPayloadSchema.properties.schemaVersion.const,
  '1.0.0'
);
assert.deepEqual(
  changeSceneToolDetails.argumentsSchema.properties.delete_this_scene,
  { type: 'boolean' }
);
assert.equal('officialArguments' in changeSceneToolDetails, false);
assert.equal(
  importProjectResourceToolDetails.binaryStaging.requiredHeaders[0],
  'Authorization: Bearer <developer-token>'
);
assert.equal(
  importProjectResourceToolDetails.binaryStaging.loopbackOnly,
  false
);

{
  const statusText = statusModule.serializePlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation: null,
    calls: [],
    approvals: [],
    failure: {
      stage: 'pre_request',
      operation: 'gdevelop.ai.turn.execute',
      status: 0,
      code: 'manual_call_envelope_required',
      reason:
        'Use a complete GDevelop AI call: {"name":"get_gdevelop_tool_details","arguments":{"tool_name":"the exact target tool name"}}.',
      requestId: 'web-envelope-1',
      errorType: 'PlaymeshAiProtocolError',
    },
    connectionStatus: 'online',
  });
  const status = JSON.parse(statusText);
  assert.equal(status.latestTurn, null);
  assert.equal(status.echo, null);
  assert.equal(status.failure.code, 'manual_call_envelope_required');
  assert.equal(status.failure.errorType, 'PlaymeshAiProtocolError');
  assert.match(status.failure.reason, /get_gdevelop_tool_details/);
  assert.equal(status.nextAction, 'copy_status_to_ai_and_replan');
}

{
  const status = statusModule.buildPlaymeshAiReturnStatus({
    mode: 'agent',
    session,
    calls: [{ ...baseCall, state: 'awaiting_approval' }],
    approvals: [
      {
        approvalId: 'approval-1',
        toolName: 'create_scene',
        risk: 'medium',
        beforeRevision: 3,
        afterRevision: 4,
        arguments: [{ name: 'secret', value: 'must-not-copy' }],
      },
    ],
    failure: null,
    connectionStatus: 'online',
  });
  assert.equal(status.shouldContinuePolling, true);
  assert.equal(status.nextAction, 'wait_for_user_approval');
  assert.equal(status.pendingApprovals[0].status, 'waiting');
  assert.equal(status.latestTurn.calls[0].approvalStatus, 'waiting');
  assert.doesNotMatch(JSON.stringify(status), /must-not-copy/);
}

{
  const statusText = statusModule.serializePlaymeshAiReturnStatus({
    mode: 'chat',
    session,
    chatOperation,
    calls: [
      {
        ...baseCall,
        state: 'failed',
        error: {
          code: 'editor_function_failed',
          message:
            'Revision changed; token=root-secret-value Bearer root-secret-value',
        },
        output: { reason: 'safe function failure reason' },
      },
    ],
    approvals: [],
    failure: {
      stage: 'pre_request',
      operation: 'gdevelop.ai.turn.execute',
      status: 0,
      code: 'invalid_manual_calls',
      reason: 'TypeError failed before token=root-secret-value',
      requestId: 'web-request-1',
      errorType: 'TypeError',
    },
    connectionStatus: 'online',
  });
  const status = JSON.parse(statusText);
  assert.equal(status.latestTurn.calls[0].failure.stage, 'tool_execution');
  assert.equal(
    status.latestTurn.calls[0].failure.code,
    'editor_function_failed'
  );
  assert.equal(status.failure.stage, 'pre_request');
  assert.equal(status.failure.requestId, undefined);
  assert.equal(status.latestTurn.calls[0].failure.requestId, undefined);
  assert.equal(status.failure.errorType, 'TypeError');
  assert.equal(status.nextAction, 'copy_status_to_ai_and_replan');
  assert.doesNotMatch(statusText, /root-secret-value/);
  assert.doesNotMatch(statusText, /web-request-1/);
}

{
  const shared = {
    session,
    calls: [{ ...baseCall, state: 'running' }],
    approvals: [],
    failure: null,
    connectionStatus: 'online',
  };
  const chat = statusModule.buildPlaymeshAiReturnStatus({
    ...shared,
    mode: 'chat',
    chatOperation,
  });
  const agent = statusModule.buildPlaymeshAiReturnStatus({
    ...shared,
    mode: 'agent',
  });
  assert.equal(chat.editorSession, undefined);
  assert.equal(chat.latestTurn.turnId, undefined);
  assert.equal(chat.latestTurn.calls[0].callId, undefined);
  assert.equal(chat.echo, chatOperation.echo);
  assert.equal(chat.latestTurn.calls[0].echo, undefined);
  assert.equal(agent.editorSession.editorSessionId, session.editorSessionId);
  assert.equal(agent.editorSession.gameId, session.gameId);
  assert.equal(agent.latestTurn.turnId, baseCall.turnId);
  assert.equal(agent.latestTurn.calls[0].callId, baseCall.callId);
  assert.equal(agent.latestTurn.calls[0].sequence, baseCall.sequence);
  assert.equal(agent.latestTurn.calls[0].baseRevision, undefined);
  assert.equal(chat.shouldContinuePolling, true);
  assert.equal(chat.nextAction, 'continue_polling');
  assert.equal(agent.shouldContinuePolling, true);
  assert.equal(agent.nextAction, 'continue_polling');
}

process.stdout.write('GDevelop Playmesh AI return-status tests passed.\n');
