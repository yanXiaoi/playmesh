import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/app_media/app_media_adapter.dart';
import 'package:playmesh/core/app_media/app_media_runtime.dart';
import 'package:playmesh/core/capabilities/camera/camera_capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_registry.dart';
import 'package:playmesh/core/capabilities/vibration/vibration_capability_plugin.dart';
import 'package:playmesh/core/capabilities/web_permission/web_permission_platform_authorizer.dart';
import 'package:playmesh/core/game_sdk/app_webview_bridge.dart';
import 'package:playmesh/core/platform/app_device_service.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  test('bootstrap 返回项目声明、平台注册表和当前可用插件', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-current-app',
      nickname: '本机玩家',
      declaredCapabilities: const ['device.vibration'],
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final response = await _command(bridge, 'app.bootstrap', 'bootstrap');
    final result = response['result']! as Map<String, Object?>;
    final identity = result['identity']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;
    final registry = result['capabilityRegistry']! as List<Object?>;

    expect(result['available'], isTrue);
    expect(result, isNot(contains('game')));
    expect(identity['userId'], 'u-current-app');
    expect(device['capabilities'], ['device.vibration']);
    expect(device['declaredCapabilities'], ['device.vibration']);
    expect(registry, hasLength(5));
    expect(registry, everyElement(contains('methods')));
    expect(
      registry.where(
        (item) => (item! as Map<String, Object?>)['code'] == 'media.camera',
      ),
      everyElement(containsPair('events', <Object?>[])),
    );
  });

  test('远程 App 入口由 Game SDK 单向配置终端能力声明', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-remote-app',
      nickname: '远程玩家',
      acceptRuntimeGameDeclaration: true,
      coreBaseUri: Uri.parse('http://127.0.0.1:45678/'),
      playerSource: 'server',
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final bootstrapResponse = await _command(
      bridge,
      'app.bootstrap',
      'remote-bootstrap',
    );
    final bootstrap = bootstrapResponse['result']! as Map<String, Object?>;
    final initialDevice = bootstrap['device']! as Map<String, Object?>;
    expect(bootstrap, isNot(contains('game')));
    expect(initialDevice['declaredCapabilities'], isEmpty);

    final configureResponse = await _command(
      bridge,
      'app.game.configure',
      'remote-game-configure',
      payload: {
        'declaredCapabilities': ['device.vibration'],
      },
    );
    final environment = configureResponse['result']! as Map<String, Object?>;
    final runtime = bootstrap['runtime']! as Map<String, Object?>;
    final device = environment['device']! as Map<String, Object?>;

    expect(device['declaredCapabilities'], ['device.vibration']);
    expect(device['capabilities'], ['device.vibration']);
    expect(bridge.runtimeDeclaredCapabilities, ['device.vibration']);
    expect(runtime['coreBase'], 'http://127.0.0.1:45678/');
    expect(runtime['playerSource'], 'server');

    await bridge.resetCapabilities();
    expect(bridge.runtimeDeclaredCapabilities, isEmpty);
  });

  test('App Bridge 统一按远程页面运行时声明路由 WebView 权限', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-web-permission',
      nickname: '远程玩家',
      acceptRuntimeGameDeclaration: true,
      capabilityRegistry: CapabilityRegistry([
        CameraCapabilityPlugin(
          webPermissionAuthorizer: _AllowWebPermissionAuthorizer(),
        ),
      ]),
    );
    addTearDown(bridge.close);

    expect(await bridge.authorizeWebPermissions(['camera']), isFalse);
    await _command(
      bridge,
      'app.game.configure',
      'configure-camera',
      payload: {
        'declaredCapabilities': ['media.camera'],
      },
    );
    expect(await bridge.authorizeWebPermissions(['camera']), isTrue);
    expect(await bridge.authorizeWebPermissions(['microphone']), isFalse);

    await bridge.resetCapabilities();
    expect(await bridge.authorizeWebPermissions(['camera']), isFalse);
  });

  test('未声明或未确认时拒绝创建插件实例', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-capability',
      nickname: '玩家',
      declaredCapabilities: const ['device.vibration'],
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final undeclared = await _command(
      bridge,
      'app.capability.create',
      'undeclared',
      payload: {'code': 'media.camera', 'options': <String, Object?>{}},
    );
    expect(undeclared['type'], 'app.command.error');
    expect(undeclared['error'], contains('media.camera'));

    final unconfirmed = await _command(
      bridge,
      'app.capability.create',
      'unconfirmed',
      payload: {'code': 'device.vibration', 'options': <String, Object?>{}},
    );
    expect(unconfirmed['type'], 'app.command.error');
    expect(unconfirmed['error'], contains('能力确认'));
  });

  test('震动能力通过通用插件实例调用原生触觉服务', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-haptic',
      nickname: '震动玩家',
      declaredCapabilities: const ['device.vibration'],
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    await _command(bridge, 'app.capabilities.confirm', 'confirm');
    final create = await _command(
      bridge,
      'app.capability.create',
      'create-vibration',
      payload: {'code': 'device.vibration', 'options': <String, Object?>{}},
    );
    final instanceId =
        (create['result']! as Map<String, Object?>)['instanceId']! as String;

    final invoke = await _command(
      bridge,
      'app.capability.invoke',
      'vibrate',
      payload: {
        'instanceId': instanceId,
        'method': 'vibrate',
        'arguments': {
          'pattern': [0, 80, 40, 120],
          'intensities': [0, 128, 0, 255],
          'repeat': -1,
        },
      },
    );

    expect(invoke['type'], 'app.command.result');
    expect(vibrationDriver.vibrateCount, 1);
    expect(vibrationDriver.lastPattern, [0, 80, 40, 120]);

    final cancel = await _command(
      bridge,
      'app.capability.invoke',
      'cancel-vibration',
      payload: {
        'instanceId': instanceId,
        'method': 'cancel',
        'arguments': <String, Object?>{},
      },
    );
    expect(cancel['type'], 'app.command.result');
    expect(vibrationDriver.cancelCount, 1);
  });

  test('App 媒体命令只转交独立 adapterOptions 并映射公共会话', () async {
    final adapter = _FakeAppMediaAdapter();
    final mediaRuntime = AppMediaRuntime([adapter]);
    final bridge = AppWebViewBridge(
      userId: 'u-media',
      nickname: '媒体玩家',
      mediaRuntime: mediaRuntime,
    );
    addTearDown(bridge.close);
    final source = await mediaRuntime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
      sourceOptions: const {'fps': 30},
    );

    final opened = await _command(
      bridge,
      'app.media.open',
      'open-media',
      payload: {
        'source': source,
        'adapterOptions': {
          'offer': {'type': 'offer', 'sdp': 'browser-offer'},
        },
      },
    );
    final result = opened['result']! as Map<String, Object?>;

    expect(opened['type'], 'app.command.result');
    expect(result['protocol'], 'fake');
    expect(result['sessionId'], startsWith('media-session-'));
    expect(adapter.openOptions, {
      'offer': {'type': 'offer', 'sdp': 'browser-offer'},
    });
    expect(source, isNot(contains('offer')));

    final closed = await _command(
      bridge,
      'app.media.close',
      'close-media',
      payload: {'sessionId': result['sessionId']},
    );
    expect(closed['type'], 'app.command.result');
    expect(adapter.closedSessions, ['private-session']);
  });

  test('网页请求退出时通知宿主', () async {
    final exitRequested = Completer<void>();
    final bridge = AppWebViewBridge(
      userId: 'u-exit',
      nickname: '玩家',
      onExitRequested: () async => exitRequested.complete(),
    );
    addTearDown(bridge.close);

    final response = await _command(bridge, 'app.game.exit', 'exit');

    expect(response['type'], 'app.command.result');
    await exitRequested.future.timeout(const Duration(seconds: 1));
  });

  test('App SDK 完成输入监听后明确通知宿主接管', () async {
    var takeoverCount = 0;
    final bridge = AppWebViewBridge(
      userId: 'u-input-takeover',
      nickname: '玩家',
      onInputTakeover: () => takeoverCount += 1,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.input.takeover',
      'input-takeover',
    );

    expect(response['type'], 'app.command.result');
    expect(takeoverCount, 1);
  });

  test('App 级平台 UI 只向宿主转发受限分享动作', () async {
    var shareCount = 0;
    final bridge = AppWebViewBridge(
      userId: 'u-app-ui',
      nickname: '玩家',
      onOpenSharePanel: () async => shareCount += 1,
    );
    addTearDown(bridge.close);

    final share = await _command(
      bridge,
      'app.ui.openSharePanel',
      'share',
      payload: {'userActivation': true},
    );
    final obsoleteSidebarCommand = await _command(
      bridge,
      'app.ui.gameSidebar.show',
      'sidebar-show',
    );

    expect(share['type'], 'app.command.result');
    expect(obsoleteSidebarCommand['type'], 'app.command.error');
    expect(obsoleteSidebarCommand['code'], isNull);
    expect(obsoleteSidebarCommand['error'], contains('未注册 App SDK 命令'));
    expect(shareCount, 1);
  });

  test('App 分享命令在缺少用户激活标识时返回稳定错误 code', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-app-ui',
      nickname: '玩家',
      onOpenSharePanel: () async {},
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.ui.openSharePanel',
      'share-denied',
    );

    expect(response['type'], 'app.command.error');
    expect(response['code'], 'user_activation_required');
  });

  test('全屏命令把控制器方向传给原生设备服务', () async {
    final deviceService = _FakeDeviceService();
    final bridge = AppWebViewBridge(
      userId: 'u-controller',
      nickname: 'Controller',
      deviceService: deviceService,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.device.fullscreen',
      'fullscreen',
      payload: {'enabled': true, 'orientation': 'portrait'},
    );

    expect(response['type'], 'app.command.result');
    expect(deviceService.fullscreenCalls, [
      (enabled: true, orientation: GameOrientation.portrait),
    ]);
  });
}

