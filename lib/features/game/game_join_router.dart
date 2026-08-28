import 'package:flutter/material.dart';

import '../../core/game_web/game_join_coordinator.dart';
import '../../core/network/lan_game_discovery_service.dart';
import '../../core/relay/relay_tunnel.dart';
import 'remote_game_page.dart';

/// 远程游戏页面的唯一 Flutter 导航适配器。
///
/// 邀请解析、探测和 gameId 校验均在 [GameJoinCoordinator] 完成；此类只把已经
/// 验证的 [RemoteGameLaunch] 转为现有 [RemoteGamePage]。
class GameJoinRouter {
  const GameJoinRouter();

  Future<void> push(
    BuildContext context, {
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    Uri? coreControlBaseUri,
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) async {
    final relayClientSession = launch.takeRelayClientSession();
    try {
      await Navigator.of(context).push<void>(
        _route(
          launch: launch,
          relayClientSession: relayClientSession,
          userId: userId,
          nickname: nickname,
          coreControlBaseUri: coreControlBaseUri,
          discoveryService: discoveryService,
          onNicknameChanged: onNicknameChanged,
        ),
      );
    } catch (_) {
      await relayClientSession?.close();
      rethrow;
    }
  }

  Future<void> replace(
    BuildContext context, {
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    Uri? coreControlBaseUri,
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) async {
    final relayClientSession = launch.takeRelayClientSession();
    try {
      await Navigator.of(context).pushReplacement<void, void>(
        _route(
          launch: launch,
          relayClientSession: relayClientSession,
          userId: userId,
          nickname: nickname,
          coreControlBaseUri: coreControlBaseUri,
          discoveryService: discoveryService,
          onNicknameChanged: onNicknameChanged,
        ),
      );
    } catch (_) {
      await relayClientSession?.close();
      rethrow;
    }
  }

  MaterialPageRoute<void> _route({
    required RemoteGameLaunch launch,
    required RelayClientSession? relayClientSession,
    required String userId,
    required String nickname,
    required Uri? coreControlBaseUri,
    required LanGameDiscoveryService? discoveryService,
    required Future<void> Function(String nickname)? onNicknameChanged,
  }) => MaterialPageRoute<void>(
    settings: RouteSettings(name: RemoteGamePage.routeName, arguments: launch),
    builder: (_) => RemoteGamePage(
      entryUri: launch.entryUri,
      userId: userId,
      nickname: nickname,
      coreControlBaseUri: coreControlBaseUri,
      preparedRelayClientSession: relayClientSession,
      resolvedEntryPath: launch.resolvedEntryPath,
      gameId: launch.gameId,
      gameName: launch.gameName,
      sourceInstanceId: launch.sourceInstanceId,
      discoveryService: discoveryService,
      onNicknameChanged: onNicknameChanged,
    ),
  );
}
