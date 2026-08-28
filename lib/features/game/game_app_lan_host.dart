import 'dart:async';

import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_web/game_invitation.dart';
import '../../core/game_web/game_invitation_inspector.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/game_web/game_share_link_snapshot.dart';
import '../../core/network/lan_game_discovery_service.dart';

typedef AppLanQrScanner = Future<String?> Function();
typedef AppLanRemoteGameReplacer =
    Future<void> Function(RemoteGameLaunch launch);

/// 把共享发现、邀请预检和页面导航组合为 App SDK 的薄宿主适配器。
///
/// 本地 Authority、standalone 与远程加入页都复用这一实现；SDK feature 本身不接触
/// 发现缓存、邀请 token、网关、Relay 或 Flutter 页面。
class GameAppLanHostAdapter implements AppLanHost {
  factory GameAppLanHostAdapter({
    required String Function() gameId,
    required LanGameDiscoveryService discoveryService,
    required bool Function() isActive,
    required bool Function() isAuthority,
    required String? Function() selfInstanceId,
    required bool Function(GameInvitation invitation) isSelfInvitation,
    required AppLanQrScanner scanQr,
    required AppLanRemoteGameReplacer replaceGame,
    required Future<void> Function() publish,
    required Future<GameShareLinkSnapshot> Function() readShareLinks,
    Uri? coreBaseUri,
    Duration discoveryDuration = const Duration(seconds: 2),
    GameInvitationInspector? inspector,
  }) {
    final resolvedInspector =
        inspector ?? DefaultGameInvitationInspector(coreBaseUri: coreBaseUri);
    return GameAppLanHostAdapter._(
      gameId,
      discoveryService,
      isActive,
      isAuthority,
      selfInstanceId,
      isSelfInvitation,
      scanQr,
      replaceGame,
      publish,
      readShareLinks,
      discoveryDuration,
      resolvedInspector,
      inspector == null,
    );
  }

  GameAppLanHostAdapter._(
    this._gameId,
    this._discoveryService,
    this._isActive,
    this._isAuthority,
    this._selfInstanceId,
    this._isSelfInvitation,
    this._scanQr,
    this._replaceGame,
    this._publish,
    this._readShareLinks,
    this.discoveryDuration,
    this._inspector,
    this._ownsInspector,
  ) {
    _joinCoordinator = GameJoinCoordinator(
      inspector: _inspector,
      discoveredGames: _discoveryService,
    );
  }

  final String Function() _gameId;
  final LanGameDiscoveryService _discoveryService;
  final bool Function() _isActive;
  final bool Function() _isAuthority;
  final String? Function() _selfInstanceId;
  final bool Function(GameInvitation invitation) _isSelfInvitation;
  final AppLanQrScanner _scanQr;
  final AppLanRemoteGameReplacer _replaceGame;
  final Future<void> Function() _publish;
  final Future<GameShareLinkSnapshot> Function() _readShareLinks;
  final GameInvitationInspector _inspector;
  final bool _ownsInspector;
  final Duration discoveryDuration;
  late final GameJoinCoordinator _joinCoordinator;
  final Set<String> _discoveredInstances = {};
  LanGameDiscoveryLease? _discoveryLease;
  Future<LanGameDiscoveryLease>? _discoveryStartOperation;
  Future<void>? _discoveryReleaseOperation;
  int _documentGeneration = 0;
  bool _navigationStarted = false;
  bool _closed = false;

