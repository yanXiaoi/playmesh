// @flow

import {
  browserPreviewDebuggerServer,
} from '../ExportAndShare/BrowserExporters/BrowserPreview/BrowserPreviewDebuggerServer';
import {
  type DebuggerId,
  type PreviewDebuggerServer,
  type PreviewDebuggerServerCallbacks,
} from '../ExportAndShare/PreviewLauncher.flow';

/*::
type ActiveAppRuntime = {|
  gameId: string,
  previewId: string,
  abortController: AbortController,
  connected: boolean,
  consecutiveFailures: number,
|};

type PlaymeshDebuggerMessages = {|
  protocolVersion: '1.0.0',
  ready: boolean,
  messages: Array<string>,
|};
*/

const APP_RUNTIME_DEBUGGER_ID = 'playmesh-app-runtime';
const callbacksList /*: Array<PreviewDebuggerServerCallbacks> */ = [];
const responseCallbacks /*: Map<number, mixed => void> */ = new Map();
let nextResponseMessageId = 1;

const notifyCallbacks = (
  name /*: $Keys<PreviewDebuggerServerCallbacks> */,
  value /*: any */
) /*: void */ => {
  callbacksList.slice().forEach(callbacks => {
    const callback /*: any */ = callbacks[name];
    if (typeof callback === 'function') callback(value);
  });
};

