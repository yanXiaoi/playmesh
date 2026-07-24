import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const commands = [];
const binaryFrames = [];
const uploads = [];
const binaryChannelBytes = Uint8Array.from({ length: 16 }, (_, index) => index + 1);

function parseBinarySend(frame) {
  assert.equal(frame[1], 0x04);
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const flags = frame[22];
  const targetField = view.getUint16(23);
  const targetPlayerIds = [];
  let offset = 25;
  if (flags & 4) {
    assert.equal(targetField, 0);
  } else if (flags & 2) {
    for (let index = 0; index < targetField; index += 1) {
      const targetLength = view.getUint16(offset);
      offset += 2;
      targetPlayerIds.push(new TextDecoder().decode(frame.subarray(offset, offset + targetLength)));
      offset += targetLength;
    }
  } else {
    targetPlayerIds.push(new TextDecoder().decode(frame.subarray(offset, offset + targetField)));
    offset += targetField;
  }
  return {
    flags,
    targetPlayerIds,
    payload: [...frame.subarray(offset)],
  };
}

class MockFile {
  constructor(bytes, name) {
    this.bytes = bytes;
    this.name = name;
    this.size = bytes.length;
  }
}

class MockWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances = [];

  constructor(url) {
    MockWebSocket.last = this;
    MockWebSocket.instances.push(this);
    this.url = url;
    this.readyState = MockWebSocket.CONNECTING;
    this.bufferedAmount = 0;
    this.listeners = new Map();
    setTimeout(() => {
      this.readyState = MockWebSocket.OPEN;
      this.emit("open", {});
    }, 0);
  }

  addEventListener(type, listener, options = {}) {
    const wrapped = options.once
      ? (event) => {
          this.removeEventListener(type, wrapped);
          listener(event);
        }
      : listener;
    const listeners = this.listeners.get(type) || [];
    listeners.push(wrapped);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    this.listeners.set(
      type,
      (this.listeners.get(type) || []).filter((candidate) => candidate !== listener),
    );
  }

  emit(type, event) {
    for (const listener of [...(this.listeners.get(type) || [])]) listener(event);
  }

  receive(data) {
    this.emit("message", { data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) });
  }

  send(raw) {
    const data = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
    binaryFrames.push(new Uint8Array(data));
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const operation = data[1];
    if (operation === 0x01 || operation === 0x02) {
      const response = new Uint8Array(24);
      response[0] = 1;
      response[1] = 0x81;
      new DataView(response.buffer).setUint32(2, view.getUint32(2));
      response[6] = 0;
      response[7] = operation === 0x01 ? data[6] : 1;
      response.set(binaryChannelBytes, 8);
      setTimeout(() => this.receive(response), 0);
    } else if (operation === 0x03 || operation === 0x04) {
      const response = new Uint8Array(7);
      response[0] = 1;
      response[1] = 0x81;
      new DataView(response.buffer).setUint32(2, view.getUint32(2));
      response[6] = 0;
      setTimeout(() => this.receive(response), 0);
    }
  }

  close() {
    if (this.readyState >= MockWebSocket.CLOSING) return;
    this.readyState = MockWebSocket.CLOSING;
    setTimeout(() => {
      this.readyState = MockWebSocket.CLOSED;
      this.emit("close", {});
    }, 0);
  }
}

