import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/game_runtime_bridge.dart';
import '../../core/game_sdk/standalone_game_runtime_bridge.dart';
import '../../core/game_web/game_web_gateway.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/session/go_core_session_client.dart';
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
  void Function()? _unregisterDeveloperRestart;
  void Function()? _unregisterDeveloperStop;
  String? _developerRunId;

  GameSdkBridge? get _webViewBridge => _bridge ?? _soloBridge;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showPerformance = widget.initialPerformanceVisible;
    _orientationController =
        widget.orientationController ?? SystemGameOrientationController();
    _applyOrientation(widget.game.orientation);
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
    }
    _initializeSession();
  }

  @override
  void didUpdateWidget(GamePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.orientation != widget.game.orientation) {
      _applyOrientation(widget.game.orientation);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _unregisterDeveloperRestart?.call();
    _unregisterDeveloperRestart = null;
    _unregisterDeveloperStop?.call();
    _unregisterDeveloperStop = null;
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
              backTooltip: '返回游戏详情',
              showPerformance: _showPerformance,
              onTogglePerformance: _togglePerformance,
              onReload: () =>
                  unawaited(_restartGame().catchError((Object _) {})),
              onBack: () => unawaited(_returnToPrevious()),
              onShare: () => unawaited(_openShare()),
              onEnterFullscreen: () => _applyOrientation(
                widget.game.orientation,
                userInitiated: true,
              ),
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
                    widget.game.orientation,
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
                  onClose: _hideShare,
                  onSelectLink: (link) {
                    setState(() => _selectedShareLink = link);
                  },
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
            controllerRole: widget.joinRequest != null,
            onExitRequested: _returnToPrevious,
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
        gameEntryPath: widget.game.entry.gameEntryPath,
        controllerEntryPath: widget.game.entry.controllerEntryPath,
        gameId: widget.game.id,
        gameName: widget.game.name,
        requiredCapabilities: widget.game.capabilities.required.toList(),
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
    if (bridge?.connection.isAuthority ?? false) {
      try {
        await bridge!.connection.reset();
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('重新开始失败：$error')));
        }
        rethrow;
      }
    }
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
    ).showSnackBar(const SnackBar(content: Text('游戏已重新开始。')));
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

class _ShareOverlay extends StatelessWidget {
  const _ShareOverlay({
    required this.joinCode,
    required this.corePort,
    required this.links,
    required this.selectedLink,
    required this.loading,
    required this.error,
    required this.onClose,
    required this.onSelectLink,
  });

  final String? joinCode;
  final int? corePort;
  final List<Uri> links;
  final Uri? selectedLink;
  final bool loading;
  final Object? error;
  final Future<void> Function() onClose;
  final ValueChanged<Uri> onSelectLink;

  @override
  Widget build(BuildContext context) {
    final qrLink = _invitationLink(selectedLink)?.toString();
    return ColoredBox(
      color: const Color(0xc7000000),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final panelWidth = min(720.0, max(0.0, viewport.maxWidth - 20));
            final compact = panelWidth < 590;
            final qrSize = min(
              compact ? 168.0 : 214.0,
              max(48.0, panelWidth - 64),
            );
            final qr = qrLink == null
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(color: Color(0x18000000), blurRadius: 18),
                      ],
                    ),
                    child: QrImageView(data: qrLink, size: qrSize),
                  );
            final addresses = _ShareAddressList(
              links: links,
              selectedLink: selectedLink,
              onSelectLink: onSelectLink,
            );
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
                                        joinCode == null
                                            ? '分享游戏'
                                            : '加入对局 · $joinCode',
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
                                      onPressed: () => unawaited(onClose()),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 1),
                              if (loading)
                                const SizedBox(
                                  height: 240,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else if (error != null)
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    '无法开启分享\n$error',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Color(0xff17191d),
                                    ),
                                  ),
                                )
                              else if (compact)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Center(child: qr),
                                      const SizedBox(height: 16),
                                      addresses,
                                    ],
                                  ),
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      qr,
                                      const SizedBox(width: 20),
                                      Expanded(child: addresses),
                                    ],
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

  Uri? _invitationLink(Uri? link) {
    if (link == null || joinCode == null || corePort == null) return link;
    return link.replace(
      queryParameters: {
        ...link.queryParameters,
        'playmeshCorePort': corePort.toString(),
        'playmeshJoinCode': joinCode!,
      },
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
