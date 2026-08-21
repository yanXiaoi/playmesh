import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_invitation_inspector.dart';
import 'package:playmesh/core/game_web/game_join_coordinator.dart';
import 'package:playmesh/core/game_web/game_share_link_snapshot.dart';
import 'package:playmesh/core/network/lan_game_advertisement.dart';
import 'package:playmesh/core/network/lan_game_discovery_platform.dart';
import 'package:playmesh/core/network/lan_game_discovery_service.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';
import 'package:playmesh/features/game/game_app_lan_host.dart';

void main() {
  test('discover 默认 2 秒且可注入短时窗口，并按 gameId/self 过滤', () async {
    final defaults = _HostHarness();
    addTearDown(defaults.close);
    expect(defaults.host.discoveryDuration, const Duration(seconds: 2));

    final harness = _HostHarness(
      discoveryDuration: const Duration(milliseconds: 40),
      selfInstanceId: _selfInstanceId,
    );
    addTearDown(harness.close);
    final stopwatch = Stopwatch()..start();
    final games = await harness.discover([
      _record(
        platformId: 'matching',
        instanceId: _remoteInstanceId,
        gameId: _expectedGameId,
        name: 'Matching game',
        address: '192.168.1.20',
      ),
      _record(
        platformId: 'self',
        instanceId: _selfInstanceId,
        gameId: _expectedGameId,
        name: 'Self game',
        address: '192.168.1.21',
      ),
      _record(
        platformId: 'other-game',
        instanceId: _otherInstanceId,
        gameId: _otherGameId,
        name: 'Other game',
        address: '192.168.1.22',
      ),
    ]);
    stopwatch.stop();

    expect(harness.platform.startCount, 1);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(games, hasLength(1));
    expect(games.single.instanceId, _remoteInstanceId);
    expect(games.single.gameId, _expectedGameId);
    expect(games.single.name, 'Matching game');
    expect(games.single.host, '192.168.1.20:16667');
  });

  test('discover 建立短期 instance 映射，resetDocument 后立即失效', () async {
    final harness = _HostHarness(
      discoveryDuration: const Duration(milliseconds: 40),
    );
    addTearDown(harness.close);
    await harness.discover([
      _record(
        platformId: 'remote',
        instanceId: _remoteInstanceId,
        gameId: _expectedGameId,
        name: 'Remote game',
        address: '192.168.1.20',
      ),
    ]);

    final action = await harness.host.prepareDiscoveredJoin(_remoteInstanceId);
    expect(harness.inspector.calls, hasLength(1));
    expect(harness.replacements, isEmpty);

    harness.host.resetDocument();

    await expectLater(
      harness.host.prepareDiscoveredJoin(_remoteInstanceId),
      _sdkFailure('discovery_not_found'),
    );
    await expectLater(
      action.afterResponse(),
      _sdkFailure('operation_cancelled'),
    );
    expect(harness.replacements, isEmpty);
  });

  test('resetDocument 等待旧 lease 完整释放后再为新文档重新发现', () async {
    final harness = _HostHarness(
      discoveryDuration: const Duration(milliseconds: 20),
    );
    addTearDown(harness.close);
    await harness.discover([
      _record(
        platformId: 'old-document',
        instanceId: _remoteInstanceId,
        gameId: _expectedGameId,
        name: 'Old document game',
        address: '192.168.1.20',
      ),
    ]);

    final oldDiscovery = harness.platform.discoveries.single;
    final releaseGate = Completer<void>();
    oldDiscovery.cancelGate = releaseGate;
    addTearDown(() {
      if (!releaseGate.isCompleted) releaseGate.complete();
    });

    harness.host.resetDocument();
    await Future<void>.delayed(Duration.zero);

    var rediscoveryCompleted = false;
    final rediscovery = harness.host.discoverGames().whenComplete(
      () => rediscoveryCompleted = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(rediscoveryCompleted, isFalse);
    expect(harness.platform.startCount, 1);

    releaseGate.complete();
    await _waitUntil(() => harness.platform.discoveries.length == 2);
    harness.platform.discoveries.last.add(
      _record(
        platformId: 'new-document',
        instanceId: _otherInstanceId,
        gameId: _expectedGameId,
        name: 'New document game',
        address: '192.168.1.30',
      ),
    );
    final games = await rediscovery;

    expect(games.map((game) => game.instanceId), [_otherInstanceId]);
    expect(oldDiscovery.closeCount, 1);
  });

  test('join 入口把预检错误映射为稳定 SDK code', () async {
    final harness = _HostHarness(
      discoveryDuration: const Duration(milliseconds: 20),
    );
    addTearDown(harness.close);

    await expectLater(
      harness.host.prepareInvitationJoin('not-an-invitation'),
      _sdkFailure('invalid_invitation'),
    );

    harness.inspector.inspectedGameId = _otherGameId;
    await expectLater(
      harness.host.prepareInvitationJoin(_invitationUrl('192.168.1.20')),
      _sdkFailure('game_mismatch'),
    );

    harness.inspector.inspectedGameId = _expectedGameId;
    harness.matchesSelfInvitation = true;
    await expectLater(
      harness.host.prepareInvitationJoin(_invitationUrl('192.168.1.20')),
      _sdkFailure('self_invitation'),
    );

    harness.matchesSelfInvitation = false;
    harness.scannedQr = null;
    await expectLater(harness.host.prepareQrJoin(), _sdkFailure('cancelled'));

    await expectLater(
      harness.host.prepareDiscoveredJoin(_remoteInstanceId),
      _sdkFailure('discovery_not_found'),
    );
  });

  test('prepare 只准备导航，afterResponse 才导航且至多执行一次', () async {
    final harness = _HostHarness();
    addTearDown(harness.close);

    final action = await harness.host.prepareInvitationJoin(
      _invitationUrl('192.168.1.20'),
    );

    expect(harness.inspector.calls, hasLength(1));
    expect(harness.replacements, isEmpty);
    await action.afterResponse();
    expect(harness.replacements, hasLength(1));
    expect(harness.replacements.single.gameId, _expectedGameId);
    await expectLater(
      action.afterResponse(),
      _sdkFailure('operation_cancelled'),
    );
    expect(harness.replacements, hasLength(1));
  });

  test('remote host 仍可准备加入，但发布和分享读取返回 not_authority', () async {
    final harness = _HostHarness(isAuthority: false);
    addTearDown(harness.close);

    final action = await harness.host.prepareInvitationJoin(
      _invitationUrl('192.168.1.20'),
    );
    expect(action, isA<AppLanJoinAction>());
    expect(harness.replacements, isEmpty);

    await expectLater(
      harness.host.setPublished(),
      _sdkFailure('not_authority'),
    );
    await expectLater(
      harness.host.getShareLinks(),
      _sdkFailure('not_authority'),
    );
    expect(harness.publishCount, 0);
    expect(harness.shareReadCount, 0);
  });

  test('setPublished/getShareLinks 仅转发宿主回调并保留同一快照对象', () async {
    final snapshot = GameShareLinkSnapshot(
      generation: 9,
      links: [
        GameShareLink(
          url: Uri.parse(_invitationUrl('192.168.1.20')),
          type: GameShareLinkType.lan,
          pngBytes: const [1, 2, 3, 4],
        ),
      ],
    );
    final harness = _HostHarness(shareSnapshot: snapshot);
    addTearDown(harness.close);

    await harness.host.setPublished();
    final result = await harness.host.getShareLinks();

    expect(harness.publishCount, 1);
    expect(harness.shareReadCount, 1);
    expect(result, same(snapshot));
    expect(harness.platform.startCount, 0);
    expect(harness.inspector.calls, isEmpty);
    expect(harness.replacements, isEmpty);
  });

  test('close 取消进行中的预检且不会执行迟到导航', () async {
    final inspection = Completer<InspectedGameInvitation>();
    final harness = _HostHarness();
    addTearDown(harness.close);
    harness.inspector.pending = inspection;
    final operation = harness.host.prepareInvitationJoin(
      _invitationUrl('192.168.1.20'),
    );
    await _waitUntil(() => harness.inspector.calls.isNotEmpty);

    await harness.host.close();
    final invitation = harness.inspector.calls.single;
    inspection.complete(
      InspectedGameInvitation(
        invitation: invitation,
        gameId: _expectedGameId,
        gameName: 'Expected game',
      ),
    );

    await expectLater(operation, _sdkFailure('operation_cancelled'));
    expect(harness.replacements, isEmpty);
    await expectLater(
      Future<AppLanJoinAction>.sync(
        () =>
            harness.host.prepareInvitationJoin(_invitationUrl('192.168.1.21')),
      ),
      _sdkFailure('game_context_unavailable'),
    );
    await harness.host.close();
  });

  test('close/reset 取消进行中的 discover，迟到结果不能建立映射', () async {
    final harness = _HostHarness(
      discoveryDuration: const Duration(milliseconds: 80),
    );
    addTearDown(harness.close);
    final operation = harness.host.discoverGames();
    await _waitUntil(() => harness.platform.discoveries.isNotEmpty);
    await Future<void>.delayed(Duration.zero);
    harness.platform.discoveries.single.add(
      _record(
        platformId: 'late',
        instanceId: _remoteInstanceId,
        gameId: _expectedGameId,
        name: 'Late game',
        address: '192.168.1.20',
      ),
    );

    harness.host.resetDocument();

    await expectLater(operation, _sdkFailure('operation_cancelled'));
    await expectLater(
      harness.host.prepareDiscoveredJoin(_remoteInstanceId),
      _sdkFailure('discovery_not_found'),
    );
  });
}

const _expectedGameId = 'com.example.game';
const _otherGameId = 'com.example.other';
const _remoteInstanceId = 'instance-remote-0001';
const _selfInstanceId = 'instance-self-000001';
const _otherInstanceId = 'instance-other-00001';

String _invitationUrl(String host) =>
    'http://$host:16667/playmesh/join#inviteToken=opaque-token';

LanGamePlatformResolved _record({
  required String platformId,
  required String instanceId,
  required String gameId,
  required String name,
  required String address,
}) {
  final advertisement = LanGameAdvertisement(
    instanceId: instanceId,
    gameId: gameId,
    name: name,
    inviteToken: 'token-$platformId',
    presence: LanGamePresence.multiplayer(
      hostNickname: '远程房主',
      playerCount: 2,
      maxPlayers: 6,
    ),
  );
  return LanGamePlatformResolved(
    platformId: platformId,
    instanceId: instanceId,
    port: 16667,
    hostAddresses: [address],
    payload: advertisement.toPayload(),
  );
}

Matcher _sdkFailure(String code) => throwsA(
  isA<SdkCommandException>().having((error) => error.code, 'code', code),
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('测试条件未在期限内满足');
}

class _HostHarness {
  _HostHarness({
    Duration? discoveryDuration,
    String? selfInstanceId,
    bool isAuthority = true,
    GameShareLinkSnapshot? shareSnapshot,
  }) : active = true,
       authority = isAuthority,
       currentSelfInstanceId = selfInstanceId,
       shareSnapshot = shareSnapshot ?? GameShareLinkSnapshot.empty(0),
       platform = _FakeLanGameDiscoveryPlatform(),
       inspector = _FakeInspector() {
    discoveryService = LanGameDiscoveryService(platform: platform);
    host = discoveryDuration == null
        ? GameAppLanHostAdapter(
            gameId: () => _expectedGameId,
            discoveryService: discoveryService,
            isActive: () => active,
            isAuthority: () => authority,
            selfInstanceId: () => currentSelfInstanceId,
            isSelfInvitation: (_) => matchesSelfInvitation,
            scanQr: () async => scannedQr,
            replaceGame: _replaceGame,
            publish: _publish,
            readShareLinks: _readShareLinks,
            inspector: inspector,
          )
        : GameAppLanHostAdapter(
            gameId: () => _expectedGameId,
            discoveryService: discoveryService,
            isActive: () => active,
            isAuthority: () => authority,
            selfInstanceId: () => currentSelfInstanceId,
            isSelfInvitation: (_) => matchesSelfInvitation,
            scanQr: () async => scannedQr,
            replaceGame: _replaceGame,
            publish: _publish,
            readShareLinks: _readShareLinks,
            discoveryDuration: discoveryDuration,
            inspector: inspector,
          );
  }

  final _FakeLanGameDiscoveryPlatform platform;
  final _FakeInspector inspector;
  late final LanGameDiscoveryService discoveryService;
  late final GameAppLanHostAdapter host;
  final List<RemoteGameLaunch> replacements = [];
  final GameShareLinkSnapshot shareSnapshot;
  bool active;
  bool authority;
  String? currentSelfInstanceId;
  bool matchesSelfInvitation = false;
  String? scannedQr = _invitationUrl('192.168.1.30');
  int publishCount = 0;
  int shareReadCount = 0;

  Future<List<AppLanDiscoveredGame>> discover(
    List<LanGamePlatformEvent> events,
  ) => startDiscover(events);

  Future<List<AppLanDiscoveredGame>> startDiscover(
    List<LanGamePlatformEvent> events,
  ) async {
    final previousDiscoveries = platform.discoveries.length;
    final operation = host.discoverGames();
    await _waitUntil(() => platform.discoveries.length > previousDiscoveries);
    await Future<void>.delayed(Duration.zero);
    final discovery = platform.discoveries.last;
    for (final event in events) {
      discovery.add(event);
    }
    return operation;
  }

  Future<void> _replaceGame(RemoteGameLaunch launch) async {
    replacements.add(launch);
  }

  Future<void> _publish() async {
    publishCount += 1;
  }

  Future<GameShareLinkSnapshot> _readShareLinks() async {
    shareReadCount += 1;
    return shareSnapshot;
  }

  Future<void> close() async {
    await host.close();
    await discoveryService.dispose();
    await inspector.close();
  }
}

class _FakeInspector implements GameInvitationInspector {
  String inspectedGameId = _expectedGameId;
  Completer<InspectedGameInvitation>? pending;
  final List<GameInvitation> calls = [];
  int closeCount = 0;

  @override
  Future<InspectedGameInvitation> inspect(GameInvitation invitation) {
    calls.add(invitation);
    final pendingInspection = pending;
    if (pendingInspection != null) return pendingInspection.future;
    return Future.value(
      InspectedGameInvitation(
        invitation: invitation,
        gameId: inspectedGameId,
        gameName: 'Inspected game',
      ),
    );
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

class _FakeLanGameDiscoveryPlatform implements LanGameDiscoveryPlatform {
  final List<_FakeLanGamePlatformDiscovery> discoveries = [];
  int startCount = 0;

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async {
    startCount += 1;
    final discovery = _FakeLanGamePlatformDiscovery();
    discoveries.add(discovery);
    return discovery;
  }

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async => _FakeLanGamePlatformRegistration();
}

class _FakeLanGamePlatformDiscovery implements LanGamePlatformDiscovery {
  _FakeLanGamePlatformDiscovery() {
    _events = StreamController<LanGamePlatformEvent>(
      sync: true,
      onCancel: () => cancelGate?.future,
    );
  }

  late final StreamController<LanGamePlatformEvent> _events;
  Completer<void>? cancelGate;
  int closeCount = 0;

  @override
  Stream<LanGamePlatformEvent> get events => _events.stream;

  void add(LanGamePlatformEvent event) => _events.add(event);

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!_events.isClosed) await _events.close();
  }
}

class _FakeLanGamePlatformRegistration implements LanGamePlatformRegistration {
  @override
  Future<void> close() async {}
}