  @override
  Future<List<AppLanDiscoveredGame>> discoverGames() async {
    _requireActive();
    final generation = _documentGeneration;
    final expectedGameId = _gameId();
    final lease = await _acquireDiscoveryLease(generation);
    await Future<void>.delayed(discoveryDuration);
    _checkGeneration(generation);
    final snapshot = lease.current;
    if (snapshot.state != LanGameDiscoveryState.ready) {
      throw const SdkCommandException('discovery_unavailable', '局域网发现不可用');
    }
    final selfInstanceId = _selfInstanceId();
    final games = snapshot.games
        .where(
          (game) =>
              game.gameId == expectedGameId &&
              game.instanceId != selfInstanceId,
        )
        .toList(growable: false);
    _discoveredInstances
      ..clear()
      ..addAll(games.map((game) => game.instanceId));
    return games
        .map(
          (game) => AppLanDiscoveredGame(
            instanceId: game.instanceId,
            gameId: game.gameId,
            name: game.name,
            host: game.host,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<AppLanJoinAction> prepareDiscoveredJoin(String instanceId) async {
    _requireActive();
    if (!_discoveredInstances.contains(instanceId)) {
      throw const SdkCommandException('discovery_not_found', '发现的游戏已经失效');
    }
    return _prepareJoin(
      (context) =>
          _joinCoordinator.prepareDiscovered(instanceId, context: context),
    );
  }

  @override
  Future<AppLanJoinAction> prepareInvitationJoin(String invitationUrl) {
    _requireActive();
    return _prepareJoin(
      (context) =>
          _joinCoordinator.prepareLink(invitationUrl, context: context),
    );
  }

  @override
  Future<AppLanJoinAction> prepareQrJoin() async {
    _requireActive();
    final raw = await _scanQr();
    _requireActive();
    if (raw == null) {
      throw const SdkCommandException('cancelled', '用户已取消操作');
    }
    return prepareInvitationJoin(raw);
  }

  @override
  Future<void> setPublished() async {
    _requireAuthority();
    await _publish();
  }

  @override
  Future<GameShareLinkSnapshot> getShareLinks() async {
    _requireAuthority();
    return _readShareLinks();
  }

  @override
  void resetDocument() {
    if (_closed) return;
    _documentGeneration += 1;
    _discoveredInstances.clear();
    _navigationStarted = false;
    unawaited(_releaseDiscoveryLease());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _documentGeneration += 1;
    _discoveredInstances.clear();
    final startOperation = _discoveryStartOperation;
    if (startOperation != null) {
      try {
        await startOperation;
      } on Object {
        // 文档结束会使进行中的 acquire 主动失败并回收租约。
      }
    }
    await _releaseDiscoveryLease();
    if (_ownsInspector) await _inspector.close();
  }

  Future<LanGameDiscoveryLease> _acquireDiscoveryLease(int generation) async {
    final release = _discoveryReleaseOperation;
    if (release != null) {
      await release;
      _checkGeneration(generation);
      return _acquireDiscoveryLease(generation);
    }
    final existing = _discoveryLease;
    if (existing != null) return existing;
    final active = _discoveryStartOperation;
    if (active != null) {
      try {
        await active;
      } on Object {
        // 前一文档的 acquire 被取消后，当前文档重新获取。
      }
      _checkGeneration(generation);
      final acquired = _discoveryLease;
      if (acquired != null) return acquired;
      return _acquireDiscoveryLease(generation);
    }
    late final Future<LanGameDiscoveryLease> operation;
    operation = _discoveryService
        .startDiscovery()
        .then((lease) async {
          if (!_isCurrent(generation)) {
            await lease.close();
            throw const SdkCommandException(
              'operation_cancelled',
              '游戏退出，操作已取消',
            );
          }
          _discoveryLease = lease;
          return lease;
        })
        .whenComplete(() {
          if (identical(_discoveryStartOperation, operation)) {
            _discoveryStartOperation = null;
          }
        });
    _discoveryStartOperation = operation;
    return operation;
  }

  Future<void> _releaseDiscoveryLease() async {
    final active = _discoveryReleaseOperation;
    if (active != null) return active;
    final lease = _discoveryLease;
    _discoveryLease = null;
    if (lease == null) return;
    late final Future<void> operation;
    operation = lease.close().whenComplete(() {
      if (identical(_discoveryReleaseOperation, operation)) {
        _discoveryReleaseOperation = null;
      }
    });
    _discoveryReleaseOperation = operation;
    await operation;
  }

  Future<AppLanJoinAction> _prepareJoin(
    Future<RemoteGameLaunch> Function(GameJoinContext context) prepare,
  ) async {
    final generation = _documentGeneration;
    final context = GameJoinContext(
      expectedGameId: _gameId(),
      selfInstanceId: _selfInstanceId(),
      isSelfInvitation: _isSelfInvitation,
      isCancelled: () => !_isCurrent(generation),
    );
    try {
      final launch = await prepare(context);
      try {
        _checkGeneration(generation);
      } on Object {
        await launch.close();
        rethrow;
      }
      return AppLanJoinAction(() async {
        try {
          await _navigate(launch, generation);
        } finally {
          await launch.close();
        }
      });
    } on GameJoinException catch (error, stackTrace) {
      throw SdkCommandException(
        error.code,
        error.message,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'prepare_join'},
      );
    }
  }

  Future<void> _navigate(RemoteGameLaunch launch, int generation) async {
    _checkGeneration(generation);
    if (_navigationStarted) return;
    _navigationStarted = true;
    await _replaceGame(launch);
  }

  void _requireAuthority() {
    _requireActive();
    if (!_isAuthority()) {
      throw const SdkCommandException('not_authority', '当前页面不是本机房主');
    }
  }

  void _requireActive() {
    if (_closed || !_isActive() || _navigationStarted) {
      throw const SdkCommandException('game_context_unavailable', '当前游戏上下文不可用');
    }
  }

  bool _isCurrent(int generation) =>
      !_closed &&
      !_navigationStarted &&
      generation == _documentGeneration &&
      _isActive();

  void _checkGeneration(int generation) {
    if (!_isCurrent(generation)) {
      throw const SdkCommandException('operation_cancelled', '游戏退出，操作已取消');
    }
  }
}
