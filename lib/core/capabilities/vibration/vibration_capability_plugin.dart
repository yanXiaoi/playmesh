import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';
import 'package:vibration/vibration_presets.dart';

import '../capability_plugin.dart';

abstract interface class VibrationDriver {
  bool get platformSupported;

  Future<bool> hasVibrator();

  Future<bool> hasAmplitudeControl();

  Future<bool> hasCustomVibrationsSupport();

  Future<void> vibrate({
    required int duration,
    required List<int> pattern,
    required int repeat,
    required List<int> intensities,
    required int amplitude,
    required double sharpness,
    required String? preset,
  });

  Future<void> cancel();
}

class NativeVibrationDriver implements VibrationDriver {
  const NativeVibrationDriver();

  @override
  bool get platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<bool> hasVibrator() => Vibration.hasVibrator();

  @override
  Future<bool> hasAmplitudeControl() => Vibration.hasAmplitudeControl();

  @override
  Future<bool> hasCustomVibrationsSupport() =>
      Vibration.hasCustomVibrationsSupport();

  @override
  Future<void> vibrate({
    required int duration,
    required List<int> pattern,
    required int repeat,
    required List<int> intensities,
    required int amplitude,
    required double sharpness,
    required String? preset,
  }) {
    return Vibration.vibrate(
      duration: duration,
      pattern: pattern,
      repeat: repeat,
      intensities: intensities,
      amplitude: amplitude,
      sharpness: sharpness,
      preset: preset == null ? null : VibrationPreset.values.byName(preset),
    );
  }

  @override
  Future<void> cancel() => Vibration.cancel();
}

class VibrationCapabilityPlugin implements CapabilityPlugin {
  VibrationCapabilityPlugin({required this.driver});

  static const code = 'device.vibration';
  static const supportedPresets = <String>[
    'singleShortBuzz',
    'doubleBuzz',
    'tripleBuzz',
    'longAlarmBuzz',
    'pulseWave',
    'progressiveBuzz',
    'rhythmicBuzz',
    'gentleReminder',
    'quickSuccessAlert',
    'zigZagAlert',
    'softPulse',
    'emergencyAlert',
    'heartbeatVibration',
    'countdownTimerAlert',
    'rapidTapFeedback',
    'dramaticNotification',
    'urgentBuzzWave',
  ];
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '震动反馈',
    description: '通过 vibration 插件触发或取消当前设备的跨平台震动。',
    apiVersion: '2.0.0',
    optionsSchema: {'type': 'object', 'additionalProperties': false},
    methods: [
      CapabilityMethodDescriptor(
        name: 'vibrate',
        description: '触发震动；支持默认震动、时长、振幅、波形、强度、重复、iOS 锐度和预设参数。',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            'duration': {'type': 'integer', 'minimum': 1, 'default': 500},
            'pattern': {
              'type': 'array',
              'items': {'type': 'integer', 'minimum': 0},
              'default': <int>[],
            },
            'repeat': {'type': 'integer', 'minimum': -1, 'default': -1},
            'intensities': {
              'type': 'array',
              'items': {'type': 'integer', 'minimum': 0, 'maximum': 255},
              'default': <int>[],
            },
            'amplitude': {
              'type': 'integer',
              'minimum': -1,
              'maximum': 255,
              'default': -1,
            },
            'sharpness': {
              'type': 'number',
              'minimum': 0,
              'maximum': 1,
              'default': 0.5,
            },
            'preset': {'type': 'string', 'enum': supportedPresets},
          },
          'additionalProperties': false,
        },
      ),
      CapabilityMethodDescriptor(
        name: 'cancel',
        description: '取消当前仍在进行或重复的震动。',
        argumentsSchema: {'type': 'object', 'additionalProperties': false},
      ),
    ],
    events: [],
  );

  final VibrationDriver driver;
  final Set<_VibrationCapabilityInstance> _instances = {};

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  bool get isAvailable => driver.platformSupported;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    if (options.isNotEmpty) {
      throw const FormatException('震动能力不接受创建参数');
    }
    if (!isAvailable) throw UnsupportedError('当前平台不支持 vibration 插件');
    late final _VibrationCapabilityInstance instance;
    instance = _VibrationCapabilityInstance(
      driver,
      onDisposed: () => _instances.remove(instance),
    );
    _instances.add(instance);
    return instance;
  }

  @override
  Future<CapabilityJson> test(Duration timeout) async {
    if (!isAvailable) throw UnsupportedError('当前平台不支持 vibration 插件');
    final results = await Future.wait([
      driver.hasVibrator(),
      driver.hasAmplitudeControl(),
      driver.hasCustomVibrationsSupport(),
    ]).timeout(timeout);
    return {
      'available': results[0],
      'hasAmplitudeControl': results[1],
      'hasCustomVibrationsSupport': results[2],
      'presets': supportedPresets,
      'sideEffectExecuted': false,
    };
  }

  @override
  Future<void> dispose() async {
    final instances = _instances.toList(growable: false);
    _instances.clear();
    await Future.wait(instances.map((instance) => instance.dispose()));
  }
}

