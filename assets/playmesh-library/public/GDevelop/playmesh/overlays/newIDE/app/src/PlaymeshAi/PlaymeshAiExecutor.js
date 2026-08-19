// @flow

import { playmeshAiClient } from './PlaymeshAiClient';
import { executePlaymeshAiEditorFunction } from './PlaymeshAiEditorFunctionAdapter';
import { createPlaymeshAiLocalToolWrappers } from './PlaymeshAiLocalToolWrappers';
import {
  isPlaymeshAiTerminalCall,
  validatePlaymeshAiEventPayload,
} from './PlaymeshAiProtocol';
import { sha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';

/*::
import type {
  PlaymeshAiClient,
  PlaymeshAiExecutionEnvelope,
  PlaymeshAiExecutionRequest,
} from './PlaymeshAiClient';
import type {
  PlaymeshAiCall,
  PlaymeshAiEventPayload,
  PlaymeshAiObject,
  PlaymeshAiStagedResource,
} from './PlaymeshAiProtocol';
import type { FileMetadata } from '../ProjectsStorage';
import type {
  PlaymeshAiEventPayloadContext,
  PlaymeshAiLocalToolContext,
  PlaymeshAiLocalToolExecution,
  PlaymeshAiLocalToolWrappers,
  PlaymeshAiLocalToolWrappersOptions,
  PlaymeshAiPlan,
} from './PlaymeshAiLocalToolWrappers';
import type {
  PlaymeshAiRunnerOptions,
  PlaymeshAiToolDefinition,
  PlaymeshAiToolsContract,
} from './PlaymeshAiEditorFunctionTypes';
import type { EditorFunctionCallResult } from '../EditorFunctions';

type PlaymeshAiExecutionOutput = PlaymeshAiObject;
type PlaymeshAiPendingExecutionResult = {|
  gameId: string,
  sessionId: string,
  callId: string,
  turnId: string,
  execution: PlaymeshAiExecutionRequest,
|};
export type PlaymeshAiExecutionOutcome = {
  +status: 'finished' | 'failed' | 'cancelled',
  +call?: PlaymeshAiCall,
  +callId?: string,
  ...,
};
type PlaymeshAiExecutorOptions = {
  client?: PlaymeshAiClient,
  executeEditorFunction?: typeof executePlaymeshAiEditorFunction,
  createLocalWrappers?: typeof createPlaymeshAiLocalToolWrappers,
  applyEventPayload?: PlaymeshAiEventPayloadContext =>
    Promise<PlaymeshAiLocalToolExecution>,
  readFullDocs?: ({|
    project: gdProject,
    extensionNames: string,
  |}) => Promise<mixed>,
  updatePlan?: PlaymeshAiPlan => Promise<mixed>,
  onProjectModified?: () => mixed,
  onFetchNewlyAddedResources?: () => Promise<void>,
  onNewResourcesAdded?: () => void,
  ...,
};
type PlaymeshAiExecutionIdentity = {|
  gameId: string,
  sessionId: string,
  sessionEpoch: number,
  isSessionEpochCurrent: number => boolean,
  call: PlaymeshAiCall,
  project: gdProject,
  fileMetadata: FileMetadata,
|};
type PlaymeshAiExecuteCallOptions = {
  ...PlaymeshAiExecutionIdentity,
  selectedSceneName: ?string,
  toolsContract: PlaymeshAiToolsContract,
  runnerOptions: PlaymeshAiRunnerOptions,
  signal?: ?AbortSignal,
  abortHandle?: ?PlaymeshAiExecutionAbortHandle,
};
*/

export class PlaymeshAiExecutionError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The local GDevelop AI call could not be completed.');
    this.name = 'PlaymeshAiExecutionError';
    this.code = code;
  }
}

const executionIdentityKey = (
  gameId /*: string */,
  sessionId /*: string */,
  callId /*: string */
) /*: string */ => JSON.stringify([gameId, sessionId, callId]);

