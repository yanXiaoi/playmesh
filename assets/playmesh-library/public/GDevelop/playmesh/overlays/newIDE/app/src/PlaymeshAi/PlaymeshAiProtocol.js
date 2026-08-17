// @flow

/*::
import type {
  AiGeneratedEventMissingObjectBehavior,
  AiGeneratedEventMissingResource,
  AiGeneratedEventUndeclaredVariable,
} from '../Utils/GDevelopServices/Generation';

export type PlaymeshAiObject = { +[key: string]: mixed };
export type PlaymeshAiResourceReference = {
  logicalId: string,
  name?: string,
  contentHash: string,
  mime: string,
  size: number,
  metadata?: PlaymeshAiObject,
};
export type PlaymeshAiStagedResource = {|
  resourceName: string,
  resourceKind: string,
  contentHash: string,
  mime: string,
  size: number,
  blob: Blob,
|};
export type PlaymeshAiCapabilitiesReference = {|
  contractHash: string,
  protocolVersion: string,
  toolsVersion: string,
  gdevelopVersion: string,
  upstreamCommit: string,
  storeNetworkEnabled: boolean,
  toolCount: number,
|};
export type PlaymeshAiProjectContextMetadata = {|
  schemaVersion: string,
  contentHash: string,
  size: number,
  selectedSceneName: ?string,
|};
export type PlaymeshAiSession = {
  editorSessionId: string,
  gameId: string,
  mode: 'chat' | 'agent',
  locale: string,
  projectContext: ?PlaymeshAiProjectContextMetadata,
  sequence: number,
  closed: boolean,
  ...,
};
export type PlaymeshAiTurn = {
  turnId: string,
  editorSessionId: string,
  sequence: number,
  ...,
};
export type PlaymeshAiCallState =
  | 'queued'
  | 'awaiting_approval'
  | 'running'
  | 'finished'
  | 'failed'
  | 'cancelled'
  | 'timed_out';
export type PlaymeshAiCall = {
  callId: string,
  editorSessionId: string,
  turnId: string,
  toolName: string,
  arguments: PlaymeshAiObject,
  idempotencyKey: string,
  state: PlaymeshAiCallState,
  sequence: number,
  input?: {|
    eventPayload: PlaymeshAiEventPayload,
  |},
  output?: mixed,
  error?: {
    code?: string,
    message?: string,
    ...,
  },
  ...,
};
export type PlaymeshAiEventChange = {|
  operationName: string,
  operationTargetEvent: ?string,
  isEventsJsonValid: ?boolean,
  generatedEvents: ?string,
  areEventsValid: ?boolean,
  extensionNames: ?Array<string>,
  diagnosticLines: Array<string>,
  undeclaredVariables: Array<AiGeneratedEventUndeclaredVariable>,
  undeclaredObjectVariables: {
    [objectName: string]: Array<AiGeneratedEventUndeclaredVariable>,
  },
  missingObjectBehaviors: {
    [objectName: string]: Array<AiGeneratedEventMissingObjectBehavior>,
  },
  missingResources: Array<AiGeneratedEventMissingResource>,
|};
export type PlaymeshAiEventPayload = {|
  schemaVersion: string,
  sceneName: string,
  changes: Array<PlaymeshAiEventChange>,
|};
export type PlaymeshAiManualCall = {|
  toolName: string,
  arguments: PlaymeshAiObject,
  eventPayload?: PlaymeshAiEventPayload,
|};
export type PlaymeshAiToolDefinition = {
  +name: string,
  +executionKind: 'editor_function' | 'event_payload' | 'agent_resource_cas',
  +executionConfig: PlaymeshAiObject,
  ...,
};
export type PlaymeshAiEnqueueRequest = {|
  turnId: string,
  callId: string,
  idempotencyKey: string,
  toolName: string,
  arguments: PlaymeshAiObject,
  input?: {|
    eventPayload: PlaymeshAiEventPayload,
  |},
|};
*/