Future<Map<String, Object?>> _command(
  AppWebViewBridge bridge,
  String command,
  String requestId, {
  Map<String, Object?> payload = const {},
  List<Map<String, Object?>>? messages,
}) async {
  Map<String, Object?>? response;
  await bridge.handleJavaScriptMessage(
    jsonEncode({
      'command': command,
      'requestId': requestId,
      'payload': payload,
    }),
    (message) async {
      final decoded = Map<String, Object?>.from(jsonDecode(message) as Map);
      messages?.add(decoded);
      if (decoded['requestId'] == requestId) response = decoded;
    },
  );
  return response!;
}

class _FakeDeviceService extends AppDeviceService {
  final List<({bool enabled, GameOrientation? orientation})> fullscreenCalls =
      [];

  @override
  Future<void> setFullscreen(
    bool enabled, {
    GameOrientation? orientation,
  }) async {
    fullscreenCalls.add((enabled: enabled, orientation: orientation));
  }
}

class _FakeVibrationDriver implements VibrationDriver {
  int vibrateCount = 0;
  int cancelCount = 0;
  List<int>? lastPattern;

  @override
  bool get platformSupported => true;

  @override
  Future<bool> hasVibrator() async => true;

  @override
  Future<bool> hasAmplitudeControl() async => true;

