part of '../../sdk_feature_registry.dart';

const gameRuntimeSdkSource = SdkSourceFragment(
  id: 'game.runtime',
  target: SdkSourceTarget.game,
  order: 60,
  typeScript: r'''  function receive(rawMessage) {
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
        isAuthority: false,
        player: null,
        session: null,
      };
      emit(lifecycleListeners, { state: "ready" });
      if (!appSdk.isAvailable()) {
        void ensureBrowserNicknameUi().catch((error) => {
          global.console?.warn?.("Playmesh 浏览器游戏侧边栏初始化失败", error);
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
    version: "__PLAYMESH_APP_SDK_VERSION__",
    ready: Promise.resolve({
      available: false,
      identity: null,
      device: { platform: "browser", capabilities: [] },
    }),
    isAvailable() { return false; },
    openSharePanel() {
      return Promise.reject(new Error("当前浏览器没有 Playmesh App 平台分享宿主"));
    },
    showGameSidebar() {
      return Promise.reject(new Error("当前浏览器没有 Playmesh App 游戏侧边栏宿主"));
    },
    hideGameSidebar() {
      return Promise.reject(new Error("当前浏览器没有 Playmesh App 游戏侧边栏宿主"));
    },
    exitGame() {
      return Promise.reject(new Error("当前浏览器没有 Playmesh App 游戏退出宿主"));
    },
    __restoreGameContentFocus() {},
    __requestExit() { return Promise.resolve(); },
    __confirmCapabilities() { return Promise.resolve(); },
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
        : appBootstrap?.device?.declaredCapabilities ??
          appBootstrap?.game?.requiredCapabilities;
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
      gameName: browserConfig?.gameName ||
        appBootstrap?.game?.name ||
        platformText("capability.current_game"),
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

''',
);