const sharedExecutionResults /*: Map<string, PlaymeshAiPendingExecutionResult> */ = new Map();
const sharedExecutionOperations /*: Map<string, Promise<PlaymeshAiExecutionOutcome>> */ = new Map();
const DEFERRED_PROJECT_MUTATION_TOOLS = new Set([
  'import_sprite_sheet_animation',
  'import_gif_animation',
  'create_or_update_jfxr_sound',
  'create_or_update_yarn_dialogue',
]);

const hasPendingExecutionResult = (
  gameId /*: string */,
  sessionId /*: string */,
  callId /*: string */
) /*: boolean */ =>
  sharedExecutionResults.has(executionIdentityKey(gameId, sessionId, callId));

/**
 * Read-only calls remain cancellable. A project mutation becomes
 * non-cancellable immediately before the official EditorFunction touches the
 * live gdProject, because there is deliberately no clone or rollback layer.
 */
export class PlaymeshAiExecutionAbortHandle {
  /*:: controller: AbortController; */
  /*:: phase: 'cancellable' | 'executing' | 'complete'; */
  /*:: removeParentAbortListener: ?(() => void); */

  constructor(parentSignal /*: ?AbortSignal */) {
    this.controller = new AbortController();
    this.phase = 'cancellable';
    this.removeParentAbortListener = null;
    if (parentSignal) {
      const onParentAbort = () => this.abort();
      if (parentSignal.aborted) {
        onParentAbort();
      } else {
        parentSignal.addEventListener('abort', onParentAbort, { once: true });
        this.removeParentAbortListener = () =>
          parentSignal.removeEventListener('abort', onParentAbort);
      }
    }
  }

  get signal() /*: AbortSignal */ {
    return this.controller.signal;
  }

  isAborted() /*: boolean */ {
    return this.controller.signal.aborted;
  }

  isNonCancellableExecution() /*: boolean */ {
    return this.phase === 'executing';
  }

  abort() /*: boolean */ {
    if (this.phase !== 'cancellable') return false;
    if (!this.controller.signal.aborted) this.controller.abort();
    return true;
  }

  enterNonCancellableExecution() /*: boolean */ {
    if (this.phase !== 'cancellable' || this.controller.signal.aborted) {
      return false;
    }
    this.phase = 'executing';
    this._detachParent();
    return true;
  }

  complete() /*: void */ {
    this.phase = 'complete';
    this._detachParent();
  }

  _detachParent() /*: void */ {
    const remove = this.removeParentAbortListener;
    this.removeParentAbortListener = null;
    if (remove) remove();
  }
}

export class PlaymeshAiExecutionAbortRegistry {
  /*:: entries: Map<string, {|
    handle: PlaymeshAiExecutionAbortHandle,
    gameId: string,
    callId: string,
    turnId: string,
    sessionId: string,
  |}>; */

  constructor() {
    this.entries = new Map();
  }

  begin(
    gameId /*: string */,
    call /*: PlaymeshAiCall */,
    parentSignal /*: ?AbortSignal */
  ) /*: PlaymeshAiExecutionAbortHandle */ {
    const key = executionIdentityKey(
      gameId,
      call.editorSessionId,
      call.callId
    );
    const existing = this.entries.get(key);
    if (existing) {
      if (
        existing.turnId !== call.turnId ||
        existing.sessionId !== call.editorSessionId
      ) {
        throw new PlaymeshAiExecutionError('call_execution_already_active');
      }
      return existing.handle;
    }
    const handle = new PlaymeshAiExecutionAbortHandle(parentSignal);
    this.entries.set(key, {
      handle,
      gameId,
      callId: call.callId,
      turnId: call.turnId,
      sessionId: call.editorSessionId,
    });
    return handle;
  }

