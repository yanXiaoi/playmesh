import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/catalog/game_catalog_models.dart';
import '../../core/catalog/online_game_catalog.dart';
import '../../core/developer/developer_event_hub.dart';
import '../../core/developer/developer_run_controller.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/game_runtime_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_sdk/standalone_game_runtime_bridge.dart';
import '../../core/game_web/game_web_gateway.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/profile/user_profile_store.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/session/go_core_session_client.dart';
import '../../core/session/game_session.dart';
import '../../core/storage/game_storage_service.dart';
import '../../models/game_summary.dart';
import '../../models/user_profile.dart';
import 'game_controls.dart';
import 'game_launcher.dart';
import 'game_orientation_controller.dart';

typedef GamePreviewBuilder = Widget Function(GameSummary game);

class GameJoinRequest {
  const GameJoinRequest({
    required this.coreEndpoint,
    required this.joinCode,
    required this.nickname,
  });

  final Uri coreEndpoint;
  final String joinCode;
  final String nickname;
}

class GameLaunchArguments {
  const GameLaunchArguments({
    required this.game,
    this.joinRequest,
    this.developerProjectId,
  });

  final GameSummary game;
  final GameJoinRequest? joinRequest;
  final String? developerProjectId;
}

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.game,
    this.localUserId = 'u_local',
    this.localNickname = playmeshDefaultLocalNickname,
    this.previewBuilder,
    this.orientationController,
    this.goCoreRuntime,
    this.joinRequest,
    this.developerProjectId,
    this.catalogController,
    this.initialPerformanceVisible = false,
    this.onPerformanceVisibilityChanged,
  });

  static const routeName = '/game';
  static const gameSurfaceKey = Key('game-surface');

  static Key runtimeKey(int generation) {
    return ValueKey('game-runtime-$generation');
  }

  final GameSummary game;
  final String localUserId;
  final String localNickname;
  final GamePreviewBuilder? previewBuilder;
  final GameOrientationController? orientationController;
  final GoCoreRuntime? goCoreRuntime;
  final GameJoinRequest? joinRequest;
  final String? developerProjectId;
  final GameCatalogController? catalogController;
  final bool initialPerformanceVisible;
  final ValueChanged<bool>? onPerformanceVisibilityChanged;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  static const _sdkShareReopenCooldown = Duration(milliseconds: 800);

  int _runtimeGeneration = 0;
  int _configurationGeneration = 0;
  final GameSidebarController _sidebarController = GameSidebarController();
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
  bool _showPerformance = false;
  GameWebGateway? _webGateway;
  List<Uri> _shareLinks = const [];
  Uri? _selectedShareLink;
  bool _shareVisible = false;
  bool _shareLoading = false;
  int _shareGeneration = 0;
  Future<void>? _shareOpenOperation;
  FocusNode? _focusBeforeShare;
  DateTime? _shareClosedAt;
  Object? _shareError;
  bool _disposing = false;
  bool _allowPop = false;
  Future<void>? _exitOperation;
  Future<void>? _closeSessionOperation;
  bool _shareGrantActive = false;
  GameStorageService? _soloShareStorage;
  bool _debugVisible = false;
  bool _infoVisible = false;
  final List<Map<String, Object?>> _developerLogs = [];
  StreamSubscription<Map<String, Object?>>? _developerLogSubscription;
  StreamSubscription<Map<String, Object?>>? _roomSubscription;
  StreamSubscription<RelayConnectionStatus>? _relayStatusSubscription;
  void Function()? _unregisterDeveloperRestart;
  void Function()? _unregisterDeveloperStop;
  void Function()? _unregisterDeveloperJavaScript;
  DeveloperWebViewJavaScriptExecutor? _developerJavaScriptExecutor;
  String? _developerRunId;
  RelayHostSession? _relaySession;
  OnlineGameSourceProbe? _relaySource;
  RelayConnectionStatus _relayStatus = RelayConnectionStatus.disconnected;
  List<OnlineGameSourceProbe> _relaySources = const [];
  bool _relaySourcesLoading = false;
  bool _relayConnecting = false;
  Object? _relayError;

  GameSdkBridge? get _webViewBridge => _bridge ?? _soloBridge;
  bool get _controllerRole =>
      widget.game.displayMode == 'single_screen_multiplayer' &&
      widget.joinRequest != null;
  GameOrientation get _runtimeOrientation =>
      widget.game.orientationForRole(controller: _controllerRole);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _orientationController =
        widget.orientationController ?? SystemGameOrientationController();
    _applyOrientation(_runtimeOrientation);
    _registerDeveloperHandlers();
    _initializeSession();
  }

  @override
  void didUpdateWidget(GamePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldControllerRole =
        oldWidget.game.displayMode == 'single_screen_multiplayer' &&
        oldWidget.joinRequest != null;
    final oldOrientation = oldWidget.game.orientationForRole(
      controller: oldControllerRole,
    );
    if (oldOrientation != _runtimeOrientation) {
      _applyOrientation(_runtimeOrientation);
    }
    final developerBindingChanged =
        oldWidget.developerProjectId != widget.developerProjectId ||
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
    final oldJoin = oldWidget.joinRequest;
    final join = widget.joinRequest;
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
        oldEntry.assetPath != entry.assetPath ||
        oldEntry.gameEntryPath != entry.gameEntryPath ||
        oldEntry.controllerEntryPath != entry.controllerEntryPath ||
        oldEntry.packageRootAssetPath != entry.packageRootAssetPath ||
        oldEntry.packageRootFilePath != entry.packageRootFilePath ||
        !setEquals(oldGame.capabilities.required, game.capabilities.required) ||
        !setEquals(
          oldGame.capabilities.controllerRequired,
          game.capabilities.controllerRequired,
        ) ||
        oldWidget.localUserId != widget.localUserId ||
        oldWidget.localNickname != widget.localNickname ||
        (oldWidget.previewBuilder == null) != (widget.previewBuilder == null) ||
        oldJoin?.coreEndpoint != join?.coreEndpoint ||
        oldJoin?.joinCode != join?.joinCode ||
        oldJoin?.nickname != join?.nickname;
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
    );
    _unregisterDeveloperStop = runtime.registerDeveloperGameStopHandler(
      developerProjectId,
      _exitGame,
    );
    _unregisterDeveloperJavaScript = runtime
        .registerDeveloperGameJavaScriptExecutor(
          developerProjectId,
          _executeDeveloperJavaScript,
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
    if (_infoVisible && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    _infoVisible = false;
    _developerJavaScriptExecutor = null;
    _shareOpenOperation = null;
    _focusBeforeShare = null;
    _shareClosedAt = null;
    await _hideDebugLogs(restoreFocus: false);
    await _closeSession();
    if (!_isCurrentConfiguration(generation)) return;
    setState(() {
      _runtimeGeneration += 1;
      _sessionReady = false;
      _sessionError = null;
      _showPerformance = false;
      _shareVisible = false;
      _shareLoading = false;
      _shareError = null;
      _debugVisible = false;
      _fullscreenError = null;
      _relaySources = const [];
      _relaySourcesLoading = false;
      _relayConnecting = false;
      _relayError = null;
    });
    widget.onPerformanceVisibilityChanged?.call(false);
    await _initializeSession();
  }

  @override
  void dispose() {
    _disposing = true;
    _configurationGeneration += 1;
    _unregisterDeveloperHandlers();
    _developerJavaScriptExecutor = null;
    unawaited(_developerLogSubscription?.cancel());
    _developerLogSubscription = null;
    final developerProjectId = widget.developerProjectId;
    if (developerProjectId != null) {
      widget.goCoreRuntime?.reportDeveloperGameStopped(
        developerProjectId,
        expectedRunId: _developerRunId,
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeSession());
    unawaited(
      _orientationOperation.then(
        (_) => _orientationController.restore(),
        onError: (_) => _orientationController.restore(),
      ),
    );
    super.dispose();
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
    return GameRuntimeShortcutScope(
      controller: _sidebarController,
      onBack: _handleRuntimeBack,
      onOpenSidebar: _openSidebarFromShortcut,
      child: PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleRuntimeBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            key: GamePage.gameSurfaceKey,
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _buildGameRuntime()),
              GameSidebar(
                controller: _sidebarController,
                resetKey: _runtimeGeneration,
                backLabel: context.tr('game.back_previous'),
                onContinue: _restoreGameContentFocus,
                showPerformance: _showPerformance,
                onTogglePerformance: _togglePerformance,
                onReload: () =>
                    unawaited(_restartGame().catchError((Object _) {})),
                onBack: () => unawaited(_returnToPrevious()),
                onShare: () => unawaited(_openShare()),
                onOpenLogs: _openDebugLogs,
                onEnterFullscreen: () =>
                    _applyOrientation(_runtimeOrientation, userInitiated: true),
                onExitFullscreen: () => unawaited(_exitFullscreen()),
                secondaryActions: [
                  GameSidebarAction(
                    icon: Icons.info_outline,
                    label: context.tr('game.info'),
                    onPressed: () => unawaited(_openGameInfo()),
                  ),
                ],
              ),
              if (_fullscreenError != null && !_shareVisible && !_debugVisible)
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
                    corePort: widget.goCoreRuntime?.endpoint.port,
                    links: _shareLinks,
                    selectedLink: _selectedShareLink,
                    loading: _shareLoading,
                    error: _shareError,
                    players:
                        _bridge?.connection.snapshot.players ??
                        const <GameSessionPlayer>[],
                    relaySources: _relaySources,
                    relaySourcesLoading: _relaySourcesLoading,
                    relayConnecting: _relayConnecting,
                    relaySource: _relaySource,
                    relaySession: _relaySession,
                    relayStatus: _relayStatus,
                    relayError: _relayError,
                    onClose: _hideShare,
                    onSelectLink: (link) {
                      setState(() => _selectedShareLink = link);
                    },
                    onLoadRelaySources: _loadRelaySources,
                    onConnectRelay: _connectRelay,
                    onDisconnectRelay: _disconnectRelay,
                  ),
                ),
              if (_debugVisible)
                Positioned.fill(
                  child: GameRuntimeLogOverlay(
                    logs: _developerLogs,
                    onClear: () {
                      developerEventHub.clearRecentLogs();
                      setState(_developerLogs.clear);
                    },
                    onClose: () => unawaited(_hideDebugLogs()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
            localUserId: widget.localUserId,
            localNickname: widget.localNickname,
            controllerRole: _controllerRole,
            onOpenSharePanel: _openShareFromAppSdk,
            onShowGameSidebar: _showGameSidebarFromSdk,
            onHideGameSidebar: _hideGameSidebarFromSdk,
            onExitRequested: _returnToPrevious,
            onJavaScriptExecutorChanged: (executor) {
              _developerJavaScriptExecutor = executor;
            },
          ),
    );
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
    final joinRequest = widget.joinRequest;
    final localUserId = widget.localUserId;
    final localNickname = widget.localNickname;
    final developerProjectId = widget.developerProjectId;
    if (_sessionReady || _sessionError != null) {
      if (_infoVisible && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await _hideDebugLogs(restoreFocus: false);
      if (!_isCurrentConfiguration(configurationGeneration)) return;
      _focusBeforeShare = null;
      _shareClosedAt = null;
      setState(() {
        _runtimeGeneration += 1;
        _showPerformance = false;
        _shareVisible = false;
        _debugVisible = false;
        _fullscreenError = null;
      });
      _webViewBridge?.setPerformanceVisible(false);
      widget.onPerformanceVisibilityChanged?.call(false);
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
    if (!game.supportsMultiplayer || (runtime == null && joinRequest == null)) {
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
      late final GoCoreSessionClient client;
      late final GameSessionConnection connection;
      if (joinRequest == null) {
        await runtime!.start();
        if (!_isCurrentConfiguration(configurationGeneration)) return;
        client = GoCoreSessionClient(baseUri: runtime.endpoint);
        connection = await client.create(
          gameId: game.id,
          displayMode: game.displayMode,
          minPlayers: game.minPlayers,
          maxPlayers: game.maxPlayers,
          nickname: localNickname,
        );
      } else {
        client = GoCoreSessionClient(baseUri: joinRequest.coreEndpoint);
        connection = await client.join(
          joinCode: joinRequest.joinCode,
          nickname: joinRequest.nickname,
          playerId: localUserId,
        );
      }
      final storage = await GameStorageService.create(gameId: game.id);
      if (!_isCurrentConfiguration(configurationGeneration)) {
        await connection.close();
        await storage.close();
        client.close();
        return;
      }
      if (connection.isAuthority) {
        // A process crash can leave fixed-name platform avatar files behind.
        // A newly created Authority session owns a fresh avatar namespace and
        // must clear it before any local or joining player synchronizes.
        await storage.clearSystemAvatars();
        if (!_isCurrentConfiguration(configurationGeneration)) {
          await connection.close();
          await storage.close();
          client.close();
          return;
        }
      }
      late final GameRuntimeBridge bridge;
      bridge = GameRuntimeBridge(connection, storage: storage);
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
      unawaited(
        _syncLocalAvatar(
          connection,
          userId: localUserId,
          nickname: localNickname,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentConfiguration(configurationGeneration) &&
            identical(_bridge, bridge)) {
          bridge.setPerformanceVisible(_showPerformance);
        }
      });
      if (developerProjectId != null &&
          _isCurrentConfiguration(configurationGeneration)) {
        if (connection.isAuthority) {
          await _ensureShare(showOverlay: false);
        } else {
          runtime?.reportDeveloperGameRunning(
            projectId: developerProjectId,
            expectedRunId: _developerRunId,
            joinCode: connection.snapshot.joinCode,
          );
        }
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
      );
      setState(() {
        _soloBridge = bridge;
        _sessionReady = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentConfiguration(configurationGeneration) &&
            identical(_soloBridge, bridge)) {
          bridge.setPerformanceVisible(_showPerformance);
        }
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

  Future<void> _syncLocalAvatar(
    GameSessionConnection connection, {
    required String userId,
    required String nickname,
  }) async {
    try {
      final profile = await const UserProfileStore().load(
        UserProfile(userId: userId, nickname: nickname),
      );
      if (profile.userId != userId ||
          profile.avatarBytes == null ||
          profile.avatarSha256 == null) {
        return;
      }
      await connection.syncAvatar(profile.avatarBytes!, profile.avatarSha256!);
    } on Object {
      // 头像失败不影响创建、加入或恢复会话。
    }
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
    if (!mounted ||
        _disposing ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
    }
    if (!isCurrentAuthority) {
      throw const SdkCommandException(
        'not_authority',
        '只有当前 Authority 游戏可以打开分享界面',
      );
    }
    final executor = _developerJavaScriptExecutor;
    if (executor == null) {
      throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
    }
    final active = await executor(
      'Boolean(globalThis.navigator?.userActivation?.isActive)',
    );
    if (active != true && active.toString() != 'true') {
      throw const SdkCommandException(
        'user_activation_required',
        '打开分享界面需要当前用户操作',
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

  Future<void> _showGameSidebarFromSdk() async {
    if (!mounted ||
        _disposing ||
        _shareVisible ||
        _debugVisible ||
        _infoVisible ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏侧边栏不可用');
    }
    if (!_sidebarController.showFromSdk()) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏侧边栏不可用');
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _hideGameSidebarFromSdk() async {
    if (!mounted || _disposing) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏侧边栏不可用');
    }
    if (!_sidebarController.hideFromSdk()) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏侧边栏不可用');
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _ensureShare({
    required bool showOverlay,
    bool throwOnError = false,
  }) async {
    final configurationGeneration = _configurationGeneration;
    final shareGeneration = _shareGeneration;
    final game = widget.game;
    final multiplayer = game.supportsMultiplayer;
    final bridge = _bridge;
    final soloBridge = _soloBridge;
    final runtime = widget.goCoreRuntime;
    final gameRootAsset = game.entry.packageRootAssetPath;
    final gameRootFile = game.entry.packageRootFilePath;
    final hasGameRoot = gameRootAsset != null || gameRootFile != null;
    final canShareMultiplayer =
        bridge != null && bridge.connection.isAuthority && runtime != null;
    bool isCurrentOperation() =>
        _isCurrentConfiguration(configurationGeneration) &&
        shareGeneration == _shareGeneration &&
        identical(_bridge, bridge) &&
        identical(_soloBridge, soloBridge);
    void failIfRequested() {
      if (throwOnError) {
        throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
      }
    }

    if (!isCurrentOperation()) {
      failIfRequested();
      return;
    }
    if (!hasGameRoot || (multiplayer && !canShareMultiplayer)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('game.share_unavailable'))),
      );
      if (throwOnError) {
        throw const SdkCommandException('ui_unavailable', '当前页面不能开启浏览器分享');
      }
      return;
    }
    if (_webGateway != null || _shareLoading) {
      if (showOverlay) setState(() => _shareVisible = true);
      return;
    }
    setState(() {
      _shareVisible = showOverlay;
      _shareLoading = true;
      _shareError = null;
      _shareLinks = const [];
      _selectedShareLink = null;
    });
    GameStorageService? soloStorage;
    GameWebGateway? gateway;
    var localGrantActive = false;
    Future<void> cleanupLocalResources() async {
      await gateway?.close();
      gateway = null;
      await soloStorage?.close();
      soloStorage = null;
      if (localGrantActive) {
        localGrantActive = false;
        try {
          await bridge?.connection.closeShare();
        } on Object catch (closeError) {
          debugPrint('回收浏览器分享授权失败: $closeError');
        }
      }
      if (shareGeneration == _shareGeneration) {
        _shareGrantActive = false;
      }
    }

    try {
      late final String shareToken;
      late final GameStorageService storage;
      if (multiplayer) {
        final grant = await bridge!.connection.openShare();
        localGrantActive = true;
        if (!isCurrentOperation()) {
          await cleanupLocalResources();
          failIfRequested();
          return;
        }
        _shareGrantActive = true;
        shareToken = grant.token;
        storage = bridge.storage;
      } else {
        final localStorage = await soloBridge?.ensureStorage();
        if (!isCurrentOperation()) {
          failIfRequested();
          return;
        }
        soloStorage = localStorage == null
            ? await GameStorageService.create(gameId: game.id)
            : null;
        if (!isCurrentOperation()) {
          await cleanupLocalResources();
          failIfRequested();
          return;
        }
        shareToken = _newStandaloneShareToken();
        storage = localStorage ?? soloStorage!;
      }
      final startedGateway = await startGameWebGateway(
        gameRootAssetPath: gameRootAsset ?? '',
        gameRootFilePath: gameRootFile,
        multiplayer: multiplayer,
        displayMode: multiplayer
            ? bridge!.connection.snapshot.displayMode
            : 'multi_screen',
        orientation: game.orientation,
        controllerOrientation: game.controllerOrientation,
        gameEntryPath: game.entry.gameEntryPath,
        controllerEntryPath: game.entry.controllerEntryPath,
        gameName: game.name,
        gameSdkVersion: game.sdkVersion.isEmpty ? null : game.sdkVersion,
        appSdkVersion: game.appSdkVersion.isEmpty ? null : game.appSdkVersion,
        requiredCapabilities: game.capabilities.required.toList(),
        controllerRequiredCapabilities: game.capabilities.controllerRequired
            .toList(),
        coreEndpoint: multiplayer ? runtime!.endpoint : null,
        joinCode: multiplayer ? bridge!.connection.snapshot.joinCode : null,
        shareToken: shareToken,
        storage: storage,
      );
      gateway = startedGateway;
      if (!isCurrentOperation()) {
        await cleanupLocalResources();
        failIfRequested();
        return;
      }
      final links = await startedGateway.shareLinks();
      if (!isCurrentOperation()) {
        await cleanupLocalResources();
        failIfRequested();
        return;
      }
      setState(() {
        _webGateway = startedGateway;
        _soloShareStorage = soloStorage;
        _shareLinks = links;
        _selectedShareLink = links.isEmpty ? null : links.first;
        _shareLoading = false;
      });
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && isCurrentOperation()) {
        runtime?.reportDeveloperGameRunning(
          projectId: developerProjectId,
          expectedRunId: _developerRunId,
          joinCode: multiplayer ? bridge!.connection.snapshot.joinCode : null,
          links: links,
        );
      }
    } on Object catch (error) {
      await cleanupLocalResources();
      final isCurrent = isCurrentOperation();
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && isCurrent) {
        runtime?.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (isCurrent) {
        setState(() {
          _shareError = error;
          _shareLoading = false;
        });
      }
      if (throwOnError) rethrow;
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
      } else {
        _sidebarController.restoreFocus();
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
          _relayError = context.tr('game.relay_catalog_unavailable');
        });
      }
      return;
    }
    setState(() {
      _relaySourcesLoading = true;
      _relayError = null;
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
    } on Object catch (error) {
      if (!mounted || _disposing) return;
      setState(() {
        _relaySourcesLoading = false;
        _relayError = error;
      });
    }
  }

  Future<void> _connectRelay(OnlineGameSourceProbe probe) async {
    if (_relayConnecting) return;
    final declaration = probe.declaration;
    final relayDeclaration = declaration?.relay;
    if (!probe.supportsGameRelay || relayDeclaration == null) {
      setState(() => _relayError = context.tr('game.relay_not_declared'));
      return;
    }
    if (relayDeclaration.transport != 'playmesh-tcp-upgrade') {
      setState(
        () => _relayError = context.tr('game.relay_transport_unsupported'),
      );
      return;
    }
    if (relayDeclaration.protocolVersion != relayProtocolVersion) {
      setState(
        () => _relayError = context.tr(
          'game.relay_version_unsupported',
          arguments: {'version': relayDeclaration.protocolVersion},
        ),
      );
      return;
    }
    await _disconnectRelay();
    if (!mounted || _disposing) return;
    setState(() {
      _relayConnecting = true;
      _relaySource = probe;
      _relayStatus = RelayConnectionStatus.connecting;
      _relayError = null;
    });
    RelayHostSession? session;
    try {
      await _ensureShare(showOverlay: false);
      if (!mounted || _disposing) return;
      final gateway = _webGateway;
      final runtime = widget.goCoreRuntime;
      final entry = _selectedShareLink ?? _shareLinks.firstOrNull;
      if (gateway == null || runtime == null || entry == null) {
        throw StateError(context.tr('game.relay_local_share_missing'));
      }
      session = await startRelayHostSession(
        serverBaseUri: relayDeclaration.publicBaseUrl,
        sourceToken: probe.source.token,
        hostPath: relayDeclaration.hostPath,
        clientPath: relayDeclaration.clientPath,
        authorityWebBaseUri: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: gateway.port,
        ),
        authorityCoreBaseUri: runtime.endpoint,
        authorityEntryUri: entry,
        maxConnectionsPerTunnel: relayDeclaration.maxConnectionsPerTunnel,
      );
      final statusSubscription = session.statuses.listen((status) {
        if (!mounted || _disposing || !identical(_relaySession, session)) {
          return;
        }
        setState(() => _relayStatus = status);
      });
      if (!mounted || _disposing) {
        await statusSubscription.cancel();
        await session.close();
        return;
      }
      setState(() {
        _relaySession = session;
        _relayStatusSubscription = statusSubscription;
        _relayStatus = session!.status;
        _relayConnecting = false;
      });
    } on Object catch (error) {
      await session?.close();
      if (!mounted || _disposing) return;
      setState(() {
        _relaySession = null;
        _relayConnecting = false;
        _relayStatus = RelayConnectionStatus.disconnected;
        _relayError = error;
      });
    }
  }

  Future<void> _disconnectRelay() async {
    final statusSubscription = _relayStatusSubscription;
    _relayStatusSubscription = null;
    await statusSubscription?.cancel();
    final session = _relaySession;
    _relaySession = null;
    await session?.close();
    if (!mounted || _disposing) {
      _relaySource = null;
      _relayStatus = RelayConnectionStatus.disconnected;
      _relayConnecting = false;
      return;
    }
    setState(() {
      _relaySource = null;
      _relayStatus = RelayConnectionStatus.disconnected;
      _relayConnecting = false;
      _relayError = null;
    });
  }

  String _newStandaloneShareToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _openGameInfo() async {
    if (_infoVisible || !mounted) return;
    _infoVisible = true;
    final playerRange = widget.game.minPlayers == widget.game.maxPlayers
        ? context.tr(
            'library.player_count',
            arguments: {'count': widget.game.minPlayers},
          )
        : context.tr(
            'library.player_range',
            arguments: {
              'min': widget.game.minPlayers,
              'max': widget.game.maxPlayers,
            },
          );
    final description =
        widget.game.description.trim().isNotEmpty ||
            widget.game.manifestError == null
        ? widget.game.description
        : context.tr('game.repair_description');
    await showModalBottomSheet<void>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (context) => GameToolInfoSheet(
        title: widget.game.name,
        description: description,
        labels: [
          widget.game.manifestError == null && widget.game.sdkVersion.isNotEmpty
              ? 'Game SDK ${widget.game.sdkVersion}'
              : context.tr('game.needs_repair'),
          widget.game.displayMode == 'single_screen_multiplayer'
              ? context.tr('game.display_single_screen')
              : context.tr('game.display_multi_screen'),
          playerRange,
          widget.game.supportsMultiplayer
              ? context.tr('library.multiplayer')
              : context.tr('library.solo'),
        ],
      ),
    );
    _infoVisible = false;
    if (mounted) _sidebarController.restoreFocus();
  }

  void _openDebugLogs() {
    _developerLogs
      ..clear()
      ..addAll(developerEventHub.recentLogs);
    _developerLogSubscription ??= developerEventHub.events.listen((event) {
      if (event['type'] != 'runtime.log' || !mounted || _disposing) return;
      setState(() {
        _developerLogs.add(Map<String, Object?>.from(event));
        if (_developerLogs.length > DeveloperEventHub.maxRecentLogs) {
          _developerLogs.removeRange(
            0,
            _developerLogs.length - DeveloperEventHub.maxRecentLogs,
          );
        }
      });
    });
    setState(() => _debugVisible = true);
  }

  Future<void> _hideDebugLogs({bool restoreFocus = true}) async {
    if (mounted && !_disposing) {
      setState(() => _debugVisible = false);
      if (restoreFocus) _sidebarController.restoreFocus();
    }
    final subscription = _developerLogSubscription;
    _developerLogSubscription = null;
    await subscription?.cancel();
  }

  Future<void> _stopShare() async {
    _shareGeneration += 1;
    _shareOpenOperation = null;
    final shareBridge = _bridge;
    await _disconnectRelay();
    final gateway = _webGateway;
    _webGateway = null;
    final soloStorage = _soloShareStorage;
    _soloShareStorage = null;
    final hadGrant = _shareGrantActive;
    _shareGrantActive = false;
    _focusBeforeShare = null;
    _shareClosedAt = null;
    if (!_disposing && mounted) {
      setState(() {
        _shareVisible = false;
        _shareLoading = false;
        _shareError = null;
        _shareLinks = const [];
        _selectedShareLink = null;
      });
    }
    await gateway?.close();
    await soloStorage?.close();
    if (hadGrant) {
      try {
        await shareBridge?.connection.closeShare();
      } on Object catch (error) {
        debugPrint('关闭浏览器分享失败: $error');
      }
    }
  }

  Future<void> _restartGame() async {
    if (_infoVisible && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    final bridge = _bridge;
    final soloBridge = _soloBridge;
    await _webViewBridge?.notifyLifecycle('exit');
    await bridge?.persistStorage();
    await soloBridge?.persistStorage();
    await _soloShareStorage?.flushAll();
    await _stopShare();
    await _hideDebugLogs(restoreFocus: false);
    if (!mounted) {
      return;
    }
    _clearLogsForNewRun();
    setState(() {
      _runtimeGeneration += 1;
      _showPerformance = false;
      _debugVisible = false;
      _fullscreenError = null;
    });
    widget.onPerformanceVisibilityChanged?.call(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _webViewBridge?.setPerformanceVisible(_showPerformance);
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
    _developerRunId = projectId == null
        ? null
        : widget.goCoreRuntime?.developerRunController.status(projectId).runId;
    developerEventHub.beginRuntime(
      projectId: projectId,
      runId: _developerRunId,
    );
    _developerLogs.clear();
  }

  void _togglePerformance() {
    setState(() => _showPerformance = !_showPerformance);
    _webViewBridge?.setPerformanceVisible(_showPerformance);
    widget.onPerformanceVisibilityChanged?.call(_showPerformance);
  }

  void _handleRuntimeBack() {
    if (_debugVisible) {
      unawaited(_hideDebugLogs());
      return;
    }
    if (_shareVisible) {
      unawaited(_hideShare());
      return;
    }
    if (_sidebarController.closeTopLayer()) return;
    if (_fullscreenError != null) {
      setState(() => _fullscreenError = null);
      return;
    }
    unawaited(_openSidebarFromNativeBack());
  }

  void _restoreGameContentFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
    _webViewBridge?.restoreGameContentFocus();
  }

  void _openSidebarFromShortcut() {
    if (_shareVisible || _debugVisible || _infoVisible) return;
    _sidebarController.open();
  }

  Future<void> _openSidebarFromNativeBack() async {
    final executor = _developerJavaScriptExecutor;
    if (executor != null) {
      try {
        final handled = await executor(
          'Boolean(window[Symbol.for("playmesh.platform-ui.back")]?.())',
        );
        if (handled == true || handled?.toString() == 'true') return;
      } on Object catch (error) {
        debugPrint('游戏网页未能处理返回键，改由 App 打开侧边栏: $error');
      }
    }
    if (mounted) _sidebarController.open();
  }

  void _resetTransientUiForReconnect() {
    if (!mounted || _disposing) return;
    if (_infoVisible && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    unawaited(_hideDebugLogs(restoreFocus: false));
    _focusBeforeShare = null;
    _shareClosedAt = null;
    setState(() {
      _runtimeGeneration += 1;
      _showPerformance = false;
      _shareVisible = false;
      _debugVisible = false;
      _fullscreenError = null;
    });
    _webViewBridge?.setPerformanceVisible(false);
    widget.onPerformanceVisibilityChanged?.call(false);
  }

  Future<void> _exitFullscreen() async {
    try {
      await _orientationController.exitFullscreen();
      if (mounted && _fullscreenError != null) {
        setState(() => _fullscreenError = null);
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'game.fullscreen_exit_failed',
              arguments: {'error': error},
            ),
          ),
        ),
      );
    }
  }

  Future<void> _returnToPrevious() =>
      _exitOperation ??= _performExitGame(toLibrary: false);

  Future<void> _exitGame() =>
      _exitOperation ??= _performExitGame(toLibrary: true);

  Future<void> _performExitGame({required bool toLibrary}) async {
    if (!mounted) return;
    final closeOperation = _closeSession();
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (toLibrary) {
        navigator.popUntil(
          (route) => route.settings.name == '/games' || route.isFirst,
        );
      } else {
        navigator.pop();
      }
    });
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
    required this.corePort,
    required this.links,
    required this.selectedLink,
    required this.loading,
    required this.error,
    required this.players,
    required this.relaySources,
    required this.relaySourcesLoading,
    required this.relayConnecting,
    required this.relaySource,
    required this.relaySession,
    required this.relayStatus,
    required this.relayError,
    required this.onClose,
    required this.onSelectLink,
    required this.onLoadRelaySources,
    required this.onConnectRelay,
    required this.onDisconnectRelay,
  });

  final String? joinCode;
  final int? corePort;
  final List<Uri> links;
  final Uri? selectedLink;
  final bool loading;
  final Object? error;
  final List<GameSessionPlayer> players;
  final List<OnlineGameSourceProbe> relaySources;
  final bool relaySourcesLoading;
  final bool relayConnecting;
  final OnlineGameSourceProbe? relaySource;
  final RelayHostSession? relaySession;
  final RelayConnectionStatus relayStatus;
  final Object? relayError;
  final Future<void> Function() onClose;
  final ValueChanged<Uri> onSelectLink;
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
    return ColoredBox(
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
                                    _SharePanelTab.lan => _buildLan(panelWidth),
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
          context.tr('game.share_failed', arguments: {'error': widget.error}),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
      );
    }
    final compact = panelWidth < 590;
    final invitation = _lanInvitation(widget.selectedLink);
    final qr = _qrCard(
      invitation?.toString(),
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
          Expanded(child: addresses),
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
    final invitation = widget.relaySession?.joinUri;
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
            invitation.toString(),
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyLink(context, invitation),
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
      invitation?.toString(),
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
                  subtitle: Text(
                    '${_playerSourceLabel(player.source)} · '
                    '${player.latencyMs == null ? '-- ms' : '${player.latencyMs} ms'}',
                  ),
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

  Widget _qrCard(String? value, double size) {
    if (value == null) {
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
      child: QrImageView(data: value, size: size),
    );
  }

  Uri? _invitationLink(Uri? link) {
    return link;
  }

  Uri? _lanInvitation(Uri? link) => _invitationLink(link);

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

  final List<Uri> links;
  final Uri? selectedLink;
  final ValueChanged<Uri> onSelectLink;

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
        for (final link in links)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: link == selectedLink
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                key: ValueKey('share-link-${link.host}'),
                contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                leading: Icon(
                  link == selectedLink
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(link.host),
                subtitle: SelectableText(
                  link.toString(),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: context.tr('game.share_link_copy'),
                  onPressed: () {
                    unawaited(
                      Clipboard.setData(ClipboardData(text: link.toString())),
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
