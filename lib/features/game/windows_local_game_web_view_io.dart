import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/localization/playmesh_localization.dart';
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
    this.appSdkInputTakenOver = true,
    this.onNavigationStarted,
    this.onRunJavaScriptReady,
    this.onEvaluateJavaScriptReady,
  });

  final String assetPath;
  final Uri entryUri;
  final String title;
  final GameSdkBridge? bridge;
  final AppWebViewBridge? appBridge;
  final bool appSdkInputTakenOver;
  final VoidCallback? onNavigationStarted;
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
  bool _navigationCompleted = false;
  bool _initialFocusScheduled = false;
  bool _initialFocusGranted = false;
  int _initialFocusAttempts = 0;
  Timer? _initialFocusRetryTimer;
  StreamSubscription<dynamic>? _webMessageSubscription;
  StreamSubscription<WebErrorStatus>? _loadErrorSubscription;
  StreamSubscription<LoadingState>? _loadingStateSubscription;
  StreamSubscription<bool>? _focusChangedSubscription;
  StreamSubscription<String>? _bridgeSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant WindowsLocalGameWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appSdkInputTakenOver == widget.appSdkInputTakenOver) return;
    if (widget.appSdkInputTakenOver) {
      _scheduleInitialFocus();
    } else {
      _resetInitialFocus();
      unawaited(WebviewController.releaseFocus());
    }
  }

  Future<void> _initialize() async {
    try {
      final webViewVersion = await WebviewController.getWebViewVersion();
      if (webViewVersion == null) {
        throw StateError('未安装 Microsoft Edge WebView2 Runtime');
      }

      await _controller.initialize();
      _focusChangedSubscription = _controller.onFocusChanged.listen((focused) {
        if (!focused || !widget.appSdkInputTakenOver) return;
        _initialFocusGranted = true;
        _initialFocusAttempts = 0;
        _initialFocusRetryTimer?.cancel();
        _initialFocusRetryTimer = null;
      });
      if (!widget.appSdkInputTakenOver) {
        await WebviewController.releaseFocus();
      }
      _loadingStateSubscription = _controller.loadingState.listen((state) {
        if (state == LoadingState.loading) {
          _navigationCompleted = false;
          _resetInitialFocus();
          widget.onNavigationStarted?.call();
          widget.onEvaluateJavaScriptReady?.call(null);
        } else if (state == LoadingState.navigationCompleted) {
          _navigationCompleted = true;
          widget.onEvaluateJavaScriptReady?.call(_controller.executeScript);
          _scheduleInitialFocus();
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
        _scheduleInitialFocus();
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
    if (_restoresGameContentFocus(message)) {
      try {
        await _focusNativeWebView();
      } on Object catch (error) {
        debugPrint('Windows 游戏 WebView 焦点恢复失败: $error');
      }
    }
    try {
      await _controller.executeScript(gameSdkReceiveScript(message));
    } on Object catch (error) {
      debugPrint('向 Windows 游戏 WebView 发送 SDK 消息失败: $error');
    }
  }

  void _scheduleInitialFocus() {
    if (!mounted ||
        !widget.appSdkInputTakenOver ||
        !_navigationCompleted ||
        _initialFocusScheduled ||
        _initialFocusGranted) {
      return;
    }
    _initialFocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initialFocusScheduled = false;
      if (!mounted ||
          !_ready ||
          !widget.appSdkInputTakenOver ||
          !_navigationCompleted ||
          _initialFocusGranted) {
        return;
      }
      try {
        _initialFocusAttempts += 1;
        await _focusNativeWebView();
        if (_controller.hasNativeFocus) {
          _initialFocusGranted = true;
          _initialFocusAttempts = 0;
        } else {
          _scheduleInitialFocusRetry();
        }
      } on Object catch (error) {
        debugPrint('Windows 游戏 WebView 初始聚焦失败: $error');
        _scheduleInitialFocusRetry();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scheduleInitialFocusRetry() {
    if (!mounted ||
        _initialFocusGranted ||
        _initialFocusAttempts >= 6 ||
        !widget.appSdkInputTakenOver ||
        !_navigationCompleted) {
      return;
    }
    _initialFocusRetryTimer?.cancel();
    final delay = switch (_initialFocusAttempts) {
      <= 1 => const Duration(milliseconds: 40),
      2 => const Duration(milliseconds: 80),
      3 => const Duration(milliseconds: 140),
      _ => const Duration(milliseconds: 240),
    };
    _initialFocusRetryTimer = Timer(delay, () {
      _initialFocusRetryTimer = null;
      _scheduleInitialFocus();
    });
  }

  void _resetInitialFocus() {
    _initialFocusGranted = false;
    _initialFocusAttempts = 0;
    _initialFocusRetryTimer?.cancel();
    _initialFocusRetryTimer = null;
  }

  Future<void> _focusNativeWebView() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _controller.focus();
  }

  bool _restoresGameContentFocus(String message) {
    try {
      final decoded = jsonDecode(message);
      return decoded is Map &&
          decoded['type'] == 'platform.ui.restoreGameFocus';
    } on FormatException {
      return false;
    }
  }

  Future<void> _sendAppMessage(String message) async {
    await _controller.executeScript(appSdkReceiveScript(message));
  }

  Future<WebviewPermissionDecision> _handlePermissionRequest(
    String url,
    WebviewPermissionKind kind,
    bool isUserInitiated,
  ) async {
    final allowed =
        await widget.appBridge?.authorizeWebPermissions(
          [kind.name],
          sourceUri: Uri.tryParse(url),
          isUserInitiated: isUserInitiated,
        ) ??
        false;
    return allowed
        ? WebviewPermissionDecision.allow
        : WebviewPermissionDecision.deny;
  }

  @override
  void dispose() {
    widget.onEvaluateJavaScriptReady?.call(null);
    _initialFocusRetryTimer?.cancel();
    unawaited(_webMessageSubscription?.cancel());
    unawaited(_loadErrorSubscription?.cancel());
    unawaited(_loadingStateSubscription?.cancel());
    unawaited(_focusChangedSubscription?.cancel());
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

    return Webview(_controller, permissionRequested: _handlePermissionRequest);
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
              context.tr('game.start_failed', arguments: {'title': title}),
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
