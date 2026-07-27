import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/support/motion_sensor_source.dart';
import 'package:playmesh/core/game_sdk/app_webview_bridge.dart';
import 'package:playmesh/core/platform/app_device_service.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  test('bootstrap 返回项目声明、平台注册表和当前可用插件', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-current-app',
      nickname: '本机玩家',
      gameName: '体感测试',
      declaredCapabilities: const ['sensor.accelerometer'],
      motionSource: _FakeMotionSource(),
    );
    addTearDown(bridge.close);

    final response = await _command(bridge, 'app.bootstrap', 'bootstrap');
    final result = response['result']! as Map<String, Object?>;
    final identity = result['identity']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;
    final registry = result['capabilityRegistry']! as List<Object?>;

    expect(result['available'], isTrue);
    expect(identity['userId'], 'u-current-app');
    expect(device['capabilities'], ['sensor.accelerometer']);
    expect(device['declaredCapabilities'], ['sensor.accelerometer']);
    expect(registry, hasLength(3));
    expect(registry, everyElement(contains('methods')));
  });

  test('远程 App 入口由本机 SDK 接收游戏声明和回环 Core 地址', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-remote-app',
      nickname: '远程玩家',
      acceptRuntimeGameDeclaration: true,
      coreBaseUri: Uri.parse('http://127.0.0.1:45678/'),
      playerSource: 'server',
      motionSource: _FakeMotionSource(),
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.bootstrap',
      'remote-bootstrap',
      payload: {
        'gameName': '权威主机游戏',
        'declaredCapabilities': ['sensor.gyroscope'],
      },
    );
    final result = response['result']! as Map<String, Object?>;
    final game = result['game']! as Map<String, Object?>;
    final runtime = result['runtime']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;

    expect(game['name'], '权威主机游戏');
    expect(game['requiredCapabilities'], ['sensor.gyroscope']);
    expect(device['declaredCapabilities'], ['sensor.gyroscope']);
    expect(device['capabilities'], ['sensor.gyroscope']);
    expect(runtime['coreBase'], 'http://127.0.0.1:45678/');
    expect(runtime['playerSource'], 'server');
  });

  test('通用能力实例通过 create/invoke/event/dispose 工作', () async {
    final source = _FakeMotionSource();
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '体感玩家',
      declaredCapabilities: const ['sensor.accelerometer'],
      motionSource: source,
    );
    addTearDown(bridge.close);
    final messages = <Map<String, Object?>>[];

    await _command(bridge, 'app.capabilities.confirm', 'confirm');
    final create = await _command(
      bridge,
      'app.capability.create',
      'create',
      payload: {
        'code': 'sensor.accelerometer',
        'options': {'fps': 20},
      },
      messages: messages,
    );
    final instanceId =
        (create['result']! as Map<String, Object?>)['instanceId']! as String;

    await _command(
      bridge,
      'app.capability.invoke',
      'start',
      payload: {
        'instanceId': instanceId,
        'method': 'start',
        'arguments': <String, Object?>{},
      },
      messages: messages,
    );
    source.add(
      MotionSample(
        x: 1,
        y: 2,
        z: 3,
        timestamp: DateTime.fromMillisecondsSinceEpoch(123),
        unit: 'm/s^2',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 65));

    final event = messages.firstWhere(
      (message) => message['type'] == 'app.capability.event',
    );
    expect(event['instanceId'], instanceId);
    expect(event['event'], 'reading');
    expect(event['data'], containsPair('unit', 'm/s^2'));
    expect(
      source.accelerometerPeriods.single,
      const Duration(milliseconds: 50),
    );

    await _command(
      bridge,
      'app.capability.dispose',
      'dispose',
      payload: {'instanceId': instanceId},
    );
  });

  test('未声明或未确认时拒绝创建插件实例', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '玩家',
      declaredCapabilities: const ['sensor.gyroscope'],
      motionSource: _FakeMotionSource(),
    );
    addTearDown(bridge.close);

    final undeclared = await _command(
      bridge,
      'app.capability.create',
      'undeclared',
      payload: {'code': 'sensor.accelerometer', 'options': <String, Object?>{}},
    );
    expect(undeclared['type'], 'app.command.error');
    expect(undeclared['error'], contains('sensor.accelerometer'));

    final unconfirmed = await _command(
      bridge,
      'app.capability.create',
      'unconfirmed',
      payload: {'code': 'sensor.gyroscope', 'options': <String, Object?>{}},
    );
    expect(unconfirmed['type'], 'app.command.error');
    expect(unconfirmed['error'], contains('能力确认'));
  });

  test('震动能力通过通用插件实例调用原生触觉服务', () async {
    final deviceService = _FakeDeviceService();
    final bridge = AppWebViewBridge(
      userId: 'u-haptic',
      nickname: '震动玩家',
      declaredCapabilities: const ['device.vibration'],
      deviceService: deviceService,
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
        'arguments': {'style': 'heavy'},
      },
    );

    expect(invoke['type'], 'app.command.result');
    expect(deviceService.styles, ['heavy']);
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

  test('App 级平台 UI 命令统一转发分享与游戏工具回调', () async {
    var shareCount = 0;
    final toolDockVisibility = <bool>[];
    final bridge = AppWebViewBridge(
      userId: 'u-app-ui',
      nickname: '玩家',
      onOpenSharePanel: () async => shareCount += 1,
      onShowToolDock: () async => toolDockVisibility.add(true),
      onHideToolDock: () async => toolDockVisibility.add(false),
    );
    addTearDown(bridge.close);

    final share = await _command(
      bridge,
      'app.ui.openSharePanel',
      'share',
      payload: {'userActivation': true},
    );
    final show = await _command(bridge, 'app.ui.toolDock.show', 'tool-show');
    final hide = await _command(bridge, 'app.ui.toolDock.hide', 'tool-hide');

    expect(share['type'], 'app.command.result');
    expect(show['type'], 'app.command.result');
    expect(hide['type'], 'app.command.result');
    expect(shareCount, 1);
    expect(toolDockVisibility, [true, false]);
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

class _FakeMotionSource implements MotionSensorSource {
  final StreamController<MotionSample> _accelerometer =
      StreamController<MotionSample>.broadcast(sync: true);
  final StreamController<MotionSample> _gyroscope =
      StreamController<MotionSample>.broadcast(sync: true);
  final List<Duration> accelerometerPeriods = [];

  @override
  bool get accelerometerAvailable => true;

  @override
  bool get gyroscopeAvailable => true;

  void add(MotionSample sample) => _accelerometer.add(sample);

  @override
  Stream<MotionSample> accelerometerEvents(Duration samplingPeriod) {
    accelerometerPeriods.add(samplingPeriod);
    return _accelerometer.stream;
  }

  @override
  Stream<MotionSample> gyroscopeEvents(Duration samplingPeriod) =>
      _gyroscope.stream;
}

class _FakeDeviceService extends AppDeviceService {
  final List<String> styles = [];
  final List<({bool enabled, GameOrientation? orientation})> fullscreenCalls =
      [];

  @override
  bool get hapticsAvailable => true;

  @override
  Future<void> haptic(String style) async {
    styles.add(style);
  }

  @override
  Future<void> setFullscreen(
    bool enabled, {
    GameOrientation? orientation,
  }) async {
    fullscreenCalls.add((enabled: enabled, orientation: orientation));
  }
}
