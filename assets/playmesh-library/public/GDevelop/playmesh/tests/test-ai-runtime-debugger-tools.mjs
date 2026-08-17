import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiRuntimeDebuggerTools.js'
);
let source = await readFile(sourcePath, 'utf8');

const callbacks = [];
const sentMessages = [];
const fakeServer = {
  debuggerIds: [],
  appRuntimeState: { bound: false, connected: false },
  autoRespond: true,
  getExistingPreviewDebuggerIds() {
    return [...this.debuggerIds];
  },
  getAppRuntimeDebuggerState() {
    return { ...this.appRuntimeState };
  },
  registerCallbacks(value) {
    callbacks.push(value);
    return () => {
      const index = callbacks.indexOf(value);
      if (index !== -1) callbacks.splice(index, 1);
    };
  },
  sendMessage(id, message) {
    sentMessages.push({ id, message });
    if (!this.autoRespond) return;
    if (message.command === 'getStatus') {
      queueMicrotask(() =>
        this.emitMessage(id, {
          command: 'status',
          payload: {
            isPaused: false,
            isInGameEdition: false,
            sceneName: 'Arena',
          },
        })
      );
    } else if (message.command === 'refresh') {
      queueMicrotask(() => this.emitMessage(id, runtimeDump));
    }
  },
  emitMessage(id, parsedMessage) {
    callbacks.forEach(value =>
      value.onHandleParsedMessage({ id, parsedMessage })
    );
  },
  open(id) {
    this.debuggerIds = [id];
    this.appRuntimeState = { bound: true, connected: true };
    callbacks.forEach(value =>
      value.onConnectionOpened({ id, debuggerIds: [id] })
    );
  },
  close(id) {
    this.debuggerIds = [];
    this.appRuntimeState = { bound: true, connected: false };
    callbacks.forEach(value =>
      value.onConnectionClosed({ id, debuggerIds: [] })
    );
  },
};
globalThis.__playmeshAiRuntimeDebuggerServerMock = fakeServer;

source = source
  .replace(
    /import \{ playmeshPreviewDebuggerServer \} from '[^']+';/,
    'const playmeshPreviewDebuggerServer = globalThis.__playmeshAiRuntimeDebuggerServerMock;'
  )
  .replace(
    'export const PLAYMESH_AI_RUNTIME_DEBUGGER_TOOL_NAMES',
    'const PLAYMESH_AI_RUNTIME_DEBUGGER_TOOL_NAMES'
  )
  .replace(
    'export class PlaymeshAiRuntimeDebuggerTools',
    'class PlaymeshAiRuntimeDebuggerTools'
  )
  .replace(
    'export const playmeshAiRuntimeDebuggerTools',
    'const playmeshAiRuntimeDebuggerTools'
  )
  .replace(/export default playmeshAiRuntimeDebuggerTools;\s*$/, '')
  .concat(`
globalThis.__playmeshAiRuntimeDebuggerToolsClass = PlaymeshAiRuntimeDebuggerTools;
globalThis.__playmeshAiRuntimeDebuggerToolNames = PLAYMESH_AI_RUNTIME_DEBUGGER_TOOL_NAMES;
playmeshAiRuntimeDebuggerTools.dispose();
`);

const instances = Array.from({ length: 620 }, (_, index) => ({
  name: 'Enemy',
  type: 'Sprite',
  id: index + 1,
  x: index,
  y: index * 2,
  angle: index % 360,
  layer: '',
  hidden: false,
  _variables: {
    _variables: {
      items: {
        health: { _value: 100 - index, _str: '', _isStructure: false },
      },
    },
  },
  _renderer: { private: true },
  networkAdapter: { private: true },
}));

const runtimeDump = {
  command: 'dump',
  payload: {
    _variables: {
      _variables: { items: { score: { _value: 10 } } },
    },
    _sceneStack: {
      _stack: [
        {
          _name: 'Arena',
          _isLoaded: true,
          _gameStopRequested: false,
          _requestedScene: '',
          _requestedChange: 0,
          _backgroundColor: 123,
          _timeManager: { _timeFromStart: 456 },
          _layers: { items: { '': { _hidden: false } } },
          _variables: {
            _variables: { items: { wave: { _value: 3 } } },
          },
          _instances: { items: { Enemy: instances } },
        },
      ],
    },
  },
};

const context = (toolName, args = {}) => ({
  call: {
    callId: `call-${toolName}`,
    toolName,
    arguments: args,
  },
});

const outputOf = execution => execution.result.output;

