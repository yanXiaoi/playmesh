import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/catalog/game_catalog_models.dart';
import '../../core/catalog/online_game_catalog.dart';
import '../../core/developer/developer_event_hub.dart';
import '../../core/developer/developer_run_controller.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/game_runtime_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_sdk/standalone_game_runtime_bridge.dart';
import '../../core/game_package/game_web_resource_source.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/game_web/game_share_coordinator.dart';
import '../../core/game_web/game_share_link_snapshot.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/network/lan_game_discovery_service.dart';
import '../../core/profile/user_profile_store.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/session/go_core_session_client.dart';
import '../../core/session/game_session.dart';
import '../../core/storage/game_storage_service.dart';
import '../../models/game_summary.dart';
import '../../models/user_profile.dart';
import 'game_app_lan_host.dart';
import 'game_invitation_scanner_page.dart';
import 'game_launcher.dart';
import 'game_join_router.dart';
import 'game_orientation_controller.dart';

typedef GamePreviewBuilder = Widget Function(GameSummary game);

class _LocalAvatar {
  const _LocalAvatar(this.pngBytes, this.sha256);

  final Uint8List pngBytes;
  final String sha256;
}

class GameLaunchArguments {
  const GameLaunchArguments({
    required this.game,
    required this.enterFullscreenOnLaunch,
    this.developerProjectId,
    this.developerRunId,
    this.developerResourceSession,
  });

