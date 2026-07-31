import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/app_media/app_media_adapter.dart';
import 'package:playmesh/core/app_media/app_media_runtime.dart';
import 'package:playmesh/core/capabilities/capability_plugin.dart';
import 'package:playmesh/core/capabilities/pose6d/pose6d_capability_plugin.dart';
import 'package:playmesh/core/capabilities/web_permission/web_permission_platform_authorizer.dart';

void main() {
  test('pose6d 描述符公开位姿、重置原点与媒体源契约', () {
    final descriptor = Pose6dCapabilityPlugin.capabilityDescriptor;

    expect(descriptor.code, 'sensor.pose6d');
    expect(descriptor.apiVersion, '1.0.0');
    expect(
      descriptor.methods.map((method) => method.name),
      containsAll(['recenter', 'openVideo', 'createVideoSource']),
    );
    expect(descriptor.events.map((event) => event.name), ['pose']);
  });

  test('多个实例共享驱动并以最高订阅频率更新原生采样', () async {
    final driver = _FakePose6dDriver();
    final hub = Pose6dHub(driver);
    final plugin = Pose6dCapabilityPlugin(
      hub: hub,
      mediaSourceBroker: _FakeMediaBroker(),
      permissionAuthorizer: _AllowPermissionAuthorizer(),
    );
    addTearDown(plugin.dispose);

    final slow = await plugin.create({'rateHz': 15});
    final fast = await plugin.create({'rateHz': 60});

    expect(driver.startRates, [15]);
    expect(driver.updatedRates, [60]);

    await fast.dispose();
    expect(driver.updatedRates, [60, 15]);
    expect(driver.stopCount, 0);
    await slow.dispose();
    expect(driver.stopCount, 1);
  });

  test('实例按自身原点输出相对位姿并在释放时回收媒体源', () async {
    final driver = _FakePose6dDriver();
    final mediaBroker = _FakeMediaBroker();
    final plugin = Pose6dCapabilityPlugin(
      hub: Pose6dHub(driver),
      mediaSourceBroker: mediaBroker,
      permissionAuthorizer: _AllowPermissionAuthorizer(),
    );
    addTearDown(plugin.dispose);
    final instance = await plugin.create({'rateHz': 60});
    final received = <CapabilityInstanceEvent>[];
    final subscription = instance.events.listen(received.add);
    addTearDown(subscription.cancel);

    driver.emit(
      _pose(
        timestamp: '100',
        position: const [1, 0, 0],
        rotation: const [0, 0, 0, 1],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await instance.invoke('recenter', {});
    driver.emit(
      _pose(
        timestamp: '200',
        position: const [2, 0, 0],
        rotation: const [0, 0, 0, 1],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relative = received.last.data;
    expect(relative['position'], [1.0, 0.0, 0.0]);
    expect(relative['rotation'], [0.0, 0.0, 0.0, 1.0]);

    final source =
        await instance.invoke('openVideo', {
              'width': 1280,
              'height': 720,
              'fps': 30,
            })
            as Map<String, Object?>;
    expect(source['type'], appMediaSourceType);
    expect(mediaBroker.lastSourceOptions, {
      'width': 1280,
      'height': 720,
      'fps': 30,
    });

    await instance.dispose();
    expect(mediaBroker.releasedIds, [source['id']]);
  });

  test('pose6d 拒绝越界参数和未授权相机', () async {
    final driver = _FakePose6dDriver();
    final plugin = Pose6dCapabilityPlugin(
      hub: Pose6dHub(driver),
      mediaSourceBroker: _FakeMediaBroker(),
      permissionAuthorizer: _DenyPermissionAuthorizer(),
    );
    addTearDown(plugin.dispose);

    expect(() => plugin.create({'rateHz': 0}), throwsFormatException);
    expect(() => plugin.create({'unknown': true}), throwsFormatException);
    expect(() => plugin.create({'rateHz': 30}), throwsStateError);
  });
}

Map<String, Object?> _pose({
  required String timestamp,
  required List<num> position,
  required List<num> rotation,
}) => {
  'captureTimestampNs': timestamp,
  'trackingState': 'tracking',
  'position': position,
  'rotation': rotation,
};

final class _FakePose6dDriver implements Pose6dPlatformDriver {
  final StreamController<Pose6dJson> _events = StreamController.broadcast();
  final List<int> startRates = [];
  final List<int> updatedRates = [];
  int stopCount = 0;

  @override
  Stream<Pose6dJson> get events => _events.stream;

  void emit(Pose6dJson event) => _events.add(event);

  @override
  Future<void> start(int rateHz) async {
    startRates.add(rateHz);
  }

  @override
  Future<void> updateRate(int rateHz) async {
    updatedRates.add(rateHz);
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

final class _FakeMediaBroker implements AppMediaSourceBroker {
  int _sequence = 0;
  AppMediaJson? lastSourceOptions;
  final List<Object?> releasedIds = [];

  @override
  Future<AppMediaJson> createSource({
    required String producer,
    required String kind,
    AppMediaJson sourceOptions = const <String, Object?>{},
    AppMediaJson adapterOptions = const <String, Object?>{},
  }) async {
    lastSourceOptions = sourceOptions;
    return {
      'type': appMediaSourceType,
      'version': appMediaSourceVersion,
      'id': 'source-${++_sequence}',
      'kind': kind,
      'protocol': 'fake',
      'live': true,
    };
  }

  @override
  Future<void> releaseSource(AppMediaJson source) async {
    releasedIds.add(source['id']);
  }
}

final class _AllowPermissionAuthorizer
    implements WebPermissionPlatformAuthorizer {
  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async => true;
}

final class _DenyPermissionAuthorizer
    implements WebPermissionPlatformAuthorizer {
  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async => false;
}
