import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const appSource = await readFile(
  path.join(root, 'assets/playmesh-library/public/sdk/v1/playmesh-app.js'),
  'utf8'
);
const mainSource = await readFile(
  path.join(root, 'assets/playmesh-library/public/sdk/v1/playmesh-main.js'),
  'utf8'
);
const runtimePath = path.join(
  root,
  'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src/PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection.js'
);
const runtimeSource = await readFile(runtimePath, 'utf8');
const gdevelopRuntime = await import(
  `data:text/javascript;base64,${Buffer.from(runtimeSource).toString('base64')}`
);
const windowsHostSource = await readFile(
  path.join(root, 'lib/features/game/windows_local_game_web_view_io.dart'),
  'utf8'
);
assert.match(windowsHostSource, /WebViewSdkNavigationQueue/);
assert.match(
  windowsHostSource,
  /LoadingState\.loading[\s\S]*?_sdkMessages\.notifyNavigationLoading\(\)/
);
assert.match(
  windowsHostSource,
  /LoadingState\.navigationCompleted[\s\S]*?_resumeSdkMessages\(generation\)/
);
assert.match(
  windowsHostSource,
  /_sdkMessages\.beginNavigation\(\);\s*await _controller\.loadUrl/
);
assert.match(
  windowsHostSource,
  /_sendAppMessage[\s\S]*?_sdkMessages\.addApp/
);
assert.match(windowsHostSource, /_sdkMessages\.addGame[\s\S]*?beforeSend:/);
assert.match(
  windowsHostSource,
  /_resumeSdkMessages[\s\S]*?attempt < 3[\s\S]*?completeNavigation\(generation\)/
);

const manifest = JSON.parse(
  await readFile(path.join(root, 'assets/playmesh-localization/manifest.json'), 'utf8')
);
const locale = manifest.locales.find(item => item.id === 'zh-CN');
const messages = JSON.parse(
  await readFile(path.join(root, 'assets/playmesh-localization', locale.bundles.app), 'utf8')
);
const platformMessages = Object.fromEntries(
  Object.entries(messages)
    .filter(([key]) => key.startsWith('platform.game.'))
    .map(([key, value]) => [key.slice('platform.game.'.length), value])
);

const appTag = '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>';
const mainTag = '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>';
const injectAppLikeGameAssetGateway = html =>
  html.replace(mainTag, `${appTag}${mainTag}`);
const runtimeGame = '<script>new gdjs.RuntimeGame(gdjs.projectData, {});</script>';
const htmlFixtures = new Map([
  [
    'ordinary-body-end',
    injectAppLikeGameAssetGateway(
      `<!doctype html><html><head></head><body>${runtimeGame}${mainTag}</body></html>`
    ),
  ],
  [
    'custom-head-sdk',
    injectAppLikeGameAssetGateway(
      `<!doctype html><html><head>${mainTag}</head><body>${runtimeGame}</body></html>`
    ),
  ],
  [
    'gdevelop-head-sdk',
    injectAppLikeGameAssetGateway(
      gdevelopRuntime.injectMultiplayerCompatibility({
        html: gdevelopRuntime.ensureSdkPlaceholder({
          html: `<!doctype html><html><head><script src="gdjs.js"></script></head><body>${runtimeGame}</body></html>`,
        }),
        activation: 'enabled',
      })
    ),
  ],
]);

const delayTasks = async () => {
  await Promise.resolve();
  await new Promise(resolve => setTimeout(resolve, 5));
  await Promise.resolve();
};

class NavigationHost {
  constructor() {
    this.generation = 0;
    this.appReady = false;
    this.gameReady = false;
    this.appPending = [];
    this.gamePending = [];
    this.commands = [];
    this.deferredAppReplies = [];
  }

  beginNavigation() {
    this.generation += 1;
    this.appReady = false;
    this.gameReady = false;
    this.appPending.length = 0;
    this.gamePending.length = 0;
    return this.generation;
  }

  addApp(deliver, generation) {
    if (generation !== this.generation) return;
    this.appPending.push(deliver);
    if (this.appReady) void this.drain(this.appPending);
  }

