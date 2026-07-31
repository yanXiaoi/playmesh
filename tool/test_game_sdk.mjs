import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const commands = [];
const binaryFrames = [];
const uploads = [];
const appInternalKey = Symbol.for("playmesh.app.internal.v1");
const mainInternalKey = Symbol.for("playmesh.main.internal.v1");
const receiveMain = (message) => window[mainInternalKey].receive(message);
const binaryChannelBytes = Uint8Array.from({ length: 16 }, (_, index) => index + 1);
const localizationManifest = JSON.parse(
  fs.readFileSync(
    new URL("../assets/playmesh-localization/manifest.json", import.meta.url),
    "utf8",
  ),
);
const localizationMessages = new Map(
  localizationManifest.locales.map((locale) => {
    const appMessages = JSON.parse(
      fs.readFileSync(
        new URL(`../assets/playmesh-localization/${locale.bundles.app}`, import.meta.url),
        "utf8",
      ),
    );
    return [
      locale.id,
      Object.fromEntries(
        Object.entries(appMessages)
          .filter(([key]) => key.startsWith("platform.game."))
          .map(([key, value]) => [key.slice("platform.game.".length), value]),
      ),
    ];
  }),
);

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

const gameDocumentBody = {
  isConnected: true,
  tabIndex: -1,
  attributes: new Map(),
  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  },
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === "tabindex") this.tabIndex = Number(value);
  },
  removeAttribute(name) {
    this.attributes.delete(name);
    if (name === "tabindex") this.tabIndex = -1;
  },
  focus() {
    window.document.activeElement = this;
  },
};
const gameFocusTarget = {
  isConnected: true,
  focus() {
    window.document.activeElement = this;
  },
};
const appReadyBootstrap = {
  available: true,
  sdkVersion: "3.2.0",
  capabilityRegistry: [],
  device: {
    platform: "windows",
    capabilities: [],
    declaredCapabilities: [],
  },
};
let appReadyThenCount = 0;
let resolveAppReady;
const appReadyPromise = new Promise((resolve) => {
  resolveAppReady = resolve;
});
const appReadyThenable = {
  then(resolve, reject) {
    appReadyThenCount += 1;
    return appReadyPromise.then(resolve, reject);
  },
};
const appPublicApi = {
  version: "3.2.0",
  ready: appReadyThenable,
  isAvailable() {
    return true;
  },
  runtime: Object.freeze({
    getLocale() {
      return "zh-CN";
    },
  }),
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
};
let appPlatformUiConfiguration = {
  locale: localizationManifest.defaultLocale,
  messages: localizationMessages.get(localizationManifest.defaultLocale),
};
const appInternalRuntime = {
  publicApi: appPublicApi,
  takePlatformUiConfiguration() {
    const value = appPlatformUiConfiguration;
    appPlatformUiConfiguration = null;
    return value;
  },
  restoreGameContentFocus() {},
};

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
  navigator: {
    languages: ["zh-CN"],
    language: "zh-CN",
    userActivation: { isActive: true },
  },
  document: {
    activeElement: gameFocusTarget,
    body: gameDocumentBody,
    documentElement: { isConnected: true },
  },
  [appInternalKey]: appInternalRuntime,
  PlaymeshBridge: {
    postMessage(message) {
      const command = JSON.parse(message);
      commands.push(command);
      if (command.command === "sdk.ready") {
        receiveMain(JSON.stringify({
          type: "sdk.bootstrap",
          requestId: command.requestId,
          sdkVersion: "4.0.0",
          isAuthority: true,
          player: null,
          binaryTransport: { url: "ws://127.0.0.1/binary?token=secret" },
          session: {
            id: "s-1", joinCode: "ABC123", state: "lobby",
            authorityClientId: "p-authority",
            players: [{
              id: "p-guest",
              nickname: "Guest",
              avatar: null,
              role: "player",
              connected: true,
              source: "lan_html",
              latencyMs: 18,
            }],
            minPlayers: 2,
          },
        }));
      } else if (command.command === "performance.ping") {
        receiveMain({
          type: "command.result", requestId: command.requestId, result: null,
        });
        receiveMain({
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
        receiveMain({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "lifecycle.complete") {
        receiveMain({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "session.finish") {
        const current = window.playmesh.main.session.getCurrent();
        receiveMain({
          type: "command.result",
          requestId: command.requestId,
          result: {
            ...current,
            state: "stopped",
            players: current.players.map((player) => ({
              ...player,
              source: "lan_html",
              latencyMs: 21,
            })),
          },
        });
      }
    },
  },
};

const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh-main.js", import.meta.url), "utf8");
vm.runInThisContext(source, { filename: "playmesh-main.js" });

await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(appReadyThenCount, 1);
assert.equal(
  commands.length,
  0,
  "main initialization must not start before playmesh.app.ready",
);
resolveAppReady(appReadyBootstrap);
await new Promise((resolve) => setTimeout(resolve, 0));
const readyCommand = commands.shift();
assert.equal(readyCommand.command, "sdk.ready");
const sdkBootstrap = await window.playmesh.ready;
assert.equal(
  appReadyThenCount,
  1,
  "playmesh.ready must reuse main.ready's single app.ready dependency",
);
assert.strictEqual(
  sdkBootstrap.app,
  appReadyBootstrap,
  "playmesh.ready.app must be the exact playmesh.app.ready result",
);
assert.equal(sdkBootstrap.binaryTransport, undefined);
assert.equal(JSON.stringify(sdkBootstrap).includes("toolbar.expand"), false);
assert.equal(window.playmesh.app.runtime.getLocale(), "zh-CN");
assert.equal("messages" in window.playmesh.app.runtime, false);
assert.equal(window.playmeshApp, undefined);
assert.equal(Object.getOwnPropertyDescriptor(window, mainInternalKey).enumerable, false);
assert.deepEqual(Object.keys(window.playmesh.main).filter((key) => key.startsWith("__")), []);
assert.equal(window.playmesh.main.session.isAuthority(), true);
assert.equal(window.playmesh.main.player.getCurrent(), null);
assert.equal(window.playmesh.main.session.getCurrent().joinCode, "ABC123");
assert.deepEqual(
  Object.keys(window.playmesh.main.session.getCurrent().players[0]).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.equal(window.playmesh.main.version, "4.0.0");
assert.deepEqual(Object.keys(window.playmesh).sort(), ["app", "main", "ready"]);
assert.equal(sdkBootstrap.main.sdkVersion, "4.0.0");
assert.equal(sdkBootstrap.app.sdkVersion, "3.2.0");
const unrelatedPlatformFocusTarget = { isConnected: true };
window.document.activeElement = unrelatedPlatformFocusTarget;
receiveMain({ type: "platform.ui.restoreGameFocus" });
assert.equal(
  window.document.activeElement,
  unrelatedPlatformFocusTarget,
  "a host restore without an SDK share capture must not steal focus",
);
const finishedSession = await window.playmesh.main.session.finish();
assert.equal(finishedSession.state, "stopped");
assert.equal("source" in finishedSession.players[0], false);
assert.equal("latencyMs" in finishedSession.players[0], false);
await assert.rejects(
  window.playmesh.main.player.setNickname("App 玩家"),
  /仅适用于浏览器玩家/,
);

const binaryChannel = await window.playmesh.main.binary.createChannel({
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

let pauseCalls = 0;
window.playmesh.main.lifecycle.onPause(() => { pauseCalls += 1; });
receiveMain({ type: "lifecycle.event", event: "pause" });
assert.equal(pauseCalls, 1);

const bucket = window.playmesh.main.storage.getBucket("fishing_save");
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
receiveMain({
  type: "command.result", requestId: setCommand.requestId, result: null,
});
await setOperation;
assert.throws(() => window.playmesh.main.storage.getBucket("../save"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket("bad.bucket"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket("_save"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket("-save"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket("存档"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket("save\n"), /无效的 bucket/);
assert.throws(() => window.playmesh.main.storage.getBucket(`a${"b".repeat(64)}`), /无效的 bucket/);

let received = null;
window.playmesh.main.game.onMessage((message) => { received = message; });
receiveMain({
  type: "transport.message",
  message: { type: "game.message", payload: { type: "answer.result", correct: true } },
});
assert.equal(received.correct, true);

let authorityContext = null;
window.playmesh.main.authority.onService((action, context) => {
  authorityContext = context;
  return {
    targetPlayerIds: [context.senderPlayerId],
    message: { type: "echo", action },
  };
});
receiveMain({
  type: "transport.message",
  message: {
    type: "authority.action", senderPlayerId: "p-guest", payload: { type: "ping" },
    session: {
      players: [
        {
          id: "p-host", nickname: "Host", avatar: null,
          role: "authority_player", connected: true,
          source: "lan_app", latencyMs: 4,
        },
        {
          id: "p-guest", nickname: "Guest", avatar: null,
          role: "player", connected: true,
          source: "lan_html", latencyMs: 19,
        },
      ],
    },
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
const authorityResult = commands.find((command) => command.command === "authority.result");
assert.deepEqual(authorityResult.targetPlayerIds, ["p-guest"]);
assert.equal(authorityResult.payload.type, "echo");
assert.deepEqual(
  Object.keys(authorityContext.members[0]).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);

const syncController = window.playmesh.main.sync.startAuthority({
  initialState: { score: 0 },
  tickRate: 1,
  onInput(input, context) {
    assert.equal(context.inputType, "action");
    return { score: context.state.score + input.points };
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(window.playmesh.main.sync.getSnapshot().state.score, 0);
receiveMain({
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
assert.equal(window.playmesh.main.sync.getSnapshot().state.score, 3);
syncController.stop();
const disconnectedBinarySocket = MockWebSocket.last;
disconnectedBinarySocket.close();
while (MockWebSocket.last === disconnectedBinarySocket) {
  await new Promise((resolve) => setTimeout(resolve, 5));
}
await binaryChannel.send("p-guest", new Uint8Array([11]));
assert.equal(MockWebSocket.instances.length >= 2, true);

receiveMain({
  type: "lifecycle.event",
  event: "exit",
  requestId: "test-exit",
});

console.log("Game SDK bridge and Binary reconnect contract passed");