const mixedRecord = (value /*: mixed */) /*: ?{ +[string]: mixed } */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const debuggerBasePath = (
  gameId /*: string */,
  previewId /*: string */
) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    gameId
  )}/preview/${encodeURIComponent(previewId)}/debugger`;

const readJson = async (response /*: Response */) /*: Promise<mixed> */ => {
  try {
    return await response.json();
  } catch (_) {
    return null;
  }
};

class PlaymeshPreviewDebuggerServer {
  _state /*: 'started' | 'stopped' */ = 'stopped';
  _activeAppRuntime /*: ?ActiveAppRuntime */ = null;

  constructor() {
    browserPreviewDebuggerServer.registerCallbacks({
      onErrorReceived: error => notifyCallbacks('onErrorReceived', error),
      onConnectionClosed: value =>
        notifyCallbacks('onConnectionClosed', {
          ...value,
          debuggerIds: this.getExistingDebuggerIds(),
        }),
      onConnectionOpened: value =>
        notifyCallbacks('onConnectionOpened', {
          ...value,
          debuggerIds: this.getExistingDebuggerIds(),
        }),
      onConnectionErrored: value =>
        notifyCallbacks('onConnectionErrored', value),
      onServerStateChanged: () => {
        // The composite server owns its public lifecycle.
      },
      onHandleParsedMessage: value => this._handleParsedMessage(value),
    });
  }

  async startServer({ origin } /*: {| origin: string |} */) /*: Promise<void> */ {
    if (this._state === 'started') return;
    await browserPreviewDebuggerServer.startServer({ origin });
    this._state = 'started';
    notifyCallbacks('onServerStateChanged');
  }

  getServerState = () /*: 'started' | 'stopped' */ => this._state;

  getExistingDebuggerIds = () /*: Array<DebuggerId> */ => [
    ...browserPreviewDebuggerServer.getExistingDebuggerIds(),
    ...this.getExistingAppRuntimeDebuggerIds(),
  ];

  getExistingEmbeddedGameFrameDebuggerIds = () /*: Array<DebuggerId> */ =>
    browserPreviewDebuggerServer.getExistingEmbeddedGameFrameDebuggerIds();

  getExistingPreviewDebuggerIds = () /*: Array<DebuggerId> */ => [
    ...browserPreviewDebuggerServer.getExistingPreviewDebuggerIds(),
    ...this.getExistingAppRuntimeDebuggerIds(),
  ];

  getExistingAppRuntimeDebuggerIds = () /*: Array<DebuggerId> */ =>
    this._activeAppRuntime?.connected ? [APP_RUNTIME_DEBUGGER_ID] : [];

  getAppRuntimeDebuggerState /*: () => {|
    bound: boolean,
    connected: boolean,
  |} */ = () => ({
    bound: !!this._activeAppRuntime,
    connected: !!this._activeAppRuntime?.connected,
  });

  registerCallbacks = (
    callbacks /*: PreviewDebuggerServerCallbacks */
  ) /*: () => void */ => {
    callbacksList.push(callbacks);
    return () => {
      const index = callbacksList.indexOf(callbacks);
      if (index !== -1) callbacksList.splice(index, 1);
    };
  };

  registerEmbeddedGameFrame = (frameWindow /*: WindowProxy */) /*: void */ => {
    browserPreviewDebuggerServer.registerEmbeddedGameFrame(frameWindow);
  };

  unregisterEmbeddedGameFrame = (frameWindow /*: WindowProxy */) /*: void */ => {
    browserPreviewDebuggerServer.unregisterEmbeddedGameFrame(frameWindow);
  };

  sendMessage = (id /*: DebuggerId */, message /*: Object */) /*: void */ => {
    if (id !== APP_RUNTIME_DEBUGGER_ID) {
      browserPreviewDebuggerServer.sendMessage(id, message);
      return;
    }
    const active = this._activeAppRuntime;
    if (!active || !active.connected) return;
    void this._sendAppRuntimeCommand(active, message);
  };

  sendMessageWithResponse = (message /*: Object */) /*: Promise<Object> */ => {
    const messageId = nextResponseMessageId++;
    const messageWithId = { ...message, messageId };
    this.getExistingDebuggerIds().forEach(id =>
      this.sendMessage(id, messageWithId)
    );
    return new Promise((resolve, reject) => {
      const timeout = global.setTimeout(() => {
        responseCallbacks.delete(messageId);
        reject(
          new Error(
            `Timeout while waiting for a debugger response (${messageId}).`
          )
        );
      }, 1000);
      responseCallbacks.set(messageId, value => {
        global.clearTimeout(timeout);
        resolve(value);
      });
    });
  };

  bindAppRuntime = ({
    gameId,
    previewId,
  } /*: {| gameId: string, previewId: string |} */) /*: void */ => {
    this.unbindAppRuntime();
    const active /*: ActiveAppRuntime */ = {
      gameId,
      previewId,
      abortController: new AbortController(),
      connected: false,
      consecutiveFailures: 0,
    };
    this._activeAppRuntime = active;
    void this._pollAppRuntime(active);
  };

  unbindAppRuntime = () /*: void */ => {
    const active = this._activeAppRuntime;
    this._activeAppRuntime = null;
    if (!active) return;
    active.abortController.abort();
    if (active.connected) {
      notifyCallbacks('onConnectionClosed', {
        id: APP_RUNTIME_DEBUGGER_ID,
        debuggerIds: this.getExistingDebuggerIds(),
      });
    }
  };

  closeAllConnections = () /*: void */ => {
    this.unbindAppRuntime();
    responseCallbacks.clear();
    browserPreviewDebuggerServer.closeAllConnections();
  };

  _handleParsedMessage = ({ id, parsedMessage } /*: any */) /*: void */ => {
    const messageId = parsedMessage && parsedMessage.messageId;
    if (typeof messageId === 'number') {
      const resolve = responseCallbacks.get(messageId);
      if (resolve) {
        responseCallbacks.delete(messageId);
        resolve(parsedMessage);
      }
    }
    notifyCallbacks('onHandleParsedMessage', { id, parsedMessage });
  };

  _pollAppRuntime = async (active /*: ActiveAppRuntime */) /*: Promise<void> */ => {
    if (this._activeAppRuntime !== active || active.abortController.signal.aborted)
      return;
    try {
      const response = await global.fetch(
        `${debuggerBasePath(active.gameId, active.previewId)}/messages`,
        {
          credentials: 'same-origin',
          cache: 'no-store',
          signal: active.abortController.signal,
        }
      );
      const value = mixedRecord(await readJson(response));
      const rawMessages = value && value.messages;
      const ready = value && value.ready;
      if (
        !response.ok ||
        value?.protocolVersion !== '1.0.0' ||
        typeof ready !== 'boolean' ||
        !Array.isArray(rawMessages)
      ) {
        throw new Error(`Debugger relay poll failed (HTTP ${response.status}).`);
      }
      active.consecutiveFailures = 0;
      if (ready && !active.connected) {
        active.connected = true;
        notifyCallbacks('onConnectionOpened', {
          id: APP_RUNTIME_DEBUGGER_ID,
          debuggerIds: this.getExistingDebuggerIds(),
        });
      }
      rawMessages.forEach(rawMessage => {
        if (typeof rawMessage !== 'string') return;
        try {
          this._handleParsedMessage({
            id: APP_RUNTIME_DEBUGGER_ID,
            parsedMessage: JSON.parse(rawMessage),
          });
        } catch (error) {
          notifyCallbacks('onErrorReceived', error);
        }
      });
    } catch (error) {
      if (active.abortController.signal.aborted) return;
      active.consecutiveFailures += 1;
      if (active.connected && active.consecutiveFailures >= 3) {
        active.connected = false;
        notifyCallbacks('onConnectionClosed', {
          id: APP_RUNTIME_DEBUGGER_ID,
          debuggerIds: this.getExistingDebuggerIds(),
        });
      }
    }
    if (this._activeAppRuntime === active && !active.abortController.signal.aborted) {
      global.setTimeout(() => void this._pollAppRuntime(active), 250);
    }
  };

  _sendAppRuntimeCommand = async (
    active /*: ActiveAppRuntime */,
    command /*: Object */
  ) /*: Promise<void> */ => {
    try {
      const response = await global.fetch(
        `${debuggerBasePath(active.gameId, active.previewId)}/commands`,
        {
          method: 'POST',
          credentials: 'same-origin',
          cache: 'no-store',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ command }),
          signal: active.abortController.signal,
        }
      );
      if (!response.ok) {
        throw new Error(
          `Debugger relay command failed (HTTP ${response.status}).`
        );
      }
    } catch (error) {
      if (active.abortController.signal.aborted) return;
      notifyCallbacks('onConnectionErrored', {
        id: APP_RUNTIME_DEBUGGER_ID,
        errorMessage: error instanceof Error ? error.message : String(error),
      });
    }
  };
}

export const playmeshPreviewDebuggerServer /*: PreviewDebuggerServer & {
  bindAppRuntime: ({| gameId: string, previewId: string |}) => void,
  unbindAppRuntime: () => void,
  getAppRuntimeDebuggerState: () => {|
    bound: boolean,
    connected: boolean,
  |},
} */ = (new PlaymeshPreviewDebuggerServer() /*: any */);
