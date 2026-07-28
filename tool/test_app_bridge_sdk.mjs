import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const commands = [];
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
          sdkVersion: "3.0.0",
          identity: {
            userId: "u-current-app",
            nickname: "本机玩家",
            source: "playmesh_app",
          },
          game: { requiredCapabilities: ["media.camera", "device.vibration"] },
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
      } else if (command.command === "app.capability.create") {
        result = {
          instanceId: "capability-1",
          code: command.payload.code,
          apiVersion: "1.0.0",
        };
      }
      queueMicrotask(() => window.playmeshApp.__receive({
        type: "app.command.result",
        requestId: command.requestId,
        result,
      }));
    },
  },
};
window.window = window;
vm.runInNewContext(source, window, { filename: "playmesh-app.js" });

const publicBootstrap = await window.playmeshApp.ready;
assert.equal("_playmeshPlatformUi" in publicBootstrap, false);
assert.equal("__getPlatformUiConfiguration" in window.playmeshApp, false);
assert.deepEqual(
  JSON.parse(
    JSON.stringify(
      window[Symbol.for("playmesh.platform-ui.configuration")],
    ),
  ),
  {
    locale: "en-US",
    messages: { "sidebar.title": "Game menu" },
  },
);
assert.equal(window.playmeshApp.version, "3.0.0");
assert.equal(window.playmeshApp.isAvailable(), true);
assert.deepEqual(
  JSON.parse(JSON.stringify(window.playmeshApp.identity.getCurrent())),
  { userId: "u-current-app", nickname: "本机玩家", source: "playmesh_app" },
);
assert.deepEqual(
  [...window.playmeshApp.capabilities.getAvailable()],
  ["media.camera", "device.vibration"],
);
assert.deepEqual(
  [...window.playmeshApp.capabilities.getDeclared()],
  ["media.camera", "device.vibration"],
);

const capability = await window.playmeshApp.capabilities.create(
  "device.vibration",
  {},
);
await capability.invoke("vibrate", { duration: 250, amplitude: 128 });
await capability.dispose();

const vibration = await window.playmeshApp.capabilities.create("device.vibration");
await vibration.invoke("vibrate", {
  pattern: [0, 100, 50, 200],
  intensities: [0, 128, 0, 255],
});
await vibration.invoke("cancel", {});
await vibration.dispose();
await window.playmeshApp.device.setFullscreen(true, "portrait");
assert.deepEqual(
  commands.find((item) => item.command === "app.device.fullscreen").payload,
  { enabled: true, orientation: "portrait" },
);
assert.equal(commands.some((item) => item.command === "app.capability.create"), true);
assert.equal(commands.some((item) => item.command === "app.capability.invoke"), true);
assert.equal(commands.some((item) => item.command === "app.capability.dispose"), true);

window.document.activeElement = gameFocusTarget;
await window.playmeshApp.openSharePanel();
assert.deepEqual(
  commands.findLast((item) => item.command === "app.ui.openSharePanel").payload,
  { userActivation: true },
);
window.document.activeElement = { isConnected: true };
window.playmeshApp.__restoreGameContentFocus();
assert.equal(window.document.activeElement, gameFocusTarget);

window.document.activeElement = gameFocusTarget;
await window.playmeshApp.showGameSidebar();
window.document.activeElement = { isConnected: true };
await window.playmeshApp.hideGameSidebar();
assert.equal(window.document.activeElement, gameFocusTarget);
assert.equal(commands.some((item) => item.command === "app.ui.gameSidebar.show"), true);
assert.equal(commands.some((item) => item.command === "app.ui.gameSidebar.hide"), true);

await window.playmeshApp.exitGame();
assert.equal(commands.some((item) => item.command === "app.game.exit"), true);
await window.playmeshApp.__requestExit();

console.log("Playmesh App capability plugin bridge contract passed");
