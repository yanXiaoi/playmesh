import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_share_coordinator.dart';
import 'package:playmesh/core/game_web/game_share_link_snapshot.dart';
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/core/game_web/share_qr_code_encoder.dart';
import 'package:playmesh/core/network/lan_game_advertisement.dart';
import 'package:playmesh/core/network/lan_game_discovery_platform.dart';
import 'package:playmesh/core/network/lan_game_discovery_service.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('默认不创建分享通道、不公开且读取空快照没有副作用', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    expect(harness.coordinator.state.channel, ShareChannelState.absent);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.unpublished,
    );
    expect(harness.coordinator.state.snapshot.links, isEmpty);

    final snapshot = await harness.coordinator.currentLinkSnapshot();

    expect(snapshot.links, isEmpty);
    expect(harness.accessProvider.openCalls, 0);
    expect(harness.gatewayFactory.startCalls, 0);
    expect(harness.gateway.shareLinksCalls, 0);
    expect(harness.discoveryPlatform.registerCalls, 0);
  });

  test('并发 ensureChannel/setPublished 共用同一启动和发布操作', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final accessGate = Completer<void>();
    harness.accessProvider.openGate = accessGate;

    final firstEnsure = harness.coordinator.ensureChannel();
    final secondEnsure = harness.coordinator.ensureChannel();
    final firstPublish = harness.coordinator.setPublished();
    final secondPublish = harness.coordinator.setPublished();

    expect(identical(firstEnsure, secondEnsure), isTrue);
    expect(identical(firstPublish, secondPublish), isTrue);
    expect(harness.accessProvider.openCalls, 1);
    expect(harness.coordinator.state.channel, ShareChannelState.starting);

    accessGate.complete();
    await Future.wait(<Future<void>>[
      firstEnsure,
      secondEnsure,
      firstPublish,
      secondPublish,
    ]);

    expect(harness.accessProvider.openCalls, 1);
    expect(harness.gatewayFactory.startCalls, 1);
    expect(harness.gateway.shareLinksCalls, 1);
    expect(harness.discoveryPlatform.registerCalls, 1);
    expect(
      harness.discoveryPlatform.lastAdvertisement?.presence,
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 1,
        maxPlayers: _game.maxPlayers,
      ),
    );
    expect(harness.coordinator.state.channel, ShareChannelState.active);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.published,
    );

    await harness.coordinator.ensureChannel();
    await harness.coordinator.setPublished();
    expect(harness.gatewayFactory.startCalls, 1);
    expect(harness.discoveryPlatform.registerCalls, 1);
  });

  test('单机游戏允许局域网分享且 presence 不伪造房间人数', () async {
    final harness = await _Harness.create(game: _soloGame);
    addTearDown(harness.dispose);

    await harness.coordinator.setPublished();

    expect(
      harness.coordinator.state.publication,
      LanPublicationState.published,
    );
    final presence = harness.discoveryPlatform.lastAdvertisement?.presence;
    expect(presence?.hostNickname, '单机玩家');
    expect(presence?.isSolo, isTrue);
    expect(presence?.playerCount, isNull);
    expect(presence?.maxPlayers, isNull);
  });

  test('多人 presence 只消费 session 快照消息、去重并使用注入的主机昵称', () {
    final source = File(
      'lib/core/game_web/game_share_coordinator.dart',
    ).readAsStringSync();
    final providerStart = source.indexOf(
      'class MultiplayerGameShareAccessProvider',
    );
    final providerEnd = source.indexOf(
      'class StandaloneGameShareAccessProvider',
      providerStart,
    );
    expect(providerStart, greaterThanOrEqualTo(0));
    expect(providerEnd, greaterThan(providerStart));
    final provider = source.substring(providerStart, providerEnd);

    expect(provider, contains('required this.hostNickname'));
    expect(provider, contains("where((message) => message['session'] is Map)"));
    expect(provider, contains('.distinct()'));
    expect(source, contains('hostNickname: hostNickname'));
    expect(
      source,
      contains('snapshot.players.where((player) => player.connected).length'),
    );
    expect(source, contains('maxPlayers: snapshot.maxPlayers'));
    expect(source, contains('hostNickname: bridge.nickname'));
    expect(
      source,
      isNot(contains('hostNickname: connection.currentPlayer.nickname')),
    );
  });

  test('首次发布等待注册时保留最新 presence 并在提交后补发', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final registrationGate = Completer<void>();
    harness.discoveryPlatform.registrationGate = registrationGate;

    final publish = harness.coordinator.setPublished();
    await _waitUntil(() => harness.discoveryPlatform.registerCalls == 1);
    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 2,
        maxPlayers: _game.maxPlayers,
      ),
    );
    final latest = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 3,
      maxPlayers: _game.maxPlayers,
    );
    harness.accessProvider.emitPresence(latest);

    registrationGate.complete();
    await publish;
    await _waitUntil(
      () => harness.discoveryPlatform.updateAdvertisements.isNotEmpty,
    );

    final registered = harness.discoveryPlatform.registerAdvertisements.single;
    final updated = harness.discoveryPlatform.updateAdvertisements.single;
    expect(registered.presence.playerCount, 1);
    expect(harness.discoveryPlatform.updateAdvertisements, hasLength(1));
    expect(updated.presence, latest);
    expect(updated.instanceId, registered.instanceId);
    expect(updated.inviteToken, registered.inviteToken);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.published,
    );
  });

  test('presence 更新按值去重、防抖且在途更新保持串行', () async {
    const debounce = Duration(milliseconds: 30);
    final harness = await _Harness.create(presenceUpdateDebounce: debounce);
    addTearDown(harness.dispose);
    await harness.coordinator.setPublished();

    final initial = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 1,
      maxPlayers: _game.maxPlayers,
    );
    harness.accessProvider.emitPresence(initial);
    await Future<void>.delayed(debounce + const Duration(milliseconds: 10));
    expect(harness.discoveryPlatform.updateAdvertisements, isEmpty);

    final firstUpdateGate = Completer<void>();
    harness.discoveryPlatform.updateGate = firstUpdateGate;
    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 2,
        maxPlayers: _game.maxPlayers,
      ),
    );
    await _waitUntil(
      () => harness.discoveryPlatform.updateAdvertisements.length == 1,
    );

    final latest = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 3,
      maxPlayers: _game.maxPlayers,
    );
    harness.accessProvider.emitPresence(latest);
    firstUpdateGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      harness.discoveryPlatform.updateAdvertisements,
      hasLength(1),
      reason: '在途更新完成不应绕过新一轮防抖',
    );
    await _waitUntil(
      () => harness.discoveryPlatform.updateAdvertisements.length == 2,
    );

    expect(
      harness.discoveryPlatform.updateAdvertisements.last.presence,
      latest,
    );
    expect(harness.discoveryPlatform.maxConcurrentUpdates, 1);
  });

  test('presence 在防抖期回到已发布值不更新且 close 取消待发计时', () async {
    const debounce = Duration(milliseconds: 30);
    final harness = await _Harness.create(presenceUpdateDebounce: debounce);
    addTearDown(harness.dispose);
    await harness.coordinator.setPublished();
    final initial = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 1,
      maxPlayers: _game.maxPlayers,
    );
    final changed = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 2,
      maxPlayers: _game.maxPlayers,
    );

    harness.accessProvider.emitPresence(changed);
    harness.accessProvider.emitPresence(initial);
    await Future<void>.delayed(debounce + const Duration(milliseconds: 10));
    expect(harness.discoveryPlatform.updateAdvertisements, isEmpty);

    harness.accessProvider.emitPresence(changed);
    await harness.coordinator.close();
    await Future<void>.delayed(debounce + const Duration(milliseconds: 10));

    expect(harness.discoveryPlatform.updateAdvertisements, isEmpty);
    expect(harness.coordinator.state.publication, LanPublicationState.disposed);
  });

  test('presence 更新失败先释放旧注册，再把同一次发布请求串行重试', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.coordinator.setPublished();
    final registrationCloseGate = Completer<void>();
    harness.discoveryPlatform.registrationCloseGate = registrationCloseGate;
    harness.discoveryPlatform.updateFailuresRemaining = 1;
    final latest = LanGamePresence.multiplayer(
      hostNickname: '测试房主',
      playerCount: 2,
      maxPlayers: _game.maxPlayers,
    );

    harness.accessProvider.emitPresence(latest);
    await _waitUntil(
      () => harness.discoveryPlatform.registrations.single.closeCalls == 1,
    );
    var retryCompleted = false;
    final retry = harness.coordinator.setPublished().whenComplete(
      () => retryCompleted = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(retryCompleted, isFalse);
    expect(harness.discoveryPlatform.registerCalls, 1);

    registrationCloseGate.complete();
    await retry;

    expect(harness.discoveryPlatform.registerCalls, 2);
    expect(
      harness.discoveryPlatform.registerAdvertisements.last.presence,
      latest,
    );
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.published,
    );
    expect(harness.coordinator.state.publicationFailureCode, isNull);
  });

  test('首次注册失败晚于 close 时不会把 disposing 写回 unpublished', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final registrationGate = Completer<void>();
    harness.discoveryPlatform.registrationGate = registrationGate;
    harness.discoveryPlatform.failuresRemaining = 1;
    final observed = <GameShareCoordinatorState>[];
    final subscription = harness.coordinator.states.listen(observed.add);
    addTearDown(subscription.cancel);

    final publish = harness.coordinator.setPublished();
    await _waitUntil(() => harness.discoveryPlatform.registerCalls == 1);
    final publishFailure = expectLater(publish, throwsA(anything));
    final close = harness.coordinator.close();
    await _waitUntil(
      () => observed.any(
        (state) => state.publication == LanPublicationState.disposing,
      ),
    );
    final disposingIndex = observed.lastIndexWhere(
      (state) => state.publication == LanPublicationState.disposing,
    );

    registrationGate.complete();
    await Future.wait(<Future<void>>[publishFailure, close]);

    expect(
      observed.skip(disposingIndex).map((state) => state.publication).toSet(),
      <LanPublicationState>{
        LanPublicationState.disposing,
        LanPublicationState.disposed,
      },
    );
  });

  test('close 先取消 presence 监听并等待在途更新，晚到结果和消息不复活', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.coordinator.setPublished();
    final updateGate = Completer<void>();
    harness.discoveryPlatform.updateGate = updateGate;

    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 2,
        maxPlayers: _game.maxPlayers,
      ),
    );
    await _waitUntil(
      () => harness.discoveryPlatform.updateAdvertisements.length == 1,
    );
    var closeCompleted = false;
    final close = harness.coordinator.close().whenComplete(
      () => closeCompleted = true,
    );
    await _waitUntil(
      () =>
          harness.coordinator.state.publication ==
          LanPublicationState.disposing,
    );
    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 3,
        maxPlayers: _game.maxPlayers,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);
    expect(harness.discoveryPlatform.updateAdvertisements, hasLength(1));

    updateGate.complete();
    await close;
    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 4,
        maxPlayers: _game.maxPlayers,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.discoveryPlatform.updateAdvertisements, hasLength(1));
    expect(harness.coordinator.state.channel, ShareChannelState.disposed);
    expect(harness.coordinator.state.publication, LanPublicationState.disposed);
    expect(harness.coordinator.state.snapshot.links, isEmpty);
  });

  test('presence 更新失败清理晚于 close 时不会复活公开状态', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.coordinator.setPublished();
    final registrationCloseGate = Completer<void>();
    harness.discoveryPlatform.registrationCloseGate = registrationCloseGate;
    harness.discoveryPlatform.updateFailuresRemaining = 1;
    final observed = <GameShareCoordinatorState>[];
    final subscription = harness.coordinator.states.listen(observed.add);
    addTearDown(subscription.cancel);

    harness.accessProvider.emitPresence(
      LanGamePresence.multiplayer(
        hostNickname: '测试房主',
        playerCount: 2,
        maxPlayers: _game.maxPlayers,
      ),
    );
    await _waitUntil(
      () => harness.discoveryPlatform.registrations.single.closeCalls == 1,
    );
    final close = harness.coordinator.close();
    await _waitUntil(
      () => observed.any(
        (state) => state.publication == LanPublicationState.disposing,
      ),
    );
    final disposingIndex = observed.lastIndexWhere(
      (state) => state.publication == LanPublicationState.disposing,
    );

    registrationCloseGate.complete();
    await close;

    expect(
      observed.skip(disposingIndex).map((state) => state.publication).toSet(),
      <LanPublicationState>{
        LanPublicationState.disposing,
        LanPublicationState.disposed,
      },
    );
    expect(harness.coordinator.state.snapshot.links, isEmpty);
  });

  test('UDP 公告注册失败保留分享通道并允许复用同一通道重试', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    harness.discoveryPlatform.failuresRemaining = 1;

    await expectLater(
      harness.coordinator.setPublished(),
      throwsA(_shareExceptionWithCode('discovery_unavailable')),
    );

    expect(harness.coordinator.state.channel, ShareChannelState.active);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.unpublished,
    );
    expect(
      harness.coordinator.state.publicationFailureCode,
      'discovery_unavailable',
    );
    expect(harness.gateway.closeCalls, 0);
    expect(harness.accessProvider.releaseCalls, 0);

    await harness.coordinator.setPublished();

    expect(harness.gatewayFactory.startCalls, 1);
    expect(harness.gateway.shareLinksCalls, 1);
    expect(harness.discoveryPlatform.registerCalls, 2);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.published,
    );
    expect(harness.coordinator.state.publicationFailureCode, isNull);
  });

  test('没有 LAN 地址时发布失败但已经建立的本地通道保持可用', () async {
    final harness = await _Harness.create(lanUrls: <Uri>[]);
    addTearDown(harness.dispose);

    await expectLater(
      harness.coordinator.setPublished(),
      throwsA(_shareExceptionWithCode('discovery_unavailable')),
    );

    expect(harness.coordinator.state.channel, ShareChannelState.active);
    expect(harness.coordinator.state.snapshot.links, isEmpty);
    expect(
      harness.coordinator.state.publication,
      LanPublicationState.unpublished,
    );
    expect(harness.discoveryPlatform.registerCalls, 0);
    expect(harness.gateway.closeCalls, 0);
    expect(harness.accessProvider.releaseCalls, 0);
  });

  test('快照只来自网关首次结果且重复读取不重新枚举或编码', () async {
    final firstLan = _lanInvitation('192.168.1.20', 4100, 'first');
    final secondLan = _lanInvitation('10.0.0.8', 4100, 'second');
    final harness = await _Harness.create(lanUrls: <Uri>[firstLan, secondLan]);
    addTearDown(harness.dispose);

    await harness.coordinator.ensureChannel();
    final stateSnapshot = harness.coordinator.state.snapshot;
    harness.gateway.shareLinksResult.clear();

    final firstRead = await harness.coordinator.currentLinkSnapshot();
    final secondRead = await harness.coordinator.currentLinkSnapshot();

    expect(firstRead, same(stateSnapshot));
    expect(secondRead, same(stateSnapshot));
    expect(firstRead.links.map((link) => link.url), <Uri>[firstLan, secondLan]);
    expect(firstRead.links.map((link) => link.type), <GameShareLinkType>[
      GameShareLinkType.lan,
      GameShareLinkType.lan,
    ]);
    expect(harness.gateway.shareLinksCalls, 1);
    expect(harness.qrEncoder.encodedUrls, <Uri>[firstLan, secondLan]);
  });

  test('Relay 使用内部回环邀请并在连接和断开时原子更新同一快照', () async {
    final lan = _lanInvitation('192.168.1.20', 4100, 'lan');
    final wan = Uri.parse(
      'https://relay.example.test/j/tunnel#inviteToken=relay-secret',
    );
    final harness = await _Harness.create(lanUrls: <Uri>[lan]);
    addTearDown(harness.dispose);
    final session = _FakeRelayHostSession(joinUri: wan);
    harness.relayFactory.session = session;

    await harness.coordinator.connectRelay(_relayRequest);

    expect(harness.relayFactory.startCalls, 1);
    expect(
      harness.relayFactory.authorityEntryUri,
      harness.gateway.loopbackInvitationUri,
    );
    expect(
      harness.relayFactory.authorityWebBaseUri,
      Uri(scheme: 'http', host: '127.0.0.1', port: harness.gateway.port),
    );
    expect(
      harness.relayFactory.authorityCoreBaseUri,
      harness.accessProvider.coreEndpoint,
    );
    expect(
      harness.coordinator.state.relayStatus,
      RelayConnectionStatus.connected,
    );
    expect(
      harness.coordinator.state.snapshot.links.map((link) => link.url),
      <Uri>[lan, wan],
    );
    expect(harness.coordinator.state.snapshot.wanLink?.url, wan);

    session.emit(RelayConnectionStatus.disconnected);
    await _waitUntil(() => harness.coordinator.state.snapshot.wanLink == null);

    expect(
      harness.coordinator.state.relayStatus,
      RelayConnectionStatus.disconnected,
    );
    expect(
      harness.coordinator.state.snapshot.links.map((link) => link.url),
      <Uri>[lan],
    );
    expect(session.closeCalls, 1);
    await harness.coordinator.disconnectRelay();
    expect(session.closeCalls, 1);
  });

  test('Relay factory 返回初始已断开的 session 时拒绝提交并完整回收', () async {
    final lan = _lanInvitation('192.168.1.20', 4100, 'lan');
    final wan = Uri.parse(
      'https://relay.example.test/j/disconnected#inviteToken=relay-secret',
    );
    final harness = await _Harness.create(lanUrls: <Uri>[lan]);
    addTearDown(harness.dispose);
    final session = _FakeRelayHostSession(
      joinUri: wan,
      initialStatus: RelayConnectionStatus.disconnected,
    );
    harness.relayFactory.session = session;

    await expectLater(
      harness.coordinator.connectRelay(_relayRequest),
      throwsA(_shareExceptionWithCode('share_unavailable')),
    );

    expect(session.closeCalls, 1);
    expect(
      harness.coordinator.state.relayStatus,
      RelayConnectionStatus.disconnected,
    );
    expect(harness.coordinator.state.relayFailureCode, 'relay_unavailable');
    expect(
      harness.coordinator.state.snapshot.links.map((link) => link.url),
      <Uri>[lan],
    );
    expect(harness.coordinator.state.snapshot.wanLink, isNull);

    await harness.coordinator.disconnectRelay();
    expect(session.closeCalls, 1, reason: '失败 session 不应继续保存在 coordinator 中');
  });

  test('Relay 快照构建失败时回滚 WAN、session、订阅和二维码保留集', () async {
    final lan = _lanInvitation('192.168.1.20', 4100, 'lan');
    final wan = Uri.parse(
      'https://relay.example.test/j/qr-failure#inviteToken=relay-secret',
    );
    final harness = await _Harness.create(lanUrls: <Uri>[lan]);
    addTearDown(harness.dispose);
    final session = _FakeRelayHostSession(joinUri: wan);
    harness.relayFactory.session = session;
    harness.qrEncoder.failOnUrl = wan;

    await expectLater(
      harness.coordinator.connectRelay(_relayRequest),
      throwsA(_shareExceptionWithCode('share_unavailable')),
    );

    expect(session.closeCalls, 1);
    expect(
      harness.coordinator.state.relayStatus,
      RelayConnectionStatus.disconnected,
    );
    expect(harness.coordinator.state.relayFailureCode, 'relay_unavailable');
    expect(
      harness.coordinator.state.snapshot.links.map((link) => link.url),
      <Uri>[lan],
    );
    expect(harness.coordinator.state.snapshot.wanLink, isNull);
    expect(harness.qrEncoder.retainedUrls, <Uri>[lan]);

    await harness.coordinator.disconnectRelay();
    expect(session.closeCalls, 1, reason: '失败回滚后显式断开必须是无副作用操作');
  });

  test('Relay 在快照构建期间断开时回滚并离开 connecting 状态', () async {
    final lan = _lanInvitation('192.168.1.20', 4100, 'lan');
    final wan = Uri.parse(
      'https://relay.example.test/j/disconnect-during-qr#inviteToken=relay-secret',
    );
    final harness = await _Harness.create(lanUrls: <Uri>[lan]);
    addTearDown(harness.dispose);
    final session = _FakeRelayHostSession(joinUri: wan);
    harness.relayFactory.session = session;
    final encodeStarted = Completer<void>();
    final allowEncode = Completer<void>();
    harness.qrEncoder
      ..blockOnUrl = wan
      ..encodeStarted = encodeStarted
      ..allowEncode = allowEncode;

    final connect = harness.coordinator.connectRelay(_relayRequest);
    await encodeStarted.future;
    session.emit(RelayConnectionStatus.disconnected);
    allowEncode.complete();

    await expectLater(
      connect,
      throwsA(_shareExceptionWithCode('share_unavailable')),
    );
    expect(session.closeCalls, 1);
    expect(
      harness.coordinator.state.relayStatus,
      RelayConnectionStatus.disconnected,
    );
    expect(harness.coordinator.state.relayFailureCode, 'relay_unavailable');
    expect(
      harness.coordinator.state.snapshot.links.map((link) => link.url),
      <Uri>[lan],
    );
    expect(harness.coordinator.state.snapshot.wanLink, isNull);
    expect(harness.qrEncoder.retainedUrls, <Uri>[lan]);
  });

  test('close 按注册、Relay、网关、访问授权顺序清理且完全幂等', () async {
    final log = <String>[];
    final harness = await _Harness.create(log: log);
    addTearDown(harness.dispose);
    final session = _FakeRelayHostSession(
      joinUri: Uri.parse(
        'https://relay.example.test/j/tunnel#inviteToken=relay-secret',
      ),
      log: log,
    );
    harness.relayFactory.session = session;
    await harness.coordinator.setPublished();
    await harness.coordinator.connectRelay(_relayRequest);
    log.clear();

    final firstClose = harness.coordinator.close();
    final secondClose = harness.coordinator.close();

    expect(identical(firstClose, secondClose), isTrue);
    await Future.wait(<Future<void>>[firstClose, secondClose]);

    expect(log, <String>[
      'registration.close',
      'relay.close',
      'gateway.close',
      'access.close',
    ]);
    expect(harness.coordinator.state.channel, ShareChannelState.disposed);
    expect(harness.coordinator.state.publication, LanPublicationState.disposed);
    expect(harness.coordinator.state.snapshot.links, isEmpty);
    expect(session.closeCalls, 1);
    expect(harness.gateway.closeCalls, 1);
    expect(harness.accessProvider.releaseCalls, 1);
  });

  test('close 等待并回收晚到的 Gateway，旧 generation 不会复活', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gatewayResult = Completer<GameWebGateway>();
    harness.gatewayFactory.result = gatewayResult;
    final observed = <GameShareCoordinatorState>[];
    final subscription = harness.coordinator.states.listen(observed.add);
    addTearDown(subscription.cancel);

    final ensure = harness.coordinator.ensureChannel();
    await _waitUntil(() => harness.gatewayFactory.startCalls == 1);
    final ensureFailure = expectLater(ensure, throwsA(anything));
    final close = harness.coordinator.close();
    gatewayResult.complete(harness.gateway);
    await Future.wait(<Future<void>>[ensureFailure, close]);

    expect(
      observed.any((state) => state.channel == ShareChannelState.active),
      isFalse,
    );
    expect(harness.coordinator.state.channel, ShareChannelState.disposed);
    expect(harness.coordinator.state.snapshot.links, isEmpty);
    expect(harness.gateway.closeCalls, 1);
    expect(harness.accessProvider.releaseCalls, 1);
  });

  test('close 回收晚到的 Relay session，WAN 结果不会进入已关闭快照', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.coordinator.ensureChannel();
    final relayResult = Completer<RelayHostSession>();
    harness.relayFactory.result = relayResult;
    final lateSession = _FakeRelayHostSession(
      joinUri: Uri.parse(
        'https://relay.example.test/j/late#inviteToken=late-secret',
      ),
    );
    final observed = <GameShareCoordinatorState>[];
    final subscription = harness.coordinator.states.listen(observed.add);
    addTearDown(subscription.cancel);

    final connect = harness.coordinator.connectRelay(_relayRequest);
    await _waitUntil(() => harness.relayFactory.startCalls == 1);
    final connectFailure = expectLater(connect, throwsA(anything));
    final close = harness.coordinator.close();
    relayResult.complete(lateSession);
    await Future.wait(<Future<void>>[connectFailure, close]);

    expect(observed.any((state) => state.snapshot.wanLink != null), isFalse);
    expect(harness.coordinator.state.channel, ShareChannelState.disposed);
    expect(harness.coordinator.state.snapshot.links, isEmpty);
    expect(lateSession.closeCalls, 1);
  });
}

