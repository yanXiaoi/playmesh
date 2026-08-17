import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshPreview/PlaymeshPreviewDebuggerServer.js'
);
let source = await readFile(sourcePath, 'utf8');

const browserCallbacks = [];
const embeddedFramesRegistered = [];
const embeddedFramesUnregistered = [];
const browserMessages = [];
let browserCloseCalls = 0;
const browserServer = {
  state: 'stopped',
  async startServer() {
    this.state = 'started';
  },
  getServerState() {
    return this.state;
  },
  getExistingDebuggerIds: () => ['browser-preview', 'browser-embedded'],
  getExistingEmbeddedGameFrameDebuggerIds: () => ['browser-embedded'],
  getExistingPreviewDebuggerIds: () => ['browser-preview'],
  registerCallbacks(callbacks) {
    browserCallbacks.push(callbacks);
    return () => {};
  },
  registerEmbeddedGameFrame: frame => embeddedFramesRegistered.push(frame),
  unregisterEmbeddedGameFrame: frame => embeddedFramesUnregistered.push(frame),
  sendMessage: (id, message) => browserMessages.push({ id, message }),
  closeAllConnections: () => {
    browserCloseCalls++;
  },
};
globalThis.__playmeshDebuggerServerBrowserMock = browserServer;

source = source
  .replace(
    /import \{\s*browserPreviewDebuggerServer,?\s*\} from '[^']+';/,
    'const browserPreviewDebuggerServer = globalThis.__playmeshDebuggerServerBrowserMock;'
  )
  .replace(/import \{[\s\S]*?\} from '\.\.\/ExportAndShare\/PreviewLauncher\.flow';/, '')
  .replace(
    'export const playmeshPreviewDebuggerServer',
    'const playmeshPreviewDebuggerServer'
  )
  .concat('\nglobalThis.__playmeshPreviewDebuggerServerTest = playmeshPreviewDebuggerServer;\n');

const originalFetch = globalThis.fetch;
const requests = [];
let polls = 0;
let failingPolls = 0;
globalThis.fetch = async (url, options = {}) => {
  requests.push({ url, options });
  if (options.method === 'POST') {
    return { ok: true, status: 200, json: async () => ({ accepted: true }) };
  }
  polls += 1;
  if (failingPolls > 0) {
    failingPolls -= 1;
    return { ok: false, status: 503, json: async () => null };
  }
  return {
    ok: true,
    status: 200,
    json: async () => ({
      protocolVersion: '1.0.0',
      ready: polls > 1,
      messages:
        polls > 1
          ? [
              JSON.stringify({
                command: 'status',
                payload: {
                  isPaused: false,
                  isInGameEdition: false,
                  sceneName: 'Scene',
                },
              }),
            ]
          : [],
    }),
  };
};

try {
  await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const server = globalThis.__playmeshPreviewDebuggerServerTest;
  const opened = [];
  const closed = [];
  const parsed = [];
  const errors = [];
  let stateChanges = 0;
  server.registerCallbacks({
    onErrorReceived: error => errors.push(error),
    onConnectionClosed: value => closed.push(value),
    onConnectionOpened: value => opened.push(value),
    onConnectionErrored: value => errors.push(value),
    onServerStateChanged: () => stateChanges++,
    onHandleParsedMessage: value => parsed.push(value),
  });

  assert.equal(server.getServerState(), 'stopped');
  await server.startServer({ origin: 'http://127.0.0.1:16666' });
  assert.equal(server.getServerState(), 'started');
  assert.equal(stateChanges, 1);
  assert.deepEqual(server.getExistingEmbeddedGameFrameDebuggerIds(), [
    'browser-embedded',
  ]);
  assert.deepEqual(server.getExistingPreviewDebuggerIds(), [
    'browser-preview',
  ]);
  assert.deepEqual(server.getExistingDebuggerIds(), [
    'browser-preview',
    'browser-embedded',
  ]);

  const embeddedFrame = {};
  server.registerEmbeddedGameFrame(embeddedFrame);
  server.sendMessage('browser-embedded', { command: 'switchForInGameEdition' });
  server.unregisterEmbeddedGameFrame(embeddedFrame);
  assert.deepEqual(embeddedFramesRegistered, [embeddedFrame]);
  assert.deepEqual(embeddedFramesUnregistered, [embeddedFrame]);
  assert.deepEqual(browserMessages, [
    {
      id: 'browser-embedded',
      message: { command: 'switchForInGameEdition' },
    },
  ]);

  server.bindAppRuntime({ gameId: 'com.playmesh.game.test', previewId: 'p1' });
  await new Promise(resolve => setTimeout(resolve, 320));
  assert.equal(opened.length, 1);
  assert.equal(opened[0].id, 'playmesh-app-runtime');
  assert.deepEqual(server.getExistingPreviewDebuggerIds(), [
    'browser-preview',
    'playmesh-app-runtime',
  ]);
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].parsedMessage.command, 'status');

  failingPolls = 3;
  await new Promise(resolve => setTimeout(resolve, 800));
  assert.equal(closed.length, 1);
  assert.deepEqual(server.getExistingPreviewDebuggerIds(), [
    'browser-preview',
  ]);
  await new Promise(resolve => setTimeout(resolve, 320));
  assert.equal(opened.length, 2);
  assert.deepEqual(server.getExistingPreviewDebuggerIds(), [
    'browser-preview',
    'playmesh-app-runtime',
  ]);

  server.sendMessage('playmesh-app-runtime', { command: 'pause' });
  await new Promise(resolve => setTimeout(resolve, 0));
  const commandRequest = requests.find(
    request => request.options.method === 'POST'
  );
  assert.ok(commandRequest);
  assert.equal(
    JSON.parse(commandRequest.options.body).command.command,
    'pause'
  );

  server.unbindAppRuntime();
  assert.equal(closed.length, 2);
  assert.deepEqual(server.getExistingPreviewDebuggerIds(), [
    'browser-preview',
  ]);
  server.closeAllConnections();
  assert.equal(browserCloseCalls, 1);
  assert.equal(errors.length, 0);
} finally {
  globalThis.fetch = originalFetch;
  delete globalThis.__playmeshDebuggerServerBrowserMock;
  delete globalThis.__playmeshPreviewDebuggerServerTest;
}

console.log('Playmesh preview debugger server contracts passed.');
