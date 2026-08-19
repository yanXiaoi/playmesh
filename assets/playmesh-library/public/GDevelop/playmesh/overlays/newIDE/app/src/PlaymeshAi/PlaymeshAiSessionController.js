// @flow

import { playmeshAiClient } from './PlaymeshAiClient';
import { buildPlaymeshAiProjectContext } from './PlaymeshAiProjectContext';
import {
  completePlaymeshAiFailureDiagnostics,
  createPlaymeshAiLocalRequestId,
} from './PlaymeshAiDiagnostics';

/*::
import type {
  PlaymeshAiClient,
  PlaymeshAiToolsEnvelope,
} from './PlaymeshAiClient';
import type {
  PlaymeshAiApprovalMode,
  PlaymeshAiObject,
  PlaymeshAiSession,
} from './PlaymeshAiProtocol';
import type { FileMetadata } from '../ProjectsStorage';

type PlaymeshAiMode = 'chat' | 'agent';
export type PlaymeshAiSessionState = {|
  session: ?PlaymeshAiSession,
  tools: ?PlaymeshAiToolsEnvelope,
  mode: ?PlaymeshAiMode,
  gameId: ?string,
  sessionEpoch: number,
|};
type PlaymeshAiPreparedSession = {|
  gameId: string,
  tools: PlaymeshAiToolsEnvelope,
  context: PlaymeshAiObject,
|};
type PlaymeshAiBuildProjectContextOptions = {|
  project: gdProject,
  selectedSceneName: ?string,
  capabilities: mixed,
|};
type PlaymeshAiBuildProjectContext = (
  options: PlaymeshAiBuildProjectContextOptions
) => PlaymeshAiObject;
type PlaymeshAiSessionControllerOptions = {|
  client?: PlaymeshAiClient,
  buildProjectContext?: PlaymeshAiBuildProjectContext,
|};
type PlaymeshAiSessionStateListener = (
  state: PlaymeshAiSessionState
) => mixed;
type PlaymeshAiProjectIdentity = {|
  gameId: string,
  fileIdentifier: string,
|};
type PlaymeshAiApprovalModeOperationSnapshot = {|
  sessionEpoch: number,
  gameId: string,
  editorSessionId: string,
|};
type PlaymeshAiPrepareOptions = {|
  project: gdProject,
  fileMetadata: FileMetadata,
  selectedSceneName: ?string,
  signal?: ?AbortSignal,
|};
type PlaymeshAiOpenOptions = {|
  mode: PlaymeshAiMode,
  project: gdProject,
  fileMetadata: FileMetadata,
  locale: string,
  selectedSceneName?: ?string,
  signal?: ?AbortSignal,
|};
type PlaymeshAiRefreshOptions = {|
  project: gdProject,
  fileMetadata: FileMetadata,
  locale: string,
  selectedSceneName?: ?string,
  signal?: ?AbortSignal,
|};
*/

const VALID_GAME_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export class PlaymeshAiSessionControllerError extends Error {
  /*:: code: string; status: number; requestId: ?string; operation: ?string; */

  constructor(
    code /*: string */,
    {
      status = 0,
      requestId = null,
      operation = null,
    } /*: {|
      status?: number,
      requestId?: ?string,
      operation?: ?string,
    |} */ = {}
  ) {
    super('The local GDevelop AI session is unavailable.');
    this.name = 'PlaymeshAiSessionControllerError';
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.operation = operation;
  }
}

const withOpenFailureDiagnostics = (
  error /*: mixed */,
  requestId /*: string */
) /*: Error */ =>
  completePlaymeshAiFailureDiagnostics(error, {
    code: 'ai_session_open_local_failed',
    operation: 'gdevelop.ai.session.open',
    requestId,
  });

const requireProjectIdentity = ({
  project,
  fileMetadata,
} /*: {|
  project: gdProject,
  fileMetadata: FileMetadata,
|} */) /*: PlaymeshAiProjectIdentity */ => {
  const gameId = fileMetadata && fileMetadata.gameId;
  const fileIdentifier = fileMetadata && fileMetadata.fileIdentifier;
  if (
    !project ||
    typeof gameId !== 'string' ||
    !VALID_GAME_ID.test(gameId || '') ||
    typeof fileIdentifier !== 'string' ||
    !fileIdentifier
  ) {
    throw new PlaymeshAiSessionControllerError('project_identity_missing');
  }
  if (project.getPackageName() !== gameId) {
    throw new PlaymeshAiSessionControllerError('project_identity_mismatch');
  }
  return { gameId, fileIdentifier };
};

const assertMode = (mode /*: mixed */) /*: void */ => {
  if (mode !== 'chat' && mode !== 'agent') {
    throw new PlaymeshAiSessionControllerError('invalid_ai_mode');
  }
};

const isApprovalModeOperationTerminationError = (
  error /*: mixed */
) /*: boolean */ =>
  error instanceof PlaymeshAiSessionControllerError &&
  (error.code === 'approval_mode_operation_stale' ||
    error.code === 'approval_mode_operation_aborted');