final class _Harness {
  _Harness._({
    required this.root,
    required this.storage,
    required this.accessProvider,
    required this.gateway,
    required this.gatewayFactory,
    required this.discoveryPlatform,
    required this.discoveryService,
    required this.relayFactory,
    required this.qrEncoder,
    required this.coordinator,
  });

  static Future<_Harness> create({
    List<Uri>? lanUrls,
    List<String>? log,
    GameSummary game = _game,
    LanGamePresence? initialPresence,
    Duration presenceUpdateDebounce = Duration.zero,
  }) async {
    final lifecycleLog = log ?? <String>[];
    final root = await Directory.systemTemp.createTemp(
      'playmesh-share-coordinator-',
    );
    final storage = await GameStorageService.create(
      gameId: game.id,
      libraryRoot: root,
    );
    final accessProvider = _FakeAccessProvider(
      storage: storage,
      log: lifecycleLog,
      initialPresence:
          initialPresence ??
          (game.supportsMultiplayer
              ? LanGamePresence.multiplayer(
                  hostNickname: '测试房主',
                  playerCount: 1,
                  maxPlayers: game.maxPlayers,
                )
              : LanGamePresence.solo(hostNickname: '单机玩家')),
    );
    final gateway = _FakeGameWebGateway(
      shareLinksResult: lanUrls ?? <Uri>[_defaultLanInvitation],
      log: lifecycleLog,
    );
    final gatewayFactory = _FakeGameShareGatewayFactory(gateway);
    final discoveryPlatform = _FakeLanGameDiscoveryPlatform(lifecycleLog);
    final discoveryService = LanGameDiscoveryService(
      platform: discoveryPlatform,
    );
    final relayFactory = _FakeGameRelayHostFactory();
    final qrEncoder = _CountingQrEncoder();
    final coordinator = GameShareCoordinator(
      game: game,
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      accessProvider: accessProvider,
      discoveryService: discoveryService,
      qrEncoder: qrEncoder,
      presenceUpdateDebounce: presenceUpdateDebounce,
      gatewayFactory: gatewayFactory,
      relayFactory: relayFactory,
    );
    return _Harness._(
      root: root,
      storage: storage,
      accessProvider: accessProvider,
      gateway: gateway,
      gatewayFactory: gatewayFactory,
      discoveryPlatform: discoveryPlatform,
      discoveryService: discoveryService,
      relayFactory: relayFactory,
      qrEncoder: qrEncoder,
      coordinator: coordinator,
    );
  }

