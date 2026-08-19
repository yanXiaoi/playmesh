// @flow

import { playmeshPreviewDebuggerServer } from '../PlaymeshPreview/PlaymeshPreviewDebuggerServer';

/*::
import type {
  DebuggerId,
  PreviewDebuggerServerCallbacks,
} from '../ExportAndShare/PreviewLauncher.flow';
import type {
  PlaymeshAiEditorFunctionExecution,
  PlaymeshAiEditorFunctionWrapperContext,
  PlaymeshAiEditorFunctionWrappers,
} from './PlaymeshAiEditorFunctionTypes';
import type { PlaymeshAiObject } from './PlaymeshAiProtocol';

type ReadonlyMixedDictionary = { +[key: string]: mixed };
type WritableMixedDictionary = { [key: string]: mixed };
interface PlaymeshRuntimeDebuggerServer {
  getExistingPreviewDebuggerIds(): Array<DebuggerId>;
  registerCallbacks(callbacks: PreviewDebuggerServerCallbacks): () => void;
  sendMessage(id: DebuggerId, message: Object): void;
  getAppRuntimeDebuggerState?: () => {
    bound: boolean,
    connected: boolean,
    ...,
  };
}

type UnavailableReason =
  | 'no_preview'
  | 'disconnected'
  | 'debugger_response_unavailable';
type UnavailableDebugger = {|
  status: 'unavailable',
  reason: UnavailableReason,
|};
type CurrentDebugger = {|
  status: 'available',
  debuggerId: DebuggerId,
  debuggerIds: Array<DebuggerId>,
|};
type CurrentDebuggerResult = CurrentDebugger | UnavailableDebugger;
type DebuggerMessage = {|
  status: 'message',
  message: PlaymeshAiObject,
|};
type DebuggerMessageResult = DebuggerMessage | UnavailableDebugger;
type RuntimeDump = {|
  status: 'available',
  current: CurrentDebugger,
  message: PlaymeshAiObject,
  scene: PlaymeshAiObject,
|};
type RuntimeDumpResult = RuntimeDump | UnavailableDebugger;

type PendingDebuggerMessage = {|
  debuggerId: DebuggerId,
  expectedCommand: string,
  resolve: DebuggerMessageResult => void,
  timeout: TimeoutID,
|};

type PlaymeshAiRuntimeDebuggerToolsOptions = {|
  previewDebuggerServer?: PlaymeshRuntimeDebuggerServer,
  responseTimeoutMs?: number,
|};
*/

export const PLAYMESH_AI_RUNTIME_DEBUGGER_TOOL_NAMES /*: $ReadOnlyArray<string> */ = Object.freeze([
  'get_debugger_connection_status',
  'get_runtime_error_logs',
  'get_current_runtime_scene',
  'get_current_runtime_instances',
  'get_current_runtime_variables',
  'pause_runtime',
  'resume_runtime',
  'set_runtime_value',
  'call_runtime_method',
]);

const isObject = (value /*: mixed */) /*: ?ReadonlyMixedDictionary */ => {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  const dictionary /*: ReadonlyMixedDictionary */ = value;
  return dictionary;
};

const unavailable = (
  reason /*: UnavailableReason */
) /*: UnavailableDebugger */ => ({
  status: 'unavailable',
  reason,
});

const finished = (
  context /*: PlaymeshAiEditorFunctionWrapperContext */,
  output /*: PlaymeshAiObject */
) /*: PlaymeshAiEditorFunctionExecution */ => ({
  result: {
    status: 'finished',
    call_id: context.call.callId,
    success: true,
    output,
  },
  createdProject: null,
  createdSceneNames: [],
});

const currentSceneFromDump = (
  parsedMessage /*: PlaymeshAiObject */
) /*: ?PlaymeshAiObject */ => {
  const payload = isObject(parsedMessage.payload);
  const sceneStack = payload && isObject(payload._sceneStack);
  const stack = sceneStack && sceneStack._stack;
  if (!Array.isArray(stack) || !stack.length) return null;
  return isObject(stack[stack.length - 1]);
};

const instanceItemsFromScene = (
  scene /*: PlaymeshAiObject */
) /*: ?PlaymeshAiObject */ => {
  const instances = isObject(scene._instances);
  return instances && isObject(instances.items);
};

