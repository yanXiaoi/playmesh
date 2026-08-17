import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayRoot = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src'
);
const readOverlay = relativePath =>
  readFile(path.join(overlayRoot, relativePath), 'utf8');
const importSource = source =>
  import(
    `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
  );

const lifecycleSource = await readOverlay(
  'PlaymeshPreview/PlaymeshLocalBrowserSWPreview.js'
);
const executableLifecycleSource = transformFlow(lifecycleSource).replace(
  /import \{ ensureBrowserSWPreviewSession \} from[^;]+;/,
  'const ensureBrowserSWPreviewSession = async () => {};'
);
const lifecycle = await importSource(executableLifecycleSource);

const calls = [];
const activeRegistration = {
  active: {},
  scope: 'http://127.0.0.1:16666/dev/token/gdevelop/',
};
const serviceWorker = {
  register: async url => {
    calls.push(['register', url]);
    return activeRegistration;
  },
  ready: Promise.resolve(activeRegistration),
};
await lifecycle.initializePlaymeshLocalBrowserSWPreview({
  serviceWorker,
  indexedDbAvailable: true,
  documentBaseUri:
    'http://127.0.0.1:16666/dev/token/gdevelop/index.html?locale=zh-CN',
  ensurePreviewSession: async () => calls.push(['session']),
});
assert.deepEqual(calls, [
  [
    'register',
    'http://127.0.0.1:16666/dev/token/gdevelop/service-worker.js',
  ],
  ['session'],
]);

for (const input of [
  { serviceWorker: null, indexedDbAvailable: true },
  { serviceWorker, indexedDbAvailable: false },
]) {
  await assert.rejects(
    lifecycle.initializePlaymeshLocalBrowserSWPreview({
      ...input,
      documentBaseUri: 'http://127.0.0.1/dev/token/gdevelop/',
      ensurePreviewSession: async () => {},
    }),
    /此环境不支持 GDevelop 本地游戏内编辑器预览。不会回退到云端预览。/
  );
}

await assert.rejects(
  lifecycle.initializePlaymeshLocalBrowserSWPreview({
    serviceWorker: {
      register: async () => activeRegistration,
      ready: Promise.resolve({
        active: {},
        scope: 'http://127.0.0.1:16666/',
      }),
    },
    indexedDbAvailable: true,
    documentBaseUri: 'http://127.0.0.1:16666/dev/token/gdevelop/',
    ensurePreviewSession: async () => {},
  }),
  /Service Worker 未在当前 WebIDE 路径激活/
);

const routingSource = await readOverlay(
  'PlaymeshPreview/PlaymeshPreviewLauncherRouting.js'
);
const routing = await importSource(transformFlow(routingSource));
const routeCalls = [];
const exactEmbeddedOptions = { isForInGameEdition: true, marker: {} };
const exactAppOptions = { isForInGameEdition: false, marker: {} };
const localLauncher = {
  immediatelyPreparePreviewWindows: options => {
    routeCalls.push(['local-prepare', options]);
    return ['local-window'];
  },
  launchPreview: async options => routeCalls.push(['local-launch', options]),
};
const gatewayLauncher = {
  immediatelyPreparePreviewWindows: options => {
    routeCalls.push(['gateway-prepare', options]);
    return [];
  },
  launchPreview: async options =>
    routeCalls.push(['gateway-launch', options]),
};
assert.deepEqual(
  routing.preparePlaymeshPreviewWindows({
    options: exactEmbeddedOptions,
    localLauncher,
    gatewayLauncher,
  }),
  ['local-window']
);
await routing.launchPlaymeshPreview({
  previewOptions: exactEmbeddedOptions,
  localLauncher,
  gatewayLauncher,
  ensureLocalPreview: async () => routeCalls.push(['ensure-local']),
});
await routing.launchPlaymeshPreview({
  previewOptions: exactAppOptions,
  localLauncher,
  gatewayLauncher,
  ensureLocalPreview: async () => {
    throw new Error('ordinary preview must not initialize local SW');
  },
});
assert.deepEqual(routeCalls, [
  ['local-prepare', exactEmbeddedOptions],
  ['ensure-local'],
  ['local-launch', exactEmbeddedOptions],
  ['gateway-launch', exactAppOptions],
]);

const routerSource = await readOverlay(
  'PlaymeshPreview/PlaymeshPreviewLauncherRouter.js'
);
assert.match(routerSource, /BrowserSWPreviewLauncher/);
assert.doesNotMatch(routerSource, /BrowserS3PreviewLauncher|BrowserS3FileSystem/);
assert.match(routerSource, /playmeshPreviewDebuggerServer/);
for (const localPreviewSource of [routerSource, lifecycleSource, routingSource]) {
  assert.doesNotMatch(
    localPreviewSource,
    /PlaymeshPreviewAdapter|PlaymeshMultiplayerRuntimeInjection|playmesh-main\.js|playmesh-multiplayer-bridge/,
    'BrowserSW 游戏内预览不得注入 App SDK 或 GDevelop 多人宿主运行层'
  );
}

const debuggerSource = await readOverlay(
  'PlaymeshPreview/PlaymeshPreviewDebuggerServer.js'
);
for (const delegatedMethod of [
  'getExistingEmbeddedGameFrameDebuggerIds',
  'registerEmbeddedGameFrame',
  'unregisterEmbeddedGameFrame',
]) {
  assert.match(
    debuggerSource,
    new RegExp(`browserPreviewDebuggerServer\\.${delegatedMethod}`)
  );
}
assert.match(
  debuggerSource,
  /if \(id !== APP_RUNTIME_DEBUGGER_ID\) \{[\s\S]*browserPreviewDebuggerServer\.sendMessage\(id, message\)/
);

process.stdout.write('GDevelop local Browser SW preview tests passed.\n');
