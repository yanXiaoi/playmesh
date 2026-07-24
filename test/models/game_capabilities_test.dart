import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/default_capability_plugins.dart';
import 'package:playmesh/models/game_capabilities.dart';

void main() {
  test('缺少文件时使用空能力声明', () {
    expect(const GameCapabilities().isEmpty, isTrue);
  });

  test('解析统一的必需能力 code', () {
    final capabilities = GameCapabilities.fromJson({
      'required': [
        'sensor.accelerometer',
        'sensor.gyroscope',
        'device.vibration',
      ],
      'controllerRequired': ['device.vibration'],
    });

    expect(capabilities.required, {
      'sensor.accelerometer',
      'sensor.gyroscope',
      'device.vibration',
    });
    expect(capabilities.controllerRequired, {'device.vibration'});
    expect(capabilities.requiredForRole(controller: false), {
      'sensor.accelerometer',
      'sensor.gyroscope',
      'device.vibration',
    });
    expect(capabilities.requiredForRole(controller: true), {
      'device.vibration',
    });
  });

  test('主画面空声明不会回退到控制器声明', () {
    final capabilities = GameCapabilities.fromJson({
      'required': <String>[],
      'controllerRequired': [
        'sensor.accelerometer',
        'sensor.gyroscope',
        'device.vibration',
      ],
    });

    expect(capabilities.requiredForRole(controller: false), isEmpty);
    expect(capabilities.requiredForRole(controller: true), {
      'sensor.accelerometer',
      'sensor.gyroscope',
      'device.vibration',
    });
  });

  test('拒绝未注册、重复或结构错误的能力声明', () {
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

  test('插件描述符 code 唯一并公开方法、事件和平台状态', () {
    expect(
      defaultCapabilityDescriptors.map((item) => item.code).toSet(),
      hasLength(defaultCapabilityDescriptors.length),
    );
    final accelerometer =
        defaultCapabilityDescriptorRegistry['sensor.accelerometer']!;
    expect(accelerometer.name, '加速度计');
    expect(accelerometer.methods.map((item) => item.name), ['start', 'stop']);
    expect(accelerometer.events.single.name, 'reading');
    expect(accelerometer.appSupported, isTrue);
    expect(accelerometer.htmlSupported, isFalse);
    final vibration = defaultCapabilityDescriptorRegistry['device.vibration']!;
    expect(vibration.name, '震动反馈');
    expect(vibration.methods.single.name, 'vibrate');
    expect(vibration.events, isEmpty);
  });
}