export const PLAYMESH_AI_SESSION_PROTOCOL_VERSION = '2.0.0';
export const PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION = '1.0.0';
export const PLAYMESH_AI_EVENT_PAYLOAD_SCHEMA_VERSION = '1.0.0';

export const PLAYMESH_AI_CALL_STATES /*: $ReadOnlyArray<PlaymeshAiCallState> */ = Object.freeze([
  'queued',
  'awaiting_approval',
  'running',
  'finished',
  'failed',
  'cancelled',
  'timed_out',
]);

export const PLAYMESH_AI_TERMINAL_CALL_STATES /*: $ReadOnlyArray<PlaymeshAiCallState> */ = Object.freeze([
  'finished',
  'failed',
  'cancelled',
  'timed_out',
]);

const terminalCallStateSet = new Set(PLAYMESH_AI_TERMINAL_CALL_STATES);

const PLAYMESH_AI_EVENT_PAYLOAD_FIELDS = [
  'changes',
  'sceneName',
  'schemaVersion',
];
const PLAYMESH_AI_EVENT_CHANGE_FIELDS = [
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
].sort();
const PLAYMESH_AI_EVENT_OPERATION_NAMES = new Set([
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
  'delete_event',
  'insert_at_end',
]);
const PLAYMESH_AI_UNDECLARED_VARIABLE_FIELDS = [
  'name',
  'requiredScope',
  'type',
];
const PLAYMESH_AI_MISSING_BEHAVIOR_FIELDS = ['name', 'objectName', 'type'];
const PLAYMESH_AI_MISSING_RESOURCE_FIELDS = ['resourceKind', 'resourceName'];

const normalizeStringArray = (
  value /*: mixed */,
  name /*: string */
) /*: Array<string> */ => {
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string')) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      `The GDevelop AI ${name} is invalid.`
    );
  }
  return value.map(item => String(item));
};

const normalizeUndeclaredVariable = (
  value /*: mixed */
) /*: AiGeneratedEventUndeclaredVariable */ => {
  const variable = requireObject(value, 'undeclared variable');
  const requiredScopeValue = variable.requiredScope;
  const typeValue = variable.type;
  if (
    !hasExactFields(variable, PLAYMESH_AI_UNDECLARED_VARIABLE_FIELDS) ||
    typeof variable.name !== 'string' ||
    !variable.name ||
    typeof requiredScopeValue !== 'string' ||
    !['global', 'scene', 'none'].includes(requiredScopeValue) ||
    (typeValue !== null &&
      typeof typeValue !== 'string') ||
    (typeValue !== null &&
      !['number', 'string', 'boolean', 'structure', 'array'].includes(
        typeValue
      ))
  ) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      'The GDevelop AI undeclared variable is invalid.'
    );
  }
  const requiredScope = requiredScopeValue;
  const type = typeValue;
  if (
    requiredScope !== 'global' &&
    requiredScope !== 'scene' &&
    requiredScope !== 'none'
  ) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      'The GDevelop AI undeclared variable scope is invalid.'
    );
  }
  if (
    type !== null &&
    type !== 'number' &&
    type !== 'string' &&
    type !== 'boolean' &&
    type !== 'structure' &&
    type !== 'array'
  ) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      'The GDevelop AI undeclared variable type is invalid.'
    );
  }
  return {
    name: variable.name,
    requiredScope,
    type,
  };
};

const normalizeMissingBehavior = (
  value /*: mixed */
) /*: AiGeneratedEventMissingObjectBehavior */ => {
  const behavior = requireObject(value, 'missing behavior');
  if (
    !hasExactFields(behavior, PLAYMESH_AI_MISSING_BEHAVIOR_FIELDS) ||
    typeof behavior.objectName !== 'string' ||
    !behavior.objectName ||
    typeof behavior.name !== 'string' ||
    !behavior.name ||
    typeof behavior.type !== 'string' ||
    !behavior.type
  ) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      'The GDevelop AI missing behavior is invalid.'
    );
  }
  return {
    objectName: behavior.objectName,
    name: behavior.name,
    type: behavior.type,
  };
};