const buildPlaymeshAiSessionProjectContext = (
  options /*: PlaymeshAiBuildProjectContextOptions */
) /*: PlaymeshAiObject */ =>
  buildPlaymeshAiProjectContext({
    project: options.project,
    selectedSceneName: options.selectedSceneName,
    capabilities: options.capabilities,
  });

/**
 * A session carries the read-only tool contract and project context used for
 * prompting. It never participates in project persistence or versioning.
 */
export class PlaymeshAiSessionController {
  /*::
  client: PlaymeshAiClient;
  buildProjectContext: PlaymeshAiBuildProjectContext;
  session: ?PlaymeshAiSession;
  tools: ?PlaymeshAiToolsEnvelope;
  mode: ?PlaymeshAiMode;
  gameId: ?string;
  sessionEpoch: number;
  operation: Promise<mixed>;
  disposed: boolean;
  listeners: Set<PlaymeshAiSessionStateListener>;
  */

  constructor({
    client = playmeshAiClient,
    buildProjectContext = buildPlaymeshAiSessionProjectContext,
  } /*: PlaymeshAiSessionControllerOptions */ = {}) {
    this.client = client;
    this.buildProjectContext = buildProjectContext;
    this.session = null;
    this.tools = null;
    this.mode = null;
    this.gameId = null;
    this.sessionEpoch = 0;
    this.operation = Promise.resolve();
    this.disposed = false;
    this.listeners = new Set();
  }

  subscribe(
    listener /*: PlaymeshAiSessionStateListener */
  ) /*: () => void */ {
    if (typeof listener !== 'function') {
      throw new PlaymeshAiSessionControllerError('invalid_session_listener');
    }
    this.listeners.add(listener);
    listener(this.getState());
    return () => {
      this.listeners.delete(listener);
    };
  }

  _notify() /*: void */ {
    const state = this.getState();
    this.listeners.forEach(listener => listener(state));
  }

  getState() /*: PlaymeshAiSessionState */ {
    return {
      session: this.session,
      tools: this.tools,
      mode: this.mode,
      gameId: this.gameId,
      sessionEpoch: this.sessionEpoch,
    };
  }

  isSessionEpochCurrent(epoch /*: mixed */) /*: boolean */ {
    return (
      !this.disposed &&
      !!this.session &&
      Number.isSafeInteger(epoch) &&
      epoch === this.sessionEpoch
    );
  }

  _assertApprovalModeOperationCurrent(
    snapshot /*: PlaymeshAiApprovalModeOperationSnapshot */,
    signal /*: ?AbortSignal */
  ) /*: void */ {
    if (
      this.disposed ||
      !this.session ||
      this.sessionEpoch !== snapshot.sessionEpoch ||
      this.gameId !== snapshot.gameId ||
      this.session.editorSessionId !== snapshot.editorSessionId
    ) {
      throw new PlaymeshAiSessionControllerError(
        'approval_mode_operation_stale'
      );
    }
    if (signal && signal.aborted) {
      throw new PlaymeshAiSessionControllerError(
        'approval_mode_operation_aborted'
      );
    }
  }

  _enqueue(
    operation /*: () => Promise<PlaymeshAiSessionState> */
  ) /*: Promise<PlaymeshAiSessionState> */ {
    if (this.disposed) {
      return Promise.reject(
        new PlaymeshAiSessionControllerError('session_controller_disposed')
      );
    }
    const next = this.operation.catch(() => {}).then(operation);
    this.operation = next;
    return next;
  }

  async _prepare({
    project,
    fileMetadata,
    selectedSceneName,
    signal,
  } /*: PlaymeshAiPrepareOptions */) /*: Promise<PlaymeshAiPreparedSession> */ {
    const { gameId } = requireProjectIdentity({ project, fileMetadata });
    const tools = await this.client.getTools(signal);
    const context = this.buildProjectContext({
      project,
      selectedSceneName,
      capabilities: tools.capabilitiesReference,
    });
    return { gameId, tools, context };
  }

  async _openPrepared({
    mode,
    locale,
    prepared,
    signal,
  } /*: {|
    mode: PlaymeshAiMode,
    locale: string,
    prepared: PlaymeshAiPreparedSession,
    signal?: ?AbortSignal,
  |} */) /*: Promise<PlaymeshAiSessionState> */ {
    const opened = await this.client.openSession(
      prepared.gameId,
      { mode, locale, context: prepared.context },
      signal
    );
    const sessionTools = await this.client.getSessionTools(
      prepared.gameId,
      opened.session.editorSessionId,
      signal
    );
    this.session = opened.session;
    this.tools = sessionTools;
    this.mode = mode;
    this.gameId = prepared.gameId;
    this.sessionEpoch++;
    const state = this.getState();
    this._notify();
    return state;
  }