  final Directory root;
  final GameStorageService storage;
  final _FakeAccessProvider accessProvider;
  final _FakeGameWebGateway gateway;
  final _FakeGameShareGatewayFactory gatewayFactory;
  final _FakeLanGameDiscoveryPlatform discoveryPlatform;
  final LanGameDiscoveryService discoveryService;
  final _FakeGameRelayHostFactory relayFactory;
  final _CountingQrEncoder qrEncoder;
  final GameShareCoordinator coordinator;

  Future<void> dispose() async {
    try {
      await coordinator.close();
    } finally {
      await discoveryService.dispose();
      await accessProvider.dispose();
      await storage.close();
      if (await root.exists()) await root.delete(recursive: true);
    }
  }
}

final class _FakeAccessProvider implements GameShareAccessProvider {
  _FakeAccessProvider({
    required this.storage,
    required this.log,
    required LanGamePresence initialPresence,
  }) : _presence = initialPresence;

  final GameStorageService storage;
  final List<String> log;
  final StreamController<LanGamePresence> _presences =
      StreamController<LanGamePresence>.broadcast(sync: true);
  final Uri coreEndpoint = Uri.parse('http://127.0.0.1:39001/');
  LanGamePresence _presence;
  Completer<void>? openGate;
  int openCalls = 0;
  int releaseCalls = 0;