const normalizeMissingResource = (
  value /*: mixed */
) /*: AiGeneratedEventMissingResource */ => {
  const resource = requireObject(value, 'missing resource');
  if (
    !hasExactFields(resource, PLAYMESH_AI_MISSING_RESOURCE_FIELDS) ||
    typeof resource.resourceName !== 'string' ||
    !resource.resourceName ||
    typeof resource.resourceKind !== 'string' ||
    !resource.resourceKind
  ) {
    throw new PlaymeshAiProtocolError(
      'event_payload_schema_invalid',
      'The GDevelop AI missing resource is invalid.'
    );
  }
  return {
    resourceName: resource.resourceName,
    resourceKind: resource.resourceKind,
  };
};

const normalizeUndeclaredObjectVariables = (
  value /*: mixed */
) /*: { [objectName: string]: Array<AiGeneratedEventUndeclaredVariable> } */ => {
  const source = requireObject(value, 'undeclared object variables');
  return Object.keys(source).reduce(
    (
      normalized /*: { [objectName: string]: Array<AiGeneratedEventUndeclaredVariable> } */,
      objectName /*: string */
    ) => {
      if (!objectName || !Array.isArray(source[objectName])) {
        throw new PlaymeshAiProtocolError(
          'event_payload_schema_invalid',
          'The GDevelop AI undeclared object variables are invalid.'
        );
      }
      normalized[objectName] = source[objectName].map(
        normalizeUndeclaredVariable
      );
      return normalized;
    },
    {}
  );
};

const normalizeMissingObjectBehaviors = (
  value /*: mixed */
) /*: { [objectName: string]: Array<AiGeneratedEventMissingObjectBehavior> } */ => {
  const source = requireObject(value, 'missing object behaviors');
  return Object.keys(source).reduce(
    (
      normalized /*: { [objectName: string]: Array<AiGeneratedEventMissingObjectBehavior> } */,
      objectName /*: string */
    ) => {
      if (!objectName || !Array.isArray(source[objectName])) {
        throw new PlaymeshAiProtocolError(
          'event_payload_schema_invalid',
          'The GDevelop AI missing object behaviors are invalid.'
        );
      }
      normalized[objectName] = source[objectName].map(normalizeMissingBehavior);
      if (
        normalized[objectName].some(
          behavior => behavior.objectName !== objectName
        )
      ) {
        throw new PlaymeshAiProtocolError(
          'event_payload_schema_invalid',
          'The GDevelop AI missing behavior target is invalid.'
        );
      }
      return normalized;
    },
    {}
  );
};

const hasExactFields = (
  value /*: PlaymeshAiObject */,
  fields /*: $ReadOnlyArray<string> */
) /*: boolean */ =>
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify(fields);

const validatePlaymeshAiEventChangeCode = (
  change /*: mixed */
) /*: ?string */ => {
  if (
    !change ||
    typeof change !== 'object' ||
    Array.isArray(change) ||
    !hasExactFields(change, PLAYMESH_AI_EVENT_CHANGE_FIELDS) ||
    typeof change.operationName !== 'string' ||
    !PLAYMESH_AI_EVENT_OPERATION_NAMES.has(change.operationName) ||
    (change.operationTargetEvent !== null &&
      typeof change.operationTargetEvent !== 'string') ||
    (change.isEventsJsonValid !== null &&
      typeof change.isEventsJsonValid !== 'boolean') ||
    (change.areEventsValid !== null &&
      typeof change.areEventsValid !== 'boolean') ||
    (change.generatedEvents !== null &&
      typeof change.generatedEvents !== 'string') ||
    (change.extensionNames !== null &&
      !Array.isArray(change.extensionNames)) ||
    !Array.isArray(change.diagnosticLines) ||
    !Array.isArray(change.undeclaredVariables) ||
    !change.undeclaredObjectVariables ||
    typeof change.undeclaredObjectVariables !== 'object' ||
    Array.isArray(change.undeclaredObjectVariables) ||
    !change.missingObjectBehaviors ||
    typeof change.missingObjectBehaviors !== 'object' ||
    Array.isArray(change.missingObjectBehaviors) ||
    !Array.isArray(change.missingResources)
  ) {
    return 'event_payload_schema_invalid';
  }
  const undeclaredVariables = change.undeclaredVariables;
  const missingResources = change.missingResources;
  if (
    change.isEventsJsonValid === false ||
    change.areEventsValid === false
  ) {
    return 'event_payload_events_invalid';
  }
  try {
    if (change.extensionNames !== null) {
      normalizeStringArray(change.extensionNames, 'extension names');
    }
    normalizeStringArray(change.diagnosticLines, 'diagnostic lines');
    undeclaredVariables.map(normalizeUndeclaredVariable);
    normalizeUndeclaredObjectVariables(change.undeclaredObjectVariables);
    normalizeMissingObjectBehaviors(change.missingObjectBehaviors);
    missingResources.map(normalizeMissingResource);
  } catch (_) {
    return 'event_payload_schema_invalid';
  }
  return null;
};

