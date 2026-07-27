import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_sdk/webview_message_queue.dart';
import '../../core/game_web/local_app_sdk_server.dart';
import '../../core/game_web/local_tunnel_gateway.dart';
import '../../core/localization/platform_game_ui_assets.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/platform/app_device_service.dart';
import '../../core/platform/app_platform.dart';
import 'game_controls.dart';
import 'windows_local_game_web_view.dart';

class RemoteGamePage extends StatefulWidget {
  const RemoteGamePage({
    super.key,
    required this.entryUri,
    required this.userId,
    required this.nickname,
  });

  final Uri entryUri;
  final String userId;
  final String nickname;

  @override
  State<RemoteGamePage> createState() => _RemoteGamePageState();
}

class _RemoteGamePageState extends State<RemoteGamePage> {
  final GameToolDockController _toolDockController = GameToolDockController();
  WebViewController? _controller;
  AppWebViewBridge? _appBridge;
  LocalTunnelGateway? _webGateway;
  LocalTunnelGateway? _coreGateway;
  LocalAppSdkServer? _localAppSdkServer;
  Uri? _localEntryUri;
  Object? _error;
  int _windowsReloadKey = 0;
  int _toolResetGeneration = 0;
  late final WebViewMessageQueue _messageQueue;
  Future<void> Function(String)? _runWindowsJavaScript;
  String? _platformUiConfigurationKey;
  Map<String, Object?>? _platformUiConfiguration;
  bool _showPerformance = false;
  bool _debugVisible = false;
  bool _infoVisible = false;
  bool _allowPop = false;
  final List<Map<String, Object?>> _developerLogs = [];
  StreamSubscription<Map<String, Object?>>? _developerLogSubscription;

  Uri get _launchUri {
    final base = _localEntryUri ?? widget.entryUri;
    return base.replace(
      queryParameters: {
        ...base.queryParameters,
        'playmeshApp': '1',
        if (_localAppSdkServer case final sdkServer?)
          'playmeshAppSdkUrl': sdkServer.scriptUri.toString(),
        if (widget.nickname.trim().isNotEmpty)
          'playmeshNickname': widget.nickname.trim(),
      },
    );
  }

  bool get _usesFlutterWebView => supportsPlatformWebView;

  @override
  void initState() {
    super.initState();
    developerEventHub.beginRuntime();
    _messageQueue = WebViewMessageQueue(_runJavaScript);
    unawaited(_prepare());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final localizations = PlaymeshLocalizations.maybeOf(context);
    final localeId = localizations?.localeId;
    final brightness = Theme.of(context).brightness;
    final configurationKey = '$localeId:${brightness.name}';
    if (_platformUiConfigurationKey == configurationKey) return;
    _platformUiConfigurationKey = configurationKey;
    _platformUiConfiguration = localizations == null
        ? null
        : platformGameUiConfigurationFor(
            localizations,
            brightness: brightness,
          ).toJson();
    _appBridge?.setPlatformUiConfiguration(_platformUiConfiguration);
    unawaited(_syncPlatformUiConfiguration());
  }