  finish(
    gameId /*: string */,
    sessionId /*: string */,
    callId /*: string */,
    handle /*: PlaymeshAiExecutionAbortHandle */
  ) /*: void */ {
    const key = executionIdentityKey(gameId, sessionId, callId);
    const current = this.entries.get(key);
    if (!current || current.handle !== handle) return;
    handle.complete();
    this.entries.delete(key);
  }

  abortCall(
    gameId /*: string */,
    sessionId /*: string */,
    callId /*: string */
  ) /*: boolean */ {
    if (hasPendingExecutionResult(gameId, sessionId, callId)) return false;
    const current = this.entries.get(
      executionIdentityKey(gameId, sessionId, callId)
    );
    return current ? current.handle.abort() : true;
  }

  abortTurn(
    gameId /*: string */,
    sessionId /*: string */,
    turnId /*: string */
  ) /*: number */ {
    if (
      this.hasNonCancellableExecutionForTurn(gameId, sessionId, turnId)
    ) {
      return 0;
    }
    let aborted = 0;
    this.entries.forEach(entry => {
      if (
        entry.gameId === gameId &&
        entry.sessionId === sessionId &&
        entry.turnId === turnId &&
        entry.handle.abort()
      ) {
        aborted++;
      }
    });
    return aborted;
  }

  abortSession(
    gameId /*: string */,
    sessionId /*: string */
  ) /*: number */ {
    if (this.hasNonCancellableExecution(gameId, sessionId)) return 0;
    let aborted = 0;
    this.entries.forEach(entry => {
      if (
        entry.gameId === gameId &&
        entry.sessionId === sessionId &&
        entry.handle.abort()
      ) {
        aborted++;
      }
    });
    return aborted;
  }

  abortAll() /*: number */ {
    let aborted = 0;
    this.entries.forEach(entry => {
      if (entry.handle.abort()) aborted++;
    });
    return aborted;
  }

  reconcileCalls(
    gameId /*: string */,
    sessionId /*: string */,
    calls /*: $ReadOnlyArray<PlaymeshAiCall> */
  ) /*: number */ {
    const terminalStates = new Set([
      'finished',
      'failed',
      'cancelled',
      'timed_out',
    ]);
    let aborted = 0;
    calls.forEach(call => {
      if (terminalStates.has(call.state)) {
        if (call.editorSessionId !== sessionId) return;
        sharedExecutionResults.delete(
          executionIdentityKey(gameId, sessionId, call.callId)
        );
        if (this.abortCall(gameId, sessionId, call.callId)) aborted++;
      }
    });
    return aborted;
  }

  hasNonCancellableExecution(
    gameId /*: ?string */,
    sessionId /*: ?string */
  ) /*: boolean */ {
    return [...sharedExecutionResults.values()].some(
      pending =>
        (!gameId || pending.gameId === gameId) &&
        (!sessionId || pending.sessionId === sessionId)
    ) || [...this.entries.values()].some(
      entry =>
        (!gameId || entry.gameId === gameId) &&
        (!sessionId || entry.sessionId === sessionId) &&
        entry.handle.isNonCancellableExecution()
    );
  }

  hasNonCancellableExecutionForTurn(
    gameId /*: string */,
    sessionId /*: string */,
    turnId /*: string */
  ) /*: boolean */ {
    return [...sharedExecutionResults.values()].some(
      pending =>
        pending.gameId === gameId &&
        pending.sessionId === sessionId &&
        pending.turnId === turnId
    ) || [...this.entries.values()].some(
      entry =>
        entry.gameId === gameId &&
        entry.sessionId === sessionId &&
        entry.turnId === turnId &&
        entry.handle.isNonCancellableExecution()
    );
  }

  hasNonCancellableExecutionForCall(
    gameId /*: string */,
    sessionId /*: string */,
    callId /*: string */
  ) /*: boolean */ {
    if (hasPendingExecutionResult(gameId, sessionId, callId)) return true;
    const entry = this.entries.get(
      executionIdentityKey(gameId, sessionId, callId)
    );
    return !!entry && entry.handle.isNonCancellableExecution();
  }
}

