import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/webview_message_queue.dart';
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
  Object? _error;
  int _windowsReloadKey = 0;
  late final WebViewMessageQueue _messageQueue;
  ({String gameId, String gameName, List<String> required})? _descriptor;
  Future<void> Function(String)? _runWindowsJavaScript;
  bool _showPerformance = true;
  bool _debugVisible = false;
  final List<Map<String, Object?>> _developerLogs = [];
  StreamSubscription<Map<String, Object?>>? _developerLogSubscription;

  Uri get _launchUri => widget.entryUri.replace(
    queryParameters: {
      ...widget.entryUri.queryParameters,
      'playmeshApp': '1',
      if (widget.nickname.trim().isNotEmpty)
        'playmeshNickname': widget.nickname.trim(),
    },
  );

  bool get _usesFlutterWebView => supportsPlatformWebView;

  @override
  void initState() {
    super.initState();
    developerEventHub.beginRuntime();
    _messageQueue = WebViewMessageQueue(_runJavaScript);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final descriptor = await _loadDeclaredCapabilities();
      if (!mounted) return;
      _descriptor = descriptor;
      _appBridge = AppWebViewBridge(
        userId: widget.userId,
        nickname: widget.nickname,
        gameName: descriptor.gameName,
        declaredCapabilities: descriptor.required,
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
      if (mounted) setState(() => _error = error);
    }
  }

  Future<({String gameId, String gameName, List<String> required})>
  _loadDeclaredCapabilities() async {
    final token = widget.entryUri.queryParameters['token'];
    if (token == null || token.isEmpty) {
      throw const FormatException('App 游戏入口缺少分享 token');
    }
    final uri = widget.entryUri.replace(
      path: '/api/app-capabilities',
      queryParameters: {'token': token},
      fragment: null,
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('读取当前游戏设备能力失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map ||
        decoded['gameId'] is! String ||
        decoded['gameName'] is! String ||
        decoded['required'] is! List) {
      throw const FormatException('当前游戏设备能力定义无效');
    }
    return (
      gameId: decoded['gameId']! as String,
      gameName: decoded['gameName']! as String,
      required: List<String>.unmodifiable(
        (decoded['required']! as List).cast<String>(),
      ),
    );
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
              unawaited(_appBridge?.resetDeviceSubscriptions());
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
    unawaited(_appBridge?.resetDeviceSubscriptions());
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
      const AppDeviceService().setFullscreen(enabled).catchError((
        Object error,
      ) {
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
    final descriptor = _descriptor;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff20242b),
      barrierColor: const Color(0x99000000),
      builder: (context) => GameToolInfoSheet(
        title: descriptor?.gameName ?? 'Playmesh 对局',
        description: '通过主机分享地址加载，无需在本机安装游戏。',
        labels: [
          if (widget.entryUri.queryParameters['playmeshJoinCode']
              case final code?)
            '加入码 $code',
          if (descriptor != null) descriptor.gameId,
        ],
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
