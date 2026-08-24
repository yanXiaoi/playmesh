// @ts-ignore
(function (global) {
  "use strict";

  const PLAYMESH_APP_SDK_VERSION = "3.3.0";
  const PLAYMESH_APP_INTERNAL_KEY =
    Symbol.for("playmesh.app.internal.v1");

  let sequence = 0;
  let bootstrap = null;
  let appReadyCompleted = false;
  let appRuntimeLocale = null;
  let appPlatformUiConfiguration = null;
  const pending = new Map();
  const inputListeners = new Set();
  const capabilityInstances = new Map();

  function normalizeAppRuntimeLocale(value) {
    if (typeof value !== "string") return null;
    const normalized = value.trim();
    return /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(normalized)
      ? normalized
      : null;
  }

  function browserAppRuntimeLocale() {
    try {
      const candidates = [
        ...(Array.isArray(global.navigator?.languages)
          ? global.navigator.languages
          : []),
        global.navigator?.language,
      ];
      for (const candidate of candidates) {
        const locale = normalizeAppRuntimeLocale(candidate);
        if (locale) return locale;
      }
    } catch (_) {
      // 受限浏览器上下文可能禁止访问 navigator。
    }
    return "zh";
  }

  function updateAppRuntimeLocale(configuration) {
    appRuntimeLocale = bootstrap?.available === true
      ? normalizeAppRuntimeLocale(configuration?.locale) ||
        browserAppRuntimeLocale()
      : browserAppRuntimeLocale();
  }

  function nativeSender() {
    if (global.PlaymeshAppBridge?.postMessage) {
      return (message) => global.PlaymeshAppBridge.postMessage(message);
    }
    if (global.chrome?.webview) {
      return (message) => global.chrome.webview.postMessage(message);
    }
    return null;
  }

  function request(command, payload = {}) {
    const send = nativeSender();
    if (!send) return Promise.reject(new Error("当前页面不在 Playmesh App WebView 中"));
    const requestId = `app-sdk-${Date.now()}-${++sequence}`;
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`Playmesh App Bridge 请求超时: ${command}`));
      }, 30000);
      pending.set(requestId, { resolve, reject, timer });
      try {
        send(JSON.stringify({
          command,
          requestId,
          sdkVersion: PLAYMESH_APP_SDK_VERSION,
          payload,
        }));
      } catch (error) {
        global.clearTimeout(timer);
        pending.delete(requestId);
        reject(error);
      }
    });
  }

  function clone(value) {
    return value == null ? value : JSON.parse(JSON.stringify(value));
  }

  function receive(rawMessage) {
    const message = typeof rawMessage === "string" ? JSON.parse(rawMessage) : rawMessage;
    if (!message || typeof message !== "object") return;
    if (message.type === "app.device.input") {
      for (const listener of [...inputListeners]) listener(clone(message.input));
      return;
    }
    if (message.type === "app.capability.event") {
      const state = capabilityInstances.get(message.instanceId);
      const listeners = state?.listeners.get(message.event);
      if (listeners) {
        for (const listener of [...listeners]) listener(clone(message.data));
      }
      return;
    }
    if (message.type === "app.capability.error") {
      const state = capabilityInstances.get(message.instanceId);
      if (state?.errorListeners.size) {
        const error = new Error(message.error || "能力插件运行失败");
        if (typeof message.code === "string") error.code = message.code;
        for (const listener of [...state.errorListeners]) listener(error);
      } else {
        console.error(`Playmesh 能力实例 ${message.instanceId} 运行失败`, message.error);
      }
      return;
    }
    if (message.type !== "app.command.result" && message.type !== "app.command.error") return;
    const operation = pending.get(message.requestId);
    if (!operation) return;
    pending.delete(message.requestId);
    global.clearTimeout(operation.timer);
    if (message.type === "app.command.error") {
      const error = new Error(message.error || "Playmesh App Bridge 调用失败");
      if (typeof message.code === "string") error.code = message.code;
      operation.reject(error);
    } else {
      operation.resolve(clone(message.result));
    }
  }

  async function createCapability(code, options = {}) {
    if (typeof code !== "string" || !code) throw new TypeError("能力 code 必须是非空字符串");
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("能力 options 必须是对象");
    }
    if (!bootstrap) throw new Error("请先等待 playmesh.app.ready");
    if (!bootstrap.device?.declaredCapabilities?.includes(code)) {
      throw new Error(`当前游戏未在 capabilities.json 声明 ${code}`);
    }
    if (!bootstrap.device?.capabilities?.includes(code)) {
      throw new Error(`当前设备不支持能力 ${code}`);
    }
    const created = await request("app.capability.create", { code, options });
    const state = {
      id: created.instanceId,
      code,
      apiVersion: created.apiVersion,
      active: true,
      listeners: new Map(),
      errorListeners: new Set(),
    };
    capabilityInstances.set(state.id, state);
    return Object.freeze({
      id: state.id,
      code: state.code,
      apiVersion: state.apiVersion,
      invoke(method, argumentsValue = {}) {
        if (!state.active) return Promise.reject(new Error("能力实例已释放"));
        if (typeof method !== "string" || !method) {
          return Promise.reject(new TypeError("能力方法必须是非空字符串"));
        }
        if (!argumentsValue || typeof argumentsValue !== "object" || Array.isArray(argumentsValue)) {
          return Promise.reject(new TypeError("能力方法参数必须是对象"));
        }
        return request("app.capability.invoke", {
          instanceId: state.id,
          method,
          arguments: argumentsValue,
        });
      },
      on(event, callback) {
        if (!state.active) throw new Error("能力实例已释放");
        if (typeof event !== "string" || !event) throw new TypeError("事件名称必须是非空字符串");
        if (typeof callback !== "function") throw new TypeError("事件回调必须是函数");
        let listeners = state.listeners.get(event);
        if (!listeners) {
          listeners = new Set();
          state.listeners.set(event, listeners);
        }
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
      addEventListener(event, callback) {
        if (!state.active) throw new Error("能力实例已释放");
        if (typeof event !== "string" || !event) throw new TypeError("事件名称必须是非空字符串");
        if (typeof callback !== "function") throw new TypeError("事件回调必须是函数");
        let listeners = state.listeners.get(event);
        if (!listeners) {
          listeners = new Set();
          state.listeners.set(event, listeners);
        }
        listeners.add(callback);
      },
      removeEventListener(event, callback) {
        state.listeners.get(event)?.delete(callback);
      },
      onError(callback) {
        if (typeof callback !== "function") throw new TypeError("错误回调必须是函数");
        state.errorListeners.add(callback);
        return () => state.errorListeners.delete(callback);
      },
      async dispose() {
        if (!state.active) return;
        state.active = false;
        capabilityInstances.delete(state.id);
        state.listeners.clear();
        state.errorListeners.clear();
        await request("app.capability.dispose", { instanceId: state.id });
      },
    });
  }

  const APP_STORAGE_BUCKET_PATTERN =
    /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
  const APP_STORAGE_KEY_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
  const APP_STORAGE_GDEVELOP_ROOT_KEY = "$playmesh.gdevelop.root.v1";
  let appStorageSyncConfiguration = null;

  function validateAppStorageBucket(bucket) {
    if (typeof bucket !== "string" ||
        !APP_STORAGE_BUCKET_PATTERN.test(bucket)) {
      throw new TypeError(
        "App Bucket 名称必须以字母或数字开头，只能包含字母、数字、下划线和连字符，且不超过 64 个字符",
      );
    }
  }

  function validateAppStorageKey(key) {
    if (typeof key !== "string" || !APP_STORAGE_KEY_PATTERN.test(key)) {
      throw new TypeError(
        "App Bucket key 只能包含字母、数字、点、下划线和连字符，且长度为 1 至 128",
      );
    }
  }

  function appStorageUtf8Bytes(value) {
    if (typeof global.TextEncoder === "function") {
      return new global.TextEncoder().encode(value);
    }
    const encoded = unescape(encodeURIComponent(value));
    return Uint8Array.from(encoded, (character) => character.charCodeAt(0));
  }

  function validateSynchronousAppStorageBucket(bucket) {
    if (typeof bucket !== "string") {
      throw new TypeError("同步 App Bucket 逻辑名必须是字符串");
    }
    const length = appStorageUtf8Bytes(bucket).length;
    if (length < 1 || length > 4096) {
      throw new TypeError(
        "同步 App Bucket 逻辑名必须为 1 至 4096 个 UTF-8 字节",
      );
    }
  }

  function validateSynchronousAppStorageKey(key) {
    if (key === APP_STORAGE_GDEVELOP_ROOT_KEY) return;
    validateAppStorageKey(key);
  }

  function cloneAppStorageJson(value) {
    try {
      const encoded = JSON.stringify(value);
      if (typeof encoded !== "string") throw new TypeError();
      return JSON.parse(encoded);
    } catch (_) {
      throw new TypeError("App Bucket 只能写入 JSON 值");
    }
  }

  function browserAppStorage() {
    const storage = global.localStorage;
    if (!storage?.getItem || !storage?.setItem || !storage?.removeItem) {
      throw new Error("当前浏览器不支持 localStorage");
    }
    return storage;
  }

  function readBrowserAppBucket(bucket) {
    const raw = browserAppStorage().getItem(bucket);
    if (raw === null) return {};
    const decoded = JSON.parse(raw);
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
      throw new Error("App Bucket localStorage 根节点必须是对象");
    }
    for (const key of Object.keys(decoded)) validateSynchronousAppStorageKey(key);
    return decoded;
  }

  function browserAppStorageCall(operation, bucket, key, value) {
    const storage = browserAppStorage();
    if (operation === "get") {
      const values = readBrowserAppBucket(bucket);
      return Object.prototype.hasOwnProperty.call(values, key)
        ? cloneAppStorageJson(values[key])
        : null;
    }
    if (operation === "clear") {
      storage.removeItem(bucket);
      return null;
    }
    const values = readBrowserAppBucket(bucket);
    if (operation === "set") {
      values[key] = cloneAppStorageJson(value);
    } else if (operation === "remove") {
      delete values[key];
    } else {
      throw new Error(`未知 App Bucket 操作: ${operation}`);
    }
    storage.setItem(bucket, JSON.stringify(values));
    return null;
  }

  function appStorageCall(operation, bucket, key, value) {
    if (nativeSender() !== null) {
      if (operation === "get") {
        return request("app.storage.get", { bucket, key });
      }
      if (operation === "set") {
        return request("app.storage.set", { bucket, key, value });
      }
      if (operation === "remove") {
        return request("app.storage.remove", { bucket, key });
      }
      if (operation === "clear") {
        return request("app.storage.clear", { bucket });
      }
      return Promise.reject(
        new Error(`未知 App Bucket 操作: ${operation}`),
      );
    }
    try {
      return Promise.resolve(
        browserAppStorageCall(operation, bucket, key, value),
      );
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function configureAppStorageSync(configuration) {
    const endpoint = configuration?.endpoint;
    appStorageSyncConfiguration = typeof endpoint === "string" &&
        /^http:\/\/127\.0\.0\.1:\d+\/playmesh\/app-storage-sync\/v1\/[A-Za-z0-9_-]{43}$/.test(endpoint)
      ? Object.freeze({ endpoint })
      : null;
  }

  function appStorageBase64Url(bytes) {
    let binary = "";
    for (const value of bytes) binary += String.fromCharCode(value);
    return global.btoa(binary)
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replace(/=+$/g, "");
  }

  function appStorageCallSync(operation, bucket, key, value) {
    if (nativeSender() === null) {
      return browserAppStorageCall(
        operation === "sync.get" ? "get" : "set",
        bucket,
        key,
        value,
      );
    }
    const configuration = appStorageSyncConfiguration;
    if (!configuration) {
      throw new Error(
        "Playmesh App SDK 尚未就绪，App Bucket 同步存储不可用",
      );
    }
    if (typeof global.XMLHttpRequest !== "function") {
      throw new Error("当前 WebView 不支持 App Bucket 同步 XMLHttpRequest");
    }
    const requestId = `app-storage-sync-${Date.now()}-${++sequence}`;
    const envelope = operation === "sync.get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          operation,
          bucket,
          key,
        }
      : {
          protocolVersion: "1.0.0",
          requestId,
          operation,
          bucket,
          key,
          value,
        };
    const body = JSON.stringify(envelope);
    const method = operation === "sync.get" ? "GET" : "POST";
    const url = method === "GET"
      ? `${configuration.endpoint}?payload=${appStorageBase64Url(
          appStorageUtf8Bytes(body),
        )}`
      : configuration.endpoint;
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const xhr = new global.XMLHttpRequest();
        xhr.open(method, url, false);
        if (method === "POST") {
          xhr.setRequestHeader("Content-Type", "text/plain;charset=UTF-8");
        }
        xhr.send(method === "POST" ? body : null);
        const payload = JSON.parse(xhr.responseText || "");
        if (xhr.status < 200 || xhr.status >= 300 || payload?.error) {
          const error = new Error(
            payload?.error?.message || `App Bucket 同步请求失败: HTTP ${xhr.status}`,
          );
          if (typeof payload?.error?.code === "string") {
            error.code = payload.error.code;
          }
          throw error;
        }
        if (payload?.protocolVersion !== "1.0.0" ||
            payload?.requestId !== requestId ||
            !Object.prototype.hasOwnProperty.call(payload, "result")) {
          throw new Error("App Bucket 同步响应无效");
        }
        return payload.result;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError || new Error("App Bucket 同步请求失败");
  }

  const appStorageApi = Object.freeze({
    getBucket(bucket) {
      validateSynchronousAppStorageBucket(bucket);
      return Object.freeze({
        getData(key) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          return appStorageCall("get", bucket, key);
        },
        setData(key, value) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          const cloned = cloneAppStorageJson(value);
          return appStorageCall("set", bucket, key, cloned);
        },
        getDataSync(key) {
          validateSynchronousAppStorageKey(key);
          return cloneAppStorageJson(
            appStorageCallSync("sync.get", bucket, key),
          );
        },
        setDataSync(key, value) {
          validateSynchronousAppStorageKey(key);
          const cloned = cloneAppStorageJson(value);
          appStorageCallSync("sync.set", bucket, key, cloned);
        },
        removeData(key) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          return appStorageCall("remove", bucket, key);
        },
        clearData() {
          validateAppStorageBucket(bucket);
          return appStorageCall("clear", bucket);
        },
      });
    },
  });

  const appMediaAdapters = new Map();
  const appMediaSessions = new Map();

  function registerAppMediaAdapter(protocol, adapter) {
    if (typeof protocol !== "string" || !protocol) {
      throw new TypeError("媒体协议必须是非空字符串");
    }
    if (!adapter || typeof adapter.open !== "function") {
      throw new TypeError(`媒体协议 ${protocol} 没有实现 open`);
    }
    if (appMediaAdapters.has(protocol)) {
      throw new Error(`媒体协议重复注册: ${protocol}`);
    }
    appMediaAdapters.set(protocol, Object.freeze(adapter));
  }

  function validateAppMediaSource(source) {
    if (!source || typeof source !== "object" || Array.isArray(source) ||
        source.type !== "playmesh.app.media-source" ||
        source.version !== 1 ||
        typeof source.id !== "string" || !source.id ||
        typeof source.kind !== "string" || !source.kind ||
        typeof source.protocol !== "string" || !source.protocol ||
        source.live !== true) {
      throw new TypeError("媒体源描述符无效");
    }
  }

  async function openAppMedia(source, options = {}) {
    validateAppMediaSource(source);
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("媒体打开参数必须是对象");
    }
    if (options.signal !== undefined &&
        (typeof global.AbortSignal !== "function" ||
         !(options.signal instanceof global.AbortSignal))) {
      throw new TypeError("signal 必须是 AbortSignal");
    }
    if (options.signal?.aborted) throw new DOMException("操作已取消", "AbortError");
    const adapter = appMediaAdapters.get(source.protocol);
    if (!adapter) throw new Error(`当前 App SDK 不支持媒体协议 ${source.protocol}`);
    const session = await adapter.open(clone(source), options);
    if (!session || typeof session.id !== "string" || !session.id ||
        typeof global.MediaStream !== "function" ||
        !(session.stream instanceof global.MediaStream) ||
        typeof session.close !== "function") {
      try {
        await session?.close?.();
      } catch (_) {}
      throw new Error(`媒体协议 ${source.protocol} 返回了无效会话`);
    }
    appMediaSessions.set(session.id, session);
    let active = true;
    return Object.freeze({
      id: session.id,
      source: clone(source),
      stream: session.stream,
      get state() {
        return active ? (session.state || "open") : "ended";
      },
      async close() {
        if (!active) return;
        active = false;
        appMediaSessions.delete(session.id);
        await session.close();
      },
    });
  }

  global.addEventListener?.("pagehide", () => {
    const sessions = [...appMediaSessions.values()];
    appMediaSessions.clear();
    for (const session of sessions) {
      try {
        session.close({ notifyHost: false });
      } catch (_) {}
    }
  });

  function waitForAppMediaIceGathering(peer, timeoutMs = 8000) {
    if (peer.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        cleanup();
        reject(new Error("WebRTC ICE 收集超时"));
      }, timeoutMs);
      const onChange = () => {
        if (peer.iceGatheringState !== "complete") return;
        cleanup();
        resolve();
      };
      const cleanup = () => {
        global.clearTimeout(timer);
        peer.removeEventListener("icegatheringstatechange", onChange);
      };
      peer.addEventListener("icegatheringstatechange", onChange);
    });
  }

  function waitForAppMediaTrack(peer, stream, timeoutMs = 10000) {
    let cancel = () => {};
    const promise = new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        cleanup();
        reject(new Error("WebRTC 媒体轨道建立超时"));
      }, timeoutMs);
      const onTrack = (event) => {
        if (!stream.getTracks().some((track) => track.id === event.track.id)) {
          stream.addTrack(event.track);
        }
        cleanup();
        resolve();
      };
      const cleanup = () => {
        global.clearTimeout(timer);
        peer.removeEventListener("track", onTrack);
      };
      cancel = cleanup;
      peer.addEventListener("track", onTrack);
    });
    return { promise, cancel: () => cancel() };
  }

  registerAppMediaAdapter("webrtc", {
    async open(source, options) {
      if (typeof global.RTCPeerConnection !== "function" ||
          typeof global.MediaStream !== "function") {
        throw new Error("当前 WebView 不支持 WebRTC MediaStream");
      }
      const peer = new global.RTCPeerConnection({ iceServers: [] });
      const stream = new global.MediaStream();
      let hostSessionId = null;
      let closed = false;
      let state = "opening";
      const trackWait = waitForAppMediaTrack(peer, stream);
      const abort = () => {
        peer.close();
      };
      options.signal?.addEventListener("abort", abort, { once: true });
      try {
        if (source.kind === "video" || source.kind === "audio-video") {
          peer.addTransceiver("video", { direction: "recvonly" });
        }
        if (source.kind === "audio" || source.kind === "audio-video") {
          peer.addTransceiver("audio", { direction: "recvonly" });
        }
        await peer.setLocalDescription(await peer.createOffer());
        await waitForAppMediaIceGathering(peer);
        if (options.signal?.aborted) throw new DOMException("操作已取消", "AbortError");
        const opened = await request("app.media.open", {
          source,
          adapterOptions: {
            offer: {
              type: peer.localDescription.type,
              sdp: peer.localDescription.sdp,
            },
          },
        });
        hostSessionId = opened?.sessionId;
        if (typeof hostSessionId !== "string" || !hostSessionId ||
            opened?.protocol !== "webrtc" ||
            !opened.answer || typeof opened.answer.sdp !== "string") {
          throw new Error("WebRTC 宿主返回了无效应答");
        }
        await peer.setRemoteDescription(opened.answer);
        await trackWait.promise;
        state = "open";
      } catch (error) {
        state = "failed";
        trackWait.cancel();
        peer.close();
        if (hostSessionId) {
          try {
            await request("app.media.close", { sessionId: hostSessionId });
          } catch (_) {}
        }
        throw error;
      } finally {
        options.signal?.removeEventListener("abort", abort);
      }
      return {
        id: hostSessionId,
        stream,
        get state() {
          return state;
        },
        async close(closeOptions = {}) {
          if (closed) return;
          closed = true;
          state = "ended";
          for (const track of stream.getTracks()) track.stop();
          peer.close();
          if (closeOptions.notifyHost !== false) {
            await request("app.media.close", { sessionId: hostSessionId });
          }
        },
      };
    },
  });

  let appPerformanceMultiplayer = false;
  let appPerformanceFps = null;
  let appPerformanceFrameCount = 0;
  let appPerformanceWindowStartedAt = null;
  let appPerformanceLatency = null;
  let appPerformanceLatencyDiagnostics = null;
  let appPerformanceLatencyTimer = null;
  let appPerformanceProbeSequence = 0;
  let appPerformanceSendLatencyProbe = null;
  const appPerformanceFpsListeners = new Set();
  const appPerformanceLatencyListeners = new Set();

  function emitAppPerformance(listeners, value) {
    for (const listener of [...listeners]) listener(value);
  }

  function refreshAppPerformanceUi() {
    refreshAppUiPerformance();
  }

  function configureAppRuntimePerformance(context) {
    const multiplayer = context?.multiplayer === true;
    appPerformanceMultiplayer = multiplayer;
    appPerformanceSendLatencyProbe =
      typeof context?.sendLatencyProbe === "function"
        ? context.sendLatencyProbe
        : null;
    if (!multiplayer || !appPerformanceSendLatencyProbe) {
      stopAppRuntimeLatencyProbes();
      resetAppRuntimeLatency();
    } else if (!appPerformanceLatencyTimer) {
      sendAppRuntimeLatencyProbe();
      appPerformanceLatencyTimer = global.setInterval(
        sendAppRuntimeLatencyProbe,
        3000,
      );
      appPerformanceLatencyTimer?.unref?.();
    }
    refreshAppPerformanceUi();
  }

  function sendAppRuntimeLatencyProbe() {
    if (!appPerformanceMultiplayer || !appPerformanceSendLatencyProbe) return;
    const clientSentAt = Date.now();
    const payload = {
      probeId:
        `latency-${clientSentAt}-${++appPerformanceProbeSequence}`,
      clientSentAt,
    };
    try {
      Promise.resolve(appPerformanceSendLatencyProbe(payload)).catch(() => {});
    } catch (_) {
      // 单次探测失败不得中断游戏或本地性能浮层。
    }
  }

  function stopAppRuntimeLatencyProbes() {
    if (appPerformanceLatencyTimer) {
      global.clearInterval(appPerformanceLatencyTimer);
    }
    appPerformanceLatencyTimer = null;
    appPerformanceSendLatencyProbe = null;
  }

  function resetAppRuntimeLatency() {
    appPerformanceLatency = null;
    appPerformanceLatencyDiagnostics = null;
    emitAppPerformance(appPerformanceLatencyListeners, null);
    refreshAppPerformanceUi();
  }

  function recordAppRuntimeLatencyPong(payload) {
    const receivedAt = Date.now();
    const sentAt = Number(payload?.clientSentAt);
    if (!Number.isFinite(sentAt) || sentAt > receivedAt) return;
    if (payload.authorityAvailable !== true) {
      appPerformanceLatency = null;
      appPerformanceLatencyDiagnostics = {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: false,
      };
    } else {
      const rawRttMs = Math.max(0, receivedAt - sentAt);
      const smoothed = appPerformanceLatency == null
        ? rawRttMs
        : (appPerformanceLatency * 0.75) + (rawRttMs * 0.25);
      appPerformanceLatency = Math.max(0, Math.round(smoothed));
      appPerformanceLatencyDiagnostics = {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: true,
        rawRttMs,
      };
    }
    emitAppPerformance(
      appPerformanceLatencyListeners,
      appPerformanceLatency,
    );
    refreshAppPerformanceUi();
  }

  function reportAppPerformanceFrame(
    timestamp = global.performance?.now?.() || Date.now(),
  ) {
    if (typeof timestamp !== "number" || !Number.isFinite(timestamp)) {
      throw new TypeError("timestamp 必须是有限数值");
    }
    appPerformanceFrameCount += 1;
    appPerformanceWindowStartedAt ??= timestamp;
    const elapsed = timestamp - appPerformanceWindowStartedAt;
    if (elapsed < 1000) return appPerformanceFps;
    appPerformanceFps = Math.max(
      0,
      Math.round((appPerformanceFrameCount * 1000) / elapsed),
    );
    appPerformanceFrameCount = 0;
    appPerformanceWindowStartedAt = timestamp;
    emitAppPerformance(appPerformanceFpsListeners, appPerformanceFps);
    refreshAppPerformanceUi();
    return appPerformanceFps;
  }

  function subscribeAppPerformance(listeners, callback, currentValue) {
    if (typeof callback !== "function") {
      throw new TypeError("callback 必须是函数");
    }
    listeners.add(callback);
    callback(currentValue);
    return function unsubscribe() {
      listeners.delete(callback);
    };
  }

  function appPerformanceSnapshot() {
    return {
      fps: appPerformanceFps,
      latency: appPerformanceLatency,
      multiplayer: appPerformanceMultiplayer,
    };
  }


  let appUiReturnFocus = null;
  let appUiFocusCapturePending = false;
  let appFallbackUi = null;
  let appUiConfiguration = null;
  let appUiRuntimeAdapter = null;
  let appUiSystemMenuTriggerDisposer = null;
  let appUiSystemMenuTriggersDisabled = false;
  let appUiTogglePending = false;
  let appUiConsoleCaptureInstalled = false;
  let appUiPerformanceVisible = false;
  let appUiRenderTimer = null;
  const appUiConsoleLogs = [];
  const appUiGameMenuOpenListeners = new Set();
  const appUiGameMenuCloseListeners = new Set();
  let appUiGameMenuOpen = false;
  const APP_UI_LOG_LIMIT = 500;
  const APP_UI_INPUT_EVENTS = Object.freeze([
    "auxclick",
    "click",
    "contextmenu",
    "dblclick",
    "mousedown",
    "mousemove",
    "mouseup",
    "pointercancel",
    "pointerdown",
    "pointermove",
    "pointerup",
    "touchcancel",
    "touchend",
    "touchmove",
    "touchstart",
    "wheel",
  ]);
  const initialAppUiOptions =
    global.__PLAYMESH_APP_OPTIONS__ &&
    typeof global.__PLAYMESH_APP_OPTIONS__ === "object"
      ? global.__PLAYMESH_APP_OPTIONS__
      : {};
  const appUiOptions = {
    fallbackUi: initialAppUiOptions.fallbackUi !== false,
    floatingButton: initialAppUiOptions.floatingButton !== false,
  };

  function appUiError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function subscribeAppUiEvent(listeners, callback, name) {
    if (typeof callback !== "function") {
      throw new TypeError(`${name} callback 必须是函数`);
    }
    listeners.add(callback);
    let subscribed = true;
    return function unsubscribe() {
      if (!subscribed) return;
      subscribed = false;
      listeners.delete(callback);
    };
  }

  function reportAppUiEventError(name, error) {
    global.console?.warn?.(`Playmesh ${name} 回调执行失败`, error);
  }

  function notifyAppUiEvent(listeners, name) {
    for (const callback of [...listeners]) {
      try {
        const result = callback();
        if (result && typeof result.then === "function") {
          void result.catch((error) => reportAppUiEventError(name, error));
        }
      } catch (error) {
        reportAppUiEventError(name, error);
      }
    }
  }

  function setAppUiGameMenuOpen(open) {
    const nextOpen = open === true;
    if (appUiGameMenuOpen === nextOpen) return false;
    appUiGameMenuOpen = nextOpen;
    notifyAppUiEvent(
      nextOpen ? appUiGameMenuOpenListeners : appUiGameMenuCloseListeners,
      nextOpen ? "游戏菜单打开" : "游戏菜单关闭",
    );
    return true;
  }

  function onAppGameMenuOpen(callback) {
    return subscribeAppUiEvent(
      appUiGameMenuOpenListeners,
      callback,
      "onGameMenuOpen",
    );
  }

  function onAppGameMenuClose(callback) {
    return subscribeAppUiEvent(
      appUiGameMenuCloseListeners,
      callback,
      "onGameMenuClose",
    );
  }

  function configureAppUi(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("Playmesh App SDK 配置必须是对象");
    }
    for (const key of ["fallbackUi", "floatingButton"]) {
      if (options[key] !== undefined && typeof options[key] !== "boolean") {
        throw new TypeError(`${key} 必须是布尔值`);
      }
    }
    const previousFloatingButton = appUiOptions.floatingButton;
    if (options.fallbackUi !== undefined) {
      appUiOptions.fallbackUi = options.fallbackUi;
    }
    if (options.floatingButton !== undefined) {
      appUiOptions.floatingButton = options.floatingButton;
    }
    if (!appUiOptions.fallbackUi) {
      void hideAppGameSidebar();
      if (appUiRenderTimer !== null) {
        global.clearTimeout?.(appUiRenderTimer);
        appUiRenderTimer = null;
      }
      appFallbackUi?.host?.remove?.();
      appFallbackUi = null;
    } else {
      if (appFallbackUi &&
          previousFloatingButton !== appUiOptions.floatingButton) {
        void hideAppGameSidebar();
        appFallbackUi.host?.remove?.();
        appFallbackUi = null;
      }
      scheduleAppFallbackUi();
    }
    return {
      fallbackUi: appUiOptions.fallbackUi,
      floatingButton: appUiOptions.floatingButton,
    };
  }

  function initializeBrowserAppUi() {
    if (!global.__PLAYMESH_BROWSER__) return false;
    configureAppUi({ fallbackUi: true, floatingButton: false });
    return true;
  }

  function scheduleAppFallbackUi() {
    if (!appUiOptions.fallbackUi || appFallbackUi ||
        appUiRenderTimer !== null) {
      return;
    }
    if (typeof global.setTimeout !== "function") {
      void ensureAppFallbackUi();
      return;
    }
    appUiRenderTimer = global.setTimeout(() => {
      appUiRenderTimer = null;
      if (appUiOptions.fallbackUi) void ensureAppFallbackUi();
    }, 0);
  }

  function captureAppUiReturnFocus() {
    const documentObject = global.document;
    const activeElement = documentObject?.activeElement;
    appUiReturnFocus =
      activeElement &&
      activeElement !== documentObject?.body &&
      activeElement !== documentObject?.documentElement &&
      activeElement.isConnected !== false &&
      typeof activeElement.focus === "function"
        ? activeElement
        : null;
    appUiFocusCapturePending = true;
  }

  function clearAppUiReturnFocus() {
    appUiReturnFocus = null;
    appUiFocusCapturePending = false;
  }

  function restoreAppUiReturnFocus() {
    if (!appUiFocusCapturePending) return;
    appUiFocusCapturePending = false;
    const documentObject = global.document;
    const returnFocus = appUiReturnFocus;
    appUiReturnFocus = null;
    if (
      returnFocus &&
      returnFocus.isConnected !== false &&
      typeof returnFocus.focus === "function"
    ) {
      try {
        returnFocus.focus({ preventScroll: true });
        if (documentObject?.activeElement === returnFocus) return;
      } catch (_) {
        // 平台 UI 未消费时继续交给游戏文档处理。
      }
    }
    const gameDocumentTarget =
      documentObject?.body || documentObject?.documentElement;
    if (!gameDocumentTarget || typeof gameDocumentTarget.focus !== "function") {
      return;
    }
    const previousTabIndex = gameDocumentTarget.getAttribute?.("tabindex");
    try {
      if (gameDocumentTarget.tabIndex < 0) {
        gameDocumentTarget.setAttribute?.("tabindex", "-1");
      }
      gameDocumentTarget.focus({ preventScroll: true });
    } catch (_) {
      // 页面卸载期间游戏文档可能已经无法恢复焦点。
    } finally {
      if (previousTabIndex == null) {
        gameDocumentTarget.removeAttribute?.("tabindex");
      } else {
        gameDocumentTarget.setAttribute?.("tabindex", previousTabIndex);
      }
    }
  }

  function appUiText(key) {
    const messages = appUiConfiguration?.messages;
    const value = messages && typeof messages[key] === "string"
      ? messages[key]
      : null;
    if (!value) {
      throw new Error(`平台 UI 本地化消息不可用: ${key}`);
    }
    return value;
  }

  function resolveAppUiConfiguration(configuration) {
    if (!configuration || typeof configuration !== "object") return null;
    if (!Array.isArray(configuration.locales)) return configuration;
    const locales = configuration.locales.filter(
      (item) => item && typeof item === "object" &&
        typeof item.locale === "string",
    );
    let browserLocales = [];
    try {
      browserLocales = [
        ...(Array.isArray(global.navigator?.languages)
          ? global.navigator.languages
          : []),
        global.navigator?.language,
      ];
    } catch (_) {
      // 受限浏览器上下文可能禁止访问 navigator。
    }
    const candidates = [
      ...browserLocales,
      configuration.fallbackLocale,
    ].filter((value) => typeof value === "string" && value);
    let selected = null;
    for (const candidate of candidates) {
      const normalized = candidate.toLowerCase();
      selected =
        locales.find((item) => item.locale.toLowerCase() === normalized) ||
        locales.find((item) =>
          item.locale.toLowerCase().split("-")[0] ===
          normalized.split("-")[0]
        );
      if (selected) break;
    }
    selected ||= locales[0] || null;
    if (!selected) return null;
    const theme = selected.theme === "system"
      ? global.matchMedia?.("(prefers-color-scheme: light)")?.matches
        ? "light"
        : "dark"
      : selected.theme;
    return {
      ...selected,
      theme,
      actions: configuration.actions || selected.actions,
    };
  }

  function appUiActionEnabled(name, fallback = true) {
    const configured = appUiConfiguration?.actions?.[name];
    return typeof configured === "boolean" ? configured : fallback;
  }

  function escapeAppUiHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function formatAppUiConsoleValue(value) {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack || value.message;
    if (typeof value === "bigint") return value.toString();
    try {
      const encoded = JSON.stringify(value);
      return encoded === undefined ? String(value) : encoded;
    } catch (_) {
      return String(value);
    }
  }

  function installAppUiConsoleCapture() {
    if (appUiConsoleCaptureInstalled || !global.console) return;
    appUiConsoleCaptureInstalled = true;
    for (const level of ["debug", "info", "log", "warn", "error"]) {
      const original = global.console[level];
      if (typeof original !== "function") continue;
      global.console[level] = function (...args) {
        const message = args.map(formatAppUiConsoleValue).join(" ");
        appUiConsoleLogs.push({
          timestamp: Date.now(),
          level,
          message,
        });
        if (appUiConsoleLogs.length > APP_UI_LOG_LIMIT) {
          appUiConsoleLogs.splice(
            0,
            appUiConsoleLogs.length - APP_UI_LOG_LIMIT,
          );
        }
        if (appFallbackUi?.logsLayer &&
            !appFallbackUi.logsLayer.hidden) {
          renderAppUiLogs();
        }
        return original.call(this, message);
      };
    }
  }

  function renderAppUiLogs() {
    const output = appFallbackUi?.logsOutput;
    if (!output) return;
    output.textContent = appUiConsoleLogs.length
      ? appUiConsoleLogs.map((entry) => {
          const time = new Date(entry.timestamp).toLocaleTimeString();
          return `[${time}] [${entry.level.toUpperCase()}] ${entry.message}`;
        }).join("\n")
      : appUiText("logs.empty");
    output.scrollTop = output.scrollHeight;
  }

  function registerAppUiRuntimeAdapter(adapter) {
    appUiRuntimeAdapter =
      adapter && typeof adapter === "object" ? adapter : null;
    refreshAppFallbackUi();
    refreshAppUiPerformance();
  }

  async function appUiGameInfo() {
    if (typeof appUiRuntimeAdapter?.getInfo !== "function") return null;
    const runtimeInfo = await appUiRuntimeAdapter.getInfo();
    if (!runtimeInfo?.gameId || !runtimeInfo?.gameName) return null;
    const capabilities = runtimeInfo.requiredCapabilities || [];
    const tags = Array.isArray(runtimeInfo.tags)
      ? [...new Set(runtimeInfo.tags
          .map((tag) => String(tag || "").trim())
          .filter(Boolean))]
      : [];
    const role = runtimeInfo.multiplayer === true
      ? runtimeInfo.isAuthority === true
        ? appUiText("info.role_authority")
        : appUiText("info.role_player")
      : appUiText("info.role_solo");
    const gameId = runtimeInfo.gameId;
    const rows = [
      gameId
        ? {
            label: appUiText("info.game_id"),
            value: gameId,
            code: true,
            wide: true,
          }
        : null,
      { label: appUiText("info.role"), value: role },
      runtimeInfo.joinCode
        ? {
            label: appUiText("info.join_code_label"),
            value: runtimeInfo.joinCode,
            code: true,
          }
        : null,
      runtimeInfo.playerName
        ? {
            label: appUiText("info.player"),
            value: runtimeInfo.playerName,
          }
        : null,
      Number.isFinite(runtimeInfo.playerCount)
        ? {
            label: appUiText("info.players"),
            value: String(runtimeInfo.playerCount),
          }
        : null,
      {
        label: appUiText("info.platform"),
        value: runtimeInfo.platform,
      },
      runtimeInfo.gameSdkVersion
        ? {
            label: appUiText("info.game_sdk"),
            value: runtimeInfo.gameSdkVersion,
          }
        : null,
      {
        label: appUiText("info.app_sdk"),
        value: runtimeInfo.appSdkVersion,
      },
      {
        label: appUiText("info.capabilities"),
        value: Array.isArray(capabilities) && capabilities.length
          ? capabilities.join(" · ")
          : appUiText("info.none"),
        wide: true,
      },
    ].filter(Boolean);
    return {
      gameName: runtimeInfo.gameName,
      tags,
      rows,
      canEditNickname:
        runtimeInfo.canEditNickname === true &&
        Boolean(runtimeInfo.playerName) &&
        typeof appUiRuntimeAdapter?.editNickname === "function",
    };
  }

  function refreshAppUiPerformance() {
    const ui = appFallbackUi;
    if (!ui?.performancePanel) return;
    const metrics = appPerformanceSnapshot();
    ui.performancePanel.hidden = !appUiPerformanceVisible;
    ui.performanceButton?.setAttribute?.(
      "aria-pressed",
      String(appUiPerformanceVisible),
    );
    setAppUiControlLabel(
      ui.performanceButton,
      appUiPerformanceVisible
        ? "sidebar.performance_hide"
        : "sidebar.performance",
    );
    ui.fps.textContent =
      typeof metrics.fps === "number" ? `${Math.round(metrics.fps)} FPS` : "-- FPS";
    ui.latency.hidden = metrics.multiplayer !== true;
    ui.latency.textContent =
      typeof metrics.latency === "number"
        ? `${Math.round(metrics.latency)} ms`
        : "-- ms";
  }

  function setAppUiPerformanceVisible(visible) {
    appUiPerformanceVisible = visible === true;
    refreshAppUiPerformance();
    return appUiPerformanceVisible;
  }

  async function restartAppUiGame() {
    hideAppGameSidebar(false);
    try {
      if (appUiRuntimeAdapter?.reload) await appUiRuntimeAdapter.reload();
      else global.location?.reload?.();
    } catch (error) {
      global.console?.warn?.("Playmesh 重新开始游戏失败", error);
    }
  }

  async function openAppUiRuntimeLogs() {
    if (!appUiOptions.fallbackUi) return false;
    const ui = await ensureAppFallbackUi();
    if (!ui) return false;
    renderAppUiLogs();
    ui.logsLayer.hidden = false;
    ui.logsClose.focus?.({ preventScroll: true });
    return true;
  }

  async function copyAppUiRuntimeLogs() {
    const text = appFallbackUi?.logsOutput?.textContent || "";
    if (global.navigator?.clipboard?.writeText) {
      await global.navigator.clipboard.writeText(text);
      return true;
    }
    const copyField = global.document?.createElement?.("textarea");
    if (!copyField || !global.document?.body) return false;
    copyField.value = text;
    copyField.setAttribute?.("readonly", "");
    copyField.style.position = "fixed";
    copyField.style.opacity = "0";
    global.document.body.appendChild(copyField);
    copyField.select?.();
    const copied = global.document.execCommand?.("copy") === true;
    copyField.remove?.();
    return copied;
  }

  async function openAppUiGameInfo() {
    if (!appUiOptions.fallbackUi) return false;
    const ui = await ensureAppFallbackUi();
    if (!ui) return false;
    const info = await appUiGameInfo();
    if (!info) return false;
    ui.gameName.textContent = info.gameName;
    ui.gameTags.innerHTML = info.tags.map((tag) => `
      <span class="game-tag" role="listitem">
        <span class="game-tag-mark" aria-hidden="true">#</span>${escapeAppUiHtml(tag)}
      </span>
    `).join("");
    ui.gameTagsWrap.hidden = info.tags.length === 0;
    ui.gameTags.setAttribute(
      "aria-label",
      appUiText("info.tags"),
    );
    ui.gameTagsLabel.textContent = appUiText("info.tags");
    ui.gameDetail.innerHTML = info.rows.map((row) => `
      <div class="info-item${row.wide ? " wide" : ""}">
        <dt class="info-label">${escapeAppUiHtml(row.label)}</dt>
        <dd class="info-value${row.code ? " code" : ""}">${escapeAppUiHtml(row.value)}</dd>
      </div>
    `).join("");
    ui.infoEdit.hidden = !info.canEditNickname;
    ui.infoLayer.hidden = false;
    ui.infoClose.focus?.({ preventScroll: true });
    return true;
  }

  function installAppMenuButtonDrag(ui) {
    const button = ui?.menuButton;
    if (!button?.addEventListener) return;
    const dragThreshold = 5;
    const offscreenFraction = 0.5;
    let activePointerId = null;
    let startX = 0;
    let startY = 0;
    let startLeft = 0;
    let startTop = 0;
    let moved = false;
    let hasCustomPosition = false;
    let suppressNextClick = false;

    const viewportSize = () => ({
      width: global.visualViewport?.width ||
        global.innerWidth ||
        global.document?.documentElement?.clientWidth ||
        0,
      height: global.visualViewport?.height ||
        global.innerHeight ||
        global.document?.documentElement?.clientHeight ||
        0,
    });
    const moveTo = (left, top) => {
      const rect = button.getBoundingClientRect();
      const viewport = viewportSize();
      const minLeft = -rect.width * offscreenFraction;
      const minTop = -rect.height * offscreenFraction;
      const maxLeft = viewport.width - rect.width * (1 - offscreenFraction);
      const maxTop = viewport.height - rect.height * (1 - offscreenFraction);
      button.style.left =
        `${Math.round(Math.min(Math.max(minLeft, left), maxLeft))}px`;
      button.style.top =
        `${Math.round(Math.min(Math.max(minTop, top), maxTop))}px`;
      button.style.right = "auto";
      button.style.bottom = "auto";
      button.classList?.toggle?.("detached", true);
      hasCustomPosition = true;
    };
    const finish = (event) => {
      if (activePointerId === null ||
          (event?.pointerId !== undefined &&
            event.pointerId !== activePointerId)) {
        return;
      }
      button.releasePointerCapture?.(activePointerId);
      button.classList?.toggle?.("dragging", false);
      activePointerId = null;
      if (moved) {
        suppressNextClick = true;
        global.setTimeout?.(() => {
          suppressNextClick = false;
        }, 0);
      }
    };
    button.addEventListener("pointerdown", (event) => {
      if (event?.button !== undefined && event.button !== 0) return;
      const rect = button.getBoundingClientRect();
      activePointerId = event?.pointerId ?? 0;
      startX = event?.clientX ?? 0;
      startY = event?.clientY ?? 0;
      startLeft = rect.left;
      startTop = rect.top;
      moved = false;
      button.classList?.toggle?.("dragging", true);
      button.setPointerCapture?.(activePointerId);
    });
    button.addEventListener("pointermove", (event) => {
      if (activePointerId === null ||
          (event?.pointerId !== undefined &&
            event.pointerId !== activePointerId)) {
        return;
      }
      const deltaX = (event?.clientX ?? startX) - startX;
      const deltaY = (event?.clientY ?? startY) - startY;
      if (!moved && Math.hypot(deltaX, deltaY) < dragThreshold) return;
      moved = true;
      event?.preventDefault?.();
      moveTo(startLeft + deltaX, startTop + deltaY);
    });
    button.addEventListener("pointerup", finish);
    button.addEventListener("pointercancel", finish);
    button.addEventListener("click", (event) => {
      if (!suppressNextClick) return;
      suppressNextClick = false;
      event?.preventDefault?.();
      event?.stopImmediatePropagation?.();
    }, true);
    global.addEventListener?.("resize", () => {
      if (!hasCustomPosition) return;
      const rect = button.getBoundingClientRect();
      moveTo(rect.left, rect.top);
    });
  }

  function installAppUiInputIsolation(root) {
    if (!root?.addEventListener) return;
    for (const type of APP_UI_INPUT_EVENTS) {
      root.addEventListener(type, (event) => {
        event?.stopPropagation?.();
      });
    }
  }

  async function ensureAppFallbackUi() {
    if (!appUiOptions.fallbackUi) return null;
    if (appFallbackUi) return appFallbackUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener(
        "DOMContentLoaded",
        resolve,
        { once: true },
      ));
    }
    if (!appUiOptions.fallbackUi || appFallbackUi) return appFallbackUi;
    const host = global.document.createElement("div");
    host.id = "playmesh-app-platform-ui";
    host.setAttribute?.("lang", appUiConfiguration?.locale || "zh-CN");
    host.setAttribute?.("data-theme", appUiConfiguration?.theme || "dark");
    const root = host.attachShadow({ mode: "closed" });
    installAppUiInputIsolation(root);
    const menuButtonMarkup =
      global.__PLAYMESH_BROWSER__ && appUiOptions.floatingButton
        ? `<button class="menu-fab" type="button"><span class="menu-mark" aria-hidden="true">P</span></button>`
        : "";
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#111827f2;--pm-surface-strong:#172033;--pm-hover:#26334a;--pm-text:#f8fafc;--pm-muted:#a8b4c7;--pm-border:#60708a40;--pm-divider:#ffffff14;--pm-overlay:#050a14a8;--pm-focus:#67e8f9;--pm-focus-ring:#67e8f94d;--pm-accent:#2dd4bf;--pm-accent-strong:#0f9f8d;--pm-error:#fda4af;--pm-log:#090f1c;--pm-shadow:#0008;font-family:system-ui,"Microsoft YaHei",sans-serif;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#f8fafcf5;--pm-surface-strong:#fff;--pm-hover:#e8eef7;--pm-text:#172033;--pm-muted:#5d6b80;--pm-border:#9aabc238;--pm-divider:#24324a14;--pm-overlay:#17203366;--pm-focus:#087f8c;--pm-focus-ring:#087f8c3d;--pm-accent:#0f9f8d;--pm-accent-strong:#087f6d;--pm-error:#b4233f;--pm-log:#edf2f7;--pm-shadow:#17203330;color-scheme:light}
      button{box-sizing:border-box;font:inherit}.menu-fab{position:fixed;right:0;top:36%;z-index:2147483645;display:grid;place-items:center;width:42px;height:42px;padding:0;border:1px solid #92e6d5;border-radius:13px 0 0 13px;background:#087f6d;color:#fff;box-shadow:0 6px 18px #001b1752,0 2px 6px #001b1738;cursor:grab;isolation:isolate;touch-action:none;user-select:none;-webkit-user-select:none;transition:transform .16s ease,box-shadow .16s ease,border-radius .16s ease}.menu-fab.detached{border-radius:13px}
      .menu-fab::before{content:"";position:absolute;inset:-2px;z-index:-1;border:1px solid #36cbb266;border-radius:16px 0 0 16px;animation:menu-breathe 2.8s ease-in-out infinite;pointer-events:none}.menu-fab.detached::before{border-radius:16px}.menu-fab.detached:hover{transform:translateY(-2px)}.menu-fab:active{transform:scale(.96)}.menu-fab.dragging{cursor:grabbing;transform:none;transition:none}.menu-fab:focus-visible,.dialog button:focus-visible,.logs-output:focus-visible{outline:2px solid var(--pm-focus);outline-offset:2px}.action:focus-visible{outline:0;background:var(--pm-hover);box-shadow:inset 0 0 0 2px var(--pm-focus-ring)}
      .menu-mark{position:relative;display:block;width:22px;transform:translateX(-2px);font:900 20px/1 system-ui}.menu-mark::after{content:"";position:absolute;left:15px;top:3px;width:7px;height:2px;border-radius:2px;background:currentColor;box-shadow:0 5px currentColor,0 10px currentColor}
      .layer{position:fixed;inset:0;z-index:2147483646;display:grid;place-items:center;cursor:default;padding:max(18px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(18px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left));color:var(--pm-text)}.scrim{position:absolute;inset:0;width:100%;height:100%;background:radial-gradient(circle at 50% 42%,#21304a52 0,transparent 48%),var(--pm-overlay);backdrop-filter:blur(12px) saturate(1.08);-webkit-backdrop-filter:blur(12px) saturate(1.08)}.sidebar{box-sizing:border-box;position:relative;display:grid;grid-template-rows:auto minmax(0,1fr) auto;width:min(100%,480px);max-height:min(720px,calc(100dvh - 36px));overflow:hidden;padding:10px;border:0;border-radius:22px;background:linear-gradient(145deg,var(--pm-surface-strong),var(--pm-surface));box-shadow:0 24px 72px var(--pm-shadow),0 1px 0 #ffffff0f inset;animation:menu-arrive .18s cubic-bezier(.2,.8,.2,1)}.head{display:flex;align-items:center;gap:12px;padding:8px 10px 16px;border-bottom:1px solid var(--pm-divider)}.brand{display:grid;place-items:center;width:36px;height:36px;border-radius:12px;background:var(--pm-accent-strong);color:#fff;font:850 18px/1 system-ui}.title{margin:0;color:var(--pm-text);font-size:19px;line-height:1.25;font-weight:780;letter-spacing:.01em}.actions-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px;min-height:0;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable;-webkit-overflow-scrolling:touch;padding:10px 0}.action{display:flex;align-items:center;gap:11px;width:100%;min-height:52px;padding:9px 12px;border:0;border-radius:11px;background:transparent;color:var(--pm-text);font:650 14px/1.25 system-ui,"Microsoft YaHei",sans-serif;text-align:left;cursor:pointer;transition:background .14s ease,box-shadow .14s ease}.action:hover{background:var(--pm-hover)}.action.continue{background:#2dd4bf14;color:var(--pm-accent)}.action.exit{min-height:48px;color:var(--pm-error);background:transparent}.icon{display:grid;place-items:center;flex:0 0 24px;width:24px;color:inherit;font:800 18px/1 system-ui}.foot{padding-top:6px;border-top:1px solid var(--pm-divider)}
      .dialog-layer{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;cursor:default;padding:16px;background:var(--pm-overlay);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}.dialog{box-sizing:border-box;width:min(100%,720px);max-height:calc(100dvh - 32px);overflow:auto;padding:20px;border:0;border-radius:18px;background:var(--pm-surface);color:var(--pm-text);box-shadow:0 20px 60px var(--pm-shadow)}.dialog h2{margin:0 0 16px;font-size:20px}.dialog p{color:var(--pm-muted);line-height:1.6}.dialog-actions{display:flex;justify-content:flex-end;gap:6px;margin-top:14px}.dialog button{height:40px;padding:0 14px;border:0;border-radius:10px;background:transparent;color:var(--pm-text);cursor:pointer}.dialog button:hover{background:var(--pm-hover)}.info-hero{display:flex;align-items:center;gap:13px;margin-bottom:14px;padding:14px;border:0;border-radius:14px;background:#2dd4bf0d}.info-mark{display:grid;place-items:center;flex:0 0 38px;width:38px;height:38px;border-radius:12px;background:var(--pm-accent-strong);color:#fff;font:800 20px/1 ui-monospace,monospace}.game-name{min-width:0;margin:0!important;color:var(--pm-text)!important;font-size:17px;font-weight:750;overflow-wrap:anywhere}.info-hero,.info-grid,.game-name,.info-label,.info-value{cursor:text;user-select:text;-webkit-user-select:text}.info-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1px;margin:0;overflow:hidden;border:0;border-radius:14px;background:var(--pm-divider)}.info-item{min-width:0;padding:12px 13px;background:var(--pm-surface-strong)}.info-item.wide{grid-column:1/-1}.info-label{display:block;margin:0 0 5px;color:var(--pm-muted);font-size:11px;font-weight:700;letter-spacing:.05em}.info-value{display:block;margin:0;color:var(--pm-text);font:650 13px/1.45 system-ui,"Microsoft YaHei",sans-serif;overflow-wrap:anywhere}.info-value.code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;letter-spacing:.01em}.logs-output{box-sizing:border-box;height:min(58dvh,480px);margin:0;padding:12px;overflow:auto;border:0;border-radius:12px;background:var(--pm-log);color:var(--pm-text);cursor:text;user-select:text;-webkit-user-select:text;white-space:pre-wrap;word-break:break-word;font:12px/1.55 ui-monospace,SFMono-Regular,Consolas,monospace}.performance-panel{position:fixed;left:max(12px,env(safe-area-inset-left));top:max(12px,env(safe-area-inset-top));z-index:2147483647;display:flex;gap:10px;padding:0;border:0;background:transparent;color:#fff;text-shadow:0 1px 3px #000,0 0 8px #000;font:750 12px/1 ui-monospace,SFMono-Regular,Consolas,monospace;pointer-events:none}
      .game-tags-wrap{display:flex;align-items:center;gap:10px;min-width:0;margin:0 0 14px}.game-tags-label{flex:0 0 auto;color:var(--pm-muted);font-size:12px;font-weight:750}.game-tags{display:flex;flex:1 1 auto;gap:7px;min-width:0;overflow-x:auto;overscroll-behavior-x:contain;padding:1px 1px 5px;scrollbar-width:thin;-webkit-overflow-scrolling:touch}.game-tag{display:inline-flex;align-items:center;flex:0 0 auto;gap:5px;max-width:260px;padding:6px 10px;border:1px solid var(--pm-border);border-radius:999px;background:#2dd4bf12;color:var(--pm-text);font:650 12px/1.2 system-ui,"Microsoft YaHei",sans-serif;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.game-tag-mark{color:var(--pm-accent);font:800 12px/1 ui-monospace,monospace}
      [hidden]{display:none!important}@keyframes menu-breathe{0%,100%{opacity:.35;transform:scale(.96)}50%{opacity:.85;transform:scale(1.04)}}@keyframes menu-arrive{from{opacity:0;transform:translateY(10px) scale(.98)}to{opacity:1;transform:none}}@media(prefers-reduced-motion:reduce){.menu-fab,.action{transition:none}.menu-fab::before{animation:none;opacity:.55}.sidebar{animation:none}}@media(max-width:440px){.sidebar{border-radius:18px}.actions-list,.info-grid{grid-template-columns:1fr}.action{min-height:50px}}
    </style>
    ${menuButtonMarkup}
    <div class="layer" hidden><div class="scrim" aria-hidden="true"></div><aside class="sidebar" role="dialog" aria-modal="true"><header class="head"><span class="brand" aria-hidden="true">P</span><h2 class="title"></h2></header><nav class="actions-list">
      <button class="action continue" data-action="continue" type="button"><span class="icon" aria-hidden="true">▶</span><span></span></button>
      <button class="action restart" data-action="restart" type="button"><span class="icon" aria-hidden="true">↻</span><span></span></button>
      <button class="action share" data-action="share" type="button"><span class="icon" aria-hidden="true">▦</span><span></span></button>
      <button class="action logs" data-action="logs" type="button"><span class="icon" aria-hidden="true">≡</span><span></span></button>
      <button class="action enter-fullscreen" data-action="enter-fullscreen" type="button"><span class="icon" aria-hidden="true">⛶</span><span></span></button>
      <button class="action exit-fullscreen" data-action="exit-fullscreen" type="button"><span class="icon" aria-hidden="true">⊡</span><span></span></button>
      <button class="action info" data-action="info" type="button"><span class="icon" aria-hidden="true">ⓘ</span><span></span></button>
      <button class="action performance" data-action="performance" type="button" aria-pressed="false"><span class="icon" aria-hidden="true">◴</span><span></span></button>
    </nav><footer class="foot"><button class="action exit" data-action="exit" type="button"><span class="icon" aria-hidden="true">↩</span><span></span></button></footer></aside></div>
    <div class="dialog-layer info-layer" role="dialog" aria-modal="true" hidden><section class="dialog"><h2 class="info-title"></h2><div class="info-hero"><span class="info-mark" aria-hidden="true">i</span><p class="game-name"></p></div><div class="game-tags-wrap" hidden><span class="game-tags-label"></span><div class="game-tags" role="list"></div></div><dl class="game-detail info-grid"></dl><div class="dialog-actions"><button class="info-edit" type="button" hidden></button><button class="info-close" type="button"></button></div></section></div>
    <div class="dialog-layer logs-layer" role="dialog" aria-modal="true" hidden><section class="dialog"><h2 class="logs-title"></h2><pre class="logs-output" tabindex="0"></pre><div class="dialog-actions"><button class="logs-copy" type="button"></button><button class="logs-clear" type="button"></button><button class="logs-close" type="button"></button></div></section></div>
    <div class="performance-panel" hidden><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>`;
    global.document.body.appendChild(host);
    const query = (selector) => root.querySelector(selector);
    appFallbackUi = {
      host,
      root,
      menuButton: query(".menu-fab"),
      layer: query(".layer"),
      sidebar: query(".sidebar"),
      scrim: query(".scrim"),
      title: query(".title"),
      continueButton: query(".continue"),
      restart: query(".restart"),
      share: query(".share"),
      logs: query(".logs"),
      enterFullscreen: query(".enter-fullscreen"),
      exitFullscreen: query(".exit-fullscreen"),
      info: query(".info"),
      performanceButton: query(".performance"),
      exit: query(".exit"),
      performancePanel: query(".performance-panel"),
      fps: query(".fps"),
      latency: query(".latency"),
      infoLayer: query(".info-layer"),
      infoTitle: query(".info-title"),
      gameName: query(".game-name"),
      gameTagsWrap: query(".game-tags-wrap"),
      gameTagsLabel: query(".game-tags-label"),
      gameTags: query(".game-tags"),
      gameDetail: query(".game-detail"),
      infoEdit: query(".info-edit"),
      infoClose: query(".info-close"),
      logsLayer: query(".logs-layer"),
      logsTitle: query(".logs-title"),
      logsOutput: query(".logs-output"),
      logsCopy: query(".logs-copy"),
      logsClear: query(".logs-clear"),
      logsClose: query(".logs-close"),
    };
    const ui = appFallbackUi;
    if (ui.menuButton) {
      ui.menuButton.onclick = () => showAppGameSidebar();
    }
    ui.continueButton.onclick = () => hideAppGameSidebar();
    ui.scrim.onclick = () => hideAppGameSidebar();
    ui.restart.onclick = () => void restartAppUiGame();
    ui.share.onclick = () => {
      void openAppSharePanel().catch((error) => {
        global.console?.warn?.("Playmesh 分享界面未能打开", error);
      });
    };
    ui.logs.onclick = () => void openAppUiRuntimeLogs();
    ui.enterFullscreen.onclick = () => {
      void setAppUiFullscreen(true);
    };
    ui.exitFullscreen.onclick = () => {
      void setAppUiFullscreen(false);
    };
    ui.info.onclick = () => void openAppUiGameInfo();
    ui.performanceButton.onclick = () => {
      setAppUiPerformanceVisible(!appUiPerformanceVisible);
    };
    ui.exit.onclick = () => {
      hideAppGameSidebar(false);
      void exitAppUiGame();
    };
    ui.infoClose.onclick = () => {
      ui.infoLayer.hidden = true;
      if (!ui.layer.hidden) {
        ui.info.focus?.({ preventScroll: true });
      } else {
        restoreAppUiReturnFocus();
      }
    };
    ui.infoEdit.onclick = async () => {
      ui.infoLayer.hidden = true;
      try {
        await appUiRuntimeAdapter?.editNickname?.();
      } catch (error) {
        global.console?.warn?.("Playmesh 浏览器昵称修改失败", error);
      }
      if (!ui.layer.hidden) void openAppUiGameInfo();
      else restoreAppUiReturnFocus();
    };
    ui.logsClear.onclick = () => {
      appUiConsoleLogs.length = 0;
      renderAppUiLogs();
    };
    ui.logsCopy.onclick = async () => {
      try {
        const copied = await copyAppUiRuntimeLogs();
        if (!copied) throw new Error("当前环境不支持复制");
        setAppUiControlLabel(ui.logsCopy, "logs.copied");
        global.setTimeout?.(() => {
          setAppUiControlLabel(ui.logsCopy, "logs.copy");
        }, 1200);
      } catch (error) {
        global.console?.warn?.("Playmesh 运行日志复制失败", error);
      }
    };
    ui.logsClose.onclick = () => {
      ui.logsLayer.hidden = true;
      if (!ui.layer.hidden) {
        ui.logs.focus?.({ preventScroll: true });
      } else {
        restoreAppUiReturnFocus();
      }
    };
    const sidebarControls = () => [
      ui.continueButton,
      ui.restart,
      ui.share,
      ui.logs,
      ui.enterFullscreen,
      ui.exitFullscreen,
      ui.info,
      ui.performanceButton,
      ui.exit,
    ].filter((control) =>
      control &&
      !control.hidden &&
      !control.disabled
    );
    const moveSidebarFocus = (direction) => {
      const controls = sidebarControls();
      if (controls.length === 0) return false;
      const activeElement = root.activeElement || global.document?.activeElement;
      const activeIndex = controls.indexOf(activeElement);
      const exitIndex = controls.indexOf(ui.exit);
      const gridLength = exitIndex < 0 ? controls.length : exitIndex;
      const columns =
        global.matchMedia?.("(max-width: 440px)")?.matches === true ||
        (Number.isFinite(global.innerWidth) && global.innerWidth <= 440)
          ? 1
          : 2;
      let nextIndex = activeIndex < 0 ? 0 : activeIndex;
      if (direction === "first") {
        nextIndex = 0;
      } else if (direction === "last") {
        nextIndex = controls.length - 1;
      } else if (activeIndex === exitIndex && exitIndex >= 0) {
        if (direction === "up" && gridLength > 0) {
          nextIndex = gridLength - 1;
        }
      } else if (activeIndex >= 0 && activeIndex < gridLength) {
        const column = activeIndex % columns;
        if (direction === "left" && column > 0) {
          nextIndex = activeIndex - 1;
        } else if (
          direction === "right" &&
          column < columns - 1 &&
          activeIndex + 1 < gridLength
        ) {
          nextIndex = activeIndex + 1;
        } else if (direction === "up" && activeIndex - columns >= 0) {
          nextIndex = activeIndex - columns;
        } else if (direction === "down") {
          nextIndex = activeIndex + columns < gridLength
            ? activeIndex + columns
            : exitIndex >= 0
              ? exitIndex
              : activeIndex;
        }
      }
      controls[nextIndex].focus?.({ preventScroll: true });
      return true;
    };
    root.addEventListener("keydown", (event) => {
      if (!ui.layer.hidden && ui.logsLayer.hidden && ui.infoLayer.hidden) {
        let direction = null;
        if (event.key === "ArrowDown") direction = "down";
        else if (event.key === "ArrowUp") direction = "up";
        else if (event.key === "ArrowLeft") direction = "left";
        else if (event.key === "ArrowRight") direction = "right";
        else if (event.key === "Home") direction = "first";
        else if (event.key === "End") direction = "last";
        if (direction !== null && moveSidebarFocus(direction)) {
          event.preventDefault?.();
          event.stopPropagation?.();
          event.stopImmediatePropagation?.();
          return;
        }
      }
      if (event.key !== "Escape" && event.key !== "BrowserBack" &&
          event.key !== "GoBack") {
        return;
      }
      event.preventDefault?.();
      event.stopPropagation?.();
      if (!ui.logsLayer.hidden) ui.logsClose.onclick();
      else if (!ui.infoLayer.hidden) ui.infoClose.onclick();
      else if (!ui.layer.hidden) hideAppGameSidebar();
    });
    installAppMenuButtonDrag(ui);
    refreshAppFallbackUi();
    refreshAppUiPerformance();
    return ui;
  }

  function setAppUiControlLabel(element, key, updateVisibleText = true) {
    if (!element) return;
    const label = appUiText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    if (!updateVisibleText) return;
    const visibleText = element.querySelector?.("span:last-child");
    if (visibleText) visibleText.textContent = label;
    else if (element.tagName === "BUTTON") element.textContent = label;
  }

  function refreshAppFallbackUi() {
    const ui = appFallbackUi;
    if (!ui) return;
    ui.host.setAttribute?.("lang", appUiConfiguration?.locale || "zh-CN");
    ui.host.setAttribute?.("data-theme", appUiConfiguration?.theme || "dark");
    ui.title.textContent = appUiText("sidebar.title");
    setAppUiControlLabel(ui.menuButton, "sidebar.title", false);
    setAppUiControlLabel(ui.continueButton, "sidebar.continue");
    setAppUiControlLabel(ui.restart, "sidebar.restart");
    setAppUiControlLabel(ui.share, "sidebar.share");
    setAppUiControlLabel(ui.logs, "sidebar.logs");
    setAppUiControlLabel(
      ui.enterFullscreen,
      "sidebar.enter_fullscreen",
    );
    setAppUiControlLabel(
      ui.exitFullscreen,
      "sidebar.exit_fullscreen",
    );
    setAppUiControlLabel(ui.info, "sidebar.info");
    setAppUiControlLabel(
      ui.performanceButton,
      "sidebar.performance",
    );
    setAppUiControlLabel(ui.exit, "sidebar.exit");
    ui.share.hidden = !appUiActionEnabled("share", false);
    ui.restart.hidden = !appUiActionEnabled("restart");
    ui.logs.hidden = !appUiActionEnabled("logs");
    ui.enterFullscreen.hidden = !appUiActionEnabled("fullscreen");
    ui.exitFullscreen.hidden = !appUiActionEnabled("fullscreen");
    ui.info.hidden =
      !appUiActionEnabled("info") ||
      typeof appUiRuntimeAdapter?.getInfo !== "function";
    ui.performanceButton.hidden = !appUiActionEnabled("performance");
    ui.exit.hidden = !appUiActionEnabled("exit");
    const browser = bootstrap?.available !== true;
    if (ui.menuButton) {
      ui.menuButton.hidden =
        !browser ||
        !appUiOptions.floatingButton ||
        !ui.layer.hidden;
    }
    ui.infoTitle.textContent = appUiText("info.title");
    ui.logsTitle.textContent = appUiText("logs.title");
    setAppUiControlLabel(ui.logsCopy, "logs.copy");
    setAppUiControlLabel(ui.infoEdit, "nickname.edit_action");
    setAppUiControlLabel(ui.infoClose, "common.close");
    setAppUiControlLabel(ui.logsClear, "common.clear");
    setAppUiControlLabel(ui.logsClose, "common.close");
  }

  async function showAppGameSidebar() {
    if (!appUiOptions.fallbackUi) return false;
    if (appUiGameMenuOpen && appFallbackUi &&
        !appFallbackUi.layer.hidden) {
      appFallbackUi.continueButton.focus?.({ preventScroll: true });
      return true;
    }
    captureAppUiReturnFocus();
    const ui = await ensureAppFallbackUi();
    if (!ui) {
      clearAppUiReturnFocus();
      return false;
    }
    ui.infoLayer.hidden = true;
    ui.logsLayer.hidden = true;
    ui.layer.hidden = false;
    if (ui.menuButton) ui.menuButton.hidden = true;
    ui.continueButton.focus?.({ preventScroll: true });
    setAppUiGameMenuOpen(true);
    return true;
  }

  function hideAppGameSidebar(restoreFocus = true) {
    const ui = appFallbackUi;
    if (!ui) {
      setAppUiGameMenuOpen(false);
      return Promise.resolve(false);
    }
    ui.layer.hidden = true;
    refreshAppFallbackUi();
    if (restoreFocus) restoreAppUiReturnFocus();
    setAppUiGameMenuOpen(false);
    return Promise.resolve(true);
  }

  function toggleAppGameSidebar() {
    if (appFallbackUi && !appFallbackUi.layer.hidden) {
      return hideAppGameSidebar();
    }
    return showAppGameSidebar();
  }

  function handleAppUiNativeBack() {
    const ui = appFallbackUi;
    if (ui && !ui.logsLayer.hidden) {
      ui.logsClose.onclick();
      return true;
    }
    if (ui && !ui.infoLayer.hidden) {
      ui.infoClose.onclick();
      return true;
    }
    if (ui && !ui.layer.hidden) {
      void hideAppGameSidebar();
      return true;
    }
    if (!appUiOptions.fallbackUi || appUiSystemMenuTriggersDisabled) {
      return false;
    }
    void showAppGameSidebar();
    return true;
  }

  function openAppSharePanel() {
    if (!global.navigator?.userActivation?.isActive) {
      return Promise.reject(appUiError(
        "user_activation_required",
        "打开分享界面需要当前用户操作",
      ));
    }
    if (bootstrap?.available !== true) {
      return Promise.reject(appUiError(
        "ui_unavailable",
        "当前浏览器不提供 Authority 分享功能",
      ));
    }
    captureAppUiReturnFocus();
    return request("app.ui.openSharePanel", { userActivation: true })
      .catch((error) => {
        clearAppUiReturnFocus();
        throw error;
      });
  }

  async function setAppUiFullscreen(enabled) {
    try {
      if (bootstrap?.available === true) {
        await publicAppApi.device.setFullscreen(enabled);
      } else if (enabled) {
        await global.document?.documentElement?.requestFullscreen?.();
      } else if (global.document?.fullscreenElement) {
        await global.document.exitFullscreen?.();
      }
    } catch (error) {
      global.console?.warn?.("Playmesh 全屏切换失败", error);
    }
  }

  async function exitAppUiGame() {
    if (bootstrap?.available === true) {
      return request("app.game.exit");
    }
    try {
      if (global.history?.length > 1) {
        global.history.back();
        return;
      }
      global.close?.();
      global.setTimeout?.(() => {
        if (!global.closed) global.location?.replace?.("about:blank");
      }, 0);
    } catch (error) {
      global.console?.warn?.("浏览器无法退出当前游戏", error);
    }
  }

  function isAppUiOwnedKeyboardEvent(event) {
    const hostId = "playmesh-app-platform-ui";
    const target = event?.target;
    if (target?.id === hostId ||
        target?.getRootNode?.()?.host?.id === hostId) {
      return true;
    }
    const path = event?.composedPath?.();
    return Array.isArray(path) &&
      path.some((node) => node?.id === hostId);
  }

  function isAppUiEditableTarget(target) {
    if (!target || typeof target !== "object") return false;
    const tag = String(target.tagName || "").toUpperCase();
    return target.isContentEditable === true ||
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT";
  }

  function installAppUiKeyboardInterception() {
    if (appUiSystemMenuTriggersDisabled ||
        appUiSystemMenuTriggerDisposer ||
        !global.addEventListener) {
      return;
    }
    const handler = (event) => {
      if (event?.defaultPrevented ||
          event?.repeat ||
          isAppUiOwnedKeyboardEvent(event) ||
          isAppUiEditableTarget(event?.target)) {
        return;
      }
      const key = event?.key;
      const code = event?.keyCode;
      const menu =
        key === "F10" ||
        key === "ContextMenu" ||
        key === "Menu" ||
        code === 82 ||
        code === 121 ||
        code === 93;
      const back =
        key === "Escape" ||
        key === "Back" ||
        key === "BrowserBack" ||
        key === "GoBack" ||
        key === "XF86Back" ||
        code === 27 ||
        code === 4 ||
        code === 166 ||
        code === 461 ||
        code === 10009;
      if (!menu && !back) return;
      if (!appUiOptions.fallbackUi) return;
      event.preventDefault?.();
      event.stopPropagation?.();
      event.stopImmediatePropagation?.();
      if (!appUiConfiguration?.messages) {
        // 原生 bootstrap 返回前先记录切换意图，避免 UI 为抢首键引入硬编码文案。
        appUiTogglePending = !appUiTogglePending;
        return;
      }
      void toggleAppGameSidebar();
    };
    global.addEventListener("keydown", handler, true);
    const dispose = () => {
      global.removeEventListener?.("keydown", handler, true);
      if (appUiSystemMenuTriggerDisposer === dispose) {
        appUiSystemMenuTriggerDisposer = null;
      }
    };
    appUiSystemMenuTriggerDisposer = dispose;
  }

  function disableAppUiSystemMenuTriggers() {
    if (!appReadyCompleted) {
      throw appUiError(
        "app_not_ready",
        "请先等待 playmesh.app.ready",
      );
    }
    if (arguments.length !== 0) {
      throw appUiError(
        "invalid_argument",
        "disableSystemMenuTriggers 不接受参数",
      );
    }
    if (appUiSystemMenuTriggersDisabled) return;
    appUiSystemMenuTriggersDisabled = true;
    appUiTogglePending = false;
    appUiSystemMenuTriggerDisposer?.();
  }

  function initializeAppPlatformUi(configuration) {
    appUiConfiguration = resolveAppUiConfiguration(configuration);
    updateAppRuntimeLocale(appUiConfiguration);
    installAppUiConsoleCapture();
    installAppUiKeyboardInterception();
    if (appUiOptions.fallbackUi) scheduleAppFallbackUi();
    refreshAppFallbackUi();
    if (appUiTogglePending && appUiConfiguration?.messages) {
      appUiTogglePending = false;
      void toggleAppGameSidebar();
    }
  }


  function appLanError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function requireAppLanReady() {
    if (!appReadyCompleted) {
      throw appLanError("app_not_ready", "请先等待 playmesh.app.ready");
    }
  }

  function requireAppLanArguments(args, expected, method) {
    if (args.length !== expected) {
      throw appLanError(
        "invalid_argument",
        `${method} 参数数量无效`,
      );
    }
  }

  function requireAppLanAvailable() {
    if (bootstrap?.available !== true) {
      throw appLanError(
        "app_unavailable",
        "当前页面不在 Playmesh App WebView 中",
      );
    }
  }

  function freezeAppLanGame(value) {
    if (!value || typeof value !== "object" ||
        typeof value.instanceId !== "string" || !value.instanceId ||
        typeof value.gameId !== "string" || !value.gameId ||
        typeof value.name !== "string" || !value.name ||
        typeof value.host !== "string" || !value.host) {
      throw appLanError(
        "discovery_unavailable",
        "局域网发现结果无效",
      );
    }
    const instanceId = value.instanceId;
    return Object.freeze({
      instanceId,
      gameId: value.gameId,
      name: value.name,
      host: value.host,
      join: async function () {
        requireAppLanReady();
        requireAppLanArguments(arguments, 0, "PlaymeshLanGame.join");
        requireAppLanAvailable();
        await request("app.lan.joinDiscovered", {
          instanceId,
          userActivation: true,
        });
      },
    });
  }

  function freezeAppLanShareLink(value) {
    if (!value || typeof value !== "object" ||
        typeof value.url !== "string" || !value.url ||
        (value.type !== "lan" && value.type !== "wan") ||
        typeof value.img !== "string" ||
        !value.img.startsWith("data:image/png;base64,")) {
      throw appLanError("share_unavailable", "分享链接结果无效");
    }
    return Object.freeze({
      url: value.url,
      type: value.type,
      img: value.img,
    });
  }

  const appLanApi = Object.freeze({
    async discoverGames() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "discoverGames");
      requireAppLanAvailable();
      const result = await request("app.lan.discover");
      if (!Array.isArray(result)) {
        throw appLanError(
          "discovery_unavailable",
          "局域网发现结果无效",
        );
      }
      return Object.freeze(result.map(freezeAppLanGame));
    },
    async joinByLink(invitationUrl) {
      requireAppLanReady();
      requireAppLanArguments(arguments, 1, "joinByLink");
      if (typeof invitationUrl !== "string" || !invitationUrl.trim()) {
        throw appLanError("invalid_argument", "invitationUrl 必须是非空字符串");
      }
      requireAppLanAvailable();
      await request("app.lan.joinByLink", {
        invitationUrl,
        userActivation: true,
      });
    },
    async scanQrAndJoin() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "scanQrAndJoin");
      requireAppLanAvailable();
      await request("app.lan.scanQr", { userActivation: true });
    },
    async setPublished() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "setPublished");
      requireAppLanAvailable();
      await request("app.lan.setPublished");
    },
    async getShareLinks() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "getShareLinks");
      requireAppLanAvailable();
      const result = await request("app.lan.getShareLinks");
      if (!Array.isArray(result)) {
        throw appLanError("share_unavailable", "分享链接结果无效");
      }
      return Object.freeze(result.map(freezeAppLanShareLink));
    },
  });


  const publicAppApi = {
    version: PLAYMESH_APP_SDK_VERSION,
    isAvailable() {
      return bootstrap?.available === true;
    },
    identity: {
      getCurrent() {
        return bootstrap ? clone(bootstrap.identity) : null;
      },
    },
    runtime: Object.freeze({
      getLocale() {
        if (!appRuntimeLocale) {
          throw new Error(
            "playmesh.app.runtime.getLocale requires await playmesh.app.ready",
          );
        }
        return appRuntimeLocale;
      },
    }),
    performance: Object.freeze({
      getFps() {
        return appPerformanceFps;
      },
      onFps(callback) {
        return subscribeAppPerformance(
          appPerformanceFpsListeners,
          callback,
          appPerformanceFps,
        );
      },
      getLatency() {
        return appPerformanceLatency;
      },
      getLatencyDiagnostics() {
        return clone(appPerformanceLatencyDiagnostics);
      },
      onLatency(callback) {
        return subscribeAppPerformance(
          appPerformanceLatencyListeners,
          callback,
          appPerformanceLatency,
        );
      },
      setVisible(visible) {
        setAppUiPerformanceVisible(visible === true);
      },
      reportFrame(timestamp) {
        return reportAppPerformanceFrame(timestamp);
      },
    }),
    capabilities: {
      getRegistry() {
        return bootstrap ? clone(bootstrap.capabilityRegistry || []) : [];
      },
      getAvailable() {
        return bootstrap ? [...(bootstrap.device?.capabilities || [])] : [];
      },
      getDeclared() {
        return bootstrap ? [...(bootstrap.device?.declaredCapabilities || [])] : [];
      },
      create: createCapability,
    },
    media: {
      open: openAppMedia,
    },
    storage: appStorageApi,
    lan: appLanApi,
    device: {
      getPlatform() {
        return bootstrap?.device?.platform || null;
      },
      setFullscreen(enabled, orientation) {
        if (orientation !== undefined &&
            orientation !== "landscape" &&
            orientation !== "portrait") {
          return Promise.reject(new TypeError("orientation 必须是 landscape 或 portrait"));
        }
        if (enabled !== true && orientation !== undefined) {
          return Promise.reject(new TypeError("退出全屏时不能声明 orientation"));
        }
        return request("app.device.fullscreen", {
          enabled: enabled === true,
          ...(orientation === undefined ? {} : { orientation }),
        });
      },
      onInput(listener) {
        if (typeof listener !== "function") throw new TypeError("listener 必须是函数");
        inputListeners.add(listener);
        return () => inputListeners.delete(listener);
      },
    },
    ui: {
      disableSystemMenuTriggers() {
        return disableAppUiSystemMenuTriggers.apply(null, arguments);
      },
      initializeBrowser() {
        return initializeBrowserAppUi();
      },
      configure(options) {
        return configureAppUi(options);
      },
      restartGame() {
        return restartAppUiGame();
      },
      openSharePanel() {
        return openAppSharePanel();
      },
      showGameSidebar() {
        return showAppGameSidebar();
      },
      onGameMenuOpen(callback) {
        return onAppGameMenuOpen(callback);
      },
      onGameMenuClose(callback) {
        return onAppGameMenuClose(callback);
      },
      openRuntimeLogs() {
        return openAppUiRuntimeLogs();
      },
      enterFullscreen(orientation) {
        if (bootstrap?.available === true) {
          return publicAppApi.device.setFullscreen(true, orientation);
        }
        return setAppUiFullscreen(true);
      },
      exitFullscreen() {
        return setAppUiFullscreen(false);
      },
      openGameInfo() {
        return openAppUiGameInfo();
      },
      setPerformanceVisible(visible) {
        return setAppUiPerformanceVisible(visible);
      },
      togglePerformance() {
        return setAppUiPerformanceVisible(!appUiPerformanceVisible);
      },
      exitGame() {
        return exitAppUiGame();
      },
    },
  };

  // ready 对外只暴露一个稳定只读视图；远程 App 的运行时能力配置会更新内部
  // bootstrap，但不会替换开发者已经取得的 ready 结果引用。
  const appBootstrapResult = Object.freeze({
    get available() {
      return bootstrap?.available === true;
    },
    get sdkVersion() {
      return bootstrap?.sdkVersion || PLAYMESH_APP_SDK_VERSION;
    },
    get identity() {
      return clone(bootstrap?.identity ?? null);
    },
    get runtime() {
      return clone(bootstrap?.runtime ?? null);
    },
    get capabilityRegistry() {
      return clone(bootstrap?.capabilityRegistry || []);
    },
    get device() {
      return clone(bootstrap?.device || {
        platform: "browser",
        capabilities: [],
        declaredCapabilities: [],
      });
    },
  });

  let appAutoApproveCapabilities = false;
  const appInternalRuntime = Object.freeze({
    publicApi: publicAppApi,
    receive,
    requestExit() {
      return exitAppUiGame();
    },
    restoreGameContentFocus() {
      restoreAppUiReturnFocus();
    },
    handleNativeBack() {
      return handleAppUiNativeBack();
    },
    syncAvatar(sessionId, credentialToken) {
      return request("app.identity.syncAvatar", { sessionId, credentialToken });
    },
    updateIdentityNickname(nickname, sessionId, credentialToken, playerId) {
      return request("app.identity.updateNickname", {
        nickname,
        ...(sessionId && credentialToken && playerId
          ? { sessionId, credentialToken, playerId }
          : {}),
      }).then((result) => {
        if (result?.identity) {
          bootstrap = { ...bootstrap, identity: clone(result.identity) };
        }
        return clone(result);
      });
    },
    confirmCapabilities() {
      return request("app.capabilities.confirm");
    },
    shouldAutoApproveCapabilities() {
      return appAutoApproveCapabilities;
    },
    configureRuntimeGame(declaration) {
      return request("app.game.configure", {
        declaredCapabilities: [
          ...(declaration?.requiredCapabilities || []),
        ],
      }).then((environment) => {
        bootstrap = {
          ...bootstrap,
          capabilityRegistry: clone(environment?.capabilityRegistry || []),
          device: clone(environment?.device || bootstrap?.device),
        };
        return appBootstrapResult;
      });
    },
    configureRuntimePerformance(context) {
      configureAppRuntimePerformance(context);
    },
    recordRuntimeLatencyPong(payload) {
      recordAppRuntimeLatencyPong(payload);
    },
    registerRuntimeUi(adapter) {
      registerAppUiRuntimeAdapter(adapter);
    },
    refreshRuntimeUi() {
      refreshAppFallbackUi();
      refreshAppUiPerformance();
    },
    configurePlatformUi(configuration) {
      initializeAppPlatformUi({
        ...(configuration || {}),
        actions: appUiConfiguration?.actions,
      });
    },
    takePlatformUiConfiguration() {
      const configuration = appPlatformUiConfiguration;
      appPlatformUiConfiguration = null;
      return clone(configuration);
    },
  });
  Object.defineProperty(global, PLAYMESH_APP_INTERNAL_KEY, {
    value: appInternalRuntime,
    configurable: true,
    enumerable: false,
    writable: false,
  });
  installAppUiConsoleCapture();
  global.console?.info?.(
    `Playmesh App SDK 注入成功 ${JSON.stringify({
      version: PLAYMESH_APP_SDK_VERSION,
    })}`,
  );
  if (global.chrome?.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  const runtimeDeclaration = global.__PLAYMESH_BROWSER__;
  const runtimePlatformUi = runtimeDeclaration?._playmeshPlatformUi;
  installAppUiKeyboardInterception();
  if (runtimePlatformUi) initializeAppPlatformUi(runtimePlatformUi);
  let appInputTakeoverRequested = false;
  function requestAppInputTakeover() {
    if (appInputTakeoverRequested || bootstrap?.available !== true) return;
    appInputTakeoverRequested = true;
    void request("app.input.takeover").catch(() => {
      appInputTakeoverRequested = false;
    });
  }
  const appReady = nativeSender() === null
    ? Promise.resolve().then(() => {
      // 普通浏览器没有原生 Bridge，属于预期降级；存在 Bridge 时的任何失败必须 reject。
      bootstrap = {
        available: false,
        sdkVersion: PLAYMESH_APP_SDK_VERSION,
        identity: null,
        runtime: null,
        capabilityRegistry: [],
        device: {
          platform: "browser",
          capabilities: [],
          declaredCapabilities: [],
        },
      };
      appAutoApproveCapabilities = false;
      appPlatformUiConfiguration = null;
      initializeAppPlatformUi(runtimePlatformUi);
      global.console?.info?.("Playmesh App SDK 就绪");
      appReadyCompleted = true;
      return appBootstrapResult;
    })
    : request("app.bootstrap").then((result) => {
      const privateUi = result?._playmeshPlatformUi;
      configureAppStorageSync(result?._playmeshAppStorageSync);
      appAutoApproveCapabilities =
        result?._playmeshAutoApproveCapabilities === true;
      appPlatformUiConfiguration =
        privateUi && typeof privateUi === "object" ? clone(privateUi) : null;
      bootstrap = result && typeof result === "object"
        ? { ...result }
        : result;
      if (bootstrap && typeof bootstrap === "object") {
        delete bootstrap._playmeshPlatformUi;
        delete bootstrap._playmeshAppStorageSync;
        delete bootstrap._playmeshAutoApproveCapabilities;
      }
      initializeAppPlatformUi(privateUi);
      requestAppInputTakeover();
      global.console?.info?.("Playmesh App SDK 就绪");
      appReadyCompleted = true;
      return appBootstrapResult;
    });
  Object.defineProperty(publicAppApi, "ready", {
    value: appReady,
    enumerable: true,
    writable: false,
  });
  Object.freeze(publicAppApi);
})(window);
