import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/app_webview_bridge.dart';
import 'package:playmesh/core/platform/app_sensor_service.dart';

void main() {
  test('App 桥接自动返回当前 App 身份和设备能力', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-current-app',
      nickname: '本机玩家',
      gameName: '体感测试',
      declaredCapabilities: const ['sensor.accelerometer'],
    );
    String? response;

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.bootstrap',
        'requestId': 'app-1',
        'payload': <String, Object?>{},
      }),
      (message) async => response = message,
    );

    final decoded = jsonDecode(response!) as Map<String, Object?>;
    final result = decoded['result']! as Map<String, Object?>;
    final identity = result['identity']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;
    final game = result['game']! as Map<String, Object?>;
    expect(result['available'], isTrue);
    expect(identity['userId'], 'u-current-app');
    expect(identity['nickname'], '本机玩家');
    expect(device['capabilities'], containsAll(['fullscreen', 'haptics']));
    expect(game['name'], '体感测试');
    expect(game['requiredCapabilities'], ['sensor.accelerometer']);
  });

  test('SDK 拒绝能力请求后可要求 App 退出当前游戏', () async {
    final exitRequested = Completer<void>();
    final bridge = AppWebViewBridge(
      userId: 'u-exit',
      nickname: '玩家',
      onExitRequested: () async => exitRequested.complete(),
    );
    String? response;

    await bridge.handleJavaScriptMessage(
      jsonEncode({'command': 'app.game.exit', 'requestId': 'exit-1'}),
      (message) async => response = message,
    );

    expect(
      jsonDecode(response!) as Map<String, Object?>,
      containsPair('type', 'app.command.result'),
    );
    await exitRequested.future.timeout(const Duration(seconds: 1));
  });

  test('只向网页开放游戏已声明且设备可用的传感器', () async {
    final source = _FakeSensorSource();
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '体感玩家',
      declaredCapabilities: const ['sensor.accelerometer'],
      sensorSource: source,
    );
    addTearDown(bridge.close);
    String? response;

    await bridge.handleJavaScriptMessage(
      jsonEncode({'command': 'app.bootstrap', 'requestId': 'app-bootstrap'}),
      (message) async => response = message,
    );

    final decoded = jsonDecode(response!) as Map<String, Object?>;
    final result = decoded['result']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;
    expect(device['capabilities'], contains('sensor.accelerometer'));
    expect(device['capabilities'], isNot(contains('sensor.gyroscope')));
    expect(device['declaredCapabilities'], ['sensor.accelerometer']);
  });

  test('按 fps tick 把最新传感器快照回调给 App SDK', () async {
    final source = _FakeSensorSource();
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '体感玩家',
      declaredCapabilities: const ['sensor.accelerometer'],
      sensorSource: source,
    );
    addTearDown(bridge.close);
    final messages = <Map<String, Object?>>[];

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.capabilities.confirm',
        'requestId': 'confirm-1',
      }),
      (message) async {
        messages.add(Map<String, Object?>.from(jsonDecode(message) as Map));
      },
    );

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.device.sensor.subscribe',
        'requestId': 'subscribe-1',
        'payload': {
          'subscriptionId': 'sensor-1',
          'type': 'accelerometer',
          'fps': 20,
        },
      }),
      (message) async {
        messages.add(Map<String, Object?>.from(jsonDecode(message) as Map));
      },
    );
    source.add(
      AppSensorSample(
        type: AppSensorType.accelerometer,
        x: 1,
        y: 2,
        z: 3,
        timestamp: DateTime.fromMillisecondsSinceEpoch(123),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 65));

    final dataMessage = messages.firstWhere(
      (message) => message['type'] == 'app.device.data',
    );
    final data = dataMessage['data']! as Map<String, Object?>;
    expect(data, containsPair('type', 'accelerometer'));
    expect(data, containsPair('x', 1.0));
    expect(data, containsPair('unit', 'm/s^2'));
    expect(source.samplingPeriods.single, const Duration(milliseconds: 50));
  });

  test('拒绝订阅 capabilities.json 未声明的传感器', () async {
    final source = _FakeSensorSource();
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '体感玩家',
      sensorSource: source,
    );
    addTearDown(bridge.close);
    String? response;

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.device.sensor.subscribe',
        'requestId': 'subscribe-denied',
        'payload': {
          'subscriptionId': 'sensor-denied',
          'type': 'gyroscope',
          'fps': 30,
        },
      }),
      (message) async => response = message,
    );

    final decoded = jsonDecode(response!) as Map<String, Object?>;
    expect(decoded['type'], 'app.command.error');
    expect(decoded['error'], contains('sensor.gyroscope'));
    expect(source.samplingPeriods, isEmpty);
  });

  test('已声明传感器仍需先完成本次 SDK 能力确认', () async {
    final source = _FakeSensorSource();
    final bridge = AppWebViewBridge(
      userId: 'u-sensor',
      nickname: '体感玩家',
      declaredCapabilities: const ['sensor.gyroscope'],
      sensorSource: source,
    );
    addTearDown(bridge.close);
    String? response;

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.device.sensor.subscribe',
        'requestId': 'subscribe-before-confirm',
        'payload': {
          'subscriptionId': 'sensor-before-confirm',
          'type': 'gyroscope',
          'fps': 30,
        },
      }),
      (message) async => response = message,
    );

    final decoded = jsonDecode(response!) as Map<String, Object?>;
    expect(decoded['type'], 'app.command.error');
    expect(decoded['error'], contains('能力确认'));
    expect(source.samplingPeriods, isEmpty);
  });
}

class _FakeSensorSource implements AppSensorSource {
  final StreamController<AppSensorSample> _events =
      StreamController<AppSensorSample>.broadcast(sync: true);
  final List<Duration> samplingPeriods = [];

  @override
  Set<AppSensorType> get availableTypes => AppSensorType.values.toSet();

  void add(AppSensorSample sample) => _events.add(sample);

  @override
  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  }) {
    samplingPeriods.add(samplingPeriod);
    return _events.stream.where((sample) => sample.type == type);
  }
}