  final GameSummary game;
  final bool enterFullscreenOnLaunch;
  final String? developerProjectId;
  final String? developerRunId;
  final DeveloperResourceSession? developerResourceSession;
}

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.game,
    required this.enterFullscreenOnLaunch,
    this.localUserId = 'u_local',
    this.localNickname = playmeshDefaultLocalNickname,
    this.localProfile,
    this.onNicknameChanged,
    this.previewBuilder,
    this.orientationController,
    this.goCoreRuntime,
    this.developerProjectId,
    this.developerRunId,
    this.developerResourceSession,
    this.catalogController,
    this.lanGameDiscoveryService,
  });

  static const routeName = '/game';
  static const gameSurfaceKey = Key('game-surface');

  static Key runtimeKey(int generation) {
    return ValueKey('game-runtime-$generation');
  }

  final GameSummary game;
  final bool enterFullscreenOnLaunch;
  final String localUserId;
  final String localNickname;
  final UserProfile? localProfile;
  final Future<void> Function(String nickname)? onNicknameChanged;
  final GamePreviewBuilder? previewBuilder;
  final GameOrientationController? orientationController;
  final GoCoreRuntime? goCoreRuntime;
  final String? developerProjectId;
  final String? developerRunId;
  final DeveloperResourceSession? developerResourceSession;
  final GameCatalogController? catalogController;
  final LanGameDiscoveryService? lanGameDiscoveryService;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  static const _sdkShareReopenCooldown = Duration(milliseconds: 800);

  int _runtimeGeneration = 0;
  int _configurationGeneration = 0;
  final GlobalKey<_ShareOverlayState> _shareOverlayKey =
      GlobalKey<_ShareOverlayState>();
  late final GameOrientationController _orientationController;
  Future<void> _orientationOperation = Future<void>.value();
  Object? _fullscreenError;
  bool _sessionReady = false;
  Object? _sessionError;
  GoCoreSessionClient? _sessionClient;
  GameRuntimeBridge? _bridge;
  StandaloneGameRuntimeBridge? _soloBridge;
  GameWebResourceSource? _gameResourceSource;
  GameShareCoordinator? _shareCoordinator;
  StreamSubscription<GameShareCoordinatorState>? _shareStateSubscription;
  GameShareCoordinatorState? _shareState;
  GameShareLink? _selectedShareLink;
  bool _shareVisible = false;
  Future<void>? _shareOpenOperation;
  FocusNode? _focusBeforeShare;
  DateTime? _shareClosedAt;
  String? _shareErrorCode;
  String? _publicationErrorCode;
  bool _disposing = false;
  bool _allowPop = false;
  Future<void>? _exitOperation;
  Future<void>? _closeSessionOperation;
  StreamSubscription<Map<String, Object?>>? _roomSubscription;
  void Function()? _unregisterDeveloperRestart;
  void Function()? _unregisterDeveloperStop;
  void Function()? _unregisterDeveloperJavaScript;
  DeveloperWebViewJavaScriptExecutor? _developerJavaScriptExecutor;
  VoidCallback? _gameSystemBackHandler;
  String? _developerRunId;
  OnlineGameSourceProbe? _relaySource;
  List<OnlineGameSourceProbe> _relaySources = const [];
  bool _relaySourcesLoading = false;
  String? _relayErrorCode;
  late final LanGameDiscoveryService _lanGameDiscoveryService;
  late final bool _ownsLanGameDiscoveryService;
  late final GameAppLanHostAdapter _appLanHost;
  late String _currentNickname;
  Future<void> _nicknameUpdateTail = Future<void>.value();

  GameSdkBridge? get _webViewBridge => _bridge ?? _soloBridge;
  bool get _canShareFromAppSdk =>
      _soloBridge != null || _bridge?.connection.isAuthority == true;
  bool get _shouldEnterFullscreenOnLaunch => widget.enterFullscreenOnLaunch;
  GameOrientation get _runtimeOrientation => widget.game.orientation;

  @override
  void initState() {
    super.initState();
    _currentNickname = widget.localNickname;
    _gameResourceSource = resolveGameWebResourceSource(
      widget.game,
      widget.developerResourceSession,
    );
    final injectedDiscoveryService = widget.lanGameDiscoveryService;
    _lanGameDiscoveryService =
        injectedDiscoveryService ?? LanGameDiscoveryService();
    _ownsLanGameDiscoveryService = injectedDiscoveryService == null;
    _appLanHost = GameAppLanHostAdapter(
      gameId: () => widget.game.id,
      discoveryService: _lanGameDiscoveryService,
      isActive: () =>
          mounted &&
          !_disposing &&
          _sessionReady &&
          _closeSessionOperation == null,
      isAuthority: () => _canShareFromAppSdk,
      selfInstanceId: () => _shareCoordinator?.instanceId,
      isSelfInvitation: (invitation) =>
          _shareCoordinator?.state.snapshot.links.any(
            (link) => link.url == invitation.entryUri,
          ) ??
          false,
      scanQr: _scanQrFromAppSdk,
      replaceGame: _replaceWithRemoteGame,
      publish: _publishFromAppSdk,
      readShareLinks: _readShareLinksFromAppSdk,
    );
    _developerRunId = widget.developerRunId;
    WidgetsBinding.instance.addObserver(this);
    _orientationController =
        widget.orientationController ?? SystemGameOrientationController();
    if (_shouldEnterFullscreenOnLaunch) {
      _applyOrientation(_runtimeOrientation);
    }
    _registerDeveloperHandlers();
    _initializeSession();
  }

  @override
  void didUpdateWidget(GamePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localNickname != widget.localNickname &&
        _currentNickname == oldWidget.localNickname) {
      _currentNickname = widget.localNickname;
    }
    final oldOrientation = oldWidget.game.orientation;
    final oldShouldEnterFullscreen = oldWidget.enterFullscreenOnLaunch;
    if (_shouldEnterFullscreenOnLaunch &&
        (!oldShouldEnterFullscreen || oldOrientation != _runtimeOrientation)) {
      _applyOrientation(_runtimeOrientation);
    }
    final developerBindingChanged =
        oldWidget.developerProjectId != widget.developerProjectId ||
        oldWidget.developerRunId != widget.developerRunId ||
        !identical(oldWidget.goCoreRuntime, widget.goCoreRuntime);
    final runtimeChanged =
        developerBindingChanged || _runtimeIdentityChanged(oldWidget);
    if (developerBindingChanged) {
      final oldProjectId = oldWidget.developerProjectId;
      if (oldProjectId != null) {
        oldWidget.goCoreRuntime?.reportDeveloperGameStopped(
          oldProjectId,
          expectedRunId: _developerRunId,
        );
      }
      _unregisterDeveloperHandlers();
      _developerRunId = widget.developerRunId;
      _registerDeveloperHandlers();
    }
    if (runtimeChanged) {
      final generation = ++_configurationGeneration;
      unawaited(_resetForWidgetUpdate(generation));
    }
  }

  bool _runtimeIdentityChanged(GamePage oldWidget) {
    final oldGame = oldWidget.game;
    final game = widget.game;
    final oldEntry = oldGame.entry;
    final entry = game.entry;
    return oldGame.id != game.id ||
        oldGame.name != game.name ||
        oldGame.version != game.version ||
        oldGame.sdkVersion != game.sdkVersion ||
        oldGame.appSdkVersion != game.appSdkVersion ||
        oldGame.description != game.description ||
        oldGame.minPlayers != game.minPlayers ||
        oldGame.maxPlayers != game.maxPlayers ||
        oldGame.supportsMultiplayer != game.supportsMultiplayer ||
        oldGame.displayMode != game.displayMode ||
        oldGame.orientation != game.orientation ||
        oldGame.controllerOrientation != game.controllerOrientation ||
        oldEntry.gameEntryPath != entry.gameEntryPath ||
        oldEntry.controllerEntryPath != entry.controllerEntryPath ||
        oldEntry.packageRootFilePath != entry.packageRootFilePath ||
        !_sameDeveloperResourceSession(
          oldWidget.developerResourceSession,
          widget.developerResourceSession,
        ) ||
        !setEquals(oldGame.capabilities.required, game.capabilities.required) ||
        !setEquals(
          oldGame.capabilities.controllerRequired,
          game.capabilities.controllerRequired,
        ) ||
        oldWidget.localUserId != widget.localUserId ||
        (oldWidget.previewBuilder == null) != (widget.previewBuilder == null);
  }

  bool _sameDeveloperResourceSession(
    DeveloperResourceSession? left,
    DeveloperResourceSession? right,
  ) {
    if (identical(left, right)) return true;
    return left != null &&
        right != null &&
        left.projectId == right.projectId &&
        left.resourceBaseUri == right.resourceBaseUri &&
        left.credential == right.credential &&
        left.expiresAt == right.expiresAt;
  }

  bool _isCurrentConfiguration(int generation) =>
      mounted && !_disposing && generation == _configurationGeneration;

  void _registerDeveloperHandlers() {
    final developerProjectId = widget.developerProjectId;
    final runtime = widget.goCoreRuntime;
    if (developerProjectId == null || runtime == null) return;
    _unregisterDeveloperRestart = runtime.registerDeveloperGameRestartHandler(
      developerProjectId,
      _restartGame,
      expectedRunId: _developerRunId,
    );
    _unregisterDeveloperStop = runtime.registerDeveloperGameStopHandler(
      developerProjectId,
      _exitGame,
      expectedRunId: _developerRunId,
    );
    _unregisterDeveloperJavaScript = runtime
        .registerDeveloperGameJavaScriptExecutor(
          developerProjectId,
          _executeDeveloperJavaScript,
          expectedRunId: _developerRunId,
        );
  }

  void _unregisterDeveloperHandlers() {
    _unregisterDeveloperRestart?.call();
    _unregisterDeveloperRestart = null;
    _unregisterDeveloperStop?.call();
    _unregisterDeveloperStop = null;
    _unregisterDeveloperJavaScript?.call();
    _unregisterDeveloperJavaScript = null;
  }

  Future<void> _resetForWidgetUpdate(int generation) async {
    _developerJavaScriptExecutor = null;
    _shareOpenOperation = null;
    _focusBeforeShare = null;
    _shareClosedAt = null;
    await _closeSession();
    if (!_isCurrentConfiguration(generation)) return;
    _gameResourceSource = resolveGameWebResourceSource(
      widget.game,
      widget.developerResourceSession,
    );
    setState(() {
      _runtimeGeneration += 1;
      _sessionReady = false;
      _sessionError = null;
      _shareVisible = false;
      _shareErrorCode = null;
      _publicationErrorCode = null;
      _fullscreenError = null;
      _relaySources = const [];
      _relaySourcesLoading = false;
      _relayErrorCode = null;
    });
    await _initializeSession();
  }

  @override
  void dispose() {
    _disposing = true;
    _configurationGeneration += 1;
    _unregisterDeveloperHandlers();
    _developerJavaScriptExecutor = null;
    final developerProjectId = widget.developerProjectId;
    if (developerProjectId != null) {
      widget.goCoreRuntime?.reportDeveloperGameStopped(
        developerProjectId,
        expectedRunId: _developerRunId,
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeSession());
    unawaited(_appLanHost.close());
    if (_ownsLanGameDiscoveryService) {
      unawaited(_lanGameDiscoveryService.dispose());
    }
    unawaited(
      _orientationOperation.then(
        (_) => _restoreDisplayState(),
        onError: (_) => _restoreDisplayState(),
      ),
    );
    super.dispose();
  }

  Future<void> _restoreDisplayState() async {
    try {
      if (!_shouldEnterFullscreenOnLaunch) {
        await _orientationController.exitFullscreen();
      }
    } finally {
      await _orientationController.restore();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_webViewBridge?.notifyLifecycle('resume'));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_webViewBridge?.notifyLifecycle('pause'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          key: GamePage.gameSurfaceKey,
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _buildGameRuntime()),
            if (_fullscreenError != null && !_shareVisible)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.paddingOf(context).bottom + 12,
                child: _FullscreenNotice(
                  error: _fullscreenError!,
                  onRetry: () => _applyOrientation(
                    _runtimeOrientation,
                    userInitiated: true,
                  ),
                  onDismiss: () => setState(() => _fullscreenError = null),
                ),
              ),
            if (_shareVisible)
              Positioned.fill(
                child: _ShareOverlay(
                  key: _shareOverlayKey,
                  joinCode: _bridge?.connection.snapshot.joinCode,
                  links:
                      _shareState?.snapshot.lanLinks ?? const <GameShareLink>[],
                  selectedLink: _selectedShareLink,
                  loading: _shareState?.channel == ShareChannelState.starting,
                  error: _shareErrorCode == null
                      ? null
                      : context.tr('game.share_unavailable'),
                  publicationError:
                      _publicationErrorCode == null ||
                          (_shareState?.snapshot.lanLinks.isEmpty ?? true)
                      ? null
                      : context.tr('game.nearby_discovery_unavailable'),
                  players:
                      _bridge?.connection.snapshot.players ??
                      const <GameSessionPlayer>[],
                  relaySources: _relaySources,
                  relaySourcesLoading: _relaySourcesLoading,
                  relayConnecting:
                      _shareState?.relayStatus ==
                      RelayConnectionStatus.connecting,
                  relaySource: _relaySource,
                  relayLink: _shareState?.snapshot.wanLink,
                  relayStatus:
                      _shareState?.relayStatus ??
                      RelayConnectionStatus.disconnected,
                  relayError: _relayErrorCode == null
                      ? null
                      : context.tr(_relayErrorCode!),
                  onClose: _hideShare,
                  onSelectLink: (link) {
                    setState(() => _selectedShareLink = link);
                  },
                  onLoadRelaySources: _loadRelaySources,
                  onConnectRelay: _connectRelay,
                  onDisconnectRelay: _disconnectRelay,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleSystemBack() {
    if (_shareVisible) {
      unawaited(_hideShare());
      return;
    }
    final handler = _gameSystemBackHandler;
    if (handler != null) {
      handler();
      return;
    }
    unawaited(_returnToPrevious());
  }

  void _setGameSystemBackHandler(VoidCallback? handler) {
    _gameSystemBackHandler = handler;
  }

  Widget _buildGameRuntime() {
    if (!_sessionReady) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_sessionError != null) {
      return _GameStartFailure(
        error: _sessionError!,
        onRetry: _initializeSession,
      );
    }

    return KeyedSubtree(
      key: GamePage.runtimeKey(_runtimeGeneration),
      child:
          widget.previewBuilder?.call(widget.game) ??
          GameLauncher(
            game: widget.game,
            bridge: _webViewBridge,
            resourceSource: _gameResourceSource,
            localUserId: widget.localUserId,
            localNickname: _currentNickname,
            developerResourceSession: widget.developerResourceSession,
            appLanHost: _appLanHost,
            onOpenSharePanel: _canShareFromAppSdk ? _openShareFromAppSdk : null,
            onExitRequested: _returnToPrevious,
            onNicknameUpdate: _updateNicknameFromSdk,
            onSystemBackHandlerChanged: _setGameSystemBackHandler,
            onJavaScriptExecutorChanged: (executor) {
              _developerJavaScriptExecutor = executor;
            },
          ),
    );
  }

  Future<Object?> _updateNicknameFromSdk(Map<String, Object?> payload) {
    final previous = _nicknameUpdateTail;
    late final Future<Object?> operation;
    operation = () async {
      try {
        await previous;
      } on Object {
        // 队列中的前一项失败不阻断后续改名。
      }
      return _performNicknameUpdate(payload);
    }();
    _nicknameUpdateTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Object?> _performNicknameUpdate(Map<String, Object?> payload) async {
    if (payload.length != 1 || !payload.containsKey('nickname')) {
      throw const SdkCommandException('invalid_argument', '昵称参数无效');
    }
    final rawNickname = payload['nickname'];
    if (rawNickname is! String) {
      throw const SdkCommandException('invalid_argument', '昵称参数无效');
    }
    final normalized = rawNickname.trim();
    if (normalized.isEmpty || normalized.runes.length > 32) {
      throw const SdkCommandException('invalid_argument', '昵称必须为 1 至 32 个字符');
    }
    final connection = _bridge?.connection;
    if (connection == null) {
      throw const SdkCommandException(
        'nickname_update_unavailable',
        '当前游戏没有可更新昵称的多人会话',
      );
    }
    if (connection.snapshot.displayMode == 'single_screen_multiplayer') {
      throw const SdkCommandException(
        'nickname_update_unavailable',
        '公共 Authority 屏没有可修改昵称的当前玩家',
      );
    }
    final expectedPlayerId = connection.currentPlayer.id;
    final previousNickname = _currentNickname;
    await _persistLocalNickname(normalized);
    Object? ambiguousError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final player = await connection.updateNickname(normalized);
        if (player.id != expectedPlayerId || player.nickname != normalized) {
          throw const FormatException('Core 昵称更新响应身份不匹配');
        }
        return _nicknameUpdatePayload(connection, player);
      } on GameSessionException catch (error) {
        if (error.statusCode >= 400 && error.statusCode < 500) {
          await _restoreLocalNickname(previousNickname);
          rethrow;
        }
        ambiguousError = error;
      } on Object catch (error) {
        ambiguousError = error;
      }
    }
    try {
      final snapshot = await connection.refreshSnapshot();
      final player = snapshot.players
          .where((candidate) => candidate.id == expectedPlayerId)
          .firstOrNull;
      if (player == null) {
        throw const FormatException('Core 快照缺少当前玩家');
      }
      if (player.nickname == normalized) {
        return _nicknameUpdatePayload(connection, player);
      }
      await _persistLocalNickname(player.nickname);
      throw SdkCommandException(
        'nickname_update_failed',
        'Core 未提交昵称更新：${ambiguousError ?? '未知错误'}',
      );
    } on SdkCommandException {
      rethrow;
    } on Object {
      // 无法判断 Core 是否已提交时保留本地意图；下次重连会携带该昵称完成对账。
      throw const SdkCommandException(
        'nickname_update_pending',
        '昵称已保存在本机，等待与房间重新同步',
      );
    }
  }

  Map<String, Object?> _nicknameUpdatePayload(
    GameSessionConnection connection,
    GameSessionPlayer player,
  ) => {
    'session': connection.snapshot.toJson(),
    'player': player.toJson(),
    'identity': {
      'userId': widget.localUserId,
      'nickname': player.nickname,
      'source': 'playmesh_app',
    },
  };

  Future<void> _restoreLocalNickname(String nickname) async {
    try {
      await _persistLocalNickname(nickname);
    } on Object {
      _currentNickname = nickname;
    }
  }

  Future<void> _persistLocalNickname(String nickname) async {
    final callback = widget.onNicknameChanged;
    if (callback != null) {
      await callback(nickname);
    } else {
      final fallback =
          widget.localProfile ??
          UserProfile(userId: widget.localUserId, nickname: _currentNickname);
      final profile = await const UserProfileStore().load(fallback);
      if (profile.userId != widget.localUserId) {
        throw const SdkCommandException('identity_mismatch', '本机身份与当前玩家不一致');
      }
      await const UserProfileStore().save(profile.copyWith(nickname: nickname));
    }
    _currentNickname = nickname;
  }

  void _applyOrientation(
    GameOrientation orientation, {
    bool userInitiated = false,
  }) {
    if (mounted && _fullscreenError != null) {
      setState(() => _fullscreenError = null);
    }
    _orientationOperation = userInitiated
        ? _orientationController.enter(orientation)
        : _orientationOperation.then(
            (_) => _orientationController.enter(orientation),
            onError: (_) => _orientationController.enter(orientation),
          );
    unawaited(
      _orientationOperation.then(
        (_) {
          if (mounted) {
            setState(() {
              _fullscreenError = null;
            });
          }
        },
        onError: (Object error) {
          debugPrint('进入游戏全屏失败: $error');
          if (mounted) {
            setState(() {
              _fullscreenError = error;
            });
          }
        },
      ),
    );
  }

  Future<void> _initializeSession() async {
    final configurationGeneration = _configurationGeneration;
    final game = widget.game;
    final runtime = widget.goCoreRuntime;
    final localUserId = widget.localUserId;
    final localNickname = widget.localNickname;
    final developerProjectId = widget.developerProjectId;
    if (_sessionReady || _sessionError != null) {
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      _focusBeforeShare = null;
      _shareClosedAt = null;
      setState(() {
        _runtimeGeneration += 1;
        _shareVisible = false;
        _fullscreenError = null;
      });
    }
    if (!_isCurrentConfiguration(configurationGeneration)) return;
    _clearLogsForNewRun();
    if (widget.previewBuilder != null) {
      if (_isCurrentConfiguration(configurationGeneration)) {
        setState(() {
          _sessionReady = true;
          _sessionError = null;
        });
      }
      return;
    }
    if (!game.supportsMultiplayer || runtime == null) {
      await _initializeStandaloneSession(
        configurationGeneration: configurationGeneration,
        game: game,
        localUserId: localUserId,
        localNickname: localNickname,
        developerProjectId: developerProjectId,
        runtime: runtime,
      );
      return;
    }
    if (_isCurrentConfiguration(configurationGeneration)) {
      setState(() {
        _sessionReady = false;
        _sessionError = null;
      });
    }
    try {
      await _closeSession();
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      final localAvatar = await _loadLocalAvatar(
        userId: localUserId,
        nickname: localNickname,
      );
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      await runtime.start();
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      final client = GoCoreSessionClient(baseUri: runtime.endpoint);
      final connection = await client.create(
        gameId: game.id,
        displayMode: game.displayMode,
        minPlayers: game.minPlayers,
        maxPlayers: game.maxPlayers,
        nickname: localNickname,
      );
      final storage = await GameStorageService.create(gameId: game.id);
      if (!_isCurrentConfiguration(configurationGeneration)) {
        await connection.close();
        await storage.close();
        client.close();
        return;
      }
      if (connection.isAuthority) {
        // 进程崩溃可能遗留使用固定文件名的平台头像文件。
        // 新创建的 Authority 会话拥有全新的头像命名空间，
        // 必须在任何本地玩家或加入端玩家同步前将其清空。
        await storage.clearSystemAvatars();
        if (!_isCurrentConfiguration(configurationGeneration)) {
          await connection.close();
          await storage.close();
          client.close();
          return;
        }
      }
      late final GameRuntimeBridge bridge;
      bridge = GameRuntimeBridge(
        connection,
        storage: storage,
        gameName: game.name,
        tags: game.tags,
        requiredCapabilities: game.capabilities
            .requiredForRole(controller: false)
            .toList(),
        onNicknameUpdate: (nickname) async => Map<String, Object?>.from(
          await _updateNicknameFromSdk({'nickname': nickname}) as Map,
        ),
      );
      await _syncLocalAvatar(connection, localAvatar);
      if (!_isCurrentConfiguration(configurationGeneration)) {
        await bridge.close();
        client.close();
        return;
      }
      final shareCoordinator = _createShareCoordinator(bridge: bridge);
      _attachShareCoordinator(shareCoordinator);
      setState(() {
        _sessionClient = client;
        _bridge = bridge;
        _sessionReady = true;
      });
      await _roomSubscription?.cancel();
      _roomSubscription = connection.messages.listen((message) {
        if (!_isCurrentConfiguration(configurationGeneration) ||
            !identical(_bridge, bridge)) {
          return;
        }
        if (message['type'] == 'transport.status' &&
            message['state'] == 'reconnected') {
          _resetTransientUiForReconnect();
          return;
        }
        if (message['session'] is! Map) return;
        setState(() {});
      });
      if (developerProjectId != null &&
          _isCurrentConfiguration(configurationGeneration)) {
        await _ensureShare(showOverlay: false);
      }
    } on Object catch (error) {
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      if (developerProjectId != null) {
        runtime.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (_isCurrentConfiguration(configurationGeneration)) {
        setState(() {
          _sessionError = error;
          _sessionReady = true;
        });
      }
    }
  }

  Future<void> _initializeStandaloneSession({
    required int configurationGeneration,
    required GameSummary game,
    required String localUserId,
    required String localNickname,
    required String? developerProjectId,
    required GoCoreRuntime? runtime,
  }) async {
    if (_isCurrentConfiguration(configurationGeneration)) {
      setState(() {
        _sessionReady = false;
        _sessionError = null;
      });
    }
    try {
      await _closeSession();
      if (!_isCurrentConfiguration(configurationGeneration)) {
        return;
      }
      late final StandaloneGameRuntimeBridge bridge;
      bridge = StandaloneGameRuntimeBridge(
        gameId: game.id,
        userId: localUserId,
        nickname: localNickname,
        gameName: game.name,
        tags: game.tags,
        requiredCapabilities: game.capabilities
            .requiredForRole(controller: false)
            .toList(),
      );
      final shareCoordinator = _createShareCoordinator(soloBridge: bridge);
      _attachShareCoordinator(shareCoordinator);
      setState(() {
        _soloBridge = bridge;
        _sessionReady = true;
      });
      if (developerProjectId != null &&
          _isCurrentConfiguration(configurationGeneration)) {
        runtime?.reportDeveloperGameRunning(
          projectId: developerProjectId,
          expectedRunId: _developerRunId,
        );
        await _ensureShare(showOverlay: false);
      }
    } on Object catch (error) {
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      if (developerProjectId != null) {
        runtime?.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (_isCurrentConfiguration(configurationGeneration)) {
        setState(() {
          _sessionError = error;
          _sessionReady = true;
        });
      }
    }
  }

  Future<void> _closeSession() {
    final active = _closeSessionOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _performCloseSession().whenComplete(() {
      if (identical(_closeSessionOperation, operation)) {
        _closeSessionOperation = null;
      }
    });
    _closeSessionOperation = operation;
    return operation;
  }

  Future<void> _performCloseSession() async {
    _appLanHost.resetDocument();
    await _stopShare();
    final roomSubscription = _roomSubscription;
    _roomSubscription = null;
    await roomSubscription?.cancel();
    final bridge = _bridge;
    _bridge = null;
    final soloBridge = _soloBridge;
    _soloBridge = null;
    if (bridge != null) {
      await bridge.notifyLifecycle('exit');
      await bridge.close();
    }
    if (soloBridge != null) {
      await soloBridge.notifyLifecycle('exit');
      await soloBridge.close();
    }
    _sessionClient?.close();
    _sessionClient = null;
  }

  GameShareCoordinator? _createShareCoordinator({
    GameRuntimeBridge? bridge,
    StandaloneGameRuntimeBridge? soloBridge,
  }) {
    final source = _gameResourceSource;
    if (source == null) return null;
    final accessProvider = bridge != null
        ? MultiplayerGameShareAccessProvider(
            bridge: bridge,
            coreEndpoint: widget.goCoreRuntime!.endpoint,
            hostNickname: _currentNickname,
            hostNicknameProvider: () =>
                bridge.connection.currentPlayer.nickname,
          )
        : StandaloneGameShareAccessProvider(soloBridge!);
    return GameShareCoordinator(
      game: widget.game,
      source: source,
      accessProvider: accessProvider,
      discoveryService: _lanGameDiscoveryService,
    );
  }

  void _attachShareCoordinator(GameShareCoordinator? coordinator) {
    _shareCoordinator = coordinator;
    _shareState = coordinator?.state;
    _shareStateSubscription = coordinator?.states.listen(
      (state) => _handleShareCoordinatorState(coordinator, state),
    );
  }

  void _handleShareCoordinatorState(
    GameShareCoordinator coordinator,
    GameShareCoordinatorState state,
  ) {
    if (!mounted || _disposing || !identical(_shareCoordinator, coordinator)) {
      return;
    }
    final lanLinks = state.snapshot.lanLinks;
    final selectedUrl = _selectedShareLink?.url;
    GameShareLink? selected;
    if (selectedUrl != null) {
      for (final link in lanLinks) {
        if (link.url == selectedUrl) {
          selected = link;
          break;
        }
      }
    }
    setState(() {
      _shareState = state;
      _selectedShareLink = selected ?? lanLinks.firstOrNull;
      if (state.publication == LanPublicationState.published) {
        _publicationErrorCode = null;
      }
    });
  }

  Future<_LocalAvatar?> _loadLocalAvatar({
    required String userId,
    required String nickname,
  }) async {
    try {
      final currentProfile = widget.localProfile;
      final profile = currentProfile != null && currentProfile.userId == userId
          ? currentProfile
          : await const UserProfileStore().load(
              UserProfile(userId: userId, nickname: nickname),
            );
      if (profile.userId != userId) {
        _logAvatar(
          level: 'WARNING',
          event: 'session.avatar_load_identity_mismatch',
          message: 'Playmesh 本地头像加载失败：玩家身份不匹配',
          playerId: userId,
          extra: {'profilePlayerId': profile.userId},
        );
        return null;
      }
      if (profile.avatarBytes == null || profile.avatarSha256 == null) {
        _logAvatar(
          level: 'INFO',
          event: 'session.avatar_load_skipped',
          message: 'Playmesh 玩家未设置可上传的本地头像',
          playerId: userId,
          extra: {
            'hasAvatarBytes': profile.avatarBytes != null,
            'hasAvatarSha256': profile.avatarSha256 != null,
          },
        );
        return null;
      }
      _logAvatar(
        level: 'INFO',
        event: 'session.avatar_loaded',
        message: 'Playmesh 本地头像加载成功',
        playerId: userId,
        extra: {
          'avatarSha256': profile.avatarSha256,
          'avatarBytes': profile.avatarBytes!.length,
          'profileSource': identical(profile, currentProfile)
              ? 'memory'
              : 'storage',
        },
      );
      return _LocalAvatar(profile.avatarBytes!, profile.avatarSha256!);
    } on Object catch (error) {
      _logAvatar(
        level: 'WARNING',
        event: 'session.avatar_load_failed',
        message: 'Playmesh 本地头像加载失败，继续进入游戏',
        playerId: userId,
        extra: {'error': error.toString()},
      );
      return null;
    }
  }

  Future<void> _syncLocalAvatar(
    GameSessionConnection connection,
    _LocalAvatar? avatar,
  ) async {
    if (avatar == null) return;
    try {
      await connection.syncAvatar(avatar.pngBytes, avatar.sha256);
    } on Object catch (error) {
      _logAvatar(
        level: 'WARNING',
        event: 'session.avatar_sync_failed_continue',
        message: 'Playmesh 头像同步失败，继续进入游戏',
        playerId: connection.currentPlayer.id,
        sessionId: connection.snapshot.id,
        extra: {'avatarSha256': avatar.sha256, 'error': error.toString()},
      );
    }
  }

  void _logAvatar({
    required String level,
    required String event,
    required String message,
    required String playerId,
    String? sessionId,
    Map<String, Object?> extra = const {},
  }) {
    debugPrint(
      '[$level] $message ${jsonEncode({'component': 'game-session', 'event': event, 'sessionId': ?sessionId, 'playerId': playerId, 'nickname': _currentNickname, ...extra})}',
    );
  }

  Future<void> _openShare({bool throwOnError = false}) {
    if (_shareVisible) {
      _shareOverlayKey.currentState?.requestCloseFocus();
      final activeOperation = _shareOpenOperation;
      if (activeOperation == null) return Future<void>.value();
      return throwOnError
          ? activeOperation
          : activeOperation.catchError((Object _) {});
    }
    _focusBeforeShare = FocusManager.instance.primaryFocus;
    final activeOperation = _shareOpenOperation;
    if (activeOperation != null) {
      if (mounted) {
        setState(() => _shareVisible = true);
      }
      return throwOnError
          ? activeOperation
          : activeOperation.catchError((Object _) {});
    }
    late final Future<void> operation;
    operation = _ensureShare(showOverlay: true, throwOnError: true)
        .whenComplete(() {
          if (identical(_shareOpenOperation, operation)) {
            _shareOpenOperation = null;
          }
        });
    _shareOpenOperation = operation;
    return throwOnError ? operation : operation.catchError((Object _) {});
  }

  Future<void> _openShareFromAppSdk() async {
    final isCurrentAuthority =
        _bridge?.connection.isAuthority == true || _soloBridge != null;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        _disposing ||
        lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.detached) {
      throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
    }
    if (!isCurrentAuthority) {
      throw const SdkCommandException(
        'not_authority',
        '只有当前 Authority 游戏可以打开分享界面',
      );
    }
    final shareClosedAt = _shareClosedAt;
    if (!_shareVisible &&
        shareClosedAt != null &&
        DateTime.now().difference(shareClosedAt) < _sdkShareReopenCooldown) {
      throw const SdkCommandException('rate_limited', '分享界面刚刚关闭，请稍后再试');
    }
    try {
      await _openShare(throwOnError: true);
    } on SdkCommandException {
      rethrow;
    } on Object {
      throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
    }
  }

  Future<String?> _scanQrFromAppSdk() {
    if (!_scannerSupported) {
      throw const SdkCommandException('scanner_unavailable', '当前平台扫码不可用');
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GameInvitationScannerPage()),
    );
  }

  Future<void> _publishFromAppSdk() async {
    final coordinator = _shareCoordinator;
    if (coordinator == null) {
      throw const SdkCommandException('game_context_unavailable', '当前游戏上下文不可用');
    }
    await coordinator.setPublished();
  }

  Future<GameShareLinkSnapshot> _readShareLinksFromAppSdk() async {
    final coordinator = _shareCoordinator;
    if (coordinator == null) {
      throw const SdkCommandException('game_context_unavailable', '当前游戏上下文不可用');
    }
    return coordinator.currentLinkSnapshot();
  }

  bool get _scannerSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> _replaceWithRemoteGame(RemoteGameLaunch launch) async {
    if (!mounted || _disposing) {
      throw const SdkCommandException('operation_cancelled', '游戏退出，操作已取消');
    }
    await _webViewBridge?.notifyLifecycle('exit');
    await _bridge?.persistStorage();
    await _soloBridge?.persistStorage();
    if (!mounted || _disposing) return;
    await const GameJoinRouter().replace(
      context,
      launch: launch,
      userId: widget.localUserId,
      nickname: _currentNickname,
      discoveryService: _ownsLanGameDiscoveryService
          ? null
          : _lanGameDiscoveryService,
      onNicknameChanged: widget.onNicknameChanged,
    );
  }

  Future<void> _ensureShare({
    required bool showOverlay,
    bool throwOnError = false,
  }) async {
    final coordinator = _shareCoordinator;
    if (coordinator == null || !_canShareFromAppSdk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('game.share_unavailable'))),
      );
      if (throwOnError) {
        throw const SdkCommandException('ui_unavailable', '当前页面不能开启浏览器分享');
      }
      return;
    }
    if (mounted) {
      setState(() {
        if (showOverlay) _shareVisible = true;
        _shareErrorCode = null;
        _publicationErrorCode = null;
      });
    }
    try {
      await coordinator.ensureChannel();
      if (!mounted || !identical(_shareCoordinator, coordinator)) return;
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null) {
        widget.goCoreRuntime?.reportDeveloperGameRunning(
          projectId: developerProjectId,
          expectedRunId: _developerRunId,
          joinCode: _bridge?.connection.snapshot.joinCode,
          links: coordinator.state.snapshot.lanLinks
              .map((link) => link.url)
              .toList(growable: false),
        );
      }
      if (showOverlay) {
        try {
          await coordinator.setPublished();
        } on GameShareException catch (error) {
          if (!mounted || !identical(_shareCoordinator, coordinator)) return;
          if (error.code == 'discovery_unavailable') {
            setState(() => _publicationErrorCode = error.code);
            return;
          }
          rethrow;
        }
      }
    } on Object {
      final isCurrent = mounted && identical(_shareCoordinator, coordinator);
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && isCurrent) {
        widget.goCoreRuntime?.reportDeveloperGameError(
          developerProjectId,
          const GameShareException('share_unavailable', '分享通道不可用'),
          expectedRunId: _developerRunId,
        );
      }
      if (isCurrent) {
        setState(() => _shareErrorCode = 'share_unavailable');
      }
      if (throwOnError) {
        throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
      }
    }
  }

  Future<void> _hideShare() async {
    if (!mounted || !_shareVisible) return;
    final focusBeforeShare = _focusBeforeShare;
    final bridge = _webViewBridge;
    _focusBeforeShare = null;
    _shareClosedAt = DateTime.now();
    setState(() => _shareVisible = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (focusBeforeShare != null &&
          focusBeforeShare.canRequestFocus &&
          focusBeforeShare.context != null) {
        focusBeforeShare.requestFocus();
      }
      bridge?.restoreGameContentFocus();
    });
  }

  Future<void> _loadRelaySources() async {
    if (_relaySourcesLoading) return;
    final controller = widget.catalogController;
    if (controller == null) {
      if (mounted) {
        setState(() {
          _relaySources = const [];
          _relayErrorCode = 'game.relay_catalog_unavailable';
        });
      }
      return;
    }
    setState(() {
      _relaySourcesLoading = true;
      _relayErrorCode = null;
    });
    try {
      final probes = await controller.probeEnabledSources();
      final relaySources =
          probes
              .where((probe) => probe.supportsGameRelay)
              .toList(growable: false)
            ..sort((left, right) => left.elapsed.compareTo(right.elapsed));
      if (!mounted || _disposing) return;
      setState(() {
        _relaySources = relaySources;
        _relaySourcesLoading = false;
      });
    } on Object {
      if (!mounted || _disposing) return;
      setState(() {
        _relaySourcesLoading = false;
        _relayErrorCode = 'game.relay_load_failed_safe';
      });
    }
  }

  Future<void> _connectRelay(OnlineGameSourceProbe probe) async {
    final coordinator = _shareCoordinator;
    if (coordinator == null ||
        coordinator.state.relayStatus == RelayConnectionStatus.connecting) {
      return;
    }
    final declaration = probe.declaration;
    final relayDeclaration = declaration?.relay;
    if (!probe.supportsGameRelay || relayDeclaration == null) {
      setState(() => _relayErrorCode = 'game.relay_not_declared');
      return;
    }
    if (relayDeclaration.transport != 'playmesh-tcp-upgrade') {
      setState(() => _relayErrorCode = 'game.relay_transport_unsupported');
      return;
    }
    if (relayDeclaration.protocolVersion != relayProtocolVersion) {
      setState(() => _relayErrorCode = 'game.relay_version_unsupported_safe');
      return;
    }
    await _disconnectRelay();
    if (!mounted || _disposing) return;
    setState(() {
      _relaySource = probe;
      _relayErrorCode = null;
    });
    try {
      await coordinator.connectRelay(
        GameRelayHostRequest(
          serverBaseUri: relayDeclaration.publicBaseUrl,
          sourceToken: probe.source.token,
          hostPath: relayDeclaration.hostPath,
          clientPath: relayDeclaration.clientPath,
          maxConnectionsPerTunnel: relayDeclaration.maxConnectionsPerTunnel,
        ),
      );
    } on Object {
      if (!mounted || _disposing) return;
      setState(() {
        _relaySource = null;
        _relayErrorCode = 'game.relay_connect_failed_safe';
      });
    }
  }

  Future<void> _disconnectRelay() async {
    final coordinator = _shareCoordinator;
    if (coordinator != null && !coordinator.isClosing) {
      try {
        await coordinator.disconnectRelay();
      } on Object {
        // Relay 断开属于可恢复清理；错误文本不得带上 source token。
      }
    }
    if (!mounted || _disposing) {
      _relaySource = null;
      return;
    }
    setState(() {
      _relaySource = null;
      _relayErrorCode = null;
    });
  }

  Future<void> _stopShare() async {
    _shareOpenOperation = null;
    final subscription = _shareStateSubscription;
    _shareStateSubscription = null;
    await subscription?.cancel();
    final coordinator = _shareCoordinator;
    _shareCoordinator = null;
    _shareState = null;
    _focusBeforeShare = null;
    _shareClosedAt = null;
    if (!_disposing && mounted) {
      setState(() {
        _shareVisible = false;
        _shareErrorCode = null;
        _publicationErrorCode = null;
        _selectedShareLink = null;
        _relaySource = null;
        _relayErrorCode = null;
      });
    }
    await coordinator?.close();
  }

  Future<void> _restartGame() async {
    final bridge = _bridge;
    final soloBridge = _soloBridge;
    await _webViewBridge?.notifyLifecycle('exit');
    await bridge?.persistStorage();
    await soloBridge?.persistStorage();
    if (!mounted) {
      return;
    }
    _clearLogsForNewRun();
    setState(() {
      _runtimeGeneration += 1;
      _fullscreenError = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('game.reloaded'))));
  }

  Future<Object?> _executeDeveloperJavaScript(String source) {
    final executor = _developerJavaScriptExecutor;
    if (executor == null) {
      throw StateError('当前游戏 WebView 尚未完成加载');
    }
    return executor(source);
  }

  void _clearLogsForNewRun() {
    final projectId = widget.developerProjectId;
    if (projectId == null) {
      _developerRunId = null;
    } else {
      _developerRunId =
          widget.goCoreRuntime?.developerRunController
              .status(projectId)
              .runId ??
          widget.developerRunId;
    }
    developerEventHub.beginRuntime(
      projectId: projectId,
      runId: _developerRunId,
    );
  }

  void _resetTransientUiForReconnect() {
    if (!mounted || _disposing) return;
    _focusBeforeShare = null;
    _shareClosedAt = null;
    setState(() {
      _runtimeGeneration += 1;
      _shareVisible = false;
      _fullscreenError = null;
    });
  }

  Future<void> _returnToPrevious() =>
      _exitOperation ??= _performExitGame(toLibrary: false);

  Future<void> _exitGame() =>
      _exitOperation ??= _performExitGame(toLibrary: true);

  Future<void> _performExitGame({required bool toLibrary}) async {
    if (!mounted) return;
    final closeOperation = _closeSession();
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      final navigator = Navigator.of(context);
      if (toLibrary) {
        navigator.popUntil(
          (route) => route.settings.name == '/games' || route.isFirst,
        );
      } else {
        navigator.pop();
      }
    }
    try {
      await closeOperation;
    } on Object catch (error) {
      debugPrint('Failed to close the game session after exit: $error');
    }
  }
}

