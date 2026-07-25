import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
import '../../core/game_sdk/standalone_game_runtime_bridge.dart';
import '../../core/game_web/game_web_gateway.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/session/go_core_session_client.dart';
import '../../core/session/game_session.dart';
import '../../core/storage/game_storage_service.dart';
import '../../models/game_summary.dart';
import '../settings/settings_page.dart';
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
    this.localNickname = '本机玩家',
    this.previewBuilder,
    this.orientationController,
    this.goCoreRuntime,
    this.joinRequest,
    this.developerProjectId,
    this.catalogController,
    this.initialPerformanceVisible = true,
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
  int _runtimeGeneration = 0;
  late final GameOrientationController _orientationController;
  Future<void> _orientationOperation = Future<void>.value();
  Object? _fullscreenError;
  bool _sessionReady = false;
  Object? _sessionError;
  GoCoreSessionClient? _sessionClient;
  GameRuntimeBridge? _bridge;
  StandaloneGameRuntimeBridge? _soloBridge;
  late bool _showPerformance;
  GameWebGateway? _webGateway;
  List<Uri> _shareLinks = const [];
  Uri? _selectedShareLink;
  bool _shareVisible = false;
  bool _shareLoading = false;
  Object? _shareError;
  bool _disposing = false;
  bool _allowPop = false;
  Future<void>? _exitOperation;
  bool _shareGrantActive = false;
  GameStorageService? _soloShareStorage;
  bool _debugVisible = false;
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
    _showPerformance = widget.initialPerformanceVisible;
    _orientationController =
        widget.orientationController ?? SystemGameOrientationController();
    _applyOrientation(_runtimeOrientation);
    final developerProjectId = widget.developerProjectId;
    final runtime = widget.goCoreRuntime;
    if (developerProjectId != null && runtime != null) {
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
  }

  @override
  void dispose() {
    _disposing = true;
    _unregisterDeveloperRestart?.call();
    _unregisterDeveloperRestart = null;
    _unregisterDeveloperStop?.call();
    _unregisterDeveloperStop = null;
    _unregisterDeveloperJavaScript?.call();
    _unregisterDeveloperJavaScript = null;
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
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_returnToPrevious());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          key: GamePage.gameSurfaceKey,
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _buildGameRuntime()),
            GameToolDock(
              backTooltip: '返回上一页',
              showPerformance: _showPerformance,
              onTogglePerformance: _togglePerformance,
              onReload: () =>
                  unawaited(_restartGame().catchError((Object _) {})),
              onBack: () => unawaited(_returnToPrevious()),
              onShare: () => unawaited(_openShare()),
              onEnterFullscreen: () =>
                  _applyOrientation(_runtimeOrientation, userInitiated: true),
              onExitFullscreen: () => unawaited(_exitFullscreen()),
              secondaryActions: [
                GameToolAction(
                  icon: Icons.info_outline,
                  label: '游戏信息',
                  onPressed: _openGameInfo,
                ),
                GameToolAction(
                  icon: Icons.receipt_long_outlined,
                  label: '运行日志',
                  onPressed: _openDebugLogs,
                ),
                GameToolAction(
                  icon: Icons.tune_outlined,
                  label: '游戏设置',
                  onPressed: () =>
                      Navigator.of(context).pushNamed(SettingsPage.routeName),
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
    _clearLogsForNewRun();
    if (widget.previewBuilder != null) {
      if (mounted) {
        setState(() {
          _sessionReady = true;
          _sessionError = null;
        });
      }
      return;
    }
    if (!widget.game.supportsMultiplayer ||
        (widget.goCoreRuntime == null && widget.joinRequest == null)) {
      await _initializeStandaloneSession();
      return;
    }
    if (mounted) {
      setState(() {
        _sessionReady = false;
        _sessionError = null;
      });
    }
    try {
      await _closeSession();
      final joinRequest = widget.joinRequest;
      late final GoCoreSessionClient client;
      late final GameSessionConnection connection;
      if (joinRequest == null) {
        await widget.goCoreRuntime!.start();
        client = GoCoreSessionClient(baseUri: widget.goCoreRuntime!.endpoint);
        connection = await client.create(
          gameId: widget.game.id,
          displayMode: widget.game.displayMode,
          minPlayers: widget.game.minPlayers,
          maxPlayers: widget.game.maxPlayers,
          nickname: widget.localNickname,
        );
      } else {
        client = GoCoreSessionClient(baseUri: joinRequest.coreEndpoint);
        connection = await client.join(
          joinCode: joinRequest.joinCode,
          nickname: joinRequest.nickname,
          playerId: widget.localUserId,
        );
      }
      final storage = await GameStorageService.create(gameId: widget.game.id);
      if (!mounted) {
        await connection.close();
        await storage.close();
        client.close();
        return;
      }
      final bridge = GameRuntimeBridge(connection, storage: storage);
      setState(() {
        _sessionClient = client;
        _bridge = bridge;
        _sessionReady = true;
      });
      await _roomSubscription?.cancel();
      _roomSubscription = connection.messages.listen((message) {
        if (message['session'] is! Map || !mounted || _disposing) return;
        setState(() {});
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_bridge, bridge)) {
          bridge.setPerformanceVisible(_showPerformance);
        }
      });
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        if (connection.isAuthority) {
          await _ensureShare(showOverlay: false);
        } else {
          widget.goCoreRuntime?.reportDeveloperGameRunning(
            projectId: developerProjectId,
            expectedRunId: _developerRunId,
            joinCode: connection.snapshot.joinCode,
          );
        }
      }
    } on Object catch (error) {
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        widget.goCoreRuntime?.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (mounted) {
        setState(() {
          _sessionError = error;
          _sessionReady = true;
        });
      }
    }
  }

  Future<void> _initializeStandaloneSession() async {
    if (mounted) {
      setState(() {
        _sessionReady = false;
        _sessionError = null;
      });
    }
    try {
      await _closeSession();
      if (!mounted) {
        return;
      }
      final bridge = StandaloneGameRuntimeBridge(
        gameId: widget.game.id,
        userId: widget.localUserId,
        nickname: widget.localNickname,
      );
      setState(() {
        _soloBridge = bridge;
        _sessionReady = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_soloBridge, bridge)) {
          bridge.setPerformanceVisible(_showPerformance);
        }
      });
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        widget.goCoreRuntime?.reportDeveloperGameRunning(
          projectId: developerProjectId,
          expectedRunId: _developerRunId,
        );
        await _ensureShare(showOverlay: false);
      }
    } on Object catch (error) {
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        widget.goCoreRuntime?.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (mounted) {
        setState(() {
          _sessionError = error;
          _sessionReady = true;
        });
      }
    }
  }

  Future<void> _closeSession() async {
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

  Future<void> _openShare() => _ensureShare(showOverlay: true);

  Future<void> _ensureShare({required bool showOverlay}) async {
    final multiplayer = widget.game.supportsMultiplayer;
    final bridge = _bridge;
    final runtime = widget.goCoreRuntime;
    final gameRootAsset = widget.game.entry.packageRootAssetPath;
    final gameRootFile = widget.game.entry.packageRootFilePath;
    final hasGameRoot = gameRootAsset != null || gameRootFile != null;
    final canShareMultiplayer =
        bridge != null && bridge.connection.isAuthority && runtime != null;
    if (!hasGameRoot || (multiplayer && !canShareMultiplayer)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前页面不能开启浏览器分享。')));
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
    try {
      late final String shareToken;
      late final GameStorageService storage;
      if (multiplayer) {
        final grant = await bridge!.connection.openShare();
        _shareGrantActive = true;
        shareToken = grant.token;
        storage = bridge.storage;
      } else {
        final localStorage = await _soloBridge?.ensureStorage();
        soloStorage = localStorage == null
            ? await GameStorageService.create(gameId: widget.game.id)
            : null;
        shareToken = _newStandaloneShareToken();
        storage = localStorage ?? soloStorage!;
      }
      gateway = await startGameWebGateway(
        gameRootAssetPath: gameRootAsset ?? '',
        gameRootFilePath: gameRootFile,
        multiplayer: multiplayer,
        displayMode: multiplayer
            ? bridge!.connection.snapshot.displayMode
            : 'multi_screen',
        orientation: widget.game.orientation,
        controllerOrientation: widget.game.controllerOrientation,
        gameEntryPath: widget.game.entry.gameEntryPath,
        controllerEntryPath: widget.game.entry.controllerEntryPath,
        gameName: widget.game.name,
        gameSdkVersion: widget.game.sdkVersion.isEmpty
            ? null
            : widget.game.sdkVersion,
        appSdkVersion: widget.game.appSdkVersion.isEmpty
            ? null
            : widget.game.appSdkVersion,
        requiredCapabilities: widget.game.capabilities.required.toList(),
        controllerRequiredCapabilities: widget
            .game
            .capabilities
            .controllerRequired
            .toList(),
        coreEndpoint: multiplayer ? runtime!.endpoint : null,
        joinCode: multiplayer ? bridge!.connection.snapshot.joinCode : null,
        shareToken: shareToken,
        storage: storage,
      );
      final links = await gateway.shareLinks();
      if (!mounted) {
        await gateway.close();
        await soloStorage?.close();
        if (_shareGrantActive) {
          _shareGrantActive = false;
          await bridge?.connection.closeShare();
        }
        return;
      }
      setState(() {
        _webGateway = gateway;
        _soloShareStorage = soloStorage;
        _shareLinks = links;
        _selectedShareLink = links.isEmpty ? null : links.first;
        _shareLoading = false;
      });
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        runtime?.reportDeveloperGameRunning(
          projectId: developerProjectId,
          expectedRunId: _developerRunId,
          joinCode: multiplayer ? bridge!.connection.snapshot.joinCode : null,
          links: links,
        );
      }
    } on Object catch (error) {
      await gateway?.close();
      await soloStorage?.close();
      if (_shareGrantActive) {
        _shareGrantActive = false;
        try {
          await bridge?.connection.closeShare();
        } on Object catch (closeError) {
          debugPrint('回收浏览器分享授权失败: $closeError');
        }
      }
      final developerProjectId = widget.developerProjectId;
      if (developerProjectId != null && !_disposing && mounted) {
        runtime?.reportDeveloperGameError(
          developerProjectId,
          error,
          expectedRunId: _developerRunId,
        );
      }
      if (mounted) {
        setState(() {
          _shareError = error;
          _shareLoading = false;
        });
      }
    }
  }

  Future<void> _hideShare() async {
    if (mounted) {
      setState(() => _shareVisible = false);
    }
  }

  Future<void> _loadRelaySources() async {
    if (_relaySourcesLoading) return;
    final controller = widget.catalogController;
    if (controller == null) {
      if (mounted) {
        setState(() {
          _relaySources = const [];
          _relayError = '当前运行环境未启用在线游戏源';
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
      setState(() => _relayError = '该游戏源未声明公共联机中转能力');
      return;
    }
    if (relayDeclaration.transport != 'playmesh-tcp-upgrade') {
      setState(() => _relayError = '当前 App 不支持该游戏源的中转协议');
      return;
    }
    if (relayDeclaration.protocolVersion != relayProtocolVersion) {
      setState(
        () => _relayError =
            '当前 App 不支持该游戏源的中转协议版本：'
            '${relayDeclaration.protocolVersion}',
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
      final gateway = _webGateway;
      final runtime = widget.goCoreRuntime;
      final entry = _selectedShareLink ?? _shareLinks.firstOrNull;
      if (gateway == null || runtime == null || entry == null) {
        throw StateError('当前游戏尚未建立可供中转使用的本地分享链路');
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

  void _openGameInfo() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff20242b),
      barrierColor: const Color(0x99000000),
      builder: (context) => GameToolInfoSheet(
        title: widget.game.name,
        description: widget.game.description,
        labels: [
          widget.game.entry.statusLabel,
          widget.game.displayModeLabel,
          widget.game.playerRangeLabel,
          widget.game.modeLabel,
        ],
      ),
    );
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

  Future<void> _hideDebugLogs() async {
    if (mounted && !_disposing) {
      setState(() => _debugVisible = false);
    }
    final subscription = _developerLogSubscription;
    _developerLogSubscription = null;
    await subscription?.cancel();
  }

  Future<void> _stopShare() async {
    await _disconnectRelay();
    final gateway = _webGateway;
    _webGateway = null;
    final soloStorage = _soloShareStorage;
    _soloShareStorage = null;
    final hadGrant = _shareGrantActive;
    _shareGrantActive = false;
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
        await _bridge?.connection.closeShare();
      } on Object catch (error) {
        debugPrint('关闭浏览器分享失败: $error');
      }
    }
  }

  Future<void> _restartGame() async {
    final bridge = _bridge;
    final soloBridge = _soloBridge;
    await _webViewBridge?.notifyLifecycle('exit');
    await bridge?.persistStorage();
    await soloBridge?.persistStorage();
    await _soloShareStorage?.flushAll();
    if (!mounted) {
      return;
    }
    _clearLogsForNewRun();
    setState(() {
      _runtimeGeneration += 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _webViewBridge?.setPerformanceVisible(_showPerformance);
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('游戏内容已刷新。')));
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

  Future<void> _exitFullscreen() async {
    try {
      await _orientationController.exitFullscreen();
      if (mounted && _fullscreenError != null) {
        setState(() => _fullscreenError = null);
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('退出全屏失败：$error')));
    }
  }

  Future<void> _returnToPrevious() =>
      _exitOperation ??= _performExitGame(toLibrary: false);

  Future<void> _exitGame() =>
      _exitOperation ??= _performExitGame(toLibrary: true);

  Future<void> _performExitGame({required bool toLibrary}) async {
    try {
      await _closeSession();
    } on Object catch (error) {
      _exitOperation = null;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('退出前保存游戏数据失败：$error')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    final navigator = Navigator.of(context);
    if (toLibrary) {
      navigator.popUntil(
        (route) => route.settings.name == '/games' || route.isFirst,
      );
    } else {
      navigator.pop();
    }
  }
}

enum _SharePanelTab { lan, server, room }

class _ShareOverlay extends StatefulWidget {
  const _ShareOverlay({
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

  _SharePanelTab _tab = _SharePanelTab.lan;
  String _search = '';
  int _page = 1;

  @override
  Widget build(BuildContext context) {
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
                    data: ThemeData.light(useMaterial3: true),
                    child: Material(
                      color: const Color(0xfff7f8f6),
                      borderRadius: BorderRadius.circular(24),
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
                                            ? '分享游戏'
                                            : '加入对局 · ${widget.joinCode}',
                                        style: const TextStyle(
                                          color: Color(0xff17191d),
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '关闭分享',
                                      color: const Color(0xff17191d),
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
          _tabButton(_SharePanelTab.lan, Icons.lan_outlined, '局域网'),
          const SizedBox(width: 8),
          _tabButton(_SharePanelTab.server, Icons.public_outlined, '服务器'),
          const SizedBox(width: 8),
          _tabButton(
            _SharePanelTab.room,
            Icons.groups_outlined,
            '房间状态 (${widget.players.where((player) => player.connected).length})',
          ),
        ],
      ),
    );
  }

  Widget _tabButton(_SharePanelTab value, IconData icon, String label) {
    final selected = _tab == value;
    return Expanded(
      child: Material(
        color: selected ? const Color(0xffdcebe5) : const Color(0x08000000),
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
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
          '无法开启分享\n${widget.error}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xff17191d)),
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
          final declaration = probe.declaration!;
          final haystack = [
            probe.source.name,
            probe.source.host.toString(),
            declaration.displayNameFor(probe.source.host),
            declaration.author ?? '',
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
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索中转游戏源',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() {
                    _search = value;
                    _page = 1;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '重新检测延迟',
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
                '无法获取中转服务器\n${widget.relayError}',
                textAlign: TextAlign.center,
              ),
            )
          else if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Text(
                '已开启的在线游戏源中没有可用的联机中转服务器',
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
                  tooltip: '上一页',
                  onPressed: page <= 1
                      ? null
                      : () => setState(() => _page = page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('$page / $pageCount'),
                IconButton(
                  tooltip: '下一页',
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
      color: const Color(0x08000000),
      child: ListTile(
        title: Text(
          declaration.displayNameFor(probe.source.host),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (declaration.author != null) Text('作者：${declaration.author}'),
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
                label: const Text('游戏源主页'),
              ),
          ],
        ),
        trailing: FilledButton(
          onPressed: widget.relayConnecting
              ? null
              : () => unawaited(widget.onConnectRelay(probe)),
          child: const Text('连接'),
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
          declaration.displayNameFor(source.source.host),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text('游戏源：${source.source.host}'),
        Text('中转地址：${declaration.relay!.publicBaseUrl}'),
        Text('探测延迟：${source.elapsed.inMilliseconds} ms'),
        Text('连接状态：${_relayStatusLabel(widget.relayStatus)}'),
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
            label: const Text('复制服务器加入链接'),
          ),
        ],
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: widget.relayConnecting
              ? null
              : () => unawaited(widget.onDisconnectRelay()),
          icon: const Icon(Icons.link_off),
          label: const Text('断开服务器'),
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
            '已连接 $connected / 已加入 ${widget.players.length}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (widget.players.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Text('暂无已加入玩家', textAlign: TextAlign.center),
            )
          else
            for (final player in widget.players)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: const Color(0x08000000),
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
                  trailing: Text(player.connected ? '在线' : '已断开'),
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
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 18)],
      ),
      child: QrImageView(data: value, size: size),
    );
  }

  Uri? _invitationLink(Uri? link) {
    return link;
  }

  Uri? _lanInvitation(Uri? link) => _invitationLink(link);

  String _relayStatusLabel(RelayConnectionStatus status) => switch (status) {
    RelayConnectionStatus.connecting => '连接中',
    RelayConnectionStatus.connected => '已连接',
    RelayConnectionStatus.retrying => '重试中',
    RelayConnectionStatus.disconnected => '已断开',
  };

  String _playerSourceLabel(String source) => switch (source) {
    'server' => '服务器',
    'lan_app' => '局域网 App',
    'lan_html' => '局域网 HTML',
    _ => source,
  };

  void _copyLink(BuildContext context, Uri link) {
    unawaited(Clipboard.setData(ClipboardData(text: link.toString())));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('加入链接已复制')));
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
          '可用网络地址',
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
                  ? const Color(0xffdcebe5)
                  : const Color(0x0a000000),
              borderRadius: BorderRadius.circular(15),
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
                  tooltip: '复制游戏分享链接',
                  onPressed: () {
                    unawaited(
                      Clipboard.setData(ClipboardData(text: link.toString())),
                    );
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('游戏分享链接已复制')));
                  },
                  icon: const Icon(Icons.copy),
                ),
                onTap: () => onSelectLink(link),
              ),
            ),
          ),
        Text(
          '扫码可在 Playmesh 中直接加入，也可复制链接在浏览器打开。链接在退出游戏前持续有效。',
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
    return Material(
      color: const Color(0xee111827),
      borderRadius: BorderRadius.circular(16),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            const Icon(Icons.fullscreen_exit, color: Colors.amberAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '未能进入全屏，游戏仍可正常游玩。\n$error',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, height: 1.35),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('重试')),
            IconButton(
              tooltip: '关闭提示',
              color: Colors.white70,
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
    return ColoredBox(
      color: const Color(0xff241516),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 42),
              const SizedBox(height: 12),
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => unawaited(onRetry()),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
