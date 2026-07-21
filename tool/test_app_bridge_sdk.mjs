import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const commands = [];
const window = {
  queueMicrotask,
  setTimeout,
  clearTimeout,
  PlaymeshAppBridge: {
    postMessage(rawMessage) {
      const command = JSON.parse(rawMessage);
      commands.push(command);
      const result = command.command === "app.bootstrap"
        ? {
            available: true,
            sdkVersion: "1.0.0",
            identity: {
              userId: "u-current-app",
              nickname: "本机玩家",
              source: "playmesh_app",
            },
            device: {
              platform: "android",
              capabilities: ["fullscreen", "haptics"],
            },
          }
        : null;
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

await window.playmeshApp.ready;
assert.equal(window.playmeshApp.version, "1.2.1");
assert.equal(window.playmeshApp.isAvailable(), true);
assert.deepEqual(
  JSON.parse(JSON.stringify(window.playmeshApp.identity.getCurrent())),
  {
    userId: "u-current-app",
    nickname: "本机玩家",
    source: "playmesh_app",
  },
);
assert.deepEqual(
  [...window.playmeshApp.device.getCapabilities()],
  ["fullscreen", "haptics"],
);

await window.playmeshApp.device.haptic("medium");
await window.playmeshApp.device.setFullscreen(false);
assert.equal(commands.some((command) => command.command === "app.device.haptic"), true);
assert.equal(commands.some((command) => command.command === "app.device.fullscreen"), true);

let input = null;
const unsubscribe = window.playmeshApp.device.onInput((value) => { input = value; });
window.playmeshApp.__receive({
  type: "app.device.input",
  input: { type: "axis", code: "left_x", value: 0.5 },
});
assert.equal(input.code, "left_x");
unsubscribe();

console.log("Playmesh App bridge identity and device contract passed");
