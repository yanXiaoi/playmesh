import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_game_advertisement.dart';
import 'package:playmesh/core/network/lan_game_discovery_platform.dart';
import 'package:playmesh/core/network/lan_game_discovery_service.dart';
import 'package:playmesh/core/network/lan_game_join_candidate_source.dart';
import 'package:playmesh/core/network/lan_game_multicast_protocol.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';

void main() {
  test('无地址的前 64 条记录不会占用有效实例上限', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();

    for (var index = 0; index < maxDiscoveredLanGames; index += 1) {
      discovery.add(
        _record(index, hostAddresses: const ['127.0.0.1'], name: '无效游戏 $index'),
      );
    }
    discovery.add(
      _record(999, hostAddresses: const ['192.168.1.99'], name: '有效游戏'),
    );

    expect(service.currentSnapshot.games, hasLength(1));
    expect(service.currentSnapshot.games.single.name, '有效游戏');
    expect(
      service.findJoinCandidates(_instanceId(999))?.candidates,
      hasLength(1),
    );
    await lease.close();
  });

  test('有效实例先稳定排序再截取 64 且秘密映射只覆盖可见项', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();

    for (var index = 69; index >= 0; index -= 1) {
      discovery.add(
        _record(
          index,
          hostAddresses: ['192.168.1.${index + 1}'],
          name: 'Game ${index.toString().padLeft(3, '0')}',
        ),
      );
    }

    final games = service.currentSnapshot.games;
    expect(games, hasLength(maxDiscoveredLanGames));
    expect(games.first.name, 'Game 000');
    expect(games.last.name, 'Game 063');
    expect(service.findJoinCandidates(_instanceId(63)), isNotNull);
    expect(service.findJoinCandidates(_instanceId(64)), isNull);
    await lease.close();
  });

  test('Service 二级记录缓存有硬上限并淘汰最久未更新项', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();

    for (var index = 0; index <= maxLanGameMulticastRecords; index += 1) {
      discovery.add(
        _record(
          index,
          hostAddresses: <String>['10.1.${index ~/ 250}.${index % 250 + 1}'],
          name: index == maxLanGameMulticastRecords
              ? 'A latest'
              : 'Z ${index.toString().padLeft(3, '0')}',
        ),
      );
    }

    expect(service.findJoinCandidates(_instanceId(0)), isNull);
    expect(
      service.findJoinCandidates(_instanceId(maxLanGameMulticastRecords)),
      isNotNull,
    );
    await lease.close();
  });

  test('发现候选只在最后一个 browse lease 释放前保持有效', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();
    discovery.add(
      _record(1, hostAddresses: const ['192.168.1.10'], name: '租约内可用游戏'),
    );

    expect(service.findJoinCandidates(_instanceId(1)), isNotNull);

    await lease.close();

    expect(service.currentSnapshot.state, LanGameDiscoveryState.scanning);
    expect(service.findJoinCandidates(_instanceId(1)), isNull);
  });

  test('只过滤本进程注册实例且重启扫描后仍保留过滤边界', () async {
    final firstDiscovery = _FakeDiscovery();
    final secondDiscovery = _FakeDiscovery();
    final platform = _SequenceRegistrationPlatform(<LanGamePlatformDiscovery>[
      firstDiscovery,
      secondDiscovery,
    ]);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final localAdvertisement = _advertisement(1);
    final firstLease = await service.startDiscovery();

    firstDiscovery.add(
      _advertisementRecord(
        localAdvertisement,
        platformId: 'before-local-registration',
        hostAddress: '192.168.1.20',
      ),
    );
    expect(
      service.currentSnapshot.games.single.instanceId,
      localAdvertisement.instanceId,
    );

    final registrationFuture = service.register(
      advertisement: localAdvertisement,
      port: 16667,
    );
    // register 在触发底层首个公告前同步记住 instance，回环包没有可见窗口。
    firstDiscovery.add(
      _advertisementRecord(
        localAdvertisement,
        platformId: 'looped-back-local-registration',
        hostAddress: '192.168.1.20',
      ),
    );
    final registration = await registrationFuture;
    expect(service.currentSnapshot.games, isEmpty);

    firstDiscovery.add(
      _record(91, hostAddresses: const ['192.168.1.20'], name: '同机其他进程'),
    );
    expect(service.currentSnapshot.games.single.instanceId, _instanceId(91));

    await firstLease.close();
    final secondLease = await service.startDiscovery();
    secondDiscovery.add(
      _advertisementRecord(
        localAdvertisement,
        platformId: 'local-after-browse-restart',
        hostAddress: '192.168.1.20',
      ),
    );
    expect(service.currentSnapshot.games, isEmpty);
    secondDiscovery.add(
      _record(92, hostAddresses: const ['192.168.1.20'], name: '重启扫描后的其他进程'),
    );
    expect(service.currentSnapshot.games.single.instanceId, _instanceId(92));

    expect(platform.registerCount, 1);
    await registration.close();
    await secondLease.close();
  });

  test('第 257 个活跃注册不会逐出仍活跃的本机 instance', () async {
    final discovery = _FakeDiscovery();
    final platform = _SequenceRegistrationPlatform(<LanGamePlatformDiscovery>[
      discovery,
    ]);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final advertisements = <LanGameAdvertisement>[];
    final registrations = <LanGameRegistrationLease>[];

    for (var index = 0; index <= 256; index += 1) {
      final advertisement = _indexedAdvertisement(index);
      advertisements.add(advertisement);
      registrations.add(
        await service.register(advertisement: advertisement, port: 16667),
      );
    }
    final discoveryLease = await service.startDiscovery();

    discovery.add(
      _advertisementRecord(
        advertisements.first,
        platformId: 'first-of-257-active-local-instances',
        hostAddress: '192.168.1.20',
      ),
    );

    expect(service.currentSnapshot.games, isEmpty);
    expect(platform.registerCount, 257);
    await registrations.first.close();
    discovery.add(
      _advertisementRecord(
        advertisements.first,
        platformId: 'late-after-first-of-257-closed',
        hostAddress: '192.168.1.20',
      ),
    );
    expect(service.currentSnapshot.games, isEmpty);
    for (final registration in registrations.skip(1)) {
      await registration.close();
    }
    await discoveryLease.close();
  });

  test('同 instance 旧 update 与 close 完成后才重新调用底层注册', () async {
    final calls = <String>[];
    final updateStarted = Completer<void>();
    final updateGate = Completer<void>();
    final closeStarted = Completer<void>();
    final closeGate = Completer<void>();
    final platform = _RegistrationSequenceWithDiscoveryPlatform(
      discovery: _FakeDiscovery(),
      calls: calls,
      registrations: <LanGamePlatformRegistration>[
        _BlockingUpdateCloseRegistration(
          calls: calls,
          updateStarted: updateStarted,
          updateGate: updateGate,
          closeStarted: closeStarted,
          closeGate: closeGate,
        ),
        _FakeRegistration(),
      ],
    );
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(() async {
      if (!updateGate.isCompleted) updateGate.complete();
      if (!closeGate.isCompleted) closeGate.complete();
      await service.dispose();
    });
    final advertisement = _advertisement(1);
    final firstRegistration = await service.register(
      advertisement: advertisement,
      port: 16667,
    );
    final updatedPresence = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 2,
      maxPlayers: 4,
    );

    final update = firstRegistration.updatePresence(updatedPresence);
    await updateStarted.future;
    final firstClose = firstRegistration.close();
    final reopenedFuture = service.register(
      advertisement: advertisement.withPresence(updatedPresence),
      port: 16667,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, <String>['register-1', 'update-start']);

    updateGate.complete();
    await update;
    await closeStarted.future;
    expect(calls, <String>[
      'register-1',
      'update-start',
      'update-complete',
      'close-start',
    ]);

    closeGate.complete();
    await firstClose;
    final reopened = await reopenedFuture;
    expect(calls, <String>[
      'register-1',
      'update-start',
      'update-complete',
      'close-start',
      'close-complete',
      'register-2',
    ]);
    await reopened.close();
  });

  test('并发发现租约共用一次底层启动且最后释放才关闭', () async {
    final start = Completer<LanGamePlatformDiscovery>();
    final discovery = _FakeDiscovery();
    final platform = _FakePlatform(() => start.future);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    final firstFuture = service.startDiscovery();
    final secondFuture = service.startDiscovery();
    expect(platform.startCount, 1);
    start.complete(discovery);
    final leases = await Future.wait([firstFuture, secondFuture]);

    await leases.first.close();
    expect(discovery.closeCount, 0);
    await leases.last.close();
    expect(discovery.closeCount, 1);
  });

  test('最后 lease 释放取消未完成时新 lease 会启动新 generation', () async {
    final cancelGate = Completer<void>();
    final cancelStarted = Completer<void>();
    final oldDiscovery = _BlockingCancelDiscovery(cancelGate, cancelStarted);
    final newDiscovery = _FakeDiscovery();
    final platform = _SequencePlatform(<LanGamePlatformDiscovery>[
      oldDiscovery,
      newDiscovery,
    ]);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final oldLease = await service.startDiscovery();

    final oldClose = oldLease.close();
    await cancelStarted.future;
    final newLease = await service.startDiscovery();

    expect(platform.startCount, 2);
    newDiscovery.add(
      _record(88, hostAddresses: const ['192.168.1.88'], name: '新 generation'),
    );
    expect(service.currentSnapshot.games.single.name, '新 generation');

    cancelGate.complete();
    await oldClose;
    expect(service.currentSnapshot.state, LanGameDiscoveryState.ready);
    expect(service.currentSnapshot.games.single.name, '新 generation');
    await newLease.close();
  });

  test('unsupported 启动仍为每个调用返回可释放租约并保持状态', () async {
    final start = Completer<LanGamePlatformDiscovery>();
    final platform = _FakePlatform(() => start.future);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    final firstFuture = service.startDiscovery();
    final secondFuture = service.startDiscovery();
    start.completeError(UnsupportedError('unsupported'));
    final leases = await Future.wait([firstFuture, secondFuture]);

    expect(platform.startCount, 1);
    expect(service.currentSnapshot.state, LanGameDiscoveryState.unsupported);
    expect(
      () => service.findJoinCandidates('missing-instance'),
      throwsA(isA<LanGameJoinSourceUnavailableException>()),
    );
    await leases.first.close();
    expect(service.currentSnapshot.state, LanGameDiscoveryState.unsupported);
    await leases.last.close();
    expect(service.currentSnapshot.state, LanGameDiscoveryState.scanning);
  });

  test('启动过程中 dispose 不返回已失效租约并关闭迟到句柄', () async {
    final start = Completer<LanGamePlatformDiscovery>();
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() => start.future),
    );

    final leaseFuture = service.startDiscovery();
    final leaseExpectation = expectLater(leaseFuture, throwsStateError);
    final disposeFuture = service.dispose();
    start.complete(discovery);

    await disposeFuture;
    await leaseExpectation;
    expect(discovery.closeCount, 1);
  });

  test('注册过程中 dispose 只关闭一次迟到句柄且所有 waiter 稳定失败', () async {
    final registration = Completer<LanGamePlatformRegistration>();
    final platform = _PendingRegistrationPlatform(registration.future);
    final service = LanGameDiscoveryService(platform: platform);
    final advertisement = LanGameAdvertisement(
      instanceId: 'instance-register-0001',
      gameId: 'com.example.registration',
      name: '待关闭注册',
      inviteToken: 'registration-token',
      presence: LanGamePresence.solo(hostNickname: '测试房主'),
    );
    final handle = _FakeRegistration();

    final first = service.register(advertisement: advertisement, port: 16667);
    final second = service.register(advertisement: advertisement, port: 16667);
    final firstExpectation = expectLater(first, throwsStateError);
    final secondExpectation = expectLater(second, throwsStateError);
    expect(platform.registerCount, 1);

    await service.dispose();
    await service.dispose();
    registration.complete(handle);

    await firstExpectation;
    await secondExpectation;
    expect(handle.closeCount, 1);
    await service.dispose();
    expect(handle.closeCount, 1);
  });

  test('presence 并发同值更新被串行去重且 close 等待在途更新', () async {
    final updateGate = Completer<void>();
    final handle = _UpdatingRegistration(updateGate: updateGate);
    final service = LanGameDiscoveryService(
      platform: _RegistrationPlatform(handle),
    );
    addTearDown(service.dispose);
    final lease = await service.register(
      advertisement: _advertisement(1),
      port: 16667,
    );
    final updated = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 2,
      maxPlayers: 4,
    );

    final first = lease.updatePresence(updated);
    final second = lease.updatePresence(updated);
    await Future<void>.delayed(Duration.zero);
    final close = lease.close();

    expect(handle.updateCount, 1);
    expect(handle.closeCount, 0);
    updateGate.complete();
    await Future.wait(<Future<void>>[first, second, close]);
    expect(handle.updateCount, 1);
    expect(handle.closeCount, 1);
    await expectLater(lease.updatePresence(updated), throwsStateError);
  });

  test('presence 更新失败不提交，之后同值重试仍调用底层', () async {
    final handle = _UpdatingRegistration(failuresRemaining: 1);
    final service = LanGameDiscoveryService(
      platform: _RegistrationPlatform(handle),
    );
    addTearDown(service.dispose);
    final lease = await service.register(
      advertisement: _advertisement(1),
      port: 16667,
    );
    final updated = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 2,
      maxPlayers: 4,
    );

    await expectLater(lease.updatePresence(updated), throwsStateError);
    await lease.updatePresence(updated);

    expect(handle.updateCount, 2);
    expect(handle.advertisement?.presence, updated);
    await lease.close();
  });

  test('发现接受 link-local 单播源并拒绝 multicast 与保留地址源', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();

    discovery.add(
      _record(1, hostAddresses: const ['169.254.3.7'], name: '直连游戏'),
    );
    discovery.add(_record(2, hostAddresses: const ['224.1.2.3'], name: '组播伪源'));
    discovery.add(_record(3, hostAddresses: const ['240.1.2.3'], name: '保留伪源'));

    expect(service.currentSnapshot.games, hasLength(1));
    expect(service.currentSnapshot.games.single.hostAddress, '169.254.3.7');
    expect(service.currentSnapshot.games.single.presence.isSolo, isFalse);
    await lease.close();
  });

  test('运行中全部网卡失效后 lost 不伪造 ready，显式恢复才回 ready', () async {
    final discovery = _FakeDiscovery();
    final service = LanGameDiscoveryService(
      platform: _FakePlatform(() async => discovery),
    );
    addTearDown(service.dispose);
    final lease = await service.startDiscovery();
    final record = _record(
      77,
      hostAddresses: const ['192.168.1.77'],
      name: '恢复状态测试',
    );
    discovery.add(record);

    discovery.add(
      const LanGamePlatformFailure(LanGamePlatformFailureKind.unavailable),
    );
    expect(service.currentSnapshot.state, LanGameDiscoveryState.failed);
    expect(service.currentSnapshot.games, hasLength(1));

    final queuedRecord = _record(
      78,
      hostAddresses: const ['192.168.1.78'],
      name: '失效后排队公告',
    );
    discovery.add(queuedRecord);
    expect(service.currentSnapshot.state, LanGameDiscoveryState.failed);
    expect(service.currentSnapshot.games, hasLength(2));

    discovery.add(LanGamePlatformLost(record.platformId));
    expect(service.currentSnapshot.state, LanGameDiscoveryState.failed);
    expect(service.currentSnapshot.games.single.name, '失效后排队公告');

    discovery.add(const LanGamePlatformReady());
    expect(service.currentSnapshot.state, LanGameDiscoveryState.ready);
    expect(service.currentSnapshot.games.single.name, '失效后排队公告');
    await lease.close();
  });
}