const normalizePlaymeshAiEventChange = (
  change /*: mixed */
) /*: PlaymeshAiEventChange */ => {
  const changeObject = requireObject(change, 'event payload change');
  const code = validatePlaymeshAiEventChangeCode(changeObject);
  if (code) {
    throw new PlaymeshAiProtocolError(
      code,
      'The pasted GDevelop event payload change is invalid.'
    );
  }
  const operationTargetEvent =
    changeObject.operationTargetEvent == null
      ? null
      : requireString(
          changeObject.operationTargetEvent,
          'event operation target'
        );
  const generatedEvents =
    changeObject.generatedEvents == null
      ? null
      : requireString(changeObject.generatedEvents, 'generated events');
  return {
    operationName: requireString(
      changeObject.operationName,
      'event operation name'
    ),
    operationTargetEvent,
    isEventsJsonValid:
      changeObject.isEventsJsonValid == null
        ? null
        : Boolean(changeObject.isEventsJsonValid),
    generatedEvents,
    areEventsValid:
      changeObject.areEventsValid == null
        ? null
        : Boolean(changeObject.areEventsValid),
    extensionNames:
      changeObject.extensionNames == null
        ? null
        : normalizeStringArray(
            changeObject.extensionNames,
            'extension names'
          ),
    diagnosticLines: normalizeStringArray(
      changeObject.diagnosticLines,
      'diagnostic lines'
    ),
    undeclaredVariables: Array.isArray(changeObject.undeclaredVariables)
      ? changeObject.undeclaredVariables.map(normalizeUndeclaredVariable)
      : [],
    undeclaredObjectVariables: normalizeUndeclaredObjectVariables(
      changeObject.undeclaredObjectVariables
    ),
    missingObjectBehaviors: normalizeMissingObjectBehaviors(
      changeObject.missingObjectBehaviors
    ),
    missingResources: Array.isArray(changeObject.missingResources)
      ? changeObject.missingResources.map(normalizeMissingResource)
      : [],
  };
};

/**
 * Pure validation shared by paste-time enqueue and live-project execution.
 * Keeping it here prevents the parser and the executor from accepting
 * different GDevelopEventPayload shapes after an upstream upgrade.
 */
export const getPlaymeshAiEventPayloadValidationError = (
  eventPayload /*: mixed */,
  expectedSceneName /*: mixed */
) /*: ?string */ => {
  if (
    !eventPayload ||
    typeof eventPayload !== 'object' ||
    Array.isArray(eventPayload) ||
    !hasExactFields(eventPayload, PLAYMESH_AI_EVENT_PAYLOAD_FIELDS) ||
    eventPayload.schemaVersion !== PLAYMESH_AI_EVENT_PAYLOAD_SCHEMA_VERSION ||
    typeof eventPayload.sceneName !== 'string' ||
    !Array.isArray(eventPayload.changes)
  ) {
    return 'event_payload_schema_invalid';
  }
  if (eventPayload.sceneName !== expectedSceneName) {
    return 'event_payload_scene_mismatch';
  }
  for (const change of eventPayload.changes) {
    const code = validatePlaymeshAiEventChangeCode(change);
    if (code) return code;
  }
  return null;
};