  addGame(deliver) {
    this.gamePending.push(deliver);
    if (this.gameReady) void this.drain(this.gamePending);
  }

  async drain(pending) {
    for (;;) {
      while (pending.length) await pending.shift()();
      await Promise.resolve();
      if (!pending.length) return;
    }
  }

  async completeNavigation(generation) {
    if (generation !== this.generation) return;
    this.appReady = true;
    await this.drain(this.appPending);
    if (generation !== this.generation) return;
    this.gameReady = true;
    await this.drain(this.gamePending);
  }

  receive(runtime, label, rawMessage, generation, { deferBootstrap = false } = {}) {
    const command = JSON.parse(rawMessage);
    this.commands.push({ label, command });
    if (command.command.startsWith('app.')) {
      let result = null;
      if (command.command === 'app.bootstrap') {
        result = {
          _playmeshPlatformUi: { locale: 'zh-CN', messages: platformMessages },
          available: true,
          sdkVersion: '3.3.0',
          identity: {
            userId: 'host-1',
            nickname: 'Host',
            source: 'playmesh_app',
          },
          capabilityRegistry: [],
          device: {
            platform: 'windows',
            capabilities: [],
            declaredCapabilities: [],
          },
        };
      } else if (command.command === 'app.game.configure') {
        result = {
          capabilityRegistry: [],
          device: {
            platform: 'windows',
            capabilities: [],
            declaredCapabilities: [],
          },
        };
      }
      const deliver = () => runtime[Symbol.for('playmesh.app.internal.v1')].receive({
        type: 'app.command.result',
        requestId: command.requestId,
        result,
      });
      if (deferBootstrap && command.command === 'app.bootstrap') {
        this.deferredAppReplies.push({ deliver, generation });
      } else {
        this.addApp(deliver, generation);
      }
      return;
    }
    if (command.command === 'sdk.ready') {
      this.addGame(
        () => runtime[Symbol.for('playmesh.main.internal.v1')].receive({
          type: 'sdk.bootstrap',
          requestId: command.requestId,
          sdkVersion: '4.1.0',
          isAuthority: true,
          gameInfo: {
            id: 'com.playmesh.navigation-test',
            name: 'Navigation test',
            tags: [],
            multiplayer: true,
            displayMode: 'multi_screen',
            requiredCapabilities: [],
          },
          player: null,
          session: {
            id: 'shared-session',
            joinCode: 'SHARED',
            state: 'lobby',
            authorityClientId: 'host-1',
            players: [],
            minPlayers: 1,
          },
        })
      );
    }
  }
}

const createPage = ({ host, label, generation, deferBootstrap = false }) => {
  const logs = [];
  const page = {
    console: {
      log(...values) { logs.push(values.map(String).join(' ')); },
      info(...values) { logs.push(values.map(String).join(' ')); },
      warn(...values) { logs.push(values.map(String).join(' ')); },
      error(...values) { logs.push(values.map(String).join(' ')); },
    },
    queueMicrotask,
    setTimeout(callback, delay, ...args) {
      const handle = setTimeout(callback, delay, ...args);
      handle.unref?.();
      return handle;
    },
    clearTimeout,
    setInterval() { return { unref() {} }; },
    clearInterval() {},
    TextEncoder,
    TextDecoder,
    Uint8Array,
    ArrayBuffer,
    DataView,
    Blob,
    URL,
    crypto: webcrypto,
    fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }),
    btoa(value) { return Buffer.from(value, 'binary').toString('base64'); },
    atob(value) { return Buffer.from(value, 'base64').toString('binary'); },
    navigator: {
      languages: ['zh-CN'],
      language: 'zh-CN',
      userActivation: { isActive: true },
    },
    document: {
      readyState: 'loading',
      activeElement: null,
      body: {
        isConnected: true,
        tabIndex: -1,
        getAttribute() { return null; },
        setAttribute() {},
        removeAttribute() {},
        focus() {},
      },
      documentElement: { isConnected: true },
    },
    addEventListener() {},
    removeEventListener() {},
    __PLAYMESH_APP_OPTIONS__: { fallbackUi: false },
  };
  page.chrome = {
    webview: {
      addEventListener() {},
      removeEventListener() {},
      postMessage(message) {
        host.receive(page, label, message, generation, { deferBootstrap });
      },
    },
  };
  page.window = page;
  page.globalThis = page;
  return { page, context: vm.createContext(page), logs };
};

