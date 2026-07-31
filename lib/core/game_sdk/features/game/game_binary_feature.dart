part of '../../sdk_feature_registry.dart';

const gameBinarySdkSource = SdkSourceFragment(
  id: 'game.binary',
  target: SdkSourceTarget.game,
  order: 20,
  typeScript: r'''  function binaryModeCode(mode) {
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
        if (!main.session.isAuthority() || mode !== "authority") {
          throw new Error("只有 Authority mode 的 Authority 可以注册 Binary Channel 审核器");
        }
        if (typeof handler !== "function") throw new Error("Binary Channel onForward 需要函数");
        state.forwardHandler = handler;
        return () => {
          if (state.forwardHandler === handler) state.forwardHandler = null;
        };
      },
      async close() {
        if (!main.session.isAuthority()) {
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

''',
);
