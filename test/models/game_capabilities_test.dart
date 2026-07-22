import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/models/game_capabilities.dart';
import 'package:playmesh/models/game_capability_registry.dart';

void main() {
  test('缺少文件时使用无权限能力定义', () {
    expect(const GameCapabilities().isEmpty, isTrue);
  });

  test('解析统一的必需能力 ID', () {
    final capabilities = GameCapabilities.fromJson({
      'required': ['sensor.accelerometer', 'sensor.gyroscope'],
    });

    expect(capabilities.required, {'sensor.accelerometer', 'sensor.gyroscope'});
    expect(capabilities.sensors, GameSensorCapability.values.toSet());
  });

  test('拒绝当前版本未知、重复或结构错误的能力', () {
    expect(
      () => GameCapabilities.fromJson({
        'required': ['media.camera'],
      }),
      throwsFormatException,
    );
    expect(
      () => GameCapabilities.fromJson({
        'required': ['sensor.accelerometer', 'sensor.accelerometer'],
      }),
      throwsFormatException,
    );
    expect(
      () => GameCapabilities.fromJson({'sensors': <Object?>[]}),
      throwsFormatException,
    );
  });

  test('能力注册表集中提供中文说明和 App HTML 适配状态', () {
    expect(
      gameCapabilityDefinitions.map((definition) => definition.code).toSet(),
      hasLength(gameCapabilityDefinitions.length),
    );
    final accelerometer =
        gameCapabilityRegistry[GameCapabilityCodes.accelerometer]!;
    expect(accelerometer.name, '加速度计');
    expect(accelerometer.description, isNotEmpty);
    expect(accelerometer.appSupported, isTrue);
    expect(accelerometer.htmlSupported, isFalse);
  });
}
