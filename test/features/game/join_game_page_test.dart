import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_invitation_inspector.dart';
import 'package:playmesh/core/game_web/game_join_coordinator.dart';
import 'package:playmesh/core/network/lan_game_advertisement.dart';
import 'package:playmesh/core/network/lan_game_discovery_platform.dart';
import 'package:playmesh/core/network/lan_game_discovery_service.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';
import 'package:playmesh/features/game/game_invitation_scanner_page.dart';
import 'package:playmesh/features/game/game_join_router.dart';
import 'package:playmesh/features/game/join_game_page.dart';

import '../../support/localized_test_app.dart';

const _instanceId = 'instance-nearby-0001';
const _gameId = 'com.example.full-game_id';
const _gameName = '<script>alert("nearby")</script>';
const _host = '192.168.37.42';
const _port = 16667;
const _hostNickname = '房主玩家';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('附近对局启动期间显示 scanning，启动完成后显示 ready-empty', (tester) async {
    final pending = Completer<LanGamePlatformDiscovery>();
    final platform = _FakeDiscoveryPlatform(startPlans: [() => pending.future]);
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);

    expect(find.text('正在搜索同一局域网内的对局…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete(_FakePlatformDiscovery());
    await _pumpAsyncUi(tester);

    expect(find.text('暂未发现附近对局'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('附近对局启动成功且无结果时显示 ready-empty', (tester) async {
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);

    expect(platform.startCount, 1);
    expect(find.text('暂未发现附近对局'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);
  });

  testWidgets('标题刷新按钮关闭旧租约并只启动一次可继续订阅的新发现', (tester) async {
    final semantics = tester.ensureSemantics();
    final firstDiscovery = _FakePlatformDiscovery();
    final secondDiscovery = _FakePlatformDiscovery();
    final secondStart = Completer<LanGamePlatformDiscovery>();
    final platform = _FakeDiscoveryPlatform(
      startPlans: [() async => firstDiscovery, () => secondStart.future],
    );
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);

    final refresh = find.byKey(const ValueKey('nearby-refresh'));
    expect(refresh, findsOneWidget);
    expect(find.byTooltip('刷新附近对局'), findsOneWidget);
    expect(find.bySemanticsLabel('刷新附近对局'), findsOneWidget);
    semantics.dispose();
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

    await tester.tap(refresh);
    await _pumpUntil(
      tester,
      () => firstDiscovery.closeCount == 1 && platform.startCount == 2,
      reason: '手动刷新应关闭旧 browse lease 并且只启动一轮新发现',
    );

    expect(platform.startCount, 2);
    expect(firstDiscovery.closeCount, 1);
    expect(find.text('正在搜索同一局域网内的对局…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<IconButton>(refresh).onPressed,
      isNull,
      reason: '新一轮发现加载期间刷新按钮应保持可见但禁用',
    );

    secondStart.complete(secondDiscovery);
    await _pumpUntil(
      tester,
      () => service.currentSnapshot.state == LanGameDiscoveryState.ready,
      reason: '刷新后的底层发现应完成启动',
    );
    secondDiscovery.add(_nearbyGameRecord());
    await tester.pump();

    expect(platform.startCount, 2, reason: '一次刷新不得创建第二个并行扫描');
    expect(find.text(_gameName), findsOneWidget);
    expect(
      find.byKey(const ValueKey('nearby-game-$_instanceId')),
      findsOneWidget,
      reason: '刷新后页面必须继续自动订阅同一 Service 的新快照',
    );
  });

  final failureCases = <({String name, Object error, String message})>[
    (
      name: 'permission-denied',
      error: const LanGamePlatformException(
        LanGamePlatformFailureKind.permissionDenied,
      ),
      message: '没有本地网络权限，无法发现附近对局。',
    ),
    (
      name: 'unsupported',
      error: UnsupportedError('unsupported'),
      message: '当前平台不支持自动发现，可继续扫码或手动输入链接。',
    ),
    (
      name: 'failed',
      error: const LanGamePlatformException(
        LanGamePlatformFailureKind.unavailable,
      ),
      message: '附近对局发现暂时不可用。',
    ),
  ];

  for (final failureCase in failureCases) {
    testWidgets('附近发现 ${failureCase.name} 状态可重试', (tester) async {
      final platform = _FakeDiscoveryPlatform(
        startPlans: [() => Future.error(failureCase.error)],
      );
      final service = LanGameDiscoveryService(platform: platform);
      addTearDown(service.dispose);

      await _pumpJoinPage(tester, service: service);

      expect(find.text(failureCase.message), findsOneWidget);
      expect(find.text('重新搜索'), findsOneWidget);
    });
  }

  testWidgets('自动发现 unsupported 时仍保留完整手工加入入口', (tester) async {
    final platform = _FakeDiscoveryPlatform(
      startPlans: [() => Future.error(UnsupportedError('web unsupported'))],
    );
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);

    expect(find.text('当前平台不支持自动发现，可继续扫码或手动输入链接。'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('对局邀请链接'), findsOneWidget);
    expect(find.text('加入对局'), findsOneWidget);
  });

  testWidgets('附近列表显示多人游戏、主机、IP、完整 gameId 与人数', (tester) async {
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);
    platform.latestDiscovery.add(_nearbyGameRecord());
    await tester.pump();

    final nameText = tester.widget<Text>(find.text(_gameName));
    expect(nameText.data, _gameName);
    expect(find.text('主机：$_hostNickname'), findsOneWidget);
    expect(find.text('主机 IP：$_host'), findsOneWidget);
    expect(find.text('游戏 ID：$_gameId'), findsOneWidget);
    expect(find.text('2 / 6'), findsOneWidget);
    final tile = find.byKey(const ValueKey('nearby-game-$_instanceId'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byType(Image)),
      findsNothing,
      reason: '附近列表不得为游戏图标增加网络资源投影',
    );
  });

  testWidgets('附近列表把单机分享显示为单机且不伪造人数', (tester) async {
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);
    platform.latestDiscovery.add(
      _nearbyGameRecord(
        presence: LanGamePresence.solo(hostNickname: _hostNickname),
      ),
    );
    await tester.pump();

    expect(find.text('单机'), findsOneWidget);
    expect(find.text('主机：$_hostNickname'), findsOneWidget);
    expect(find.text('主机 IP：$_host'), findsOneWidget);
    expect(find.text('2 / 6'), findsNothing);
  });

  testWidgets('点击附近对局只调用注入的准备服务和 Router，路由期间释放发现', (tester) async {
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final routeReturn = Completer<void>();
    late final _FakeJoinPreparationService coordinator;
    coordinator = _FakeJoinPreparationService(
      onPrepareDiscovered: (_) {
        coordinator.discoveryCloseCountAtPreparation = platform.totalCloseCount;
        return _remoteLaunch();
      },
    );
    final router = _RecordingGameJoinRouter(pushResult: routeReturn.future);
    Future<void> persistNickname(String nickname) async {}

    await _pumpJoinPage(
      tester,
      service: service,
      coordinator: coordinator,
      router: router,
      userId: 'u_widget_test',
      nickname: '附近玩家',
      onNicknameChanged: persistNickname,
    );
    platform.latestDiscovery.add(_nearbyGameRecord());
    await tester.pump();

    final nearbyTile = find.byKey(const ValueKey('nearby-game-$_instanceId'));
    expect(nearbyTile.hitTestable(), findsOneWidget);
    final onTap = tester.widget<ListTile>(nearbyTile).onTap;
    expect(onTap, isNotNull);
    await tester.tap(nearbyTile);
    await _pumpUntil(
      tester,
      () => router.pushes.isNotEmpty,
      reason: '点击附近对局后应通过注入的准备服务进入统一 Router',
    );

    expect(coordinator.discoveredInstanceIds, const [_instanceId]);
    expect(coordinator.linkValues, isEmpty);
    expect(
      coordinator.discoveryCloseCountAtPreparation,
      0,
      reason: '发现候选预检完成前必须保留页面的 browse lease',
    );
    expect(
      platform.totalCloseCount,
      1,
      reason: '进入远程 Router 前必须释放 browse lease',
    );
    expect(router.pushes, hasLength(1));
    expect(router.replaces, isEmpty);
    expect(router.pushes.single.launch, same(coordinator.launches.single));
    expect(router.pushes.single.userId, 'u_widget_test');
    expect(router.pushes.single.nickname, '附近玩家');
    expect(router.pushes.single.discoveryService, same(service));
    expect(router.pushes.single.onNicknameChanged, same(persistNickname));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('nearby-refresh')))
          .onPressed,
      isNull,
      reason: '加入准备或远程路由进行中不得手动重启发现',
    );
    expect(platform.startCount, 1, reason: '远程页面返回前不得恢复发现租约');

    routeReturn.complete();
    await _pumpUntil(
      tester,
      () => platform.startCount == 2,
      reason: '远程路由返回后页面应重新启动发现',
    );

    expect(platform.startCount, 2, reason: '远程页面返回后应恢复发现租约');
    expect(find.byType(JoinGamePage), findsOneWidget);
  });

  testWidgets('真实 Coordinator 可在候选租约释放前完成附近加入预检', (tester) async {
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final inspector = _SuccessfulInvitationInspector();
    addTearDown(inspector.close);
    final coordinator = GameJoinCoordinator(
      inspector: inspector,
      discoveredGames: service,
    );
    final routeReturn = Completer<void>();
    final router = _RecordingGameJoinRouter(pushResult: routeReturn.future);

    await _pumpJoinPage(
      tester,
      service: service,
      coordinator: coordinator,
      router: router,
    );
    platform.latestDiscovery.add(_nearbyGameRecord());
    await tester.pump();
    expect(service.findJoinCandidates(_instanceId), isNotNull);

    await tester.tap(find.byKey(const ValueKey('nearby-game-$_instanceId')));
    await _pumpUntil(
      tester,
      () => router.pushes.isNotEmpty,
      reason: 'Coordinator 应在 browse lease 仍有效时取得并复核候选',
    );

    expect(inspector.invitations, hasLength(1));
    expect(router.pushes.single.launch.sourceInstanceId, _instanceId);
    expect(platform.totalCloseCount, 1, reason: '预检成功后、路由前应释放 browse lease');
    expect(service.findJoinCandidates(_instanceId), isNull);
    expect(find.text('该附近对局已离线或发生变化，请重新搜索。'), findsNothing);

    routeReturn.complete();
    await _pumpUntil(
      tester,
      () => platform.startCount == 2,
      reason: '远程路由返回后应恢复附近发现',
    );
  });

  testWidgets('进入扫码前释放发现租约，扫码返回后恢复', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final coordinator = _FakeJoinPreparationService();
    late final _AutoPopRouteObserver observer;
    observer = _AutoPopRouteObserver(
      onSecondaryPush: () {
        observer.discoveryCloseCountAtPush = platform.totalCloseCount;
      },
    );

    await _pumpJoinPage(
      tester,
      service: service,
      coordinator: coordinator,
      observer: observer,
    );
    await tester.ensureVisible(find.text('扫码加入'));
    await tester.pump();

    await tester.tap(find.text('扫码加入'));
    await _pumpUntil(
      tester,
      () => observer.secondaryPushCount == 1,
      reason: '释放发现租约后应压入扫码路由',
    );
    await _pumpUntil(
      tester,
      () => platform.startCount == 2,
      reason: '自动取消扫码路由后应恢复发现',
    );

    expect(observer.secondaryPushCount, 1);
    expect(observer.discoveryCloseCountAtPush, 1);
    expect(coordinator.discoveredInstanceIds, isEmpty);
    expect(coordinator.linkValues, isEmpty);
    expect(find.byType(GameInvitationScannerPage), findsNothing);
    expect(platform.startCount, 2, reason: '扫码取消返回后应重新取得发现租约');
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('paused、resumed 与 dispose 正确维护共享发现引用', (tester) async {
    addTearDown(() => _restoreResumedLifecycle(tester));
    final platform = _FakeDiscoveryPlatform();
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);
    final externalLease = await service.startDiscovery();

    await _pumpJoinPage(tester, service: service);

    expect(platform.startCount, 1, reason: '页面应复用调用方已有的底层发现会话');
    expect(platform.totalCloseCount, 0);

    _pauseApp(tester);

    await externalLease.close();
    await _pumpUntil(
      tester,
      () => platform.totalCloseCount == 1,
      reason: '页面暂停与外部租约释放后应关闭共享底层会话',
    );
    expect(platform.totalCloseCount, 1);

    _resumeApp(tester);
    await _pumpUntil(
      tester,
      () => platform.startCount == 2,
      reason: '应用恢复后应重新取得页面发现引用',
    );
    expect(platform.startCount, 2);
    expect(platform.totalCloseCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(
      tester,
      () => platform.totalCloseCount == 2,
      reason: '页面销毁后应释放恢复后的发现引用',
    );
    expect(platform.totalCloseCount, 2, reason: 'dispose 必须释放页面恢复后的引用');
  });

  testWidgets('发现启动未完成时快速 paused-resumed 不会丢失恢复请求', (tester) async {
    addTearDown(() => _restoreResumedLifecycle(tester));
    final firstStart = Completer<LanGamePlatformDiscovery>();
    final platform = _FakeDiscoveryPlatform(
      startPlans: [() => firstStart.future],
    );
    final service = LanGameDiscoveryService(platform: platform);
    addTearDown(service.dispose);

    await _pumpJoinPage(tester, service: service);
    expect(platform.startCount, 1);

    _pauseApp(tester);
    _resumeApp(tester);
    firstStart.complete(_FakePlatformDiscovery());
    await _pumpUntil(
      tester,
      () => platform.startCount == 2,
      reason: '迟到租约关闭后必须兑现 queued resumed 请求',
    );

    expect(platform.startCount, 2);
    expect(platform.discoveries.first.closeCount, 1);
    expect(platform.discoveries.last.closeCount, 0);
    expect(find.text('暂未发现附近对局'), findsOneWidget);
  });
}