enum _SharePanelTab { lan, server, room }

class _ShareOverlay extends StatefulWidget {
  const _ShareOverlay({
    super.key,
    required this.joinCode,
    required this.links,
    required this.selectedLink,
    required this.loading,
    required this.error,
    required this.publicationError,
    required this.players,
    required this.relaySources,
    required this.relaySourcesLoading,
    required this.relayConnecting,
    required this.relaySource,
    required this.relayLink,
    required this.relayStatus,
    required this.relayError,
    required this.onClose,
    required this.onSelectLink,
    required this.onLoadRelaySources,
    required this.onConnectRelay,
    required this.onDisconnectRelay,
  });

  final String? joinCode;
  final List<GameShareLink> links;
  final GameShareLink? selectedLink;
  final bool loading;
  final String? error;
  final String? publicationError;
  final List<GameSessionPlayer> players;
  final List<OnlineGameSourceProbe> relaySources;
  final bool relaySourcesLoading;
  final bool relayConnecting;
  final OnlineGameSourceProbe? relaySource;
  final GameShareLink? relayLink;
  final RelayConnectionStatus relayStatus;
  final String? relayError;
  final Future<void> Function() onClose;
  final ValueChanged<GameShareLink> onSelectLink;
  final Future<void> Function() onLoadRelaySources;
  final Future<void> Function(OnlineGameSourceProbe) onConnectRelay;
  final Future<void> Function() onDisconnectRelay;