export const playmeshAiExecutionAbortRegistry /*: PlaymeshAiExecutionAbortRegistry */ = new PlaymeshAiExecutionAbortRegistry();

const cancelledExecutionOutcome = (
  call /*: PlaymeshAiCall */
) /*: PlaymeshAiExecutionOutcome */ => ({
  status: 'cancelled',
  callId: call.callId,
});

const hashBlob = async (blob /*: Blob */) /*: Promise<string> */ =>
  sha256Hex(await blob.arrayBuffer(), global.crypto);

const requireToolDefinition = (
  toolsContract /*: PlaymeshAiToolsContract */,
  call /*: PlaymeshAiCall */
) /*: PlaymeshAiToolDefinition */ => {
  const tools = toolsContract && toolsContract.tools;
  const definition =
    Array.isArray(tools) && tools.find(tool => tool.name === call.toolName);
  if (!definition) {
    throw new PlaymeshAiExecutionError('tool_contract_unavailable');
  }
  return definition;
};

export const normalizePlaymeshAiExecutionOutput = (
  result /*: ?EditorFunctionCallResult */
) /*: PlaymeshAiExecutionOutput */ => {
  const output = result && result.output;
  if (!output || typeof output !== 'object' || Array.isArray(output)) {
    throw new PlaymeshAiExecutionError('editor_function_output_invalid');
  }
  let normalized;
  try {
    normalized = JSON.parse(JSON.stringify(output));
  } catch (_) {
    throw new PlaymeshAiExecutionError('editor_function_output_invalid');
  }
  if (!normalized || typeof normalized !== 'object' || Array.isArray(normalized)) {
    throw new PlaymeshAiExecutionError('editor_function_output_invalid');
  }
  return normalized;
};

const executionFailure = (
  code /*: string */
) /*: PlaymeshAiExecutionRequest */ => ({
  success: false,
  output: {},
  errorCode: code,
  errorMessage: 'The local GDevelop AI tool failed.',
});

const readExecutionErrorCode = (
  error /*: mixed */,
  fallback /*: string */
) /*: string */ => {
  try {
    return error &&
      typeof error === 'object' &&
      typeof error.code === 'string' &&
      error.code
      ? error.code
      : fallback;
  } catch (_) {
    return fallback;
  }
};

/**
 * One in-page queue invokes the official runner against the exact gdProject
 * owned by the editor. The Gateway receives only the business result.
 */
export class PlaymeshAiExecutor {
  /*::
  client: PlaymeshAiClient;
  executeEditorFunction: $NonMaybeType<PlaymeshAiExecutorOptions['executeEditorFunction']>;
  createLocalWrappers: $NonMaybeType<PlaymeshAiExecutorOptions['createLocalWrappers']>;
  applyEventPayload: ?$NonMaybeType<PlaymeshAiExecutorOptions['applyEventPayload']>;
  readFullDocs: ?$NonMaybeType<PlaymeshAiExecutorOptions['readFullDocs']>;
  updatePlan: ?$NonMaybeType<PlaymeshAiExecutorOptions['updatePlan']>;
  onProjectModified: () => mixed;
  onFetchNewlyAddedResources: () => Promise<void>;
  onNewResourcesAdded: () => void;
  executionResults: Map<string, PlaymeshAiPendingExecutionResult>;
  operation: Promise<mixed>;
  disposed: boolean;
  */

