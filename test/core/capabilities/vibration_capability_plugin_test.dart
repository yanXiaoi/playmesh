import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/vibration/vibration_capability_plugin.dart';
import 'package:playmesh/core/platform/app_device_service.dart';

void main() {
  test('震动插件公开契约并调用原生触觉服务', () async {
    final service = _RecordingDeviceService();
    final plugin = VibrationCapabilityPlugin(deviceService: service);
    final instance = await plugin.create(const {});
    addTearDown(instance.dispose);

    final result = await instance.invoke('vibrate', {'style': 'medium'});

    expect(result, isNull);
    expect(service.styles, ['medium']);
    expect(plugin.descriptor.code, 'device.vibration');
    expect(plugin.descriptor.methods.single.name, 'vibrate');
    expect(plugin.descriptor.events, isEmpty);
  });

  test('震动插件拒绝未知强度和创建参数', () async {
    final plugin = VibrationCapabilityPlugin(
      deviceService: _RecordingDeviceService(),
    );
    final instance = await plugin.create(const {});
    addTearDown(instance.dispose);

    await expectLater(
      instance.invoke('vibrate', {'style': 'unknown'}),
      throwsFormatException,
    );
    await expectLater(
      plugin.create({'durationMs': 100}),
      throwsFormatException,
    );
  });

  test('自检只报告可用样式，不自动产生连续震动', () async {
    final service = _RecordingDeviceService();
    final plugin = VibrationCapabilityPlugin(deviceService: service);

    final result = await plugin.test(const Duration(seconds: 1));

    expect(result['available'], isTrue);
    expect(result['sideEffectExecuted'], isFalse);
    expect(service.styles, isEmpty);
  });
}

class _RecordingDeviceService extends AppDeviceService {
  final List<String> styles = [];

  @override
  bool get hapticsAvailable => true;

  @override
  Future<void> haptic(String style) async {
    styles.add(style);
  }
}
