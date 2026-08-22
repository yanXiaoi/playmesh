import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:playmesh_share_ui/playmesh_share_ui.dart';
import 'package:playmesh_ui/playmesh_ui.dart';
import 'package:share_plus/share_plus.dart';

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
  final GlobalKey<PlaymeshSharePanelState> _shareOverlayKey =
      GlobalKey<PlaymeshSharePanelState>();
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
                child: ColoredBox(
                  color: const Color(0xc7000000),
                  child: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: PlaymeshSharePanel(
                          key: _shareOverlayKey,
                          model: _buildSharePanelModel(context),
                          strings: _buildSharePanelStrings(context),
                          actionMode:
                              !kIsWeb &&
                                  defaultTargetPlatform ==
                                      TargetPlatform.windows
                              ? PlaymeshShareActionMode.copy
                              : PlaymeshShareActionMode.share,
                          onClose: _hideShare,
                          onSelectLanLink: _selectSharePanelLanLink,
                          onLinkAction: _actOnSharePanelLink,
                          onInternetOpened: () {
                            if (_relaySource == null) {
                              return _loadRelaySources();
                            }
                          },
                          onServerSelected: _selectSharePanelServer,
                          onServerRefresh: _loadRelaySources,
                          onServerDisconnected: _disconnectRelay,
                        ),
                      ),
                    ),
                  ),
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
      return const PlaymeshLoadingView();
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

  PlaymeshSharePanelModel _buildSharePanelModel(BuildContext context) {
    final snapshot = _shareState?.snapshot;
    final lanLinks = snapshot?.lanLinks ?? const <GameShareLink>[];
    final internetLink = snapshot?.wanLink;
    final relayConnecting =
        _shareState?.relayStatus == RelayConnectionStatus.connecting;
    final selectedLanIndex = lanLinks.indexWhere(
      (link) => link.url == _selectedShareLink?.url,
    );
    final players =
        _bridge?.connection.snapshot.players ?? const <GameSessionPlayer>[];
    final joinCode = _bridge?.connection.snapshot.joinCode;
    final relayError = _sharePanelRelayError(context);
    final lanError = _shareErrorCode != null
        ? context.tr('game.share_unavailable')
        : _publicationErrorCode != null && lanLinks.isNotEmpty
        ? context.tr('game.nearby_discovery_unavailable')
        : null;
    return PlaymeshSharePanelModel(
      title: joinCode == null
          ? context.tr('game.share_title')
          : context.tr('game.join_code_title', arguments: {'code': joinCode}),
      lanLinks: List<PlaymeshShareLink>.generate(
        lanLinks.length,
        (index) => _toSharePanelLink(lanLinks[index], id: 'lan-$index'),
        growable: false,
      ),
      selectedLanLinkId: selectedLanIndex < 0 ? null : 'lan-$selectedLanIndex',
      internetLinks: internetLink == null
          ? const <PlaymeshShareLink>[]
          : <PlaymeshShareLink>[
              _toSharePanelLink(internetLink, id: 'internet-0'),
            ],
      selectedInternetLinkId: internetLink == null ? null : 'internet-0',
      participants: players
          .map(
            (player) => PlaymeshShareParticipant(
              id: player.id,
              name: player.nickname,
              connected: player.connected,
            ),
          )
          .toList(growable: false),
      serverCatalog: PlaymeshShareServerCatalog(
        options: _relaySources
            .map(
              (probe) => PlaymeshShareServerOption(
                id: probe.source.id,
                name: probe.source.name,
                latencyMilliseconds: probe.elapsed.inMilliseconds,
                enabled: probe.supportsGameRelay,
              ),
            )
            .toList(growable: false),
        selectedId: _relaySource?.source.id,
        loading: _relaySourcesLoading,
        errorMessage: relayError,
        searchEnabled: true,
        selectionEnabled: !relayConnecting,
        refreshEnabled: !relayConnecting && !_relaySourcesLoading,
      ),
      lanLoading: _shareState?.channel == ShareChannelState.starting,
      lanError: lanError,
      internetLoading: relayConnecting,
    );
  }

  PlaymeshSharePanelStrings _buildSharePanelStrings(BuildContext context) {
    return PlaymeshSharePanelStrings(
      closeTooltip: context.tr('game.share_close'),
      lanTab: context.tr('game.share_lan'),
      internetTab: context.tr('game.share_internet'),
      roomTab: context.tr('game.share_room'),
      lanHint: context.tr('game.share_lan_hint'),
      internetHint: context.tr('game.share_internet_hint'),
      roomHint: context.tr('game.share_room_hint'),
      noLanLinks: context.tr('game.share_no_lan_addresses'),
      noInternetLinks: context.tr('game.share_no_internet_link'),
      noPlayers: context.tr('game.room_empty'),
      serverSearchHint: context.tr('game.relay_search'),
      noServers: context.tr('game.relay_empty'),
      refreshServersTooltip: context.tr('game.relay_refresh_latency'),
      disconnectServer: context.tr('game.server_disconnect'),
      shareLinkTooltip: context.tr('common.share'),
      copyLinkTooltip: context.tr('game.share_link_copy'),
      qrSemantics: context.tr('game.share_qr_semantics'),
      playerOnline: context.tr('game.player_online'),
      playerOffline: context.tr('game.player_disconnected'),
    );
  }

  String? _sharePanelRelayError(BuildContext context) {
    return switch (_relayErrorCode) {
      null => null,
      'game.relay_catalog_unavailable' => context.tr(
        'game.relay_catalog_unavailable',
      ),
      'game.relay_load_failed_safe' => context.tr(
        'game.relay_load_failed_safe',
      ),
      _ => context.tr('game.relay_connect_failed_safe'),
    };
  }

  PlaymeshShareLink _toSharePanelLink(
    GameShareLink link, {
    required String id,
  }) {
    return PlaymeshShareLink(
      id: id,
      url: link.url,
      qrPngBytes: Uint8List.fromList(link.pngBytes),
    );
  }

  void _selectSharePanelLanLink(String id) {
    final index = _sharePanelLinkIndex(id, prefix: 'lan-');
    final lanLinks = _shareState?.snapshot.lanLinks ?? const <GameShareLink>[];
    if (index == null || index >= lanLinks.length) return;
    setState(() => _selectedShareLink = lanLinks[index]);
  }

  Future<void> _actOnSharePanelLink(PlaymeshShareLink link) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await Clipboard.setData(ClipboardData(text: link.url.toString()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('game.share_link_copied'))),
      );
      return;
    }
    await SharePlus.instance.share(ShareParams(text: link.url.toString()));
  }

  Future<void> _selectSharePanelServer(String id) async {
    final probe = _relaySources
        .where((probe) => probe.source.id == id)
        .firstOrNull;
    if (probe == null) return;
    await _connectRelay(probe);
  }

  int? _sharePanelLinkIndex(String id, {required String prefix}) {
    if (!id.startsWith(prefix)) return null;
    final index = int.tryParse(id.substring(prefix.length));
    return index != null && index >= 0 ? index : null;
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
