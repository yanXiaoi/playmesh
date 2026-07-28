// @ts-ignore
(function (global) {
  "use strict";

  const PLAYMESH_SDK_VERSION = "3.0.0";

  let sequence = 0;
  let bootstrap = null;
  let authorityService = null;
  let browserSocket = null;
  let browserCredential = null;
  let browserConnectionConfig = null;
  let browserReconnectOperation = null;
  let binaryTransportConfig = null;
  let binarySocket = null;
  let binaryConnectOperation = null;
  let binaryReconnectWanted = false;
  let runtimeExited = false;
  let binaryRequestSequence = 0;
  let binaryQueueHead = 0;
  let binaryFlushTimer = null;
  const binaryQueue = [];
  const binaryLatestQueue = new Map();
  const binaryPending = new Map();
  const binaryChannels = new Map();
  let browserNicknameUi = null;
  let browserBackInterceptionInstalled = false;
  let browserBackExitRequested = false;
  let browserBackGuardUrl = null;
  let capabilityConsentUi = null;
  let transportSequence = 0;
  const pending = new Map();
  const browserStoragePending = new Map();
  let browserStorageSequence = 0;
  const sessionListeners = new Set();
  const playerJoinListeners = new Set();
  const playerLeaveListeners = new Set();
  const playerReconnectListeners = new Set();
  const previouslyConnectedPlayerIds = new Set();
  const messageListeners = new Set();
  const lifecycleListeners = new Set();
  const pauseListeners = new Set();
  const resumeListeners = new Set();
  const exitListeners = new Set();
  const fpsListeners = new Set();
  const latencyListeners = new Set();
  const syncListeners = new Set();
  const browserNicknameStorageKey = "playmesh.nickname.v1";
  const browserPlayerIdStorageKey = "playmesh.player-id.v1";
  let currentFps = null;
  let fpsFrameCount = 0;
  let fpsWindowStartedAt = null;
  let currentLatency = null;
  let latencyDiagnostics = null;
  let latencyTimer = null;
  let latencyProbeSequence = 0;
  let performanceVisible = false;
  let performanceUi = null;
  let syncAuthorityRuntime = null;
  let currentSyncSnapshot = null;
  let syncInputSequence = 0;
  const pendingStateInputs = new Map();
  const BINARY_PROTOCOL_VERSION = 1;
  const BINARY_OP_CREATE = 0x01;
  const BINARY_OP_JOIN = 0x02;
  const BINARY_OP_CLOSE = 0x03;
  const BINARY_OP_SEND = 0x04;
  const BINARY_OP_DECISION = 0x05;
  const BINARY_OP_RESPONSE = 0x81;
  const BINARY_OP_DELIVERY = 0x82;
  const BINARY_OP_REVIEW = 0x83;
  const BINARY_OP_CLOSED = 0x84;
  const BINARY_MODE_AUTHORITY = 1;
  const BINARY_MODE_RELAY = 2;
  const BINARY_FLAG_LATEST = 1;
  const BINARY_FLAG_MULTIPLE_TARGETS = 2;
  const BINARY_FLAG_BROADCAST = 4;
  const BINARY_DECISION_PASS = 1;
  const BINARY_DECISION_REPLACE = 2;
  const BINARY_DECISION_REJECT = 3;
  const BINARY_STATUS_OK = 0;
  const BINARY_STATUS_ERROR = 1;
  const BINARY_STATUS_SUPERSEDED = 2;
  const BINARY_CHANNEL_ID_BYTES = 16;
  const BINARY_MAX_TARGETS = 1024;
  const BINARY_MAX_BUFFERED_BYTES = 8 * 1024 * 1024;
  const BINARY_REQUEST_TIMEOUT_MS = 15000;
  const RECONNECT_BASE_DELAY_MS = 250;
  const RECONNECT_MAX_DELAY_MS = 5000;
  function post(command, payload, extra) {
    const requestId = `sdk-${Date.now()}-${++sequence}`;
    const message = JSON.stringify({
      command,
      requestId,
      sdkVersion: PLAYMESH_SDK_VERSION,
      payload,
      ...extra,
    });
    if (global.__PLAYMESH_BROWSER__ &&
        (command === "game.submitAction" ||
          command === "performance.ping" ||
          command === "performance.latency")) {
      return sendBrowserTransport(command, payload);
    }
    const send = global.PlaymeshBridge && global.PlaymeshBridge.postMessage
      ? (value) => global.PlaymeshBridge.postMessage(value)
      : global.chrome && global.chrome.webview
        ? (value) => global.chrome.webview.postMessage(value)
        : null;
    if (!send) {
      return Promise.reject(new Error("Playmesh 传输通道不可用"));
    }
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`Playmesh Bridge 请求超时: ${command}`));
      }, 15000);
      pending.set(requestId, { resolve, reject, timer });
      try {
        send(message);
      } catch (error) {
        global.clearTimeout(timer);
        pending.delete(requestId);
        reject(error);
      }
    });
  }

  function reconnectDelay(attempt) {
    if (attempt <= 1) return 0;
    return Math.min(
      RECONNECT_BASE_DELAY_MS * (2 ** Math.min(attempt - 2, 5)),
      RECONNECT_MAX_DELAY_MS,
    );
  }

  async function waitForReconnect(attempt) {
    const delay = reconnectDelay(attempt);
    if (delay > 0) {
      await new Promise((resolve) => global.setTimeout(resolve, delay));
    }
    if (runtimeExited) throw new Error("游戏页面已退出");
  }

  async function sendBrowserTransport(command, payload) {
    let socket = browserSocket;
    if (!socket || socket.readyState !== global.WebSocket.OPEN) {
      if (!browserReconnectOperation) {
        throw new Error("主会话 WebSocket 当前不可用");
      }
      await browserReconnectOperation;
      socket = browserSocket;
    }
    if (!socket || socket.readyState !== global.WebSocket.OPEN) {
      throw new Error("主会话 WebSocket 重连尚未完成");
    }
    const type = command === "game.submitAction"
      ? "game.action"
      : command === "performance.latency"
        ? "performance.latency"
        : "session.ping";
    socket.send(JSON.stringify({
      type,
      sequence: ++transportSequence,
      payload,
    }));
    return null;
  }

  function subscribe(listeners, callback) {
    listeners.add(callback);
    return function unsubscribe() {
      listeners.delete(callback);
    };
  }

  function emit(listeners, value) {
    for (const listener of listeners) {
      listener(value);
    }
  }

  function binaryModeCode(mode) {
    if (mode === "authority") return BINARY_MODE_AUTHORITY;
    if (mode === "relay") return BINARY_MODE_RELAY;
    throw new Error('Binary Channel mode 必须是 "authority" 或 "relay"');
  }

  function binaryModeName(mode) {
    if (mode === BINARY_MODE_AUTHORITY) return "authority";
    if (mode === BINARY_MODE_RELAY) return "relay";
    throw new Error("主机返回了无效的 Binary Channel mode");
  }

  function binaryChannelIdFromBytes(bytes) {
    let raw = "";
    for (const value of bytes) raw += String.fromCharCode(value);
    return global.btoa(raw)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");
  }

  function binaryChannelIdToBytes(value) {
    if (typeof value !== "string" || !value) {
      throw new Error("Binary Channel ID 必须是非空字符串");
    }
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
    let raw;
    try {
      raw = global.atob(padded);
    } catch (_) {
      throw new Error("Binary Channel ID 无效");
    }
    if (raw.length !== BINARY_CHANNEL_ID_BYTES) {
      throw new Error("Binary Channel ID 无效");
    }
    return Uint8Array.from(raw, (character) => character.charCodeAt(0));
  }

  function normalizeBinaryData(data) {
    if (!(data instanceof Uint8Array)) {
      throw new Error("Binary Channel 数据必须是 Uint8Array");
    }
    return new Uint8Array(data);
  }

  function normalizeBinaryTargets(target) {
    const values = Array.isArray(target) ? target : [target];
    if (!values.length || values.length > BINARY_MAX_TARGETS) {
      throw new Error(`Binary Channel 目标数量必须为 1 至 ${BINARY_MAX_TARGETS}`);
    }
    const result = [];
    const seen = new Set();
    for (const playerId of values) {
      if (typeof playerId !== "string" || !playerId) {
        throw new Error("Binary Channel 目标玩家 ID 必须是非空字符串");
      }
      if (seen.has(playerId)) continue;
      seen.add(playerId);
      result.push(playerId);
    }
    return result;
  }

  function encodeBinaryCreate(requestId, mode) {
    const data = new Uint8Array(7);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_CREATE;
    view.setUint32(2, requestId);
    data[6] = mode;
    return data;
  }

  function encodeBinaryChannelOperation(operation, requestId, channelId) {
    const channelBytes = binaryChannelIdToBytes(channelId);
    const data = new Uint8Array(22);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = operation;
    view.setUint32(2, requestId);
    data.set(channelBytes, 6);
    return data;
  }

  function encodeBinarySend(requestId, channelId, flags, targetPlayerIds, payload, broadcast) {
    const encodedTargets = broadcast
      ? []
      : targetPlayerIds.map((playerId) => {
          const encoded = new TextEncoder().encode(playerId);
          if (encoded.length > 0xffff) {
            throw new Error("Binary Channel 目标玩家 ID 过长");
          }
          return encoded;
        });
    if (broadcast) flags |= BINARY_FLAG_BROADCAST;
    if (encodedTargets.length > 1) flags |= BINARY_FLAG_MULTIPLE_TARGETS;
    const channelBytes = binaryChannelIdToBytes(channelId);
    const targetsLength = encodedTargets.reduce(
      (total, target) => total + target.length + (encodedTargets.length > 1 ? 2 : 0),
      0,
    );
    const data = new Uint8Array(25 + targetsLength + payload.length);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_SEND;
    view.setUint32(2, requestId);
    data.set(channelBytes, 6);
    data[22] = flags;
    view.setUint16(23, broadcast ? 0 : encodedTargets.length > 1
      ? encodedTargets.length
      : encodedTargets[0].length);
    let offset = 25;
    for (const target of encodedTargets) {
      if (encodedTargets.length > 1) {
        view.setUint16(offset, target.length);
        offset += 2;
      }
      data.set(target, offset);
      offset += target.length;
    }
    data.set(payload, offset);
    return data;
  }

  function encodeBinaryDecision(reviewId, decision, payload) {
    const data = new Uint8Array(11 + payload.length);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_DECISION;
    data.set(reviewId, 2);
    data[10] = decision;
    data.set(payload, 11);
    return data;
  }

  function nextBinaryRequestId() {
    binaryRequestSequence = (binaryRequestSequence + 1) >>> 0;
    if (binaryRequestSequence === 0) binaryRequestSequence = 1;
    return binaryRequestSequence;
  }

  async function ensureBinarySocket() {
    if (!bootstrap?.session || !binaryTransportConfig?.url) {
      throw new Error("当前游戏没有可用的多人二进制传输");
    }
    if (runtimeExited) throw new Error("游戏页面已退出");
    binaryReconnectWanted = true;
    if (binarySocket?.readyState === global.WebSocket.OPEN) {
      return binarySocket;
    }
    if (binaryConnectOperation) return binaryConnectOperation;
    binaryConnectOperation = connectBinaryWithRetry()
      .finally(() => {
        binaryConnectOperation = null;
        if (!runtimeExited &&
            binaryReconnectWanted &&
            binarySocket?.readyState !== global.WebSocket.OPEN) {
          void ensureBinarySocket().catch(() => {});
        }
      });
    return binaryConnectOperation;
  }

  async function connectBinaryWithRetry() {
    let attempt = 0;
    while (!runtimeExited && binaryReconnectWanted) {
      attempt += 1;
      await waitForReconnect(attempt);
      if (global.__PLAYMESH_BROWSER__?.mode !== "solo" &&
          browserConnectionConfig &&
          browserSocket?.readyState !== global.WebSocket.OPEN) {
        global.console?.info?.("Playmesh Binary WebSocket 等待主会话重连", { attempt });
        if (browserReconnectOperation) {
          await browserReconnectOperation.catch(() => {});
        }
        continue;
      }
      if (attempt > 1) {
        global.console?.info?.("Playmesh Binary WebSocket 正在重连", { attempt });
      }
      try {
        const socket = await openBinarySocket();
        await restoreBinaryChannels();
        if (attempt > 1) {
          global.console?.info?.("Playmesh Binary WebSocket 重连成功", { attempt });
        } else {
          global.console?.info?.("Playmesh Binary WebSocket 已连接");
        }
        scheduleBinaryFlush();
        return socket;
      } catch (error) {
        if (runtimeExited || !binaryReconnectWanted) break;
        const failedSocket = binarySocket;
        binarySocket = null;
        if (failedSocket && failedSocket.readyState < global.WebSocket.CLOSING) {
          failedSocket.close();
        }
        global.console?.warn?.("Playmesh Binary WebSocket 重连失败，将继续重试", {
          attempt,
          error: error?.message || String(error),
          retryInMs: reconnectDelay(attempt + 1),
        });
      }
    }
    throw new Error("游戏页面已退出，停止 Binary WebSocket 重连");
  }

  function openBinarySocket() {
    return new Promise((resolve, reject) => {
      const socket = new global.WebSocket(binaryTransportConfig.url);
      socket.binaryType = "arraybuffer";
      binarySocket = socket;
      let opened = false;
      const fail = () => {
        if (!opened) reject(new Error("无法连接主机 Binary WebSocket"));
      };
      socket.addEventListener("open", () => {
        opened = true;
        socket.removeEventListener?.("error", fail);
        resolve(socket);
      }, { once: true });
      socket.addEventListener("error", fail, { once: true });
      socket.addEventListener("message", (event) => {
        void receiveBinarySocketMessage(event.data);
      });
      socket.addEventListener("close", (event) => {
        if (binarySocket !== socket) return;
        binarySocket = null;
        if (!opened) {
          reject(new Error("Binary WebSocket 在连接完成前关闭"));
          return;
        }
        handleBinaryDisconnect(event);
      });
    });
  }

  function handleBinaryDisconnect(event) {
    const error = new Error("Binary WebSocket 已掉线");
    global.console?.warn?.("Playmesh Binary WebSocket 已掉线", {
      code: event?.code,
      reason: event?.reason || "",
    });
    failBinaryTransport(error, false);
    if (!runtimeExited && binaryReconnectWanted) {
      void ensureBinarySocket().catch(() => {});
    }
  }

  async function restoreBinaryChannels() {
    for (const state of [...binaryChannels.values()]) {
      if (state.closed) continue;
      try {
        await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_JOIN, requestId, state.id),
          { expectsChannel: true },
        );
        global.console?.info?.("Playmesh Binary Channel 已恢复", { channelId: state.id });
      } catch (error) {
        state.closed = true;
        binaryChannels.delete(state.id);
        global.console?.error?.("Playmesh Binary Channel 恢复失败，Channel 已关闭", {
          channelId: state.id,
          error: error?.message || String(error),
        });
      }
    }
  }

  function failBinaryTransport(error, closeChannels = true) {
    if (binaryFlushTimer) global.clearTimeout(binaryFlushTimer);
    binaryFlushTimer = null;
    for (let index = binaryQueueHead; index < binaryQueue.length; index += 1) {
      const item = binaryQueue[index];
      if (item?.latestKey && binaryLatestQueue.get(item.latestKey) === item) {
        binaryLatestQueue.delete(item.latestKey);
      }
    }
    binaryQueue.length = 0;
    binaryQueueHead = 0;
    for (const request of binaryPending.values()) {
      global.clearTimeout(request.timer);
      request.reject(error);
    }
    binaryPending.clear();
    if (closeChannels) {
      for (const state of binaryChannels.values()) {
        state.closed = true;
      }
      binaryChannels.clear();
    }
  }

  function closeBinaryTransport(reason = "游戏运行时已退出", permanent = false) {
    if (permanent) binaryReconnectWanted = false;
    const socket = binarySocket;
    binarySocket = null;
    if (socket && socket.readyState < global.WebSocket.CLOSING) {
      socket.close(1000, reason);
    }
    failBinaryTransport(new Error(reason), permanent);
    if (!permanent && !runtimeExited && binaryReconnectWanted) {
      void ensureBinarySocket().catch(() => {});
    }
  }

  function queueBinaryFrame(data, options = {}) {
    const item = {
      data,
      latestKey: options.latestKey || null,
      requestId: options.requestId || 0,
      superseded: false,
    };
    if (item.latestKey) {
      const previous = binaryLatestQueue.get(item.latestKey);
      if (previous && !previous.sent) {
        previous.superseded = true;
        settleBinaryRequest(previous.requestId, BINARY_STATUS_SUPERSEDED);
      }
      binaryLatestQueue.set(item.latestKey, item);
    }
    binaryQueue.push(item);
    scheduleBinaryFlush();
  }

  function scheduleBinaryFlush() {
    if (binaryFlushTimer) return;
    binaryFlushTimer = global.setTimeout(flushBinaryQueue, 0);
  }

  function flushBinaryQueue() {
    binaryFlushTimer = null;
    const socket = binarySocket;
    if (!socket || socket.readyState !== global.WebSocket.OPEN) return;
    while (binaryQueueHead < binaryQueue.length &&
           socket.bufferedAmount < BINARY_MAX_BUFFERED_BYTES) {
      const item = binaryQueue[binaryQueueHead++];
      if (item.superseded) continue;
      item.sent = true;
      if (item.latestKey && binaryLatestQueue.get(item.latestKey) === item) {
        binaryLatestQueue.delete(item.latestKey);
      }
      try {
        socket.send(item.data);
      } catch (error) {
        settleBinaryRequest(item.requestId, BINARY_STATUS_ERROR, error);
      }
    }
    if (binaryQueueHead >= binaryQueue.length) {
      binaryQueue.length = 0;
      binaryQueueHead = 0;
      return;
    }
    binaryFlushTimer = global.setTimeout(flushBinaryQueue, 4);
  }

  async function binaryRequest(frameFactory, options = {}) {
    await ensureBinarySocket();
    const requestId = nextBinaryRequestId();
    const frame = frameFactory(requestId);
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        binaryPending.delete(requestId);
        reject(new Error("Binary Channel 请求超时"));
      }, BINARY_REQUEST_TIMEOUT_MS);
      binaryPending.set(requestId, {
        resolve, reject, timer,
        expectsChannel: options.expectsChannel === true,
      });
      queueBinaryFrame(frame, {
        requestId,
        latestKey: options.latestKey,
      });
    });
  }

  function settleBinaryRequest(requestId, status, error, result) {
    if (!requestId) return;
    const request = binaryPending.get(requestId);
    if (!request) return;
    global.clearTimeout(request.timer);
    binaryPending.delete(requestId);
    if (status === BINARY_STATUS_ERROR) {
      request.reject(error instanceof Error ? error : new Error(String(error || "Binary Channel 请求失败")));
    } else {
      request.resolve(result);
    }
  }

  async function receiveBinarySocketMessage(raw) {
    let data;
    if (raw instanceof ArrayBuffer) {
      data = new Uint8Array(raw);
    } else if (raw instanceof Uint8Array) {
      data = raw;
    } else if (raw?.arrayBuffer) {
      data = new Uint8Array(await raw.arrayBuffer());
    } else {
      closeBinaryTransport("主机返回了无效的二进制帧");
      return;
    }
    if (data.length < 2 || data[0] !== BINARY_PROTOCOL_VERSION) {
      closeBinaryTransport("主机返回了不兼容的二进制协议");
      return;
    }
    switch (data[1]) {
    case BINARY_OP_RESPONSE:
      receiveBinaryResponse(data);
      break;
    case BINARY_OP_DELIVERY:
      receiveBinaryDelivery(data);
      break;
    case BINARY_OP_REVIEW:
      void receiveBinaryReview(data);
      break;
    case BINARY_OP_CLOSED:
      receiveBinaryClosed(data);
      break;
    default:
      closeBinaryTransport("主机返回了未知的二进制操作");
    }
  }

  function receiveBinaryResponse(data) {
    if (data.length < 7) {
      closeBinaryTransport("Binary Channel 响应格式无效");
      return;
    }
    const requestId = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(2);
    const status = data[6];
    if (status === BINARY_STATUS_ERROR) {
      settleBinaryRequest(
        requestId,
        status,
        new Error(new TextDecoder().decode(data.subarray(7)) || "Binary Channel 请求失败"),
      );
      return;
    }
    let result;
    if (status === BINARY_STATUS_OK && data.length === 24) {
      result = {
        mode: binaryModeName(data[7]),
        id: binaryChannelIdFromBytes(data.subarray(8, 24)),
      };
    }
    settleBinaryRequest(requestId, status, null, result);
  }

  function receiveBinaryDelivery(data) {
    if (data.length < 21) {
      closeBinaryTransport("Binary Channel 消息格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const senderLength = view.getUint16(19);
    if (!senderLength || data.length < 21 + senderLength) {
      closeBinaryTransport("Binary Channel 发送者格式无效");
      return;
    }
    const channelId = binaryChannelIdFromBytes(data.subarray(2, 18));
    const state = binaryChannels.get(channelId);
    if (!state || state.closed) return;
    const senderPlayerId = new TextDecoder().decode(data.subarray(21, 21 + senderLength));
    const payload = data.slice(21 + senderLength);
    const context = {
      senderPlayerId,
      delivery: data[18] & BINARY_FLAG_LATEST ? "latest" : "queued",
    };
    for (const listener of [...state.listeners]) {
      listener(payload, context);
    }
  }

  async function receiveBinaryReview(data) {
    if (data.length < 31) {
      closeBinaryTransport("Binary Channel Authority 审核帧格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const reviewId = data.slice(2, 10);
    const channelId = binaryChannelIdFromBytes(data.subarray(10, 26));
    const senderLength = view.getUint16(27);
    const targetField = view.getUint16(29);
    if (!senderLength || !targetField || data.length < 31 + senderLength) {
      closeBinaryTransport("Binary Channel Authority 审核上下文无效");
      return;
    }
    let offset = 31;
    const senderPlayerId = new TextDecoder().decode(data.subarray(offset, offset + senderLength));
    offset += senderLength;
    const targetPlayerIds = [];
    if (data[26] & BINARY_FLAG_MULTIPLE_TARGETS) {
      if (targetField > BINARY_MAX_TARGETS) {
        closeBinaryTransport("Binary Channel Authority 审核目标过多");
        return;
      }
      for (let index = 0; index < targetField; index += 1) {
        if (data.length < offset + 2) {
          closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
          return;
        }
        const targetLength = view.getUint16(offset);
        offset += 2;
        if (!targetLength || data.length < offset + targetLength) {
          closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
          return;
        }
        targetPlayerIds.push(
          new TextDecoder().decode(data.subarray(offset, offset + targetLength)),
        );
        offset += targetLength;
      }
    } else {
      if (data.length < offset + targetField) {
        closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
        return;
      }
      targetPlayerIds.push(
        new TextDecoder().decode(data.subarray(offset, offset + targetField)),
      );
      offset += targetField;
    }
    const payload = data.slice(offset);
    const state = binaryChannels.get(channelId);
    if (!state || state.closed || state.mode !== "authority" || !state.forwardHandler) {
      queueBinaryFrame(encodeBinaryDecision(
        reviewId,
        BINARY_DECISION_REJECT,
        new TextEncoder().encode("Authority 未注册 Binary Channel 审核器"),
      ));
      return;
    }
    try {
      const replacement = await state.forwardHandler(payload, {
        senderPlayerId,
        targetPlayerIds,
        delivery: data[26] & BINARY_FLAG_LATEST ? "latest" : "queued",
      });
      if (replacement === undefined) {
        queueBinaryFrame(encodeBinaryDecision(reviewId, BINARY_DECISION_PASS, new Uint8Array()));
      } else if (replacement instanceof Uint8Array) {
        queueBinaryFrame(encodeBinaryDecision(
          reviewId,
          BINARY_DECISION_REPLACE,
          new Uint8Array(replacement),
        ));
      } else {
        throw new Error("Binary Channel Authority 审核器只能返回 void 或 Uint8Array");
      }
    } catch (error) {
      queueBinaryFrame(encodeBinaryDecision(
        reviewId,
        BINARY_DECISION_REJECT,
        new TextEncoder().encode(error?.message || String(error)),
      ));
    }
  }

  function receiveBinaryClosed(data) {
    if (data.length < 18) {
      closeBinaryTransport("Binary Channel 关闭帧格式无效");
      return;
    }
    const channelId = binaryChannelIdFromBytes(data.subarray(2, 18));
    const state = binaryChannels.get(channelId);
    if (!state) return;
    state.closed = true;
    binaryChannels.delete(channelId);
  }

  function createBinaryChannelHandle(id, mode) {
    const existing = binaryChannels.get(id);
    if (existing && !existing.closed) return existing.handle;
    const state = {
      id,
      mode,
      listeners: new Set(),
      forwardHandler: null,
      closed: false,
      handle: null,
    };
    const sendToTargets = (target, data, latest) => {
      if (state.closed) return Promise.reject(new Error("Binary Channel 已关闭"));
      const targetPlayerIds = normalizeBinaryTargets(target);
      const payload = normalizeBinaryData(data);
      const latestKey = latest
        ? `${id}\u0000${JSON.stringify([...targetPlayerIds].sort())}`
        : null;
      return binaryRequest(
        (requestId) => encodeBinarySend(
          requestId,
          id,
          latest ? BINARY_FLAG_LATEST : 0,
          targetPlayerIds,
          payload,
          false,
        ),
        { latestKey },
      );
    };
    const broadcast = (data, latest) => {
      if (state.closed) return Promise.reject(new Error("Binary Channel 已关闭"));
      const payload = normalizeBinaryData(data);
      return binaryRequest(
        (requestId) => encodeBinarySend(
          requestId,
          id,
          latest ? BINARY_FLAG_LATEST : 0,
          [],
          payload,
          true,
        ),
        { latestKey: latest ? `${id}\u0000broadcast` : null },
      );
    };
    state.handle = Object.freeze({
      id,
      mode,
      send(targetOrData, data) {
        if (data === undefined && targetOrData instanceof Uint8Array) {
          return broadcast(targetOrData, false);
        }
        return sendToTargets(targetOrData, data, false);
      },
      sendLatest(targetOrData, data) {
        if (data === undefined && targetOrData instanceof Uint8Array) {
          return broadcast(targetOrData, true);
        }
        return sendToTargets(targetOrData, data, true);
      },
      onMessage(callback) {
        if (typeof callback !== "function") throw new Error("Binary Channel onMessage 需要函数");
        state.listeners.add(callback);
        return () => state.listeners.delete(callback);
      },
      onForward(handler) {
        if (!playmesh.session.isAuthority() || mode !== "authority") {
          throw new Error("只有 Authority mode 的 Authority 可以注册 Binary Channel 审核器");
        }
        if (typeof handler !== "function") throw new Error("Binary Channel onForward 需要函数");
        state.forwardHandler = handler;
        return () => {
          if (state.forwardHandler === handler) state.forwardHandler = null;
        };
      },
      async close() {
        if (!playmesh.session.isAuthority()) {
          throw new Error("只有 Authority 可以关闭 Binary Channel");
        }
        if (state.closed) return;
        await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_CLOSE, requestId, id),
        );
        state.closed = true;
        binaryChannels.delete(id);
      },
    });
    binaryChannels.set(id, state);
    return state.handle;
  }

  function publicPlayer(player) {
    if (!player || typeof player !== "object") return null;
    return {
      id: player.id,
      nickname: player.nickname,
      avatar: typeof player.avatar === "string" ? player.avatar : null,
      role: player.role,
      connected: Boolean(player.connected),
    };
  }

  function publicSession(session) {
    if (!session || typeof session !== "object") return null;
    return {
      ...session,
      players: Array.isArray(session.players)
        ? session.players.map(publicPlayer)
        : [],
    };
  }

  function seedPlayerConnections(session) {
    previouslyConnectedPlayerIds.clear();
    for (const player of session?.players || []) {
      if (player.connected) previouslyConnectedPlayerIds.add(player.id);
    }
  }

  function playerConnectionLogContext(player) {
    const value = publicPlayer(player);
    return {
      playerId: value?.id || null,
      nickname: value?.nickname || null,
      avatar: value?.avatar ?? null,
      playerRole: value?.role || null,
      playerConnected: value?.connected ?? false,
    };
  }

  function sessionConnectionLogContext(session, player) {
    const players = session?.players || [];
    return {
      sessionId: session?.id || null,
      gameId: session?.gameId || null,
      roomType: session?.displayMode || "unknown",
      sessionState: session?.state || "unknown",
      onlinePlayers: players.filter((member) => member.connected).length,
      roomPlayers: players.length,
      minPlayers: session?.minPlayers ?? null,
      maxPlayers: session?.maxPlayers ?? null,
      ...playerConnectionLogContext(player),
      isCurrentPlayer: player?.id === bootstrap?.player?.id,
      isAuthority: player?.id === session?.authorityClientId,
    };
  }

  function emitPlayerConnectionChanges(previousSession, nextSession) {
    if (previousSession?.id !== nextSession?.id) {
      seedPlayerConnections(previousSession?.id === nextSession?.id ? previousSession : null);
    }
    const previousPlayers = new Map((previousSession?.players || []).map((player) => [player.id, player]));
    const nextPlayers = new Map((nextSession?.players || []).map((player) => [player.id, player]));
    for (const player of nextPlayers.values()) {
      const previous = previousPlayers.get(player.id);
      if (player.connected && !previous?.connected) {
        const reconnecting = previouslyConnectedPlayerIds.has(player.id);
        previouslyConnectedPlayerIds.add(player.id);
        global.console?.info?.(
          reconnecting
            ? "Playmesh 玩家已重连"
            : "Playmesh 新玩家已加入房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(reconnecting ? playerReconnectListeners : playerJoinListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      } else if (!player.connected && previous?.connected) {
        global.console?.warn?.(
          "Playmesh 玩家已掉线或退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
    for (const player of previousPlayers.values()) {
      if (player.connected && !nextPlayers.has(player.id)) {
        global.console?.warn?.(
          "Playmesh 玩家已退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player: { ...player, connected: false },
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
  }

  async function dispatchAuthorityAction(transportMessage) {
    if (await dispatchSyncAuthorityAction(transportMessage)) return;
    if (!authorityService) {
      return;
    }
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
    };
    const output = await authorityService(transportMessage.payload, context);
    const results = Array.isArray(output) ? output : [output];
    for (const result of results) {
      if (!result || !Array.isArray(result.targetPlayerIds) || !result.message) {
        continue;
      }
      await post("authority.result", result.message, {
        targetPlayerIds: result.targetPlayerIds,
      });
    }
  }

  function cloneJson(value, label) {
    let encoded;
    try {
      encoded = JSON.stringify(value);
    } catch (error) {
      throw new Error(`${label} 必须可 JSON 序列化: ${error.message || error}`);
    }
    if (encoded === undefined) throw new Error(`${label} 不能是 undefined`);
    return JSON.parse(encoded);
  }

  function syncTargetIds(session) {
    return [...new Set([
      session.authorityClientId,
      ...session.players.map((player) => player.id),
    ].filter(Boolean))];
  }

  function applySyncState(runtime, nextState) {
    if (nextState === undefined) return false;
    const normalized = cloneJson(nextState, "权威状态");
    if (JSON.stringify(normalized) === JSON.stringify(runtime.state)) return false;
    runtime.state = normalized;
    runtime.revision += 1;
    return true;
  }

  function continuousInputs(runtime) {
    const result = {};
    for (const [compoundKey, entry] of runtime.inputs) {
      const separator = compoundKey.indexOf(":");
      const playerId = compoundKey.substring(0, separator);
      const key = compoundKey.substring(separator + 1);
      result[playerId] ??= {};
      result[playerId][key] = cloneJson(entry, "连续输入");
    }
    return result;
  }

  async function publishSyncSnapshot(runtime, targetPlayerIds) {
    if (runtime.stopped) return null;
    const session = bootstrap?.session;
    if (!session) return null;
    const snapshot = {
      protocolVersion: 1,
      stateType: runtime.stateType,
      full: true,
      revision: runtime.revision,
      sequence: ++runtime.snapshotSequence,
      timestamp: Date.now(),
      sourceTick: runtime.tick,
      state: cloneJson(runtime.state, "权威状态"),
    };
    applySyncSnapshot(snapshot);
    await post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
      targetPlayerIds: targetPlayerIds || syncTargetIds(session),
    });
    return snapshot;
  }

  async function runSyncTick(runtime) {
    if (runtime.stopped || runtime.tickRunning) return;
    runtime.tickRunning = true;
    try {
      const now = Date.now();
      const dt = Math.min(1, Math.max(0, (now - runtime.lastTickAt) / 1000));
      runtime.lastTickAt = now;
      runtime.tick += 1;
      if (runtime.onTick) {
        const next = await runtime.onTick({
          state: cloneJson(runtime.state, "权威状态"),
          inputs: continuousInputs(runtime),
          tick: runtime.tick,
          dt,
          now,
          session: bootstrap.session,
          members: bootstrap.session.players,
        });
        applySyncState(runtime, next);
      }
      await publishSyncSnapshot(runtime);
    } catch (error) {
      emit(lifecycleListeners, { state: "error", error: String(error) });
    } finally {
      runtime.tickRunning = false;
    }
  }

  async function dispatchSyncAuthorityAction(transportMessage) {
    const envelope = transportMessage.payload?.__playmeshSync;
    if (!envelope) return false;
    const runtime = syncAuthorityRuntime;
    if (!runtime) return true;
    if (envelope.type === "snapshot.request") {
      await publishSyncSnapshot(runtime, [transportMessage.senderPlayerId]);
      return true;
    }
    if (envelope.type !== "input.action" && envelope.type !== "input.state") {
      return true;
    }
    const input = cloneJson(envelope.payload, "同步输入");
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
      state: cloneJson(runtime.state, "权威状态"),
      inputId: envelope.inputId,
      inputType: envelope.type === "input.state" ? "state" : "action",
      key: envelope.key || null,
      receivedAt: Date.now(),
    };
    if (envelope.type === "input.state") {
      runtime.inputs.set(`${context.senderPlayerId}:${envelope.key}`, {
        value: input,
        inputId: envelope.inputId,
        receivedAt: context.receivedAt,
      });
    }
    if (runtime.onInput) {
      applySyncState(runtime, await runtime.onInput(input, context));
    }
    return true;
  }

  function applySyncSnapshot(snapshot) {
    if (!snapshot || snapshot.protocolVersion !== 1 || snapshot.full !== true) return;
    if (typeof snapshot.revision !== "number" || typeof snapshot.sequence !== "number") return;
    if (currentSyncSnapshot && snapshot.sequence <= currentSyncSnapshot.sequence &&
        snapshot.timestamp <= currentSyncSnapshot.timestamp) return;
    currentSyncSnapshot = cloneJson(snapshot, "同步快照");
    emit(syncListeners, currentSyncSnapshot);
  }

  function submitSyncEnvelope(type, payload, extra = {}) {
    if (!bootstrap?.session) return Promise.reject(new Error("当前游戏没有多人会话"));
    const inputId = `input-${Date.now()}-${++syncInputSequence}`;
    return post("game.submitAction", {
      __playmeshSync: {
        type,
        inputId,
        payload: cloneJson(payload, "同步输入"),
        clientTime: Date.now(),
        ...extra,
      },
    }).then(() => inputId);
  }

  function submitStateInput(key, value, options = {}) {
    if (typeof key !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(key)) {
      return Promise.reject(new Error("连续输入 key 无效"));
    }
    const rateHz = options.rateHz ?? 20;
    if (!Number.isFinite(rateHz) || rateHz < 1 || rateHz > 20) {
      return Promise.reject(new Error("连续输入 rateHz 必须在 1 至 20 之间"));
    }
    const existing = pendingStateInputs.get(key) || { lastSentAt: 0, timer: null };
    existing.value = cloneJson(value, "连续输入");
    existing.rateHz = rateHz;
    pendingStateInputs.set(key, existing);
    const wait = Math.max(0, (1000 / rateHz) - (Date.now() - existing.lastSentAt));
    if (!existing.timer) {
      existing.timer = global.setTimeout(() => {
        existing.timer = null;
        existing.lastSentAt = Date.now();
        void submitSyncEnvelope("input.state", existing.value, { key }).catch(() => {});
      }, wait);
      existing.timer?.unref?.();
    }
    return Promise.resolve(null);
  }

  function startSyncAuthority(options) {
    if (!playmesh.session.isAuthority()) {
      throw new Error("只有 Authority Client 可以启动状态同步");
    }
    if (syncAuthorityRuntime) throw new Error("权威状态同步已经启动");
    if (!options || !("initialState" in options)) {
      throw new Error("initialState 为必填项");
    }
    const tickRate = options.tickRate ?? 10;
    if (!Number.isInteger(tickRate) || tickRate < 1 || tickRate > 20) {
      throw new Error("tickRate 必须是 1 至 20 的整数");
    }
    const runtime = {
      state: cloneJson(options.initialState, "initialState"),
      stateType: typeof options.stateType === "string" && options.stateType
        ? options.stateType : "game",
      onInput: typeof options.onInput === "function" ? options.onInput : null,
      onTick: typeof options.onTick === "function" ? options.onTick : null,
      revision: 0,
      snapshotSequence: 0,
      tick: 0,
      inputs: new Map(),
      lastTickAt: Date.now(),
      tickRunning: false,
      stopped: false,
      timer: null,
    };
    syncAuthorityRuntime = runtime;
    runtime.timer = global.setInterval(() => { void runSyncTick(runtime); }, 1000 / tickRate);
    runtime.timer?.unref?.();
    void publishSyncSnapshot(runtime);
    return {
      getState: () => cloneJson(runtime.state, "权威状态"),
      setState(nextState, publish = true) {
        applySyncState(runtime, nextState);
        return publish ? publishSyncSnapshot(runtime) : Promise.resolve(null);
      },
      publish: (targetPlayerIds) => publishSyncSnapshot(runtime, targetPlayerIds),
      stop() {
        if (runtime.stopped) return;
        runtime.stopped = true;
        global.clearInterval(runtime.timer);
        if (syncAuthorityRuntime === runtime) syncAuthorityRuntime = null;
      },
    };
  }

  function setLatency(value, diagnostics = null) {
    currentLatency = typeof value === "number" && Number.isFinite(value)
      ? Math.max(0, Math.round(value))
      : null;
    latencyDiagnostics = diagnostics;
    emit(latencyListeners, currentLatency);
    void renderPerformanceUi();
    post("performance.latency", {
      latencyMs: currentLatency,
      diagnostics: latencyDiagnostics,
    }).catch(() => {});
  }

  function sendLatencyProbe() {
    if (!bootstrap?.session) return;
    const clientSentAt = Date.now();
    post("performance.ping", {
      probeId: `latency-${clientSentAt}-${++latencyProbeSequence}`,
      clientSentAt,
    }).catch(() => {});
  }

  function startLatencyProbes() {
    if (!bootstrap?.session) return;
    if (latencyTimer) return;
    sendLatencyProbe();
    latencyTimer = global.setInterval(sendLatencyProbe, 3000);
    latencyTimer?.unref?.();
  }

  function stopLatencyProbes() {
    if (latencyTimer) global.clearInterval(latencyTimer);
    latencyTimer = null;
  }

  function handleLatencyPong(payload) {
    const receivedAt = Date.now();
    const sentAt = Number(payload?.clientSentAt);
    if (!Number.isFinite(sentAt) || sentAt > receivedAt) return;
    if (payload.authorityAvailable !== true) {
      setLatency(null, {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: false,
      });
      return;
    }
    const rtt = Math.max(0, receivedAt - sentAt);
    const smoothed = currentLatency == null ? rtt : (currentLatency * 0.75) + (rtt * 0.25);
    setLatency(smoothed, {
      probeId: payload.probeId || null,
      clientSentAt: sentAt,
      serverReceivedAt: payload.serverReceivedAt || null,
      serverSentAt: payload.serverSentAt || null,
      receivedAt,
      authorityAvailable: true,
      rawRttMs: rtt,
    });
  }

  async function ensurePerformanceUi() {
    if (global.__PLAYMESH_BROWSER__ && !appSdk.isAvailable()) {
      return ensureBrowserNicknameUi();
    }
    if (performanceUi) return performanceUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    if (typeof global.document.createElement !== "function") return null;
    const host = global.document.createElement("div");
    host.id = "playmesh-performance";
    host.setAttribute?.("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;--pm-performance-border:#ffffff30;--pm-performance-surface:#111827e8;--pm-performance-text:#f9fafb;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;letter-spacing:0;color-scheme:dark}
      :host([data-theme="light"]){--pm-performance-border:#8795a6;--pm-performance-surface:#fffffff2;--pm-performance-text:#17202b;color-scheme:light}
      .panel{position:fixed;right:12px;top:12px;z-index:2147483646;display:flex;gap:10px;padding:7px 9px;border:1px solid var(--pm-performance-border);border-radius:7px;background:var(--pm-performance-surface);color:var(--pm-performance-text);box-shadow:0 3px 12px #0004;font-size:12px;font-weight:700;line-height:1}
      .panel[hidden],.latency[hidden]{display:none}
    </style><div class="panel"><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>`;
    global.document.body.appendChild(host);
    performanceUi = {
      host,
      panel: root.querySelector(".panel"),
      fps: root.querySelector(".fps"),
      latency: root.querySelector(".latency"),
    };
    refreshPerformancePlatformUi(performanceUi);
    return performanceUi;
  }

  function refreshPerformancePlatformUi(ui) {
    ui?.host?.setAttribute?.("data-theme", platformUiTheme);
  }

  async function renderPerformanceUi() {
    if (typeof appSdk.__refreshRuntimeUi === "function") {
      appSdk.__refreshRuntimeUi();
      return;
    }
    const ui = await ensurePerformanceUi();
    if (!ui) return;
    ui.panel.hidden = !performanceVisible;
    ui.fps.textContent = currentFps == null ? "-- FPS" : `${currentFps} FPS`;
    const multiplayer = Boolean(bootstrap?.session);
    ui.latency.hidden = !multiplayer;
    ui.latency.textContent = currentLatency == null ? "-- ms" : `${currentLatency} ms`;
    if (ui.performanceButton) {
      ui.performanceButton.classList.toggle("active", performanceVisible);
      ui.performanceButton.setAttribute("aria-pressed", String(performanceVisible));
    }
  }

  function receive(rawMessage) {
    const message = typeof rawMessage === "string" ? JSON.parse(rawMessage) : rawMessage;
    if (!message || typeof message !== "object") return;
    if (message.type === "platform.ui.restoreGameFocus") {
      appSdk.__restoreGameContentFocus?.();
      return;
    }
    if (message.type === "platform.ui.configure") {
      try {
        configurePlatformUi(
          message.configuration,
          runtimeLocaleUsesBrowserSystem
            ? browserRuntimeLocale
            : message.configuration?.locale,
        );
      } catch (error) {
        global.console?.error?.("Playmesh platform UI localization update failed", error);
      }
      return;
    }
    if (message.type === "performance.visibility") {
      performanceVisible = message.visible !== false;
      void renderPerformanceUi();
      return;
    }
    if (message.type === "sdk.bootstrap") {
      const previousSessionId = bootstrap?.session?.id;
      const publicBootstrap = {
        ...message,
        player: publicPlayer(message.player),
        session: publicSession(message.session),
      };
      if (message.binaryTransport?.url) {
        binaryTransportConfig = { url: String(message.binaryTransport.url) };
      }
      delete publicBootstrap.binaryTransport;
      bootstrap = publicBootstrap;
      seedPlayerConnections(bootstrap.session);
      if (previousSessionId !== bootstrap.session?.id) currentSyncSnapshot = null;
      emit(sessionListeners, bootstrap.session);
      emit(lifecycleListeners, { state: "ready" });
      const request = pending.get(message.requestId);
      if (request) global.clearTimeout(request.timer);
      request?.resolve(publicBootstrap);
      pending.delete(message.requestId);
      global.console?.info?.("Playmesh Game SDK 就绪", {
        mode: bootstrap.session ? "multiplayer" : "solo",
      });
      void renderPerformanceUi();
      startLatencyProbes();
      if (bootstrap.session && !bootstrap.isAuthority) {
        void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
      }
      return;
    }
    if (message.type === "command.result" || message.type === "command.error") {
      const request = pending.get(message.requestId);
      if (request) {
        global.clearTimeout(request.timer);
        if (message.type === "command.result") {
          request.resolve(message.result);
        } else {
          const error = new Error(message.error);
          error.code = message.code;
          request.reject(error);
        }
        pending.delete(message.requestId);
      }
      return;
    }
    if (message.type === "transport.error" || message.type === "transport.closed") {
      global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      closeBinaryTransport("主会话连接已关闭");
      stopLatencyProbes();
      setLatency(null);
      emit(lifecycleListeners, {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      if (browserConnectionConfig && !runtimeExited) {
        scheduleBrowserReconnect();
      }
      return;
    }
    if (message.type === "lifecycle.event") {
      const event = { state: message.event };
      emit(lifecycleListeners, event);
      const listeners = message.event === "pause"
        ? pauseListeners
        : message.event === "resume"
          ? resumeListeners
          : exitListeners;
      Promise.allSettled([...listeners].map((handler) => handler(event)))
        .then(() => {
          if (message.event === "exit") {
            markRuntimeExited("游戏运行时已退出");
          }
          if (!global.__PLAYMESH_BROWSER__) {
            return post("lifecycle.complete", {
              lifecycleRequestId: message.requestId,
            });
          }
        });
      return;
    }
    if (message.type !== "transport.message") {
      return;
    }
    const transport = message.message?.session
      ? {
          ...message.message,
          session: publicSession(message.message.session),
        }
      : message.message;
    if (transport.type === "transport.status") {
      const details = {
        attempt: transport.attempt,
        error: transport.error,
      };
      if (transport.state === "reconnected") {
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", details);
      } else if (transport.state === "reconnecting") {
        global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", details);
      } else {
        global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", details);
      }
    } else if (transport.type === "session.state") {
      emitPlayerConnectionChanges(bootstrap.session, transport.session);
      bootstrap.session = transport.session;
      emit(sessionListeners, transport.session);
      void renderPerformanceUi();
      startLatencyProbes();
    } else if (transport.type === "game.message") {
      const storageResponse = transport.payload?.__playmeshStorageResponse;
      if (storageResponse) {
        settleBrowserStorage(storageResponse);
      } else {
        const snapshot = transport.payload?.__playmeshSyncSnapshot;
        if (snapshot) applySyncSnapshot(snapshot);
        else emit(messageListeners, transport.payload);
      }
    } else if (transport.type === "session.pong") {
      handleLatencyPong(transport.payload);
    } else if (transport.type === "authority.ping") {
      post("performance.pong", transport.payload, {
        targetPlayerId: transport.senderPlayerId,
      }).catch(() => {});
    } else if (transport.type === "authority.action") {
      dispatchAuthorityAction(transport).catch((error) => {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      });
    }
  }

  async function connectBrowser(config) {
    if (config.mode === "solo") {
      bootstrap = {
        type: "sdk.bootstrap",
        sdkVersion: PLAYMESH_SDK_VERSION,
        gameInfo: {
          id: config.gameId,
          name: config.gameName,
          multiplayer: false,
          displayMode: "solo",
          requiredCapabilities: [...(config.requiredCapabilities || [])],
        },
        isAuthority: false,
        player: null,
        session: null,
      };
      emit(lifecycleListeners, { state: "ready" });
      if (!appSdk.isAvailable()) {
        void ensureBrowserNicknameUi().catch((error) => {
          global.console?.warn?.("Playmesh 浏览器游戏菜单初始化失败", error);
        });
      }
      void renderPerformanceUi();
      return bootstrap;
    }
    const appIdentity = appSdk.isAvailable()
      ? appSdk.identity.getCurrent()
      : null;
    const preferredNickname = appIdentity?.nickname || config.nickname;
    const nickname = preferredNickname
      ? validateNickname(preferredNickname, false)
      : await resolveBrowserNickname();
    if (!appIdentity && config.nickname) writeBrowserNickname(nickname);
    const playerId = appIdentity?.userId || resolveBrowserPlayerId();
    browserConnectionConfig = {
      ...config,
      nickname,
      playerId,
    };
    const joined = await joinBrowserWithRetry(browserConnectionConfig);
    applyBrowserJoin(config, joined);
    try {
      await connectBrowserSocket(config, joined);
      if (appSdk.isAvailable() && typeof appSdk.__syncAvatar === "function") {
        appSdk.__syncAvatar(joined.session.id, joined.credential.token).catch((error) => {
          global.console?.warn?.("Playmesh App 头像同步失败，游戏将继续", error);
        });
      }
    } catch (error) {
      global.console?.warn?.("Playmesh 主会话 WebSocket 首次连接失败，将开始重连", {
        error: error?.message || String(error),
      });
      browserReconnectOperation = reconnectBrowserSocket()
        .finally(() => {
          browserReconnectOperation = null;
          if (!runtimeExited &&
              browserConnectionConfig &&
              browserSocket?.readyState !== global.WebSocket.OPEN) {
            scheduleBrowserReconnect();
          }
        });
      await browserReconnectOperation;
    }
    emit(sessionListeners, bootstrap.session);
    emit(lifecycleListeners, { state: "ready" });
    mountBrowserNicknameControl().catch(() => {});
    void renderPerformanceUi();
    startLatencyProbes();
    void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
    return bootstrap;
  }

  function applyBrowserJoin(config, joined) {
    browserCredential = joined.credential;
    const core = new URL(config.coreBase);
    const binarySocketUrl = new URL(joined.binaryWebSocketPath, core);
    binarySocketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    binarySocketUrl.searchParams.set("token", joined.credential.token);
    binaryTransportConfig = { url: binarySocketUrl.toString() };
    if (joined.credential.reconnected) {
      previouslyConnectedPlayerIds.add(joined.credential.player.id);
    }
    // The Core may publish the connected snapshot as soon as the socket opens.
    // Seed bootstrap first so that an early session.state can update it safely.
    bootstrap = {
      type: "sdk.bootstrap",
      sdkVersion: PLAYMESH_SDK_VERSION,
      gameInfo: {
        id: joined.session.gameId,
        name: config.gameName,
        multiplayer: true,
        displayMode: joined.session.displayMode || config.displayMode,
        requiredCapabilities: [...(config.requiredCapabilities || [])],
      },
      isAuthority: false,
      player: publicPlayer(joined.credential.player),
      session: publicSession(joined.session),
    };
  }

  async function joinBrowserWithRetry(config) {
    const attempts = 30;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await joinBrowser(config);
      } catch (error) {
        if (!["session_full", "player_connected"].includes(error.code) || attempt === attempts) throw error;
        await new Promise((resolve) => global.setTimeout(resolve, 200));
      }
    }
  }

  async function joinBrowser(config) {
    const response = await fetch(new URL("v1/sessions/join", config.coreBase), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        joinCode: config.joinCode,
        nickname: config.nickname,
        shareToken: config.shareToken,
        playerId: config.playerId,
        source: config.playerSource || (appSdk.isAvailable() ? "lan_app" : "lan_html"),
      }),
    });
    const joined = await response.json();
    if (!response.ok) {
      const error = new Error(joined.error?.message || "加入对局失败");
      error.code = joined.error?.code;
      throw error;
    }
    return joined;
  }

  async function connectBrowserSocket(config, joined) {
    const core = new URL(config.coreBase);
    const socketUrl = new URL(joined.webSocketPath, core);
    socketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    socketUrl.searchParams.set("token", joined.credential.token);
    const socket = new WebSocket(socketUrl);
    browserSocket = socket;
    let opened = false;
    // Subscribe before awaiting open so the initial connected snapshot cannot
    // pass between the open event and listener registration.
    socket.addEventListener("message", (event) => {
      receive({ type: "transport.message", message: JSON.parse(event.data) });
    });
    socket.addEventListener("close", (event) => {
      if (browserSocket !== socket) return;
      browserSocket = null;
      if (opened) {
        receive({
          type: "transport.closed",
          error: event?.reason || (event?.code ? `close code ${event.code}` : undefined),
        });
      }
    });
    try {
      await new Promise((resolve, reject) => {
        socket.addEventListener("open", () => {
          opened = true;
          resolve();
        }, { once: true });
        socket.addEventListener(
          "error",
          () => reject(new Error("无法连接主机会话")),
          { once: true },
        );
        socket.addEventListener(
          "close",
          () => {
            if (!opened) reject(new Error("主会话 WebSocket 在连接完成前关闭"));
          },
          { once: true },
        );
      });
    } catch (error) {
      if (browserSocket === socket) browserSocket = null;
      if (socket.readyState < global.WebSocket.CLOSING) socket.close();
      throw error;
    }
  }

  function scheduleBrowserReconnect() {
    if (runtimeExited || !browserConnectionConfig || browserReconnectOperation) return;
    browserReconnectOperation = reconnectBrowserSocket()
      .finally(() => {
        browserReconnectOperation = null;
        if (!runtimeExited &&
            browserConnectionConfig &&
            browserSocket?.readyState !== global.WebSocket.OPEN) {
          scheduleBrowserReconnect();
        }
      });
    void browserReconnectOperation.catch(() => {});
  }

  async function reconnectBrowserSocket() {
    let attempt = 0;
    while (!runtimeExited && browserConnectionConfig) {
      attempt += 1;
      await waitForReconnect(attempt);
      global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", { attempt });
      try {
        const previousSession = bootstrap?.session;
        const joined = await joinBrowser(browserConnectionConfig);
        applyBrowserJoin(browserConnectionConfig, joined);
        await connectBrowserSocket(browserConnectionConfig, joined);
        if (appSdk.isAvailable() && typeof appSdk.__syncAvatar === "function") {
          void appSdk.__syncAvatar(
            joined.session.id,
            joined.credential.token,
          ).catch(() => {});
        }
        emitPlayerConnectionChanges(previousSession, bootstrap.session);
        emit(sessionListeners, bootstrap.session);
        startLatencyProbes();
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", { attempt });
        if (binaryReconnectWanted) {
          void ensureBinarySocket().catch(() => {});
        }
        if (!bootstrap.isAuthority) {
          void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
        }
        return browserSocket;
      } catch (error) {
        if (runtimeExited) break;
        global.console?.warn?.("Playmesh 主会话 WebSocket 重连失败，将继续重试", {
          attempt,
          error: error?.message || String(error),
          retryInMs: reconnectDelay(attempt + 1),
        });
      }
    }
    throw new Error("游戏页面已退出，停止主会话 WebSocket 重连");
  }

  const emptyAppSdk = {
    version: "3.0.0",
    ready: Promise.resolve({
      available: false,
      identity: null,
      device: { platform: "browser", capabilities: [] },
    }),
    isAvailable() { return false; },
    __restoreGameContentFocus() {},
    __requestExit() { return Promise.resolve(); },
    __confirmCapabilities() { return Promise.resolve(); },
    __configureRuntimeGame() { return emptyAppSdk.ready; },
    identity: { getCurrent() { return null; } },
    capabilities: {
      getRegistry() { return []; },
      getAvailable() { return []; },
      getDeclared() { return []; },
      create() { return Promise.reject(new Error("当前浏览器没有 Playmesh App 能力插件宿主")); },
    },
    device: {
      getPlatform() { return "browser"; },
      setFullscreen() { return Promise.reject(new Error("请使用浏览器 Fullscreen API")); },
      onInput() { return function unsubscribe() {}; },
    },
    ui: {
      initializeBrowser() { return false; },
      configure() { return { fallbackUi: false, floatingButton: false }; },
      restartGame() { global.location?.reload?.(); },
      openSharePanel() { return Promise.reject(new Error("当前浏览器没有 Playmesh App 平台分享宿主")); },
      showGameSidebar() { return Promise.resolve(false); },
      openRuntimeLogs() { return Promise.resolve(false); },
      enterFullscreen() { return Promise.reject(new Error("请使用浏览器 Fullscreen API")); },
      exitFullscreen() { return Promise.reject(new Error("请使用浏览器 Fullscreen API")); },
      openGameInfo() { return Promise.resolve(false); },
      setPerformanceVisible() { return false; },
      togglePerformance() { return false; },
      exitGame() { return Promise.reject(new Error("当前浏览器没有 Playmesh App 游戏退出宿主")); },
    },
  };
  const appSdk = global.playmeshApp || emptyAppSdk;
  const appPlatformUiConfigurationKey =
    typeof Symbol === "function" && typeof Symbol.for === "function"
      ? Symbol.for("playmesh.platform-ui.configuration")
      : "__PLAYMESH_PLATFORM_UI_CONFIGURATION__";
  function takeAppPlatformUiConfiguration() {
    const configuration = global[appPlatformUiConfigurationKey] || null;
    try {
      delete global[appPlatformUiConfigurationKey];
    } catch (_) {
      // The host-owned value is still never copied into a public SDK result.
    }
    return configuration;
  }
  let browserPlatformUiCatalog =
    global.__PLAYMESH_BROWSER__?._playmeshPlatformUi || null;
  if (global.__PLAYMESH_BROWSER__ &&
      typeof global.__PLAYMESH_BROWSER__ === "object") {
    delete global.__PLAYMESH_BROWSER__._playmeshPlatformUi;
  }
  let platformUiLocale = null;
  let runtimeLocale = null;
  let browserRuntimeLocale = null;
  let runtimeLocaleUsesBrowserSystem = false;
  let platformUiMessages = Object.freeze({});
  let platformUiThemeMode = "system";
  let platformUiTheme = "dark";
  const platformUiDarkModeQuery =
    global.matchMedia?.("(prefers-color-scheme: dark)") || null;
  const BROWSER_RUNTIME_LOCALE_FALLBACK = "zh";
  const BROWSER_PLATFORM_UI_FALLBACK_LOCALE = "zh-CN";

  function effectivePlatformUiTheme(mode) {
    if (mode === "light" || mode === "dark") return mode;
    return platformUiDarkModeQuery?.matches === false ? "light" : "dark";
  }

  function normalizePlatformUiLocaleId(value) {
    if (typeof value !== "string") return null;
    const normalized = value.trim();
    return /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(normalized)
      ? normalized
      : null;
  }

  function browserLocalePreferences() {
    try {
      const navigatorObject = global.navigator;
      const rawValues = [];
      if (Array.isArray(navigatorObject?.languages)) {
        rawValues.push(...navigatorObject.languages);
      }
      rawValues.push(navigatorObject?.language);
      const seen = new Set();
      const locales = [];
      for (const value of rawValues) {
        const locale = normalizePlatformUiLocaleId(value);
        if (!locale) continue;
        const normalized = locale.toLowerCase();
        if (seen.has(normalized)) continue;
        seen.add(normalized);
        locales.push(locale);
      }
      return locales;
    } catch (_) {
      return [];
    }
  }

  function resolveBrowserPlatformUiConfiguration(catalog, preferences) {
    const rawConfigurations = Array.isArray(catalog?.locales)
      ? catalog.locales
      : [];
    const configurations = rawConfigurations.filter((configuration) => {
      const locale = normalizePlatformUiLocaleId(configuration?.locale);
      const messages = configuration?.messages;
      return Boolean(
        locale &&
        messages &&
        typeof messages === "object" &&
        !Array.isArray(messages) &&
        Object.keys(messages).length > 0,
      );
    });
    const fallback = configurations.find(
      (configuration) =>
        configuration.locale.toLowerCase() ===
          BROWSER_PLATFORM_UI_FALLBACK_LOCALE.toLowerCase(),
    );
    if (!fallback) {
      throw new Error(
        `Browser platform UI ${BROWSER_PLATFORM_UI_FALLBACK_LOCALE} fallback is unavailable`,
      );
    }
    for (const preference of preferences) {
      const exact = configurations.find(
        (configuration) =>
          configuration.locale.toLowerCase() === preference.toLowerCase(),
      );
      if (exact) return exact;
    }
    for (const preference of preferences) {
      const language = preference.split("-")[0].toLowerCase();
      const languageMatch = configurations.find(
        (configuration) =>
          configuration.locale.split("-")[0].toLowerCase() === language,
      );
      if (languageMatch) return languageMatch;
    }
    return fallback;
  }

  function takeBrowserPlatformUiConfiguration() {
    const catalog = browserPlatformUiCatalog;
    browserPlatformUiCatalog = null;
    const preferences = browserLocalePreferences();
    browserRuntimeLocale =
      preferences[0] || BROWSER_RUNTIME_LOCALE_FALLBACK;
    return resolveBrowserPlatformUiConfiguration(catalog, preferences);
  }

  function configurePlatformUi(configuration, exposedLocale) {
    const locale = normalizePlatformUiLocaleId(configuration?.locale);
    const normalizedExposedLocale = normalizePlatformUiLocaleId(
      exposedLocale || locale,
    );
    const messages = configuration?.messages;
    const themeMode = configuration?.theme || "system";
    if (!locale ||
        !normalizedExposedLocale ||
        !["system", "light", "dark"].includes(themeMode) ||
        !messages ||
        typeof messages !== "object" ||
        Array.isArray(messages)) {
      throw new Error("Platform UI localization configuration is invalid");
    }
    const entries = Object.entries(messages);
    if (entries.length === 0) {
      throw new Error("Platform UI localization messages are empty");
    }
    for (const [key, value] of entries) {
      if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(key) ||
          typeof value !== "string") {
        throw new Error("Platform UI localization messages must be strings");
      }
    }
    platformUiLocale = locale;
    runtimeLocale = normalizedExposedLocale;
    platformUiMessages = Object.freeze({ ...messages });
    platformUiThemeMode = themeMode;
    platformUiTheme = effectivePlatformUiTheme(themeMode);
    refreshCapabilityConsentUi(capabilityConsentUi);
    refreshBrowserPlatformUi(browserNicknameUi);
    refreshPerformancePlatformUi(performanceUi);
  }

  function platformUiSystemThemeChanged() {
    if (platformUiThemeMode !== "system") return;
    platformUiTheme = effectivePlatformUiTheme("system");
    refreshCapabilityConsentUi(capabilityConsentUi);
    refreshBrowserPlatformUi(browserNicknameUi);
    refreshPerformancePlatformUi(performanceUi);
  }
  platformUiDarkModeQuery?.addEventListener?.(
    "change",
    platformUiSystemThemeChanged,
  );

  function platformText(key, argumentsMap = {}) {
    const template = platformUiMessages[key];
    if (typeof template !== "string") {
      throw new Error(`Platform UI localization message is unavailable: ${key}`);
    }
    return template.replace(/\{([A-Za-z0-9_]+)\}/g, (_, name) =>
      String(argumentsMap[name] ?? ""));
  }

  function platformHtml(key, argumentsMap = {}) {
    return escapeCapabilityHtml(platformText(key, argumentsMap));
  }

  function isPlatformUiEditableTarget(target) {
    if (!target) return false;
    if (target.isContentEditable === true) return true;
    const tagName = String(target.tagName || "").toLowerCase();
    return tagName === "input" || tagName === "textarea" || tagName === "select";
  }

  function platformUiEventKey(event) {
    if (typeof event?.key === "string" && event.key.length > 0) {
      return event.key;
    }
    return {
      8: "Backspace",
      9: "Tab",
      13: "Enter",
      27: "Escape",
      32: " ",
      35: "End",
      36: "Home",
      37: "ArrowLeft",
      38: "ArrowUp",
      39: "ArrowRight",
      40: "ArrowDown",
    }[event?.keyCode] || "";
  }

  function isPlatformUiBackEvent(event) {
    const key = platformUiEventKey(event);
    if (key === "Escape" ||
        key === "Esc" ||
        key === "Back" ||
        key === "BrowserBack" ||
        key === "GoBack" ||
        key === "XF86Back" ||
        event?.keyCode === 4 ||
        event?.keyCode === 461 ||
        event?.keyCode === 10009) {
      return true;
    }
    return key === "Backspace" && !isPlatformUiEditableTarget(event?.target);
  }

  function isPlatformUiMenuEvent(event) {
    const key = platformUiEventKey(event);
    return key === "F10" ||
      key === "ContextMenu" ||
      key === "Menu" ||
      event?.keyCode === 82 ||
      event?.keyCode === 93 ||
      event?.keyCode === 121;
  }

  function platformUiControls(value) {
    const raw = typeof value === "function" ? value() : value;
    return Array.from(raw || []).filter(
      (control) =>
        control &&
        !control.hidden &&
        !control.disabled &&
        control.getAttribute?.("aria-hidden") !== "true",
    );
  }

  function focusPlatformUiControl(control) {
    if (!control || control.hidden || control.disabled ||
        typeof control.focus !== "function") {
      return false;
    }
    try {
      control.focus({ preventScroll: true });
    } catch (_) {
      control.focus();
    }
    return true;
  }

  function setPlatformUiRovingTabStop(controls, activeControl) {
    const available = platformUiControls(controls);
    const active = available.includes(activeControl)
      ? activeControl
      : available[0] || null;
    for (const control of available) {
      control.setAttribute?.("tabindex", control === active ? "0" : "-1");
    }
    return active;
  }

  function consumePlatformUiKey(event) {
    event?.preventDefault?.();
    event?.stopPropagation?.();
  }

  function activatePlatformUiControl(control) {
    if (!control || control.disabled) return;
    if (typeof control.click === "function") {
      control.click();
      return;
    }
    control.onclick?.({
      currentTarget: control,
      target: control,
      preventDefault() {},
      stopPropagation() {},
    });
  }

  function installPlatformUiKeyboardNavigation(
    container,
    controls,
    { roving = false, trap = false, onBack = null } = {},
  ) {
    if (!container?.addEventListener) return;
    if (roving) setPlatformUiRovingTabStop(controls, null);
    container.addEventListener("keydown", (event) => {
      if (isPlatformUiBackEvent(event)) {
        consumePlatformUiKey(event);
        onBack?.();
        return;
      }
      const available = platformUiControls(controls);
      if (available.length === 0) return;
      const currentIndex = available.indexOf(event.target);
      const key = platformUiEventKey(event);
      if (trap && key === "Tab") {
        consumePlatformUiKey(event);
        const nextIndex = event.shiftKey
          ? (currentIndex <= 0 ? available.length - 1 : currentIndex - 1)
          : (currentIndex < 0 || currentIndex === available.length - 1
              ? 0
              : currentIndex + 1);
        focusPlatformUiControl(available[nextIndex]);
        return;
      }
      if (isPlatformUiEditableTarget(event.target)) return;
      if ((key === "Enter" || key === " " ||
          key === "Spacebar") && currentIndex >= 0) {
        consumePlatformUiKey(event);
        activatePlatformUiControl(available[currentIndex]);
        return;
      }
      let nextIndex = null;
      if (key === "Home") {
        nextIndex = 0;
      } else if (key === "End") {
        nextIndex = available.length - 1;
      } else if (key === "ArrowRight" || key === "ArrowDown") {
        nextIndex = currentIndex < 0
          ? 0
          : (currentIndex + 1) % available.length;
      } else if (key === "ArrowLeft" || key === "ArrowUp") {
        nextIndex = currentIndex <= 0
          ? available.length - 1
          : currentIndex - 1;
      }
      if (nextIndex == null) return;
      consumePlatformUiKey(event);
      const next = available[nextIndex];
      if (roving) setPlatformUiRovingTabStop(available, next);
      focusPlatformUiControl(next);
    });
  }

  function openPlatformUiLayer(layer, initialFocus, returnFocus = null) {
    if (!layer) return;
    layer.__playmeshReturnFocus =
      returnFocus ||
      layer.getRootNode?.().activeElement ||
      global.document?.activeElement ||
      null;
    layer.hidden = false;
    global.setTimeout(() => focusPlatformUiControl(initialFocus), 0);
  }

  function closePlatformUiLayer(layer, fallbackFocus = null) {
    if (!layer) return;
    const returnFocus = layer.__playmeshReturnFocus || fallbackFocus;
    layer.__playmeshReturnFocus = null;
    layer.hidden = true;
    global.setTimeout(
      () => focusPlatformUiControl(returnFocus || fallbackFocus),
      0,
    );
  }

  function normalizeCapabilityList(value) {
    if (!Array.isArray(value)) return [];
    return [...new Set(value.filter((item) => typeof item === "string" && item.length > 0))];
  }

  function capabilityConsentContext(appBootstrap) {
    const browserConfig = global.__PLAYMESH_BROWSER__;
    const declaredForCurrentPage = browserConfig
      ? browserConfig.requiredCapabilities
      : appSdk.isAvailable()
        ? appSdk.capabilities.getDeclared?.()
        : appBootstrap?.device?.declaredCapabilities;
    const required = normalizeCapabilityList(declaredForCurrentPage);
    const available = normalizeCapabilityList(
      appSdk.isAvailable()
        ? appBootstrap?.device?.capabilities || appSdk.capabilities.getAvailable()
        : browserConfig?.availableCapabilities,
    );
    const definitions = Array.isArray(browserConfig?.capabilityRegistry)
      ? browserConfig.capabilityRegistry
      : Array.isArray(appBootstrap?.capabilityRegistry)
        ? appBootstrap.capabilityRegistry
        : [];
    return {
      gameName:
        browserConfig?.gameName || platformText("capability.current_game"),
      required,
      available: new Set(available),
      definitions: new Map(definitions.map((definition) => [definition.code, definition])),
    };
  }

  const platformCapabilityMessageRoots = new Map([
    ["media.camera", "capability.media.camera"],
    ["media.microphone", "capability.media.microphone"],
    ["device.midi", "capability.device.midi"],
    ["device.vibration", "capability.device.vibration"],
  ]);

  function capabilityDisplayText(capability, definition) {
    const messageRoot = platformCapabilityMessageRoots.get(capability);
    if (messageRoot) {
      return {
        name: platformText(`${messageRoot}.name`),
        description: platformText(`${messageRoot}.description`),
      };
    }
    return {
      name: definition?.name || capability,
      description: definition?.description || "",
    };
  }

  async function requestCapabilityConsent(appBootstrap) {
    const context = capabilityConsentContext(appBootstrap);
    if (context.required.length === 0) return;
    const document = global.document;
    if (!document) throw new Error("当前页面无法显示游戏能力确认");
    if (!document.body) {
      await new Promise((resolve) => document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    capabilityConsentUi?.host.remove();
    const returnFocus = document.activeElement || null;
    const host = document.createElement("div");
    host.id = "playmesh-capability-consent";
    host.setAttribute("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    const rows = context.required.map((capability) => {
      const definition = context.definitions.get(capability);
      const displayText = capabilityDisplayText(capability, definition);
      const label = displayText.name;
      const descriptionText = displayText.description;
      const description = descriptionText
        ? `<em class="capability-description">${escapeCapabilityHtml(descriptionText)}</em>`
        : "";
      const unsupported = context.available.has(capability)
        ? ""
        : `<span class="unsupported">${platformHtml("capability.unsupported")}</span>`;
      return `<li data-capability="${escapeCapabilityHtml(capability)}"><span><strong class="capability-name">${escapeCapabilityHtml(label)}</strong>${description}<small>${escapeCapabilityHtml(capability)}</small></span>${unsupported}</li>`;
    }).join("");
    root.innerHTML = `<style>
      :host{all:initial;--pm-overlay:#050b12e8;--pm-surface:#18201d;--pm-text:#f8fafc;--pm-muted:#cbd5e1;--pm-border:#ffffff24;--pm-row:#ffffff0a;--pm-row-border:#ffffff18;--pm-secondary-bg:#ffffff0b;--pm-secondary-border:#ffffff30;--pm-secondary-text:#e2e8f0;--pm-focus:#78a6ff;--pm-warning:#fbbf24;font-family:system-ui,"Microsoft YaHei",sans-serif;letter-spacing:0;color-scheme:dark}
      :host([data-theme="light"]){--pm-overlay:#e8edf4d9;--pm-surface:#ffffff;--pm-text:#17202b;--pm-muted:#526071;--pm-border:#9aa8b8;--pm-row:#f3f6f9;--pm-row-border:#d5dde6;--pm-secondary-bg:#f5f7fa;--pm-secondary-border:#98a6b6;--pm-secondary-text:#1f2937;--pm-focus:#075dce;--pm-warning:#8a4b00;color-scheme:light}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;box-sizing:border-box;padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));background:var(--pm-overlay);color:var(--pm-text)}
      .card{box-sizing:border-box;display:flex;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);width:min(100%,460px);padding:26px;flex-direction:column;overflow:hidden;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface);box-shadow:0 20px 56px #0005}
      .content{min-height:0;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable;-webkit-overflow-scrolling:touch}
      h2{margin:0;font-size:25px;line-height:1.3}p{margin:10px 0 18px;color:var(--pm-muted);font-size:14px;line-height:1.7}
      ul{display:grid;gap:10px;margin:0;padding:0;list-style:none}li{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:13px 14px;border:1px solid var(--pm-row-border);border-radius:8px;background:var(--pm-row)}
      strong{display:block;font-size:15px}em{display:block;margin-top:4px;color:var(--pm-muted);font:normal 12px/1.5 system-ui}small{display:block;margin-top:4px;color:var(--pm-muted);font-size:11px}.unsupported{flex:none;color:var(--pm-warning);font-size:12px}
      .actions{display:flex;flex:none;gap:10px;margin-top:18px}.actions button{min-height:46px;flex:1;border-radius:8px;font:700 14px/1 system-ui;cursor:pointer;touch-action:manipulation}.actions button:focus-visible{outline:3px solid var(--pm-focus);outline-offset:2px}
      .deny{border:1px solid var(--pm-secondary-border);background:var(--pm-secondary-bg);color:var(--pm-secondary-text)}.allow{border:0;background:#087f6d;color:#fff}
      @media (max-height:440px),(max-width:420px){.overlay{padding:10px}.card{max-height:calc(100vh - 20px);max-height:calc(100dvh - 20px);padding:16px;border-radius:8px}h2{font-size:20px}p{margin:6px 0 10px;line-height:1.45}ul{gap:7px}li{padding:9px 10px}.actions{margin-top:10px}.actions button{min-height:42px}}
    </style><div class="overlay" role="dialog" aria-modal="true" aria-labelledby="capability-title"><div class="card"><div class="content"><h2 class="capability-title" id="capability-title">${platformHtml("capability.title", { gameName: context.gameName })}</h2><p class="capability-copy">${platformHtml("capability.description")}</p><ul>${rows}</ul></div><div class="actions"><button class="deny" type="button" aria-label="${platformHtml("capability.deny")}">${platformHtml("capability.deny")}</button><button class="allow" type="button" aria-label="${platformHtml("capability.allow")}">${platformHtml("capability.allow")}</button></div></div></div>`;
    document.body.appendChild(host);
    capabilityConsentUi = { host, root, context, denied: false };
    const deny = root.querySelector(".deny");
    const allow = root.querySelector(".allow");
    const decision = await new Promise((resolve) => {
      allow.addEventListener("click", () => resolve("allow"), { once: true });
      deny.addEventListener("click", () => resolve("deny"), { once: true });
      installPlatformUiKeyboardNavigation(
        root,
        () => [deny, allow],
        {
          trap: true,
          onBack: () => resolve("back"),
        },
      );
      global.setTimeout(() => focusPlatformUiControl(deny), 0);
    });
    if (decision === "allow") {
      if (appSdk.isAvailable() && typeof appSdk.__confirmCapabilities === "function") {
        await appSdk.__confirmCapabilities();
      }
      host.remove();
      capabilityConsentUi = null;
      focusPlatformUiControl(returnFocus);
      return;
    }
    if (decision === "deny") {
      root.querySelector(".actions").remove();
      capabilityConsentUi.denied = true;
      root.querySelector(".capability-copy").textContent =
        platformText("capability.denied");
    }
    const error = new Error("用户拒绝了当前游戏的能力请求");
    error.code = "capability_denied";
    if (appSdk.isAvailable() && typeof appSdk.__requestExit === "function") {
      await appSdk.__requestExit().catch(() => {});
    } else if (global.history?.length > 1) {
      global.setTimeout(() => global.history.back(), 0);
    }
    if (decision === "back") {
      host.remove();
      capabilityConsentUi = null;
      focusPlatformUiControl(returnFocus);
    }
    throw error;
  }

  function refreshCapabilityConsentUi(ui) {
    if (!ui?.root) return;
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    const title = ui.root.querySelector?.(".capability-title");
    if (title) {
      title.textContent = platformText("capability.title", {
        gameName: ui.context.gameName,
      });
    }
    const copy = ui.root.querySelector?.(".capability-copy");
    if (copy) {
      copy.textContent = platformText(
        ui.denied ? "capability.denied" : "capability.description",
      );
    }
    const deny = ui.root.querySelector?.(".deny");
    if (deny) {
      deny.textContent = platformText("capability.deny");
      deny.setAttribute?.("aria-label", platformText("capability.deny"));
    }
    const allow = ui.root.querySelector?.(".allow");
    if (allow) {
      allow.textContent = platformText("capability.allow");
      allow.setAttribute?.("aria-label", platformText("capability.allow"));
    }
    for (const element of ui.root.querySelectorAll?.(".unsupported") || []) {
      element.textContent = platformText("capability.unsupported");
    }
    for (const row of ui.root.querySelectorAll?.("[data-capability]") || []) {
      const capability = row.getAttribute?.("data-capability");
      if (!capability) continue;
      const definition = ui.context.definitions.get(capability);
      const displayText = capabilityDisplayText(capability, definition);
      const name = row.querySelector?.(".capability-name");
      const description = row.querySelector?.(".capability-description");
      if (name) {
        name.textContent = displayText.name;
      }
      if (description) {
        description.textContent = displayText.description;
      }
    }
  }

  function escapeCapabilityHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  const browserConsoleLogs = [];
  const BROWSER_CONSOLE_LOG_LIMIT = 500;
  let browserConsoleCaptureInstalled = false;
  const playmesh = {
    version: PLAYMESH_SDK_VERSION,
    ready: null,
    app: appSdk,
    runtime: Object.freeze({
      getLocale() {
        if (!runtimeLocale) {
          throw new Error("playmesh.runtime.getLocale requires await playmesh.ready");
        }
        return runtimeLocale;
      },
    }),
    gameInfo: Object.freeze({
      getCurrent() {
        const info = bootstrap?.gameInfo;
        if (!info) return null;
        return {
          ...info,
          requiredCapabilities: [...(info.requiredCapabilities || [])],
        };
      },
    }),
    session: {
      onStateChange(callback) {
        const unsubscribe = subscribe(sessionListeners, callback);
        if (bootstrap) callback(bootstrap.session);
        return unsubscribe;
      },
      onPlayerJoin(callback) {
        return subscribe(playerJoinListeners, callback);
      },
      onPlayerLeave(callback) {
        return subscribe(playerLeaveListeners, callback);
      },
      onPlayerReconnect(callback) {
        return subscribe(playerReconnectListeners, callback);
      },
      isAuthority() {
        return Boolean(bootstrap && bootstrap.isAuthority);
      },
      getCurrent() {
        return bootstrap && bootstrap.session;
      },
      start() {
        return post("session.start", {}).then(publicSession);
      },
      finish() {
        return post("session.finish", {}).then(publicSession);
      },
    },
    player: {
      getCurrent() {
        return bootstrap && bootstrap.player;
      },
      setNickname(nickname) {
        if (!global.__PLAYMESH_BROWSER__ || appSdk.isAvailable()) {
          return Promise.reject(new Error("修改昵称仅适用于浏览器玩家"));
        }
        if (global.__PLAYMESH_BROWSER__.mode === "solo") {
          return Promise.reject(new Error("单机分享没有玩家昵称"));
        }
        return updateBrowserNickname(nickname);
      },
    },
    game: {
      submitAction(action) {
        return post("game.submitAction", action);
      },
      onMessage(callback) {
        return subscribe(messageListeners, callback);
      },
      onEvent(callback) {
        return subscribe(messageListeners, callback);
      },
    },
    authority: {
      onService(handler) {
        if (!playmesh.session.isAuthority()) {
          throw new Error("只有 Authority Client 可以注册权威服务");
        }
        authorityService = handler;
        return function unregister() {
          if (authorityService === handler) authorityService = null;
        };
      },
    },
    binary: {
      authorityPlayerId: "authority",
      async createChannel(options) {
        await playmesh.ready;
        if (!playmesh.session.isAuthority()) {
          throw new Error("只有 Authority 可以创建 Binary Channel");
        }
        const mode = binaryModeCode(options?.mode);
        const result = await binaryRequest(
          (requestId) => encodeBinaryCreate(requestId, mode),
          { expectsChannel: true },
        );
        return createBinaryChannelHandle(result.id, result.mode);
      },
      async joinChannel(channelId) {
        await playmesh.ready;
        const normalized = binaryChannelIdFromBytes(binaryChannelIdToBytes(channelId));
        const existing = binaryChannels.get(normalized);
        if (existing && !existing.closed) return existing.handle;
        const result = await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_JOIN, requestId, normalized),
          { expectsChannel: true },
        );
        return createBinaryChannelHandle(result.id, result.mode);
      },
    },
    sync: {
      startAuthority: startSyncAuthority,
      submitAction(payload) {
        return submitSyncEnvelope("input.action", payload);
      },
      submitState: submitStateInput,
      requestSnapshot() {
        return submitSyncEnvelope("snapshot.request", {});
      },
      getSnapshot() {
        return currentSyncSnapshot && cloneJson(currentSyncSnapshot, "同步快照");
      },
      observe(callback) {
        const unsubscribe = subscribe(syncListeners, callback);
        if (currentSyncSnapshot) callback(cloneJson(currentSyncSnapshot, "同步快照"));
        return unsubscribe;
      },
    },
    lifecycle: {
      onChange(callback) {
        return subscribe(lifecycleListeners, callback);
      },
      onPause(callback) {
        return subscribe(pauseListeners, callback);
      },
      onResume(callback) {
        return subscribe(resumeListeners, callback);
      },
      onExit(callback) {
        return subscribe(exitListeners, callback);
      },
    },
    performance: {
      getFps() {
        return currentFps;
      },
      onFps(callback) {
        const unsubscribe = subscribe(fpsListeners, callback);
        callback(currentFps);
        return unsubscribe;
      },
      getLatency() {
        return currentLatency;
      },
      getLatencyDiagnostics() {
        return latencyDiagnostics && cloneJson(latencyDiagnostics, "延迟诊断");
      },
      onLatency(callback) {
        const unsubscribe = subscribe(latencyListeners, callback);
        callback(currentLatency);
        return unsubscribe;
      },
      setVisible(visible) {
        performanceVisible = visible !== false;
        void renderPerformanceUi();
      },
      reportFrame(timestamp = global.performance?.now?.() || Date.now()) {
        if (typeof timestamp !== "number" || !Number.isFinite(timestamp)) {
          throw new Error("无效的帧时间");
        }
        fpsFrameCount += 1;
        fpsWindowStartedAt ??= timestamp;
        const elapsed = timestamp - fpsWindowStartedAt;
        if (elapsed < 1000) return currentFps;
        currentFps = Math.round((fpsFrameCount * 1000) / elapsed);
        fpsFrameCount = 0;
        fpsWindowStartedAt = timestamp;
        emit(fpsListeners, currentFps);
        void renderPerformanceUi();
        if (!global.__PLAYMESH_BROWSER__) {
          post("performance.fps", { fps: currentFps }).catch(() => {});
        }
        return currentFps;
      },
    },
    storage: {
      getBucket(bucket) {
        validateStorageName(bucket, "bucket");
        return {
          getData(key) {
            validateStorageName(key, "key");
            return storageCall("storage.get", bucket, key);
          },
          setData(key, value) {
            validateStorageName(key, "key");
            JSON.stringify(value);
            return storageCall("storage.set", bucket, key, value);
          },
          removeData(key) {
            validateStorageName(key, "key");
            return storageCall("storage.remove", bucket, key);
          },
          clearData() {
            return storageCall("storage.clear", bucket);
          },
          upload(file) {
            return storageUpload(bucket, file);
          },
        };
      },
    },
    __receive: receive,
  };

  registerAppPlatformUiRuntime();
  global.playmesh = playmesh;
  global.console?.info?.("Playmesh Game SDK 注入成功", {
    version: PLAYMESH_SDK_VERSION,
  });
  if (global.chrome && global.chrome.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  global.addEventListener?.("pagehide", () => markRuntimeExited("游戏页面已退出"));
  playmesh.ready = appSdk.ready.then(async (initialAppBootstrap) => {
    let appBootstrap = initialAppBootstrap;
    const runtimeGameDeclaration = global.__PLAYMESH_BROWSER__;
    if (runtimeGameDeclaration &&
        appSdk.isAvailable() &&
        typeof appSdk.__configureRuntimeGame === "function") {
      appBootstrap = await appSdk.__configureRuntimeGame({
        requiredCapabilities:
          runtimeGameDeclaration.requiredCapabilities || [],
      });
    }
    const appPlatformUiConfiguration = takeAppPlatformUiConfiguration();
    const platformUiConfiguration = appPlatformUiConfiguration ||
      takeBrowserPlatformUiConfiguration();
    if (appPlatformUiConfiguration) browserPlatformUiCatalog = null;
    runtimeLocaleUsesBrowserSystem = !appPlatformUiConfiguration;
    configurePlatformUi(
      platformUiConfiguration,
      appPlatformUiConfiguration?.locale || browserRuntimeLocale,
    );
    global.console?.info?.("Playmesh Game SDK 等待能力确认");
    await requestCapabilityConsent(appBootstrap);
    global.console?.info?.("Playmesh Game SDK 请求宿主就绪");
    return global.__PLAYMESH_BROWSER__
      ? connectBrowserFullscreen({
          ...global.__PLAYMESH_BROWSER__,
          ...(appBootstrap?.runtime?.coreBase
            ? { coreBase: appBootstrap.runtime.coreBase }
            : {}),
          ...(appBootstrap?.runtime?.playerSource
            ? { playerSource: appBootstrap.runtime.playerSource }
            : {}),
        })
      : post("sdk.ready", {});
  });

  async function connectBrowserFullscreen(config) {
    if (appSdk.isAvailable() && typeof appSdk.device?.setFullscreen === "function") {
      try {
        await appSdk.device.setFullscreen(true, config.orientation);
        global.console?.info?.("Playmesh 扫码加入页面已自动进入全屏");
      } catch (error) {
        global.console?.warn?.("Playmesh 扫码加入页面自动全屏失败，游戏将继续", error);
      }
    } else {
      void requestBrowserFullscreen(config.orientation).catch((error) => {
        global.console?.info?.(
          "浏览器未允许自动全屏，可通过游戏菜单手动进入",
          error,
        );
      });
    }
    return connectBrowser(config);
  }

  function markRuntimeExited(reason) {
    if (runtimeExited) return;
    runtimeExited = true;
    browserConnectionConfig = null;
    const socket = browserSocket;
    browserSocket = null;
    if (socket && socket.readyState < global.WebSocket.CLOSING) {
      socket.close(1000, reason);
    }
    closeBinaryTransport(reason, true);
    global.console?.info?.("Playmesh 游戏页面已退出，停止 WebSocket 重连", { reason });
  }

  async function lockBrowserOrientation(orientation) {
    if (orientation !== "landscape" && orientation !== "portrait") return;
    const lock = global.screen?.orientation?.lock;
    if (typeof lock !== "function") {
      throw new Error("当前浏览器不支持锁定屏幕方向");
    }
    await lock.call(global.screen.orientation, orientation);
  }

  async function requestBrowserFullscreen(orientation) {
    const target = global.document?.documentElement;
    if (!target || typeof target.requestFullscreen !== "function") {
      throw new Error("当前浏览器不支持全屏");
    }
    await target.requestFullscreen();
    await lockBrowserOrientation(orientation);
  }

  async function storageCall(command, bucket, key, value) {
    if (!global.__PLAYMESH_BROWSER__) {
      return post(command, { bucket, key, value });
    }
    await playmesh.ready;
    const requestId = `browser-storage-${Date.now()}-${++browserStorageSequence}`;
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        browserStoragePending.delete(requestId);
        reject(new Error(`Authority 存储请求超时: ${command}`));
      }, 15000);
      browserStoragePending.set(requestId, { resolve, reject, timer });
      sendBrowserTransport("game.submitAction", {
        __playmeshStorageRequest: {
          requestId,
          command,
          bucket,
          ...(key === undefined ? {} : { key }),
          ...(value === undefined ? {} : { value }),
        },
      }).catch((error) => {
        global.clearTimeout(timer);
        browserStoragePending.delete(requestId);
        reject(error);
      });
    });
  }

  function settleBrowserStorage(response) {
    const operation = browserStoragePending.get(response?.requestId);
    if (!operation) return;
    browserStoragePending.delete(response.requestId);
    global.clearTimeout(operation.timer);
    if (response.error != null) operation.reject(new Error(String(response.error)));
    else operation.resolve(response.result);
  }

  async function storageUpload(bucket, file) {
    await playmesh.ready;
    if (!file || typeof file.name !== "string" || typeof file.size !== "number") {
      throw new Error("upload(file) 需要浏览器 File");
    }
    if (file.size > 256 * 1024 * 1024) {
      throw new Error("上传文件不能超过 256 MiB");
    }
    const config = global.__PLAYMESH_BROWSER__;
    const base = config?.bucketEndpoint || "/bucket";
    const url = `${base}/${encodeURIComponent(bucket)}?name=${encodeURIComponent(file.name)}`;
    const headers = {};
    if (config?.shareToken) {
      headers["X-Playmesh-Share-Token"] = config.shareToken;
    }
    const response = await global.fetch(url, {
      method: "POST",
      headers,
      body: file,
    });
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      // 网关异常返回也统一转换成 SDK Error。
    }
    if (!response.ok || typeof payload?.url !== "string") {
      throw new Error(payload?.error || "文件上传失败");
    }
    return payload.url;
  }

  async function resolveBrowserNickname() {
    const cached = readBrowserNickname();
    if (cached) return cached;
    return openBrowserNicknameDialog({
      required: true,
      current: "",
      submit(nickname) {
        writeBrowserNickname(nickname);
      },
    });
  }

  function readBrowserNickname() {
    try {
      const cached = global.localStorage?.getItem(browserNicknameStorageKey);
      return validateNickname(cached, false);
    } catch (_) {
      return null;
    }
  }

  function writeBrowserNickname(nickname) {
    try {
      global.localStorage?.setItem(browserNicknameStorageKey, nickname);
    } catch (_) {
      // Private browsing may reject storage; the current session can still continue.
    }
  }

  function resolveBrowserPlayerId() {
    try {
      const cached = global.localStorage?.getItem(browserPlayerIdStorageKey);
      if (/^p_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(cached || "")) return cached;
    } catch (_) {
      // Continue with an in-memory identity when persistent storage is unavailable.
    }
    const bytes = new Uint8Array(16);
    if (global.crypto?.getRandomValues) {
      global.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    const playerId = `p_${[...bytes].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
    try {
      global.localStorage?.setItem(browserPlayerIdStorageKey, playerId);
    } catch (_) {
      // The current page can still join, but refresh cannot restore this identity.
    }
    return playerId;
  }

  async function updateBrowserNickname(value) {
    const nickname = validateNickname(value, true);
    await playmesh.ready;
    const config = global.__PLAYMESH_BROWSER__;
    const response = await fetch(new URL(
      `v1/sessions/${encodeURIComponent(bootstrap.session.id)}/players/me`,
      config.coreBase,
    ), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${browserCredential.token}`,
      },
      body: JSON.stringify({
        nickname,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error?.message || payload.error || "修改昵称失败");
    }
    bootstrap.session = publicSession(payload.session);
    bootstrap.player = publicPlayer(payload.player);
    writeBrowserNickname(nickname);
    emit(sessionListeners, bootstrap.session);
    return bootstrap.player;
  }

  function validateNickname(value, throws) {
    const nickname = typeof value === "string" ? value.trim() : "";
    if (nickname && [...nickname].length <= 32) return nickname;
    if (throws) throw new Error("昵称必须为 1 至 32 个字符");
    return null;
  }

  async function mountBrowserNicknameControl() {
    if (appSdk.isAvailable()) return;
    const ui = await ensureBrowserNicknameUi();
    if (!ui) return;
    ui.button.hidden = false;
    ui.button.onclick = () => {
      closePlatformUiLayer(ui.infoOverlay, ui.info);
      return openBrowserNicknameDialog({
        required: false,
        current: bootstrap?.player?.nickname || readBrowserNickname() || "",
        returnFocus: ui.info,
        submit: updateBrowserNickname,
      });
    };
  }

  async function openBrowserNicknameDialog(options) {
    const ui = await ensureBrowserNicknameUi();
    if (!ui) throw new Error("浏览器昵称界面不可用");
    ui.nicknameRequired = options.required === true;
    ui.title.textContent = platformText(
      ui.nicknameRequired ? "nickname.set_title" : "nickname.edit_title",
    );
    ui.input.value = options.current;
    ui.error.textContent = "";
    ui.close.hidden = options.required;
    openPlatformUiLayer(
      ui.overlay,
      ui.input,
      options.returnFocus || (options.required ? null : ui.pageReturnFocus),
    );
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (value, error = null) => {
        if (settled) return;
        settled = true;
        ui.onNicknameBack = null;
        closePlatformUiLayer(
          ui.overlay,
          options.returnFocus || ui.pageReturnFocus,
        );
        if (error) reject(error);
        else resolve(value);
      };
      ui.onNicknameBack = () => {
        if (ui.submit.disabled) return;
        if (!ui.nicknameRequired) {
          finish(null);
          return;
        }
        const error = new Error("Browser nickname setup was cancelled");
        error.name = "AbortError";
        finish(null, error);
      };
      ui.close.onclick = () => finish(null);
      ui.form.onsubmit = async (event) => {
        event.preventDefault();
        ui.error.textContent = "";
        ui.submit.disabled = true;
        try {
          const nickname = validateNickname(ui.input.value, false);
          if (!nickname) {
            ui.error.textContent = platformText("nickname.invalid");
            return;
          }
          await options.submit(nickname);
          finish(nickname);
        } catch (error) {
          global.console?.warn?.("Playmesh browser nickname update failed", error);
          ui.error.textContent = platformText("nickname.update_failed");
        } finally {
          ui.submit.disabled = false;
        }
      };
    });
  }

  function formatBrowserConsoleValue(value) {
    if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
    if (typeof value === "string") return value;
    if (typeof value === "bigint") return value.toString();
    try {
      const encoded = JSON.stringify(value);
      return encoded === undefined ? String(value) : encoded;
    } catch (_) {
      return String(value);
    }
  }

  function recordBrowserConsole(level, args, eventType = "console") {
    browserConsoleLogs.push({
      timestamp: Date.now(),
      level,
      eventType,
      message: args.map(formatBrowserConsoleValue).join(" "),
    });
    if (browserConsoleLogs.length > BROWSER_CONSOLE_LOG_LIMIT) {
      browserConsoleLogs.splice(0, browserConsoleLogs.length - BROWSER_CONSOLE_LOG_LIMIT);
    }
    if (browserNicknameUi?.logsOverlay && !browserNicknameUi.logsOverlay.hidden) {
      renderBrowserConsoleLogs(browserNicknameUi);
    }
  }

  function installBrowserConsoleCapture() {
    if (!global.__PLAYMESH_BROWSER__ ||
        appSdk.isAvailable() ||
        browserConsoleCaptureInstalled ||
        !global.console) {
      return;
    }
    browserConsoleCaptureInstalled = true;
    for (const level of ["log", "info", "warn", "error", "debug"]) {
      const nativeMethod = typeof global.console[level] === "function"
        ? global.console[level].bind(global.console)
        : null;
      if (!nativeMethod) continue;
      global.console[level] = (...args) => {
        nativeMethod(...args);
        recordBrowserConsole(level, args);
      };
    }
    global.addEventListener?.("error", (event) => {
      const resource = event.target && event.target !== global
        ? event.target.currentSrc || event.target.src || event.target.href
        : null;
      const error = event.error instanceof Error ? event.error : null;
      recordBrowserConsole(
        "error",
        [resource ? `Resource load failed: ${resource}` : error || event.message],
        resource ? "resource.error" : "uncaught.error",
      );
    }, true);
    global.addEventListener?.("unhandledrejection", (event) => {
      recordBrowserConsole("error", [event.reason], "unhandled.rejection");
    });
  }

  function formatBrowserConsoleTimestamp(timestamp) {
    const value = new Date(timestamp);
    try {
      return new Intl.DateTimeFormat(platformUiLocale || undefined, {
        dateStyle: "short",
        timeStyle: "medium",
      }).format(value);
    } catch (_) {
      // Older WebViews keep the deterministic fallback below.
    }
    const pad = (part) => String(part).padStart(2, "0");
    return `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())} ` +
      `${pad(value.getHours())}:${pad(value.getMinutes())}:${pad(value.getSeconds())}`;
  }

  function renderBrowserConsoleLogs(ui) {
    if (!ui?.logsOutput) return;
    ui.logsOutput.textContent = browserConsoleLogs.length
      ? browserConsoleLogs.map((entry) => {
          const eventType = entry.eventType === "console" ? "" : ` [${entry.eventType}]`;
          return `[${formatBrowserConsoleTimestamp(entry.timestamp)}] [${entry.level}]${eventType} ${entry.message}`;
        }).join("\n")
      : platformText("logs.empty");
    ui.logsOutput.scrollTop = ui.logsOutput.scrollHeight;
  }

  function registerAppPlatformUiRuntime() {
    if (typeof appSdk.__registerRuntimeUi !== "function") return;
    appSdk.__registerRuntimeUi({
      async reload() {
        if (playmesh.session.isAuthority()) {
          await post("session.reset", {});
        }
        global.location?.reload?.();
      },
      async getInfo() {
        await playmesh.ready;
        const gameInfo = playmesh.gameInfo.getCurrent();
        if (!gameInfo) return null;
        const session = playmesh.session.getCurrent();
        const player = playmesh.player.getCurrent();
        return {
          gameId: gameInfo.id,
          gameName: gameInfo.name,
          requiredCapabilities: [...gameInfo.requiredCapabilities],
          joinCode: session?.joinCode || null,
          multiplayer: gameInfo.multiplayer,
          isAuthority: playmesh.session.isAuthority(),
          playerName: player?.nickname || null,
          playerCount: Array.isArray(session?.players)
            ? session.players.length
            : null,
          gameSdkVersion: playmesh.version,
          appSdkVersion: appSdk.version,
          platform: playmesh.app.device.getPlatform() || "browser",
        };
      },
      getPerformance() {
        return {
          fps: currentFps,
          latency: currentLatency,
          multiplayer: Boolean(bootstrap?.session),
        };
      },
      setPerformanceVisible(visible) {
        performanceVisible = visible === true;
      },
    });
  }

  function exitBrowserGameFromSidebar(ui) {
    browserBackExitRequested = true;
    ui.closeSidebar(false);
    markRuntimeExited("用户从游戏菜单退出");
    try {
      if (browserBackInterceptionInstalled && global.history.length > 2) {
        global.history.go(-2);
        return;
      }
      global.close?.();
      global.setTimeout(() => {
        if (!global.closed) global.location?.replace?.("about:blank");
      }, 0);
    } catch (error) {
      global.console?.warn?.("浏览器无法离开当前游戏页面", error);
    }
  }

  async function ensureBrowserNicknameUi() {
    if (browserNicknameUi) return browserNicknameUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    const pageReturnFocus = global.document.activeElement || null;
    const host = global.document.createElement("div");
    host.id = "playmesh-browser-profile";
    host.setAttribute?.("lang", platformUiLocale);
    host.setAttribute?.("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#121720eb;--pm-surface-solid:#20242b;--pm-surface-hover:#343b46;--pm-text:#f4f7fb;--pm-muted:#d5dbe4;--pm-border:#596272;--pm-soft-border:#ffffff35;--pm-divider:#ffffff18;--pm-overlay:#0008;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-log-bg:#0b0f15;--pm-log-text:#dbe5f0;--pm-focus:#78a6ff;--pm-error:#fda4af;font-family:system-ui,"Microsoft YaHei",sans-serif;letter-spacing:0;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#fffffff2;--pm-surface-solid:#ffffff;--pm-surface-hover:#e8edf3;--pm-text:#18212c;--pm-muted:#526071;--pm-border:#91a0b0;--pm-soft-border:#aab5c2;--pm-divider:#d5dde6;--pm-overlay:#dce3ecd9;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-log-bg:#f4f7fa;--pm-log-text:#1f2937;--pm-focus:#075dce;--pm-error:#a1122f;color-scheme:light}
      button,input{box-sizing:border-box;font:inherit;letter-spacing:0}
      .sidebar-layer{position:fixed;inset:0;z-index:2147483646;color:var(--pm-text)}
      .sidebar-scrim{position:absolute;inset:0;width:100%;height:100%;padding:0;border:0;background:var(--pm-overlay);cursor:pointer}
      .sidebar{box-sizing:border-box;position:absolute;right:0;top:0;display:grid;grid-template-rows:auto minmax(0,1fr) auto;width:min(88vw,360px);height:100%;height:100dvh;padding:max(16px,env(safe-area-inset-top)) max(10px,env(safe-area-inset-right)) max(12px,env(safe-area-inset-bottom)) 10px;border-left:1px solid var(--pm-border);background:var(--pm-surface-solid);box-shadow:-18px 0 42px #0006}
      .sidebar-head{display:flex;align-items:center;gap:12px;padding:4px 10px 14px;border-bottom:1px solid var(--pm-divider)}
      .sidebar-mark{display:grid;place-items:center;width:34px;height:34px;border-radius:9px;background:#087f6d;color:#fff;font:800 18px/1 system-ui}
      .sidebar-title{margin:0;color:var(--pm-text);font-size:20px;line-height:1.25;font-weight:800}
      .sidebar-actions{min-height:0;overflow:auto;padding:8px 0}
      .sidebar-action{display:flex;align-items:center;gap:13px;width:100%;min-height:52px;padding:8px 12px;border:0;border-radius:8px;background:transparent;color:var(--pm-text);font:700 15px/1.25 system-ui,"Microsoft YaHei",sans-serif;text-align:left;cursor:pointer}
      .sidebar-action:hover{background:var(--pm-surface-hover)}.sidebar-action:focus-visible,.sidebar-scrim:focus-visible,.actions button:focus-visible,.logs-head button:focus-visible,.logs-output:focus-visible,input:focus-visible{outline:3px solid var(--pm-focus);outline-offset:-3px}
      .sidebar-action.continue{background:#087f6d;color:#fff}.sidebar-action.exit{color:var(--pm-error)}
      .sidebar-icon{display:grid;place-items:center;flex:0 0 24px;width:24px;font:800 19px/1 system-ui}
      .sidebar-foot{padding-top:8px;border-top:1px solid var(--pm-divider)}
      .panel{position:fixed;right:max(12px,env(safe-area-inset-right));top:max(12px,env(safe-area-inset-top));z-index:2147483645;display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--pm-soft-border);border-radius:8px;background:var(--pm-surface);color:var(--pm-text);font:700 12px/1 ui-monospace,SFMono-Regular,Consolas,monospace}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:20px;background:var(--pm-overlay)}
      .sidebar-layer[hidden],.overlay[hidden],.panel[hidden],.edit[hidden],.latency[hidden],.info-overlay[hidden],.logs-overlay[hidden]{display:none}
      form,.info-card{box-sizing:border-box;width:min(100%,380px);max-height:calc(100vh - 40px);max-height:calc(100dvh - 40px);overflow:auto;padding:20px;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface-solid);color:var(--pm-text);box-shadow:0 16px 40px #0005}
      h2{margin:0 0 16px;font-size:20px;line-height:1.3;letter-spacing:0}
      label{display:block;margin-bottom:6px;font-size:14px;font-weight:700}
      input{width:100%;height:44px;padding:8px 10px;border:1px solid var(--pm-border);border-radius:6px;color:var(--pm-field-text);background:var(--pm-field-bg)}
      .error{min-height:20px;margin:6px 0;color:var(--pm-error);font-size:13px}
      .actions{display:flex;justify-content:flex-end;gap:8px}
      .actions button{height:40px;padding:0 14px;border:1px solid var(--pm-border);border-radius:6px;background:var(--pm-surface-hover);color:var(--pm-text);cursor:pointer}
      .actions .save{border-color:#10b981;background:#0f766e;color:#fff;font-weight:700}
      .info-overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:20px;background:var(--pm-overlay)}.info-card p{margin:8px 0;color:var(--pm-muted);line-height:1.6}.info-card strong{color:var(--pm-text)}.info-card .actions{margin-top:18px}
      .logs-overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:14px;background:var(--pm-overlay)}.logs-card{box-sizing:border-box;display:grid;grid-template-rows:auto minmax(0,1fr) auto;width:min(100%,760px);height:min(78vh,620px);height:min(78dvh,620px);padding:16px;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface-solid);color:var(--pm-text);box-shadow:0 16px 40px #0005}.logs-head{display:flex;align-items:center;gap:10px;margin-bottom:10px}.logs-head h2{flex:1;margin:0}.logs-head button{height:36px;padding:0 12px;border:1px solid var(--pm-border);border-radius:6px;background:var(--pm-surface-hover);color:var(--pm-text);cursor:pointer}.logs-output{min-width:0;min-height:0;margin:0;padding:10px;overflow:auto;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-log-bg);color:var(--pm-log-text);white-space:pre-wrap;word-break:break-word;user-select:text;font:12px/1.5 ui-monospace,SFMono-Regular,Consolas,monospace}.logs-card .actions{margin-top:10px}
      button:disabled{cursor:wait;opacity:.65}
      @media (orientation:landscape){.sidebar{width:min(46vw,420px)}.sidebar-head{padding-bottom:10px}.sidebar-actions{padding:5px 0}.sidebar-action{min-height:46px}.sidebar-foot{padding-top:5px}}
    </style>
    <div class="sidebar-layer" hidden>
      <button class="sidebar-scrim" type="button" aria-label="${platformHtml("sidebar.continue")}" tabindex="-1"></button>
      <aside class="sidebar" role="dialog" aria-modal="true" aria-labelledby="playmesh-sidebar-title">
        <header class="sidebar-head"><span class="sidebar-mark" aria-hidden="true">P</span><h2 class="sidebar-title" id="playmesh-sidebar-title">${platformHtml("sidebar.title")}</h2></header>
        <nav class="sidebar-actions">
          <button class="sidebar-action continue" type="button"><span class="sidebar-icon" aria-hidden="true">▶</span><span>${platformHtml("sidebar.continue")}</span></button>
          <button class="sidebar-action reload" type="button"><span class="sidebar-icon" aria-hidden="true">↻</span><span>${platformHtml("sidebar.restart")}</span></button>
          <button class="sidebar-action logs" type="button"><span class="sidebar-icon" aria-hidden="true">≡</span><span>${platformHtml("sidebar.logs")}</span></button>
          <button class="sidebar-action enter-fullscreen" type="button"><span class="sidebar-icon" aria-hidden="true">⛶</span><span>${platformHtml("sidebar.enter_fullscreen")}</span></button>
          <button class="sidebar-action exit-fullscreen" type="button"><span class="sidebar-icon" aria-hidden="true">⊡</span><span>${platformHtml("sidebar.exit_fullscreen")}</span></button>
          <button class="sidebar-action info" type="button"><span class="sidebar-icon" aria-hidden="true">ⓘ</span><span>${platformHtml("sidebar.info")}</span></button>
          <button class="sidebar-action performance" type="button" aria-pressed="false"><span class="sidebar-icon" aria-hidden="true">◴</span><span>${platformHtml("sidebar.performance")}</span></button>
        </nav>
        <footer class="sidebar-foot"><button class="sidebar-action exit" type="button"><span class="sidebar-icon" aria-hidden="true">↩</span><span>${platformHtml("sidebar.exit")}</span></button></footer>
      </aside>
    </div>
    <div class="panel" hidden><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>
    <div class="overlay" role="dialog" aria-modal="true" aria-labelledby="playmesh-nickname-title" hidden>
      <form><h2 id="playmesh-nickname-title"></h2><label class="nickname-label" for="nickname">${platformHtml("nickname.label")}</label>
      <input id="nickname" maxlength="32" autocomplete="nickname" required>
      <div class="error" role="alert"></div><div class="actions">
      <button class="close" type="button" aria-label="${platformHtml("common.cancel")}">${platformHtml("common.cancel")}</button><button class="save" type="submit" aria-label="${platformHtml("common.save")}">${platformHtml("common.save")}</button>
      </div></form>
    </div>
    <div class="info-overlay" role="dialog" aria-modal="true" aria-labelledby="playmesh-info-title" hidden><div class="info-card"><h2 class="info-title" id="playmesh-info-title">${platformHtml("info.title")}</h2><p class="game-name"></p><p class="session-info"></p><div class="actions"><button class="edit" type="button" aria-label="${platformHtml("nickname.edit_action")}" hidden>${platformHtml("nickname.edit_action")}</button><button class="info-close" type="button" aria-label="${platformHtml("common.close")}">${platformHtml("common.close")}</button></div></div></div>
    <div class="logs-overlay" role="dialog" aria-modal="true" aria-labelledby="playmesh-logs-title" hidden><div class="logs-card"><div class="logs-head"><h2 class="logs-title" id="playmesh-logs-title">${platformHtml("logs.title")}</h2><button class="logs-clear" type="button" aria-label="${platformHtml("common.clear")}">${platformHtml("common.clear")}</button></div><pre class="logs-output" tabindex="0" aria-live="polite">${platformHtml("logs.empty")}</pre><div class="actions"><button class="logs-close" type="button" aria-label="${platformHtml("common.close")}">${platformHtml("common.close")}</button></div></div></div>`;
    global.document.body.appendChild(host);
    browserNicknameUi = {
      host,
      pageReturnFocus,
      sidebarLayer: root.querySelector(".sidebar-layer"),
      sidebar: root.querySelector(".sidebar"),
      sidebarTitle: root.querySelector(".sidebar-title"),
      sidebarScrim: root.querySelector(".sidebar-scrim"),
      continueButton: root.querySelector(".continue"),
      panel: root.querySelector(".panel"),
      fps: root.querySelector(".fps"),
      latency: root.querySelector(".latency"),
      performanceButton: root.querySelector(".performance"),
      button: root.querySelector(".edit"),
      overlay: root.querySelector(".overlay"),
      form: root.querySelector("form"),
      title: root.querySelector("h2"),
      nicknameLabel: root.querySelector(".nickname-label"),
      input: root.querySelector("input"),
      error: root.querySelector(".error"),
      close: root.querySelector(".close"),
      submit: root.querySelector(".save"),
      reload: root.querySelector(".reload"),
      enterFullscreen: root.querySelector(".enter-fullscreen"),
      exitFullscreen: root.querySelector(".exit-fullscreen"),
      info: root.querySelector(".info"),
      exit: root.querySelector(".exit"),
      logs: root.querySelector(".logs"),
      infoOverlay: root.querySelector(".info-overlay"),
      infoClose: root.querySelector(".info-close"),
      infoTitle: root.querySelector(".info-title"),
      gameName: root.querySelector(".game-name"),
      sessionInfo: root.querySelector(".session-info"),
      logsOverlay: root.querySelector(".logs-overlay"),
      logsOutput: root.querySelector(".logs-output"),
      logsTitle: root.querySelector(".logs-title"),
      logsClear: root.querySelector(".logs-clear"),
      logsClose: root.querySelector(".logs-close"),
    };
    const ui = browserNicknameUi;
    global.document.addEventListener?.("focusin", (event) => {
      if (event.target && event.target !== host) {
        ui.pageReturnFocus = event.target;
      }
    }, true);
    const sidebarControls = () => [
      ui.continueButton,
      ui.reload,
      ui.logs,
      ui.enterFullscreen,
      ui.exitFullscreen,
      ui.info,
      ui.performanceButton,
      ui.exit,
    ];
    const closeBrowserSidebar = (restoreFocus = true) => {
      ui.sidebarLayer.hidden = true;
      if (restoreFocus) focusPlatformUiControl(ui.pageReturnFocus);
    };
    const openBrowserSidebar = () => {
      const activeElement = global.document.activeElement;
      if (activeElement && activeElement !== host) ui.pageReturnFocus = activeElement;
      ui.sidebarLayer.hidden = false;
      const first = setPlatformUiRovingTabStop(
        sidebarControls(),
        ui.continueButton,
      );
      focusPlatformUiControl(first);
    };
    ui.openSidebar = openBrowserSidebar;
    ui.closeSidebar = closeBrowserSidebar;
    ui.continueButton.onclick = () => closeBrowserSidebar();
    ui.sidebarScrim.onclick = () => closeBrowserSidebar();
    ui.reload.onclick = () => {
      closeBrowserSidebar(false);
      global.location?.reload?.();
    };
    ui.performanceButton.onclick = () => {
      performanceVisible = !performanceVisible;
      void renderPerformanceUi();
      closeBrowserSidebar();
    };
    ui.enterFullscreen.onclick = async () => {
      closeBrowserSidebar(false);
      try {
        await requestBrowserFullscreen(browserConnectionConfig?.orientation);
      } catch (error) {
        global.console?.warn?.("浏览器全屏或方向锁定不可用，请手动调整", error);
      }
    };
    ui.exitFullscreen.onclick = () => {
      closeBrowserSidebar(false);
      if (global.document.fullscreenElement) {
        Promise.resolve(global.document.exitFullscreen?.()).catch(() => {});
      }
    };
    ui.info.onclick = () => {
      const config = global.__PLAYMESH_BROWSER__ || {};
      ui.infoTitle.textContent = platformText("info.title");
      ui.gameName.textContent =
        config.gameName || platformText("info.default_game");
      ui.sessionInfo.textContent = bootstrap?.session?.joinCode
        ? platformText("info.join_code", {
            joinCode: bootstrap.session.joinCode,
          })
        : platformText("info.solo_share");
      closeBrowserSidebar(false);
      openPlatformUiLayer(ui.infoOverlay, ui.infoClose, ui.pageReturnFocus);
    };
    ui.logs.onclick = () => {
      renderBrowserConsoleLogs(ui);
      closeBrowserSidebar(false);
      openPlatformUiLayer(ui.logsOverlay, ui.logsClose, ui.pageReturnFocus);
    };
    ui.infoClose.onclick = () => {
      closePlatformUiLayer(ui.infoOverlay, ui.pageReturnFocus);
    };
    ui.logsClear.onclick = () => {
      browserConsoleLogs.length = 0;
      renderBrowserConsoleLogs(ui);
    };
    ui.logsClose.onclick = () => {
      closePlatformUiLayer(ui.logsOverlay, ui.pageReturnFocus);
    };
    ui.exit.onclick = () => exitBrowserGameFromSidebar(ui);
    installPlatformUiKeyboardNavigation(
      ui.sidebar,
      sidebarControls,
      {
        trap: true,
        roving: true,
        onBack: () => closeBrowserSidebar(),
      },
    );
    installPlatformUiKeyboardNavigation(
      ui.overlay,
      () => [ui.input, ui.close, ui.submit],
      {
        trap: true,
        onBack: () => ui.onNicknameBack?.(),
      },
    );
    installPlatformUiKeyboardNavigation(
      ui.infoOverlay,
      () => [ui.button, ui.infoClose],
      {
        trap: true,
        onBack: () => ui.infoClose.onclick(),
      },
    );
    installPlatformUiKeyboardNavigation(
      ui.logsOverlay,
      () => [ui.logsClear, ui.logsOutput, ui.logsClose],
      {
        trap: true,
        onBack: () => ui.logsClose.onclick(),
      },
    );
    refreshBrowserPlatformUi(ui);
    performanceUi = browserNicknameUi;
    return browserNicknameUi;
  }

  function setPlatformControlLabel(element, key, { visible = false } = {}) {
    if (!element) return;
    const label = platformText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    if (visible) element.textContent = label;
  }

  function setSidebarActionLabel(element, key) {
    if (!element) return;
    const label = platformText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    const text = element.querySelector?.("span:last-child");
    if (text) text.textContent = label;
  }

  function refreshBrowserPlatformUi(ui) {
    if (!ui) return;
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    ui.host?.setAttribute?.("lang", platformUiLocale);
    if (ui.sidebarTitle) {
      ui.sidebarTitle.textContent = platformText("sidebar.title");
    }
    setPlatformControlLabel(ui.sidebarScrim, "sidebar.continue");
    setSidebarActionLabel(ui.continueButton, "sidebar.continue");
    setSidebarActionLabel(ui.reload, "sidebar.restart");
    setSidebarActionLabel(ui.logs, "sidebar.logs");
    setSidebarActionLabel(ui.enterFullscreen, "sidebar.enter_fullscreen");
    setSidebarActionLabel(ui.exitFullscreen, "sidebar.exit_fullscreen");
    setSidebarActionLabel(ui.info, "sidebar.info");
    setSidebarActionLabel(ui.performanceButton, "sidebar.performance");
    setSidebarActionLabel(ui.exit, "sidebar.exit");
    setPlatformControlLabel(ui.button, "nickname.edit_action", {
      visible: true,
    });
    if (ui.nicknameLabel) {
      ui.nicknameLabel.textContent = platformText("nickname.label");
    }
    if (ui.title && !ui.overlay.hidden) {
      ui.title.textContent = platformText(
        ui.nicknameRequired ? "nickname.set_title" : "nickname.edit_title",
      );
    }
    setPlatformControlLabel(ui.close, "common.cancel", { visible: true });
    setPlatformControlLabel(ui.submit, "common.save", { visible: true });
    if (ui.infoTitle) ui.infoTitle.textContent = platformText("info.title");
    setPlatformControlLabel(ui.infoClose, "common.close", { visible: true });
    if (ui.logsTitle) ui.logsTitle.textContent = platformText("logs.title");
    setPlatformControlLabel(ui.logsClear, "common.clear", { visible: true });
    setPlatformControlLabel(ui.logsClose, "common.close", { visible: true });
    const config = global.__PLAYMESH_BROWSER__ || {};
    if (ui.gameName) {
      ui.gameName.textContent =
        config.gameName || platformText("info.default_game");
    }
    if (ui.sessionInfo) {
      ui.sessionInfo.textContent = bootstrap?.session?.joinCode
        ? platformText("info.join_code", {
            joinCode: bootstrap.session.joinCode,
          })
        : platformText("info.solo_share");
    }
    if (!ui.logsOverlay.hidden) renderBrowserConsoleLogs(ui);
  }

  function validateStorageName(value, field) {
    const max = field === "bucket" ? 64 : 128;
    const pattern = field === "bucket"
      ? /^[A-Za-z0-9][A-Za-z0-9_-]*$/
      : /^[A-Za-z0-9._-]+$/;
    if (typeof value !== "string" || value.length < 1 || value.length > max || !pattern.test(value)) {
      throw new Error(`无效的 ${field}`);
    }
  }
})(window);
