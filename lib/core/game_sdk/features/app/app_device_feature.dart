part of '../../sdk_feature_registry.dart';

const appDeviceSdkSource = SdkSourceFragment(
  id: 'app.device',
  target: SdkSourceTarget.app,
  order: 30,
  typeScript: r'''
  const playmeshApp = {
    version: PLAYMESH_APP_SDK_VERSION,
    ready: null,
    __requestExit() {
      return exitAppUiGame();
    },
    __restoreGameContentFocus() {
      restoreAppUiReturnFocus();
    },
    __handleNativeBack() {
      return handleAppUiNativeBack();
    },
    __syncAvatar(sessionId, credentialToken) {
      return request("app.identity.syncAvatar", { sessionId, credentialToken });
    },
    __confirmCapabilities() {
      return request("app.capabilities.confirm");
    },
    __configureRuntimeGame(declaration) {
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
        return clone(bootstrap);
      });
    },
    __registerRuntimeUi(adapter) {
      registerAppUiRuntimeAdapter(adapter);
    },
    __refreshRuntimeUi() {
      refreshAppFallbackUi();
      refreshAppUiPerformance();
    },
    __configurePlatformUi(configuration) {
      initializeAppPlatformUi({
        ...(configuration || {}),
        actions: appUiConfiguration?.actions,
      });
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
          return playmeshApp.device.setFullscreen(true, orientation);
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
    __receive: receive,
  };

  global.playmeshApp = playmeshApp;
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
  playmeshApp.ready = request("app.bootstrap").then((result) => {
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
    initializeAppPlatformUi(privateUi);
    requestAppInputTakeover();
    global.console?.info?.("Playmesh App SDK 就绪");
    return clone(bootstrap);
  }).catch((error) => {
    delete global[PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY];
    bootstrap = {
      available: false,
      identity: null,
      capabilityRegistry: [],
      device: { platform: "browser", capabilities: [], declaredCapabilities: [] },
      error: error?.message || String(error),
    };
    initializeAppPlatformUi(runtimePlatformUi);
    return clone(bootstrap);
  });
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