Future<void> _pumpJoinPage(
  WidgetTester tester, {
  required LanGameDiscoveryService service,
  GameJoinPreparationService? coordinator,
  GameJoinRouter router = const GameJoinRouter(),
  NavigatorObserver? observer,
  String userId = 'u_local_test',
  String nickname = '本地玩家',
  Future<void> Function(String nickname)? onNicknameChanged,
}) async {
  await tester.pumpWidget(
    localizedTestApp(
      home: JoinGamePage(
        initialUserId: userId,
        initialNickname: nickname,
        discoveryService: service,
        joinCoordinator: coordinator ?? _FakeJoinPreparationService(),
        joinRouter: router,
        onNicknameChanged: onNicknameChanged,
      ),
      navigatorObservers: [?observer],
    ),
  );
  await _pumpAsyncUi(tester);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(condition(), isTrue, reason: reason);
}

void _pauseApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resumeApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void _restoreResumedLifecycle(WidgetTester tester) {
  switch (tester.binding.lifecycleState) {
    case AppLifecycleState.paused:
      _resumeApp(tester);
      return;
    case AppLifecycleState.hidden:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.inactive:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.detached:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.resumed:
    case null:
      return;
  }
}

Future<void> _pumpAsyncUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
}

LanGamePlatformResolved _nearbyGameRecord({LanGamePresence? presence}) {
  final advertisement = LanGameAdvertisement(
    instanceId: _instanceId,
    gameId: _gameId,
    name: _gameName,
    inviteToken: 'nearby-test-token',
    presence:
        presence ??
        LanGamePresence.multiplayer(
          hostNickname: _hostNickname,
          playerCount: 2,
          maxPlayers: 6,
        ),
  );
  return LanGamePlatformResolved(
    platformId: 'platform-nearby-1',
    instanceId: _instanceId,
    port: _port,
    hostAddresses: const [_host],
    payload: advertisement.toPayload(),
  );
}

