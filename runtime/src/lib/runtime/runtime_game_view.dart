import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:playmesh_ui/playmesh_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'runtime_android_webview_file_selector.dart';
import 'runtime_app_bridge.dart';
import 'runtime_external_navigation.dart';
import 'runtime_game_bridge.dart';
import 'runtime_navigation.dart';
import 'runtime_package.dart';
import 'runtime_webview_message_queue.dart';

final class RuntimeGameView extends StatefulWidget {
  const RuntimeGameView({
    super.key,
    required this.entryUri,
    required this.game,
    required this.gameBridge,
    required this.appBridge,
    required this.navigation,
    required this.inputTakenOver,
    required this.onExitRequested,
  });

  final Uri entryUri;
  final RuntimeGameManifest game;
  final RuntimeGameBridge gameBridge;
  final RuntimeAppBridge appBridge;
  final RuntimeNavigation navigation;
  final ValueNotifier<bool> inputTakenOver;
  final Future<void> Function() onExitRequested;

  @override
  State<RuntimeGameView> createState() => _RuntimeGameViewState();
}

final class _RuntimeGameViewState extends State<RuntimeGameView> {
  WebViewController? _android;
  WebviewController? _windows;
  StreamSubscription<String>? _outbound;
  StreamSubscription<dynamic>? _windowsMessages;
  StreamSubscription<LoadingState>? _windowsLoadingState;
  StreamSubscription<WebviewExternalNavigationRequest>?
  _windowsExternalNavigation;
  StreamSubscription<Uri>? _navigationRequests;
  Object? _error;
  final RuntimeAndroidWebViewFileSelector _androidFileSelector =
      const RuntimeAndroidWebViewFileSelector();
  final FocusNode _nativeInputFallbackFocusNode = FocusNode(
    debugLabel: 'runtime-native-input-fallback',
  );
  final FocusScopeNode _androidWebViewFocusScopeNode = FocusScopeNode(
    debugLabel: 'runtime-android-webview',
  );
  bool _androidNavigationCompleted = false;
  bool _androidWebViewFocusScheduled = false;
  bool _androidWebViewFocusGranted = false;
  int _androidWebViewFocusAttempts = 0;
  Timer? _androidWebViewFocusRetryTimer;
  Future<void>? _nativeExitOperation;
  late final RuntimeWebViewMessageQueue _messageQueue =
      RuntimeWebViewMessageQueue(_executeImmediately);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_recordHardwareUserActivation);
    widget.inputTakenOver.addListener(_handleInputOwnershipChanged);
    _navigationRequests = widget.navigation.requests.listen(
      (uri) => unawaited(_load(uri)),
    );
    unawaited(Platform.isWindows ? _initializeWindows() : _initializeAndroid());
  }

  bool _recordHardwareUserActivation(KeyEvent event) {
    if (event is KeyDownEvent) widget.appBridge.recordUserActivation();
    return false;
  }

  void _handleInputOwnershipChanged() {
    if (!mounted) return;
    if (widget.inputTakenOver.value) {
      _nativeInputFallbackFocusNode.unfocus();
      _resetAndroidWebViewFocus();
      _scheduleAndroidWebViewFocus();
    } else {
      _resetAndroidWebViewFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            widget.inputTakenOver.value ||
            !_nativeInputFallbackFocusNode.canRequestFocus) {
          return;
        }
        _nativeInputFallbackFocusNode.requestFocus();
      });
    }
    setState(() {});
  }

  Future<void> _load(Uri uri) async {
    if (_android case final controller?) {
      await controller.loadRequest(uri);
    } else if (_windows case final controller?) {
      await controller.loadUrl(uri.toString());
    } else {
      throw StateError('Runtime WebView 尚未就绪');
    }
  }

  KeyEventResult _handleNativeFallbackKey(FocusNode _, KeyEvent event) {
    if (widget.inputTakenOver.value || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.gameButtonB) {
      _exitBeforeAppSdkTakeover();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _exitBeforeAppSdkTakeover() {
    _nativeExitOperation ??= widget.onExitRequested().whenComplete(() {
      _nativeExitOperation = null;
    });
  }

  void _handleNativeSystemBack() {
    if (!widget.inputTakenOver.value) {
      _exitBeforeAppSdkTakeover();
      return;
    }
    if (Platform.isAndroid) unawaited(_forwardAndroidBackToAppSdk());
  }

  Future<void> _forwardAndroidBackToAppSdk() async {
    try {
      final handled = await _evaluateJavaScript(
        'Boolean(window[Symbol.for("playmesh.app.internal.v1")]'
        '?.handleNativeBack?.())',
      );
      if (handled == true || handled.toString() == 'true') return;
    } on Object catch (error) {
      debugPrint('Runtime Android 系统返回未能交给 App SDK: $error');
    }
    _exitBeforeAppSdkTakeover();
  }

  Future<Object?> _evaluateJavaScript(String source) async {
    if (_android case final controller?) {
      return controller.runJavaScriptReturningResult(source);
    }
    if (_windows case final controller?) {
      return controller.executeScript(source);
    }
    throw StateError('Runtime WebView 尚未创建');
  }

  void _scheduleAndroidWebViewFocus() {
    if (!mounted ||
        !Platform.isAndroid ||
        !widget.inputTakenOver.value ||
        !_androidNavigationCompleted ||
        _android == null ||
        _androidWebViewFocusScheduled ||
        _androidWebViewFocusGranted) {
      return;
    }
    _androidWebViewFocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _androidWebViewFocusScheduled = false;
      if (!mounted ||
          !widget.inputTakenOver.value ||
          !_androidNavigationCompleted) {
        return;
      }
      _androidWebViewFocusAttempts += 1;
      FocusNode? platformViewFocus;
      for (final node in _androidWebViewFocusScopeNode.traversalDescendants) {
        if (node.canRequestFocus) {
          platformViewFocus = node;
          break;
        }
      }
      if (platformViewFocus == null) {
        _scheduleAndroidWebViewFocusRetry();
        return;
      }
      FocusManager.instance.primaryFocus?.unfocus();
      platformViewFocus.requestFocus();
      unawaited(_confirmAndroidWebViewFocus(platformViewFocus));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _confirmAndroidWebViewFocus(FocusNode platformViewFocus) async {
    try {
      await _executeImmediately('window.focus();');
      final result = await _evaluateJavaScript('document.hasFocus()');
      final documentFocused =
          result == true || result.toString().toLowerCase() == 'true';
      if (mounted &&
          platformViewFocus.hasFocus &&
          documentFocused &&
          widget.inputTakenOver.value &&
          _androidNavigationCompleted) {
        _androidWebViewFocusGranted = true;
        _androidWebViewFocusAttempts = 0;
        _androidWebViewFocusRetryTimer?.cancel();
        _androidWebViewFocusRetryTimer = null;
        return;
      }
    } on Object catch (error) {
      debugPrint('Runtime Android 游戏 WebView 焦点确认失败: $error');
    }
    _scheduleAndroidWebViewFocusRetry();
  }

  void _scheduleAndroidWebViewFocusRetry() {
    if (!mounted ||
        _androidWebViewFocusGranted ||
        _androidWebViewFocusAttempts >= 6 ||
        !widget.inputTakenOver.value ||
        !_androidNavigationCompleted) {
      return;
    }
    _androidWebViewFocusRetryTimer?.cancel();
    final delay = switch (_androidWebViewFocusAttempts) {
      <= 1 => const Duration(milliseconds: 40),
      2 => const Duration(milliseconds: 80),
      3 => const Duration(milliseconds: 140),
      _ => const Duration(milliseconds: 240),
    };
    _androidWebViewFocusRetryTimer = Timer(delay, () {
      _androidWebViewFocusRetryTimer = null;
      _scheduleAndroidWebViewFocus();
    });
  }

  void _resetAndroidWebViewFocus() {
    _androidWebViewFocusGranted = false;
    _androidWebViewFocusAttempts = 0;
    _androidWebViewFocusRetryTimer?.cancel();
    _androidWebViewFocusRetryTimer = null;
  }

  Future<void> _initializeAndroid() async {
    try {
      // MainActivity disables debugging before Flutter starts, but a WebView
      // provider on a userdebug device can restore its platform default while
      // the first native WebView is created. Reassert the setting through the
      // plugin after that native controller exists and before loading any game
      // content.
      final controller =
          WebViewController(
              onPermissionRequest: (request) async {
                try {
                  final allowed = await widget.appBridge
                      .authorizeWebPermissions(
                        request.types.map((value) => value.name),
                        sourceUri: widget.entryUri,
                      );
                  if (allowed) {
                    await request.grant();
                  } else {
                    await request.deny();
                  }
                } on Object catch (error) {
                  debugPrint('Runtime 处理 WebView 权限请求失败: $error');
                  await request.deny();
                }
              },
            )
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setOnConsoleMessage((message) {
              debugPrint(
                '[Runtime WebView ${message.level.name}] ${message.message}',
              );
            })
            ..addJavaScriptChannel(
              'PlaymeshBridge',
              onMessageReceived: (message) =>
                  unawaited(widget.gameBridge.handle(message.message)),
            )
            ..addJavaScriptChannel(
              'PlaymeshAppBridge',
              onMessageReceived: (message) {
                final generation = _messageQueue.generation;
                unawaited(_handleAppBridgeMessage(message.message, generation));
              },
            )
            ..addJavaScriptChannel(
              runtimeExternalNavigationChannel,
              onMessageReceived: (message) {
                final uri = parseRuntimeExternalNavigationMessage(
                  message.message,
                );
                if (uri != null) unawaited(_openExternalNavigation(uri));
              },
            )
            ..setNavigationDelegate(
              NavigationDelegate(
                onNavigationRequest: _handleNavigationRequest,
                onPageStarted: (_) {
                  _androidNavigationCompleted = false;
                  widget.inputTakenOver.value = false;
                  _resetAndroidWebViewFocus();
                  _messageQueue.pause(clearPending: true);
                  unawaited(widget.appBridge.resetDocument());
                  unawaited(
                    _executeImmediately(runtimeWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('Runtime 安装 Android 外部导航脚本失败: $error');
                    }),
                  );
                },
                onPageFinished: (_) {
                  _androidNavigationCompleted = true;
                  unawaited(
                    _executeImmediately(runtimeWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('Runtime 确认 Android 外部导航脚本失败: $error');
                    }),
                  );
                  unawaited(
                    _resumeDocument().catchError((Object error) {
                      debugPrint('Runtime WebView 启动消息投递失败: $error');
                    }),
                  );
                  _scheduleAndroidWebViewFocus();
                },
                onWebResourceError: (error) {
                  debugPrint(
                    'Runtime WebView 资源加载失败: '
                    '${error.url ?? error.description}',
                  );
                },
              ),
            );
      if (controller.platform case final AndroidWebViewController android) {
        await android.setMediaPlaybackRequiresUserGesture(false);
        await android.setOnShowFileSelector(_androidFileSelector.select);
      }
      await AndroidWebViewController.enableDebugging(false);
      _android = controller;
      _outbound = widget.gameBridge.outboundMessages.listen(
        (message) => unawaited(_sendGameMessage(message)),
      );
      await controller.loadRequest(widget.entryUri);
      if (mounted) {
        setState(() {});
        _scheduleAndroidWebViewFocus();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _initializeWindows() async {
    try {
      if (await WebviewController.getWebViewVersion() == null) {
        throw StateError('未安装 Microsoft Edge WebView2 Runtime');
      }
      final controller = WebviewController();
      await controller.initialize();
      _windows = controller;
      _windowsExternalNavigation = controller.onExternalNavigationRequested
          .listen((request) {
            final uri = parseRuntimeExternalUri(request.url);
            if (uri != null) unawaited(_openExternalNavigation(uri));
          });
      await controller.setExternalNavigationEnabled(true);
      _windowsLoadingState = controller.loadingState.listen((state) {
        if (state == LoadingState.loading) {
          widget.inputTakenOver.value = false;
          _messageQueue.pause(clearPending: true);
          unawaited(widget.appBridge.resetDocument());
        } else if (state == LoadingState.navigationCompleted) {
          unawaited(
            _resumeDocument().catchError((Object error) {
              debugPrint('Runtime Windows WebView 启动消息投递失败: $error');
            }),
          );
        }
      });
      _windowsMessages = controller.webMessage.listen((message) {
        if (message is! String) return;
        try {
          final decoded = jsonDecode(message);
          if (decoded is Map &&
              decoded['command'] is String &&
              (decoded['command']! as String).startsWith('app.')) {
            final generation = _messageQueue.generation;
            unawaited(_handleAppBridgeMessage(message, generation));
          } else {
            unawaited(widget.gameBridge.handle(message));
          }
        } on FormatException {
          // 忽略不是 Bridge JSON 的 WebView 消息。
        }
      });
      _outbound = widget.gameBridge.outboundMessages.listen(
        (message) => unawaited(_sendGameMessage(message)),
      );
      await controller.loadUrl(widget.entryUri.toString());
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _resumeDocument() async {
    await _sendPlatformUiConfiguration();
    await _messageQueue.resume();
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    if (!request.isMainFrame) return NavigationDecision.navigate;
    switch (classifyRuntimeNavigation(request.url)) {
      case RuntimeNavigationDisposition.navigate:
        return NavigationDecision.navigate;
      case RuntimeNavigationDisposition.prevent:
        return NavigationDecision.prevent;
      case RuntimeNavigationDisposition.openExternal:
        final uri = parseRuntimeExternalUri(request.url);
        if (uri != null) unawaited(_openExternalNavigation(uri));
        return NavigationDecision.prevent;
    }
  }

  Future<void> _openExternalNavigation(Uri uri) async {
    if (!await openRuntimeExternalUri(uri)) {
      debugPrint('Runtime 系统未能处理游戏外部链接: $uri');
    }
  }

  Future<void> _sendPlatformUiConfiguration() => _messageQueue.add(
    'window[Symbol.for("playmesh.app.internal.v1")]'
    '?.configurePlatformUi?.(${jsonEncode(widget.appBridge.platformUiConfiguration)});'
    'window[Symbol.for("playmesh.main.internal.v1")]?.receive('
    '${jsonEncode({'type': 'platform.ui.configure', 'configuration': widget.appBridge.platformUiConfiguration})}'
    ');',
  );

  /// Game SDK receives a JSON object, matching the main App bridge. App SDK's
  /// private receiver intentionally receives an encoded JSON string.
  Future<void> _sendGameMessage(String message) async {
    try {
      await _messageQueue.add(
        'window[Symbol.for("playmesh.main.internal.v1")]?.receive($message);',
      );
    } on Object catch (error) {
      debugPrint('Runtime 向 Game SDK 投递消息失败: $error');
    }
  }

  Future<void> _sendAppMessage(
    String message,
    int generation,
  ) => _messageQueue.addAndWait(
    'window[Symbol.for("playmesh.app.internal.v1")]?.receive(${jsonEncode(message)});',
    generation: generation,
  );

  Future<void> _handleAppBridgeMessage(String message, int generation) async {
    // A JavaScript confirm/alert is rendered by the WebView itself, outside
    // Flutter's pointer tree. Its confirmation click therefore refreshes the
    // browser's trusted user activation but never reaches the Listener around
    // WebViewWidget. Mirror that browser-owned activation immediately before
    // the native bridge validates navigation-sensitive commands.
    try {
      final active = await _evaluateJavaScript(
        'Boolean(globalThis.navigator?.userActivation?.isActive)',
      );
      if (active == true || active.toString() == 'true') {
        widget.appBridge.recordUserActivation();
      }
    } on Object catch (error) {
      debugPrint('Runtime 读取 WebView 用户操作状态失败: $error');
    }
    await widget.appBridge.handle(
      message,
      (reply) => _sendAppMessage(reply, generation),
    );
  }

  Future<void> _executeImmediately(String script) async {
    if (_android case final controller?) {
      await controller.runJavaScript(script);
    } else if (_windows case final controller?) {
      await controller.executeScript(script);
    } else {
      throw StateError('Runtime WebView 尚未创建');
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_recordHardwareUserActivation);
    widget.inputTakenOver.removeListener(_handleInputOwnershipChanged);
    _androidWebViewFocusRetryTimer?.cancel();
    _nativeInputFallbackFocusNode.dispose();
    _androidWebViewFocusScopeNode.dispose();
    unawaited(_outbound?.cancel());
    unawaited(_windowsMessages?.cancel());
    unawaited(_windowsLoadingState?.cancel());
    unawaited(_windowsExternalNavigation?.cancel());
    unawaited(_navigationRequests?.cancel());
    unawaited(_windows?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(child: SelectableText('游戏 WebView 启动失败\n$error'));
    }
    Widget content;
    if (Platform.isWindows) {
      final controller = _windows;
      content = controller == null
          ? const PlaymeshLoadingView()
          : Webview(
              controller,
              permissionRequested: (_, kind, isUserInitiated) async {
                try {
                  final allowed = await widget.appBridge
                      .authorizeWebPermissions(
                        [kind.name],
                        sourceUri: widget.entryUri,
                        isUserInitiated: isUserInitiated,
                      );
                  return allowed
                      ? WebviewPermissionDecision.allow
                      : WebviewPermissionDecision.deny;
                } on Object catch (error) {
                  debugPrint('Runtime Windows WebView 权限请求失败: $error');
                  return WebviewPermissionDecision.deny;
                }
              },
            );
    } else {
      final controller = _android;
      content = controller == null
          ? const PlaymeshLoadingView()
          : FocusScope(
              node: _androidWebViewFocusScopeNode,
              child: WebViewWidget(controller: controller),
            );
    }
    content = Focus(
      focusNode: _nativeInputFallbackFocusNode,
      autofocus: !widget.inputTakenOver.value,
      canRequestFocus: !widget.inputTakenOver.value,
      onKeyEvent: _handleNativeFallbackKey,
      child: AbsorbPointer(
        absorbing: !widget.inputTakenOver.value,
        child: content,
      ),
    );
    if (!widget.inputTakenOver.value) {
      content = Stack(
        fit: StackFit.expand,
        children: [content, const PlaymeshLoadingView()],
      );
    }
    content = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.appBridge.recordUserActivation(),
      child: content,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleNativeSystemBack();
      },
      child: content,
    );
  }
}