LanGamePlatformResolved _record(
  int index, {
  required List<String> hostAddresses,
  required String name,
}) => LanGamePlatformResolved(
  platformId: 'platform-$index',
  instanceId: _instanceId(index),
  port: 16667,
  hostAddresses: hostAddresses,
  payload: LanGameAdvertisement(
    instanceId: _instanceId(index),
    gameId: 'com.example.game$index',
    name: name,
    inviteToken: 'token-$index',
    presence: LanGamePresence.multiplayer(
      hostNickname: '房主 $index',
      playerCount: 1,
      maxPlayers: 4,
    ),
  ).toPayload(),
);

LanGamePlatformResolved _advertisementRecord(
  LanGameAdvertisement advertisement, {
  required String platformId,
  required String hostAddress,
}) => LanGamePlatformResolved(
  platformId: platformId,
  instanceId: advertisement.instanceId,
  port: 16667,
  hostAddresses: <String>[hostAddress],
  payload: advertisement.toPayload(),
);

LanGameAdvertisement _advertisement(int playerCount) => LanGameAdvertisement(
  instanceId: 'instance-register-0001',
  gameId: 'com.example.registration',
  name: '注册测试游戏',
  inviteToken: 'registration-token',
  presence: LanGamePresence.multiplayer(
    hostNickname: '测试房主',
    playerCount: playerCount,
    maxPlayers: 4,
  ),
);

