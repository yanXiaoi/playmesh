// @flow

import type { FileMetadata } from '../ProjectsStorage';
import type { PreparedPlaymeshProjectPersistence } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
import {
  PlaymeshProjectRekeyCoordinatorError,
  recoverPlaymeshProjectRekeyLocalIdentity,
  rekeyPlaymeshProjectLocalIdentity,
} from './PlaymeshProjectRekeyCoordinator';
import type {
  PlaymeshProjectRekeyCoordinatorResult,
  PlaymeshProjectRekeyDependencies,
  PlaymeshProjectRekeyStage,
} from './PlaymeshProjectRekeyCoordinator';
import { readPlaymeshProjectRekeyBrowserState } from './PlaymeshProjectRekeyJournal';

/*::
export type PlaymeshProjectRekeyControllerStatus =
  | 'idle'
  | 'capturing_source'
  | 'applying_properties'
  | PlaymeshProjectRekeyStage
  | 'succeeded'
  | 'rolled_back'
  | 'failed'
  | 'blocked';
export type PlaymeshProjectRekeyControllerState = {|
  status: PlaymeshProjectRekeyControllerStatus,
  busy: boolean,
  canClose: boolean,
  errorCode: ?string,
  errorMessage: ?string,
  rollbackCompleted: boolean,
  result: ?PlaymeshProjectRekeyCoordinatorResult,
  revision: number,
|};
export type PlaymeshProjectRekeyExecutionOptions = {|
  oldGameId: string,
  newGameId: string,
  fileMetadata: FileMetadata,
  prepareCurrentProject: FileMetadata => Promise<PreparedPlaymeshProjectPersistence>,
  applyTargetProperties: () => Promise<void> | void,
  restoreSourceProperties: () => Promise<void> | void,
  signal?: ?AbortSignal,
  dependencies?: Partial<PlaymeshProjectRekeyDependencies>,
|};
export type PlaymeshProjectRekeyRecoveryOptions = {|
  fileMetadata: FileMetadata,
  reload: () => void,
  signal?: ?AbortSignal,
  dependencies?: Partial<PlaymeshProjectRekeyDependencies>,
|};
*/

export class PlaymeshProjectRekeyControllerError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshProjectRekeyControllerError';
    this.code = code;
  }
}

const initialState = () /*: PlaymeshProjectRekeyControllerState */ => ({
  status: 'idle',
  busy: false,
  canClose: true,
  errorCode: null,
  errorMessage: null,
  rollbackCompleted: false,
  result: null,
  revision: 0,
});

export class PlaymeshProjectRekeyController {
  /*::
  _state: PlaymeshProjectRekeyControllerState;
  _listeners: Set<PlaymeshProjectRekeyControllerState => void>;
  */

  constructor() {
    this._state = initialState();
    this._listeners = new Set();
  }

  getState() /*: PlaymeshProjectRekeyControllerState */ {
    return this._state;
  }

  subscribe(
    listener /*: PlaymeshProjectRekeyControllerState => void */
  ) /*: () => void */ {
    this._listeners.add(listener);
    listener(this._state);
    return () => {
      this._listeners.delete(listener);
    };
  }

  reset() /*: void */ {
    if (this._state.busy || !this._state.canClose) {
      throw new PlaymeshProjectRekeyControllerError(
        'rekey_state_locked',
        '项目身份迁移仍在恢复，不能重置状态。'
      );
    }
    this._replace(initialState());
  }