RemoteGameLaunch _remoteLaunch() => RemoteGameLaunch(
  invitation: GameInvitation.parse(
    'http://$_host:$_port/playmesh/join#inviteToken=nearby-test-token',
  ),
  gameId: _gameId,
  gameName: _gameName,
  sourceInstanceId: _instanceId,
);

typedef _StartPlan = Future<LanGamePlatformDiscovery> Function();

class _FakeDiscoveryPlatform implements LanGameDiscoveryPlatform {
  _FakeDiscoveryPlatform({List<_StartPlan> startPlans = const []})
    : _startPlans = List.of(startPlans);

  final List<_StartPlan> _startPlans;
  final List<_FakePlatformDiscovery> discoveries = [];
  int startCount = 0;

  _FakePlatformDiscovery get latestDiscovery => discoveries.last;

  int get totalCloseCount =>
      discoveries.fold(0, (total, discovery) => total + discovery.closeCount);

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async {
    startCount += 1;
    if (_startPlans.isEmpty) {
      final discovery = _FakePlatformDiscovery();
      discoveries.add(discovery);
      return discovery;
    }
    final discovery = await _startPlans.removeAt(0)();
    if (discovery is _FakePlatformDiscovery &&
        !discoveries.contains(discovery)) {
      discoveries.add(discovery);
    }
    return discovery;
  }

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async => _FakePlatformRegistration();
}