export const validatePlaymeshAiEventPayload = (
  eventPayload /*: mixed */,
  expectedSceneName /*: string */
) /*: PlaymeshAiEventPayload */ => {
  const code = getPlaymeshAiEventPayloadValidationError(
    eventPayload,
    expectedSceneName
  );
  if (code) {
    throw new PlaymeshAiProtocolError(
      code,
      'The pasted GDevelop event payload is invalid.'
    );
  }
  const payload = requireObject(eventPayload, 'event payload');
  const changes = Array.isArray(payload.changes)
    ? payload.changes.map(normalizePlaymeshAiEventChange)
    : [];
  return {
    schemaVersion: requireString(payload.schemaVersion, 'event schema version'),
    sceneName: requireStringValue(payload.sceneName, 'event scene name'),
    changes,
  };
};

export class PlaymeshAiProtocolError extends Error {
  /*:: code: string; */
  /*:: reason: ?string; */

  constructor(
    code /*: string */,
    message /*: string */,
    exposeReason /*: boolean */ = false
  ) {
    super(message);
    this.name = 'PlaymeshAiProtocolError';
    this.code = code;
    if (exposeReason) this.reason = message;
  }
}

const requireString = (value /*: mixed */, name /*: string */) /*: string */ => {
  if (typeof value !== 'string' || !value.trim()) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return value;
};

export const validatePlaymeshAiClientId = (
  value /*: mixed */,
  name /*: string */ = 'identifier'
) /*: string */ => {
  if (
    typeof value !== 'string' ||
    !/^[A-Za-z0-9._-]{1,128}$/.test(value)
  ) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return value;
};

const requireStringValue = (
  value /*: mixed */,
  name /*: string */
) /*: string */ => {
  if (typeof value !== 'string') {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return value;
};

const requireInteger = (value /*: mixed */, name /*: string */) /*: number */ => {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return Number(value);
};

const requirePositiveInteger = (
  value /*: mixed */,
  name /*: string */
) /*: number */ => {
  const integer = requireInteger(value, name);
  if (integer < 1) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return integer;
};

const requireObject = (
  value /*: mixed */,
  name /*: string */
) /*: PlaymeshAiObject */ => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      `GDevelop AI ${name} is invalid.`
    );
  }
  return value;
};

const requireCallState = (value /*: mixed */) /*: PlaymeshAiCallState */ => {
  const state = requireString(value, 'call state');
  switch (state) {
    case 'queued':
    case 'awaiting_approval':
    case 'running':
    case 'finished':
    case 'failed':
    case 'cancelled':
    case 'timed_out':
      return state;
    default:
      throw new PlaymeshAiProtocolError(
        'invalid_ai_response',
        'GDevelop AI call state is invalid.'
      );
  }
};

export const validatePlaymeshAiResourceReference = (
  value /*: mixed */
) /*: PlaymeshAiResourceReference */ => {
  const resource = requireObject(value, 'resource reference');
  const contentHash = requireString(
    resource.contentHash,
    'resource content hash'
  );
  if (!/^[a-f0-9]{64}$/.test(contentHash)) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI resource content hash is invalid.'
    );
  }
  const metadata =
    resource.metadata == null
      ? undefined
      : requireObject(resource.metadata, 'resource metadata');
  const validated /*: PlaymeshAiResourceReference */ = {
    logicalId: requireString(resource.logicalId, 'resource logical id'),
    contentHash,
    mime: requireString(resource.mime, 'resource mime'),
    size: requirePositiveInteger(resource.size, 'resource size'),
  };
  if (resource.name != null) {
    validated.name = requireString(resource.name, 'resource name');
  }
  if (metadata) validated.metadata = metadata;
  return validated;
};

