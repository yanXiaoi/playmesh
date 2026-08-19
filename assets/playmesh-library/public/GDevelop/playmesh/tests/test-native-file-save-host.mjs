import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const readRepositoryFile = relativePath =>
  readFile(path.join(repositoryRoot, relativePath), 'utf8');

const [
  bridgeDart,
  workspaceDart,
  windowsWebViewDart,
  serviceDart,
  sourcePolicy,
] = await Promise.all([
  readRepositoryFile('lib/core/developer/developer_native_file_save.dart'),
  readRepositoryFile('lib/features/developer/developer_workspace_page.dart'),
  readRepositoryFile('lib/features/game/windows_local_game_web_view_io.dart'),
  readRepositoryFile(
    'lib/core/developer/developer_native_file_save_service_io.dart'
  ),
  readRepositoryFile(
    'assets/playmesh-library/public/GDevelop/playmesh/scripts/apply-source-policy.mjs'
  ),
]);

const scriptMatch = bridgeDart.match(
  /const String playmeshNativeFileSaveScript = r'''([\s\S]*?)''';/
);
assert.ok(
  scriptMatch,
  'the native file save document-created script must exist'
);
const bridgeScript = scriptMatch[1];

const stagedBlob = new Blob(['portable-game'], {
  type: 'application/zip',
});
let stageRequest = null;
let resolveMessage;
const messageReceived = new Promise(resolve => {
  resolveMessage = resolve;
});
const context = vm.createContext({
  Blob,
  URL,
  Promise,
  Date,
  location: new URL('http://127.0.0.1:16666/dev/session/gdevelop/'),
  console: { error() {} },
  chrome: {
    webview: {
      postMessage(rawMessage) {
        resolveMessage(rawMessage);
      },
    },
  },
  async fetch(input, init) {
    if (String(input).startsWith('blob:')) {
      return {
        ok: true,
        status: 200,
        blob: async () => stagedBlob,
      };
    }
    stageRequest = { url: String(input), init };
    return {
      ok: true,
      status: 201,
      json: async () => ({
        requestId: 'dev-gateway-request',
        protocolVersion: 1,
        transferId: 'abcdefghijklmnopqrstuvwx',
        downloadPath:
          '/dev/api/gdevelop/native-file-saves/abcdefghijklmnopqrstuvwx',
        filename: 'game.zip',
        mimeType: 'application/zip',
        size: stagedBlob.size,
      }),
    };
  },
});
vm.runInContext(bridgeScript, context);
assert.equal(
  typeof context.__playmeshSaveBlobDownload,
  'function',
  'Windows WebView must receive the host hook at document creation'
);
const nativeSaveCompletion = context.__playmeshSaveBlobDownload({
  url: 'blob:playmesh-native-save-fixture',
  filename: 'game.zip',
});
assert.equal(
  typeof nativeSaveCompletion?.then,
  'function',
  'the native hook must expose when it has finished consuming the Blob URL'
);
const readyEnvelope = JSON.parse(await messageReceived);
await nativeSaveCompletion;
assert.equal(readyEnvelope.__playmeshNativeFileSave.kind, 'ready');
assert.match(
  readyEnvelope.__playmeshNativeFileSave.requestId,
  /^save-[a-z0-9-]+$/,
  'the client save-* id must survive a Gateway receipt containing dev-* requestId'
);
assert.notEqual(
  readyEnvelope.__playmeshNativeFileSave.requestId,
  'dev-gateway-request'
);
assert.equal(
  stageRequest.url,
  'http://127.0.0.1:16666/dev/api/gdevelop/native-file-saves'
);
assert.equal(stageRequest.init.credentials, 'same-origin');
assert.equal(stageRequest.init.body, stagedBlob);

const ordinaryBrowserContext = vm.createContext({
  URL,
  Promise,
  Date,
  location: new URL('https://editor.example.test/'),
  console: { error() {} },
  fetch: async () => {
    throw new Error('ordinary browsers must not use the native host script');
  },
});
vm.runInContext(bridgeScript, ordinaryBrowserContext);
assert.equal(
  ordinaryBrowserContext.__playmeshSaveBlobDownload,
  undefined,
  'without a native message channel the host hook must not be installed'
);

assert.match(
  workspaceDart,
  /additionalDocumentCreatedScripts:\s*const \[[\s\S]*?playmeshNativeFileSaveScript,[\s\S]*?\]/
);
assert.match(
  workspaceDart,
  /onWebMessage:[\s\S]*?_handleNativeFileSaveWebMessage\(message\)/
);
assert.ok(
  windowsWebViewDart.indexOf('addScriptToExecuteOnDocumentCreated(script)') <
    windowsWebViewDart.indexOf('_controller.loadUrl('),
  'the save hook must be registered before the first navigation'
);
assert.ok(
  windowsWebViewDart.indexOf('widget.onWebMessage?.call(message)') <
    windowsWebViewDart.indexOf('widget.appBridge?.handleJavaScriptMessage'),
  'native file-save receipts must be offered to the workspace before SDK routing'
);
assert.match(serviceDart, /getSaveLocation\(/);
assert.match(serviceDart, /await _download\(/);
assert.match(
  sourcePolicy,
  /chromeWebView[\s\S]*?native_file_save_bridge_missing[\s\S]*?window\.alert\(message\)/,
  'a Playmesh WebView without the injected hook must show a visible error'
);
const visibleGuardIndex = sourcePolicy.indexOf('window.alert(message)');
assert.ok(
  sourcePolicy.indexOf('const { body } = document;`', visibleGuardIndex) >
    visibleGuardIndex,
  'the transform must rejoin the official ordinary-browser anchor boundary'
);

process.stdout.write('Native file save host bridge contracts passed.\n');
