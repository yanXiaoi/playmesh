part of '../../sdk_feature_registry.dart';

const gameRpcSdkSource = SdkSourceFragment(
  id: 'game.rpc',
  target: SdkSourceTarget.game,
  order: 47,
  typeScript: r'''  const RPC_DEFAULT_TIMEOUT_MS = 10000;
  const RPC_MIN_TIMEOUT_MS = 100;
  const RPC_MAX_TIMEOUT_MS = 60000;
  const RPC_MAX_PENDING = 64;
  const RPC_MAX_PAYLOAD_BYTES = 4 * 1024 * 1024 - 64 * 1024;
  const RPC_MAX_DEPTH = 64;
  const RPC_MAX_ENTRIES = 100000;
  const RPC_TAG_UNDEFINED = 0;
  const RPC_TAG_NULL = 1;
  const RPC_TAG_FALSE = 2;
  const RPC_TAG_TRUE = 3;
  const RPC_TAG_NUMBER = 4;
  const RPC_TAG_STRING = 5;
  const RPC_TAG_ARRAY = 6;
  const RPC_TAG_OBJECT = 7;
  const RPC_TAG_UINT8_ARRAY = 8;
  const RPC_TAG_ARRAY_BUFFER = 9;
  const RPC_TAG_BLOB = 10;
  const RPC_TAG_FILE = 11;
  const rpcPathPattern = /^\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?$/;
  const rpcErrorCodePattern = /^[a-z][a-z0-9_]{0,63}$/;
  const rpcHandlers = new Map();
  const rpcPending = new Map();

  function rpcError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function validateRpcPath(path) {
    if (
      typeof path !== "string" ||
      path.length > 256 ||
      !rpcPathPattern.test(path)
    ) {
      throw rpcError(
        "rpc_path_invalid",
        "RPC path 必须以 / 开头、长度不超过 256，且每段只允许字母、数字、点、下划线、连字符和波浪号",
      );
    }
    return path;
  }

  function rpcTimeoutFromOptions(options) {
    if (options === undefined) return RPC_DEFAULT_TIMEOUT_MS;
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw rpcError("rpc_options_invalid", "RPC options 必须是对象");
    }
    for (const key of Object.keys(options)) {
      if (key !== "timeoutMs") {
        throw rpcError("rpc_options_invalid", `未知 RPC option: ${key}`);
      }
    }
    const timeoutMs = options.timeoutMs ?? RPC_DEFAULT_TIMEOUT_MS;
    if (
      !Number.isInteger(timeoutMs) ||
      timeoutMs < RPC_MIN_TIMEOUT_MS ||
      timeoutMs > RPC_MAX_TIMEOUT_MS
    ) {
      throw rpcError(
        "rpc_timeout_invalid",
        `RPC timeoutMs 必须是 ${RPC_MIN_TIMEOUT_MS} 至 ${RPC_MAX_TIMEOUT_MS} 的整数`,
      );
    }
    return timeoutMs;
  }

  function rpcUint32(value) {
    const data = new Uint8Array(4);
    new DataView(data.buffer).setUint32(0, value);
    return data;
  }

  function rpcFloat64(value) {
    const data = new Uint8Array(8);
    new DataView(data.buffer).setFloat64(0, value);
    return data;
  }

  async function encodeRpcValue(value) {
    const chunks = [];
    const ancestors = new Set();
    const textEncoder = new TextEncoder();
    let byteLength = 0;
    let entries = 0;

    const append = (chunk) => {
      byteLength += chunk.byteLength;
      if (byteLength > RPC_MAX_PAYLOAD_BYTES) {
        throw rpcError(
          "rpc_payload_too_large",
          `RPC 数据超过 ${RPC_MAX_PAYLOAD_BYTES} 字节限制`,
        );
      }
      chunks.push(chunk);
    };
    const appendTag = (tag) => append(Uint8Array.of(tag));
    const appendBytes = (bytes) => {
      append(rpcUint32(bytes.byteLength));
      append(bytes);
    };
    const appendString = (text) => appendBytes(textEncoder.encode(text));
    const enterContainer = (container, depth) => {
      if (depth > RPC_MAX_DEPTH) {
        throw rpcError("rpc_payload_invalid", `RPC 数据嵌套不能超过 ${RPC_MAX_DEPTH} 层`);
      }
      if (ancestors.has(container)) {
        throw rpcError("rpc_payload_invalid", "RPC 数据不能包含循环引用");
      }
      ancestors.add(container);
    };
    const countEntries = (count) => {
      entries += count;
      if (entries > RPC_MAX_ENTRIES) {
        throw rpcError("rpc_payload_invalid", "RPC 数据成员数量过多");
      }
    };

    const visit = async (current, depth) => {
      if (current === undefined) {
        appendTag(RPC_TAG_UNDEFINED);
        return;
      }
      if (current === null) {
        appendTag(RPC_TAG_NULL);
        return;
      }
      if (current === false || current === true) {
        appendTag(current ? RPC_TAG_TRUE : RPC_TAG_FALSE);
        return;
      }
      if (typeof current === "number") {
        if (!Number.isFinite(current)) {
          throw rpcError("rpc_payload_invalid", "RPC 数字必须是有限值");
        }
        appendTag(RPC_TAG_NUMBER);
        append(rpcFloat64(current));
        return;
      }
      if (typeof current === "string") {
        appendTag(RPC_TAG_STRING);
        appendString(current);
        return;
      }
      if (typeof current !== "object") {
        throw rpcError(
          "rpc_payload_invalid",
          `RPC 不支持传输 ${typeof current}`,
        );
      }
      if (current instanceof Uint8Array) {
        appendTag(RPC_TAG_UINT8_ARRAY);
        appendBytes(new Uint8Array(current));
        return;
      }
      if (current instanceof global.ArrayBuffer) {
        appendTag(RPC_TAG_ARRAY_BUFFER);
        appendBytes(new Uint8Array(current.slice(0)));
        return;
      }
      if (typeof global.File === "function" && current instanceof global.File) {
        appendTag(RPC_TAG_FILE);
        appendString(current.name || "");
        appendString(current.type || "");
        append(rpcFloat64(Number(current.lastModified) || 0));
        appendBytes(new Uint8Array(await current.arrayBuffer()));
        return;
      }
      if (typeof global.Blob === "function" && current instanceof global.Blob) {
        appendTag(RPC_TAG_BLOB);
        appendString(current.type || "");
        appendBytes(new Uint8Array(await current.arrayBuffer()));
        return;
      }
      if (Array.isArray(current)) {
        enterContainer(current, depth);
        countEntries(current.length);
        appendTag(RPC_TAG_ARRAY);
        append(rpcUint32(current.length));
        for (const item of current) await visit(item, depth + 1);
        ancestors.delete(current);
        return;
      }
      const prototype = Object.getPrototypeOf(current);
      if (prototype !== null && prototype?.constructor?.name !== "Object") {
        throw rpcError(
          "rpc_payload_invalid",
          "RPC 对象必须是普通对象；图片或文件请使用 Blob、File、ArrayBuffer 或 Uint8Array",
        );
      }
      const keys = Object.keys(current);
      enterContainer(current, depth);
      countEntries(keys.length);
      appendTag(RPC_TAG_OBJECT);
      append(rpcUint32(keys.length));
      for (const key of keys) {
        appendString(key);
        await visit(current[key], depth + 1);
      }
      ancestors.delete(current);
    };

    await visit(value, 0);
    const output = new Uint8Array(byteLength);
    let offset = 0;
    for (const chunk of chunks) {
      output.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return output;
  }

  function decodeRpcValue(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const textDecoder = new TextDecoder();
    let offset = 0;
    let entries = 0;

    const requireBytes = (count) => {
      if (count < 0 || offset + count > bytes.byteLength) {
        throw rpcError("rpc_payload_invalid", "RPC 二进制数据不完整");
      }
    };
    const readUint32 = () => {
      requireBytes(4);
      const value = view.getUint32(offset);
      offset += 4;
      return value;
    };
    const readFloat64 = () => {
      requireBytes(8);
      const value = view.getFloat64(offset);
      offset += 8;
      return value;
    };
    const readBytes = () => {
      const length = readUint32();
      requireBytes(length);
      const value = bytes.slice(offset, offset + length);
      offset += length;
      return value;
    };
    const readString = () => textDecoder.decode(readBytes());
    const countEntries = (count) => {
      entries += count;
      if (entries > RPC_MAX_ENTRIES) {
        throw rpcError("rpc_payload_invalid", "RPC 数据成员数量过多");
      }
    };
    const read = (depth) => {
      if (depth > RPC_MAX_DEPTH) {
        throw rpcError("rpc_payload_invalid", `RPC 数据嵌套不能超过 ${RPC_MAX_DEPTH} 层`);
      }
      requireBytes(1);
      const tag = bytes[offset++];
      switch (tag) {
      case RPC_TAG_UNDEFINED:
        return undefined;
      case RPC_TAG_NULL:
        return null;
      case RPC_TAG_FALSE:
        return false;
      case RPC_TAG_TRUE:
        return true;
      case RPC_TAG_NUMBER: {
        const value = readFloat64();
        if (!Number.isFinite(value)) {
          throw rpcError("rpc_payload_invalid", "RPC 数字必须是有限值");
        }
        return value;
      }
      case RPC_TAG_STRING:
        return readString();
      case RPC_TAG_ARRAY: {
        const length = readUint32();
        countEntries(length);
        const value = new Array(length);
        for (let index = 0; index < length; index += 1) {
          value[index] = read(depth + 1);
        }
        return value;
      }
      case RPC_TAG_OBJECT: {
        const length = readUint32();
        countEntries(length);
        const value = {};
        for (let index = 0; index < length; index += 1) {
          const key = readString();
          Object.defineProperty(value, key, {
            value: read(depth + 1),
            enumerable: true,
            configurable: true,
            writable: true,
          });
        }
        return value;
      }
      case RPC_TAG_UINT8_ARRAY:
        return readBytes();
      case RPC_TAG_ARRAY_BUFFER: {
        const value = readBytes();
        return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength);
      }
      case RPC_TAG_BLOB: {
        const type = readString();
        const value = readBytes();
        if (typeof global.Blob !== "function") return value;
        return new global.Blob([value], { type });
      }
      case RPC_TAG_FILE: {
        const name = readString();
        const type = readString();
        const lastModified = readFloat64();
        const value = readBytes();
        if (typeof global.File === "function") {
          return new global.File([value], name, { type, lastModified });
        }
        if (typeof global.Blob === "function") {
          const blob = new global.Blob([value], { type });
          Object.defineProperties(blob, {
            name: { value: name, enumerable: true },
            lastModified: { value: lastModified, enumerable: true },
          });
          return blob;
        }
        return value;
      }
      default:
        throw rpcError("rpc_payload_invalid", `未知 RPC 二进制类型: ${tag}`);
      }
    };

    const value = read(0);
    if (offset !== bytes.byteLength) {
      throw rpcError("rpc_payload_invalid", "RPC 二进制数据包含多余内容");
    }
    return value;
  }

  function encodeRpcRequestFrame(requestId, timeoutMs, path, payload) {
    const encodedPath = new TextEncoder().encode(path);
    if (!encodedPath.length || encodedPath.length > 0xffff) {
      throw rpcError("rpc_path_invalid", "RPC path 编码长度无效");
    }
    const data = new Uint8Array(12 + encodedPath.length + payload.length);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_RPC_REQUEST;
    view.setUint32(2, requestId);
    view.setUint32(6, timeoutMs);
    view.setUint16(10, encodedPath.length);
    data.set(encodedPath, 12);
    data.set(payload, 12 + encodedPath.length);
    return data;
  }

  function encodeRpcResponseFrame(rpcId, value, error) {
    if (!(rpcId instanceof Uint8Array) || rpcId.length !== 8) {
      throw rpcError("rpc_response_invalid", "RPC ID 无效");
    }
    if (!error) {
      const data = new Uint8Array(11 + value.length);
      data[0] = BINARY_PROTOCOL_VERSION;
      data[1] = BINARY_OP_RPC_RESPONSE;
      data.set(rpcId, 2);
      data[10] = BINARY_STATUS_OK;
      data.set(value, 11);
      return data;
    }
    const code = typeof error.code === "string" && rpcErrorCodePattern.test(error.code)
      ? error.code
      : "rpc_handler_failed";
    const message = String(error.message || error || "Authority RPC 处理失败").slice(0, 512);
    const encodedCode = new TextEncoder().encode(code);
    const encodedMessage = new TextEncoder().encode(message);
    const data = new Uint8Array(13 + encodedCode.length + encodedMessage.length);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_RPC_RESPONSE;
    data.set(rpcId, 2);
    data[10] = BINARY_STATUS_ERROR;
    view.setUint16(11, encodedCode.length);
    data.set(encodedCode, 13);
    data.set(encodedMessage, 13 + encodedCode.length);
    return data;
  }

  function rpcRequestIdFromBytes(bytes) {
    let value = "";
    for (const byte of bytes) value += byte.toString(16).padStart(2, "0");
    return `rpc-${value}`;
  }

  function settleRpcRequest(requestId, error, value) {
    const pendingRequest = rpcPending.get(requestId);
    if (!pendingRequest) return false;
    rpcPending.delete(requestId);
    global.clearTimeout(pendingRequest.timer);
    if (error) pendingRequest.reject(error);
    else pendingRequest.resolve(value);
    return true;
  }

  function rejectAllRpcRequests(reason, code = "rpc_transport_closed") {
    const message = reason?.message || String(reason || "Authority RPC 传输已关闭");
    for (const requestId of [...rpcPending.keys()]) {
      settleRpcRequest(requestId, rpcError(code, message));
    }
  }

  async function requestRpc(path, data = null, options) {
    const normalizedPath = validateRpcPath(path);
    const timeoutMs = rpcTimeoutFromOptions(options);
    await main.ready;
    if (!main.session.getCurrent()) {
      throw rpcError("rpc_session_required", "RPC 只能在多人会话中调用");
    }
    if (rpcPending.size >= RPC_MAX_PENDING) {
      throw rpcError("rpc_pending_limit", "当前页面等待中的 RPC 请求过多");
    }
    const payload = await encodeRpcValue(data);
    await ensureBinarySocket();
    const requestId = nextBinaryRequestId();
    const frame = encodeRpcRequestFrame(
      requestId,
      timeoutMs,
      normalizedPath,
      payload,
    );
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        settleRpcRequest(
          requestId,
          rpcError("rpc_timeout", `Authority RPC 请求超时: ${normalizedPath}`),
        );
      }, timeoutMs);
      rpcPending.set(requestId, { resolve, reject, timer, path: normalizedPath });
      queueBinaryFrame(frame, { requestId });
    });
  }

  function registerRpcRequestHandler(path, handler) {
    if (!main.session.isAuthority()) {
      throw rpcError(
        "not_authority",
        "只有 Authority Client 可以调用 playmesh.main.rpc.onRequest()",
      );
    }
    const normalizedPath = validateRpcPath(path);
    if (typeof handler !== "function") {
      throw rpcError("rpc_handler_invalid", "RPC handler 必须是函数");
    }
    if (rpcHandlers.has(normalizedPath)) {
      throw rpcError(
        "rpc_path_registered",
        `Authority RPC path 已注册: ${normalizedPath}`,
      );
    }
    const registration = { handler };
    rpcHandlers.set(normalizedPath, registration);
    void ensureBinarySocket().catch((error) => {
      global.console?.warn?.("Authority RPC 二进制连接暂不可用", {
        path: normalizedPath,
        error: error?.message || String(error),
      });
    });
    return function unregister() {
      if (rpcHandlers.get(normalizedPath) === registration) {
        rpcHandlers.delete(normalizedPath);
      }
    };
  }

  async function receiveRpcIncoming(data) {
    if (data.length < 17) {
      closeBinaryTransport("Authority RPC 请求帧格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const rpcId = data.slice(2, 10);
    const senderLength = view.getUint16(10);
    const pathLength = view.getUint16(12);
    if (!senderLength || !pathLength || data.length < 14 + senderLength + pathLength + 1) {
      closeBinaryTransport("Authority RPC 请求上下文无效");
      return;
    }
    let offset = 14;
    const senderPlayerId = new TextDecoder().decode(
      data.subarray(offset, offset + senderLength),
    );
    offset += senderLength;
    const path = new TextDecoder().decode(data.subarray(offset, offset + pathLength));
    offset += pathLength;
    let normalizedPath;
    try {
      normalizedPath = validateRpcPath(path);
    } catch (error) {
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, null, error));
      return;
    }
    const registration = rpcHandlers.get(normalizedPath);
    if (!registration) {
      queueBinaryFrame(encodeRpcResponseFrame(
        rpcId,
        null,
        rpcError("rpc_path_not_found", `Authority 未监听 RPC path: ${normalizedPath}`),
      ));
      return;
    }
    let payload;
    try {
      payload = decodeRpcValue(data.subarray(offset));
    } catch (error) {
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, null, error));
      return;
    }
    const session = main.session.getCurrent();
    const context = {
      requestId: rpcRequestIdFromBytes(rpcId),
      path: normalizedPath,
      senderPlayerId,
      session,
      members: Array.isArray(session?.players) ? session.players : [],
    };
    try {
      const result = await registration.handler(payload, context);
      const encoded = await encodeRpcValue(result);
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, encoded, null));
    } catch (error) {
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, null, error));
    }
  }

  function receiveRpcResult(data) {
    if (data.length < 7) {
      closeBinaryTransport("Authority RPC 响应帧格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const requestId = view.getUint32(2);
    if (!rpcPending.has(requestId)) return;
    if (data[6] === BINARY_STATUS_OK) {
      try {
        settleRpcRequest(requestId, null, decodeRpcValue(data.subarray(7)));
      } catch (error) {
        settleRpcRequest(requestId, error);
      }
      return;
    }
    if (data[6] !== BINARY_STATUS_ERROR || data.length < 9) {
      settleRpcRequest(
        requestId,
        rpcError("rpc_response_invalid", "Authority RPC 响应格式无效"),
      );
      return;
    }
    const codeLength = view.getUint16(7);
    if (!codeLength || data.length < 9 + codeLength) {
      settleRpcRequest(
        requestId,
        rpcError("rpc_response_invalid", "Authority RPC 错误响应格式无效"),
      );
      return;
    }
    const code = new TextDecoder().decode(data.subarray(9, 9 + codeLength));
    const message = new TextDecoder().decode(data.subarray(9 + codeLength));
    settleRpcRequest(
      requestId,
      rpcError(
        rpcErrorCodePattern.test(code) ? code : "rpc_failed",
        message || "Authority RPC 请求被拒绝",
      ),
    );
  }

''',
);