  @override
  State<_ShareOverlay> createState() => _ShareOverlayState();
}

class _ShareOverlayState extends State<_ShareOverlay> {
  static const _relayPageSize = 5;

  final FocusNode _closeFocusNode = FocusNode(debugLabel: 'game-share-close');
  _SharePanelTab _tab = _SharePanelTab.lan;
  String _search = '';
  int _page = 1;

  void requestCloseFocus() {
    if (_closeFocusNode.canRequestFocus) {
      _closeFocusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _closeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(widget.onClose()),
      },
      child: ColoredBox(
        color: const Color(0xc7000000),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, viewport) {
              final panelWidth = min(720.0, max(0.0, viewport.maxWidth - 20));
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 720,
                      maxHeight: max(120.0, viewport.maxHeight - 20),
                    ),
                    child: Theme(
                      data: Theme.of(context),
                      child: Material(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          width: panelWidth,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    10,
                                    8,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.joinCode == null
                                              ? context.tr('game.share_title')
                                              : context.tr(
                                                  'game.join_code_title',
                                                  arguments: {
                                                    'code': widget.joinCode,
                                                  },
                                                ),
                                          style:
                                              const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                              ).copyWith(
                                                color: colorScheme.onSurface,
                                              ),
                                        ),
                                      ),
                                      IconButton(
                                        key: const Key('game-share-close'),
                                        focusNode: _closeFocusNode,
                                        autofocus: true,
                                        tooltip: context.tr('game.share_close'),
                                        color: colorScheme.onSurface,
                                        onPressed: () =>
                                            unawaited(widget.onClose()),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                _buildTabs(),
                                const Divider(height: 1),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 160),
                                  child: KeyedSubtree(
                                    key: ValueKey(_tab),
                                    child: switch (_tab) {
                                      _SharePanelTab.lan => _buildLan(
                                        panelWidth,
                                      ),
                                      _SharePanelTab.server => _buildServer(
                                        panelWidth,
                                      ),
                                      _SharePanelTab.room => _buildRoom(),
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _tabButton(
            _SharePanelTab.lan,
            Icons.lan_outlined,
            context.tr('game.share_lan'),
          ),
          const SizedBox(width: 8),
          _tabButton(
            _SharePanelTab.server,
            Icons.public_outlined,
            context.tr('game.share_server'),
          ),
          const SizedBox(width: 8),
          _tabButton(
            _SharePanelTab.room,
            Icons.groups_outlined,
            context.tr(
              'game.room_status_count',
              arguments: {
                'count': widget.players
                    .where((player) => player.connected)
                    .length,
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(_SharePanelTab value, IconData icon, String label) {
    final selected = _tab == value;
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            setState(() => _tab = value);
            if (value == _SharePanelTab.server && widget.relaySource == null) {
              unawaited(widget.onLoadRelaySources());
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLan(double panelWidth) {
    if (widget.loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
      );
    }
    if (widget.links.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: _ShareAddressList(
          links: widget.links,
          selectedLink: null,
          onSelectLink: widget.onSelectLink,
        ),
      );
    }
    final compact = panelWidth < 590;
    final qr = _qrCard(
      widget.selectedLink,
      min(compact ? 168.0 : 214.0, max(48.0, panelWidth - 64)),
    );
    final addresses = _ShareAddressList(
      links: widget.links,
      selectedLink: widget.selectedLink,
      onSelectLink: widget.onSelectLink,
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(child: qr),
            const SizedBox(height: 16),
            if (widget.publicationError != null) ...[
              Text(
                widget.publicationError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            addresses,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          qr,
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.publicationError != null) ...[
                  Text(
                    widget.publicationError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                addresses,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServer(double panelWidth) {
    final source = widget.relaySource;
    if (source != null) {
      return _buildConnectedServer(source, panelWidth);
    }
    final query = _search.trim().toLowerCase();
    final filtered = widget.relaySources
        .where((probe) {
          final haystack = [
            probe.source.name,
            probe.source.host.toString(),
          ].join('\n').toLowerCase();
          return query.isEmpty || haystack.contains(query);
        })
        .toList(growable: false);
    final pageCount = max(1, (filtered.length / _relayPageSize).ceil());
    final page = _page.clamp(1, pageCount);
    final start = min(filtered.length, (page - 1) * _relayPageSize);
    final visible = filtered
        .skip(start)
        .take(_relayPageSize)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: context.tr('game.relay_search'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() {
                    _search = value;
                    _page = 1;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: context.tr('game.relay_refresh_latency'),
                onPressed: widget.relaySourcesLoading
                    ? null
                    : () => unawaited(widget.onLoadRelaySources()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.relaySourcesLoading)
            const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (widget.relayError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Text(
                context.tr(
                  'game.relay_load_failed',
                  arguments: {'error': widget.relayError},
                ),
                textAlign: TextAlign.center,
              ),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(
                context.tr('game.relay_empty'),
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final probe in visible) _relaySourceTile(probe),
          if (!widget.relaySourcesLoading && filtered.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: context.tr('common.previous_page'),
                  onPressed: page <= 1
                      ? null
                      : () => setState(() => _page = page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('$page / $pageCount'),
                IconButton(
                  tooltip: context.tr('common.next_page'),
                  onPressed: page >= pageCount
                      ? null
                      : () => setState(() => _page = page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _relaySourceTile(OnlineGameSourceProbe probe) {
    final declaration = probe.declaration!;
    final homepage = declaration.homepage;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        title: Text(
          probe.source.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${probe.source.host} · ${probe.elapsed.inMilliseconds} ms'),
            if (homepage != null)
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => unawaited(
                  launchUrl(homepage, mode: LaunchMode.externalApplication),
                ),
                icon: const Icon(Icons.open_in_new, size: 15),
                label: Text(context.tr('game.source_homepage')),
              ),
          ],
        ),
        trailing: FilledButton(
          onPressed: widget.relayConnecting
              ? null
              : () => unawaited(widget.onConnectRelay(probe)),
          child: Text(context.tr('game.connect')),
        ),
      ),
    );
  }

  Widget _buildConnectedServer(
    OnlineGameSourceProbe source,
    double panelWidth,
  ) {
    final declaration = source.declaration!;
    final invitation = widget.relayLink;
    final compact = panelWidth < 590;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          source.source.name,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          context.tr(
            'game.source_address',
            arguments: {'address': source.source.host},
          ),
        ),
        Text(
          context.tr(
            'game.relay_address',
            arguments: {'address': declaration.relay!.publicBaseUrl},
          ),
        ),
        Text(
          context.tr(
            'game.relay_latency',
            arguments: {'latency': source.elapsed.inMilliseconds},
          ),
        ),
        Text(
          context.tr(
            'game.connection_status',
            arguments: {'status': _relayStatusLabel(widget.relayStatus)},
          ),
        ),
        if (widget.relayError != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.relayError.toString(),
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        if (invitation != null) ...[
          const SizedBox(height: 12),
          SelectableText(
            invitation.url.toString(),
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyLink(context, invitation.url),
            icon: const Icon(Icons.copy),
            label: Text(context.tr('game.server_join_link_copy')),
          ),
        ],
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: widget.relayConnecting
              ? null
              : () => unawaited(widget.onDisconnectRelay()),
          icon: const Icon(Icons.link_off),
          label: Text(context.tr('game.server_disconnect')),
        ),
      ],
    );
    final qr = _qrCard(
      invitation,
      min(compact ? 168.0 : 214.0, max(48.0, panelWidth - 64)),
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: compact
          ? Column(children: [qr, const SizedBox(height: 16), details])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                qr,
                const SizedBox(width: 20),
                Expanded(child: details),
              ],
            ),
    );
  }

  Widget _buildRoom() {
    final connected = widget.players.where((player) => player.connected).length;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr(
              'game.room_player_summary',
              arguments: {
                'connected': connected,
                'joined': widget.players.length,
              },
            ),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (widget.players.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(
                context.tr('game.room_empty'),
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final player in widget.players)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(
                      player.connected
                          ? Icons.person
                          : Icons.person_off_outlined,
                    ),
                  ),
                  title: Text(
                    player.nickname,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(_playerSourceLabel(player.source)),
                  trailing: Text(
                    player.connected
                        ? context.tr('game.player_online')
                        : context.tr('game.player_disconnected'),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _qrCard(GameShareLink? link, double size) {
    if (link == null) {
      return SizedBox(
        width: size + 20,
        height: size + 20,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Image.memory(
        Uint8List.fromList(link.pngBytes),
        width: size,
        height: size,
        filterQuality: FilterQuality.none,
        semanticLabel: context.tr('game.share_qr_semantics'),
      ),
    );
  }

  String _relayStatusLabel(RelayConnectionStatus status) => switch (status) {
    RelayConnectionStatus.connecting => context.tr(
      'game.connection_connecting',
    ),
    RelayConnectionStatus.connected => context.tr('game.connection_connected'),
    RelayConnectionStatus.retrying => context.tr('game.connection_retrying'),
    RelayConnectionStatus.disconnected => context.tr(
      'game.connection_disconnected',
    ),
  };

  String _playerSourceLabel(String source) => switch (source) {
    'server' => context.tr('game.player_source_server'),
    'lan_app' => context.tr('game.player_source_lan_app'),
    'lan_html' => context.tr('game.player_source_lan_html'),
    _ => source,
  };

  void _copyLink(BuildContext context, Uri link) {
    unawaited(Clipboard.setData(ClipboardData(text: link.toString())));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('game.join_link_copied'))),
    );
  }
}

class _ShareAddressList extends StatelessWidget {
  const _ShareAddressList({
    required this.links,
    required this.selectedLink,
    required this.onSelectLink,
  });

  final List<GameShareLink> links;
  final GameShareLink? selectedLink;
  final ValueChanged<GameShareLink> onSelectLink;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.tr('game.available_addresses'),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        if (links.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              context.tr('game.share_no_lan_addresses'),
              textAlign: TextAlign.center,
            ),
          ),
        for (final link in links)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: link.url == selectedLink?.url
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                key: ValueKey('share-link-${link.url.host}'),
                contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                leading: Icon(
                  link.url == selectedLink?.url
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(link.url.host),
                subtitle: SelectableText(
                  link.url.toString(),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: context.tr('game.share_link_copy'),
                  onPressed: () {
                    unawaited(
                      Clipboard.setData(
                        ClipboardData(text: link.url.toString()),
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.tr('game.share_link_copied')),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
                onTap: () => onSelectLink(link),
              ),
            ),
          ),
        Text(
          context.tr('game.share_address_description'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _FullscreenNotice extends StatelessWidget {
  const _FullscreenNotice({
    required this.error,
    required this.onRetry,
    required this.onDismiss,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(8),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            const Icon(Icons.fullscreen_exit, color: Colors.amberAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.tr(
                  'game.fullscreen_notice',
                  arguments: {'error': error},
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.onInverseSurface,
                  height: 1.35,
                ),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: Text(context.tr('common.retry')),
            ),
            IconButton(
              tooltip: context.tr('game.notice_close'),
              color: colorScheme.onInverseSurface,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameStartFailure extends StatelessWidget {
  const _GameStartFailure({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.errorContainer,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: colorScheme.onErrorContainer,
                size: 42,
              ),
              const SizedBox(height: 12),
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => unawaited(onRetry()),
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('common.retry')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