  Future<void> _prepare() async {
    LocalTunnelGateway? webGateway;
    LocalTunnelGateway? coreGateway;
    LocalAppSdkServer? appSdkServer;
    try {
      final entryUri = widget.entryUri;
      final usesRelay = _isRelayInvitation(entryUri);
      if (entryUri.host.isEmpty ||
          (usesRelay
              ? !{'http', 'https'}.contains(entryUri.scheme)
              : entryUri.scheme != 'http')) {
        throw const FormatException('App 游戏入口地址无效');
      }
      appSdkServer = await startLocalAppSdkServer();
      if (usesRelay) {
        webGateway = await startRelayClientGateway(
          invitationUri: entryUri,
          target: RelayTarget.web,
        );
        coreGateway = await startRelayClientGateway(
          invitationUri: entryUri,
          target: RelayTarget.core,
        );
      } else {
        final shareToken = entryUri.queryParameters['token'];
        if (shareToken == null || shareToken.isEmpty) {
          throw const FormatException('局域网游戏邀请缺少 Token');
        }
        final authorityBaseUri = Uri(
          scheme: 'http',
          host: entryUri.host,
          port: entryUri.hasPort ? entryUri.port : null,
          path: '/',
        );
        webGateway = await startLocalTunnelGateway(
          targetBaseUri: authorityBaseUri,
        );
        coreGateway = await startLocalUpgradeTunnelGateway(
          targetBaseUri: authorityBaseUri,
          path: playmeshCoreTunnelPath,
          headers: {playmeshShareTokenHeader: shareToken},
        );
      }
      if (!mounted) {
        await appSdkServer.close();
        await coreGateway.close();
        await webGateway.close();
        return;
      }
      _webGateway = webGateway;
      _coreGateway = coreGateway;
      _localAppSdkServer = appSdkServer;
      _localEntryUri = usesRelay
          ? (webGateway as RelayClientGateway).localEntryUri
          : webGateway.localBaseUri.replace(
              path: entryUri.path,
              queryParameters: entryUri.queryParameters,
            );
      _appBridge = AppWebViewBridge(
        userId: widget.userId,
        nickname: widget.nickname,
        gameName: context.tr('game.remote_title'),
        acceptRuntimeGameDeclaration: true,
        coreBaseUri: coreGateway.localBaseUri,
        playerSource: usesRelay ? 'server' : 'lan_app',
        platformUiConfiguration: _platformUiConfiguration,
        onOpenSharePanel: _rejectShareFromRemote,
        onShowToolDock: _showToolDockFromSdk,
        onHideToolDock: _hideToolDockFromSdk,
        onExitRequested: () async {
          if (mounted) await Navigator.of(context).maybePop();
        },
      );
      if (_usesFlutterWebView) {
        await _initialize();
      } else if (mounted) {
        setState(() {});
      }
    } on Object catch (error) {
      await appSdkServer?.close();
      await coreGateway?.close();
      await webGateway?.close();
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setOnConsoleMessage((message) {
          recordLocalWebViewConsole(
            level: message.level.name,
            message: message.message,
          );
        })
        ..addJavaScriptChannel(
          'PlaymeshAppBridge',
          onMessageReceived: (message) {
            unawaited(
              _appBridge!.handleJavaScriptMessage(
                message.message,
                _sendAppMessage,
              ),
            );
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              _resetTransientUiForLoad();
              _messageQueue.pause(clearPending: true);
              unawaited(_appBridge?.resetCapabilities());
            },
            onPageFinished: (_) {
              unawaited(
                _messageQueue
                    .resume()
                    .then((_) async {
                      await _syncPlatformUiConfiguration();
                      await _syncPerformanceVisible();
                    })
                    .catchError((Object error) {
                      debugPrint('发送远程 WebView Bridge 启动消息失败: $error');
                    }),
              );
            },
            onWebResourceError: (error) {
              recordLocalWebViewConsole(
                level: 'error',
                message:
                    'Resource load failed: ${error.url ?? error.description}',
                href: error.url,
                eventType: 'resource.error',
              );
              if (error.isForMainFrame == true && mounted) {
                setState(() => _error = error.description);
              }
            },
          ),
        );
      _controller = controller;
      await controller.loadRequest(_launchUri);
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _sendAppMessage(String message) async {
    await _messageQueue.add(
      'window.playmeshApp && window.playmeshApp.__receive(${jsonEncode(message)});',
    );
  }

  Future<void> _runJavaScript(String script) async {
    final controller = _controller;
    if (controller == null) throw StateError('远程游戏 WebView 尚未创建');
    await controller.runJavaScript(script);
  }

  Future<void> _syncPlatformUiConfiguration() async {
    final configuration = _platformUiConfiguration;
    if (configuration == null) return;
    _appBridge?.setPlatformUiConfiguration(configuration);
    final script = gameSdkReceiveScript(
      jsonEncode({
        'type': 'platform.ui.configure',
        'configuration': configuration,
      }),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _runWindowsJavaScript?.call(script);
      return;
    }
    if (_controller != null) await _messageQueue.add(script);
  }

  @override
  void dispose() {
    unawaited(_developerLogSubscription?.cancel());
    _developerLogSubscription = null;
    unawaited(_appBridge?.close());
    unawaited(_localAppSdkServer?.close());
    unawaited(_coreGateway?.close());
    unawaited(_webGateway?.close());
    unawaited(
      const AppDeviceService().setFullscreen(false).catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GameRuntimeShortcutScope(
      controller: _toolDockController,
      onBack: _handleRuntimeBack,
      onOpenTools: _openToolsFromShortcut,
      onMoveTools: _moveToolsFromShortcut,
      child: PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleRuntimeBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildWebView(),
              GameToolDock(
                controller: _toolDockController,
                resetKey: Object.hash(_windowsReloadKey, _toolResetGeneration),
                backTooltip: context.tr('game.back_join'),
                onBack: _exitRemotePage,
                onReload: _reload,
                showPerformance: _showPerformance,
                onTogglePerformance: _togglePerformance,
                onOpenLogs: _openDebugLogs,
                onEnterFullscreen: () => _setFullscreen(true),
                onExitFullscreen: () => _setFullscreen(false),
                secondaryActions: [
                  GameToolAction(
                    icon: Icons.info_outline,
                    label: context.tr('game.info'),
                    onPressed: () => unawaited(_openGameInfo()),
                  ),
                ],
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

  Widget _buildWebView() {
    final error = _error;
    if (error != null) {
      return ColoredBox(
        color: const Color(0xff241516),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.tr(
                'game.remote_open_failed',
                arguments: {'error': error},
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final appBridge = _appBridge;
      if (appBridge == null) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
      return WindowsLocalGameWebView(
        key: ValueKey('remote-game-$_windowsReloadKey'),
        assetPath: _launchUri.path,
        entryUri: _launchUri,
        title: context.tr('game.remote_title'),
        appBridge: appBridge,
        onRunJavaScriptReady: (runJavaScript) {
          _runWindowsJavaScript = runJavaScript;
          unawaited(_syncPlatformUiConfiguration());
          unawaited(_syncPerformanceVisible());
        },
      );
    }
    final controller = _controller;
    if (controller != null) return WebViewWidget(controller: controller);
    if (_usesFlutterWebView) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(
      child: SelectableText(
        _launchUri.toString(),
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white),
      ),
    );
  }

  void _reload() {
    if (_infoVisible && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    developerEventHub.beginRuntime();
    _messageQueue.pause(clearPending: true);
    unawaited(_appBridge?.resetCapabilities());
    unawaited(_hideDebugLogs(restoreFocus: false));
    setState(() {
      _error = null;
      _runWindowsJavaScript = null;
      _showPerformance = false;
      _debugVisible = false;
      _windowsReloadKey += 1;
      _toolResetGeneration += 1;
    });
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return;
    }
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.reload());
      return;
    }
    if (_usesFlutterWebView) {
      setState(() => _error = null);
      unawaited(_appBridge == null ? _prepare() : _initialize());
    }
  }

  void _setFullscreen(bool enabled) {
    unawaited(
      const AppDeviceService()
          .setFullscreen(enabled, orientation: null)
          .catchError((Object error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.tr(
                    enabled
                        ? 'game.fullscreen_enter_failed'
                        : 'game.fullscreen_exit_failed',
                    arguments: {'error': error},
                  ),
                ),
              ),
            );
          }),
    );
  }

  void _togglePerformance() {
    setState(() => _showPerformance = !_showPerformance);
    unawaited(_syncPerformanceVisible());
  }

  Future<void> _syncPerformanceVisible() async {
    final script =
        'window.playmesh && window.playmesh.performance && '
        'window.playmesh.performance.setVisible(${jsonEncode(_showPerformance)});';
    try {
      final runWindowsJavaScript = _runWindowsJavaScript;
      if (runWindowsJavaScript != null) {
        await runWindowsJavaScript(script);
      } else if (_controller != null) {
        await _controller!.runJavaScript(script);
      }
    } on Object catch (error) {
      debugPrint('同步扫码加入页性能显示失败: $error');
    }
  }

  Future<void> _openGameInfo() async {
    if (_infoVisible || !mounted) return;
    _infoVisible = true;
    await showModalBottomSheet<void>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (context) => GameToolInfoSheet(
        title: context.tr('game.remote_title'),
        description: context.tr('game.remote_description'),
        labels: const [],
      ),
    );
    _infoVisible = false;
    if (mounted) _toolDockController.restoreFocus();
  }

