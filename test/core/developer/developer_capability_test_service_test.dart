import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';
import 'package:playmesh/core/platform/app_sensor_service.dart';

void main() {
  test('能力测试清单与统一能力注册表对齐', () {
    final service = DeveloperCapabilityTestService(
      sensorSource: _CapabilitySensorSource(),
    );

    final items = service.describe();

    expect(items.map((item) => item['code']), [
      'sensor.accelerometer',
      'sensor.gyroscope',
    ]);
    expect(items.every((item) => item['testable'] == true), isTrue);
  });

  test('测试全部能力并返回首个传感器样本', () async {
    final service = DeveloperCapabilityTestService(
      sensorSource: _CapabilitySensorSource(),
    );

    final results = await service.run();

    expect(results, hasLength(2));
    expect(results.every((item) => item['status'] == 'passed'), isTrue);
    expect(results.first['sample'], isA<Map<String, Object?>>());
  });

  test('平台不可用能力返回 unavailable', () async {
    final service = DeveloperCapabilityTestService(
      sensorSource: _CapabilitySensorSource(availableTypes: const {}),
    );

    final results = await service.run(codes: ['sensor.accelerometer']);

    expect(results.single['status'], 'unavailable');
  });

  test('未知能力 code 拒绝执行', () async {
    final service = DeveloperCapabilityTestService(
      sensorSource: _CapabilitySensorSource(),
    );

    await expectLater(
      service.run(codes: ['sensor.unknown']),
      throwsFormatException,
    );
  });
}

class _CapabilitySensorSource implements AppSensorSource {
  _CapabilitySensorSource({
    this.availableTypes = const {
      AppSensorType.accelerometer,
      AppSensorType.gyroscope,
    },
  });

  @override
  final Set<AppSensorType> availableTypes;

  @override
  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  }) => Stream.value(
    AppSensorSample(
      type: type,
      x: 1,
      y: 2,
      z: 3,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1234),
    ),
  );
}
