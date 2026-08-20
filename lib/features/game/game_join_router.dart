import 'package:flutter/material.dart';

import '../../core/game_web/game_join_coordinator.dart';
import '../../core/network/lan_game_discovery_service.dart';
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
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) => Navigator.of(context).push<void>(
    _route(
      launch: launch,
      userId: userId,
      nickname: nickname,
      discoveryService: discoveryService,
      onNicknameChanged: onNicknameChanged,
    ),
  );

  Future<void> replace(
    BuildContext context, {
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    LanGameDiscoveryService? discoveryService,
    Future<void> Function(String nickname)? onNicknameChanged,
  }) => Navigator.of(context).pushReplacement<void, void>(
    _route(
      launch: launch,
      userId: userId,
      nickname: nickname,
      discoveryService: discoveryService,
      onNicknameChanged: onNicknameChanged,
    ),
  );

  MaterialPageRoute<void> _route({
    required RemoteGameLaunch launch,
    required String userId,
    required String nickname,
    required LanGameDiscoveryService? discoveryService,
    required Future<void> Function(String nickname)? onNicknameChanged,
  }) => MaterialPageRoute<void>(
    settings: RouteSettings(name: RemoteGamePage.routeName, arguments: launch),
    builder: (_) => RemoteGamePage(
      entryUri: launch.entryUri,
      userId: userId,
      nickname: nickname,
      gameId: launch.gameId,
      gameName: launch.gameName,
      sourceInstanceId: launch.sourceInstanceId,
      discoveryService: discoveryService,
      onNicknameChanged: onNicknameChanged,
    ),
  );
}