const instanceIdentityKeys = Object.freeze([
  'name',
  '_nameId',
  'type',
  'id',
  'x',
  'y',
  'z',
  'zOrder',
  'angle',
  'layer',
  'hidden',
  'livingOnScene',
  'opacity',
  '_scaleX',
  '_scaleY',
  '_scaleZ',
  'width',
  'height',
  'depth',
]);

// Runtime objects can contain engine, renderer and extension internals. Only the
// stable instance identity/transform surface is returned; counts are never cut.
const projectRuntimeInstance = (
  value /*: mixed */
) /*: ?PlaymeshAiObject */ => {
  const instance = isObject(value);
  if (!instance) return null;
  const projected /*: WritableMixedDictionary */ = {};
  instanceIdentityKeys.forEach(key => {
    if (Object.hasOwn(instance, key)) {
      projected[key] = instance[key];
    }
  });
  return projected;
};

const runtimeInstancesFromScene = (
  scene /*: PlaymeshAiObject */
) /*: Array<PlaymeshAiObject> */ => {
  const items = instanceItemsFromScene(scene);
  if (!items) return [];
  const instances /*: Array<PlaymeshAiObject> */ = [];
  Object.keys(items).forEach(objectName => {
    const objectInstances = items[objectName];
    if (!Array.isArray(objectInstances)) return;
    objectInstances.forEach(value => {
      const instance = projectRuntimeInstance(value);
      if (instance) instances.push(instance);
    });
  });
  return instances;
};

const runtimeInstanceVariablesFromScene = (
  scene /*: PlaymeshAiObject */
) /*: Array<PlaymeshAiObject> */ => {
  const items = instanceItemsFromScene(scene);
  if (!items) return [];
  const variables /*: Array<PlaymeshAiObject> */ = [];
  Object.keys(items).forEach(objectName => {
    const objectInstances = items[objectName];
    if (!Array.isArray(objectInstances)) return;
    objectInstances.forEach(value => {
      const instance = isObject(value);
      if (!instance || !isObject(instance._variables)) return;
      variables.push({
        objectName,
        instanceId: instance.id,
        variables: instance._variables,
      });
    });
  });
  return variables;
};

export class PlaymeshAiRuntimeDebuggerTools {
  /*::
  previewDebuggerServer: PlaymeshRuntimeDebuggerServer;
  responseTimeoutMs: number;
  pendingMessages: Set<PendingDebuggerMessage>;
  runtimeErrors: Map<DebuggerId, Array<PlaymeshAiObject>>;
  lastDebuggerId: ?DebuggerId;
  hasObservedConnection: boolean;
  disconnected: boolean;
  unregisterCallbacks: () => void;
  wrappers: PlaymeshAiEditorFunctionWrappers;
  */

  constructor({
    previewDebuggerServer = playmeshPreviewDebuggerServer,
    responseTimeoutMs = 5000,
  } /*: PlaymeshAiRuntimeDebuggerToolsOptions */ = {}) {
    this.previewDebuggerServer = previewDebuggerServer;
    this.responseTimeoutMs = responseTimeoutMs;
    this.pendingMessages = new Set();
    this.runtimeErrors = new Map();
    const existingDebuggerIds = this._existingDebuggerIds();
    this.lastDebuggerId = existingDebuggerIds.length
      ? existingDebuggerIds[existingDebuggerIds.length - 1]
      : null;
    this.hasObservedConnection = existingDebuggerIds.length > 0;
    this.disconnected = false;
    this.unregisterCallbacks = previewDebuggerServer.registerCallbacks({
      onErrorReceived: () => {},
      onServerStateChanged: () => {},
      onConnectionOpened: ({ id }) => {
        this.lastDebuggerId = id;
        this.hasObservedConnection = true;
        this.disconnected = false;
      },
      onConnectionClosed: ({ id }) => {
        this.lastDebuggerId = id;
        this.disconnected = true;
        this._settlePending(id, unavailable('disconnected'));
      },
      onConnectionErrored: ({ id }) => {
        this._settlePending(
          id,
          unavailable('debugger_response_unavailable')
        );
      },
      onHandleParsedMessage: ({ id, parsedMessage }) => {
        const message = isObject(parsedMessage);
        if (!message) return;
        this._captureRuntimeError(id, message);
        const command = message.command;
        if (typeof command === 'string') {
          this._settlePending(
            id,
            { status: 'message', message },
            command
          );
        }
      },
    });
    this.wrappers = {
      get_debugger_connection_status: context =>
        this._getConnectionStatus(context),
      get_runtime_error_logs: context => this._getRuntimeErrors(context),
      get_current_runtime_scene: context => this._getCurrentScene(context),
      get_current_runtime_instances: context =>
        this._getCurrentInstances(context),
      get_current_runtime_variables: context =>
        this._getCurrentVariables(context),
      pause_runtime: context => this._control(context, 'pause'),
      resume_runtime: context => this._control(context, 'play'),
      set_runtime_value: context =>
        this._control(context, 'set', {
          path: context.call.arguments.path,
          newValue: context.call.arguments.newValue,
        }),
      call_runtime_method: context =>
        this._control(context, 'call', {
          path: context.call.arguments.path,
          args: context.call.arguments.args,
        }),
    };
  }

