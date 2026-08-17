// @flow

import {
  PlaymeshProjectConfigClientError,
  PlaymeshProjectConfigConflictError,
} from './PlaymeshProjectConfigClient';
import {
  PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS,
  normalizePlaymeshProjectTags,
} from './PlaymeshProjectConfigProtocol';

/*::
import type { PlaymeshProjectConfigClient } from './PlaymeshProjectConfigClient';
import type {
  PlaymeshProjectConfig,
  PlaymeshProjectConfigReadResponse,
  PlaymeshProjectGameType,
} from './PlaymeshProjectConfigProtocol';

export type PlaymeshProjectConfigControllerStatus =
  | 'loading'
  | 'ready'
  | 'missing'
  | 'invalid'
  | 'unavailable'
  | 'saving'
  | 'save_failed'
  | 'conflict';
export type PlaymeshProjectConfigBaselineStatus =
  | 'ready'
  | 'missing'
  | 'invalid'
  | 'unavailable';
export type PlaymeshProjectConfigControllerState = {|
  status: PlaymeshProjectConfigControllerStatus,
  gameId: ?string,
  draftGameType: PlaymeshProjectGameType,
  draftMinPlayers: number,
  draftMaxPlayers: number,
  draftTags: Array<string>,
  savedGameType: ?PlaymeshProjectGameType,
  revision: number,
  currentRevision: ?number,
  isExplicitlySaved: boolean,
  requiresExplicitSave: boolean,
  fieldDisabled: boolean,
  errorCode: ?string,
  errorStatus: number,
  errorRequestId: ?string,
  errorMessage: ?string,
  baselineStatus: ?PlaymeshProjectConfigBaselineStatus,
  config: ?PlaymeshProjectConfig,
|};
export type PlaymeshProjectConfigSaveOutcome =
  | {| ok: true, kind: 'saved', config: PlaymeshProjectConfig |}
  | {| ok: true, kind: 'unchanged', config: PlaymeshProjectConfig |}
  | {| ok: false, reason: 'official_apply_failed' |}
  | {| ok: false, reason: 'config_not_savable' |}
  | {| ok: false, reason: 'conflict', currentRevision: number |}
  | {|
      ok: false,
      reason: 'save_failed',
      code: string,
      status: number,
      requestId: ?string,
    |}
  | {| ok: false, reason: 'superseded' |};
type StateListener = PlaymeshProjectConfigControllerState => void;
type Operation = {|
  epoch: number,
  controller: AbortController,
  cleanup: () => void,
|};
*/

const initialState = () /*: PlaymeshProjectConfigControllerState */ => ({
  status: 'unavailable',
  gameId: null,
  draftGameType: 'single',
  draftMinPlayers: 1,
  draftMaxPlayers: 1,
  draftTags: [],
  savedGameType: null,
  revision: 0,
  currentRevision: null,
  isExplicitlySaved: false,
  requiresExplicitSave: false,
  fieldDisabled: true,
  errorCode: null,
  errorStatus: 0,
  errorRequestId: null,
  errorMessage: null,
  baselineStatus: 'unavailable',
  config: null,
});

const errorCode = (error /*: mixed */) /*: string */ =>
  error instanceof PlaymeshProjectConfigClientError
    ? error.code
    : error &&
      typeof error === 'object' &&
      typeof Reflect.get(error, 'code') === 'string'
    ? String(Reflect.get(error, 'code'))
    : 'config_unavailable';

const errorDetails = (
  error /*: mixed */
) /*: {| code: string, status: number, requestId: ?string, message: ?string |} */ => ({
  code: errorCode(error),
  status:
    error instanceof PlaymeshProjectConfigClientError ? error.status : 0,
  requestId:
    error instanceof PlaymeshProjectConfigClientError
      ? error.requestId
      : null,
  message: error instanceof Error ? error.message : null,
});

const sameTags = (
  left /*: $ReadOnlyArray<string> */,
  right /*: $ReadOnlyArray<string> */
) /*: boolean */ =>
  left.length === right.length && left.every((tag, index) => tag === right[index]);

