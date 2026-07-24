import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const commands = [];
const window = {
  console,
  queueMicrotask,
  setTimeout,
  clearTimeout,
  PlaymeshAppBridge: {
    postMessage(rawMessage) {
      const command = JSON.parse(rawMessage);
      commands.push(command);
      let result = null;
      if (command.command === "app.bootstrap") {
        result = {
          available: true,
          sdkVersion: "2.1.0",
          identity: {
            userId: "u-current-app",
            nickname: "本机玩家",
            source: "playmesh_app",
          },
          game: { requiredCapabilities: ["sensor.accelerometer", "device.vibration"] },
          capabilityRegistry: [{
            code: "sensor.accelerometer",
            name: "加速度计",
            apiVersion: "1.0.0",
            methods: [{ name: "start" }, { name: "stop" }],
            events: [{ name: "reading" }],
          }, {
            code: "device.vibration",
            name: "震动反馈",
            apiVersion: "1.0.0",
            methods: [{ name: "vibrate" }],
            events: [],
          }],
          device: {
            platform: "android",
            capabilities: ["sensor.accelerometer", "device.vibration"],
            declaredCapabilities: ["sensor.accelerometer", "device.vibration"],
          },
        };
      } else if (command.command === "app.capability.create") {
        result = {
          instanceId: "capability-1",
          code: "sensor.accelerometer",
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

await window.playmeshApp.ready;
assert.equal(window.playmeshApp.version, "2.1.0");
assert.equal(window.playmeshApp.isAvailable(), true);
assert.deepEqual(
  JSON.parse(JSON.stringify(window.playmeshApp.identity.getCurrent())),
  { userId: "u-current-app", nickname: "本机玩家", source: "playmesh_app" },
);
assert.deepEqual(
  [...window.playmeshApp.capabilities.getAvailable()],
  ["sensor.accelerometer", "device.vibration"],
);
assert.deepEqual(
  [...window.playmeshApp.capabilities.getDeclared()],
  ["sensor.accelerometer", "device.vibration"],
);

const capability = await window.playmeshApp.capabilities.create(
  "sensor.accelerometer",
  { fps: 30 },
);
let reading = null;
capability.on("reading", (value) => { reading = value; });
await capability.invoke("start");
window.playmeshApp.__receive({
  type: "app.capability.event",
  instanceId: "capability-1",
  event: "reading",
  data: { x: 1, y: 2, z: 3, unit: "m/s^2" },
});
assert.equal(reading.unit, "m/s^2");
await capability.dispose();

const vibration = await window.playmeshApp.capabilities.create("device.vibration");
await vibration.invoke("vibrate", { style: "medium" });
await vibration.dispose();
await window.playmeshApp.device.setFullscreen(true, "portrait");
assert.deepEqual(
  commands.find((item) => item.command === "app.device.fullscreen").payload,
  { enabled: true, orientation: "portrait" },
);
assert.equal(commands.some((item) => item.command === "app.capability.create"), true);
assert.equal(commands.some((item) => item.command === "app.capability.invoke"), true);
assert.equal(commands.some((item) => item.command === "app.capability.dispose"), true);

console.log("Playmesh App capability plugin bridge contract passed");