  constructor({
    client = playmeshAiClient,
    executeEditorFunction = executePlaymeshAiEditorFunction,
    createLocalWrappers = createPlaymeshAiLocalToolWrappers,
    applyEventPayload,
    readFullDocs,
    updatePlan,
    onProjectModified = () => {},
    onFetchNewlyAddedResources = async () => {},
    onNewResourcesAdded = () => {},
  } /*: PlaymeshAiExecutorOptions */ = {}) {
    this.client = client;
    this.executeEditorFunction = executeEditorFunction;
    this.createLocalWrappers = createLocalWrappers;
    this.applyEventPayload = applyEventPayload;
    this.readFullDocs = readFullDocs;
    this.updatePlan = updatePlan;
    this.onProjectModified = onProjectModified;
    this.onFetchNewlyAddedResources = onFetchNewlyAddedResources;
    this.onNewResourcesAdded = onNewResourcesAdded;
    this.executionResults = sharedExecutionResults;
    this.operation = Promise.resolve();
    this.disposed = false;
  }

  _enqueue(
    operation /*: () => Promise<PlaymeshAiExecutionOutcome> */
  ) /*: Promise<PlaymeshAiExecutionOutcome> */ {
    if (this.disposed) {
      return Promise.reject(new PlaymeshAiExecutionError('executor_disposed'));
    }
    const next = this.operation.catch(() => {}).then(operation);
    this.operation = next;
    return next;
  }

  _assertExecutionIdentity({
    gameId,
    sessionId,
    sessionEpoch,
    isSessionEpochCurrent,
    call,
    project,
    fileMetadata,
  } /*: PlaymeshAiExecutionIdentity */) /*: void */ {
    if (!call || call.editorSessionId !== sessionId) {
      throw new PlaymeshAiExecutionError('call_session_mismatch');
    }
    if (
      !fileMetadata ||
      fileMetadata.gameId !== gameId ||
      typeof fileMetadata.fileIdentifier !== 'string' ||
      !fileMetadata.fileIdentifier
    ) {
      throw new PlaymeshAiExecutionError('project_file_identity_mismatch');
    }
    if (
      !Number.isSafeInteger(sessionEpoch) ||
      sessionEpoch < 1 ||
      typeof isSessionEpochCurrent !== 'function' ||
      isSessionEpochCurrent(sessionEpoch) !== true
    ) {
      throw new PlaymeshAiExecutionError('editor_session_epoch_mismatch');
    }
    if (!project || project.getPackageName() !== gameId) {
      throw new PlaymeshAiExecutionError('project_identity_mismatch');
    }
  }

  async _readEventPayload(
    call /*: PlaymeshAiCall */,
    definition /*: PlaymeshAiToolDefinition */
  ) /*: Promise<PlaymeshAiEventPayload> */ {
    const input = call.input;
    const eventPayload /*: mixed */ =
      input && typeof input === 'object' && !Array.isArray(input)
        ? input.eventPayload
        : null;
    if (!eventPayload) {
      throw new PlaymeshAiExecutionError('event_payload_required');
    }
    const sceneArgument = definition.executionConfig.sceneArgument;
    const sceneName =
      typeof sceneArgument === 'string'
        ? call.arguments[sceneArgument]
        : call.arguments.scene_name;
    if (typeof sceneName !== 'string') {
      throw new PlaymeshAiExecutionError('event_payload_schema_invalid');
    }
    try {
      return validatePlaymeshAiEventPayload(eventPayload, sceneName);
    } catch (error) {
      throw new PlaymeshAiExecutionError(
        error && typeof error.code === 'string'
          ? error.code
          : 'event_payload_schema_invalid'
      );
    }
  }