  @override
  Future<GameShareAccess> open() async {
    openCalls += 1;
    final gate = openGate;
    if (gate != null) await gate.future;
    return GameShareAccess(
      shareToken: 'share-token',
      storage: storage,
      displayMode: 'multi_screen',
      currentPresence: () => _presence,
      presenceChanges: _presences.stream,
      coreEndpoint: coreEndpoint,
      joinCode: 'ABC123',
      release: () async {
        releaseCalls += 1;
        log.add('access.close');
      },
    );
  }

  void emitPresence(LanGamePresence value) {
    _presence = value;
    _presences.add(value);
  }

  Future<void> dispose() => _presences.close();
}

final class _FakeGameShareGatewayFactory implements GameShareGatewayFactory {
  _FakeGameShareGatewayFactory(this.gateway);

  final GameWebGateway gateway;
  Completer<GameWebGateway>? result;
  int startCalls = 0;
  GameShareGatewayRequest? lastRequest;

  @override
  Future<GameWebGateway> start(GameShareGatewayRequest request) {
    startCalls += 1;
    lastRequest = request;
    return result?.future ?? Future<GameWebGateway>.value(gateway);
  }
}

final class _FakeGameWebGateway implements GameWebGateway {
  _FakeGameWebGateway({required List<Uri> shareLinksResult, required this.log})
    : shareLinksResult = List<Uri>.of(shareLinksResult);

