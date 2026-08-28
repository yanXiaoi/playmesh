import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import fs from "node:fs";
import vm from "node:vm";

const commands = [];
const binaryFrames = [];
const uploads = [];
const standardStorageRequests = [];
const standardStorageData = new Map();
const synchronousStorageRequests = [];
const synchronousStorageLedger = new Map();
const rpcStreamBodies = new Map();
let dropNextSynchronousStorageResponse = false;
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

class MockFile extends Blob {
  constructor(parts, name, options = {}) {
    const normalizedParts = Array.isArray(parts) ? parts : [parts];
    super(normalizedParts, { type: options.type || "" });
    this.bytes = normalizedParts.length === 1 && normalizedParts[0] instanceof Uint8Array
      ? normalizedParts[0]
      : new Uint8Array();
    this.name = name;
    this.lastModified = options.lastModified || 0;
  }
}

function synchronousBucketRevision(bucket) {
  const values = Object.fromEntries(
    [...standardStorageData.entries()]
      .filter(([key]) => key.startsWith(`${bucket}:`))
      .map(([key, value]) => [key.slice(bucket.length + 1), value]),
  );
  return createHash("sha256").update(JSON.stringify(values)).digest("hex");
}

class MockXMLHttpRequest {
  constructor() {
    this.headers = {};
    this.status = 0;
    this.responseText = "";
  }

  open(method, url, asynchronous = true) {
    assert.equal(asynchronous, false, "sync storage must use blocking XHR");
    this.method = method;
    this.url = url;
  }

  setRequestHeader(name, value) {
    this.headers[name] = value;
  }