class _VibrationCapabilityInstance implements CapabilityInstance {
  _VibrationCapabilityInstance(this.driver, {required this.onDisposed});

  final VibrationDriver driver;
  final void Function() onDisposed;
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async {
    if (_disposed) throw StateError('能力实例已释放');
    switch (method) {
      case 'vibrate':
        await _vibrate(arguments);
        return null;
      case 'cancel':
        if (arguments.isNotEmpty) {
          throw const FormatException('cancel 不接受参数');
        }
        await driver.cancel();
        return null;
      default:
        throw FormatException('震动能力不支持方法：$method');
    }
  }

  Future<void> _vibrate(CapabilityJson arguments) async {
    const allowedKeys = {
      'duration',
      'pattern',
      'repeat',
      'intensities',
      'amplitude',
      'sharpness',
      'preset',
    };
    if (arguments.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('vibrate 包含未知参数');
    }
    final duration = _integer(arguments, 'duration', 500);
    final pattern = _integerList(arguments, 'pattern');
    final repeat = _integer(arguments, 'repeat', -1);
    final intensities = _integerList(arguments, 'intensities');
    final amplitude = _integer(arguments, 'amplitude', -1);
    final sharpness = _number(arguments, 'sharpness', 0.5);
    final preset = arguments['preset'];

    if (duration < 1) {
      throw const FormatException('duration 必须是正整数毫秒');
    }
    if (pattern.any((value) => value < 0)) {
      throw const FormatException('pattern 只能包含非负整数毫秒');
    }
    if (repeat < -1 || (repeat >= 0 && repeat >= pattern.length)) {
      throw const FormatException('repeat 必须是 -1 或 pattern 内的有效索引');
    }
    if (intensities.any((value) => value < 0 || value > 255)) {
      throw const FormatException('intensities 只能包含 0 至 255 的整数');
    }
    if (intensities.isNotEmpty && intensities.length != pattern.length) {
      throw const FormatException('intensities 和 pattern 的长度必须相同');
    }
    if (amplitude != -1 && (amplitude < 1 || amplitude > 255)) {
      throw const FormatException('amplitude 必须是 -1 或 1 至 255 的整数');
    }
    if (sharpness < 0 || sharpness > 1) {
      throw const FormatException('sharpness 必须介于 0 和 1');
    }
    if (preset != null &&
        (preset is! String ||
            !VibrationCapabilityPlugin.supportedPresets.contains(preset))) {
      throw const FormatException('preset 不是 vibration 插件支持的预设');
    }

    await driver.vibrate(
      duration: duration,
      pattern: pattern,
      repeat: repeat,
      intensities: intensities,
      amplitude: amplitude,
      sharpness: sharpness,
      preset: preset as String?,
    );
  }

  static int _integer(CapabilityJson arguments, String name, int fallback) {
    final value = arguments[name] ?? fallback;
    if (value is! int) throw FormatException('$name 必须是整数');
    return value;
  }

  static double _number(
    CapabilityJson arguments,
    String name,
    double fallback,
  ) {
    final value = arguments[name] ?? fallback;
    if (value is! num) throw FormatException('$name 必须是数字');
    return value.toDouble();
  }

  static List<int> _integerList(CapabilityJson arguments, String name) {
    final value = arguments[name] ?? const <int>[];
    if (value is! List || value.any((item) => item is! int)) {
      throw FormatException('$name 必须是整数数组');
    }
    return List<int>.unmodifiable(value.cast<int>());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await driver.cancel();
    } finally {
      onDisposed();
      await _events.close();
    }
  }
}