  final List<String> log;
  final List<Uri> shareLinksResult;
  int shareLinksCalls = 0;
  int closeCalls = 0;

  @override
  int get port => 4100;

  @override
  String get invitationToken => _invitationToken;

  @override
  Uri get loopbackInvitationUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: playmeshGameInvitationPath,
    fragment: Uri(
      queryParameters: {playmeshGameInvitationTokenParameter: invitationToken},
    ).query,
  );

  @override
  Future<List<Uri>> shareLinks() async {
    shareLinksCalls += 1;
    return shareLinksResult;
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    log.add('gateway.close');
  }
}

final class _FakeLanGameDiscoveryPlatform implements LanGameDiscoveryPlatform {
  _FakeLanGameDiscoveryPlatform(this.log);

  final List<String> log;
  final List<LanGameAdvertisement> registerAdvertisements = [];
  final List<LanGameAdvertisement> updateAdvertisements = [];
  final List<_FakeLanGamePlatformRegistration> registrations = [];
  int registerCalls = 0;
  int failuresRemaining = 0;
  int updateFailuresRemaining = 0;
  int concurrentUpdates = 0;
  int maxConcurrentUpdates = 0;
  Completer<void>? registrationGate;
  Completer<void>? updateGate;
  Completer<void>? registrationCloseGate;
  LanGameAdvertisement? lastAdvertisement;
  int? lastPort;

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async {
    registerCalls += 1;
    registerAdvertisements.add(advertisement);
    lastAdvertisement = advertisement;
    lastPort = port;
    final gate = registrationGate;
    if (gate != null) await gate.future;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw const LanGamePlatformException(
        LanGamePlatformFailureKind.unavailable,
      );
    }
    final registration = _FakeLanGamePlatformRegistration(this);
    registrations.add(registration);
    return registration;
  }

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() =>
      throw UnsupportedError('测试不启动发现扫描');
}

