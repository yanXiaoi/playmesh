import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/developer/developer_run_controller.dart';

class WindowsLocalGameWebView extends StatefulWidget {
  const WindowsLocalGameWebView({
    super.key,
    required this.assetPath,
    required this.entryUri,
    required this.title,
    this.bridge,
    this.appBridge,
    this.onRunJavaScriptReady,
    this.onEvaluateJavaScriptReady,
  });

  final String assetPath;
  final Uri entryUri;
  final String title;
  final GameSdkBridge? bridge;
  final AppWebViewBridge? appBridge;
  final ValueChanged<Future<void> Function(String)>? onRunJavaScriptReady;
  final ValueChanged<DeveloperWebViewJavaScriptExecutor?>?
  onEvaluateJavaScriptReady;

  @override
  State<WindowsLocalGameWebView> createState() =>
      _WindowsLocalGameWebViewState();
}

class _WindowsLocalGameWebViewState extends State<WindowsLocalGameWebView> {
  final WebviewController _controller = WebviewController();
  Object? _loadError;
  bool _ready = false;
  StreamSubscription<dynamic>? _webMessageSubscription;
  StreamSubscription<WebErrorStatus>? _loadErrorSubscription;
  StreamSubscription<LoadingState>? _loadingStateSubscription;
  StreamSubscription<String>? _bridgeSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final webViewVersion = await WebviewController.getWebViewVersion();
      if (webViewVersion == null) {
        throw StateError('未安装 Microsoft Edge WebView2 Runtime');
      }

      await _controller.initialize();
      _loadingStateSubscription = _controller.loadingState.listen((state) {
        if (state == LoadingState.loading) {
          widget.onEvaluateJavaScriptReady?.call(null);
        } else if (state == LoadingState.navigationCompleted) {
          widget.onEvaluateJavaScriptReady?.call(_controller.executeScript);
        }
      });
      _loadErrorSubscription = _controller.onLoadError.listen((error) {
        recordLocalWebViewConsole(
          level: 'error',
          message: 'WebView navigation failed: ${error.name}',
          source: widget.bridge == null && widget.appBridge == null
              ? 'standalone-html-webview'
              : 'app-webview',
          href: widget.entryUri.toString(),
          eventType: 'navigation.error',
        );
      });
      _webMessageSubscription = _controller.webMessage.listen((message) {
        if (handleWindowsWebViewConsoleMessage(
          message,
          source: widget.bridge == null && widget.appBridge == null
              ? 'standalone-html-webview'
              : 'app-webview',
        )) {
          return;
        }
        if (message is String) {
          if (message.contains('"command":"app.')) {
            unawaited(
              widget.appBridge?.handleJavaScriptMessage(
                message,
                _sendAppMessage,
              ),
            );
          } else {
            unawaited(widget.bridge?.handleJavaScriptMessage(message));
          }
        }
      });
      await _controller.addScriptToExecuteOnDocumentCreated(
        windowsWebViewConsoleCaptureScript,
      );
      _bridgeSubscription = widget.bridge?.outboundMessages.listen(
        (message) => unawaited(_sendToWebView(message)),
      );
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.loadUrl(widget.entryUri.toString());
      widget.onRunJavaScriptReady?.call((script) async {
        await _controller.executeScript(script);
      });
      widget.onEvaluateJavaScriptReady?.call(_controller.executeScript);

      if (mounted) {
        setState(() => _ready = true);
      }
    } on Object catch (error) {
      recordLocalWebViewConsole(
        level: 'error',
        message: 'WebView startup failed: $error',
        source: widget.bridge == null && widget.appBridge == null
            ? 'standalone-html-webview'
            : 'app-webview',
        href: widget.entryUri.toString(),
        eventType: 'webview.startup.error',
      );
      if (mounted) {
        setState(() => _loadError = error);
      }
    }
  }

  Future<void> _sendToWebView(String message) async {
    try {
      await _controller.executeScript(gameSdkReceiveScript(message));
    } on Object catch (error) {
      debugPrint('向 Windows 游戏 WebView 发送 SDK 消息失败: $error');
    }
  }

  Future<void> _sendAppMessage(String message) async {
    await _controller.executeScript(
      'window.playmeshApp && window.playmeshApp.__receive($message);',
    );
  }

  @override
  void dispose() {
    widget.onEvaluateJavaScriptReady?.call(null);
    unawaited(_webMessageSubscription?.cancel());
    unawaited(_loadErrorSubscription?.cancel());
    unawaited(_loadingStateSubscription?.cancel());
    unawaited(_bridgeSubscription?.cancel());
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _loadError;
    if (error != null) {
      return _WindowsWebViewFailure(title: widget.title, error: error);
    }
    if (!_ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Webview(_controller);
  }
}

class _WindowsWebViewFailure extends StatelessWidget {
  const _WindowsWebViewFailure({required this.title, required this.error});

  final String title;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff241516),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 42),
            const SizedBox(height: 16),
            Text(
              '$title 无法启动',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