globalThis.window = {
  setInterval,
  clearInterval,
  setTimeout,
  clearTimeout,
  WebSocket: MockWebSocket,
  TextEncoder,
  TextDecoder,
  Uint8Array,
  ArrayBuffer,
  DataView,
  File: MockFile,
  async fetch(url, options) {
    uploads.push({ url, options });
    return {
      ok: true,
      async json() {
        return { url: "/bucket/fishing_save/1777777777777.bin" };
      },
    };
  },
  btoa(value) {
    return Buffer.from(value, "binary").toString("base64");
  },
  atob(value) {
    return Buffer.from(value, "base64").toString("binary");
  },
  addEventListener() {},
  playmeshApp: {
    ready: Promise.resolve({
      available: true,
      game: {
        name: "角色能力测试",
        requiredCapabilities: [
          "sensor.accelerometer",
          "sensor.gyroscope",
          "device.vibration",
        ],
      },
      capabilityRegistry: [],
      device: {
        platform: "windows",
        capabilities: [],
        declaredCapabilities: [],
      },
    }),
    isAvailable() {
      return true;
    },
    capabilities: {
      getRegistry() {
        return [];
      },
      getAvailable() {
        return [];
      },
      getDeclared() {
        return [];
      },
    },
    device: {
      getPlatform() {
        return "windows";
      },
      setFullscreen() {
        return Promise.resolve();
      },
      onInput() {
        return () => {};
      },
    },
  },
  PlaymeshBridge: {
    postMessage(message) {
      const command = JSON.parse(message);
      commands.push(command);
      if (command.command === "sdk.ready") {
        window.playmesh.__receive(JSON.stringify({
          type: "sdk.bootstrap",
          requestId: command.requestId,
          sdkVersion: "1.0.0",
          isAuthority: true,
          player: null,
          binaryTransport: { url: "ws://127.0.0.1/binary?token=secret" },
          session: {
            id: "s-1", joinCode: "ABC123", state: "lobby",
            authorityClientId: "p-authority", players: [], minPlayers: 2,
          },
        }));
      } else if (command.command === "performance.ping") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
        window.playmesh.__receive({
          type: "transport.message",
          message: {
            type: "session.pong",
            payload: {
              ...command.payload,
              authorityAvailable: true,
              serverReceivedAt: command.payload.clientSentAt,
              serverSentAt: command.payload.clientSentAt,
            },
          },
        });
      } else if (command.command === "authority.result") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "lifecycle.complete" || command.command === "performance.latency") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "session.finish") {
        window.playmesh.__receive({
          type: "command.result",
          requestId: command.requestId,
          result: { ...window.playmesh.session.getCurrent(), state: "stopped" },
        });
      }
    },
  },
};

const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh.js", import.meta.url), "utf8");
vm.runInThisContext(source, { filename: "playmesh.js" });

await new Promise((resolve) => setTimeout(resolve, 0));
const readyCommand = commands.shift();
assert.equal(readyCommand.command, "sdk.ready");
const sdkBootstrap = await window.playmesh.ready;
assert.equal(sdkBootstrap.binaryTransport, undefined);
assert.equal(window.playmesh.session.isAuthority(), true);
assert.equal(window.playmesh.player.getCurrent(), null);
assert.equal(window.playmesh.session.getCurrent().joinCode, "ABC123");
assert.equal(window.playmesh.version, "2.2.1");
assert.equal((await window.playmesh.session.finish()).state, "stopped");
assert.equal(window.playmesh.performance.getLatency() >= 0, true);
assert.equal(
  window.playmesh.performance.getLatencyDiagnostics().authorityAvailable,
  true,
);
await assert.rejects(
  window.playmesh.player.setNickname("App 玩家"),
  /仅适用于浏览器玩家/,
);

const binaryChannel = await window.playmesh.binary.createChannel({
  mode: "authority",
});
assert.equal(binaryChannel.mode, "authority");
assert.equal(typeof binaryChannel.id, "string");

let binaryDelivery = null;
binaryChannel.onMessage((data, context) => {
  binaryDelivery = { data: [...data], context };
});
binaryChannel.onForward((data, context) => {
  assert.deepEqual([...data], [1, 2, 3]);
  assert.equal(context.senderPlayerId, "p-guest");
  assert.deepEqual(context.targetPlayerIds, ["p-authority", "p-guest"]);
  return new Uint8Array([9, 8, 7]);
});

const review = new Uint8Array(31 + 7 + 2 + 11 + 2 + 7 + 3);
review[0] = 1;
review[1] = 0x83;
review.set(Uint8Array.from([0, 0, 0, 0, 0, 0, 0, 5]), 2);
review.set(binaryChannelBytes, 10);
review[26] = 3;
new DataView(review.buffer).setUint16(27, 7);
new DataView(review.buffer).setUint16(29, 2);
review.set(new TextEncoder().encode("p-guest"), 31);
new DataView(review.buffer).setUint16(38, 11);
review.set(new TextEncoder().encode("p-authority"), 40);
new DataView(review.buffer).setUint16(51, 7);
review.set(new TextEncoder().encode("p-guest"), 53);
review.set(Uint8Array.from([1, 2, 3]), 60);
MockWebSocket.last?.receive(review);