  @override
  Future<bool> hasCustomVibrationsSupport() async => true;

  @override
  Future<void> vibrate({
    required int duration,
    required List<int> pattern,
    required int repeat,
    required List<int> intensities,
    required int amplitude,
    required double sharpness,
    required String? preset,
  }) async {
    vibrateCount += 1;
    lastPattern = pattern;
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

class _AllowWebPermissionAuthorizer implements WebPermissionPlatformAuthorizer {
  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async => true;
}

class _FakeAppMediaAdapter implements AppMediaAdapter {
  AppMediaJson? openOptions;
  final List<String> closedSessions = [];

  @override
  String get protocol => 'fake';

  @override
  int get priority => 1;

  @override
  bool get isAvailable => true;

  @override
  bool supportsProducer(String producer, String kind) =>
      producer == 'sensor.pose6d' && kind == 'video';

  @override
  Future<AppMediaAdapterSource> createSource(
    AppMediaSourceRequest request,
  ) async => const AppMediaAdapterSource(id: 'private-source');

  @override
  Future<AppMediaAdapterSession> open(
    AppMediaAdapterSource source,
    AppMediaJson adapterOptions,
  ) async {
    openOptions = adapterOptions;
    return const AppMediaAdapterSession(
      id: 'private-session',
      answer: {'type': 'answer', 'sdp': 'host-answer'},
    );
  }

  @override
  Future<void> close(String sessionId) async {
    closedSessions.add(sessionId);
  }

  @override
  Future<void> releaseSource(String sourceId) async {}

  @override
  Future<AppMediaJson> test(Duration timeout) async => const {};

  @override
  Future<void> dispose() async {}
}
