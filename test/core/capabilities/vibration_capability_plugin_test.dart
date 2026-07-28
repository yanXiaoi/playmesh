import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/vibration/vibration_capability_plugin.dart';

void main() {
  test('震动插件公开 vibration 的完整参数和 cancel 契约', () {
    final descriptor = VibrationCapabilityPlugin.capabilityDescriptor;

    expect(descriptor.code, 'device.vibration');
    expect(descriptor.apiVersion, '2.0.0');
    expect(descriptor.methods.map((method) => method.name), [
      'vibrate',
      'cancel',
    ]);
    final properties =
        descriptor.methods.first.argumentsSchema['properties']
            as Map<String, Object?>;
    expect(properties.keys, {
      'duration',
      'pattern',
      'repeat',
      'intensities',
      'amplitude',
      'sharpness',
      'preset',
    });
    expect(descriptor.events, isEmpty);
  });

  test('vibrate 默认参数和所有可选参数均转发给 vibration 驱动', () async {
    final driver = _RecordingVibrationDriver();
    final plugin = VibrationCapabilityPlugin(driver: driver);
    final instance = await plugin.create(const {});
    addTearDown(plugin.dispose);

    await instance.invoke('vibrate', const {});
    await instance.invoke('vibrate', {
      'duration': 1200,
      'pattern': [0, 100, 50, 200],
      'repeat': 1,
      'intensities': [0, 80, 0, 255],
      'amplitude': 128,
      'sharpness': 0.75,
      'preset': 'quickSuccessAlert',
    });

    expect(driver.vibrations, [
      const _VibrationCall(
        duration: 500,
        pattern: [],
        repeat: -1,
        intensities: [],
        amplitude: -1,
        sharpness: 0.5,
        preset: null,
      ),
      const _VibrationCall(
        duration: 1200,
        pattern: [0, 100, 50, 200],
        repeat: 1,
        intensities: [0, 80, 0, 255],
        amplitude: 128,
        sharpness: 0.75,
        preset: 'quickSuccessAlert',
      ),
    ]);
  });

  test('cancel 和实例释放都会取消持续震动', () async {
    final driver = _RecordingVibrationDriver();
    final plugin = VibrationCapabilityPlugin(driver: driver);
    final instance = await plugin.create(const {});

    await instance.invoke('cancel', const {});
    await instance.dispose();

    expect(driver.cancelCount, 2);
  });

  test('震动插件拒绝未知、越界和不匹配的参数', () async {
    final plugin = VibrationCapabilityPlugin(
      driver: _RecordingVibrationDriver(),
    );
    final instance = await plugin.create(const {});
    addTearDown(plugin.dispose);

    await expectLater(
      instance.invoke('vibrate', {'amplitude': 0}),
      throwsFormatException,
    );
    await expectLater(
      instance.invoke('vibrate', {
        'pattern': [0, 100],
        'intensities': [255],
      }),
      throwsFormatException,
    );
    await expectLater(
      instance.invoke('vibrate', {
        'pattern': [0, 100],
        'repeat': 2,
      }),
      throwsFormatException,
    );
    await expectLater(
      instance.invoke('vibrate', {'preset': 'unknown'}),
      throwsFormatException,
    );
    await expectLater(
      instance.invoke('cancel', {'force': true}),
      throwsFormatException,
    );
    await expectLater(plugin.create({'duration': 100}), throwsFormatException);
  });

  test('自检读取 vibration 插件能力但不产生震动', () async {
    final driver = _RecordingVibrationDriver();
    final plugin = VibrationCapabilityPlugin(driver: driver);

    final result = await plugin.test(const Duration(seconds: 1));

    expect(result['available'], isTrue);
    expect(result['hasAmplitudeControl'], isTrue);
    expect(result['hasCustomVibrationsSupport'], isTrue);
    expect(result['sideEffectExecuted'], isFalse);
    expect(driver.vibrations, isEmpty);
  });
}

class _RecordingVibrationDriver implements VibrationDriver {
  final List<_VibrationCall> vibrations = [];
  int cancelCount = 0;

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
    vibrations.add(
      _VibrationCall(
        duration: duration,
        pattern: pattern,
        repeat: repeat,
        intensities: intensities,
        amplitude: amplitude,
        sharpness: sharpness,
        preset: preset,
      ),
    );
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

class _VibrationCall {
  const _VibrationCall({
    required this.duration,
    required this.pattern,
    required this.repeat,
    required this.intensities,
    required this.amplitude,
    required this.sharpness,
    required this.preset,
  });

  final int duration;
  final List<int> pattern;
  final int repeat;
  final List<int> intensities;
  final int amplitude;
  final double sharpness;
  final String? preset;

  @override
  bool operator ==(Object other) =>
      other is _VibrationCall &&
      duration == other.duration &&
      _listEquals(pattern, other.pattern) &&
      repeat == other.repeat &&
      _listEquals(intensities, other.intensities) &&
      amplitude == other.amplitude &&
      sharpness == other.sharpness &&
      preset == other.preset;

  @override
  int get hashCode => Object.hash(
    duration,
    Object.hashAll(pattern),
    repeat,
    Object.hashAll(intensities),
    amplitude,
    sharpness,
    preset,
  );
}

bool _listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
