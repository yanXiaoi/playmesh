part of '../../sdk_feature_registry.dart';

const gameStorageLifecycleSdkSource = SdkSourceFragment(
  id: 'game.storage-lifecycle',
  target: SdkSourceTarget.game,
  order: 70,
  typeScript: r'''  const browserConsoleLogs = [];
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

  installBrowserConsoleCapture();
  global.playmesh = playmesh;
  global.console?.info?.("Playmesh Game SDK 注入成功", {
    version: PLAYMESH_SDK_VERSION,
  });
  if (global.chrome && global.chrome.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  global.addEventListener?.("pagehide", () => markRuntimeExited("游戏页面已退出"));
  playmesh.ready = appSdk.ready.then(async (appBootstrap) => {
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
          "浏览器未允许自动全屏，可通过悬浮工具栏手动进入",
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
      options.returnFocus || (options.required ? null : ui.more),
    );
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (value, error = null) => {
        if (settled) return;
        settled = true;
        ui.onNicknameBack = null;
        closePlatformUiLayer(ui.overlay, options.returnFocus || ui.more);
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

  function installBrowserDockDrag(ui) {
    const dock = ui?.dock;
    if (!dock?.addEventListener) return;
    let drag = null;
    let suppressClick = false;
    const clampPosition = (left, top, rect) => ({
      left: Math.max(4, Math.min(left, Math.max(4, (global.innerWidth || 0) - rect.width - 4))),
      top: Math.max(4, Math.min(top, Math.max(4, (global.innerHeight || 0) - rect.height - 4))),
    });
    const moveDock = (left, top, rect) => {
      const position = clampPosition(left, top, rect);
      dock.style.left = `${position.left}px`;
      dock.style.top = `${position.top}px`;
      dock.style.right = "auto";
      dock.style.bottom = "auto";
    };
    dock.addEventListener("pointerdown", (event) => {
      if (event.isPrimary === false || (event.button != null && event.button !== 0)) return;
      const rect = dock.getBoundingClientRect();
      drag = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        moved: false,
      };
      dock.setPointerCapture?.(event.pointerId);
    });
    dock.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.pointerId) return;
      const deltaX = event.clientX - drag.startX;
      const deltaY = event.clientY - drag.startY;
      if (!drag.moved && Math.hypot(deltaX, deltaY) < 6) return;
      drag.moved = true;
      event.preventDefault?.();
      ui.menu.hidden = true;
      moveDock(drag.left + deltaX, drag.top + deltaY, drag);
    });
    const finishDrag = (event) => {
      if (!drag || event.pointerId !== drag.pointerId) return;
      suppressClick = drag.moved;
      dock.releasePointerCapture?.(event.pointerId);
      drag = null;
    };
    dock.addEventListener("pointerup", finishDrag);
    dock.addEventListener("pointercancel", finishDrag);
    dock.addEventListener("click", (event) => {
      if (!suppressClick) return;
      suppressClick = false;
      event.preventDefault?.();
      event.stopImmediatePropagation?.();
    }, true);
    global.addEventListener?.("resize", () => {
      if (!dock.style.left) return;
      const rect = dock.getBoundingClientRect();
      moveDock(rect.left, rect.top, rect);
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
    host.id = "playmesh-browser-profile";
    host.setAttribute?.("lang", platformUiLocale);
    host.setAttribute?.("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#121720eb;--pm-surface-solid:#20242b;--pm-surface-hover:#343b46;--pm-text:#f4f7fb;--pm-muted:#d5dbe4;--pm-border:#596272;--pm-soft-border:#ffffff35;--pm-divider:#ffffff18;--pm-overlay:#0008;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-log-bg:#0b0f15;--pm-log-text:#dbe5f0;--pm-focus:#78a6ff;--pm-error:#fda4af;font-family:system-ui,"Microsoft YaHei",sans-serif;letter-spacing:0;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#fffffff2;--pm-surface-solid:#ffffff;--pm-surface-hover:#e8edf3;--pm-text:#18212c;--pm-muted:#526071;--pm-border:#91a0b0;--pm-soft-border:#aab5c2;--pm-divider:#d5dde6;--pm-overlay:#dce3ecd9;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-log-bg:#f4f7fa;--pm-log-text:#1f2937;--pm-focus:#075dce;--pm-error:#a1122f;color-scheme:light}
      button,input{box-sizing:border-box;font:inherit;letter-spacing:0}
      .dock{position:fixed;right:max(12px,env(safe-area-inset-right));top:max(12px,env(safe-area-inset-top));z-index:2147483646;display:flex;align-items:flex-end;flex-direction:column;color:var(--pm-text);filter:drop-shadow(0 8px 20px #0006);touch-action:none;user-select:none}
      .tools{display:flex;flex-direction:column;overflow:hidden;border:1px solid var(--pm-soft-border);border-radius:8px;background:var(--pm-surface)}
      .tool,.expand{display:grid;place-items:center;width:48px;height:48px;padding:0;border:0;border-bottom:1px solid var(--pm-divider);background:transparent;color:var(--pm-text);font:800 21px/1 system-ui;cursor:pointer}
      .tool:last-child{border-bottom:0}.tool:hover,.expand:hover{background:var(--pm-surface-hover)}.tool:focus-visible,.expand:focus-visible,.menu button:focus-visible,.actions button:focus-visible,.logs-head button:focus-visible,.logs-output:focus-visible,input:focus-visible{outline:3px solid var(--pm-focus);outline-offset:-3px}.tool.active{color:#087f6d}
      .expand{border:1px solid var(--pm-soft-border);border-radius:8px;background:var(--pm-surface)}
      .panel{display:flex;align-items:center;gap:10px;margin-top:8px;padding:8px 10px;border:1px solid var(--pm-soft-border);border-radius:8px;background:var(--pm-surface);color:var(--pm-text);font:700 12px/1 ui-monospace,SFMono-Regular,Consolas,monospace}
      .menu{position:absolute;right:56px;top:0;width:190px;overflow:hidden;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface-solid);color:var(--pm-text);box-shadow:0 12px 30px #0005}
      .menu button{display:flex;align-items:center;width:100%;height:48px;padding:0 15px;border:0;border-bottom:1px solid var(--pm-divider);background:var(--pm-surface-solid);color:var(--pm-text);font:700 14px/1 system-ui,"Microsoft YaHei",sans-serif;cursor:pointer}.menu button:last-child{border-bottom:0}.menu button:hover{background:var(--pm-surface-hover)}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:20px;background:var(--pm-overlay)}
      .overlay[hidden],.panel[hidden],.menu[hidden],.expand[hidden],.tools[hidden],.edit[hidden],.latency[hidden],.info-overlay[hidden],.logs-overlay[hidden]{display:none}
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
      @media (max-height:360px) and (min-width:500px){.tools{flex-direction:row}.tool{border-right:1px solid #ffffff18;border-bottom:0}.tool:last-child{border-right:0}.panel{position:absolute;right:0;top:56px;margin:0}.menu{right:0;top:56px}}
    </style>
    <div class="dock">
      <button class="expand" type="button" title="${platformHtml("toolbar.expand")}" aria-label="${platformHtml("toolbar.expand")}" aria-expanded="false" aria-controls="playmesh-browser-tools" tabindex="0">🎮</button>
      <div class="tools" id="playmesh-browser-tools" role="toolbar" hidden>
        <button class="tool collapse" type="button" title="${platformHtml("toolbar.collapse")}" aria-label="${platformHtml("toolbar.collapse")}" tabindex="0">⌃</button>
        <button class="tool reload" type="button" title="${platformHtml("toolbar.restart")}" aria-label="${platformHtml("toolbar.restart")}" tabindex="-1">↻</button>
        <button class="tool logs" type="button" title="${platformHtml("toolbar.logs")}" aria-label="${platformHtml("toolbar.logs")}" tabindex="-1">≡</button>
        <button class="tool enter-fullscreen" type="button" title="${platformHtml("toolbar.enter_fullscreen")}" aria-label="${platformHtml("toolbar.enter_fullscreen")}" tabindex="-1">⛶</button>
        <button class="tool exit-fullscreen" type="button" title="${platformHtml("toolbar.exit_fullscreen")}" aria-label="${platformHtml("toolbar.exit_fullscreen")}" tabindex="-1">⊡</button>
        <button class="tool more" type="button" title="${platformHtml("toolbar.more")}" aria-label="${platformHtml("toolbar.more")}" aria-expanded="false" aria-controls="playmesh-browser-menu" tabindex="-1">⋮</button>
      </div>
      <div class="panel" hidden><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>
      <div class="menu" id="playmesh-browser-menu" role="menu" hidden><button class="info" role="menuitem" type="button" aria-label="${platformHtml("menu.info")}" tabindex="0">${platformHtml("menu.info")}</button><button class="performance" role="menuitem" type="button" aria-label="${platformHtml("menu.performance")}" aria-pressed="false" tabindex="-1">${platformHtml("menu.performance")}</button></div>
    </div>
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
      dock: root.querySelector(".dock"),
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
      expand: root.querySelector(".expand"),
      tools: root.querySelector(".tools"),
      collapse: root.querySelector(".collapse"),
      reload: root.querySelector(".reload"),
      enterFullscreen: root.querySelector(".enter-fullscreen"),
      exitFullscreen: root.querySelector(".exit-fullscreen"),
      more: root.querySelector(".more"),
      menu: root.querySelector(".menu"),
      info: root.querySelector(".info"),
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
    const toolbarControls = () => [
      ui.collapse,
      ui.reload,
      ui.logs,
      ui.enterFullscreen,
      ui.exitFullscreen,
      ui.more,
    ];
    const menuControls = () => [ui.info, ui.performanceButton];
    const closeBrowserMenu = (restoreFocus = true) => {
      ui.menu.hidden = true;
      ui.more.setAttribute?.("aria-expanded", "false");
      if (restoreFocus) focusPlatformUiControl(ui.more);
    };
    const openBrowserMenu = () => {
      ui.menu.hidden = false;
      ui.more.setAttribute?.("aria-expanded", "true");
      const first = setPlatformUiRovingTabStop(menuControls(), ui.info);
      focusPlatformUiControl(first);
    };
    ui.collapse.onclick = () => {
      ui.tools.hidden = true;
      ui.expand.hidden = false;
      ui.expand.setAttribute?.("aria-expanded", "false");
      closeBrowserMenu(false);
      focusPlatformUiControl(ui.expand);
    };
    ui.expand.onclick = () => {
      ui.tools.hidden = false;
      ui.expand.hidden = true;
      ui.expand.setAttribute?.("aria-expanded", "true");
      const first = setPlatformUiRovingTabStop(
        toolbarControls(),
        ui.collapse,
      );
      focusPlatformUiControl(first);
    };
    ui.reload.onclick = () => global.location?.reload?.();
    ui.performanceButton.onclick = () => {
      performanceVisible = !performanceVisible;
      void renderPerformanceUi();
      closeBrowserMenu();
    };
    ui.enterFullscreen.onclick = async () => {
      try {
        await requestBrowserFullscreen(browserConnectionConfig?.orientation);
      } catch (error) {
        global.console?.warn?.("浏览器全屏或方向锁定不可用，请手动调整", error);
      }
    };
    ui.exitFullscreen.onclick = () => {
      if (global.document.fullscreenElement) {
        Promise.resolve(global.document.exitFullscreen?.()).catch(() => {});
      }
    };
    ui.more.onclick = () => {
      if (ui.menu.hidden) openBrowserMenu();
      else closeBrowserMenu();
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
      closeBrowserMenu(false);
      openPlatformUiLayer(ui.infoOverlay, ui.infoClose, ui.more);
    };
    ui.logs.onclick = () => {
      renderBrowserConsoleLogs(ui);
      closeBrowserMenu(false);
      openPlatformUiLayer(ui.logsOverlay, ui.logsClose, ui.logs);
    };
    ui.infoClose.onclick = () => {
      closePlatformUiLayer(ui.infoOverlay, ui.more);
    };
    ui.logsClear.onclick = () => {
      browserConsoleLogs.length = 0;
      renderBrowserConsoleLogs(ui);
    };
    ui.logsClose.onclick = () => {
      closePlatformUiLayer(ui.logsOverlay, ui.logs);
    };
    installPlatformUiKeyboardNavigation(
      ui.expand,
      () => [ui.expand],
      {
        onBack: () => focusPlatformUiControl(ui.pageReturnFocus),
      },
    );
    installPlatformUiKeyboardNavigation(
      ui.tools,
      toolbarControls,
      {
        roving: true,
        onBack: () => {
          if (!ui.menu.hidden) closeBrowserMenu();
          else ui.collapse.onclick();
        },
      },
    );
    installPlatformUiKeyboardNavigation(
      ui.menu,
      menuControls,
      {
        roving: true,
        onBack: () => closeBrowserMenu(),
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
    installBrowserDockDrag(ui);
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

  function refreshBrowserPlatformUi(ui) {
    if (!ui) return;
    ui.dock?.getRootNode?.()?.host?.setAttribute?.("lang", platformUiLocale);
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    setPlatformControlLabel(ui.expand, "toolbar.expand");
    setPlatformControlLabel(ui.collapse, "toolbar.collapse");
    setPlatformControlLabel(ui.reload, "toolbar.restart");
    setPlatformControlLabel(ui.logs, "toolbar.logs");
    setPlatformControlLabel(ui.enterFullscreen, "toolbar.enter_fullscreen");
    setPlatformControlLabel(ui.exitFullscreen, "toolbar.exit_fullscreen");
    setPlatformControlLabel(ui.more, "toolbar.more");
    setPlatformControlLabel(ui.info, "menu.info", { visible: true });
    setPlatformControlLabel(ui.performanceButton, "menu.performance", {
      visible: true,
    });
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
''',
);