await new Promise((resolve) => setTimeout(resolve, 10));
const decision = binaryFrames.findLast((frame) => frame[1] === 0x05);
assert.ok(decision, "Authority 审核结果应通过 Binary WebSocket 返回");
assert.equal(decision[10], 2);
assert.deepEqual([...decision.subarray(11)], [9, 8, 7]);

const delivery = new Uint8Array(21 + 7 + 2);
delivery[0] = 1;
delivery[1] = 0x82;
delivery.set(binaryChannelBytes, 2);
delivery[18] = 1;
new DataView(delivery.buffer).setUint16(19, 7);
delivery.set(new TextEncoder().encode("p-guest"), 21);
delivery.set(Uint8Array.from([4, 5]), 28);
MockWebSocket.last?.receive(delivery);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.deepEqual(binaryDelivery.data, [4, 5]);
assert.equal(binaryDelivery.context.delivery, "latest");

const latestOne = binaryChannel.sendLatest("p-guest", new Uint8Array([1]));
const latestTwo = binaryChannel.sendLatest("p-guest", new Uint8Array([2]));
await Promise.all([latestOne, latestTwo]);
const sentLatest = binaryFrames.filter((frame) => frame[1] === 0x04);
assert.equal(sentLatest.length, 1);
assert.equal(sentLatest[0].at(-1), 2);

let binarySendOffset = binaryFrames.length;
await binaryChannel.send(["p-authority", "p-guest"], new Uint8Array([3, 4]));
let newBinarySends = binaryFrames.slice(binarySendOffset).filter((frame) => frame[1] === 0x04);
assert.equal(newBinarySends.length, 1);
assert.deepEqual(parseBinarySend(newBinarySends[0]), {
  flags: 2,
  targetPlayerIds: ["p-authority", "p-guest"],
  payload: [3, 4],
});

binarySendOffset = binaryFrames.length;
const multiLatestOne = binaryChannel.sendLatest(
  ["p-authority", "p-guest"],
  new Uint8Array([5]),
);
const multiLatestTwo = binaryChannel.sendLatest(
  ["p-authority", "p-guest"],
  new Uint8Array([6]),
);
await Promise.all([multiLatestOne, multiLatestTwo]);
newBinarySends = binaryFrames.slice(binarySendOffset).filter((frame) => frame[1] === 0x04);
assert.equal(newBinarySends.length, 1);
assert.deepEqual(parseBinarySend(newBinarySends[0]), {
  flags: 3,
  targetPlayerIds: ["p-authority", "p-guest"],
  payload: [6],
});

binarySendOffset = binaryFrames.length;
await binaryChannel.send(new Uint8Array([7, 8]));
newBinarySends = binaryFrames.slice(binarySendOffset).filter((frame) => frame[1] === 0x04);
assert.equal(newBinarySends.length, 1);
assert.deepEqual(parseBinarySend(newBinarySends[0]), {
  flags: 4,
  targetPlayerIds: [],
  payload: [7, 8],
});

binarySendOffset = binaryFrames.length;
const broadcastLatestOne = binaryChannel.sendLatest(new Uint8Array([9]));
const broadcastLatestTwo = binaryChannel.sendLatest(new Uint8Array([10]));
await Promise.all([broadcastLatestOne, broadcastLatestTwo]);
newBinarySends = binaryFrames.slice(binarySendOffset).filter((frame) => frame[1] === 0x04);
assert.equal(newBinarySends.length, 1);
assert.deepEqual(parseBinarySend(newBinarySends[0]), {
  flags: 5,
  targetPlayerIds: [],
  payload: [10],
});