  void _openDebugLogs() {
    _developerLogs
      ..clear()
      ..addAll(developerEventHub.recentLogs);
    _developerLogSubscription ??= developerEventHub.events.listen((event) {
      if (event['type'] != 'runtime.log' || !mounted) return;
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
    if (mounted) {
      setState(() => _debugVisible = false);
      if (restoreFocus) _toolDockController.restoreFocus();
    }
    final subscription = _developerLogSubscription;
    _developerLogSubscription = null;
    await subscription?.cancel();
  }

  void _resetTransientUiForLoad() {
    if (!mounted) return;
    if (_infoVisible && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    final hadDebugOverlay = _debugVisible;
    setState(() {
      _showPerformance = false;
      _debugVisible = false;
      _toolResetGeneration += 1;
    });
    if (hadDebugOverlay || _developerLogSubscription != null) {
      unawaited(_hideDebugLogs(restoreFocus: false));
    }
    unawaited(_syncPerformanceVisible());
  }

  void _handleRuntimeBack() {
    if (_toolDockController.isMoving) {
      _toolDockController.closeTopLayer();
      return;
    }
    if (_debugVisible) {
      unawaited(_hideDebugLogs());
      return;
    }
    if (_toolDockController.closeTopLayer()) return;
    _exitRemotePage();
  }

  void _exitRemotePage() {
    if (_allowPop || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _openToolsFromShortcut() {
    if (_debugVisible || _infoVisible) return;
    _toolDockController.openTools();
  }

  void _moveToolsFromShortcut() {
    if (_debugVisible || _infoVisible) return;
    _toolDockController.beginMoveMode();
  }

  Future<void> _rejectShareFromRemote() {
    throw const SdkCommandException(
      'not_authority',
      '只有当前 Authority 游戏可以打开分享界面',
    );
  }

  Future<void> _showToolDockFromSdk() async {
    if (!mounted ||
        _debugVisible ||
        _infoVisible ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏工具不可用');
    }
    if (!_toolDockController.showFromSdk()) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏工具不可用');
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _hideToolDockFromSdk() async {
    if (!mounted) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏工具不可用');
    }
    if (!_toolDockController.hideFromSdk()) {
      throw const SdkCommandException('ui_unavailable', '当前平台游戏工具不可用');
    }
    await WidgetsBinding.instance.endOfFrame;
  }
}

bool _isRelayInvitation(Uri value) {
  final segments = value.pathSegments;
  if (segments.length != 2 || segments.first != 'j') return false;
  if (value.fragment.isEmpty) return false;
  try {
    return Uri.splitQueryString(value.fragment)['inviteToken']?.isNotEmpty ==
        true;
  } on FormatException {
    return false;
  }
}