export const validatePlaymeshAiCapabilitiesReference = (
  value /*: mixed */
) /*: PlaymeshAiCapabilitiesReference */ => {
  const capabilities = requireObject(value, 'capabilities reference');
  const contractHash = requireString(
    capabilities.contractHash,
    'capabilities contract hash'
  );
  if (!/^[a-f0-9]{64}$/.test(contractHash)) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI capabilities contract hash is invalid.'
    );
  }
  const storeNetworkEnabled = capabilities.storeNetworkEnabled;
  if (typeof storeNetworkEnabled !== 'boolean') {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI capabilities network policy is invalid.'
    );
  }
  const toolCount = requireInteger(
    capabilities.toolCount,
    'capabilities tool count'
  );
  if (toolCount < 0) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI capabilities tool count is invalid.'
    );
  }
  return {
    contractHash,
    protocolVersion: requireString(
      capabilities.protocolVersion,
      'capabilities protocol version'
    ),
    toolsVersion: requireString(
      capabilities.toolsVersion,
      'capabilities tools version'
    ),
    gdevelopVersion: requireString(
      capabilities.gdevelopVersion,
      'capabilities GDevelop version'
    ),
    upstreamCommit: requireString(
      capabilities.upstreamCommit,
      'capabilities upstream commit'
    ),
    storeNetworkEnabled,
    toolCount,
  };
};

const validateProjectContextMetadata = (
  value /*: mixed */
) /*: ?PlaymeshAiProjectContextMetadata */ => {
  if (value == null) return null;
  const metadata = requireObject(value, 'project context metadata');
  if (metadata.schemaVersion !== PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI project context metadata is invalid.'
    );
  }
  const contentHash = requireString(
    metadata.contentHash,
    'project context content hash'
  );
  if (!/^[a-f0-9]{64}$/.test(contentHash)) {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI project context hash is invalid.'
    );
  }
  return {
    schemaVersion: PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION,
    contentHash,
    size: requirePositiveInteger(metadata.size, 'project context size'),
    selectedSceneName:
      metadata.selectedSceneName == null
        ? null
        : requireString(
            metadata.selectedSceneName,
            'project context selected scene'
          ),
  };
};

export const validatePlaymeshAiSession = (
  value /*: mixed */
) /*: PlaymeshAiSession */ => {
  const session = requireObject(value, 'session');
  const mode = requireString(session.mode, 'session mode');
  if (mode !== 'chat' && mode !== 'agent') {
    throw new PlaymeshAiProtocolError(
      'invalid_ai_response',
      'GDevelop AI session mode is invalid.'
    );
  }
  return {
    ...session,
    editorSessionId: validatePlaymeshAiClientId(
      session.editorSessionId,
      'editor session id'
    ),
    gameId: requireString(session.gameId, 'game id'),
    mode,
    locale: requireString(session.locale, 'locale'),
    projectContext: validateProjectContextMetadata(session.projectContext),
    sequence: requireInteger(session.sequence, 'session sequence'),
    closed: session.closed === true,
  };
};

export const validatePlaymeshAiTurn = (
  value /*: mixed */
) /*: PlaymeshAiTurn */ => {
  const turn = requireObject(value, 'turn');
  return {
    ...turn,
    turnId: validatePlaymeshAiClientId(turn.turnId, 'turn id'),
    editorSessionId: validatePlaymeshAiClientId(
      turn.editorSessionId,
      'editor session id'
    ),
    sequence: requireInteger(turn.sequence, 'turn sequence'),
  };
};