  _existingDebuggerIds() /*: Array<DebuggerId> */ {
    return this.previewDebuggerServer
      .getExistingPreviewDebuggerIds()
      .filter(id => typeof id === 'string' && !!id);
  }

  _currentDebugger() /*: CurrentDebuggerResult */ {
    const debuggerIds = this._existingDebuggerIds();
    if (debuggerIds.length) {
      const debuggerId =
        this.lastDebuggerId && debuggerIds.includes(this.lastDebuggerId)
          ? this.lastDebuggerId
          : debuggerIds[debuggerIds.length - 1];
      if (!debuggerId) return unavailable('no_preview');
      this.lastDebuggerId = debuggerId;
      this.hasObservedConnection = true;
      this.disconnected = false;
      return { status: 'available', debuggerId, debuggerIds };
    }
    const getAppRuntimeState = this.previewDebuggerServer
      .getAppRuntimeDebuggerState;
    const appRuntimeState =
      typeof getAppRuntimeState === 'function'
        ? getAppRuntimeState.call(this.previewDebuggerServer)
        : null;
    return unavailable(
      (appRuntimeState && appRuntimeState.bound) ||
        this.hasObservedConnection ||
        this.disconnected
        ? 'disconnected'
        : 'no_preview'
    );
  }

  _captureRuntimeError(
    debuggerId /*: DebuggerId */,
    message /*: PlaymeshAiObject */
  ) /*: void */ {
    const payload = isObject(message.payload);
    let captured = null;
    if (
      message.command === 'console.log' &&
      payload &&
      payload.type === 'error'
    ) {
      captured = message;
    } else if (message.command === 'game.crashed') {
      // The wrapper is a transport adapter for the official debugger payload.
      // Shared return-status serialization owns secret redaction; the debugger
      // layer must not silently delete diagnostic fields.
      captured = message;
    }
    if (!captured) return;
    const errors = this.runtimeErrors.get(debuggerId) || [];
    errors.push(captured);
    this.runtimeErrors.set(debuggerId, errors);
  }

  _settlePending(
    debuggerId /*: DebuggerId */,
    result /*: DebuggerMessageResult */,
    command /*: ?string */ = null
  ) /*: void */ {
    [...this.pendingMessages].forEach(pending => {
      if (
        pending.debuggerId !== debuggerId ||
        (command && pending.expectedCommand !== command)
      ) {
        return;
      }
      global.clearTimeout(pending.timeout);
      this.pendingMessages.delete(pending);
      pending.resolve(result);
    });
  }

  _requestMessage(
    current /*: CurrentDebugger */,
    requestCommand /*: string */,
    expectedCommand /*: string */
  ) /*: Promise<DebuggerMessageResult> */ {
    return new Promise(resolve => {
      const pending /*: PendingDebuggerMessage */ = {
        debuggerId: current.debuggerId,
        expectedCommand,
        resolve,
        timeout: global.setTimeout(() => {
          this.pendingMessages.delete(pending);
          resolve(unavailable('debugger_response_unavailable'));
        }, this.responseTimeoutMs),
      };
      this.pendingMessages.add(pending);
      try {
        this.previewDebuggerServer.sendMessage(current.debuggerId, {
          command: requestCommand,
        });
      } catch (_) {
        global.clearTimeout(pending.timeout);
        this.pendingMessages.delete(pending);
        resolve(unavailable('debugger_response_unavailable'));
      }
    });
  }