final class _FakeLanGamePlatformRegistration
    implements LanGamePlatformRegistration, LanGamePlatformRegistrationUpdater {
  _FakeLanGamePlatformRegistration(this.platform);

  final _FakeLanGameDiscoveryPlatform platform;
  int closeCalls = 0;

  @override
  Future<void> update(LanGameAdvertisement advertisement) async {
    platform.updateAdvertisements.add(advertisement);
    platform.concurrentUpdates += 1;
    if (platform.concurrentUpdates > platform.maxConcurrentUpdates) {
      platform.maxConcurrentUpdates = platform.concurrentUpdates;
    }
    try {
      final gate = platform.updateGate;
      if (gate != null) await gate.future;
      if (platform.updateFailuresRemaining > 0) {
        platform.updateFailuresRemaining -= 1;
        throw const LanGamePlatformException(
          LanGamePlatformFailureKind.unavailable,
        );
      }
      platform.lastAdvertisement = advertisement;
    } finally {
      platform.concurrentUpdates -= 1;
    }
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    platform.log.add('registration.close');
    final gate = platform.registrationCloseGate;
    if (gate != null) await gate.future;
  }
}

final class _FakeGameRelayHostFactory implements GameRelayHostFactory {
  RelayHostSession? session;
  Completer<RelayHostSession>? result;
  int startCalls = 0;
  GameRelayHostRequest? request;
  Uri? authorityWebBaseUri;
  Uri? authorityCoreBaseUri;
  Uri? authorityEntryUri;