let reportedFps = null;
window.playmesh.performance.onFps((fps) => { reportedFps = fps; });
for (let frame = 0; frame <= 60; frame += 1) {
  window.playmesh.performance.reportFrame(frame * (1000 / 60));
}
assert.equal(reportedFps >= 60, true);
const fpsCommand = commands.findLast((command) => command.command === "performance.fps");
assert.equal(fpsCommand.payload.fps, reportedFps);
window.playmesh.__receive({
  type: "command.result", requestId: fpsCommand.requestId, result: null,
});

let pauseCalls = 0;
window.playmesh.lifecycle.onPause(() => { pauseCalls += 1; });
window.playmesh.__receive({ type: "lifecycle.event", event: "pause" });
assert.equal(pauseCalls, 1);

const bucket = window.playmesh.storage.getBucket("fishing_save");
assert.equal(bucket.flush, undefined);
const uploadedUrl = await bucket.upload(
  new MockFile(Uint8Array.from([0, 255, 7]), "snapshot.bin"),
);
assert.equal(uploadedUrl, "/bucket/fishing_save/1777777777777.bin");
assert.equal(uploads[0].url, "/bucket/fishing_save?name=snapshot.bin");
assert.equal(uploads[0].options.method, "POST");
assert.deepEqual([...uploads[0].options.body.bytes], [0, 255, 7]);
const setOperation = bucket.setData("coins", 9);
const setCommand = commands.findLast((command) => command.command === "storage.set");
assert.equal(setCommand.payload.bucket, "fishing_save");
assert.equal(setCommand.payload.value, 9);
window.playmesh.__receive({
  type: "command.result", requestId: setCommand.requestId, result: null,
});
await setOperation;
assert.throws(() => window.playmesh.storage.getBucket("../save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("bad.bucket"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("_save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("-save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("存档"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("save\n"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket(`a${"b".repeat(64)}`), /无效的 bucket/);

let received = null;
window.playmesh.game.onMessage((message) => { received = message; });
window.playmesh.__receive({
  type: "transport.message",
  message: { type: "game.message", payload: { type: "answer.result", correct: true } },
});
assert.equal(received.correct, true);

window.playmesh.authority.onService((action, context) => ({
  targetPlayerIds: [context.senderPlayerId],
  message: { type: "echo", action },
}));
window.playmesh.__receive({
  type: "transport.message",
  message: {
    type: "authority.action", senderPlayerId: "p-guest", payload: { type: "ping" },
    session: { players: [{ id: "p-host" }, { id: "p-guest" }] },
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
const authorityResult = commands.find((command) => command.command === "authority.result");
assert.deepEqual(authorityResult.targetPlayerIds, ["p-guest"]);
assert.equal(authorityResult.payload.type, "echo");

const syncController = window.playmesh.sync.startAuthority({
  initialState: { score: 0 },
  tickRate: 1,
  onInput(input, context) {
    assert.equal(context.inputType, "action");
    return { score: context.state.score + input.points };
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(window.playmesh.sync.getSnapshot().state.score, 0);
window.playmesh.__receive({
  type: "transport.message",
  message: {
    type: "authority.action",
    senderPlayerId: "p-guest",
    payload: {
      __playmeshSync: {
        type: "input.action", inputId: "input-1", payload: { points: 3 },
      },
    },
    session: {
      authorityClientId: "p-authority",
      players: [{ id: "p-authority" }, { id: "p-guest" }],
    },
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
await syncController.publish();
assert.equal(syncController.getState().score, 3);
assert.equal(window.playmesh.sync.getSnapshot().state.score, 3);
syncController.stop();
const disconnectedBinarySocket = MockWebSocket.last;
disconnectedBinarySocket.close();
while (MockWebSocket.last === disconnectedBinarySocket) {
  await new Promise((resolve) => setTimeout(resolve, 5));
}
await binaryChannel.send("p-guest", new Uint8Array([11]));
assert.equal(MockWebSocket.instances.length >= 2, true);

window.playmesh.__receive({
  type: "lifecycle.event",
  event: "exit",
  requestId: "test-exit",
});

console.log("Game SDK bridge and Binary reconnect contract passed");