  async _readStagedResource(
    gameId /*: string */,
    sessionId /*: string */,
    call /*: PlaymeshAiCall */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiStagedResource> */ {
    const resourceName = call.arguments.resource_name;
    const resourceKind = call.arguments.resource_kind;
    const contentHash = call.arguments.content_hash;
    const mime = call.arguments.mime;
    const size = call.arguments.size;
    if (
      typeof resourceName !== 'string' ||
      typeof resourceKind !== 'string' ||
      typeof contentHash !== 'string' ||
      !/^[a-f0-9]{64}$/.test(contentHash) ||
      typeof mime !== 'string' ||
      !Number.isSafeInteger(size) ||
      Number(size) < 1
    ) {
      throw new PlaymeshAiExecutionError('staged_resource_reference_invalid');
    }
    const blob = await this.client.getSessionStagedResource(
      gameId,
      sessionId,
      contentHash,
      Number(size),
      signal
    );
    if (
      blob.size !== Number(size) ||
      (await hashBlob(blob)) !== contentHash
    ) {
      throw new PlaymeshAiExecutionError('staged_resource_corrupt');
    }
    return {
      resourceName,
      resourceKind,
      contentHash,
      mime,
      size: Number(size),
      blob: new Blob([blob], { type: mime }),
    };
  }

  _createWrappers(
    eventPayload /*: ?PlaymeshAiEventPayload */,
    stagedResource /*: ?PlaymeshAiStagedResource */ = null,
    toolsContract /*: ?PlaymeshAiToolsContract */ = null,
    beforeProjectMutation /*: () => void */ = () => {}
  ) /*: PlaymeshAiLocalToolWrappers */ {
    const options /*: PlaymeshAiLocalToolWrappersOptions */ = {};
    if (typeof this.applyEventPayload === 'function') {
      const applyEventPayload = this.applyEventPayload;
      options.applyEventPayload = (context /*: PlaymeshAiLocalToolContext */) => {
        if (!eventPayload) {
          throw new PlaymeshAiExecutionError('event_payload_schema_invalid');
        }
        return applyEventPayload({ ...context, eventPayload });
      };
    }
    if (typeof this.readFullDocs === 'function') {
      options.readFullDocs = this.readFullDocs;
    }
    if (typeof this.updatePlan === 'function') options.updatePlan = this.updatePlan;
    if (stagedResource) options.stagedResource = stagedResource;
    options.beforeProjectMutation = beforeProjectMutation;
    options.onFetchNewlyAddedResources = this.onFetchNewlyAddedResources;
    options.onNewResourcesAdded = this.onNewResourcesAdded;
    if (toolsContract) options.toolsContract = toolsContract;
    return this.createLocalWrappers(options);
  }

  async _reportFailure({
    gameId,
    sessionId,
    call,
    code,
    signal,
  } /*: {|
    gameId: string,
    sessionId: string,
    call: PlaymeshAiCall,
    code: string,
    signal?: ?AbortSignal,
  |} */) /*: Promise<PlaymeshAiExecutionEnvelope> */ {
    return this._finishExecution(
      gameId,
      sessionId,
      call,
      executionFailure(code),
      signal
    );
  }

  async _finishExecution(
    gameId /*: string */,
    sessionId /*: string */,
    call /*: PlaymeshAiCall */,
    execution /*: PlaymeshAiExecutionRequest */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiExecutionEnvelope> */ {
    const key = executionIdentityKey(gameId, sessionId, call.callId);
    const cached = this.executionResults.get(key);
    if (
      cached &&
      JSON.stringify(cached.execution) !== JSON.stringify(execution)
    ) {
      throw new PlaymeshAiExecutionError('call_execution_result_mismatch');
    }
    // Cache before the POST. If the response is lost, the next pump resends
    // this exact business result and never invokes the live mutation again.
    if (!cached) {
      this.executionResults.set(key, {
        gameId,
        sessionId,
        callId: call.callId,
        turnId: call.turnId,
        execution,
      });
    }
    const finished = await this.client.finishExecution(
      gameId,
      sessionId,
      call.callId,
      cached ? cached.execution : execution,
      signal
    );
    if (finished && finished.call && isPlaymeshAiTerminalCall(finished.call)) {
      this.executionResults.delete(key);
    }
    return finished;
  }

  _notifyProjectModified() /*: void */ {
    try {
      this.onProjectModified();
    } catch (error) {
      console.error('[PlayMesh AI] Could not mark the live project dirty.', error);
    }
  }

  executeCall({
    gameId,
    sessionId,
    call,
    project,
    selectedSceneName,
    fileMetadata,
    toolsContract,
    runnerOptions,
    sessionEpoch,
    isSessionEpochCurrent,
    signal,
    abortHandle,
  } /*: PlaymeshAiExecuteCallOptions */) /*: Promise<PlaymeshAiExecutionOutcome> */ {
    const key = executionIdentityKey(gameId, sessionId, call.callId);
    const activeOperation = sharedExecutionOperations.get(key);
    if (activeOperation) return activeOperation;
    const executionAbortHandle =
      abortHandle || new PlaymeshAiExecutionAbortHandle(signal);
    const ownsAbortHandle = !abortHandle;
    const executionSignal = executionAbortHandle.signal;
    const operation = this._enqueue(async () => {
      if (executionAbortHandle.isAborted()) {
        return cancelledExecutionOutcome(call);
      }
      this._assertExecutionIdentity({
        gameId,
        sessionId,
        sessionEpoch,
        isSessionEpochCurrent,
        call,
        project,
        fileMetadata,
      });
      if (call.state !== 'running') {
        throw new PlaymeshAiExecutionError('call_not_runnable');
      }
      const definition = requireToolDefinition(toolsContract, call);
      const cachedResult = this.executionResults.get(key);
      if (cachedResult) {
        const finished = await this._finishExecution(
          gameId,
          sessionId,
          call,
          cachedResult.execution,
          definition.modifiesProject ? undefined : executionSignal
        );
        return {
          status:
            cachedResult.execution.success === true ? 'finished' : 'failed',
          call: finished.call,
          callId: call.callId,
        };
      }
      const transientObjectUrls /*: Array<string> */ = [];
      let mutationStarted = false;
      let editorFunctionInvoked = false;
      let projectModificationNotified = false;
      const notifyProjectModifiedAfterExecution = () => {
        if (
          !mutationStarted ||
          !editorFunctionInvoked ||
          projectModificationNotified
        ) {
          return;
        }
        projectModificationNotified = true;
        this._notifyProjectModified();
      };
      try {
        let eventPayload = null;
        let stagedResource = null;
        try {
          eventPayload =
            definition.executionKind === 'event_payload'
              ? await this._readEventPayload(call, definition)
              : null;
          stagedResource =
            definition.executionKind === 'agent_resource_cas'
              ? await this._readStagedResource(
                  gameId,
                  sessionId,
                  call,
                  executionSignal
                )
              : null;
        } catch (error) {
          if (executionAbortHandle.isAborted()) {
            return cancelledExecutionOutcome(call);
          }
          const code = error.code || 'tool_input_unavailable';
          const finished = await this._reportFailure({
            gameId,
            sessionId,
            call,
            code,
            signal: executionSignal,
          });
          return { status: 'failed', call: finished.call, callId: call.callId };
        }
        if (executionAbortHandle.isAborted()) {
          return cancelledExecutionOutcome(call);
        }
        const defersProjectMutation =
          definition.modifiesProject &&
          DEFERRED_PROJECT_MUTATION_TOOLS.has(definition.name);
        if (
          definition.modifiesProject &&
          !defersProjectMutation &&
          !executionAbortHandle.enterNonCancellableExecution()
        ) {
          return cancelledExecutionOutcome(call);
        }
        mutationStarted = definition.modifiesProject && !defersProjectMutation;
        const beforeProjectMutation = () => {
          if (mutationStarted) return;
          if (executionAbortHandle.isAborted()) {
            throw new PlaymeshAiExecutionError('execution_aborted');
          }
          this._assertExecutionIdentity({
            gameId,
            sessionId,
            sessionEpoch,
            isSessionEpochCurrent,
            call,
            project,
            fileMetadata,
          });
          if (!executionAbortHandle.enterNonCancellableExecution()) {
            throw new PlaymeshAiExecutionError('execution_aborted');
          }
          mutationStarted = true;
        };
        let executed;
        try {
          const playmeshWrappers = this._createWrappers(
            eventPayload,
            stagedResource,
            toolsContract,
            beforeProjectMutation
          );
          editorFunctionInvoked = true;
          executed = await this.executeEditorFunction({
            call,
            project,
            selectedSceneName,
            toolsContract,
            playmeshWrappers,
            runnerOptions,
          });
          // Mark the editor state before inspecting or reporting the result.
          // A lost finish response must never delay or repeat this signal.
          notifyProjectModifiedAfterExecution();
        } catch (error) {
          notifyProjectModifiedAfterExecution();
          if (!mutationStarted && executionAbortHandle.isAborted()) {
            return cancelledExecutionOutcome(call);
          }
          const code = readExecutionErrorCode(
            error,
            'editor_function_failed'
          );
          const finished = await this._reportFailure({
            gameId,
            sessionId,
            call,
            code,
            signal: definition.modifiesProject ? undefined : executionSignal,
          });
          return { status: 'failed', call: finished.call, callId: call.callId };
        }
        let execution /*: PlaymeshAiExecutionRequest */;
        try {
          if (Array.isArray(executed.transientObjectUrls)) {
            transientObjectUrls.push(...executed.transientObjectUrls);
          }
          if (!definition.modifiesProject && executionAbortHandle.isAborted()) {
            return cancelledExecutionOutcome(call);
          }
          const createdProject = executed.createdProject;
          if (createdProject && createdProject !== project) {
            try {
              createdProject.delete();
            } catch (error) {
              console.error(
                '[PlayMesh AI] Could not dispose an unsupported replacement project.',
                error
              );
            }
            execution = executionFailure(
              'live_project_replacement_not_supported'
            );
          } else {
            const result = executed.result;
            if (
              !result ||
              result.status !== 'finished' ||
              result.success !== true
            ) {
              execution = executionFailure(
                result && result.status === 'aborted'
                  ? 'editor_function_aborted'
                  : 'editor_function_failed'
              );
            } else {
              execution = {
                success: true,
                output: normalizePlaymeshAiExecutionOutput(result),
              };
            }
          }
        } catch (error) {
          // The live EditorFunction has already run. Freeze every result
          // inspection/normalization failure before any network request so a
          // later pump can only resend this failure and never mutate again.
          execution = executionFailure(
            readExecutionErrorCode(error, 'editor_function_output_invalid')
          );
        }
        const finished = await this._finishExecution(
          gameId,
          sessionId,
          call,
          execution,
          definition.modifiesProject ? undefined : executionSignal
        );
        return {
          status: execution.success === true ? 'finished' : 'failed',
          call: finished.call,
          callId: call.callId,
        };
      } finally {
        transientObjectUrls.forEach(objectUrl => {
          try {
            URL.revokeObjectURL(objectUrl);
          } catch (_) {
            // Result delivery and retry identity must not depend on cleanup.
          }
        });
      }
    });
    const guardedOperation = operation.catch(error => {
      if (
        !executionAbortHandle.isNonCancellableExecution() &&
        executionAbortHandle.isAborted()
      ) {
        return cancelledExecutionOutcome(call);
      }
      throw error;
    });
    const resultOperation = ownsAbortHandle
      ? guardedOperation.finally(() => executionAbortHandle.complete())
      : guardedOperation;
    sharedExecutionOperations.set(key, resultOperation);
    return resultOperation.finally(() => {
      if (sharedExecutionOperations.get(key) === resultOperation) {
        sharedExecutionOperations.delete(key);
      }
    });
  }

  async leaseNext({
    gameId,
    sessionId,
    signal,
  } /*: {|
    gameId: string,
    sessionId: string,
    signal?: ?AbortSignal,
  |} */) /*: Promise<?PlaymeshAiCall> */ {
    return this.client.leaseNextCall(gameId, sessionId, signal);
  }

  dispose() /*: void */ {
    this.disposed = true;
  }
}

export default PlaymeshAiExecutor;
