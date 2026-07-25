import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/webview_message_queue.dart';
import '../../core/game_web/local_app_sdk_server.dart';
import '../../core/game_web/local_tunnel_gateway.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/platform/app_device_service.dart';
import '../../core/platform/app_platform.dart';
import '../settings/settings_page.dart';
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
  WebViewController? _controller;
  AppWebViewBridge? _appBridge;
  LocalTunnelGateway? _webGateway;
  LocalTunnelGateway? _coreGateway;
  LocalAppSdkServer? _localAppSdkServer;
  Uri? _localEntryUri;
  Object? _error;
  int _windowsReloadKey = 0;
  late final WebViewMessageQueue _messageQueue;
  Future<void> Function(String)? _runWindowsJavaScript;
  bool _showPerformance = true;
  bool _debugVisible = false;
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
        gameName: 'Playmesh 游戏',
        acceptRuntimeGameDeclaration: true,
        coreBaseUri: coreGateway.localBaseUri,
        playerSource: usesRelay ? 'server' : 'lan_app',
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
              _messageQueue.pause(clearPending: true);
              unawaited(_appBridge?.resetCapabilities());
            },
            onPageFinished: (_) {
              unawaited(
                _messageQueue
                    .resume()
                    .then((_) => _syncPerformanceVisible())
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildWebView(),
          GameToolDock(
            backTooltip: '返回加入页面',
            onBack: () => Navigator.of(context).pop(),
            onReload: _reload,
            showPerformance: _showPerformance,
            onTogglePerformance: _togglePerformance,
            onEnterFullscreen: () => _setFullscreen(true),
            onExitFullscreen: () => _setFullscreen(false),
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
              '无法打开主机游戏页面\n$error',
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
        title: 'Playmesh 对局',
        appBridge: appBridge,
        onRunJavaScriptReady: (runJavaScript) {
          _runWindowsJavaScript = runJavaScript;
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
    developerEventHub.beginRuntime();
    _messageQueue.pause(clearPending: true);
    unawaited(_appBridge?.resetCapabilities());
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      setState(() {
        _error = null;
        _runWindowsJavaScript = null;
        _windowsReloadKey += 1;
      });
      return;
    }
    final controller = _controller;
    if (controller != null) {
      setState(() => _error = null);
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
              SnackBar(content: Text('${enabled ? '进入' : '退出'}全屏失败：$error')),
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

  void _openGameInfo() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff20242b),
      barrierColor: const Color(0x99000000),
      builder: (context) => GameToolInfoSheet(
        title: 'Playmesh 对局',
        description: '通过主机分享地址加载，无需在本机安装游戏。',
        labels: const [],
      ),
    );
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

  Future<void> _hideDebugLogs() async {
    if (mounted) setState(() => _debugVisible = false);
    final subscription = _developerLogSubscription;
    _developerLogSubscription = null;
    await subscription?.cancel();
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