LanGameAdvertisement _indexedAdvertisement(int index) => LanGameAdvertisement(
  instanceId: 'local-instance-${index.toString().padLeft(8, '0')}',
  gameId: 'com.example.registration',
  name: '注册测试游戏 $index',
  inviteToken: 'registration-token-$index',
  presence: LanGamePresence.solo(hostNickname: '测试房主'),
);

String _instanceId(int index) => 'instance-${index.toString().padLeft(8, '0')}';

class _FakePlatform implements LanGameDiscoveryPlatform {
  _FakePlatform(this._start);

  final Future<LanGamePlatformDiscovery> Function() _start;
  int startCount = 0;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() {
    startCount += 1;
    return _start();
  }

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async => _FakeRegistration();
}

class _FakeDiscovery implements LanGamePlatformDiscovery {
  final StreamController<LanGamePlatformEvent> _events =
      StreamController<LanGamePlatformEvent>.broadcast(sync: true);
  int closeCount = 0;

  @override
  Stream<LanGamePlatformEvent> get events => _events.stream;

  void add(LanGamePlatformEvent event) => _events.add(event);

  @override
  Future<void> close() async {
    closeCount += 1;
    await _events.close();
  }
}

class _BlockingCancelDiscovery implements LanGamePlatformDiscovery {
  _BlockingCancelDiscovery(this._cancelGate, this._cancelStarted);