const executeSdkTags = (html, context) => {
  const sources = new Map([
    ['/playmesh/sdk/v1/playmesh-app.js', appSource],
    ['/playmesh/sdk/v1/playmesh-main.js', mainSource],
  ]);
  for (const match of html.matchAll(/<script src="([^"]+)"><\/script>/g)) {
    const source = sources.get(match[1]);
    if (source) vm.runInContext(source, context, { filename: match[1] });
  }
};

for (const [label, html] of htmlFixtures) {
  assert.equal(html.split(appTag).length - 1, 1);
  assert.equal(html.split(mainTag).length - 1, 1);
  assert.ok(html.indexOf(appTag) < html.indexOf(mainTag));
  const host = new NavigationHost();
  const generation = host.beginNavigation();
  const runtime = createPage({ host, label, generation });
  executeSdkTags(html, runtime.context);
  await delayTasks();
  assert.equal(
    host.commands.filter(item => item.label === label && item.command.command === 'app.bootstrap').length,
    1
  );
  assert.equal(
    host.commands.filter(item => item.label === label && item.command.command === 'sdk.ready').length,
    0,
    `${label}: Main must wait for the queued App reply`
  );
  runtime.page.document.readyState = 'complete';
  await host.completeNavigation(generation);
  await delayTasks();
  const ready = await runtime.page.playmesh.ready;
  assert.equal(ready.app.sdkVersion, '3.3.0');
  assert.equal(ready.main.sdkVersion, '4.1.0');
  assert.equal(
    host.commands.filter(item => item.label === label && item.command.command === 'app.bootstrap').length,
    1
  );
  assert.equal(
    host.commands.filter(item => item.label === label && item.command.command === 'sdk.ready').length,
    1
  );
  assert.ok(runtime.logs.some(line => line.includes('Playmesh App SDK 就绪')));
  assert.ok(runtime.logs.some(line => line.includes('Playmesh Game SDK 请求宿主就绪')));
}

const reloadHost = new NavigationHost();
const oldGeneration = reloadHost.beginNavigation();
const oldPage = createPage({
  host: reloadHost,
  label: 'reload-old',
  generation: oldGeneration,
  deferBootstrap: true,
});
executeSdkTags(htmlFixtures.get('custom-head-sdk'), oldPage.context);
await delayTasks();
const newGeneration = reloadHost.beginNavigation();
const newPage = createPage({
  host: reloadHost,
  label: 'reload-new',
  generation: newGeneration,
});
executeSdkTags(htmlFixtures.get('custom-head-sdk'), newPage.context);
for (const deferred of reloadHost.deferredAppReplies.splice(0)) {
  reloadHost.addApp(deferred.deliver, deferred.generation);
}
await reloadHost.completeNavigation(oldGeneration);
await reloadHost.completeNavigation(newGeneration);
await delayTasks();
const reloadedReady = await newPage.page.playmesh.ready;
assert.equal(reloadedReady.main.sdkVersion, '4.1.0');
assert.equal(
  reloadHost.commands.filter(item => item.label === 'reload-old' && item.command.command === 'sdk.ready').length,
  0,
  'an old App reply must not wake the old Main SDK after a reload'
);
assert.equal(
  reloadHost.commands.filter(item => item.label === 'reload-new' && item.command.command === 'app.bootstrap').length,
  1
);
assert.equal(
  reloadHost.commands.filter(item => item.label === 'reload-new' && item.command.command === 'sdk.ready').length,
  1
);

process.stdout.write(
  'Windows WebView SDK navigation queue: body/head/GDevelop and reload contracts passed.\n'
);
