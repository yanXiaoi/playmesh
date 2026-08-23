import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const gdevelopFpsProbeSource = fs.readFileSync(
  new URL(
    "../assets/playmesh-library/public/developer/gdevelop-fps-probe.js",
    import.meta.url,
  ),
  "utf8",
);
const commands = [];
const latencyIntervals = [];
const clearedLatencyIntervals = [];
const appInternalKey = Symbol.for("playmesh.app.internal.v1");
class FakeMediaStream {
  constructor() {
    this.tracks = [];
  }

  getTracks() {
    return [...this.tracks];
  }

  addTrack(track) {
    this.tracks.push(track);
  }
}

class FakePeerConnection {
  constructor(configuration) {
    this.configuration = configuration;
    this.iceGatheringState = "complete";
    this.listeners = new Map();
    this.transceivers = [];
    this.localDescription = null;
    this.closed = false;
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  removeEventListener(type, listener) {
    if (this.listeners.get(type) === listener) this.listeners.delete(type);
  }

  addTransceiver(kind, options) {
    this.transceivers.push({ kind, options });
  }

  async createOffer() {
    return { type: "offer", sdp: "browser-offer" };
  }

  async setLocalDescription(description) {
    this.localDescription = description;
  }

  async setRemoteDescription(description) {
    this.remoteDescription = description;
    queueMicrotask(() => this.listeners.get("track")?.({
      track: { id: "video-track-1", stop() {} },
    }));
  }

  close() {
    this.closed = true;
  }
}

const gameDocumentBody = {
  isConnected: true,
  tabIndex: -1,
  getAttribute() { return null; },
  setAttribute() { this.tabIndex = -1; },
  removeAttribute() {},
  focus() { window.document.activeElement = this; },
};
const gameFocusTarget = {
  isConnected: true,
  focus() { window.document.activeElement = this; },
};
const window = {
  console,
  queueMicrotask,
  setTimeout,
  clearTimeout,
  setInterval(callback, delay) {
    const handle = {
      callback,
      delay,
      unref() {},
    };
    latencyIntervals.push(handle);
    return handle;
  },
  clearInterval(handle) {
    clearedLatencyIntervals.push(handle);
  },
  addEventListener() {},
  __PLAYMESH_APP_OPTIONS__: { fallbackUi: false },
  MediaStream: FakeMediaStream,
  RTCPeerConnection: FakePeerConnection,
  navigator: { userActivation: { isActive: true } },
  document: {
    activeElement: gameFocusTarget,
    body: gameDocumentBody,
    documentElement: { isConnected: true },
  },
  PlaymeshAppBridge: {
    postMessage(rawMessage) {
      const command = JSON.parse(rawMessage);
      commands.push(command);
      let result = null;
      if (command.command === "app.bootstrap") {
        result = {
          _playmeshPlatformUi: {
            locale: "en-US",
            messages: { "sidebar.title": "Game menu" },
          },
          available: true,
          sdkVersion: "3.3.0",
          identity: {
            userId: "u-current-app",
            nickname: "本机玩家",
            source: "playmesh_app",
          },
          capabilityRegistry: [{
            code: "media.camera",
            name: "摄像头",
            apiVersion: "1.0.0",
            methods: [],
            events: [],
          }, {
            code: "device.vibration",
            name: "震动反馈",
            apiVersion: "1.0.0",
            methods: [{ name: "vibrate" }],
            events: [],
          }],
          device: {
            platform: "android",
            capabilities: ["media.camera", "device.vibration"],
            declaredCapabilities: ["media.camera", "device.vibration"],
          },
        };
      } else if (command.command === "app.game.configure") {
        result = {
          capabilityRegistry: [{
            code: "device.vibration",
            name: "震动反馈",
            apiVersion: "1.0.0",
            methods: [{ name: "vibrate" }],
            events: [],
          }],
          device: {
            platform: "android",
            capabilities: ["device.vibration"],
            declaredCapabilities: ["device.vibration"],
          },
        };
      } else if (command.command === "app.lan.discover") {
        result = [{
          instanceId: "discovered-instance-0001",
          gameId: "game.example.lan",
          name: "LAN Game",
          host: "Living room",
        }];
      } else if (command.command === "app.lan.getShareLinks") {
        result = [{
          url: "http://192.168.0.6:42317/playmesh/join#inviteToken=secret",
          type: "lan",
          img: "data:image/png;base64,aW1hZ2U=",
        }, {
          url: "https://relay.example/j/tunnel#inviteToken=secret",
          type: "wan",
          img: "data:image/png;base64,aW1hZ2Uy",
        }];
      } else if (command.command === "app.capability.create") {
        result = {
          instanceId: "capability-1",
          code: command.payload.code,
          apiVersion: "1.0.0",
        };
      } else if (command.command === "app.media.open") {
        result = {
          sessionId: "media-session-1",
          protocol: "webrtc",
          answer: { type: "answer", sdp: "host-answer" },
        };
      }
      queueMicrotask(() => window[appInternalKey].receive({
        type: "app.command.result",
        requestId: command.requestId,
        result,
      }));
    },
  },
};
window.window = window;
vm.runInNewContext(source, window, { filename: "playmesh-app.js" });

const appInternal = window[appInternalKey];
const app = appInternal.publicApi;
assert.equal(window.playmesh, undefined);
assert.equal(window.playmeshApp, undefined);
assert.equal(Object.getOwnPropertyDescriptor(window, appInternalKey).enumerable, false);
assert.deepEqual(Object.keys(app).filter((key) => key.startsWith("__")), []);
const publicBootstrap = await app.ready;
assert.equal("_playmeshPlatformUi" in publicBootstrap, false);
assert.equal("game" in publicBootstrap, false);
assert.deepEqual(
  commands.find((item) => item.command === "app.bootstrap").payload,
  {},
);
assert.equal("__getPlatformUiConfiguration" in app, false);
assert.deepEqual(
  JSON.parse(
    JSON.stringify(appInternal.takePlatformUiConfiguration()),
  ),
  {
    locale: "en-US",
    messages: { "sidebar.title": "Game menu" },
  },
);
assert.equal(app.version, "3.3.0");
assert.equal(app.isAvailable(), true);
assert.equal(app.runtime.getLocale(), "en-US");
assert.equal(app.performance.getFps(), null);
let reportedFps = null;
app.performance.onFps((fps) => {
  reportedFps = fps;
});
for (let frame = 0; frame <= 60; frame += 1) {
  app.performance.reportFrame(frame * (1000 / 60));
}
assert.equal(reportedFps >= 60, true);
const latencyProbes = [];
appInternal.configureRuntimePerformance({
  multiplayer: true,
  sendLatencyProbe(payload) {
    latencyProbes.push(payload);
  },
});
assert.equal(latencyIntervals.length, 1);
assert.equal(latencyIntervals[0].delay, 3000);
assert.equal(latencyProbes.length, 1);
latencyIntervals[0].callback();
assert.equal(latencyProbes.length, 2);
assert.match(latencyProbes[0].probeId, /^latency-\d+-1$/);
assert.match(latencyProbes[1].probeId, /^latency-\d+-2$/);
appInternal.recordRuntimeLatencyPong({
  probeId: "probe-local",
  clientSentAt: Date.now() - 20,
  serverReceivedAt: Date.now() - 10,
  serverSentAt: Date.now() - 5,
  authorityAvailable: true,
});
assert.equal(app.performance.getLatency() >= 0, true);
assert.equal(
  app.performance.getLatencyDiagnostics().authorityAvailable,
  true,
);
assert.equal(
  commands.some((item) => item.command === "performance.fps"),
  false,
);
assert.equal(
  commands.some((item) => item.command === "performance.latency"),
  false,
);
const originalSdkRender = function originalSdkRender() {
  return "rendered";
};
window.gdjs = { RuntimeScene: function RuntimeScene() {} };
window.gdjs.RuntimeScene.prototype.render = originalSdkRender;
window.playmesh = { app };
vm.runInNewContext(gdevelopFpsProbeSource, window, {
  filename: "gdevelop-fps-probe.js",
});
const renderedScene = new window.gdjs.RuntimeScene();
assert.equal(renderedScene.render(), "rendered");
assert.notEqual(
  window.gdjs.RuntimeScene.prototype.render,
  originalSdkRender,
  "GDevelop FPS probe must attach to the real App SDK performance channel",
);
assert.equal(
  commands.some((item) => item.command === "performance.fps"),
  false,
  "GDevelop FPS probe must not create a Dart FPS command channel",
);
window[Symbol.for("playmesh.gdevelop.fps-probe.v1")].dispose();
assert.equal(window.gdjs.RuntimeScene.prototype.render, originalSdkRender);
appInternal.configureRuntimePerformance({ multiplayer: false });
assert.deepEqual(clearedLatencyIntervals, latencyIntervals);
assert.deepEqual(
  JSON.parse(JSON.stringify(app.identity.getCurrent())),
  { userId: "u-current-app", nickname: "本机玩家", source: "playmesh_app" },
);
assert.deepEqual(
  [...app.capabilities.getAvailable()],
  ["media.camera", "device.vibration"],
);
assert.deepEqual(
  [...app.capabilities.getDeclared()],
  ["media.camera", "device.vibration"],
);
const configuredBootstrap = await appInternal.configureRuntimeGame({
  requiredCapabilities: ["device.vibration"],
});
assert.strictEqual(
  configuredBootstrap,
  publicBootstrap,
  "App SDK 运行时配置必须原位更新同一个公开 ready 结果",
);
assert.deepEqual(
  commands.find((item) => item.command === "app.game.configure").payload,
  { declaredCapabilities: ["device.vibration"] },
);
assert.deepEqual(
  JSON.parse(JSON.stringify(publicBootstrap.device.declaredCapabilities)),
  ["device.vibration"],
);
assert.deepEqual(
  [...app.capabilities.getDeclared()],
  ["device.vibration"],
);

const capability = await app.capabilities.create(
  "device.vibration",
  {},
);
await capability.invoke("vibrate", { duration: 250, amplitude: 128 });
await capability.dispose();

const vibration = await app.capabilities.create("device.vibration");
await vibration.invoke("vibrate", {
  pattern: [0, 100, 50, 200],
  intensities: [0, 128, 0, 255],
});
await vibration.invoke("cancel", {});
await vibration.dispose();

const erroredCapability = await app.capabilities.create("device.vibration");
let capabilityError = null;
const removeCapabilityErrorListener = erroredCapability.onError((error) => {
  capabilityError = error;
});
appInternal.receive({
  type: "app.capability.error",
  instanceId: erroredCapability.id,
  code: "speech_recognizer_busy",
  error: "系统语音识别服务正忙",
});
assert.equal(capabilityError?.code, "speech_recognizer_busy");
assert.equal(capabilityError?.message, "系统语音识别服务正忙");
removeCapabilityErrorListener();
await erroredCapability.dispose();

const mediaSource = {
  type: "playmesh.app.media-source",
  version: 1,
  id: "media-source-1",
  kind: "video",
  protocol: "webrtc",
  live: true,
};
const mediaSession = await app.media.open(mediaSource);
assert.equal(mediaSession.id, "media-session-1");
assert.equal(mediaSession.state, "open");
assert.equal(mediaSession.stream.getTracks().length, 1);
const mediaOpen = commands.find((item) => item.command === "app.media.open");
assert.deepEqual(
  JSON.parse(JSON.stringify(mediaOpen.payload.source)),
  mediaSource,
);
assert.deepEqual(
  JSON.parse(JSON.stringify(mediaOpen.payload.adapterOptions)),
  { offer: { type: "offer", sdp: "browser-offer" } },
);
assert.equal("offer" in mediaOpen.payload.source, false);
await mediaSession.close();
assert.equal(
  commands.some((item) =>
    item.command === "app.media.close" &&
    item.payload.sessionId === "media-session-1"),
  true,
);

await app.device.setFullscreen(true, "portrait");
assert.deepEqual(
  commands.find((item) => item.command === "app.device.fullscreen").payload,
  { enabled: true, orientation: "portrait" },
);
assert.equal(commands.some((item) => item.command === "app.capability.create"), true);
assert.equal(commands.some((item) => item.command === "app.capability.invoke"), true);
assert.equal(commands.some((item) => item.command === "app.capability.dispose"), true);

await app.ui.openSharePanel();
assert.deepEqual(
  commands.findLast((item) => item.command === "app.ui.openSharePanel").payload,
  { userActivation: true },
);
assert.equal(app.hideGameSidebar, undefined);
assert.equal(app.onMenuRequest, undefined);
assert.equal(await app.ui.showGameSidebar(), false);
assert.deepEqual(
  JSON.parse(JSON.stringify(app.ui.configure({ fallbackUi: false }))),
  { fallbackUi: false, floatingButton: true },
);
const commandCountBeforeDisablingSystemMenuTriggers = commands.length;
assert.equal(app.ui.disableSystemMenuTriggers(), undefined);
assert.equal(app.ui.disableSystemMenuTriggers(), undefined);
assert.equal(commands.length, commandCountBeforeDisablingSystemMenuTriggers);
assert.equal(app.ui.setSystemMenuTriggersEnabled, undefined);
for (const methodName of [
  "disableSystemMenuTriggers",
  "configure",
  "initializeBrowser",
  "showGameSidebar",
  "onGameMenuOpen",
  "onGameMenuClose",
  "restartGame",
  "openSharePanel",
  "openRuntimeLogs",
  "openGameInfo",
  "enterFullscreen",
  "exitFullscreen",
  "setPerformanceVisible",
  "togglePerformance",
  "exitGame",
]) {
  assert.equal(app[methodName], undefined);
  assert.equal(typeof app.ui[methodName], "function");
}
assert.equal(app.ui.initializeBrowser(), false);

const discoveredGames = await app.lan.discoverGames();
assert.equal(Object.isFrozen(discoveredGames), true);
assert.equal(Object.isFrozen(discoveredGames[0]), true);
assert.deepEqual(
  JSON.parse(JSON.stringify(discoveredGames.map(({ join, ...game }) => game))),
  [{
    instanceId: "discovered-instance-0001",
    gameId: "game.example.lan",
    name: "LAN Game",
    host: "Living room",
  }],
);
assert.equal("url" in discoveredGames[0], false);
assert.equal("inviteToken" in discoveredGames[0], false);
await discoveredGames[0].join();
assert.deepEqual(
  commands.findLast((item) => item.command === "app.lan.joinDiscovered").payload,
  {
    instanceId: "discovered-instance-0001",
    userActivation: true,
  },
);
await app.lan.joinByLink("https://relay.example/j/invitation");
assert.deepEqual(
  commands.findLast((item) => item.command === "app.lan.joinByLink").payload,
  {
    invitationUrl: "https://relay.example/j/invitation",
    userActivation: true,
  },
);
await app.lan.scanQrAndJoin();
assert.deepEqual(
  commands.findLast((item) => item.command === "app.lan.scanQr").payload,
  { userActivation: true },
);
await app.lan.setPublished();
assert.deepEqual(
  commands.findLast((item) => item.command === "app.lan.setPublished").payload,
  {},
);
const shareLinks = await app.lan.getShareLinks();
assert.equal(Object.isFrozen(shareLinks), true);
assert.equal(shareLinks.every(Object.isFrozen), true);
assert.deepEqual(
  JSON.parse(JSON.stringify(shareLinks.map(({ type }) => type))),
  ["lan", "wan"],
);
const lanCommandCountBeforeInvalidArguments = commands.filter(
  (item) => item.command.startsWith("app.lan."),
).length;
for (const operation of [
  () => app.lan.discoverGames(true),
  () => discoveredGames[0].join(false),
  () => app.lan.joinByLink(),
  () => app.lan.joinByLink(""),
  () => app.lan.scanQrAndJoin(false),
  () => app.lan.setPublished(true),
  () => app.lan.setPublished(false),
  () => app.lan.getShareLinks(null),
]) {
  await assert.rejects(operation(), (error) => error?.code === "invalid_argument");
}
assert.equal(
  commands.filter((item) => item.command.startsWith("app.lan.")).length,
  lanCommandCountBeforeInvalidArguments,
);
window.navigator.userActivation.isActive = false;
const lanCommandCountBeforeInactiveBrowserFlag = commands.filter(
  (item) => item.command.startsWith("app.lan."),
).length;
await discoveredGames[0].join();
await app.lan.joinByLink("https://relay.example/j/invitation");
await app.lan.scanQrAndJoin();
assert.equal(
  commands.filter((item) => item.command.startsWith("app.lan.")).length,
  lanCommandCountBeforeInactiveBrowserFlag + 3,
  "公开 SDK 必须把加入请求交给宿主 Bridge 校验原生用户操作",
);
window.navigator.userActivation.isActive = true;
for (const methodName of [
  "discoverGames",
  "joinByLink",
  "scanQrAndJoin",
  "setPublished",
  "getShareLinks",
]) {
  assert.equal(app[methodName], undefined);
  assert.equal(typeof app.lan[methodName], "function");
}
assert.equal(app.lan.setPublishedState, undefined);
assert.equal(app.lan.unpublish, undefined);

await app.ui.exitGame();
assert.equal(commands.some((item) => item.command === "app.game.exit"), true);
await appInternal.requestExit();

function createBootstrapContractWindow(onCommand) {
  const isolatedConsole = {
    debug() {},
    info() {},
    log() {},
    warn() {},
    error() {},
  };
  const isolated = {
    console: isolatedConsole,
    queueMicrotask,
    setTimeout,
    clearTimeout,
    setInterval() {
      return { unref() {} };
    },
    clearInterval() {},
    addEventListener() {},
    __PLAYMESH_APP_OPTIONS__: { fallbackUi: false },
    navigator: { languages: ["zh-CN"], language: "zh-CN" },
    document: {
      activeElement: null,
      body: null,
      documentElement: { isConnected: true },
      addEventListener() {},
    },
  };
  if (onCommand) {
    isolated.PlaymeshAppBridge = {
      postMessage(rawMessage) {
        onCommand(isolated, JSON.parse(rawMessage));
      },
    };
  }
  isolated.window = isolated;
  vm.runInNewContext(source, isolated, { filename: "playmesh-app.js" });
  return isolated;
}

const browserWindow = createBootstrapContractWindow();
const browserApp = browserWindow[appInternalKey].publicApi;
const browserBootstrap = await browserApp.ready;
assert.equal(browserWindow.playmesh, undefined);
assert.equal(browserBootstrap.available, false);
assert.equal(browserBootstrap.sdkVersion, "3.3.0");
assert.equal(browserBootstrap.identity, null);
await assert.rejects(
  browserApp.lan.discoverGames(),
  (error) => error?.code === "app_unavailable",
);

let pendingReadyCommand = null;
const pendingReadyWindow = createBootstrapContractWindow((_, command) => {
  if (command.command === "app.bootstrap") {
    pendingReadyCommand = command;
    return;
  }
  queueMicrotask(() => pendingReadyWindow[appInternalKey].receive({
    type: "app.command.result",
    requestId: command.requestId,
    result: null,
  }));
});
await assert.rejects(
  pendingReadyWindow[appInternalKey].publicApi.lan.discoverGames(),
  (error) => error?.code === "app_not_ready",
);
pendingReadyWindow[appInternalKey].receive({
  type: "app.command.result",
  requestId: pendingReadyCommand.requestId,
  result: {
    available: true,
    sdkVersion: "3.3.0",
    identity: null,
    runtime: null,
    capabilityRegistry: [],
    device: {
      platform: "test",
      capabilities: [],
      declaredCapabilities: [],
    },
  },
});
await pendingReadyWindow[appInternalKey].publicApi.ready;

const failedBridgeWindow = createBootstrapContractWindow(
  (isolated, command) => {
    queueMicrotask(() => isolated[appInternalKey].receive({
      type: "app.command.error",
      requestId: command.requestId,
      code: "bootstrap_failed",
      error: "原生 bootstrap 失败",
    }));
  },
);
await assert.rejects(
  failedBridgeWindow[appInternalKey].publicApi.ready,
  (error) =>
    error?.code === "bootstrap_failed" &&
    error.message === "原生 bootstrap 失败",
);
assert.throws(
  () => failedBridgeWindow[appInternalKey]
    .publicApi.ui.disableSystemMenuTriggers(),
  (error) => error?.code === "app_not_ready",
);
await assert.rejects(
  failedBridgeWindow[appInternalKey].publicApi.lan.discoverGames(),
  (error) => error?.code === "app_not_ready",
);
assert.equal(failedBridgeWindow.playmesh, undefined);

console.log("Playmesh App capability plugin bridge contract passed");
