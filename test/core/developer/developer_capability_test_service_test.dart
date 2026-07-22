import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/support/motion_sensor_source.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';

void main() {
  test('能力测试清单来自完整平台注册表', () {
    final service = DeveloperCapabilityTestService(
      motionSource: const _CapabilityMotionSource(),
    );

    final items = service.describe();

    expect(items.map((item) => item['code']), [
      'sensor.accelerometer',
      'sensor.gyroscope',
    ]);
    expect(items.every((item) => item['testable'] == true), isTrue);
    expect(items.every((item) => item['apiVersion'] == '1.0.0'), isTrue);
    expect(items.every((item) => item['methods'] is List), isTrue);
  });

  test('省略 codes 时测试全平台注册表并返回插件测试结果', () async {
    final service = DeveloperCapabilityTestService(
      motionSource: const _CapabilityMotionSource(),
    );

    final results = await service.run();

    expect(results, hasLength(2));
    expect(results.every((item) => item['status'] == 'passed'), isTrue);
    expect(results.first['sample'], isA<Map<String, Object?>>());
  });

  test('平台不可用能力返回 unavailable', () async {
    final service = DeveloperCapabilityTestService(
      motionSource: const _CapabilityMotionSource(available: false),
    );

    final results = await service.run(codes: ['sensor.accelerometer']);

    expect(results.single['status'], 'unavailable');
  });

  test('未知能力 code 拒绝执行', () async {
    final service = DeveloperCapabilityTestService(
      motionSource: const _CapabilityMotionSource(),
    );

    await expectLater(
      service.run(codes: ['sensor.unknown']),
      throwsFormatException,
    );
  });
}

class _CapabilityMotionSource implements MotionSensorSource {
  const _CapabilityMotionSource({this.available = true});

  final bool available;

  @override
  bool get accelerometerAvailable => available;

  @override
  bool get gyroscopeAvailable => available;

  @override
  Stream<MotionSample> accelerometerEvents(Duration samplingPeriod) =>
      Stream.value(_sample('m/s^2'));

  @override
  Stream<MotionSample> gyroscopeEvents(Duration samplingPeriod) =>
      Stream.value(_sample('rad/s'));

  MotionSample _sample(String unit) => MotionSample(
    x: 1,
    y: 2,
    z: 3,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1234),
    unit: unit,
  );
}
