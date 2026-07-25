import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../../platform/app_platform.dart';

class MotionSample {
  const MotionSample({
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
    required this.unit,
  });

  final double x;
  final double y;
  final double z;
  final DateTime timestamp;
  final String unit;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'z': z,
    'timestamp': timestamp.microsecondsSinceEpoch / 1000,
    'unit': unit,
  };
}

abstract interface class MotionSensorSource {
  bool get accelerometerAvailable;

  bool get gyroscopeAvailable;

  Stream<MotionSample> accelerometerEvents(Duration samplingPeriod);

  Stream<MotionSample> gyroscopeEvents(Duration samplingPeriod);
}

class NativeMotionSensorSource implements MotionSensorSource {
  const NativeMotionSensorSource();

  @override
  bool get accelerometerAvailable => isMobileAppPlatform;

  @override
  bool get gyroscopeAvailable => isMobileAppPlatform;

  @override
  Stream<MotionSample> accelerometerEvents(Duration samplingPeriod) {
    if (!accelerometerAvailable) {
      return Stream.error(UnsupportedError('当前平台不支持加速度计'));
    }
    return accelerometerEventStream(samplingPeriod: samplingPeriod).map(
      (event) => MotionSample(
        x: event.x,
        y: event.y,
        z: event.z,
        timestamp: event.timestamp,
        unit: 'm/s^2',
      ),
    );
  }

  @override
  Stream<MotionSample> gyroscopeEvents(Duration samplingPeriod) {
    if (!gyroscopeAvailable) {
      return Stream.error(UnsupportedError('当前平台不支持陀螺仪'));
    }
    return gyroscopeEventStream(samplingPeriod: samplingPeriod).map(
      (event) => MotionSample(
        x: event.x,
        y: event.y,
        z: event.z,
        timestamp: event.timestamp,
        unit: 'rad/s',
      ),
    );
  }
}

typedef MotionStreamFactory = Stream<MotionSample> Function(Duration period);

class MotionStreamHub {
  MotionStreamHub({required this.available, required this.openStream});

  final bool available;
  final MotionStreamFactory openStream;
  final Map<String, _MotionListener> _listeners = {};
  StreamSubscription<MotionSample>? _sourceSubscription;
  MotionSample? _latest;
  int? _sourceFps;

  Future<void> subscribe({
    required String id,
    required int fps,
    required void Function(MotionSample sample) onData,
    required void Function(Object error) onError,
  }) async {
    if (!available) throw UnsupportedError('当前平台不支持该动作传感器');
    if (_listeners.containsKey(id)) throw StateError('动作传感器实例已经启动');
    final listener = _MotionListener(
      fps: fps,
      onData: onData,
      onError: onError,
    );
    _listeners[id] = listener;
    listener.timer = Timer.periodic(_periodFor(fps), (_) {
      final latest = _latest;
      if (latest != null) listener.onData(latest);
    });
    try {
      await _reconfigure();
    } on Object {
      listener.timer?.cancel();
      _listeners.remove(id);
      rethrow;
    }
  }

  Future<void> unsubscribe(String id) async {
    final listener = _listeners.remove(id);
    if (listener == null) return;
    listener.timer?.cancel();
    await _reconfigure();
  }

  Future<void> _reconfigure() async {
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
    _sourceSubscription = openStream(_periodFor(nextFps)).listen(
      (sample) => _latest = sample,
      onError: (Object error) {
        for (final listener in _listeners.values.toList(growable: false)) {
          listener.onError(error);
        }
      },
    );
  }

  Future<void> dispose() async {
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

class _MotionListener {
  _MotionListener({
    required this.fps,
    required this.onData,
    required this.onError,
  });

  final int fps;
  final void Function(MotionSample sample) onData;
  final void Function(Object error) onError;
  Timer? timer;
}

Duration _periodFor(int fps) => Duration(microseconds: 1000000 ~/ fps);

int capabilityFps(Map<String, Object?> options) {
  final fps = options['fps'] ?? 30;
  if (fps is! num ||
      !fps.isFinite ||
      fps != fps.roundToDouble() ||
      fps < 1 ||
      fps > 120) {
    throw const FormatException('fps 必须是 1 到 120 的整数');
  }
  return fps.toInt();
}