class _FakePlatformDiscovery implements LanGamePlatformDiscovery {
  final StreamController<LanGamePlatformEvent> _events =
      StreamController<LanGamePlatformEvent>.broadcast(sync: true);
  int closeCount = 0;

  @override
  Stream<LanGamePlatformEvent> get events => _events.stream;

  void add(LanGamePlatformEvent event) => _events.add(event);

  @override
  Future<void> close() async {
    if (_events.isClosed) return;
    closeCount += 1;
    await _events.close();
  }
}

class _FakePlatformRegistration implements LanGamePlatformRegistration {
  @override
  Future<void> close() async {}
}

class _SuccessfulInvitationInspector implements GameInvitationInspector {
  final List<GameInvitation> invitations = [];

  @override
  Future<InspectedGameInvitation> inspect(GameInvitation invitation) async {
    invitations.add(invitation);
    return InspectedGameInvitation(
      invitation: invitation,
      gameId: _gameId,
      gameName: _gameName,
    );
  }

  @override
  Future<void> close() async {}
}

typedef _PrepareDiscovered = RemoteGameLaunch Function(String instanceId);

class _FakeJoinPreparationService implements GameJoinPreparationService {
  _FakeJoinPreparationService({this.onPrepareDiscovered});

  final _PrepareDiscovered? onPrepareDiscovered;
  final List<String> discoveredInstanceIds = [];
  final List<String> linkValues = [];
  final List<RemoteGameLaunch> launches = [];
  int? discoveryCloseCountAtPreparation;