  final StreamController<LanGamePlatformEvent> _events =
      StreamController<LanGamePlatformEvent>.broadcast();
  final Completer<void> _cancelGate;
  final Completer<void> _cancelStarted;
  int closeCount = 0;

  @override
  Stream<LanGamePlatformEvent> get events => _DelayedCancelStream(
    _events.stream,
    cancelGate: _cancelGate,
    cancelStarted: _cancelStarted,
  );

  @override
  Future<void> close() async {
    closeCount += 1;
    await _events.close();
  }
}

class _DelayedCancelStream extends Stream<LanGamePlatformEvent> {
  _DelayedCancelStream(
    this._inner, {
    required this.cancelGate,
    required this.cancelStarted,
  });

  final Stream<LanGamePlatformEvent> _inner;
  final Completer<void> cancelGate;
  final Completer<void> cancelStarted;

  @override
  StreamSubscription<LanGamePlatformEvent> listen(
    void Function(LanGamePlatformEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _DelayedCancelSubscription(
    _inner.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    cancelGate: cancelGate,
    cancelStarted: cancelStarted,
  );
}

class _DelayedCancelSubscription
    implements StreamSubscription<LanGamePlatformEvent> {
  _DelayedCancelSubscription(
    this._inner, {
    required this.cancelGate,
    required this.cancelStarted,
  });

  final StreamSubscription<LanGamePlatformEvent> _inner;
  final Completer<void> cancelGate;
  final Completer<void> cancelStarted;

  @override
  Future<void> cancel() async {
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await cancelGate.future;
    await _inner.cancel();
  }

  @override
  void onData(void Function(LanGamePlatformEvent data)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}

class _SequencePlatform implements LanGameDiscoveryPlatform {
  _SequencePlatform(this.discoveries);

  final List<LanGamePlatformDiscovery> discoveries;
  int startCount = 0;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async =>
      discoveries[startCount++];

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) => throw UnsupportedError('not used');
}

class _SequenceRegistrationPlatform implements LanGameDiscoveryPlatform {
  _SequenceRegistrationPlatform(this.discoveries);

  final List<LanGamePlatformDiscovery> discoveries;
  int startCount = 0;
  int registerCount = 0;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async =>
      discoveries[startCount++];

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async {
    registerCount += 1;
    return _FakeRegistration();
  }
}

class _RegistrationSequenceWithDiscoveryPlatform
    implements LanGameDiscoveryPlatform {
  _RegistrationSequenceWithDiscoveryPlatform({
    required this.discovery,
    required this.registrations,
    required this.calls,
  });

  final LanGamePlatformDiscovery discovery;
  final List<LanGamePlatformRegistration> registrations;
  final List<String> calls;
  int registerCount = 0;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async => discovery;

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async {
    registerCount += 1;
    calls.add('register-$registerCount');
    return registrations[registerCount - 1];
  }
}

class _FakeRegistration implements LanGamePlatformRegistration {
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

class _BlockingUpdateCloseRegistration
    implements LanGamePlatformRegistration, LanGamePlatformRegistrationUpdater {
  _BlockingUpdateCloseRegistration({
    required this.calls,
    required this.updateStarted,
    required this.updateGate,
    required this.closeStarted,
    required this.closeGate,
  });

  final List<String> calls;
  final Completer<void> updateStarted;
  final Completer<void> updateGate;
  final Completer<void> closeStarted;
  final Completer<void> closeGate;

  @override
  Future<void> update(LanGameAdvertisement advertisement) async {
    calls.add('update-start');
    updateStarted.complete();
    await updateGate.future;
    calls.add('update-complete');
  }

  @override
  Future<void> close() async {
    calls.add('close-start');
    closeStarted.complete();
    await closeGate.future;
    calls.add('close-complete');
  }
}

class _PendingRegistrationPlatform implements LanGameDiscoveryPlatform {
  _PendingRegistrationPlatform(this.registration);

  final Future<LanGamePlatformRegistration> registration;
  int registerCount = 0;

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) {
    registerCount += 1;
    return registration;
  }

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() =>
      throw UnsupportedError('not used');
}

class _RegistrationPlatform implements LanGameDiscoveryPlatform {
  _RegistrationPlatform(this.registration);

  final LanGamePlatformRegistration registration;

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async => registration;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() =>
      throw UnsupportedError('not used');
}

class _UpdatingRegistration
    implements LanGamePlatformRegistration, LanGamePlatformRegistrationUpdater {
  _UpdatingRegistration({this.updateGate, this.failuresRemaining = 0});

  final Completer<void>? updateGate;
  int failuresRemaining;
  int updateCount = 0;
  int closeCount = 0;
  LanGameAdvertisement? advertisement;

  @override
  Future<void> update(LanGameAdvertisement value) async {
    updateCount += 1;
    await updateGate?.future;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('测试注入更新失败');
    }
    advertisement = value;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}