  open({
    mode,
    project,
    fileMetadata,
    locale,
    selectedSceneName = null,
    signal,
  } /*: PlaymeshAiOpenOptions */) /*: Promise<PlaymeshAiSessionState> */ {
    const requestId = createPlaymeshAiLocalRequestId();
    try {
      assertMode(mode);
    } catch (error) {
      return Promise.reject(withOpenFailureDiagnostics(error, requestId));
    }
    return this._enqueue(async () => {
      try {
        const { gameId } = requireProjectIdentity({ project, fileMetadata });
        if (this.session && this.gameId === gameId && this.mode === mode) {
          return this.getState();
        }
        if (this.session) {
          throw new PlaymeshAiSessionControllerError('session_already_open');
        }
        const prepared = await this._prepare({
          project,
          fileMetadata,
          selectedSceneName,
          signal,
        });
        return this._openPrepared({ mode, locale, prepared, signal });
      } catch (error) {
        throw withOpenFailureDiagnostics(error, requestId);
      }
    });
  }

  refresh({
    project,
    fileMetadata,
    locale,
    selectedSceneName = null,
    signal,
  } /*: PlaymeshAiRefreshOptions */) /*: Promise<PlaymeshAiSessionState> */ {
    return this._enqueue(async () => {
      const session = this.session;
      const gameId = this.gameId;
      if (!session || !this.mode || !gameId) {
        throw new PlaymeshAiSessionControllerError('session_not_open');
      }
      const identity = requireProjectIdentity({ project, fileMetadata });
      if (identity.gameId !== gameId) {
        throw new PlaymeshAiSessionControllerError('project_identity_mismatch');
      }
      const prepared = await this._prepare({
        project,
        fileMetadata,
        selectedSceneName,
        signal,
      });
      const updated = await this.client.updateSession(
        gameId,
        session.editorSessionId,
        { locale, context: prepared.context },
        signal
      );
      this.session = updated;
      const state = this.getState();
      this._notify();
      return state;
    });
  }

  updateApprovalMode(
    approvalMode /*: PlaymeshAiApprovalMode */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiSessionState> */ {
    return this._enqueue(async () => {
      const session = this.session;
      const gameId = this.gameId;
      if (!session || !gameId) {
        throw new PlaymeshAiSessionControllerError('session_not_open');
      }
      const operationSnapshot = {
        sessionEpoch: this.sessionEpoch,
        gameId,
        editorSessionId: session.editorSessionId,
      };

      try {
        const updated = await this.client.updateApprovalMode(
          gameId,
          session.editorSessionId,
          approvalMode,
          signal
        );
        this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
        this.session = updated;
        const state = this.getState();
        this._notify();
        if (updated.approvalMode !== approvalMode) {
          throw new PlaymeshAiSessionControllerError(
            'approval_mode_update_not_applied'
          );
        }
        return state;
      } catch (updateError) {
        if (
          (updateError instanceof PlaymeshAiSessionControllerError &&
            updateError.code === 'approval_mode_update_not_applied') ||
          isApprovalModeOperationTerminationError(updateError)
        ) {
          throw updateError;
        }

        this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
        try {
          const reconciled = await this.client.getSession(
            gameId,
            session.editorSessionId,
            signal
          );
          this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
          this.session = reconciled;
          const state = this.getState();
          this._notify();
          if (reconciled.approvalMode === approvalMode) return state;
          throw new PlaymeshAiSessionControllerError(
            'approval_mode_update_not_applied'
          );
        } catch (reconciliationError) {
          if (
            (reconciliationError instanceof
              PlaymeshAiSessionControllerError &&
              reconciliationError.code ===
                'approval_mode_update_not_applied') ||
            isApprovalModeOperationTerminationError(reconciliationError)
          ) {
            throw reconciliationError;
          }
          this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
          throw new PlaymeshAiSessionControllerError(
            'approval_mode_state_uncertain'
          );
        }
      }
    });
  }

  reconcileApprovalMode(
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiSessionState> */ {
    return this._enqueue(async () => {
      const session = this.session;
      const gameId = this.gameId;
      if (!session || !gameId) {
        throw new PlaymeshAiSessionControllerError('session_not_open');
      }
      const operationSnapshot = {
        sessionEpoch: this.sessionEpoch,
        gameId,
        editorSessionId: session.editorSessionId,
      };
      try {
        const reconciled = await this.client.getSession(
          gameId,
          session.editorSessionId,
          signal
        );
        this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
        this.session = reconciled;
        const state = this.getState();
        this._notify();
        return state;
      } catch (error) {
        if (isApprovalModeOperationTerminationError(error)) throw error;
        this._assertApprovalModeOperationCurrent(operationSnapshot, signal);
        throw error;
      }
    });
  }

  close(signal /*: ?AbortSignal */) /*: Promise<PlaymeshAiSessionState> */ {
    return this._enqueue(async () => {
      if (!this.session || !this.gameId) return this.getState();
      await this.client.closeSession(
        this.gameId,
        this.session.editorSessionId,
        signal
      );
      return this.abandon();
    });
  }

  abandon() /*: PlaymeshAiSessionState */ {
    this.sessionEpoch++;
    this.session = null;
    this.tools = null;
    this.mode = null;
    this.gameId = null;
    const state = this.getState();
    this._notify();
    return state;
  }

  dispose() /*: void */ {
    this.sessionEpoch++;
    this.disposed = true;
    this.listeners.clear();
  }
}

export const playmeshAiSessionController /*: PlaymeshAiSessionController */ = new PlaymeshAiSessionController();

export default PlaymeshAiSessionController;