  @override
  Future<RemoteGameLaunch> prepareDiscovered(
    String instanceId, {
    required GameJoinContext context,
  }) async {
    discoveredInstanceIds.add(instanceId);
    final launch = onPrepareDiscovered?.call(instanceId) ?? _remoteLaunch();
    launches.add(launch);
    return launch;
  }

  @override
  Future<RemoteGameLaunch> prepareLink(
    String invitationUrl, {
    required GameJoinContext context,
  }) async {
    linkValues.add(invitationUrl);
    final launch = _remoteLaunch();
    launches.add(launch);
    return launch;
  }
}

class _RouterInvocation {
  const _RouterInvocation({
    required this.launch,
    required this.userId,
    required this.nickname,
    required this.discoveryService,
    required this.onNicknameChanged,
  });

  final RemoteGameLaunch launch;
  final String userId;
  final String nickname;
  final LanGameDiscoveryService? discoveryService;
  final Future<void> Function(String nickname)? onNicknameChanged;
}

class _RecordingGameJoinRouter extends GameJoinRouter {
  _RecordingGameJoinRouter({Future<void>? pushResult})
    : _pushResult = pushResult ?? Future<void>.value();

  final Future<void> _pushResult;
  final List<_RouterInvocation> pushes = [];
  final List<_RouterInvocation> replaces = [];

  @override
  Future<void> push(
    BuildContext context, {
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) {
    pushes.add(
      _RouterInvocation(
        launch: launch,
        userId: userId,
        nickname: nickname,
        discoveryService: discoveryService,
        onNicknameChanged: onNicknameChanged,
      ),
    );
    return _pushResult;
  }

  @override
  Future<void> replace(
    BuildContext context, {
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) async {
    replaces.add(
      _RouterInvocation(
        launch: launch,
        userId: userId,
        nickname: nickname,
        discoveryService: discoveryService,
        onNicknameChanged: onNicknameChanged,
      ),
    );
  }
}

class _AutoPopRouteObserver extends NavigatorObserver {
  _AutoPopRouteObserver({required this.onSecondaryPush});

  final VoidCallback onSecondaryPush;
  int secondaryPushCount = 0;
  int? discoveryCloseCountAtPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    secondaryPushCount += 1;
    onSecondaryPush();
    scheduleMicrotask(() {
      if (route.isActive) route.navigator?.pop();
    });
  }
}