  async execute(
    options /*: PlaymeshProjectRekeyExecutionOptions */
  ) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ {
    this._assertAvailable();
    let liveTargetApplied = false;
    this._setStatus('capturing_source', { busy: true, canClose: false });
    try {
      const source = await options.prepareCurrentProject(options.fileMetadata);
      this._setStatus('applying_properties');
      await options.applyTargetProperties();
      liveTargetApplied = true;
      const target = await options.prepareCurrentProject({
        ...options.fileMetadata,
        gameId: options.newGameId,
      });
      const dependencies = this._withProgress(options.dependencies);
      const result = await rekeyPlaymeshProjectLocalIdentity({
        oldGameId: options.oldGameId,
        newGameId: options.newGameId,
        source,
        target,
        signal: options.signal,
        dependencies,
      });
      if (result.outcome === 'committed') {
        this._setStatus('succeeded', {
          busy: false,
          canClose: true,
          result,
        });
        return result;
      }
      await options.restoreSourceProperties();
      this._setStatus('rolled_back', {
        busy: false,
        canClose: true,
        rollbackCompleted: true,
        result,
        errorCode: 'rekey_rolled_back',
      });
      return result;
    } catch (error) {
      const coordinatorError =
        error instanceof PlaymeshProjectRekeyCoordinatorError ? error : null;
      if (coordinatorError && coordinatorError.blocked) {
        this._setStatus('blocked', {
          busy: false,
          canClose: false,
          errorCode: coordinatorError.code,
          errorMessage: coordinatorError.message,
          rollbackCompleted: false,
        });
        throw error;
      }
      if (liveTargetApplied) {
        try {
          await options.restoreSourceProperties();
        } catch (restoreError) {
          this._setStatus('blocked', {
            busy: false,
            canClose: false,
            errorCode: 'live_source_restore_failed',
            errorMessage:
              restoreError instanceof Error
                ? restoreError.message
                : '无法恢复迁移前的编辑器项目。',
            rollbackCompleted: false,
          });
          throw restoreError;
        }
      }
      this._setStatus('failed', {
        busy: false,
        canClose: true,
        errorCode:
          coordinatorError && coordinatorError.code
            ? coordinatorError.code
            : 'rekey_failed',
        errorMessage: error instanceof Error ? error.message : null,
        rollbackCompleted:
          !coordinatorError || coordinatorError.rollbackCompleted,
      });
      throw error;
    }
  }

  async recover(
    options /*: PlaymeshProjectRekeyRecoveryOptions */
  ) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ {
    this._assertAvailable(true);
    this._setStatus('recovering', { busy: true, canClose: false });
    try {
      const result = await recoverPlaymeshProjectRekeyLocalIdentity({
        fileMetadata: options.fileMetadata,
        signal: options.signal,
        dependencies: this._withProgress(options.dependencies),
      });
      if (result.outcome === 'idle') {
        this._replace(initialState());
        return result;
      }
      this._setStatus(
        result.outcome === 'committed' ? 'succeeded' : 'rolled_back',
        {
          busy: false,
          canClose: true,
          rollbackCompleted: result.outcome === 'rolled_back',
          result,
        }
      );
      options.reload();
      return result;
    } catch (error) {
      const coordinatorError =
        error instanceof PlaymeshProjectRekeyCoordinatorError ? error : null;
      this._setStatus(
        coordinatorError && coordinatorError.blocked ? 'blocked' : 'failed',
        {
          busy: false,
          canClose: !(coordinatorError && coordinatorError.blocked),
          errorCode:
            coordinatorError && coordinatorError.code
              ? coordinatorError.code
              : 'rekey_recovery_failed',
          errorMessage: error instanceof Error ? error.message : null,
          rollbackCompleted:
            !!coordinatorError && coordinatorError.rollbackCompleted,
        }
      );
      throw error;
    }
  }

  async recoverIfPending(
    options /*: PlaymeshProjectRekeyRecoveryOptions */
  ) /*: Promise<?PlaymeshProjectRekeyCoordinatorResult> */ {
    const browserState = await readPlaymeshProjectRekeyBrowserState(
      options.fileMetadata.fileIdentifier
    );
    if (!browserState.journal) return null;
    return this.recover(options);
  }

  _withProgress(
    dependencies /*: ?Partial<PlaymeshProjectRekeyDependencies> */
  ) /*: Partial<PlaymeshProjectRekeyDependencies> */ {
    const externalNotify = dependencies && dependencies.notify;
    return {
      ...(dependencies || {}),
      notify: stage => {
        if (externalNotify) externalNotify(stage);
        this._setStatus(stage, { busy: true, canClose: false });
      },
    };
  }

  _assertAvailable(allowBlocked /*: boolean */ = false) /*: void */ {
    if (
      this._state.busy ||
      (!allowBlocked && !this._state.canClose) ||
      (allowBlocked &&
        !this._state.canClose &&
        this._state.status !== 'blocked')
    ) {
      throw new PlaymeshProjectRekeyControllerError(
        'rekey_already_running',
        '项目身份迁移或恢复已在进行。'
      );
    }
  }

  _setStatus(
    status /*: PlaymeshProjectRekeyControllerStatus */,
    patch /*: Partial<PlaymeshProjectRekeyControllerState> */ = {}
  ) /*: void */ {
    this._replace({
      ...this._state,
      status,
      ...patch,
      revision: this._state.revision + 1,
    });
  }

  _replace(state /*: PlaymeshProjectRekeyControllerState */) /*: void */ {
    this._state = state;
    this._listeners.forEach(listener => listener(state));
  }
}
