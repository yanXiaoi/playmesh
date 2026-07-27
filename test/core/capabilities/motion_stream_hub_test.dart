import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/support/motion_sensor_source.dart';

void main() {
  test('同一插件共享原生流并按实例最高 fps 调整采样', () async {
    final source = _RecordingStreamFactory();
    final hub = MotionStreamHub(available: true, openStream: source.open);
    addTearDown(hub.dispose);

    await hub.subscribe(id: 'slow', fps: 10, onData: (_) {}, onError: (_) {});
    await hub.subscribe(id: 'fast', fps: 50, onData: (_) {}, onError: (_) {});
    await hub.unsubscribe('fast');
    await hub.unsubscribe('slow');

    expect(source.samplingPeriods, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 20),
      const Duration(milliseconds: 100),
    ]);
    expect(source.activeListeners, 0);
  });
}

class _RecordingStreamFactory {
  _RecordingStreamFactory() {
    _controller = StreamController<MotionSample>.broadcast(
      sync: true,
      onListen: () => activeListeners += 1,
      onCancel: () => activeListeners -= 1,
    );
  }

  late final StreamController<MotionSample> _controller;
  final List<Duration> samplingPeriods = [];
  int activeListeners = 0;

  Stream<MotionSample> open(Duration samplingPeriod) {
    samplingPeriods.add(samplingPeriod);
    return _controller.stream;
  }
}
