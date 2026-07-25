import 'dart:async';

import '../capability_plugin.dart';
import 'motion_sensor_source.dart';

class MotionCapabilityInstance implements CapabilityInstance {
  MotionCapabilityInstance({required this.hub, required this.fps})
    : _id = 'motion-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';

  static int _sequence = 0;

  final MotionStreamHub hub;
  final int fps;
  final String _id;
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast(sync: true);
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async {
    if (_disposed) throw StateError('能力实例已释放');
    switch (method) {
      case 'start':
        if (_started) return null;
        await hub.subscribe(
          id: _id,
          fps: fps,
          onData: (sample) =>
              _events.add(CapabilityInstanceEvent('reading', sample.toJson())),
          onError: _events.addError,
        );
        _started = true;
        return null;
      case 'stop':
        if (!_started) return null;
        _started = false;
        await hub.unsubscribe(_id);
        return null;
      default:
        throw FormatException('动作传感器能力不支持方法：$method');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started) await hub.unsubscribe(_id);
    _started = false;
    await _events.close();
  }
}
