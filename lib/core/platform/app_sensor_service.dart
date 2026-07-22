import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../../models/game_capability_registry.dart';
import 'app_platform.dart';

enum AppSensorType {
  accelerometer('accelerometer', GameCapabilityCodes.accelerometer, 'm/s^2'),
  gyroscope('gyroscope', GameCapabilityCodes.gyroscope, 'rad/s');

  const AppSensorType(this.sdkValue, this.permission, this.unit);

  final String sdkValue;
  final String permission;
  final String unit;

  static AppSensorType fromSdkValue(String value) {
    return values.firstWhere(
      (type) => type.sdkValue == value,
      orElse: () => throw FormatException('不支持的设备传感器：$value'),
    );
  }
}

class AppSensorSample {
  const AppSensorSample({
    required this.type,
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
  });

  final AppSensorType type;
  final double x;
  final double y;
  final double z;
  final DateTime timestamp;

  Map<String, Object?> toJson() => {
    'type': type.sdkValue,
    'x': x,
    'y': y,
    'z': z,
    'timestamp': timestamp.microsecondsSinceEpoch / 1000,
    'unit': type.unit,
  };
}

abstract interface class AppSensorSource {
  Set<AppSensorType> get availableTypes;

  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  });
}

class NativeAppSensorSource implements AppSensorSource {
  const NativeAppSensorSource();

  @override
  Set<AppSensorType> get availableTypes {
    if (!isMobileAppPlatform) {
      return const {};
    }
    return AppSensorType.values.toSet();
  }

  @override
  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  }) {
    if (!availableTypes.contains(type)) {
      return Stream.error(UnsupportedError('当前平台不支持 ${type.sdkValue}'));
    }
    return switch (type) {
      AppSensorType.accelerometer =>
        accelerometerEventStream(samplingPeriod: samplingPeriod).map(
          (event) => AppSensorSample(
            type: type,
            x: event.x,
            y: event.y,
            z: event.z,
            timestamp: event.timestamp,
          ),
        ),
      AppSensorType.gyroscope =>
        gyroscopeEventStream(samplingPeriod: samplingPeriod).map(
          (event) => AppSensorSample(
            type: type,
            x: event.x,
            y: event.y,
            z: event.z,
            timestamp: event.timestamp,
          ),
        ),
    };
  }
}

typedef AppSensorDataCallback = void Function(AppSensorSample sample);
typedef AppSensorErrorCallback = void Function(Object error);

class AppSensorHub {
  AppSensorHub({AppSensorSource? source})
    : source = source ?? const NativeAppSensorSource();

  final AppSensorSource source;
  final Map<AppSensorType, _SensorRuntime> _runtimes = {};

  Set<AppSensorType> get availableTypes => source.availableTypes;

  Future<void> subscribe({
    required String subscriptionId,
    required AppSensorType type,
    required int fps,
    required AppSensorDataCallback onData,
    required AppSensorErrorCallback onError,
  }) async {
    if (!availableTypes.contains(type)) {
      throw UnsupportedError('当前设备不支持 ${type.sdkValue}');
    }
    if (_runtimes.values.any(
      (runtime) => runtime.hasSubscription(subscriptionId),
    )) {
      throw FormatException('传感器订阅 ID 已存在：$subscriptionId');
    }
    final runtime = _runtimes.putIfAbsent(
      type,
      () => _SensorRuntime(type: type, source: source),
    );
    await runtime.add(
      subscriptionId: subscriptionId,
      fps: fps,
      onData: onData,
      onError: onError,
    );
  }

  Future<void> unsubscribe(String subscriptionId) async {
    AppSensorType? emptyType;
    for (final entry in _runtimes.entries) {
      if (await entry.value.remove(subscriptionId)) {
        if (entry.value.isEmpty) emptyType = entry.key;
        break;
      }
    }
    if (emptyType != null) _runtimes.remove(emptyType);
  }

  Future<void> clear() async {
    final runtimes = _runtimes.values.toList(growable: false);
    _runtimes.clear();
    await Future.wait(runtimes.map((runtime) => runtime.close()));
  }
}

class _SensorRuntime {
  _SensorRuntime({required this.type, required this.source});

  final AppSensorType type;
  final AppSensorSource source;
  final Map<String, _SensorListener> _listeners = {};
  StreamSubscription<AppSensorSample>? _sourceSubscription;
  AppSensorSample? _latest;
  int? _sourceFps;

  bool get isEmpty => _listeners.isEmpty;

  bool hasSubscription(String id) => _listeners.containsKey(id);

  Future<void> add({
    required String subscriptionId,
    required int fps,
    required AppSensorDataCallback onData,
    required AppSensorErrorCallback onError,
  }) async {
    final listener = _SensorListener(
      fps: fps,
      onData: onData,
      onError: onError,
    );
    _listeners[subscriptionId] = listener;
    listener.timer = Timer.periodic(_periodFor(fps), (_) {
      final sample = _latest;
      if (sample != null) listener.onData(sample);
    });
    try {
      await _reconfigureSource();
    } on Object {
      listener.timer?.cancel();
      _listeners.remove(subscriptionId);
      rethrow;
    }
  }

  Future<bool> remove(String subscriptionId) async {
    final listener = _listeners.remove(subscriptionId);
    if (listener == null) return false;
    listener.timer?.cancel();
    await _reconfigureSource();
    return true;
  }

  Future<void> _reconfigureSource() async {
    final nextFps = _listeners.isEmpty
        ? null
        : _listeners.values
              .map((listener) => listener.fps)
              .reduce((left, right) => left > right ? left : right);
    if (nextFps == _sourceFps) return;
    await _sourceSubscription?.cancel();
    _sourceSubscription = null;
    _sourceFps = nextFps;
    _latest = null;
    if (nextFps == null) return;
    _sourceSubscription = source
        .events(type, samplingPeriod: _periodFor(nextFps))
        .listen(
          (sample) => _latest = sample,
          onError: (Object error) {
            for (final listener in _listeners.values.toList(growable: false)) {
              listener.onError(error);
            }
          },
        );
  }

  Future<void> close() async {
    for (final listener in _listeners.values) {
      listener.timer?.cancel();
    }
    _listeners.clear();
    await _sourceSubscription?.cancel();
    _sourceSubscription = null;
    _sourceFps = null;
    _latest = null;
  }
}

class _SensorListener {
  _SensorListener({
    required this.fps,
    required this.onData,
    required this.onError,
  });

  final int fps;
  final AppSensorDataCallback onData;
  final AppSensorErrorCallback onError;
  Timer? timer;
}

Duration _periodFor(int fps) => Duration(microseconds: 1000000 ~/ fps);
