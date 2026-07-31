part of '../../sdk_feature_registry.dart';

const appDeviceSdkSource = SdkSourceFragment(
  id: 'app.device',
  target: SdkSourceTarget.app,
  order: 30,
  typeScript: r'''
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
    confirmCapabilities() {
      return request("app.capabilities.confirm");
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
      appPlatformUiConfiguration = null;
      initializeAppPlatformUi(runtimePlatformUi);
      global.console?.info?.("Playmesh App SDK 就绪");
      return appBootstrapResult;
    })
    : request("app.bootstrap").then((result) => {
      const privateUi = result?._playmeshPlatformUi;
      appPlatformUiConfiguration =
        privateUi && typeof privateUi === "object" ? clone(privateUi) : null;
      bootstrap = result && typeof result === "object"
        ? { ...result }
        : result;
      if (bootstrap && typeof bootstrap === "object") {
        delete bootstrap._playmeshPlatformUi;
      }
      initializeAppPlatformUi(privateUi);
      requestAppInputTakeover();
      global.console?.info?.("Playmesh App SDK 就绪");
      return appBootstrapResult;
    });
  Object.defineProperty(publicAppApi, "ready", {
    value: appReady,
    enumerable: true,
    writable: false,
  });
  Object.freeze(publicAppApi);
})(window);
''',
);

class _AppDeviceFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appDeviceSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.device.fullscreen',
    'app.game.exit',
    'app.identity.syncAvatar',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    switch (command.name) {
      case 'app.device.fullscreen':
        return context.setFullscreen(command.payload);
      case 'app.game.exit':
        return context.requestExit();
      case 'app.identity.syncAvatar':
        return context.syncAvatar(command.payload);
    }
    throw StateError('未注册的 App 设备命令: ${command.name}');
  }
}