  send(body) {
    assert.equal(this.headers["X-Playmesh-Storage-Sync"], "1");
    let encodedBody;
    if (this.method === "GET") {
      assert.equal(body, null);
      const payload = new URL(this.url, "http://playmesh.local").searchParams.get("payload");
      assert.ok(payload);
      encodedBody = Buffer.from(payload, "base64url").toString("utf8");
    } else {
      assert.equal(this.method, "PUT");
      assert.equal(this.url, "/bucket/_playmesh-json/v1");
      assert.equal(this.headers["Content-Type"], "application/json");
      encodedBody = body;
    }
    const digest = createHash("sha256").update(encodedBody).digest("hex");
    assert.equal(this.headers["X-Playmesh-Content-Sha256"], digest);
    const envelope = JSON.parse(encodedBody);
    synchronousStorageRequests.push({
      method: this.method,
      url: this.url,
      headers: { ...this.headers },
      envelope,
      body: encodedBody,
    });
    const replay = synchronousStorageLedger.get(envelope.requestId);
    if (replay) {
      assert.equal(replay.digest, digest);
      this.status = replay.status;
      this.responseText = replay.responseText;
      return;
    }
    const key = `${envelope.bucket}:${envelope.key}`;
    let status = 200;
    let result;
    let error = null;
    if (this.method === "GET") {
      assert.equal(envelope.operation, "sync.get");
      result = {
        value: standardStorageData.has(key) ? standardStorageData.get(key) : null,
        revision: synchronousBucketRevision(envelope.bucket),
      };
    } else {
      assert.equal(envelope.operation, "sync.set");
      const currentRevision = synchronousBucketRevision(envelope.bucket);
      if (envelope.expectedRevision !== currentRevision) {
        status = 409;
        error = {
          code: "storage_revision_conflict",
          message: "存储修订已发生变化，已拒绝覆盖",
        };
      } else {
        const nextValues = Object.fromEntries(
          [...standardStorageData.entries()]
            .filter(([existing]) => existing.startsWith(`${envelope.bucket}:`))
            .map(([existing, current]) => [existing.slice(envelope.bucket.length + 1), current]),
        );
        nextValues[envelope.key] = envelope.value;
        if (Buffer.byteLength(JSON.stringify(nextValues)) > 10 * 1024 * 1024) {
          status = 413;
          error = {
            code: "standard_bucket_too_large",
            message: "Bucket JSON 序列化总量超过 10 MiB",
          };
        } else {
          standardStorageData.set(key, envelope.value);
          result = { revision: synchronousBucketRevision(envelope.bucket) };
        }
      }
    }
    this.status = status;
    this.responseText = JSON.stringify({
      protocolVersion: "1.0.0",
      requestId: envelope.requestId,
      ...(error ? { error } : { result }),
    });
    synchronousStorageLedger.set(envelope.requestId, {
      digest,
      status: this.status,
      responseText: this.responseText,
    });
    if (dropNextSynchronousStorageResponse && status === 200) {
      dropNextSynchronousStorageResponse = false;
      throw new Error("simulated response loss after commit");
    }
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
    this.rpcSequence = 0n;
    this.rpcRequests = new Map();
    this.rpcStreamRequests = new Map();
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
    } else if (operation === 0x06) {
      const requestId = view.getUint32(2);
      const pathLength = view.getUint16(10);
      const sender = new TextEncoder().encode("p-authority");
      const path = data.subarray(12, 12 + pathLength);
      const payload = data.subarray(12 + pathLength);
      this.rpcSequence += 1n;
      const rpcId = this.rpcSequence;
      const incoming = new Uint8Array(14 + sender.length + path.length + payload.length);
      const incomingView = new DataView(incoming.buffer);
      incoming[0] = 1;
      incoming[1] = 0x85;
      incomingView.setBigUint64(2, rpcId);
      incomingView.setUint16(10, sender.length);
      incomingView.setUint16(12, path.length);
      incoming.set(sender, 14);
      incoming.set(path, 14 + sender.length);
      incoming.set(payload, 14 + sender.length + path.length);
      this.rpcRequests.set(rpcId.toString(), requestId);
      setTimeout(() => this.receive(incoming), 0);
    } else if (operation === 0x07) {
      const rpcId = view.getBigUint64(2);
      const streamRequest = this.rpcStreamRequests.get(rpcId.toString());
      if (streamRequest) {
        this.rpcStreamRequests.delete(rpcId.toString());
        const responsePayload = data.subarray(11);
        if (data[10] === 0) {
          streamRequest.resolve({
            ok: true,
            status: 200,
            async arrayBuffer() {
              return responsePayload.buffer.slice(
                responsePayload.byteOffset,
                responsePayload.byteOffset + responsePayload.byteLength,
              );
            },
          });
        } else {
          const codeLength = view.getUint16(11);
          const code = new TextDecoder().decode(data.subarray(13, 13 + codeLength));
          const message = new TextDecoder().decode(data.subarray(13 + codeLength));
          streamRequest.resolve({
            ok: false,
            status: 422,
            async json() { return { error: { code, message } }; },
          });
        }
        return;
      }
      const requestId = this.rpcRequests.get(rpcId.toString());
      assert.ok(requestId, "Authority RPC response must match a routed request");
      this.rpcRequests.delete(rpcId.toString());
      const responsePayload = data.subarray(11);
      const response = new Uint8Array(7 + responsePayload.length);
      const responseView = new DataView(response.buffer);
      response[0] = 1;
      response[1] = 0x86;
      responseView.setUint32(2, requestId);
      response[6] = data[10];
      response.set(responsePayload, 7);
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
  sdkVersion: "3.5.0",
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
let webRTCSignalingEndpointProvider = null;
const appPublicApi = {
  version: "3.5.0",
  ready: appReadyThenable,
  isAvailable() {
    return true;
  },
  runtime: Object.freeze({
    getLocale() {
      return "zh-CN";
    },
  }),
  webrtc: Object.freeze({
    getSignalingEndpoint(identifier) {
      if (typeof webRTCSignalingEndpointProvider !== "function") {
        return Promise.reject(new Error("missing provider"));
      }
      return webRTCSignalingEndpointProvider(identifier);
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
const identityNicknameUpdates = [];
const appInternalRuntime = {
  publicApi: appPublicApi,
  registerWebRTCSignalingEndpointProvider(provider) {
    webRTCSignalingEndpointProvider = provider;
  },
  takePlatformUiConfiguration() {
    const value = appPlatformUiConfiguration;
    appPlatformUiConfiguration = null;
    return value;
  },
  restoreGameContentFocus() {},
  updateIdentityNickname(nickname, sessionId, credentialToken, playerId) {
    identityNicknameUpdates.push({ nickname, sessionId, credentialToken, playerId });
    const current = window.playmesh.main.session.getCurrent();
    const player = {
      id: "p-authority",
      nickname,
      avatar: null,
      role: "authority_player",
      connected: true,
    };
    return Promise.resolve({
      session: {
        ...current,
        authorityClientId: player.id,
        players: [player, ...current.players],
      },
      player,
      identity: {
        userId: "u-local",
        nickname,
        source: "playmesh_app",
      },
    });
  },
};

globalThis.window = {
  setInterval,
  clearInterval,
  setTimeout,
  clearTimeout,
  WebSocket: MockWebSocket,
  XMLHttpRequest: MockXMLHttpRequest,
  TextEncoder,
  TextDecoder,
  Uint8Array,
  ArrayBuffer,
  DataView,
  Blob,
  ReadableStream,
  File: MockFile,
  crypto: webcrypto,
  async fetch(url, options) {
    const parsedUrl = new URL(String(url), "http://playmesh.local");
    if (parsedUrl.pathname === "/v1/sessions/s-1/rpc-stream" && options.method === "POST") {
      const socket = MockWebSocket.last;
      socket.rpcSequence += 1n;
      const rpcId = socket.rpcSequence;
      const consumePath = `/v1/sessions/s-1/rpc-streams/stream-${rpcId}`;
      rpcStreamBodies.set(consumePath, options.body);
      const fields = [
        "p-authority",
        parsedUrl.searchParams.get("path"),
        consumePath,
        parsedUrl.searchParams.get("name"),
        options.headers["Content-Type"],
      ].map((value) => new TextEncoder().encode(value));
      const incoming = new Uint8Array(
        28 + fields.reduce((total, value) => total + value.length, 0),
      );
      const view = new DataView(incoming.buffer);
      incoming[0] = 1;
      incoming[1] = 0x87;
      view.setBigUint64(2, rpcId);
      fields.forEach((value, index) => view.setUint16(10 + index * 2, value.length));
      const declaredSize = parsedUrl.searchParams.get("size");
      const knownSize = declaredSize === null
        ? 0xffffffffffffffffn
        : BigInt(declaredSize);
      view.setBigUint64(20, knownSize);
      let offset = 28;
      for (const value of fields) {
        incoming.set(value, offset);
        offset += value.length;
      }
      setTimeout(() => socket.receive(incoming), 0);
      return new Promise((resolve) => {
        socket.rpcStreamRequests.set(rpcId.toString(), { resolve });
      });
    }
    if (rpcStreamBodies.has(parsedUrl.pathname) && options.method === "GET") {
      const source = rpcStreamBodies.get(parsedUrl.pathname);
      rpcStreamBodies.delete(parsedUrl.pathname);
      const body = source instanceof ReadableStream
        ? source
        : source instanceof Blob
          ? source.stream()
          : new ReadableStream({
              start(controller) {
                controller.enqueue(
                  source instanceof Uint8Array ? source : new Uint8Array(source),
                );
                controller.close();
              },
            });
      return {
        ok: true,
        status: 200,
        body,
      };
    }
    if (String(url).startsWith("/bucket/_playmesh-json/v1")) {
      const encodedBody = options.body || Buffer.from(
        new URL(String(url), "http://playmesh.local").searchParams.get("payload"),
        "base64url",
      ).toString("utf8");
      const envelope = JSON.parse(encodedBody);
      const calculatedDigest = Buffer.from(
        await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(encodedBody)),
      ).toString("hex");
      assert.equal(options.headers["X-Playmesh-Content-Sha256"], calculatedDigest);
      standardStorageRequests.push({ url, options, envelope });
      const key = `${envelope.bucket}:${envelope.key}`;
      let status = 200;
      let result;
      let error;
      if (envelope.operation === "get") {
        result = {
          value: standardStorageData.has(key) ? standardStorageData.get(key) : null,
          revision: synchronousBucketRevision(envelope.bucket),
        };
      } else if (envelope.operation === "set") {
        const currentRevision = synchronousBucketRevision(envelope.bucket);
        if (envelope.expectedRevision !== currentRevision) {
          status = 409;
          error = { code: "storage_revision_conflict", message: "revision conflict" };
        } else {
          standardStorageData.set(key, envelope.value);
          result = { revision: synchronousBucketRevision(envelope.bucket) };
        }
      } else if (envelope.operation === "remove") {
        const currentRevision = synchronousBucketRevision(envelope.bucket);
        if (envelope.expectedRevision !== currentRevision) {
          status = 409;
          error = { code: "storage_revision_conflict", message: "revision conflict" };
        } else {
          standardStorageData.delete(key);
          result = { revision: synchronousBucketRevision(envelope.bucket) };
        }
      } else if (envelope.operation === "clear") {
        const currentRevision = synchronousBucketRevision(envelope.bucket);
        if (envelope.expectedRevision !== currentRevision) {
          status = 409;
          error = { code: "storage_revision_conflict", message: "revision conflict" };
        } else {
          for (const existing of standardStorageData.keys()) {
            if (existing.startsWith(`${envelope.bucket}:`)) standardStorageData.delete(existing);
          }
          result = { revision: synchronousBucketRevision(envelope.bucket) };
        }
      }
      return {
        ok: status >= 200 && status < 300,
        status,
        async json() {
          return {
            protocolVersion: "1.0.0",
            requestId: envelope.requestId,
            ...(error ? { error } : { result }),
          };
        },
      };
    }
    let bodyBytes = null;
    if (options.body instanceof ReadableStream) {
      const reader = options.body.getReader();
      const chunks = [];
      let length = 0;
      try {
        while (true) {
          const item = await reader.read();
          if (item.done) break;
          const chunk = new Uint8Array(item.value);
          chunks.push(chunk);
          length += chunk.length;
        }
      } finally {
        reader.releaseLock();
      }
      bodyBytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) {
        bodyBytes.set(chunk, offset);
        offset += chunk.length;
      }
    }
    uploads.push({ url, options, bodyBytes });
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
          sdkVersion: "4.3.0",
          isAuthority: true,
          gameInfo: {
            id: "com.playmesh.test-game",
            name: "SDK 测试游戏",
            tags: [],
            multiplayer: true,
            displayMode: "multi_screen",
            requiredCapabilities: [],
          },
          player: {
            id: "p-authority",
            nickname: "Authority",
            avatar: null,
            role: "authority_player",
            connected: true,
          },
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
      } else if (command.command === "webrtc.getSignalingEndpoint") {
        receiveMain({
          type: "command.result",
          requestId: command.requestId,
          result: {
            type: "playmesh.webrtc-signaling-endpoint",
            version: 1,
            timestamp: 1770000000000,
            requestId: command.requestId,
            identifier: command.payload.identifier,
            url: "ws://127.0.0.1:42000/v1/webrtc/signaling/ticket",
            expiresAt: "2026-08-25T00:00:30Z",
            playerId: "p-authority",
            role: "authority",
            iceServers: [{ urls: ["stun:relay.example.test:3478"] }],
          },
        });
      } else if (command.command === "db.open") {
        receiveMain({
          type: "command.result", requestId: command.requestId,
          result: { file: "_game.db" },
        });
      } else if (command.command === "db.transaction.begin") {
        receiveMain({
          type: "command.result", requestId: command.requestId,
          result: { transactionId: `tx-${command.requestId}` },
        });
      } else if (command.command === "db.select" || command.command === "db.transaction.select") {
        receiveMain({
          type: "command.result", requestId: command.requestId,
          result: [{ args: command.payload.args }],
        });
      } else if (command.command.startsWith("db.")) {
        receiveMain({
          type: "command.result", requestId: command.requestId,
          result: command.command.endsWith("insert")
            ? { changes: 1, lastInsertRowId: "1" }
            : command.command.endsWith("update") || command.command.endsWith("delete")
              ? { changes: 1 }
              : null,
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
assert.equal(window.playmesh.main.player.getCurrent().id, "p-authority");
assert.equal(window.playmesh.main.session.getCurrent().joinCode, "ABC123");
assert.deepEqual(
  Object.keys(window.playmesh.main.session.getCurrent().players[0]).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.equal(window.playmesh.main.version, "4.3.0");
assert.deepEqual(Object.keys(window.playmesh).sort(), ["app", "main", "ready"]);
assert.equal(sdkBootstrap.main.sdkVersion, "4.3.0");
assert.equal(sdkBootstrap.app.sdkVersion, "3.5.0");

assert.deepEqual(await window.playmesh.main.db.open(), { file: "_game.db" });
assert.deepEqual(
  await window.playmesh.main.db.select("SELECT ?2, ?1", ["first", 2]),
  [{ args: ["first", 2] }],
);
assert.deepEqual(
  await window.playmesh.main.db.select("SELECT :id", { id: 7 }),
  [{ args: { id: 7 } }],
);
assert.deepEqual(
  await window.playmesh.main.db.select("SELECT @id, $name", {
    "@id": 8,
    "$name": "named",
  }),
  [{ args: { "@id": 8, "$name": "named" } }],
);
const explicitTransaction = await window.playmesh.main.db.beginTransaction();
await explicitTransaction.insert("INSERT INTO items(name) VALUES (:name)", {
  name: "transaction",
});
await explicitTransaction.commit();
assert.throws(() => explicitTransaction.select("SELECT 1"), /事务已经结束/);
const callbackFailure = new Error("callback failed");
await assert.rejects(
  window.playmesh.main.db.transaction(async (transaction) => {
    await transaction.update("UPDATE items SET name = ?", ["changed"]);
    throw callbackFailure;
  }),
  (error) => error === callbackFailure,
);
assert.equal(
  commands.some((command) => command.command === "db.transaction.rollback"),
  true,
);
const signalingEndpoint = await window.playmesh.app.webrtc.getSignalingEndpoint(
  "camera/main",
);
assert.equal(signalingEndpoint.identifier, "camera/main");
assert.equal(signalingEndpoint.playerId, "p-authority");
assert.equal(Object.isFrozen(signalingEndpoint), true);
assert.equal(
  commands.some(
    (command) =>
      command.command === "webrtc.getSignalingEndpoint" &&
      command.payload.identifier === "camera/main",
  ),
  true,
);
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
const renamedPlayer = await window.playmesh.main.player.setNickname("App 玩家");
assert.equal(renamedPlayer.nickname, "App 玩家");
assert.deepEqual(identityNicknameUpdates, [{
  nickname: "App 玩家",
  sessionId: undefined,
  credentialToken: undefined,
  playerId: undefined,
}]);
assert.equal(
  commands.some((command) => command.command === "player.setNickname"),
  false,
  "App 宿主昵称更新必须由 App Bridge 处理",
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
await bucket.setData("coins", 9);
assert.equal(await bucket.getData("coins"), 9);
await bucket.removeData("coins");
assert.equal(await bucket.getData("coins"), null);
await bucket.setData("level", 2);
await bucket.clearData();
assert.equal(await bucket.getData("level"), null);
assert.deepEqual(
  standardStorageRequests.map((request) => request.envelope.operation),
  ["get", "set", "get", "remove", "get", "set", "clear", "get"],
);
assert.equal(
  standardStorageRequests.every(
    (request) => String(request.url).startsWith("/bucket/_playmesh-json/v1") &&
      request.options.method === ({ get: "GET", set: "PUT", remove: "DELETE", clear: "DELETE" })[request.envelope.operation] &&
      request.options.credentials === "same-origin" &&
      request.envelope.gameId === "com.playmesh.test-game" &&
      request.envelope.requestId.startsWith("storage-") &&
      request.envelope.shareToken === undefined,
  ),
  true,
);
assert.equal(commands.some((command) => command.command.startsWith("storage.")), false);

const gdevelopBucketName = `目录/存档.${"长".repeat(200)}`;
const gdevelopRootKey = "$playmesh.gdevelop.root.v1";
const synchronousBucket = window.playmesh.main.storage.getBucket(gdevelopBucketName);
assert.equal(typeof synchronousBucket.getDataSync, "function");
assert.equal(typeof synchronousBucket.setDataSync, "function");
assert.equal(synchronousBucket.getSync, undefined);
assert.equal(synchronousBucket.setSync, undefined);
assert.equal(window.playmesh.main.storage.getBucketSync, undefined);
assert.equal(synchronousBucket.getDataSync(gdevelopRootKey), null);
synchronousBucket.setDataSync(gdevelopRootKey, { scene: 3, title: "你好" });
assert.deepEqual(synchronousBucket.getDataSync(gdevelopRootKey), {
  scene: 3,
  title: "你好",
});
assert.deepEqual(
  synchronousStorageRequests.slice(0, 3).map((request) => request.method),
  ["GET", "PUT", "GET"],
);
assert.equal(
  synchronousStorageRequests.every(
    (request) => request.envelope.gameId === "com.playmesh.test-game" &&
      request.envelope.bucket === gdevelopBucketName &&
      request.envelope.requestId.startsWith("storage-") &&
      request.envelope.shareToken === undefined &&
      request.headers["X-Playmesh-Content-Sha256"] ===
        createHash("sha256").update(request.body).digest("hex"),
  ),
  true,
);

dropNextSynchronousStorageResponse = true;
const beforeReplay = synchronousStorageRequests.length;
synchronousBucket.setDataSync(gdevelopRootKey, { scene: 4 });
const replayRequests = synchronousStorageRequests.slice(beforeReplay);
assert.equal(replayRequests.length, 2);
assert.equal(replayRequests[0].envelope.requestId, replayRequests[1].envelope.requestId);
assert.equal(replayRequests[0].body, replayRequests[1].body);
assert.equal(replayRequests[0].headers["X-Playmesh-Content-Sha256"], replayRequests[1].headers["X-Playmesh-Content-Sha256"]);

standardStorageData.set(`${gdevelopBucketName}:${gdevelopRootKey}`, { scene: 99 });
assert.throws(
  () => synchronousBucket.setDataSync(gdevelopRootKey, { scene: 5 }),
  (error) => error?.code === "storage_revision_conflict",
);
assert.deepEqual(synchronousBucket.getDataSync(gdevelopRootKey), { scene: 99 });
synchronousBucket.setDataSync(gdevelopRootKey, { scene: 5 });

const originalXMLHttpRequest = window.XMLHttpRequest;
window.XMLHttpRequest = undefined;
assert.throws(
  () => window.playmesh.main.storage.getBucket("no_xhr").getDataSync("value"),
  /不支持同步 XMLHttpRequest/,
);
window.XMLHttpRequest = originalXMLHttpRequest;

for (const invalidBucket of [
  "../save",
  "bad.bucket",
  "_save",
  "-save",
  "存档",
  "save\n",
  `a${"b".repeat(64)}`,
]) {
  const invalidForAsync = window.playmesh.main.storage.getBucket(invalidBucket);
  assert.throws(() => invalidForAsync.getData("value"), /无效的 bucket/);
  assert.throws(() => invalidForAsync.setData("value", 1), /无效的 bucket/);
  assert.throws(() => invalidForAsync.removeData("value"), /无效的 bucket/);
  assert.throws(() => invalidForAsync.clearData(), /无效的 bucket/);
}
assert.throws(
  () => window.playmesh.main.storage.getBucket("长".repeat(1366) + "a"),
  /4096 个 UTF-8 字节/,
);

const largeSyncBucket = window.playmesh.main.storage.getBucket("sync_large");
const emptyLargeBucketBytes = Buffer.byteLength(JSON.stringify({ blob: "" }));
const acceptedLargeValue = "x".repeat(10 * 1024 * 1024 - emptyLargeBucketBytes);
largeSyncBucket.setDataSync("blob", acceptedLargeValue);
assert.equal(largeSyncBucket.getDataSync("blob").length, acceptedLargeValue.length);
assert.throws(
  () => largeSyncBucket.setDataSync("blob", `${acceptedLargeValue}+`),
  (error) => error?.code === "standard_bucket_too_large",
);

let received = null;
window.playmesh.main.game.onMessage((message) => { received = message; });
receiveMain({
  type: "transport.message",
  message: { type: "game.message", payload: { type: "answer.result", correct: true } },
});
assert.equal(received.correct, true);

let authorityContext = null;
const unregisterEchoAuthority = window.playmesh.main.authority.onService((action, context) => {
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
unregisterEchoAuthority();

let rpcHandlerCalls = 0;
let rpcHandlerContext = null;
const unregisterRpc = window.playmesh.main.rpc.onRequest(
  "/player/profile",
  async (data, context) => {
    rpcHandlerCalls += 1;
    rpcHandlerContext = context;
    assert.equal(data.slot, "slot-1");
    assert.deepEqual([...data.raw], [0, 255, 7]);
    assert.equal(data.image.type, "image/png");
    assert.deepEqual([...new Uint8Array(await data.image.arrayBuffer())], [137, 80, 78, 71]);
    assert.equal(data.file.name, "save.bin");
    assert.equal(data.file.type, "application/octet-stream");
    assert.equal(data.file.lastModified, 123456);
    assert.deepEqual([...new Uint8Array(await data.file.arrayBuffer())], [9, 8, 7]);
    return {
      playerId: context.senderPlayerId,
      slot: data.slot,
      preview: Uint8Array.from([3, 2, 1]),
      file: new MockFile(Uint8Array.from([6, 5, 4]), "reply.bin", {
        type: "application/octet-stream",
        lastModified: 654321,
      }),
    };
  },
);
assert.throws(
  () => window.playmesh.main.rpc.onRequest("/player/profile", () => null),
  (error) => error?.code === "rpc_path_registered",
);
assert.throws(
  () => window.playmesh.main.rpc.onRequest("player/profile", () => null),
  (error) => error?.code === "rpc_path_invalid",
);
const rpcOperation = window.playmesh.main.rpc.request(
  "/player/profile",
  {
    slot: "slot-1",
    raw: Uint8Array.from([0, 255, 7]),
    image: new Blob([Uint8Array.from([137, 80, 78, 71])], { type: "image/png" }),
    file: new MockFile(Uint8Array.from([9, 8, 7]), "save.bin", {
      type: "application/octet-stream",
      lastModified: 123456,
    }),
  },
);
const rpcResult = await rpcOperation;
assert.equal(rpcHandlerCalls, 1);
assert.match(rpcHandlerContext.requestId, /^rpc-[a-f0-9]{16}$/);
assert.equal(rpcHandlerContext.path, "/player/profile");
assert.equal(rpcHandlerContext.senderPlayerId, "p-authority");
assert.equal(rpcResult.playerId, "p-authority");
assert.equal(rpcResult.slot, "slot-1");
assert.deepEqual([...rpcResult.preview], [3, 2, 1]);
assert.equal(rpcResult.file.name, "reply.bin");
assert.equal(rpcResult.file.type, "application/octet-stream");
assert.equal(rpcResult.file.lastModified, 654321);
assert.deepEqual([...new Uint8Array(await rpcResult.file.arrayBuffer())], [6, 5, 4]);
const rpcBinaryRequest = binaryFrames.findLast((frame) => frame[1] === 0x06);
assert.ok(rpcBinaryRequest, "RPC request must use the authenticated binary transport");
const rpcBinaryPathLength = new DataView(
  rpcBinaryRequest.buffer,
  rpcBinaryRequest.byteOffset,
  rpcBinaryRequest.byteLength,
).getUint16(10);
assert.equal(
  new TextDecoder().decode(rpcBinaryRequest.subarray(12, 12 + rpcBinaryPathLength)),
  "/player/profile",
);
assert.equal(
  commands.some((command) => command.payload?.__playmeshRpc),
  false,
  "RPC must not fall back to the JSON command transport",
);
assert.equal(received.correct, true, "RPC 内部响应不能泄漏到 game.onMessage");
unregisterRpc();
unregisterRpc();

let rpcStreamContext = null;
const rpcStreamSendProgress = [];
const rpcStreamReceiveProgress = [];
const unregisterRpcStream = window.playmesh.main.rpc.onStreamRequest(
  "/files/store",
  async (source, context) => {
    rpcStreamContext = context;
    return bucket.upload(source, { name: context.name, type: context.type });
  },
  {
    onProgress(transferredBytes, totalBytes) {
      rpcStreamReceiveProgress.push([transferredBytes, totalBytes]);
    },
  },
);
assert.throws(
  () => window.playmesh.main.rpc.onStreamRequest("/files/store", () => null),
  (error) => error?.code === "rpc_path_registered",
);
assert.throws(
  () => window.playmesh.main.rpc.onStreamRequest(
    "/files/invalid-progress",
    () => null,
    { onProgress: "invalid" },
  ),
  (error) => error?.code === "rpc_progress_invalid",
);
const streamFrameOffset = binaryFrames.length;
const streamedUrl = await window.playmesh.main.rpc.requestStream(
  "/files/store",
  new MockFile(Uint8Array.from([12, 0, 255, 33]), "large-save.bin", {
    type: "application/octet-stream",
  }),
  {
    onProgress(transferredBytes, totalBytes) {
      rpcStreamSendProgress.push([transferredBytes, totalBytes]);
    },
  },
);
assert.equal(streamedUrl, "/bucket/fishing_save/1777777777777.bin");
assert.equal(rpcStreamContext.path, "/files/store");
assert.equal(rpcStreamContext.senderPlayerId, "p-authority");
assert.equal(rpcStreamContext.name, "large-save.bin");
assert.equal(rpcStreamContext.type, "application/octet-stream");
assert.equal(rpcStreamContext.size, 4);
assert.deepEqual(rpcStreamSendProgress, [[0, 4], [4, 4]]);
assert.deepEqual(rpcStreamReceiveProgress, [[0, 4], [4, 4]]);
assert.deepEqual([...uploads.at(-1).bodyBytes], [12, 0, 255, 33]);
assert.equal(
  binaryFrames.slice(streamFrameOffset).some((frame) => frame[1] === 0x06),
  false,
  "RPC stream bytes must not enter the Binary RPC request frame",
);
unregisterRpcStream();
unregisterRpcStream();

const unregisterFailingRpc = window.playmesh.main.rpc.onRequest(
  "/player/reject",
  () => {
    const error = new Error("请求未通过 Authority 审核");
    error.code = "request_rejected";
    throw error;
  },
);
const failingRpcOperation = window.playmesh.main.rpc.request("/player/reject", {});
await assert.rejects(
  failingRpcOperation,
  (error) => error?.code === "request_rejected" && /未通过/.test(error.message),
);
unregisterFailingRpc();
await assert.rejects(
  window.playmesh.main.rpc.request("/too/large", {
    data: new Uint8Array(4 * 1024 * 1024),
  }),
  (error) => error?.code === "rpc_payload_too_large",
);

assert.equal(
  window.playmesh.main.authority.defaultNamespace,
  "playmesh.authority.default.v1",
);
assert.throws(
  () => window.playmesh.main.authority.onService(() => {}, { namespace: "" }),
  /namespace 无效/,
);
assert.throws(
  () => window.playmesh.main.game.submitAction({}, { namespace: "" }),
  /namespace 无效/,
);
const captureSubmittedAuthorityPayload = async (action, options) => {
  const operation = options === undefined
    ? window.playmesh.main.game.submitAction(action)
    : window.playmesh.main.game.submitAction(action, options);
  const command = commands.findLast(
    (candidate) => candidate.command === "game.submitAction",
  );
  receiveMain({
    type: "command.result",
    requestId: command.requestId,
    result: null,
  });
  await operation;
  return command.payload;
};
const dispatchSubmittedAuthorityPayload = async (payload) => {
  receiveMain({
    type: "transport.message",
    message: {
      type: "authority.action",
      senderPlayerId: "p-guest",
      payload,
      session: {
        id: "session-authority-routing",
        players: [
          {
            id: "p-guest", nickname: "Guest", avatar: null,
            role: "player", connected: true,
          },
        ],
      },
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
};
const authorityResultTypesAfter = (count) => commands
  .filter((command) => command.command === "authority.result")
  .slice(count)
  .map((command) => command.payload.type);

const defaultCalls = [];
const unregisterOldDefault = window.playmesh.main.authority.onService((action) => {
  defaultCalls.push(`old:${action.type}`);
});
const unregisterDefault = window.playmesh.main.authority.onService((action) => {
  defaultCalls.push(`new:${action.type}`);
  return { targetPlayerIds: ["p-guest"], message: { type: "default.result" } };
});
unregisterOldDefault();
const legacyActionWithNamespaceField = {
  type: "legacy.with-namespace-field",
  namespace: "game.payload.value",
};
const legacyPayload = await captureSubmittedAuthorityPayload(
  legacyActionWithNamespaceField,
);
assert.deepEqual(legacyPayload, legacyActionWithNamespaceField);
const resultsBeforeDefault = commands.filter(
  (command) => command.command === "authority.result",
).length;
await dispatchSubmittedAuthorityPayload(legacyPayload);
assert.deepEqual(defaultCalls, ["new:legacy.with-namespace-field"]);
assert.deepEqual(authorityResultTypesAfter(resultsBeforeDefault), ["default.result"]);

const routedCalls = [];
const namespaceA = "example.game.inventory.v1";
const namespaceB = "example.game.chat.v1";
const unregisterNamespaceA = window.playmesh.main.authority.onService(
  (action) => {
    routedCalls.push(`a:${action.type}`);
    return { targetPlayerIds: ["p-guest"], message: { type: "a.result" } };
  },
  { namespace: namespaceA },
);
const unregisterNamespaceB = window.playmesh.main.authority.onService(
  (action) => {
    routedCalls.push(`b:${action.type}`);
    return { targetPlayerIds: ["p-guest"], message: { type: "b.result" } };
  },
  { namespace: namespaceB },
);
assert.throws(
  () => window.playmesh.main.authority.onService(() => {}, { namespace: namespaceA }),
  /namespace 已注册/,
);
const namespaceAPayload = await captureSubmittedAuthorityPayload(
  { type: "inventory.take", itemId: "coin" },
  { namespace: namespaceA },
);
const namespaceBPayload = await captureSubmittedAuthorityPayload(
  { type: "chat.send", text: "hello" },
  { namespace: namespaceB },
);
const resultsBeforeNamed = commands.filter(
  (command) => command.command === "authority.result",
).length;
await dispatchSubmittedAuthorityPayload(namespaceAPayload);
await dispatchSubmittedAuthorityPayload(namespaceBPayload);
assert.deepEqual(routedCalls, ["a:inventory.take", "b:chat.send"]);
assert.deepEqual(authorityResultTypesAfter(resultsBeforeNamed), ["a.result", "b.result"]);
assert.deepEqual(defaultCalls, ["new:legacy.with-namespace-field"]);

const unknownPayload = await captureSubmittedAuthorityPayload(
  { type: "unknown.action" },
  { namespace: "example.game.unknown.v1" },
);
const resultsBeforeUnknown = commands.filter(
  (command) => command.command === "authority.result",
).length;
await dispatchSubmittedAuthorityPayload(unknownPayload);
assert.deepEqual(authorityResultTypesAfter(resultsBeforeUnknown), []);
assert.deepEqual(defaultCalls, ["new:legacy.with-namespace-field"]);

unregisterNamespaceA();
unregisterNamespaceA();
const resultsBeforeCancelled = commands.filter(
  (command) => command.command === "authority.result",
).length;
await dispatchSubmittedAuthorityPayload(namespaceAPayload);
assert.deepEqual(authorityResultTypesAfter(resultsBeforeCancelled), []);

let authorityLifecycleError = null;
const unregisterAuthorityLifecycle = window.playmesh.main.lifecycle.onChange((event) => {
  if (event.state === "error") authorityLifecycleError = event.error;
});
const unregisterFailingNamespace = window.playmesh.main.authority.onService(
  () => {
    throw new Error("expected isolated authority failure");
  },
  { namespace: "example.game.failure.v1" },
);
const failingPayload = await captureSubmittedAuthorityPayload(
  { type: "failure.test" },
  { namespace: "example.game.failure.v1" },
);
await dispatchSubmittedAuthorityPayload(failingPayload);
assert.match(authorityLifecycleError, /expected isolated authority failure/);
await dispatchSubmittedAuthorityPayload(legacyPayload);
assert.deepEqual(defaultCalls, [
  "new:legacy.with-namespace-field",
  "new:legacy.with-namespace-field",
]);

unregisterFailingNamespace();
unregisterAuthorityLifecycle();
unregisterNamespaceB();
unregisterDefault();

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

const transportLifecycleEvents = [];
const unregisterTransportLifecycle = window.playmesh.main.lifecycle.onChange(
  (event) => transportLifecycleEvents.push(event),
);
receiveMain({
  type: "transport.message",
  message: {
    type: "transport.status",
    state: "disconnected",
    lifecycleState: "closed",
    error: "connection closed",
  },
});
receiveMain({
  type: "transport.message",
  message: {
    type: "transport.status",
    state: "disconnected",
    lifecycleState: "error",
    error: "connection failed",
  },
});
assert.deepEqual(
  transportLifecycleEvents.map((event) => event.state),
  ["closed", "error"],
  "WebView transport.status 必须转发为跨平台 lifecycle 事件",
);
assert.equal(transportLifecycleEvents[1].error, "connection failed");
unregisterTransportLifecycle();

receiveMain({
  type: "lifecycle.event",
  event: "exit",
  requestId: "test-exit",
});

console.log("Game SDK bridge, Binary reconnect, and lifecycle contract passed");