  @override
  Future<RelayHostSession> start({
    required GameRelayHostRequest request,
    required Uri authorityWebBaseUri,
    required Uri authorityCoreBaseUri,
    required Uri authorityEntryUri,
  }) {
    startCalls += 1;
    this.request = request;
    this.authorityWebBaseUri = authorityWebBaseUri;
    this.authorityCoreBaseUri = authorityCoreBaseUri;
    this.authorityEntryUri = authorityEntryUri;
    final pending = result;
    if (pending != null) return pending.future;
    final configured = session;
    if (configured == null) {
      return Future<RelayHostSession>.error(StateError('未配置 Relay session'));
    }
    return Future<RelayHostSession>.value(configured);
  }
}

final class _FakeRelayHostSession implements RelayHostSession {
  _FakeRelayHostSession({
    required this.joinUri,
    List<String>? log,
    RelayConnectionStatus initialStatus = RelayConnectionStatus.connected,
  }) : _log = log ?? <String>[],
       _status = initialStatus;

  final List<String> _log;
  final StreamController<RelayConnectionStatus> _statuses =
      StreamController<RelayConnectionStatus>.broadcast(sync: true);
  RelayConnectionStatus _status;
  int closeCalls = 0;

  @override
  final Uri joinUri;

  @override
  RelayConnectionStatus get status => _status;

