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
  const RPC_STREAM_DEFAULT_TIMEOUT_MS = 300000;
  const RPC_STREAM_MIN_TIMEOUT_MS = 1000;
  const RPC_STREAM_MAX_TIMEOUT_MS = 1800000;
  const RPC_STREAM_MAX_PENDING = 4;
  const RPC_STREAM_MAX_BYTES = 512 * 1024 * 1024;
  const RPC_STREAM_CHUNK_BYTES = 64 * 1024;
  const RPC_STREAM_CHUNK_TRANSPORT = "chunked-v1";
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
  const rpcStreamHandlers = new Map();
  const rpcStreamPending = new Set();
  const rpcStreamReceivers = new Set();

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

  function validateRpcStreamOptions(options, allowedKeys, defaults) {
    if (options === undefined) return { ...defaults };
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw rpcError("rpc_options_invalid", "RPC 流 options 必须是对象");
    }
    for (const key of Object.keys(options)) {
      if (!allowedKeys.includes(key)) {
        throw rpcError("rpc_options_invalid", `未知 RPC 流 option: ${key}`);
      }
    }
    return { ...defaults, ...options };
  }

  function normalizeRpcStreamProgressHandler(callback) {
    if (callback !== undefined && typeof callback !== "function") {
      throw rpcError("rpc_progress_invalid", "RPC 流 onProgress 必须是函数");
    }
    return callback ?? null;
  }

  function reportRpcStreamProgress(callback, transferredBytes, totalBytes) {
    if (!callback) return;
    try {
      const result = callback(transferredBytes, totalBytes);
      if (result && typeof result.then === "function") {
        void result.catch((error) => {
          global.console?.warn?.("RPC 流进度回调执行失败", error);
        });
      }
    } catch (error) {
      global.console?.warn?.("RPC 流进度回调执行失败", error);
    }
  }

  function createRpcStreamChunkReader(stream) {
    let offset = 0;
    let transferredBytes = 0;
    let sourceReader = null;
    let sourceChunk = null;
    let sourceChunkOffset = 0;
    let released = false;
    if (stream.streaming) sourceReader = stream.body.getReader();
    reportRpcStreamProgress(stream.onProgress, 0, stream.size);

    const release = () => {
      if (released || !sourceReader) return;
      released = true;
      try {
        sourceReader.releaseLock();
      } catch (_) {
        // 流结束或取消时可能已自动释放。
      }
    };

    const report = (bytes) => {
      transferredBytes += bytes;
      if (transferredBytes > RPC_STREAM_MAX_BYTES) {
        throw rpcError("rpc_stream_too_large", "RPC 流不能超过 512 MiB");
      }
      reportRpcStreamProgress(
        stream.onProgress,
        transferredBytes,
        stream.size,
      );
    };

    return {
      async read() {
        if (stream.streaming) {
          while (!sourceChunk || sourceChunkOffset >= sourceChunk.byteLength) {
            const chunk = await sourceReader.read();
            if (chunk.done) {
              release();
              return null;
            }
            if (!(chunk.value instanceof Uint8Array)) {
              throw rpcError(
                "rpc_stream_chunk_invalid",
                "RPC ReadableStream 的每个 chunk 必须是 Uint8Array",
              );
            }
            if (chunk.value.byteLength === 0) continue;
            sourceChunk = chunk.value;
            sourceChunkOffset = 0;
          }
          const end = Math.min(
            sourceChunk.byteLength,
            sourceChunkOffset + RPC_STREAM_CHUNK_BYTES,
          );
          const value = sourceChunk.subarray(sourceChunkOffset, end);
          sourceChunkOffset = end;
          report(value.byteLength);
          return value;
        }

        if (
          typeof global.Blob === "function" &&
          stream.body instanceof global.Blob
        ) {
          if (offset >= stream.body.size) return null;
          const end = Math.min(stream.body.size, offset + RPC_STREAM_CHUNK_BYTES);
          const value = new Uint8Array(
            await stream.body.slice(offset, end).arrayBuffer(),
          );
          offset = end;
          report(value.byteLength);
          return value;
        }

        const bytes = stream.body instanceof Uint8Array
          ? stream.body
          : new Uint8Array(stream.body);
        if (offset >= bytes.byteLength) return null;
        const end = Math.min(bytes.byteLength, offset + RPC_STREAM_CHUNK_BYTES);
        const value = bytes.subarray(offset, end);
        offset = end;
        report(value.byteLength);
        return value;
      },
      async cancel(reason) {
        if (!sourceReader || released) return;
        try {
          await sourceReader.cancel(reason);
        } finally {
          release();
        }
      },
    };
  }

  async function chunkedStreamResponseError(response, fallbackMessage) {
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      // 非 JSON 错误继续使用稳定 fallback。
    }
    const details = payload?.error;
    return rpcError(
      typeof details?.code === "string" ? details.code : "stream_upload_failed",
      typeof details?.message === "string"
        ? details.message
        : typeof details === "string"
          ? details
          : fallbackMessage,
    );
  }

  async function uploadRpcStreamChunks({
    endpoint,
    stream,
    headers,
    signal,
    expectedPathPrefix,
    errorMessage,
  }) {
    const resolvedEndpoint = new URL(endpoint, global.location?.href);
    const openEndpoint = new URL(resolvedEndpoint);
    openEndpoint.searchParams.set("transport", RPC_STREAM_CHUNK_TRANSPORT);
    const openResponse = await global.fetch(openEndpoint, {
      method: "POST",
      headers,
      signal,
    });
    if (!openResponse.ok) {
      throw await chunkedStreamResponseError(openResponse, errorMessage);
    }
    let opened = null;
    try {
      opened = await openResponse.json();
    } catch (_) {
      // 统一按私有协议损坏处理。
    }
    if (
      typeof opened?.uploadPath !== "string" ||
      opened.chunkBytes !== RPC_STREAM_CHUNK_BYTES
    ) {
      throw rpcError("stream_transport_invalid", "流式上传初始化响应无效");
    }
    const uploadEndpoint = new URL(opened.uploadPath, resolvedEndpoint);
    if (
      uploadEndpoint.origin !== resolvedEndpoint.origin ||
      !uploadEndpoint.pathname.startsWith(expectedPathPrefix)
    ) {
      throw rpcError("stream_transport_invalid", "流式上传地址无效");
    }

    const reader = createRpcStreamChunkReader(stream);
    let sequence = 0;
    let completed = false;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk === null) break;
        const chunkEndpoint = new URL(uploadEndpoint);
        chunkEndpoint.searchParams.set("sequence", String(sequence));
        const response = await global.fetch(chunkEndpoint, {
          method: "POST",
          headers: { ...headers, "Content-Type": "application/octet-stream" },
          body: chunk,
          signal,
        });
        if (!response.ok) {
          const error = await chunkedStreamResponseError(response, errorMessage);
          if (error.code === "rpc_stream_finished") {
            await reader.cancel(error);
            break;
          }
          throw error;
        }
        sequence++;
      }
      const response = await global.fetch(uploadEndpoint, {
        method: "PATCH",
        headers,
        signal,
      });
      completed = true;
      return response;
    } finally {
      if (!completed) {
        await reader.cancel(rpcError("stream_upload_cancelled", "流式上传已取消"));
        try {
          await global.fetch(uploadEndpoint, { method: "DELETE", headers });
        } catch (_) {
          // 取消是 best-effort；保留最初的传输错误。
        }
      }
    }
  }

  function trackRpcStreamProgress(source, totalBytes, callback) {
    if (!callback) return source;
    const reader = source.getReader();
    let transferredBytes = 0;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      try {
        reader.releaseLock();
      } catch (_) {
        // 流结束或取消时可能已自动释放。
      }
    };
    reportRpcStreamProgress(callback, 0, totalBytes);
    return new global.ReadableStream({
      async pull(controller) {
        try {
          const chunk = await reader.read();
          if (chunk.done) {
            release();
            controller.close();
            return;
          }
          if (!(chunk.value instanceof Uint8Array)) {
            throw rpcError(
              "rpc_stream_chunk_invalid",
              "RPC ReadableStream 的每个 chunk 必须是 Uint8Array",
            );
          }
          transferredBytes += chunk.value.byteLength;
          if (transferredBytes > RPC_STREAM_MAX_BYTES) {
            throw rpcError("rpc_stream_too_large", "RPC 流不能超过 512 MiB");
          }
          controller.enqueue(chunk.value);
          reportRpcStreamProgress(callback, transferredBytes, totalBytes);
        } catch (error) {
          try {
            await reader.cancel(error);
          } catch (_) {
            // 保留最初的读取错误。
          }
          release();
          controller.error(error);
        }
      },
      async cancel(reason) {
        try {
          await reader.cancel(reason);
        } finally {
          release();
        }
      },
    });
  }

  function normalizeRpcStreamMetadata(name, type) {
    const normalizedName = name ?? "stream.bin";
    const normalizedType = type || "application/octet-stream";
    const encoder = new TextEncoder();
    if (
      typeof normalizedName !== "string" ||
      !normalizedName.length ||
      encoder.encode(normalizedName).length > 255 ||
      /[\u0000\r\n]/.test(normalizedName)
    ) {
      throw rpcError(
        "rpc_stream_name_invalid",
        "RPC 流名称必须是 1～255 UTF-8 字节且不能包含控制换行",
      );
    }
    if (
      typeof normalizedType !== "string" ||
      !normalizedType.length ||
      encoder.encode(normalizedType).length > 255 ||
      /[\u0000\r\n]/.test(normalizedType)
    ) {
      throw rpcError("rpc_stream_type_invalid", "RPC 流媒体类型无效");
    }
    return { name: normalizedName, type: normalizedType };
  }

  function describeRpcStreamSource(source, metadata = {}) {
    let body = source;
    let size = null;
    let sourceName = null;
    let sourceType = null;
    let streaming = false;
    if (typeof global.File === "function" && source instanceof global.File) {
      size = source.size;
      sourceName = source.name;
      sourceType = source.type;
    } else if (typeof global.Blob === "function" && source instanceof global.Blob) {
      size = source.size;
      sourceType = source.type;
    } else if (source instanceof global.ArrayBuffer) {
      size = source.byteLength;
    } else if (source instanceof Uint8Array) {
      size = source.byteLength;
    } else if (
      typeof global.ReadableStream === "function" &&
      source instanceof global.ReadableStream
    ) {
      streaming = true;
    } else {
      throw rpcError(
        "rpc_stream_source_invalid",
        "RPC 流 source 必须是 File、Blob、ArrayBuffer、Uint8Array 或 ReadableStream<Uint8Array>",
      );
    }
    if (size !== null && size > RPC_STREAM_MAX_BYTES) {
      throw rpcError("rpc_stream_too_large", "RPC 流不能超过 512 MiB");
    }
    const normalized = normalizeRpcStreamMetadata(
      metadata.name ?? sourceName,
      metadata.type ?? sourceType,
    );
    return { body, size, streaming, ...normalized };
  }

  function normalizeRpcStreamSource(source, options) {
    const normalized = validateRpcStreamOptions(
      options,
      ["timeoutMs", "name", "type", "onProgress"],
      { timeoutMs: RPC_STREAM_DEFAULT_TIMEOUT_MS },
    );
    if (
      !Number.isInteger(normalized.timeoutMs) ||
      normalized.timeoutMs < RPC_STREAM_MIN_TIMEOUT_MS ||
      normalized.timeoutMs > RPC_STREAM_MAX_TIMEOUT_MS
    ) {
      throw rpcError(
        "rpc_timeout_invalid",
        `RPC 流 timeoutMs 必须是 ${RPC_STREAM_MIN_TIMEOUT_MS} 至 ${RPC_STREAM_MAX_TIMEOUT_MS} 的整数`,
      );
    }
    const stream = {
      ...describeRpcStreamSource(source, normalized),
      timeoutMs: normalized.timeoutMs,
      onProgress: normalizeRpcStreamProgressHandler(normalized.onProgress),
    };
    return stream;
  }

  function normalizeStorageUploadSource(source, options) {
    const fileSource = typeof global.File === "function" && source instanceof global.File;
    const normalized = validateRpcStreamOptions(options, ["name", "type"], {});
    if (!fileSource && normalized.name === undefined) {
      throw rpcError(
        "storage_upload_name_required",
        "非 File 字节源必须通过 options.name 提供上传文件名",
      );
    }
    return describeRpcStreamSource(source, normalized);
  }

  function getRpcStreamTransport() {
    const session = main.session.getCurrent();
    if (!session?.id || !binaryTransportConfig?.url) {
      throw rpcError("rpc_session_required", "RPC 流只能在多人会话中调用");
    }
    let binaryUrl;
    try {
      binaryUrl = new URL(binaryTransportConfig.url, global.location?.href);
    } catch (_) {
      throw rpcError("rpc_stream_transport_invalid", "RPC 流传输地址无效");
    }
    const token = binaryUrl.searchParams.get("token");
    if (!token) {
      throw rpcError("rpc_stream_transport_invalid", "RPC 流传输缺少会话凭据");
    }
    binaryUrl.protocol = binaryUrl.protocol === "wss:" ? "https:" : "http:";
    binaryUrl.pathname = "/";
    binaryUrl.search = "";
    binaryUrl.hash = "";
    return { baseUrl: binaryUrl, token, session };
  }

  async function rpcStreamResponseError(response) {
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      // 非 JSON 网关错误使用稳定兜底 code。
    }
    const code = payload?.error?.code;
    const message = payload?.error?.message;
    return rpcError(
      typeof code === "string" && rpcErrorCodePattern.test(code)
        ? code
        : "rpc_stream_failed",
      typeof message === "string" && message
        ? message
        : `Authority RPC 流请求失败（HTTP ${response.status}）`,
    );
  }

  function rejectAllRpcStreamRequests(reason, code = "rpc_transport_closed") {
    const error = rpcError(code, reason?.message || String(reason || "RPC 流传输已关闭"));
    for (const pendingRequest of [...rpcStreamPending]) {
      pendingRequest.error = error;
      pendingRequest.controller.abort();
    }
    for (const controller of [...rpcStreamReceivers]) controller.abort();
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

  async function requestRpcStream(path, source, options) {
    const normalizedPath = validateRpcPath(path);
    const stream = normalizeRpcStreamSource(source, options);
    await main.ready;
    if (!main.session.getCurrent()) {
      throw rpcError("rpc_session_required", "RPC 流只能在多人会话中调用");
    }
    if (rpcStreamPending.size >= RPC_STREAM_MAX_PENDING) {
      throw rpcError("rpc_pending_limit", "当前页面等待中的 RPC 流请求过多");
    }
    await ensureBinarySocket();
    const transport = getRpcStreamTransport();
    const endpoint = new URL(
      `v1/sessions/${encodeURIComponent(transport.session.id)}/rpc-stream`,
      transport.baseUrl,
    );
    endpoint.searchParams.set("path", normalizedPath);
    endpoint.searchParams.set("timeoutMs", String(stream.timeoutMs));
    endpoint.searchParams.set("name", stream.name);
    if (stream.size !== null) endpoint.searchParams.set("size", String(stream.size));
    const controller = new AbortController();
    const pendingRequest = { controller, error: null };
    rpcStreamPending.add(pendingRequest);
    const timer = global.setTimeout(() => {
      pendingRequest.error = rpcError(
        "rpc_timeout",
        `Authority RPC 流请求超时: ${normalizedPath}`,
      );
      controller.abort();
    }, stream.timeoutMs);
    try {
      const headers = {
        "Authorization": `Bearer ${transport.token}`,
        "Content-Type": stream.type,
      };
      const response = stream.streaming || stream.onProgress
        ? await uploadRpcStreamChunks({
            endpoint,
            stream,
            headers,
            signal: controller.signal,
            expectedPathPrefix:
              `/v1/sessions/${encodeURIComponent(transport.session.id)}/rpc-stream-uploads/`,
            errorMessage: "Authority RPC 流上传失败",
          })
        : await global.fetch(endpoint, {
            method: "POST",
            headers,
            body: stream.body,
            signal: controller.signal,
          });
      if (!response.ok) throw await rpcStreamResponseError(response);
      const encoded = new Uint8Array(await response.arrayBuffer());
      if (encoded.length > RPC_MAX_PAYLOAD_BYTES) {
        throw rpcError("rpc_payload_too_large", "Authority RPC 流响应超过 4 MiB 通道上限");
      }
      return decodeRpcValue(encoded);
    } catch (error) {
      if (pendingRequest.error) throw pendingRequest.error;
      if (error?.name === "AbortError") {
        throw rpcError("rpc_stream_cancelled", "Authority RPC 流请求已取消");
      }
      throw error;
    } finally {
      global.clearTimeout(timer);
      rpcStreamPending.delete(pendingRequest);
    }
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

  function registerRpcStreamRequestHandler(path, handler, options) {
    if (!main.session.isAuthority()) {
      throw rpcError(
        "not_authority",
        "只有 Authority Client 可以调用 playmesh.main.rpc.onStreamRequest()",
      );
    }
    const normalizedPath = validateRpcPath(path);
    if (typeof handler !== "function") {
      throw rpcError("rpc_handler_invalid", "RPC 流 handler 必须是函数");
    }
    const normalizedOptions = validateRpcStreamOptions(
      options,
      ["onProgress"],
      {},
    );
    const onProgress = normalizeRpcStreamProgressHandler(
      normalizedOptions.onProgress,
    );
    if (rpcStreamHandlers.has(normalizedPath)) {
      throw rpcError(
        "rpc_path_registered",
        `Authority RPC 流 path 已注册: ${normalizedPath}`,
      );
    }
    const registration = { handler, onProgress };
    rpcStreamHandlers.set(normalizedPath, registration);
    void ensureBinarySocket().catch((error) => {
      global.console?.warn?.("Authority RPC 流二进制控制连接暂不可用", {
        path: normalizedPath,
        error: error?.message || String(error),
      });
    });
    return function unregister() {
      if (rpcStreamHandlers.get(normalizedPath) === registration) {
        rpcStreamHandlers.delete(normalizedPath);
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

  async function receiveRpcStreamIncoming(data) {
    if (data.length < 28) {
      closeBinaryTransport("Authority RPC 流请求帧格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const rpcId = data.slice(2, 10);
    const lengths = [
      view.getUint16(10),
      view.getUint16(12),
      view.getUint16(14),
      view.getUint16(16),
      view.getUint16(18),
    ];
    let offset = 28;
    const values = [];
    for (const length of lengths) {
      if (!length || data.length < offset + length) {
        closeBinaryTransport("Authority RPC 流请求上下文无效");
        return;
      }
      values.push(new TextDecoder().decode(data.subarray(offset, offset + length)));
      offset += length;
    }
    if (offset !== data.length) {
      closeBinaryTransport("Authority RPC 流请求帧包含多余数据");
      return;
    }
    const [senderPlayerId, path, consumePath, name, type] = values;
    let normalizedPath;
    try {
      normalizedPath = validateRpcPath(path);
      normalizeRpcStreamMetadata(name, type);
    } catch (error) {
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, null, error));
      return;
    }
    const registration = rpcStreamHandlers.get(normalizedPath);
    if (!registration) {
      queueBinaryFrame(encodeRpcResponseFrame(
        rpcId,
        null,
        rpcError("rpc_path_not_found", `Authority 未监听 RPC 流 path: ${normalizedPath}`),
      ));
      return;
    }
    const highLength = view.getUint32(20);
    const lowLength = view.getUint32(24);
    const size = highLength === 0xffffffff && lowLength === 0xffffffff
      ? null
      : highLength * 0x100000000 + lowLength;
    const session = main.session.getCurrent();
    const context = {
      requestId: rpcRequestIdFromBytes(rpcId),
      path: normalizedPath,
      senderPlayerId,
      session,
      members: Array.isArray(session?.players) ? session.players : [],
      name,
      type,
      size,
    };
    const controller = new AbortController();
    rpcStreamReceivers.add(controller);
    let body = null;
    try {
      const transport = getRpcStreamTransport();
      const expectedPrefix =
        `/v1/sessions/${encodeURIComponent(transport.session.id)}/rpc-streams/`;
      if (!consumePath.startsWith(expectedPrefix) || consumePath.length <= expectedPrefix.length) {
        throw rpcError("rpc_stream_transport_invalid", "Authority RPC 流读取地址无效");
      }
      const endpoint = new URL(consumePath, transport.baseUrl);
      if (endpoint.origin !== transport.baseUrl.origin) {
        throw rpcError("rpc_stream_transport_invalid", "Authority RPC 流读取来源无效");
      }
      const response = await global.fetch(endpoint, {
        method: "GET",
        headers: { "Authorization": `Bearer ${transport.token}` },
        signal: controller.signal,
      });
      if (!response.ok) throw await rpcStreamResponseError(response);
      body = response.body;
      if (!body) {
        throw rpcError("rpc_stream_unsupported", "当前浏览器不支持 ReadableStream 响应体");
      }
      body = trackRpcStreamProgress(body, size, registration.onProgress);
      const result = await registration.handler(body, context);
      const encoded = await encodeRpcValue(result);
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, encoded, null));
    } catch (error) {
      queueBinaryFrame(encodeRpcResponseFrame(rpcId, null, error));
    } finally {
      rpcStreamReceivers.delete(controller);
      if (body && !body.locked) {
        try {
          await body.cancel();
        } catch (_) {
          // 已关闭的响应流无需再次处理。
        }
      }
      controller.abort();
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