class _GameStorageLifecycleFeature implements _GameSdkCommandFeature {
  static const _storageCommands = {
    'storage.get',
    'storage.set',
    'storage.remove',
    'storage.clear',
  };

  @override
  SdkSourceFragment get source => gameStorageLifecycleSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'storage.get',
    'storage.set',
    'storage.remove',
    'storage.clear',
    'lifecycle.complete',
  };

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    if (command.name == 'lifecycle.complete') {
      final lifecycleRequestId = sdkRequiredString(
        command.payload,
        'lifecycleRequestId',
      );
      context.completeLifecycle(lifecycleRequestId);
      return const SdkCommandResult();
    }
    if (!_storageCommands.contains(command.name)) {
      throw StateError('未注册的存储命令: ${command.name}');
    }
    final connection = context.connection;
    if (connection != null && !connection.isAuthority) {
      await context.routeRemoteStorage(
        command.name,
        command.requestId,
        command.payload,
      );
      return const SdkCommandDeferred();
    }
    return SdkCommandResult(
      await executeSdkStorageCommand(
        await context.ensureStorage(),
        command.name,
        command.payload,
      ),
    );
  }
}

Future<Object?> executeSdkStorageCommand(
  GameStorageService storage,
  String command,
  Map<String, Object?> payload,
) async {
  final bucket = sdkRequiredString(payload, 'bucket');
  switch (command) {
    case 'storage.get':
      return storage.getData(bucket, sdkRequiredString(payload, 'key'));
    case 'storage.set':
      await storage.setData(
        bucket,
        sdkRequiredString(payload, 'key'),
        payload['value'],
      );
      return null;
    case 'storage.remove':
      await storage.removeData(bucket, sdkRequiredString(payload, 'key'));
      return null;
    case 'storage.clear':
      await storage.clearData(bucket);
      return null;
  }
  throw FormatException('未知存储命令: $command');
}