const draftRequiresSave = (
  state /*: PlaymeshProjectConfigControllerState */,
  draft /*: {|
    gameType: PlaymeshProjectGameType,
    minPlayers: number,
    maxPlayers: number,
    tags: Array<string>,
  |} */
) /*: boolean */ => {
  const config = state.config;
  return (
    !config ||
    config.gameType !== draft.gameType ||
    config.minPlayers !== draft.minPlayers ||
    config.maxPlayers !== draft.maxPlayers ||
    !sameTags(config.tags, draft.tags)
  );
};

export class PlaymeshProjectConfigController {
  /*::
  _client: PlaymeshProjectConfigClient;
  _state: PlaymeshProjectConfigControllerState;
  _listeners: Set<StateListener>;
  _epoch: number;
  _activeController: ?AbortController;
  _disposed: boolean;
  */

  constructor({ client } /*: {| client: PlaymeshProjectConfigClient |} */) {
    this._client = client;
    this._state = initialState();
    this._listeners = new Set();
    this._epoch = 0;
    this._activeController = null;
    this._disposed = false;
  }

  getState() /*: PlaymeshProjectConfigControllerState */ {
    return this._state;
  }

  subscribe(listener /*: StateListener */) /*: () => void */ {
    this._listeners.add(listener);
    listener(this._state);
    return () => {
      this._listeners.delete(listener);
    };
  }

  _setState(state /*: PlaymeshProjectConfigControllerState */) /*: void */ {
    if (this._disposed) return;
    this._state = state;
    this._listeners.forEach(listener => listener(state));
  }