  @override
  Stream<RelayConnectionStatus> get statuses => _statuses.stream;

  @override
  int get connectionCount => 0;

  @override
  DateTime get expiresAt => DateTime.utc(2026, 8, 19);

  void emit(RelayConnectionStatus status) {
    if (_statuses.isClosed) return;
    _status = status;
    _statuses.add(status);
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    _log.add('relay.close');
    if (!_statuses.isClosed) await _statuses.close();
  }
}

final class _CountingQrEncoder extends ShareQrCodeEncoder {
  final List<Uri> encodedUrls = <Uri>[];
  final List<Uri> retainedUrls = <Uri>[];
  Uri? failOnUrl;
  Uri? blockOnUrl;
  Completer<void>? encodeStarted;
  Completer<void>? allowEncode;
  int clearCalls = 0;

  @override
  Future<List<int>> encode(Uri url) async {
    encodedUrls.add(url);
    if (url == blockOnUrl) {
      final started = encodeStarted;
      if (started != null && !started.isCompleted) started.complete();
      await allowEncode?.future;
    }
    if (url == failOnUrl) {
      throw const GameShareException('qr_generation_failed', '测试注入二维码生成失败');
    }
    return <int>[encodedUrls.length];
  }

  @override
  void retain(Iterable<Uri> urls) {
    retainedUrls
      ..clear()
      ..addAll(urls);
  }

  @override
  void clear() {
    clearCalls += 1;
    retainedUrls.clear();
  }
}

Matcher _shareExceptionWithCode(String code) =>
    isA<GameShareException>().having((error) => error.code, 'code', code);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 2000; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('异步条件未在预期时间内满足');
}

Uri _lanInvitation(String host, int port, String suffix) => Uri(
  scheme: 'http',
  host: host,
  port: port,
  path: playmeshGameInvitationPath,
  fragment: Uri(
    queryParameters: {
      playmeshGameInvitationTokenParameter: '$_invitationToken-$suffix',
    },
  ).query,
);

const _invitationToken = 'abcdefghijklmnopqrstuvwxyzABCDEF';
final _defaultLanInvitation = _lanInvitation('192.168.1.20', 4100, 'lan');

final _relayRequest = GameRelayHostRequest(
  serverBaseUri: Uri.parse('https://relay.example.test/'),
  sourceToken: 'source-token',
  hostPath: '/host',
  clientPath: '/client',
  maxConnectionsPerTunnel: 8,
);

const _game = GameSummary(
  id: 'com.playmesh.coordinator',
  name: '协调器测试游戏',
  version: '1.0.0',
  description: '测试',
  minPlayers: 2,
  maxPlayers: 4,
  supportsMultiplayer: true,
  displayModeLabel: '多人多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);

const _soloGame = GameSummary(
  id: 'com.playmesh.coordinator.solo',
  name: '协调器单机测试游戏',
  version: '1.0.0',
  description: '测试',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '单机',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);
