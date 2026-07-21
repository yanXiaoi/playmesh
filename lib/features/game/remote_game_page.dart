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

  Uri get _launchUri => widget.entryUri.replace(
    queryParameters: {
      ...widget.entryUri.queryParameters,
      'playmeshApp': '1',
      if (widget.nickname.trim().isNotEmpty)
        'playmeshNickname': widget.nickname.trim(),
    },
  );

  bool get _usesFlutterWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

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
                _messageQueue.resume().catchError((Object error) {
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
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 8,
            child: Material(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '返回',
                    color: Colors.white,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: '重新加载',
                    color: Colors.white,
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '进入全屏',
                    color: Colors.white,
                    onPressed: () => _setFullscreen(true),
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: '退出全屏',
                    color: Colors.white,
                    onPressed: () => _setFullscreen(false),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ],
              ),
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
}