try {
  await import(
    `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
  );
  const RuntimeDebuggerTools =
    globalThis.__playmeshAiRuntimeDebuggerToolsClass;
  assert.deepEqual(
    [...globalThis.__playmeshAiRuntimeDebuggerToolNames],
    [
      'get_debugger_connection_status',
      'get_runtime_error_logs',
      'get_current_runtime_scene',
      'get_current_runtime_instances',
      'get_current_runtime_variables',
      'pause_runtime',
      'resume_runtime',
      'set_runtime_value',
      'call_runtime_method',
    ]
  );

  const tools = new RuntimeDebuggerTools({
    previewDebuggerServer: fakeServer,
    responseTimeoutMs: 100,
  });

  const noPreview = outputOf(
    await tools.wrappers.get_debugger_connection_status(
      context('get_debugger_connection_status')
    )
  );
  assert.deepEqual(noPreview, {
    status: 'unavailable',
    reason: 'no_preview',
  });

  fakeServer.open('runtime-1');
  const connected = outputOf(
    await tools.wrappers.get_debugger_connection_status(
      context('get_debugger_connection_status')
    )
  );
  assert.equal(connected.status, 'available');
  assert.equal(connected.debuggerId, 'runtime-1');
  assert.deepEqual(connected.runtimeStatus, {
    isPaused: false,
    isInGameEdition: false,
    sceneName: 'Arena',
  });

  const originalError = {
    command: 'console.log',
    payload: {
      message: 'boom',
      type: 'error',
      group: 'JavaScript',
      internal: false,
      timestamp: 42,
    },
  };
  fakeServer.emitMessage('runtime-1', originalError);
  for (let index = 0; index < 600; index += 1) {
    fakeServer.emitMessage('runtime-1', {
      command: 'console.log',
      payload: {
        message: `error-${index}`,
        type: 'error',
        group: 'JavaScript',
        internal: false,
        timestamp: index,
      },
    });
  }
  const crashReport = {
    command: 'game.crashed',
    payload: {
      type: 'javascript-uncaught-exception',
      exception: { name: 'Error', message: 'crashed', stack: 'stack' },
      game: { location: 'private-page-location' },
      sessionId: 'private-session',
      diagnostics: 'z'.repeat(4 * 1024 * 1024 + 1),
    },
  };
  fakeServer.emitMessage('runtime-1', crashReport);
  const errors = outputOf(
    await tools.wrappers.get_runtime_error_logs(
      context('get_runtime_error_logs')
    )
  );
  assert.equal(errors.errors.length, 602);
  assert.strictEqual(errors.errors[0], originalError);
  assert.strictEqual(errors.errors.at(-1), crashReport);
  assert.equal(
    errors.errors.at(-1).payload.diagnostics.length,
    4 * 1024 * 1024 + 1
  );

  const scene = outputOf(
    await tools.wrappers.get_current_runtime_scene(
      context('get_current_runtime_scene')
    )
  );
  assert.equal(scene.scene.name, 'Arena');
  assert.deepEqual(scene.scene.timeManager, { _timeFromStart: 456 });

  const runtimeInstances = outputOf(
    await tools.wrappers.get_current_runtime_instances(
      context('get_current_runtime_instances')
    )
  );
  assert.equal(runtimeInstances.instances.length, 620);
  assert.equal(runtimeInstances.instances[619].id, 620);
  assert.equal('_renderer' in runtimeInstances.instances[0], false);
  assert.equal('networkAdapter' in runtimeInstances.instances[0], false);

  const variables = outputOf(
    await tools.wrappers.get_current_runtime_variables(
      context('get_current_runtime_variables')
    )
  );
  assert.equal(variables.instanceVariables.length, 620);
  assert.equal(
    variables.globalVariables._variables.items.score._value,
    10
  );
  assert.equal(variables.sceneVariables._variables.items.wave._value, 3);

  await tools.wrappers.pause_runtime(context('pause_runtime'));
  await tools.wrappers.resume_runtime(context('resume_runtime'));
  const largeArgument = { nested: 'x'.repeat(2 * 1024 * 1024) };
  await tools.wrappers.set_runtime_value(
    context('set_runtime_value', {
      path: ['_sceneStack', '_stack', '0', '_variables'],
      newValue: largeArgument,
    })
  );
  await tools.wrappers.call_runtime_method(
    context('call_runtime_method', {
      path: ['_sceneStack', 'replaceScene'],
      args: ['Arena', false],
    })
  );
  assert.deepEqual(
    sentMessages.slice(-4).map(entry => entry.message),
    [
      { command: 'pause' },
      { command: 'play' },
      {
        command: 'set',
        path: ['_sceneStack', '_stack', '0', '_variables'],
        newValue: largeArgument,
      },
      {
        command: 'call',
        path: ['_sceneStack', 'replaceScene'],
        args: ['Arena', false],
      },
    ]
  );

  fakeServer.autoRespond = false;
  const pendingStatus = tools.wrappers.get_debugger_connection_status(
    context('get_debugger_connection_status')
  );
  fakeServer.close('runtime-1');
  assert.deepEqual(outputOf(await pendingStatus), {
    status: 'unavailable',
    reason: 'disconnected',
  });

  const disconnectedErrors = outputOf(
    await tools.wrappers.get_runtime_error_logs(
      context('get_runtime_error_logs')
    )
  );
  assert.equal(disconnectedErrors.status, 'unavailable');
  assert.equal(disconnectedErrors.reason, 'disconnected');
  assert.equal(disconnectedErrors.errors.length, 602);

  fakeServer.autoRespond = true;
  fakeServer.open('runtime-1');
  const reconnected = outputOf(
    await tools.wrappers.get_debugger_connection_status(
      context('get_debugger_connection_status')
    )
  );
  assert.equal(reconnected.status, 'available');
  tools.dispose();

  assert.equal(/\b(?:eval|evaluate|execute)\b/.test(source), false);
} finally {
  delete globalThis.__playmeshAiRuntimeDebuggerServerMock;
  delete globalThis.__playmeshAiRuntimeDebuggerToolsClass;
  delete globalThis.__playmeshAiRuntimeDebuggerToolNames;
}

console.log('Playmesh AI runtime debugger tool contracts passed.');