  async _getConnectionStatus(
    context /*: PlaymeshAiEditorFunctionWrapperContext */
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const current = this._currentDebugger();
    if (current.status === 'unavailable') return finished(context, current);
    const response = await this._requestMessage(current, 'getStatus', 'status');
    if (response.status === 'unavailable') {
      return finished(context, response);
    }
    return finished(context, {
      status: 'available',
      debuggerId: current.debuggerId,
      debuggerIds: current.debuggerIds,
      runtimeStatus: response.message.payload,
    });
  }

  async _getRuntimeErrors(
    context /*: PlaymeshAiEditorFunctionWrapperContext */
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const current = this._currentDebugger();
    if (current.status === 'unavailable') {
      const debuggerId = this.lastDebuggerId;
      return finished(context, {
        ...current,
        errors: debuggerId ? this.runtimeErrors.get(debuggerId) || [] : [],
      });
    }
    return finished(context, {
      status: 'available',
      debuggerId: current.debuggerId,
      errors: this.runtimeErrors.get(current.debuggerId) || [],
    });
  }

  async _readDump() /*: Promise<RuntimeDumpResult> */ {
    const current = this._currentDebugger();
    if (current.status === 'unavailable') return current;
    const response = await this._requestMessage(current, 'refresh', 'dump');
    if (response.status === 'unavailable') return response;
    const scene = currentSceneFromDump(response.message);
    if (!scene) return unavailable('debugger_response_unavailable');
    return {
      status: 'available',
      current,
      message: response.message,
      scene,
    };
  }

  async _getCurrentScene(
    context /*: PlaymeshAiEditorFunctionWrapperContext */
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const dump = await this._readDump();
    if (dump.status === 'unavailable') return finished(context, dump);
    const scene = dump.scene;
    return finished(context, {
      status: 'available',
      debuggerId: dump.current.debuggerId,
      scene: {
        name: scene._name,
        isLoaded: scene._isLoaded,
        gameStopRequested: scene._gameStopRequested,
        requestedScene: scene._requestedScene,
        requestedChange: scene._requestedChange,
        backgroundColor: scene._backgroundColor,
        timeManager: scene._timeManager,
        layers: scene._layers,
      },
    });
  }

  async _getCurrentInstances(
    context /*: PlaymeshAiEditorFunctionWrapperContext */
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const dump = await this._readDump();
    if (dump.status === 'unavailable') return finished(context, dump);
    return finished(context, {
      status: 'available',
      debuggerId: dump.current.debuggerId,
      sceneName: dump.scene._name,
      instances: runtimeInstancesFromScene(dump.scene),
    });
  }

  async _getCurrentVariables(
    context /*: PlaymeshAiEditorFunctionWrapperContext */
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const dump = await this._readDump();
    if (dump.status === 'unavailable') return finished(context, dump);
    const payload = isObject(dump.message.payload);
    return finished(context, {
      status: 'available',
      debuggerId: dump.current.debuggerId,
      sceneName: dump.scene._name,
      globalVariables: payload ? payload._variables : null,
      sceneVariables: dump.scene._variables,
      instanceVariables: runtimeInstanceVariablesFromScene(dump.scene),
    });
  }

  async _control(
    context /*: PlaymeshAiEditorFunctionWrapperContext */,
    command /*: 'pause' | 'play' | 'set' | 'call' */,
    commandArguments /*: PlaymeshAiObject */ = {}
  ) /*: Promise<PlaymeshAiEditorFunctionExecution> */ {
    const current = this._currentDebugger();
    if (current.status === 'unavailable') return finished(context, current);
    try {
      this.previewDebuggerServer.sendMessage(current.debuggerId, {
        ...commandArguments,
        command,
      });
      return finished(context, {
        status: 'accepted',
        debuggerId: current.debuggerId,
        command,
      });
    } catch (_) {
      return finished(context, unavailable('debugger_response_unavailable'));
    }
  }

  dispose() /*: void */ {
    this.unregisterCallbacks();
    [...this.pendingMessages].forEach(pending => {
      global.clearTimeout(pending.timeout);
      pending.resolve(unavailable('disconnected'));
    });
    this.pendingMessages.clear();
  }
}

export const playmeshAiRuntimeDebuggerTools /*: PlaymeshAiRuntimeDebuggerTools */ = new PlaymeshAiRuntimeDebuggerTools();

export default playmeshAiRuntimeDebuggerTools;
