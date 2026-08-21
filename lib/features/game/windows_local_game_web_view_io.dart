import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/webview_sdk_navigation_queue.dart';
import '../../core/game_web/game_web_external_navigation.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/developer/developer_run_controller.dart';
import '../../core/developer/developer_external_navigation.dart';

class WindowsLocalGameWebView extends StatefulWidget {
  const WindowsLocalGameWebView({
    super.key,
    required this.assetPath,
    required this.entryUri,
    required this.title,
    this.bridge,
    this.appBridge,
    this.appSdkInputTakenOver = true,
    this.gameExternalNavigationEnabled = false,
    this.onNavigationStarted,
    this.onReloadReady,
    this.onRunJavaScriptReady,
    this.onEvaluateJavaScriptReady,
    this.onOpenExternalUri,
    this.additionalDocumentCreatedScripts = const [],
    this.onWebMessage,
  });

  final String assetPath;
  final Uri entryUri;
  final String title;
  final GameSdkBridge? bridge;
  final AppWebViewBridge? appBridge;
  final bool appSdkInputTakenOver;
  final bool gameExternalNavigationEnabled;
  final VoidCallback? onNavigationStarted;
  final ValueChanged<Future<void> Function()?>? onReloadReady;
  final ValueChanged<Future<void> Function(String)>? onRunJavaScriptReady;
  final ValueChanged<DeveloperWebViewJavaScriptExecutor?>?
  onEvaluateJavaScriptReady;
  final Future<void> Function(Uri uri)? onOpenExternalUri;
  final List<String> additionalDocumentCreatedScripts;
  final bool Function(Object? message)? onWebMessage;

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
  StreamSubscription<WebviewExternalNavigationRequest>?
  _externalNavigationSubscription;
  late final WebViewSdkNavigationQueue _sdkMessages;

  @override
  void initState() {
    super.initState();
    _sdkMessages = WebViewSdkNavigationQueue(_controller.executeScript);
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
      if (widget.gameExternalNavigationEnabled) {
        _externalNavigationSubscription = _controller
            .onExternalNavigationRequested
            .listen((request) {
              final uri = parseGameWebViewExternalUri(request.url);
              if (uri != null) unawaited(_openGameExternalNavigation(uri));
            });
        await _controller.setExternalNavigationEnabled(true);
      }
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
          _sdkMessages.notifyNavigationLoading();
          _resetInitialFocus();
          widget.onNavigationStarted?.call();
          widget.onEvaluateJavaScriptReady?.call(null);
        } else if (state == LoadingState.navigationCompleted) {
          _navigationCompleted = true;
          widget.onEvaluateJavaScriptReady?.call(_controller.executeScript);
          widget.onRunJavaScriptReady?.call(_controller.executeScript);
          final generation = _sdkMessages.generation;
          unawaited(_resumeSdkMessages(generation));
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
        final externalUri = widget.onOpenExternalUri == null
            ? null
            : parsePlaymeshExternalNavigationMessage(message);
        if (externalUri != null) {
          unawaited(widget.onOpenExternalUri!(externalUri));
          return;
        }
        if (widget.onWebMessage?.call(message) == true) return;
        if (message is String) {
          if (message.contains('"command":"app.')) {
            final generation = _sdkMessages.generation;
            unawaited(
              widget.appBridge?.handleJavaScriptMessage(
                message,
                (reply) => _sendAppMessage(reply, generation),
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
      if (widget.onOpenExternalUri != null) {
        await _controller.addScriptToExecuteOnDocumentCreated(
          playmeshExternalNavigationScript,
        );
      }
      for (final script in widget.additionalDocumentCreatedScripts) {
        await _controller.addScriptToExecuteOnDocumentCreated(script);
      }
      _bridgeSubscription = widget.bridge?.outboundMessages.listen(
        (message) => unawaited(_sendToWebView(message)),
      );
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      _sdkMessages.beginNavigation();
      await _controller.loadUrl(widget.entryUri.toString());

      if (mounted) {
        setState(() => _ready = true);
        widget.onReloadReady?.call(_controller.reload);
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
    try {
      await _sdkMessages.addGame(
        gameSdkReceiveScript(message),
        beforeSend: _restoresGameContentFocus(message)
            ? () async {
                try {
                  await _focusNativeWebView();
                } on Object catch (error) {
                  debugPrint('Windows 游戏 WebView 焦点恢复失败: $error');
                }
              }
            : null,
      );
    } on Object catch (error) {
      debugPrint('向 Windows 游戏 WebView 发送 SDK 消息失败: $error');
    }
  }

  Future<void> _openGameExternalNavigation(Uri uri) async {
    if (!await openGameWebViewExternalUri(uri)) {
      debugPrint('系统未能处理 Windows 游戏外部链接: $uri');
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

  Future<void> _sendAppMessage(String message, int generation) async {
    await _sdkMessages.addApp(
      appSdkReceiveScript(message),
      generation: generation,
    );
  }

  Future<void> _resumeSdkMessages(int generation) async {
    if (!mounted) return;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        await _sdkMessages.completeNavigation(generation);
        return;
      } on Object catch (error) {
        if (!mounted ||
            !_navigationCompleted ||
            generation != _sdkMessages.generation) {
          return;
        }
        if (attempt == 2) {
          debugPrint('恢复 Windows 游戏 WebView SDK 消息失败: $error');
          return;
        }
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 0 ? 16 : 64),
        );
      }
    }
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
    widget.onReloadReady?.call(null);
    widget.onEvaluateJavaScriptReady?.call(null);
    _sdkMessages.dispose();
    _initialFocusRetryTimer?.cancel();
    unawaited(_webMessageSubscription?.cancel());
    unawaited(_loadErrorSubscription?.cancel());
    unawaited(_loadingStateSubscription?.cancel());
    unawaited(_focusChangedSubscription?.cancel());
    unawaited(_bridgeSubscription?.cancel());
    unawaited(_externalNavigationSubscription?.cancel());
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