  _startOperation(signal /*: ?AbortSignal */) /*: Operation */ {
    if (this._disposed) {
      throw new PlaymeshProjectConfigClientError({
        code: 'controller_disposed',
      });
    }
    if (this._activeController) this._activeController.abort();
    const controller = new AbortController();
    this._activeController = controller;
    const epoch = ++this._epoch;
    const abortFromExternal = () => controller.abort();
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener('abort', abortFromExternal, { once: true });
    }
    return {
      epoch,
      controller,
      cleanup: () => {
        if (signal) signal.removeEventListener('abort', abortFromExternal);
        if (this._activeController === controller) {
          this._activeController = null;
        }
      },
    };
  }

  _isCurrent(operation /*: Operation */, gameId /*: string */) /*: boolean */ {
    return (
      !this._disposed &&
      operation.epoch === this._epoch &&
      this._state.gameId === gameId
    );
  }

  _stateFromResponse(
    gameId /*: string */,
    response /*: PlaymeshProjectConfigReadResponse */
  ) /*: PlaymeshProjectConfigControllerState */ {
    if (response.status === 'ready') {
      return {
        status: 'ready',
        gameId,
        draftGameType: response.config.gameType,
        draftMinPlayers: response.config.minPlayers,
        draftMaxPlayers: response.config.maxPlayers,
        draftTags: response.config.tags,
        savedGameType: response.config.gameType,
        revision: response.config.revision,
        currentRevision: response.config.revision,
        isExplicitlySaved: true,
        requiresExplicitSave: false,
        fieldDisabled: false,
        errorCode: null,
        errorStatus: 0,
        errorRequestId: null,
        errorMessage: null,
        baselineStatus: 'ready',
        config: response.config,
      };
    }
    if (response.status === 'missing') {
      return {
        status: 'missing',
        gameId,
        draftGameType: 'single',
        draftMinPlayers: 1,
        draftMaxPlayers: 1,
        draftTags: [],
        savedGameType: null,
        revision: 0,
        currentRevision: 0,
        isExplicitlySaved: false,
        requiresExplicitSave: true,
        fieldDisabled: false,
        errorCode: null,
        errorStatus: 0,
        errorRequestId: null,
        errorMessage: null,
        baselineStatus: 'missing',
        config: null,
      };
    }
    return {
      status: 'invalid',
      gameId,
      draftGameType: 'single',
      draftMinPlayers: 1,
      draftMaxPlayers: 1,
      draftTags: [],
      savedGameType: null,
      revision: 0,
      currentRevision: null,
      isExplicitlySaved: false,
      requiresExplicitSave: false,
      fieldDisabled: true,
      errorCode: 'gdevelop_config_invalid',
      errorStatus: 200,
      errorRequestId: response.requestId,
      errorMessage: null,
      baselineStatus: 'invalid',
      config: null,
    };
  }

  async load(
    gameId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<void> */ {
    const operation = this._startOperation(signal);
    this._setState({
      status: 'loading',
      gameId,
      draftGameType: 'single',
      draftMinPlayers: 1,
      draftMaxPlayers: 1,
      draftTags: [],
      savedGameType: null,
      revision: 0,
      currentRevision: null,
      isExplicitlySaved: false,
      requiresExplicitSave: false,
      fieldDisabled: true,
      errorCode: null,
      errorStatus: 0,
      errorRequestId: null,
      errorMessage: null,
      baselineStatus: null,
      config: null,
    });
    try {
      const response = await this._client.read({
        gameId,
        signal: operation.controller.signal,
      });
      if (!this._isCurrent(operation, gameId)) return;
      this._setState(this._stateFromResponse(gameId, response));
    } catch (error) {
      if (!this._isCurrent(operation, gameId)) return;
      const details = errorDetails(error);
      this._setState({
        status: 'unavailable',
        gameId,
        draftGameType: 'single',
        draftMinPlayers: 1,
        draftMaxPlayers: 1,
        draftTags: [],
        savedGameType: null,
        revision: 0,
        currentRevision: null,
        isExplicitlySaved: false,
        requiresExplicitSave: false,
        fieldDisabled: true,
        errorCode: details.code,
        errorStatus: details.status,
        errorRequestId: details.requestId,
        errorMessage: details.message,
        baselineStatus: 'unavailable',
        config: null,
      });
    } finally {
      operation.cleanup();
    }
  }

  selectGameType(gameType /*: PlaymeshProjectGameType */) /*: void */ {
    if (gameType !== 'single' && gameType !== 'online') {
      throw new PlaymeshProjectConfigClientError({
        code: 'invalid_game_type',
      });
    }
    if (this._state.fieldDisabled || !this._state.gameId) return;
    const draftMinPlayers = gameType === 'single'
      ? 1
      : this._state.draftMaxPlayers === 1
      ? 2
      : this._state.draftMinPlayers;
    const draftMaxPlayers = gameType === 'single'
      ? 1
      : this._state.draftMaxPlayers === 1
      ? 5
      : this._state.draftMaxPlayers;
    const draft = {
      gameType,
      minPlayers: draftMinPlayers,
      maxPlayers: draftMaxPlayers,
      tags: this._state.draftTags,
    };
    this._setState({
      ...this._state,
      draftGameType: gameType,
      draftMinPlayers,
      draftMaxPlayers,
      requiresExplicitSave: draftRequiresSave(this._state, draft),
    });
  }

  selectMinPlayers(value /*: number */) /*: void */ {
    if (
      this._state.fieldDisabled ||
      this._state.draftGameType !== 'online' ||
      !Number.isSafeInteger(value) ||
      value < 1 ||
      value > PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS
    ) return;
    const maxPlayers = Math.max(value, this._state.draftMaxPlayers);
    const draft = {
      gameType: this._state.draftGameType,
      minPlayers: value,
      maxPlayers,
      tags: this._state.draftTags,
    };
    this._setState({
      ...this._state,
      draftMinPlayers: value,
      draftMaxPlayers: maxPlayers,
      requiresExplicitSave: draftRequiresSave(this._state, draft),
    });
  }

  selectMaxPlayers(value /*: number */) /*: void */ {
    if (
      this._state.fieldDisabled ||
      this._state.draftGameType !== 'online' ||
      !Number.isSafeInteger(value) ||
      value < 1 ||
      value > PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS
    ) return;
    const minPlayers = Math.min(value, this._state.draftMinPlayers);
    const draft = {
      gameType: this._state.draftGameType,
      minPlayers,
      maxPlayers: value,
      tags: this._state.draftTags,
    };
    this._setState({
      ...this._state,
      draftMinPlayers: minPlayers,
      draftMaxPlayers: value,
      requiresExplicitSave: draftRequiresSave(this._state, draft),
    });
  }

  selectTags(values /*: Array<string> */) /*: void */ {
    if (this._state.fieldDisabled) return;
    let tags /*: Array<string> */;
    try {
      tags = normalizePlaymeshProjectTags(values);
    } catch (_) {
      return;
    }
    const draft = {
      gameType: this._state.draftGameType,
      minPlayers: this._state.draftMinPlayers,
      maxPlayers: this._state.draftMaxPlayers,
      tags,
    };
    this._setState({
      ...this._state,
      draftTags: tags,
      requiresExplicitSave: draftRequiresSave(this._state, draft),
    });
  }

  async _refreshAfterConflict(
    {
      gameId,
      attemptedGameType,
      attemptedMinPlayers,
      attemptedMaxPlayers,
      attemptedTags,
      currentRevision,
      operation,
    } /*: {|
    gameId: string,
    attemptedGameType: PlaymeshProjectGameType,
    attemptedMinPlayers: number,
    attemptedMaxPlayers: number,
    attemptedTags: Array<string>,
    currentRevision: number,
    operation: Operation,
  |} */
  ) /*: Promise<void> */ {
    try {
      const latest = await this._client.read({
        gameId,
        signal: operation.controller.signal,
      });
      if (!this._isCurrent(operation, gameId)) return;
      const baseline = this._stateFromResponse(gameId, latest);
      this._setState({
        ...baseline,
        status: 'conflict',
        draftGameType: attemptedGameType,
        draftMinPlayers: attemptedMinPlayers,
        draftMaxPlayers: attemptedMaxPlayers,
        draftTags: attemptedTags,
        currentRevision,
        requiresExplicitSave: !baseline.fieldDisabled,
        fieldDisabled: baseline.fieldDisabled,
        errorCode: 'gdevelop_config_revision_conflict',
        errorStatus: 409,
        errorRequestId: null,
        errorMessage: null,
        baselineStatus:
          baseline.status === 'ready' ||
          baseline.status === 'missing' ||
          baseline.status === 'invalid' ||
          baseline.status === 'unavailable'
            ? baseline.status
            : 'unavailable',
      });
    } catch (error) {
      if (!this._isCurrent(operation, gameId)) return;
      const details = errorDetails(error);
      this._setState({
        status: 'conflict',
        gameId,
        draftGameType: attemptedGameType,
        draftMinPlayers: attemptedMinPlayers,
        draftMaxPlayers: attemptedMaxPlayers,
        draftTags: attemptedTags,
        savedGameType: null,
        revision: currentRevision,
        currentRevision,
        isExplicitlySaved: false,
        requiresExplicitSave: false,
        fieldDisabled: true,
        errorCode: details.code,
        errorStatus: details.status,
        errorRequestId: details.requestId,
        errorMessage: details.message,
        baselineStatus: 'unavailable',
        config: null,
      });
    }
  }

  async saveAfterOfficialApply(
    {
      officialApplySucceeded,
      signal,
    } /*: {|
    officialApplySucceeded: boolean,
    signal?: ?AbortSignal,
  |} */
  ) /*: Promise<PlaymeshProjectConfigSaveOutcome> */ {
    if (officialApplySucceeded !== true) {
      return { ok: false, reason: 'official_apply_failed' };
    }
    const state = this._state;
    const gameId = state.gameId;
    if (!gameId || state.fieldDisabled) {
      return { ok: false, reason: 'config_not_savable' };
    }
    if (!state.requiresExplicitSave && state.config) {
      return { ok: true, kind: 'unchanged', config: state.config };
    }
    const attemptedGameType = state.draftGameType;
    const attemptedMinPlayers = state.draftMinPlayers;
    const attemptedMaxPlayers = state.draftMaxPlayers;
    const attemptedTags = state.draftTags;
    const expectedRevision = state.revision;
    const operation = this._startOperation(signal);
    this._setState({
      ...state,
      status: 'saving',
      fieldDisabled: true,
      errorCode: null,
      errorStatus: 0,
      errorRequestId: null,
      errorMessage: null,
    });
    try {
      const response = await this._client.put({
        gameId,
        gameType: attemptedGameType,
        minPlayers: attemptedMinPlayers,
        maxPlayers: attemptedMaxPlayers,
        tags: attemptedTags,
        expectedRevision,
        signal: operation.controller.signal,
      });
      if (!this._isCurrent(operation, gameId)) {
        return { ok: false, reason: 'superseded' };
      }
      if (response.status !== 'ready') {
        throw new PlaymeshProjectConfigClientError({
          code: 'invalid_response',
        });
      }
      this._setState(this._stateFromResponse(gameId, response));
      return { ok: true, kind: 'saved', config: response.config };
    } catch (error) {
      if (!this._isCurrent(operation, gameId)) {
        return { ok: false, reason: 'superseded' };
      }
      if (error instanceof PlaymeshProjectConfigConflictError) {
        await this._refreshAfterConflict({
          gameId,
          attemptedGameType,
          attemptedMinPlayers,
          attemptedMaxPlayers,
          attemptedTags,
          currentRevision: error.currentRevision,
          operation,
        });
        if (!this._isCurrent(operation, gameId)) {
          return { ok: false, reason: 'superseded' };
        }
        return {
          ok: false,
          reason: 'conflict',
          currentRevision: error.currentRevision,
        };
      }
      const details = errorDetails(error);
      const code = details.code;
      // A local PUT can commit before WebView2 reports a body/stream failure.
      // Re-read the authoritative sidecar before showing a false failure. A
      // newer revision with the attempted value proves this exact mutation (or
      // an equivalent concurrent one) is already durable.
      try {
        const latest = await this._client.read({
          gameId,
          signal: operation.controller.signal,
        });
        if (
          this._isCurrent(operation, gameId) &&
          latest.status === 'ready' &&
          latest.config.revision > expectedRevision &&
          latest.config.gameType === attemptedGameType &&
          latest.config.minPlayers === attemptedMinPlayers &&
          latest.config.maxPlayers === attemptedMaxPlayers &&
          sameTags(latest.config.tags, attemptedTags)
        ) {
          this._setState(this._stateFromResponse(gameId, latest));
          return { ok: true, kind: 'saved', config: latest.config };
        }
      } catch (_) {
        // Preserve the original PUT diagnostic; the reconciliation read is
        // best-effort and must not replace its status/requestId.
      }
      if (!this._isCurrent(operation, gameId)) {
        return { ok: false, reason: 'superseded' };
      }
      if (code === 'gdevelop_config_invalid') {
        this._setState({
          status: 'invalid',
          gameId,
          draftGameType: attemptedGameType,
          draftMinPlayers: attemptedMinPlayers,
          draftMaxPlayers: attemptedMaxPlayers,
          draftTags: attemptedTags,
          savedGameType: state.savedGameType,
          revision: state.revision,
          currentRevision: state.currentRevision,
          isExplicitlySaved: state.isExplicitlySaved,
          requiresExplicitSave: false,
          fieldDisabled: true,
          errorCode: code,
          errorStatus: details.status,
          errorRequestId: details.requestId,
          errorMessage: details.message,
          baselineStatus: 'invalid',
          config: state.config,
        });
      } else {
        const baselineIsEditable =
          state.baselineStatus === 'ready' ||
          state.baselineStatus === 'missing';
        this._setState({
          status: 'save_failed',
          gameId,
          draftGameType: attemptedGameType,
          draftMinPlayers: attemptedMinPlayers,
          draftMaxPlayers: attemptedMaxPlayers,
          draftTags: attemptedTags,
          savedGameType: state.savedGameType,
          revision: state.revision,
          currentRevision: state.currentRevision,
          isExplicitlySaved: state.isExplicitlySaved,
          requiresExplicitSave: true,
          fieldDisabled: !baselineIsEditable,
          errorCode: code,
          errorStatus: details.status,
          errorRequestId: details.requestId,
          errorMessage: details.message,
          baselineStatus: state.baselineStatus || 'unavailable',
          config: state.config,
        });
      }
      return {
        ok: false,
        reason: 'save_failed',
        code,
        status: details.status,
        requestId: details.requestId,
      };
    } finally {
      operation.cleanup();
    }
  }

  cancelActiveOperation(gameId /*: string */) /*: void */ {
    if (this._state.gameId === gameId && this._activeController) {
      this._activeController.abort();
    }
  }

  dispose() /*: void */ {
    if (this._disposed) return;
    this._disposed = true;
    this._epoch++;
    if (this._activeController) this._activeController.abort();
    this._activeController = null;
    this._listeners.clear();
  }
}
