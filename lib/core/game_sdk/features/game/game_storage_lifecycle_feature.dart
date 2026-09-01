part of '../../sdk_feature_registry.dart';

const gameStorageLifecycleSdkSource = SdkSourceFragment(
  id: 'game.storage-lifecycle',
  target: SdkSourceTarget.game,
  order: 70,
  typeScript: r'''  const standardStorageRevisions = new Map();
  const standardStorageBucketOperations = new Map();
  let nicknameUpdateTail = Promise.resolve();
  const main = {
    version: PLAYMESH_SDK_VERSION,
    ready: null,
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
        const run = () => {
          if (appSdk.isAvailable()) {
            return updateAppNickname(nickname);
          }
          if (!global.__PLAYMESH_BROWSER__) {
            return updateHostNickname(nickname);
          }
          if (global.__PLAYMESH_BROWSER__.mode === "solo") {
            throw new Error("单机分享没有玩家昵称");
          }
          return updateBrowserNickname(nickname);
        };
        const operation = nicknameUpdateTail.then(run, run);
        nicknameUpdateTail = operation.catch(() => {});
        return operation;
      },
    },
    game: {
      submitAction(action, options) {
        return post("game.submitAction", encodeAuthorityAction(action, options));
      },
      onMessage(callback) {
        return subscribe(messageListeners, callback);
      },
      onEvent(callback) {
        return subscribe(messageListeners, callback);
      },
    },
    authority: {
      defaultNamespace: DEFAULT_AUTHORITY_SERVICE_NAMESPACE,
      onService: registerAuthorityService,
    },
    rpc: {
      request: requestRpc,
      requestStream: requestRpcStream,
      onRequest: registerRpcRequestHandler,
      onStreamRequest: registerRpcStreamRequestHandler,
    },
    binary: {
      authorityPlayerId: "authority",
      async createChannel(options) {
        await main.ready;
        if (!main.session.isAuthority()) {
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
        await main.ready;
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
    storage: {
      getBucket(bucket) {
        validateSynchronousStorageBucketName(bucket);
        return {
          getData(key) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            return storageCall("storage.get", bucket, key);
          },
          setData(key, value) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            JSON.stringify(value);
            return storageCall("storage.set", bucket, key, value);
          },
          getDataSync(key) {
            validateSynchronousStorageKey(key);
            return storageCallSync("sync.get", bucket, key);
          },
          setDataSync(key, value) {
            validateSynchronousStorageKey(key);
            JSON.stringify(value);
            storageCallSync("sync.set", bucket, key, value);
          },
          removeData(key) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            return storageCall("storage.remove", bucket, key);
          },
          clearData() {
            validateStorageName(bucket, "bucket");
            return storageCall("storage.clear", bucket);
          },
          upload(file, options) {
            validateStorageName(bucket, "bucket");
            return storageUpload(bucket, file, options);
          },
        };
      },
    },
    db: createDatabaseApi(),
  };

  const PLAYMESH_MAIN_INTERNAL_KEY =
    Symbol.for("playmesh.main.internal.v1");
  Object.defineProperty(global, PLAYMESH_MAIN_INTERNAL_KEY, {
    value: Object.freeze({ receive }),
    configurable: true,
    enumerable: false,
    writable: false,
  });
  appInternalRuntime.registerWebRTCSignalingEndpointProvider?.(
    getWebRTCSignalingEndpoint,
  );
  registerAppPlatformUiRuntime();
  if (global.chrome && global.chrome.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  global.addEventListener?.("pagehide", () => {
    const refreshing = global.__playmeshDevelopmentRefreshRequested === true;
    markRuntimeExited(refreshing ? "开发游戏页面正在重启" : "游戏页面已退出");
  });
  let readyAppBootstrap = null;
  main.ready = (async () => {
    const appBootstrap = await appSdk.ready;
    readyAppBootstrap = appBootstrap;
    const runtimeGameDeclaration = global.__PLAYMESH_BROWSER__;
    if (runtimeGameDeclaration &&
        appSdk.isAvailable() &&
        typeof appInternalRuntime.configureRuntimeGame === "function") {
      await appInternalRuntime.configureRuntimeGame({
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
  })();
  const ready = main.ready.then(
    (mainBootstrap) => Object.freeze({
      main: mainBootstrap,
      app: readyAppBootstrap,
    }),
  );
  global.playmesh = Object.freeze({
    ready,
    main,
    app: appSdk,
  });
  global.console?.info?.("Playmesh Game SDK 注入成功", {
    version: PLAYMESH_SDK_VERSION,
  });

  async function connectBrowserFullscreen(config) {
    const launchOrientation = config.orientation === "system"
      ? undefined
      : config.orientation;
    if (appSdk.isAvailable() && typeof appSdk.device?.setFullscreen === "function") {
      try {
        await appSdk.device.setFullscreen(true, launchOrientation);
        global.console?.info?.("Playmesh 扫码加入页面已自动进入全屏");
      } catch (error) {
        global.console?.warn?.("Playmesh 扫码加入页面自动全屏失败，游戏将继续", error);
      }
    } else {
      void requestBrowserFullscreen(launchOrientation).catch((error) => {
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
    rejectAllRpcRequests(reason);
    stopLatencyProbes();
    global.console?.info?.(
      reason === "开发游戏页面正在重启"
        ? "Playmesh 开发游戏页面正在重启，已停止旧页面 WebSocket 重连"
        : "Playmesh 游戏页面已退出，停止 WebSocket 重连",
      { reason },
    );
  }

  async function lockBrowserOrientation(orientation) {
    const screenOrientation = global.screen?.orientation;
    if (orientation === "system") {
      screenOrientation?.unlock?.();
      return;
    }
    if (orientation !== "landscape" && orientation !== "portrait") return;
    const lock = screenOrientation?.lock;
    if (typeof lock !== "function") {
      throw new Error("当前浏览器不支持锁定屏幕方向");
    }
    await lock.call(screenOrientation, orientation);
  }

  async function requestBrowserFullscreen(orientation) {
    const target = global.document?.documentElement;
    if (!target || typeof target.requestFullscreen !== "function") {
      throw new Error("当前浏览器不支持全屏");
    }
    await target.requestFullscreen();
    await lockBrowserOrientation(orientation);
  }

  function storageCall(command, bucket, key, value) {
    const operation = command.slice("storage.".length);
    if (!["get", "set", "remove", "clear"].includes(operation)) {
      throw new Error(`未知存储操作: ${command}`);
    }
    const previous = standardStorageBucketOperations.get(bucket) || Promise.resolve();
    const current = previous
      .catch(() => {})
      .then(() => performStandardStorageCall(operation, bucket, key, value));
    standardStorageBucketOperations.set(bucket, current);
    current.then(
      () => {
        if (standardStorageBucketOperations.get(bucket) === current) {
          standardStorageBucketOperations.delete(bucket);
        }
      },
      () => {
        if (standardStorageBucketOperations.get(bucket) === current) {
          standardStorageBucketOperations.delete(bucket);
        }
      },
    );
    return current;
  }

  async function performStandardStorageCall(operation, bucket, key, value) {
    await main.ready;
    const gameId = bootstrap?.gameInfo?.id;
    if (typeof gameId !== "string" || !gameId) {
      throw new Error("当前游戏存储上下文不可用");
    }
    if (operation !== "get" && !standardStorageRevisions.has(bucket)) {
      await standardStorageRestRequest(
        "get",
        bucket,
        key === undefined ? "_playmesh_revision_probe" : key,
        undefined,
        gameId,
      );
    }
    return standardStorageRestRequest(operation, bucket, key, value, gameId);
  }

  async function standardStorageRestRequest(operation, bucket, key, value, gameId) {
    const requestId = standardStorageRequestId();
    const revision = standardStorageRevisions.get(bucket) || null;
    const envelope = operation === "get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          revision,
        }
      : operation === "set"
        ? {
            protocolVersion: "1.0.0",
            requestId,
            gameId,
            operation,
            bucket,
            key,
            value,
            expectedRevision: revision,
          }
        : operation === "remove"
          ? {
              protocolVersion: "1.0.0",
              requestId,
              gameId,
              operation,
              bucket,
              key,
              expectedRevision: revision,
            }
          : {
              protocolVersion: "1.0.0",
              requestId,
              gameId,
              operation,
              bucket,
              expectedRevision: revision,
            };
    const body = JSON.stringify(envelope);
    const digest = await standardStorageSha256(body);
    const method = operation === "get"
      ? "GET"
      : operation === "set"
        ? "PUT"
        : "DELETE";
    const url = method === "PUT"
      ? "/bucket/_playmesh-json/v1"
      : `/bucket/_playmesh-json/v1?payload=${standardStorageBase64Url(
          standardStorageUtf8Bytes(body),
        )}`;
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await global.fetch(url, {
          method,
          credentials: "same-origin",
          headers: {
            ...(method === "PUT" ? { "Content-Type": "application/json" } : {}),
            "X-Playmesh-Content-Sha256": digest,
          },
          ...(method === "PUT" ? { body } : {}),
        });
        let payload = null;
        try {
          payload = await response.json();
        } catch (error) {
          if (attempt === 0) {
            lastError = error;
            continue;
          }
          throw new Error("存储 HTTP 响应不是有效 JSON");
        }
        if (response.status >= 500 && attempt === 0) {
          lastError = new Error(
            payload?.error?.message || "存储网关暂时不可用",
          );
          continue;
        }
        if (!response.ok) {
          const error = new Error(
            payload?.error?.message || `存储 HTTP 请求失败: ${response.status}`,
          );
          error.code = payload?.error?.code || "storage_http_failed";
          throw error;
        }
        if (
          payload?.protocolVersion !== "1.0.0" ||
          payload?.requestId !== requestId
        ) {
          throw new Error("存储 HTTP 响应与请求不匹配");
        }
        const result = payload.result;
        if (!result ||
            typeof result !== "object" ||
            !/^[a-f0-9]{64}$/.test(result.revision || "")) {
          throw new Error("存储 HTTP 响应缺少有效修订号");
        }
        standardStorageRevisions.set(bucket, result.revision);
        if (operation === "get") {
          if (!Object.prototype.hasOwnProperty.call(result, "value")) {
            throw new Error("存储 HTTP 读取响应缺少 value");
          }
          return result.value;
        }
        return null;
      } catch (error) {
        lastError = error;
        if (attempt === 0 && error?.code == null) continue;
        throw error;
      }
    }
    throw new Error(
      `存储 HTTP 路由不可用: ${lastError?.message || lastError || "unknown"}`,
    );
  }

  function standardStorageRequestId() {
    const bytes = new Uint8Array(12);
    if (global.crypto?.getRandomValues) {
      global.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    const nonce = [...bytes]
      .map((item) => item.toString(16).padStart(2, "0"))
      .join("");
    return `storage-${Date.now().toString(36)}-${nonce}`;
  }

  async function standardStorageSha256(value) {
    if (!global.crypto?.subtle || typeof global.TextEncoder !== "function") {
      throw new Error("当前 WebView 不支持标准存储 SHA-256 校验");
    }
    const data = new global.TextEncoder().encode(value);
    const digest = await global.crypto.subtle.digest("SHA-256", data);
    return [...new Uint8Array(digest)]
      .map((item) => item.toString(16).padStart(2, "0"))
      .join("");
  }

  function storageCallSync(operation, bucket, key, value) {
    if (operation !== "sync.get" && operation !== "sync.set") {
      throw new Error(`未知同步存储操作: ${operation}`);
    }
    if (operation === "sync.set" && !standardStorageRevisions.has(bucket)) {
      storageCallSync("sync.get", bucket, key);
    }
    const requestId = standardStorageRequestId();
    const gameId = bootstrap?.gameInfo?.id ||
      global.__PLAYMESH_BROWSER__?.gameId ||
      "@playmesh-current-game";
    const revision = standardStorageRevisions.get(bucket) || null;
    const envelope = operation === "sync.get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          revision,
        }
      : {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          value,
          expectedRevision: revision,
        };
    const body = JSON.stringify(envelope);
    if (typeof body !== "string") {
      throw new Error("同步存储值必须可序列化为 JSON");
    }
    const digest = standardStorageSha256Sync(body);
    const result = synchronousStorageHttpRequest(
      operation === "sync.get" ? "GET" : "PUT",
      body,
      digest,
      requestId,
    );
    if (!result ||
        typeof result !== "object" ||
        !/^[a-f0-9]{64}$/.test(result.revision || "")) {
      throw new Error("同步存储响应缺少有效修订号");
    }
    standardStorageRevisions.set(bucket, result.revision);
    if (operation === "sync.get") {
      if (!Object.prototype.hasOwnProperty.call(result, "value")) {
        throw new Error("同步存储读取响应缺少 value");
      }
      return result.value;
    }
  }

  function synchronousStorageHttpRequest(method, body, digest, requestId) {
    if (typeof global.XMLHttpRequest !== "function") {
      throw new Error("当前 WebView 不支持同步 XMLHttpRequest 存储");
    }
    const url = method === "GET"
      ? `/bucket/_playmesh-json/v1?payload=${standardStorageBase64Url(
          standardStorageUtf8Bytes(body),
        )}`
      : "/bucket/_playmesh-json/v1";
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const xhr = new global.XMLHttpRequest();
        xhr.open(method, url, false);
        xhr.setRequestHeader("X-Playmesh-Storage-Sync", "1");
        xhr.setRequestHeader("X-Playmesh-Content-Sha256", digest);
        if (method === "PUT") {
          xhr.setRequestHeader("Content-Type", "application/json");
        }
        xhr.send(method === "PUT" ? body : null);
        const status = xhr.status === 1223 ? 204 : xhr.status;
        let payload;
        try {
          payload = JSON.parse(xhr.responseText || "");
        } catch (error) {
          if (attempt === 0) {
            lastError = error;
            continue;
          }
          throw new Error("同步存储 HTTP 响应不是有效 JSON");
        }
        if (status >= 500 && attempt === 0) {
          lastError = new Error(payload?.error?.message || "存储网关暂时不可用");
          continue;
        }
        if (status < 200 || status >= 300) {
          const error = new Error(
            payload?.error?.message || `同步存储 HTTP 请求失败: ${status}`,
          );
          error.code = payload?.error?.code || "storage_sync_http_failed";
          throw error;
        }
        if (payload?.protocolVersion !== "1.0.0" ||
            payload?.requestId !== requestId) {
          if (attempt === 0) {
            lastError = new Error("同步存储 HTTP 响应与请求不匹配");
            continue;
          }
          throw new Error("同步存储 HTTP 响应与请求不匹配");
        }
        return payload.result;
      } catch (error) {
        lastError = error;
        if (attempt === 0 && error?.code == null) continue;
        throw error;
      }
    }
    throw new Error(
      `同步存储 HTTP 路由不可用: ${lastError?.message || lastError || "unknown"}`,
    );
  }

  function standardStorageUtf8Bytes(value) {
    if (typeof global.TextEncoder === "function") {
      return new global.TextEncoder().encode(value);
    }
    const bytes = [];
    for (let index = 0; index < value.length; index += 1) {
      let codePoint = value.charCodeAt(index);
      if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
        const low = value.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00);
          index += 1;
        } else {
          codePoint = 0xfffd;
        }
      } else if (codePoint >= 0xdc00 && codePoint <= 0xdfff) {
        codePoint = 0xfffd;
      }
      if (codePoint <= 0x7f) {
        bytes.push(codePoint);
      } else if (codePoint <= 0x7ff) {
        bytes.push(0xc0 | (codePoint >>> 6), 0x80 | (codePoint & 0x3f));
      } else if (codePoint <= 0xffff) {
        bytes.push(
          0xe0 | (codePoint >>> 12),
          0x80 | ((codePoint >>> 6) & 0x3f),
          0x80 | (codePoint & 0x3f),
        );
      } else {
        bytes.push(
          0xf0 | (codePoint >>> 18),
          0x80 | ((codePoint >>> 12) & 0x3f),
          0x80 | ((codePoint >>> 6) & 0x3f),
          0x80 | (codePoint & 0x3f),
        );
      }
    }
    return new Uint8Array(bytes);
  }

  function standardStorageSha256Sync(value) {
    const bytes = standardStorageUtf8Bytes(value);
    const constants = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    const state = new Uint32Array([
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]);
    const words = new Uint32Array(64);
    const paddedLength = Math.ceil((bytes.length + 9) / 64) * 64;
    const bitLength = bytes.length * 8;
    const bitLengthHigh = Math.floor(bitLength / 0x100000000);
    const bitLengthLow = bitLength >>> 0;
    const byteAt = (position) => {
      if (position < bytes.length) return bytes[position];
      if (position === bytes.length) return 0x80;
      if (position < paddedLength - 8) return 0;
      const shift = (paddedLength - 1 - position) * 8;
      return shift >= 32
        ? (bitLengthHigh >>> (shift - 32)) & 0xff
        : (bitLengthLow >>> shift) & 0xff;
    };
    const rotateRight = (value, bits) =>
      (value >>> bits) | (value << (32 - bits));
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let index = 0; index < 16; index += 1) {
        const position = offset + index * 4;
        words[index] = (
          (byteAt(position) << 24) |
          (byteAt(position + 1) << 16) |
          (byteAt(position + 2) << 8) |
          byteAt(position + 3)
        ) >>> 0;
      }
      for (let index = 16; index < 64; index += 1) {
        const x = words[index - 15];
        const y = words[index - 2];
        const sigma0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >>> 3);
        const sigma1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >>> 10);
        words[index] = (
          words[index - 16] + sigma0 + words[index - 7] + sigma1
        ) >>> 0;
      }
      let a = state[0];
      let b = state[1];
      let c = state[2];
      let d = state[3];
      let e = state[4];
      let f = state[5];
      let g = state[6];
      let h = state[7];
      for (let index = 0; index < 64; index += 1) {
        const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        const choice = (e & f) ^ (~e & g);
        const temporary1 = (h + sum1 + choice + constants[index] + words[index]) >>> 0;
        const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        const majority = (a & b) ^ (a & c) ^ (b & c);
        const temporary2 = (sum0 + majority) >>> 0;
        h = g;
        g = f;
        f = e;
        e = (d + temporary1) >>> 0;
        d = c;
        c = b;
        b = a;
        a = (temporary1 + temporary2) >>> 0;
      }
      state[0] = (state[0] + a) >>> 0;
      state[1] = (state[1] + b) >>> 0;
      state[2] = (state[2] + c) >>> 0;
      state[3] = (state[3] + d) >>> 0;
      state[4] = (state[4] + e) >>> 0;
      state[5] = (state[5] + f) >>> 0;
      state[6] = (state[6] + g) >>> 0;
      state[7] = (state[7] + h) >>> 0;
    }
    return [...state]
      .map((item) => item.toString(16).padStart(8, "0"))
      .join("");
  }

  function standardStorageBase64Url(bytes) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let encoded = "";
    for (let index = 0; index < bytes.length; index += 3) {
      const first = bytes[index];
      const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
      const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
      encoded += alphabet[first >>> 2];
      encoded += alphabet[((first & 3) << 4) | (second >>> 4)];
      if (index + 1 < bytes.length) {
        encoded += alphabet[((second & 15) << 2) | (third >>> 6)];
      }
      if (index + 2 < bytes.length) encoded += alphabet[third & 63];
    }
    return encoded;
  }

  async function storageUpload(bucket, source, options) {
    await main.ready;
    const stream = normalizeStorageUploadSource(source, options);
    const config = global.__PLAYMESH_BROWSER__;
    const base = config?.bucketEndpoint || "/bucket";
    const url = `${base}/${encodeURIComponent(bucket)}?name=${encodeURIComponent(stream.name)}`;
    const headers = {};
    if (config?.shareToken) {
      headers["X-Playmesh-Share-Token"] = config.shareToken;
    }
    if (stream.type) headers["Content-Type"] = stream.type;
    const response = stream.streaming
      ? await uploadRpcStreamChunks({
          endpoint: (() => {
            const endpoint = new URL(
              url,
              global.location?.href || "http://playmesh.local/",
            );
            if (stream.size !== null) {
              endpoint.searchParams.set("size", String(stream.size));
            }
            return endpoint;
          })(),
          stream,
          headers,
          expectedPathPrefix: "/bucket/_playmesh-stream/v1/",
          errorMessage: "文件上传失败",
        })
      : await global.fetch(url, {
          method: "POST",
          headers,
          body: stream.body,
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
    const suffix = Math.floor(Math.random() * 36 ** 4).toString(36).padStart(4, "0");
    const nickname = `浏览器${suffix}`;
    writeBrowserNickname(nickname);
    return nickname;
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
      // 隐私浏览可能拒绝持久化，但当前会话仍可继续。
    }
  }

  function restoreBrowserNickname(nickname) {
    try {
      if (nickname) {
        global.localStorage?.setItem(browserNicknameStorageKey, nickname);
      } else {
        global.localStorage?.removeItem(browserNicknameStorageKey);
      }
    } catch (_) {
      // 本地存储不可用时只能保留当前内存身份。
    }
  }

  function resolveBrowserPlayerId() {
    try {
      const cached = global.localStorage?.getItem(browserPlayerIdStorageKey);
      if (/^p_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(cached || "")) return cached;
    } catch (_) {
      // 持久化不可用时继续使用内存身份。
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
      // 当前页面仍可加入，但刷新后无法恢复这个身份。
    }
    return playerId;
  }

  function applyNicknameUpdate(
    payload,
    nickname,
    persistBrowserNickname,
    expectedPlayerId = bootstrap?.player?.id,
    expectedSessionId = bootstrap?.session?.id,
  ) {
    const player = publicPlayer(payload?.player || payload);
    const session = payload?.session ? publicSession(payload.session) : null;
    if (!player ||
        !expectedPlayerId ||
        player.id !== expectedPlayerId ||
        player.nickname !== nickname ||
        (session && expectedSessionId && session.id !== expectedSessionId)) {
      throw new Error("宿主没有返回匹配当前身份的玩家资料");
    }
    bootstrap.player = player;
    if (session) {
      bootstrap.session = session;
    } else if (bootstrap.session) {
      bootstrap.session = {
        ...bootstrap.session,
        players: bootstrap.session.players.map((member) =>
          member.id === player.id ? player : member),
      };
    }
    if (persistBrowserNickname) writeBrowserNickname(nickname);
    if (browserConnectionConfig) {
      browserConnectionConfig = { ...browserConnectionConfig, nickname };
    }
    if (browserCredential) {
      browserCredential = { ...browserCredential, player: { ...player } };
    }
    if (bootstrap.session) emit(sessionListeners, bootstrap.session);
    return bootstrap.player;
  }

  async function updateHostNickname(value) {
    const nickname = validateNickname(value, true);
    await main.ready;
    return applyNicknameUpdate(
      await post("player.setNickname", { nickname }),
      nickname,
      false,
    );
  }

  async function updateAppNickname(value) {
    const nickname = validateNickname(value, true);
    await main.ready;
    if (typeof appInternalRuntime.updateIdentityNickname !== "function") {
      throw new Error("当前宿主不支持修改玩家昵称");
    }
    const payload = await appInternalRuntime.updateIdentityNickname(
      nickname,
      browserCredential && bootstrap?.session?.id
        ? bootstrap.session.id
        : undefined,
      browserCredential?.token,
      browserCredential && bootstrap?.player?.id
        ? bootstrap.player.id
        : undefined,
    );
    return applyNicknameUpdate(payload, nickname, false);
  }

  async function updateBrowserNickname(value) {
    const nickname = validateNickname(value, true);
    await main.ready;
    const config = global.__PLAYMESH_BROWSER__;
    const sessionId = bootstrap?.session?.id;
    const playerId = bootstrap?.player?.id;
    if (!sessionId || !playerId || !browserCredential?.token) {
      throw new Error("当前页面没有可修改昵称的玩家会话");
    }
    const previousNickname = readBrowserNickname();
    const previousPlayerNickname = bootstrap.player.nickname;
    writeBrowserNickname(nickname);
    if (browserConnectionConfig) {
      browserConnectionConfig = { ...browserConnectionConfig, nickname };
    }
    let ambiguousError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await fetch(new URL(
          `v1/sessions/${encodeURIComponent(sessionId)}/players/me`,
          config.coreBase,
        ), {
          method: "PATCH",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${browserCredential.token}`,
          },
          body: JSON.stringify({ nickname }),
        });
        let payload = null;
        try {
          payload = await response.json();
        } catch (error) {
          if (response.ok) throw error;
        }
        if (!response.ok && response.status >= 400 && response.status < 500) {
          const error = new Error(
            payload?.error?.message || payload?.error || "修改昵称失败",
          );
          error.nicknameCommitRejected = true;
          throw error;
        }
        if (!response.ok) {
          throw new Error(`修改昵称结果不明确（HTTP ${response.status}）`);
        }
        return applyNicknameUpdate(
          payload,
          nickname,
          false,
          playerId,
          sessionId,
        );
      } catch (error) {
        if (error?.nicknameCommitRejected) {
          restoreBrowserNickname(previousNickname);
          if (browserConnectionConfig) {
            browserConnectionConfig = {
              ...browserConnectionConfig,
              nickname: previousPlayerNickname,
            };
          }
          throw error;
        }
        ambiguousError = error;
      }
    }
    let snapshot;
    try {
      const response = await fetch(new URL(
        `v1/sessions/${encodeURIComponent(sessionId)}`,
        config.coreBase,
      ), {
        headers: { "Authorization": `Bearer ${browserCredential.token}` },
      });
      if (!response.ok) throw new Error("读取房间昵称状态失败");
      snapshot = await response.json();
    } catch (_) {
      const error = new Error("昵称已保存在本机，等待与房间重新同步");
      error.code = "nickname_update_pending";
      error.cause = ambiguousError;
      throw error;
    }
    const authoritativePlayer = Array.isArray(snapshot?.players)
      ? snapshot.players.find((player) => player?.id === playerId)
      : null;
    const authoritativeNickname = validateNickname(
      authoritativePlayer?.nickname,
      false,
    );
    if (snapshot?.id !== sessionId || !authoritativePlayer || !authoritativeNickname) {
      const error = new Error("昵称已保存在本机，等待与房间重新同步");
      error.code = "nickname_update_pending";
      error.cause = ambiguousError;
      throw error;
    }
    if (authoritativeNickname === nickname) {
      return applyNicknameUpdate(
        { session: snapshot, player: authoritativePlayer },
        nickname,
        false,
        playerId,
        sessionId,
      );
    }
    restoreBrowserNickname(authoritativeNickname);
    applyNicknameUpdate(
      { session: snapshot, player: authoritativePlayer },
      authoritativeNickname,
      false,
      playerId,
      sessionId,
    );
    const error = new Error("Core 未提交昵称更新");
    error.code = "nickname_update_failed";
    error.cause = ambiguousError;
    throw error;
  }

  function validateNickname(value, throws) {
    const nickname = typeof value === "string" ? value.trim() : "";
    if (nickname && [...nickname].length <= 32) return nickname;
    if (throws) throw new Error("昵称必须为 1 至 32 个字符");
    return null;
  }

  async function editBrowserNickname() {
    const value = await openBrowserNicknameDialog({
      current: bootstrap?.player?.nickname || readBrowserNickname() || "",
      submit: main.player.setNickname,
    });
    return value !== null;
  }

  async function openBrowserNicknameDialog(options) {
    const ui = await ensureBrowserNicknameUi();
    if (!ui) throw new Error("浏览器昵称界面不可用");
    ui.title.textContent = platformText("nickname.edit_title");
    ui.input.value = options.current;
    ui.error.textContent = "";
    ui.close.hidden = false;
    openPlatformUiLayer(
      ui.overlay,
      ui.input,
      options.returnFocus || ui.pageReturnFocus,
    );
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        ui.onNicknameBack = null;
        closePlatformUiLayer(
          ui.overlay,
          options.returnFocus || ui.pageReturnFocus,
        );
        resolve(value);
      };
      ui.onNicknameBack = () => {
        if (ui.submit.disabled) return;
        finish(null);
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

  function registerAppPlatformUiRuntime() {
    if (typeof appInternalRuntime.registerRuntimeUi !== "function") return;
    appInternalRuntime.registerRuntimeUi({
      async reload() {
        const multiplayer = main.gameInfo.getCurrent()?.multiplayer === true;
        if (multiplayer && main.session.isAuthority()) {
          await post("session.reset", {});
        }
        global.location?.reload?.();
      },
      async getInfo() {
        await main.ready;
        const gameInfo = main.gameInfo.getCurrent();
        if (!gameInfo) return null;
        const session = main.session.getCurrent();
        const player = main.player.getCurrent();
        return {
          gameId: gameInfo.id,
          gameName: gameInfo.name,
          tags: [...(gameInfo.tags || [])],
          requiredCapabilities: [...gameInfo.requiredCapabilities],
          joinCode: session?.joinCode || null,
          multiplayer: gameInfo.multiplayer,
          isAuthority: main.session.isAuthority(),
          playerName: player?.nickname || null,
          canEditNickname: gameInfo.multiplayer === true && player !== null,
          playerCount: Array.isArray(session?.players)
            ? session.players.length
            : null,
          gameSdkVersion: main.version,
          appSdkVersion: appSdk.version,
          platform: appSdk.device.getPlatform() || "browser",
        };
      },
      editNickname() {
        return editBrowserNickname();
      },
    });
  }

  async function ensureBrowserNicknameUi() {
    if (browserNicknameUi) return browserNicknameUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    const pageReturnFocus = global.document.activeElement || null;
    const host = global.document.createElement("div");
    host.id = "playmesh-browser-nickname-ui";
    host.setAttribute?.("lang", platformUiLocale);
    host.setAttribute?.("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#20242b;--pm-hover:#343b46;--pm-text:#f4f7fb;--pm-border:#596272;--pm-overlay:#0008;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-focus:#78a6ff;--pm-error:#fda4af;font-family:system-ui,"Microsoft YaHei",sans-serif;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#fff;--pm-hover:#e8edf3;--pm-text:#18212c;--pm-border:#91a0b0;--pm-overlay:#dce3ecd9;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-focus:#075dce;--pm-error:#a1122f;color-scheme:light}
      button,input{box-sizing:border-box;font:inherit;letter-spacing:0}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:20px;background:var(--pm-overlay)}
      .overlay[hidden]{display:none}
      form{box-sizing:border-box;width:min(100%,380px);max-height:calc(100dvh - 40px);overflow:auto;padding:20px;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface);color:var(--pm-text);box-shadow:0 16px 40px #0005}
      h2{margin:0 0 16px;font-size:20px;line-height:1.3;letter-spacing:0}
      label{display:block;margin-bottom:6px;font-size:14px;font-weight:700}
      input{width:100%;height:44px;padding:8px 10px;border:1px solid var(--pm-border);border-radius:6px;color:var(--pm-field-text);background:var(--pm-field-bg)}
      .error{min-height:20px;margin:6px 0;color:var(--pm-error);font-size:13px}
      .actions{display:flex;justify-content:flex-end;gap:8px}
      .actions button{height:40px;padding:0 14px;border:1px solid var(--pm-border);border-radius:6px;background:var(--pm-hover);color:var(--pm-text);cursor:pointer}
      .actions .save{border-color:#10b981;background:#0f766e;color:#fff;font-weight:700}
      .actions button:focus-visible,input:focus-visible{outline:3px solid var(--pm-focus);outline-offset:-3px}
      button:disabled{cursor:wait;opacity:.65}
    </style>
    <div class="overlay" role="dialog" aria-modal="true" aria-labelledby="playmesh-nickname-title" hidden>
      <form><h2 id="playmesh-nickname-title"></h2><label class="nickname-label" for="nickname">${platformHtml("nickname.label")}</label>
      <input id="nickname" maxlength="32" autocomplete="nickname" required>
      <div class="error" role="alert"></div><div class="actions">
      <button class="close" type="button" aria-label="${platformHtml("common.cancel")}">${platformHtml("common.cancel")}</button><button class="save" type="submit" aria-label="${platformHtml("common.save")}">${platformHtml("common.save")}</button>
      </div></form>
    </div>`;
    global.document.body.appendChild(host);
    browserNicknameUi = {
      host,
      pageReturnFocus,
      overlay: root.querySelector(".overlay"),
      form: root.querySelector("form"),
      title: root.querySelector("h2"),
      nicknameLabel: root.querySelector(".nickname-label"),
      input: root.querySelector("input"),
      error: root.querySelector(".error"),
      close: root.querySelector(".close"),
      submit: root.querySelector(".save"),
    };
    const ui = browserNicknameUi;
    global.document.addEventListener?.("focusin", (event) => {
      if (event.target && event.target !== host) {
        ui.pageReturnFocus = event.target;
      }
    }, true);
    installPlatformUiKeyboardNavigation(
      ui.overlay,
      () => [ui.input, ui.close, ui.submit],
      {
        trap: true,
        onBack: () => ui.onNicknameBack?.(),
      },
    );
    refreshBrowserPlatformUi(ui);
    return browserNicknameUi;
  }

  function setPlatformControlLabel(element, key, { visible = false } = {}) {
    if (!element) return;
    const label = platformText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    if (visible) element.textContent = label;
  }

  function refreshBrowserPlatformUi(ui) {
    if (!ui) return;
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    ui.host?.setAttribute?.("lang", platformUiLocale);
    if (ui.nicknameLabel) {
      ui.nicknameLabel.textContent = platformText("nickname.label");
    }
    if (ui.title && !ui.overlay.hidden) {
      ui.title.textContent = platformText("nickname.edit_title");
    }
    setPlatformControlLabel(ui.close, "common.cancel", { visible: true });
    setPlatformControlLabel(ui.submit, "common.save", { visible: true });
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

  function validateSynchronousStorageBucketName(value) {
    if (typeof value !== "string") throw new Error("无效的 bucket");
    const length = standardStorageUtf8Bytes(value).length;
    if (length < 1 || length > 4096) {
      throw new Error("同步 Bucket 逻辑名必须为 1 至 4096 个 UTF-8 字节");
    }
  }

  function validateSynchronousStorageKey(value) {
    if (value === "$playmesh.gdevelop.root.v1") return;
    validateStorageName(value, "key");
  }
})(window);
''',
);

class _GameStorageLifecycleFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gameStorageLifecycleSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'lifecycle.complete'};

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final lifecycleRequestId = sdkRequiredString(
      command.payload,
      'lifecycleRequestId',
    );
    context.completeLifecycle(lifecycleRequestId);
    return const SdkCommandResult();
  }
}
