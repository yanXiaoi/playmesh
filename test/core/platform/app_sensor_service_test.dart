import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/platform/app_sensor_service.dart';

void main() {
  test('同一传感器共用原生流并按监听器最高 fps 调整采样', () async {
    final source = _RecordingSensorSource();
    final hub = AppSensorHub(source: source);
    addTearDown(hub.clear);

    await hub.subscribe(
      subscriptionId: 'slow',
      type: AppSensorType.gyroscope,
      fps: 10,
      onData: (_) {},
      onError: (_) {},
    );
    await hub.subscribe(
      subscriptionId: 'fast',
      type: AppSensorType.gyroscope,
      fps: 50,
      onData: (_) {},
      onError: (_) {},
    );
    await hub.unsubscribe('fast');
    await hub.unsubscribe('slow');

    expect(source.requestedTypes, [
      AppSensorType.gyroscope,
      AppSensorType.gyroscope,
      AppSensorType.gyroscope,
    ]);
    expect(source.samplingPeriods, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 20),
      const Duration(milliseconds: 100),
    ]);
    expect(source.activeListeners, 0);
  });
}

class _RecordingSensorSource implements AppSensorSource {
  _RecordingSensorSource() {
    _controller = StreamController<AppSensorSample>.broadcast(
      sync: true,
      onListen: () => activeListeners += 1,
      onCancel: () => activeListeners -= 1,
    );
  }

  late final StreamController<AppSensorSample> _controller;
  final List<AppSensorType> requestedTypes = [];
  final List<Duration> samplingPeriods = [];
  int activeListeners = 0;

  @override
  Set<AppSensorType> get availableTypes => AppSensorType.values.toSet();

  @override
  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  }) {
    requestedTypes.add(type);
    samplingPeriods.add(samplingPeriod);
    return _controller.stream.where((sample) => sample.type == type);
  }
}
