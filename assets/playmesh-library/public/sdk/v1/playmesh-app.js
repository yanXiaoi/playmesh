// @ts-ignore
(function (global) {
  "use strict";

  const PLAYMESH_APP_SDK_VERSION = "3.0.0";
  const PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY =
    typeof Symbol === "function" && typeof Symbol.for === "function"
      ? Symbol.for("playmesh.platform-ui.configuration")
      : "__PLAYMESH_PLATFORM_UI_CONFIGURATION__";

  let sequence = 0;
  let bootstrap = null;
  const pending = new Map();
  const inputListeners = new Set();
  const capabilityInstances = new Map();

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
    if (!bootstrap) throw new Error("请先等待 playmesh.ready");
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

  let appUiReturnFocus = null;
  let appUiFocusCapturePending = false;

  function appUiError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
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
        // Fall through to the game document.
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
      // The host has already hidden the platform UI; no further fallback exists.
    } finally {
      if (previousTabIndex == null) {
        gameDocumentTarget.removeAttribute?.("tabindex");
      } else {
        gameDocumentTarget.setAttribute?.("tabindex", previousTabIndex);
      }
    }
  }

  function openAppSharePanel() {
    if (!global.navigator?.userActivation?.isActive) {
      return Promise.reject(appUiError(
        "user_activation_required",
        "打开分享界面需要当前用户操作",
      ));
    }
    captureAppUiReturnFocus();
    return request("app.ui.openSharePanel", { userActivation: true })
      .catch((error) => {
        clearAppUiReturnFocus();
        throw error;
      });
  }

  function showAppGameSidebar() {
    captureAppUiReturnFocus();
    return request("app.ui.gameSidebar.show").catch((error) => {
      clearAppUiReturnFocus();
      throw error;
    });
  }

  function hideAppGameSidebar() {
    return request("app.ui.gameSidebar.hide").then((result) => {
      restoreAppUiReturnFocus();
      return result;
    });
  }

  const playmeshApp = {
    version: PLAYMESH_APP_SDK_VERSION,
    ready: null,
    openSharePanel() {
      return openAppSharePanel();
    },
    showGameSidebar() {
      return showAppGameSidebar();
    },
    hideGameSidebar() {
      return hideAppGameSidebar();
    },
    exitGame() {
      return request("app.game.exit");
    },
    __requestExit() {
      return request("app.game.exit");
    },
    __restoreGameContentFocus() {
      restoreAppUiReturnFocus();
    },
    __syncAvatar(sessionId, credentialToken) {
      return request("app.identity.syncAvatar", { sessionId, credentialToken });
    },
    __confirmCapabilities() {
      return request("app.capabilities.confirm");
    },
    isAvailable() {
      return bootstrap?.available === true;
    },
    identity: {
      getCurrent() {
        return bootstrap ? clone(bootstrap.identity) : null;
      },
    },
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
    __receive: receive,
  };

  global.playmeshApp = playmeshApp;
  global.console?.info?.("Playmesh App SDK 注入成功", {
    version: PLAYMESH_APP_SDK_VERSION,
  });
  if (global.chrome?.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  const runtimeDeclaration = global.__PLAYMESH_BROWSER__;
  playmeshApp.ready = request("app.bootstrap", runtimeDeclaration ? {
    gameName: runtimeDeclaration.gameName,
    declaredCapabilities: runtimeDeclaration.requiredCapabilities || [],
  } : {}).then((result) => {
    const privateUi = result?._playmeshPlatformUi;
    if (privateUi && typeof privateUi === "object") {
      Object.defineProperty(global, PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY, {
        value: clone(privateUi),
        configurable: true,
        enumerable: false,
        writable: false,
      });
    } else {
      delete global[PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY];
    }
    bootstrap = result && typeof result === "object"
      ? { ...result }
      : result;
    if (bootstrap && typeof bootstrap === "object") {
      delete bootstrap._playmeshPlatformUi;
    }
    global.console?.info?.("Playmesh App SDK 就绪");
    return clone(bootstrap);
  }).catch((error) => {
    delete global[PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY];
    bootstrap = {
      available: false,
      identity: null,
      game: { name: "Playmesh 游戏", requiredCapabilities: [] },
      capabilityRegistry: [],
      device: { platform: "browser", capabilities: [], declaredCapabilities: [] },
      error: error?.message || String(error),
    };
    return clone(bootstrap);
  });
})(window);