export const validatePlaymeshAiCall = (
  value /*: mixed */
) /*: PlaymeshAiCall */ => {
  const call = requireObject(value, 'call');
  const state = requireCallState(call.state);
  const validated /*: any */ = {
    callId: validatePlaymeshAiClientId(call.callId, 'call id'),
    editorSessionId: validatePlaymeshAiClientId(
      call.editorSessionId,
      'editor session id'
    ),
    turnId: validatePlaymeshAiClientId(call.turnId, 'turn id'),
    toolName: requireString(call.toolName, 'tool name'),
    arguments: requireObject(call.arguments, 'call arguments'),
    idempotencyKey: validatePlaymeshAiClientId(
      call.idempotencyKey,
      'idempotency key'
    ),
    state,
    sequence: requireInteger(call.sequence, 'call sequence'),
  };
  if (call.input != null) {
    const input = requireObject(call.input, 'call input');
    if (!hasExactFields(input, ['eventPayload'])) {
      throw new PlaymeshAiProtocolError(
        'invalid_ai_response',
        'GDevelop AI call input is invalid.'
      );
    }
    validated.input = {
      // Semantic validation belongs to the executor so a leased invalid input
      // is completed once as a normal tool failure instead of breaking polling.
      eventPayload: (requireObject(
        input.eventPayload,
        'event payload input'
      ) /*: any */),
    };
  }
  if (call.output != null) {
    validated.output = requireObject(call.output, 'call output');
  }
  if (call.error != null) {
    const rawError = requireObject(call.error, 'call error');
    const validatedError /*: any */ = {};
    if (rawError.code != null) {
      validatedError.code = requireString(rawError.code, 'call error code');
    }
    if (rawError.message != null) {
      validatedError.message = requireString(
        rawError.message,
        'call error message'
      );
    }
    validated.error = validatedError;
  }
  return validated;
};

export const isPlaymeshAiTerminalCall = (
  call /*: PlaymeshAiCall */
) /*: boolean */ =>
  terminalCallStateSet.has(call.state);

const extractJsonCandidate = (input /*: string */) /*: string */ => {
  const trimmed = input.trim();
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced && fenced[1]) return fenced[1].trim();
  try {
    JSON.parse(trimmed);
    return trimmed;
  } catch (_) {}

  const objectStart = trimmed.indexOf('{');
  const arrayStart = trimmed.indexOf('[');
  const start =
    objectStart === -1
      ? arrayStart
      : arrayStart === -1
      ? objectStart
      : Math.min(objectStart, arrayStart);
  if (start === -1) return trimmed;
  const end = Math.max(trimmed.lastIndexOf('}'), trimmed.lastIndexOf(']'));
  return end > start ? trimmed.slice(start, end + 1) : trimmed.slice(start);
};

const parseArguments = (value /*: mixed */) /*: PlaymeshAiObject */ => {
  let parsed = value;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch (_) {
      throw new PlaymeshAiProtocolError(
        'invalid_manual_calls',
        'A pasted GDevelop AI call has invalid JSON arguments.'
      );
    }
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new PlaymeshAiProtocolError(
      'invalid_manual_calls',
      'A pasted GDevelop AI call must contain an arguments object.'
    );
  }
  return parsed;
};

/**
 * Chat output is intentionally reduced to the public model-facing fields.
 * Turn, call and idempotency fields always come from the live editor session
 * so a model cannot choose Gateway coordination identifiers.
 */
