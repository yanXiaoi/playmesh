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
      return request("app.game.exit");
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
    bootstrap = result;
    global.console?.info?.("Playmesh App SDK 就绪");
    return clone(result);
  }).catch((error) => {
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
  Set<String> get commands => const {'app.device.fullscreen', 'app.game.exit'};

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
    }
    throw StateError('未注册的 App 设备命令: ${command.name}');
  }
}
