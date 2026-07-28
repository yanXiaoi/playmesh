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
        'media.camera',
        'media.microphone',
        'device.midi',
        'device.vibration',
      ],
      'controllerRequired': ['device.vibration'],
    });

    expect(capabilities.required, {
      'media.camera',
      'media.microphone',
      'device.midi',
      'device.vibration',
    });
    expect(capabilities.controllerRequired, {'device.vibration'});
    expect(capabilities.requiredForRole(controller: false), {
      'media.camera',
      'media.microphone',
      'device.midi',
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
        'media.camera',
        'media.microphone',
        'device.midi',
        'device.vibration',
      ],
    });

    expect(capabilities.requiredForRole(controller: false), isEmpty);
    expect(capabilities.requiredForRole(controller: true), {
      'media.camera',
      'media.microphone',
      'device.midi',
      'device.vibration',
    });
  });

  test('拒绝未注册、重复或结构错误的能力声明', () {
    expect(
      () => GameCapabilities.fromJson({
        'required': ['sensor.accelerometer'],
      }),
      throwsFormatException,
    );
    expect(
      () => GameCapabilities.fromJson({
        'required': ['media.camera', 'media.camera'],
      }),
      throwsFormatException,
    );
    expect(
      () => GameCapabilities.fromJson({'sensors': <Object?>[]}),
      throwsFormatException,
    );
  });

  test('静态开发上下文允许保留其他平台或旧版本的能力 code', () {
    final capabilities = GameCapabilities.fromJson({
      'required': ['sensor.accelerometer'],
      'controllerRequired': ['vendor.future-capability'],
    }, requireKnownCapabilities: false);

    expect(capabilities.required, {'sensor.accelerometer'});
    expect(capabilities.controllerRequired, {'vendor.future-capability'});
  });

  test('插件描述符 code 唯一并公开方法、事件和平台状态', () {
    expect(
      defaultCapabilityDescriptors.map((item) => item.code).toSet(),
      hasLength(defaultCapabilityDescriptors.length),
    );
    for (final code in const ['media.camera', 'device.midi']) {
      final permission = defaultCapabilityDescriptorRegistry[code]!;
      expect(permission.methods, isEmpty);
      expect(permission.events, isEmpty);
      expect(permission.appSupported, isTrue);
      expect(permission.htmlSupported, isFalse);
    }
    final audio = defaultCapabilityDescriptorRegistry['media.microphone']!;
    expect(audio.apiVersion, '1.1.0');
    expect(audio.methods.single.name, 'toText');
    expect(audio.events.map((event) => event.name), [
      'textOnSoundLevelChange',
      'textOnResult',
    ]);
    expect(audio.appSupported, isTrue);
    expect(audio.htmlSupported, isFalse);

    final vibration = defaultCapabilityDescriptorRegistry['device.vibration']!;
    expect(vibration.name, '震动反馈');
    expect(vibration.apiVersion, '2.0.0');
    expect(vibration.methods.map((method) => method.name), [
      'vibrate',
      'cancel',
    ]);
    expect(vibration.events, isEmpty);
  });
}