export const parsePlaymeshManualToolCalls = (
  input /*: string */,
  tools /*: $ReadOnlyArray<PlaymeshAiToolDefinition> */ = []
) /*: Array<PlaymeshAiManualCall> */ => {
  let parsed;
  try {
    parsed = JSON.parse(extractJsonCandidate(input));
  } catch (_) {
    throw new PlaymeshAiProtocolError(
      'invalid_manual_calls',
      'The pasted GDevelop AI response does not contain valid JSON.'
    );
  }
  const rawCalls = Array.isArray(parsed)
    ? parsed
    : parsed && Array.isArray(parsed.calls)
    ? parsed.calls
    : parsed && Array.isArray(parsed.toolCalls)
    ? parsed.toolCalls
    : parsed && Array.isArray(parsed.tool_calls)
    ? parsed.tool_calls
    : [parsed];
  if (!rawCalls.length) {
    throw new PlaymeshAiProtocolError(
      'invalid_manual_calls',
      'The pasted GDevelop AI response has an invalid call count.'
    );
  }
  return rawCalls.map(rawCall => {
    const call = requireObject(rawCall, 'manual call');
    const functionCall =
      call.function && typeof call.function === 'object'
        ? call.function
        : call;
    const declaredToolName =
      typeof functionCall.name === 'string' && functionCall.name.trim()
        ? functionCall.name
        : typeof functionCall.toolName === 'string' &&
          functionCall.toolName.trim()
        ? functionCall.toolName
        : '';
    if (!declaredToolName) {
      throw new PlaymeshAiProtocolError(
        'manual_call_envelope_required',
        'Use a complete GDevelop AI call: {"name":"the exact tool name from the index","arguments":{}}.',
        true
      );
    }
    const toolName = requireString(declaredToolName, 'manual tool name');
    const toolArguments = parseArguments(functionCall.arguments);
    const toolDefinition = tools.find(tool => tool.name === toolName);
    const expectsEventPayload =
      toolDefinition && toolDefinition.executionKind === 'event_payload';
    const hasEventPayload = 'eventPayload' in functionCall;
    if (expectsEventPayload && !hasEventPayload) {
      throw new PlaymeshAiProtocolError(
        'event_payload_required',
        'This pasted call must contain eventPayload next to name and arguments.'
      );
    }
    if (tools.length && !expectsEventPayload && hasEventPayload) {
      throw new PlaymeshAiProtocolError(
        'event_payload_not_allowed',
        'The registered tool does not accept an event payload.'
      );
    }
    const sceneArgument =
      toolDefinition &&
      toolDefinition.executionConfig &&
      toolDefinition.executionConfig.sceneArgument;
    const eventPayload = hasEventPayload
      ? validatePlaymeshAiEventPayload(
          functionCall.eventPayload,
          requireString(
            toolArguments[
              typeof sceneArgument === 'string' ? sceneArgument : 'scene_name'
            ],
            'event scene name'
          )
        )
      : null;
    return {
      toolName,
      arguments: toolArguments,
      ...(eventPayload ? { eventPayload } : {}),
    };
  });
};

export const createPlaymeshAiClientId = (
  prefix /*: string */
) /*: string */ => {
  const suffix =
    global.crypto && typeof global.crypto.randomUUID === 'function'
      ? global.crypto.randomUUID()
      : `${Date.now().toString(36)}-${Math.random()
          .toString(36)
          .slice(2)}`;
  return `${prefix}-${suffix}`;
};

export const buildPlaymeshAiEnqueueRequests = ({
  calls,
  turnId,
  session,
  tools,
} /*: {|
  calls: Array<PlaymeshAiManualCall>,
  turnId: string,
  session: PlaymeshAiSession,
  tools: $ReadOnlyArray<PlaymeshAiToolDefinition>,
|} */) /*: Array<PlaymeshAiEnqueueRequest> */ => {
  const knownTools = new Set(
    tools.map(tool => requireString(tool && tool.name, 'tool registry name'))
  );
  const resolvedTurnId = requireString(turnId, 'turn id');
  validatePlaymeshAiSession(session);
  return calls.map(call => {
    if (!knownTools.has(call.toolName)) {
      throw new PlaymeshAiProtocolError(
        'unknown_manual_tool',
        'The pasted response uses a tool not exposed by this GDevelop runtime.'
      );
    }
    const toolDefinition = tools.find(tool => tool.name === call.toolName);
    const expectsEventPayload =
      toolDefinition && toolDefinition.executionKind === 'event_payload';
    if (expectsEventPayload && !call.eventPayload) {
      throw new PlaymeshAiProtocolError(
        'event_payload_required',
        'This GDevelop AI call must contain an event payload.'
      );
    }
    if (!expectsEventPayload && call.eventPayload) {
      throw new PlaymeshAiProtocolError(
        'event_payload_not_allowed',
        'The registered tool does not accept an event payload.'
      );
    }
    const callId = createPlaymeshAiClientId('call');
    return {
      turnId: resolvedTurnId,
      callId,
      idempotencyKey: createPlaymeshAiClientId(`idempotency-${callId}`),
      toolName: call.toolName,
      arguments: requireObject(call.arguments, 'call arguments'),
      ...(call.eventPayload
        ? { input: { eventPayload: call.eventPayload } }
        : {}),
    };
  });
};
