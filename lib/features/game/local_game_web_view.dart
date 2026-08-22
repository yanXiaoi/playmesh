import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:playmesh_ui/playmesh_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'game_webview_exit.dart';
import 'windows_local_game_web_view.dart';
import '../../core/developer/developer_run_controller.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_sdk/webview_message_queue.dart';
import '../../core/game_package/game_asset_gateway.dart';
import '../../core/game_web/android_webview_file_selector.dart';
import '../../core/game_web/game_web_external_navigation.dart';
import '../../core/localization/platform_game_ui_assets.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/platform/app_platform.dart';
import '../../core/storage/app_local_bucket_store.dart';
import '../../models/user_profile.dart';

class LocalGameWebView extends StatefulWidget {
  const LocalGameWebView({
    super.key,
    required this.resourceSource,
    required this.entryPath,
    required this.title,
    required this.gameId,
    this.gameSdkVersion,
    this.appSdkVersion,
    this.bridge,
    this.localUserId = 'u_local',
    this.localNickname = playmeshDefaultLocalNickname,
    this.declaredCapabilities = const [],
    this.appLanHost,
    this.onOpenSharePanel,
    this.onExitRequested,
    this.onNicknameUpdate,
    this.onSystemBackHandlerChanged,
    this.onJavaScriptExecutorChanged,
  });

  final GameWebResourceSource resourceSource;
  final String entryPath;
  final String title;
  final String gameId;
  final String? gameSdkVersion;
  final String? appSdkVersion;
  final GameSdkBridge? bridge;
  final String localUserId;
  final String localNickname;
  final List<String> declaredCapabilities;
  final AppLanHost? appLanHost;
  final Future<void> Function()? onOpenSharePanel;
  final Future<void> Function()? onExitRequested;
  final Future<Object?> Function(Map<String, Object?> payload)?
  onNicknameUpdate;
  final ValueChanged<VoidCallback?>? onSystemBackHandlerChanged;
  final ValueChanged<DeveloperWebViewJavaScriptExecutor?>?
  onJavaScriptExecutorChanged;

  @override
  State<LocalGameWebView> createState() => _LocalGameWebViewState();
}

class _LocalGameWebViewState extends State<LocalGameWebView> {
  WebViewController? _controller;
  bool _loadFailed = false;
  StreamSubscription<String>? _bridgeSubscription;
  GameAssetGateway? _assetGateway;
  Uri? _entryUri;
  late final AppWebViewBridge _appBridge;
  final AndroidWebViewFileSelector _androidFileSelector =
      const AndroidWebViewFileSelector();
  late final WebViewMessageQueue _messageQueue;
  String? _platformUiConfigurationKey;
  Map<String, Object?>? _platformUiConfiguration;
  Future<void> Function(String)? _runWindowsJavaScript;
  final FocusNode _nativeInputFallbackFocusNode = FocusNode(
    debugLabel: 'game-native-input-fallback',
  );
  final FocusScopeNode _androidWebViewFocusScopeNode = FocusScopeNode(
    debugLabel: 'game-android-webview',
  );
  bool _appSdkInputTakenOver = false;
  bool _androidNavigationCompleted = false;
  bool _androidWebViewFocusScheduled = false;
  bool _androidWebViewFocusGranted = false;
  int _androidWebViewFocusAttempts = 0;
  Timer? _androidWebViewFocusRetryTimer;
  Future<void>? _nativeExitOperation;
  int _initializationGeneration = 0;

  bool get _canUsePlatformWebView {
    return supportsPlatformWebView;
  }

  @override
  void initState() {
    super.initState();
    _appBridge = AppWebViewBridge(
      userId: widget.localUserId,
      nickname: widget.localNickname,
      declaredCapabilities: widget.declaredCapabilities,
      lanHost: widget.appLanHost,
      onOpenSharePanel: widget.onOpenSharePanel,
      onInputTakeover: _takeOverAppSdkInput,
      onExitRequested: _exitFromAppGameMenu,
      onNicknameUpdate: widget.onNicknameUpdate,
      localBucketStore: AppLocalBucketStore(
        gameId: widget.gameId,
        gameName: widget.title,
      ),
    );
    HardwareKeyboard.instance.addHandler(_recordHardwareUserActivation);
    widget.onSystemBackHandlerChanged?.call(_handleNativeSystemBack);
    _messageQueue = WebViewMessageQueue(_runJavaScript);
    final supportsGateway =
        !kIsWeb &&
        (_canUsePlatformWebView ||
            defaultTargetPlatform == TargetPlatform.windows);
    if (!supportsGateway) {
      return;
    }
    final generation = ++_initializationGeneration;
    unawaited(_initialize(generation));
  }

  @override
  void didUpdateWidget(covariant LocalGameWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(
      oldWidget.onSystemBackHandlerChanged,
      widget.onSystemBackHandlerChanged,
    )) {
      return;
    }
    oldWidget.onSystemBackHandlerChanged?.call(null);
    widget.onSystemBackHandlerChanged?.call(_handleNativeSystemBack);
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
    _appBridge.setPlatformUiConfiguration(_platformUiConfiguration);
    unawaited(_sendPlatformUiConfiguration());
  }

  Future<void> _initialize(int generation) async {
    try {
      final storage = await widget.bridge?.ensureStorage();
      if (!mounted || generation != _initializationGeneration) return;
      final gateway = await startGameAssetGateway(
        source: widget.resourceSource,
        entryPath: widget.entryPath,
        gameSdkVersion: widget.gameSdkVersion,
        appSdkVersion: widget.appSdkVersion,
        storage: storage,
      );
      if (!mounted || generation != _initializationGeneration) {
        await gateway.close();
        return;
      }
      _assetGateway = gateway;
      _entryUri = gateway.entryUri;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        if (mounted) setState(() {});
        return;
      }
      final controller =
          WebViewController(
              onPermissionRequest: (request) {
                unawaited(_handleWebPermissionRequest(request));
              },
            )
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setOnConsoleMessage((message) {
              recordLocalWebViewConsole(
                level: message.level.name,
                message: message.message,
              );
            })
            ..addJavaScriptChannel(
              'PlaymeshBridge',
              onMessageReceived: (message) {
                unawaited(
                  widget.bridge?.handleJavaScriptMessage(message.message),
                );
              },
            )
            ..addJavaScriptChannel(
              'PlaymeshAppBridge',
              onMessageReceived: (message) {
                final generation = _messageQueue.generation;
                unawaited(
                  _appBridge.handleJavaScriptMessage(
                    message.message,
                    (reply) => _sendAppMessage(reply, generation),
                  ),
                );
              },
            )
            ..addJavaScriptChannel(
              playmeshGameExternalNavigationChannel,
              onMessageReceived: (message) {
                final uri = parseGameWebViewExternalNavigationMessage(
                  message.message,
                );
                if (uri != null) unawaited(_openExternalNavigation(uri));
              },
            )
            ..setNavigationDelegate(
              NavigationDelegate(
                onNavigationRequest: _handleNavigationRequest,
                onWebResourceError: (error) {
                  recordLocalWebViewConsole(
                    level: 'error',
                    message:
                        'Resource load failed: ${error.url ?? error.description}',
                    href: error.url,
                    eventType: 'resource.error',
                  );
                },
                onPageStarted: (_) {
                  _androidNavigationCompleted = false;
                  _resetAppSdkDocument();
                  widget.onJavaScriptExecutorChanged?.call(null);
                  _messageQueue.pause(clearPending: true);
                  unawaited(
                    _runJavaScript(playmeshGameWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('安装 Android 游戏外部导航兼容脚本失败: $error');
                    }),
                  );
                },
                onPageFinished: (_) {
                  _androidNavigationCompleted = true;
                  unawaited(
                    _runJavaScript(playmeshGameWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('确认 Android 游戏外部导航兼容脚本失败: $error');
                    }),
                  );
                  widget.onJavaScriptExecutorChanged?.call(_evaluateJavaScript);
                  unawaited(
                    _messageQueue.resume().catchError((Object error) {
                      debugPrint('发送启动阶段 WebView Bridge 消息失败: $error');
                    }),
                  );
                  _scheduleAndroidWebViewFocus();
                },
              ),
            );
      if (controller.platform case final AndroidWebViewController android) {
        await android.setOnShowFileSelector(_androidFileSelector.select);
        if (!mounted || generation != _initializationGeneration) {
          if (identical(_assetGateway, gateway)) {
            _assetGateway = null;
          }
          await gateway.close();
          return;
        }
      }
      _controller = controller;
      _bridgeSubscription = widget.bridge?.outboundMessages.listen(
        (message) => unawaited(_sendToWebView(message)),
      );
      await _controller!.loadRequest(gateway.entryUri);
      if (mounted) {
        setState(() {});
        _scheduleAndroidWebViewFocus();
      }
    } on Object catch (error) {
      debugPrint('启动游戏资源网关失败: $error');
      recordLocalWebViewConsole(
        level: 'error',
        message: 'WebView startup failed: $error',
        eventType: 'webview.startup.error',
      );
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _sendAppMessage(String message, int generation) async {
    await _messageQueue.addAndWait(
      appSdkReceiveScript(message),
      generation: generation,
    );
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    if (!request.isMainFrame) return NavigationDecision.navigate;
    switch (classifyGameWebViewNavigation(request.url)) {
      case GameWebViewNavigationDisposition.navigate:
        return NavigationDecision.navigate;
      case GameWebViewNavigationDisposition.prevent:
        return NavigationDecision.prevent;
      case GameWebViewNavigationDisposition.openExternal:
        final uri = parseGameWebViewExternalUri(request.url);
        if (uri != null) unawaited(_openExternalNavigation(uri));
        return NavigationDecision.prevent;
    }
  }

  Future<void> _openExternalNavigation(Uri uri) async {
    if (!await openGameWebViewExternalUri(uri)) {
      debugPrint('系统未能处理游戏外部链接: $uri');
    }
  }

  void _takeOverAppSdkInput() {
    if (!mounted || _appSdkInputTakenOver) return;
    setState(() => _appSdkInputTakenOver = true);
    _nativeInputFallbackFocusNode.unfocus();
    _resetAndroidWebViewFocus();
    _scheduleAndroidWebViewFocus();
  }

  bool _recordHardwareUserActivation(KeyEvent event) {
    if (event is KeyDownEvent) _appBridge.recordUserActivation();
    return false;
  }

  void _resetAppSdkInputOwnership() {
    if (!mounted) return;
    _resetAndroidWebViewFocus();
    if (_appSdkInputTakenOver) {
      setState(() => _appSdkInputTakenOver = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _appSdkInputTakenOver ||
          !_nativeInputFallbackFocusNode.canRequestFocus) {
        return;
      }
      _nativeInputFallbackFocusNode.requestFocus();
    });
  }

  void _resetAppSdkDocument() {
    _resetAppSdkInputOwnership();
    unawaited(_appBridge.resetCapabilities());
  }

  KeyEventResult _handleNativeFallbackKey(FocusNode _, KeyEvent event) {
    if (_appSdkInputTakenOver || event is! KeyDownEvent) {
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
    final callback = widget.onExitRequested;
    if (callback == null) return;
    _nativeExitOperation ??= callback().whenComplete(() {
      _nativeExitOperation = null;
    });
  }

  Future<void> _exitFromAppGameMenu() async {
    final callback = widget.onExitRequested;
    if (callback == null) return;
    final controller = _controller;
    await exitGameMenuWithBlankPage(
      exit: callback,
      loadRequest: controller?.loadRequest,
      runJavaScript: _runWindowsJavaScript,
    );
  }

  void _handleNativeSystemBack() {
    if (!_appSdkInputTakenOver) {
      _exitBeforeAppSdkTakeover();
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_forwardAndroidBackToAppSdk());
    }
  }

  void _scheduleAndroidWebViewFocus() {
    if (!mounted ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_appSdkInputTakenOver ||
        !_androidNavigationCompleted ||
        _controller == null ||
        _androidWebViewFocusScheduled ||
        _androidWebViewFocusGranted) {
      return;
    }
    _androidWebViewFocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _androidWebViewFocusScheduled = false;
      if (!mounted || !_appSdkInputTakenOver || !_androidNavigationCompleted) {
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
      await _runJavaScript('window.focus();');
      final result = await _evaluateJavaScript('document.hasFocus()');
      final documentFocused =
          result == true || result.toString().toLowerCase() == 'true';
      if (mounted &&
          platformViewFocus.hasFocus &&
          documentFocused &&
          _appSdkInputTakenOver &&
          _androidNavigationCompleted) {
        _androidWebViewFocusGranted = true;
        _androidWebViewFocusAttempts = 0;
        _androidWebViewFocusRetryTimer?.cancel();
        _androidWebViewFocusRetryTimer = null;
        return;
      }
    } on Object catch (error) {
      debugPrint('Android 游戏 WebView 焦点确认失败: $error');
    }
    _scheduleAndroidWebViewFocusRetry();
  }

  void _scheduleAndroidWebViewFocusRetry() {
    if (!mounted ||
        _androidWebViewFocusGranted ||
        _androidWebViewFocusAttempts >= 6 ||
        !_appSdkInputTakenOver ||
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

  Future<void> _forwardAndroidBackToAppSdk() async {
    try {
      final handled = await _evaluateJavaScript(appSdkHandleNativeBackScript());
      if (handled == true || handled.toString() == 'true') return;
    } on Object catch (error) {
      debugPrint('Android 系统返回未能交给 App SDK: $error');
    }
    _exitBeforeAppSdkTakeover();
  }

  Future<void> _handleWebPermissionRequest(
    WebViewPermissionRequest request,
  ) async {
    try {
      final allowed = await _appBridge.authorizeWebPermissions(
        request.types.map((type) => type.name),
        sourceUri: _entryUri,
      );
      if (allowed) {
        await request.grant();
      } else {
        await request.deny();
      }
    } on Object catch (error) {
      debugPrint('处理游戏 WebView 权限请求失败: $error');
      await request.deny();
    }
  }

  Future<void> _sendToWebView(String message) async {
    try {
      await _messageQueue.add(gameSdkReceiveScript(message));
    } on Object catch (error) {
      debugPrint('向游戏 WebView 发送 SDK 消息失败: $error');
    }
  }

  Future<void> _sendPlatformUiConfiguration() async {
    final configuration = _platformUiConfiguration;
    if (configuration == null) return;
    final script = gameSdkReceiveScript(
      jsonEncode({
        'type': 'platform.ui.configure',
        'configuration': configuration,
      }),
    );
    final appScript = appSdkConfigurePlatformUiScript(configuration);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _runWindowsJavaScript?.call('$appScript$script');
      return;
    }
    await _messageQueue.add('$appScript$script');
  }

  Future<void> _runJavaScript(String script) async {
    final controller = _controller;
    if (controller == null) throw StateError('游戏 WebView 尚未创建');
    await controller.runJavaScript(script);
  }

  Future<Object?> _evaluateJavaScript(String source) async {
    final controller = _controller;
    if (controller == null) throw StateError('游戏 WebView 尚未创建');
    return controller.runJavaScriptReturningResult(source);
  }

  @override
  void dispose() {
    _initializationGeneration += 1;
    widget.onSystemBackHandlerChanged?.call(null);
    widget.onJavaScriptExecutorChanged?.call(null);
    _runWindowsJavaScript = null;
    HardwareKeyboard.instance.removeHandler(_recordHardwareUserActivation);
    _androidWebViewFocusRetryTimer?.cancel();
    _nativeInputFallbackFocusNode.dispose();
    _androidWebViewFocusScopeNode.dispose();
    unawaited(_appBridge.close());
    unawaited(_bridgeSubscription?.cancel());
    final assetGateway = _assetGateway;
    _assetGateway = null;
    unawaited(assetGateway?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final useWindowsWebView =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final entryUri = _entryUri;

    Widget content = useWindowsWebView
        ? entryUri == null || _loadFailed
              ? _WebViewFallback(
                  assetPath: widget.entryPath,
                  title: widget.title,
                )
              : WindowsLocalGameWebView(
                  assetPath: widget.entryPath,
                  entryUri: entryUri,
                  title: widget.title,
                  bridge: widget.bridge,
                  appBridge: _appBridge,
                  appSdkInputTakenOver: _appSdkInputTakenOver,
                  gameExternalNavigationEnabled: true,
                  onNavigationStarted: _resetAppSdkDocument,
                  onRunJavaScriptReady: (executor) {
                    _runWindowsJavaScript = executor;
                    unawaited(_sendPlatformUiConfiguration());
                  },
                  onEvaluateJavaScriptReady: (executor) {
                    widget.onJavaScriptExecutorChanged?.call(executor);
                  },
                )
        : controller == null || _loadFailed
        ? _WebViewFallback(assetPath: widget.entryPath, title: widget.title)
        : FocusScope(
            node: _androidWebViewFocusScopeNode,
            child: WebViewWidget(controller: controller),
          );
    content = Focus(
      focusNode: _nativeInputFallbackFocusNode,
      autofocus: !_appSdkInputTakenOver,
      canRequestFocus: !_appSdkInputTakenOver,
      onKeyEvent: _handleNativeFallbackKey,
      child: AbsorbPointer(absorbing: !_appSdkInputTakenOver, child: content),
    );
    content = Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (!_appSdkInputTakenOver) const PlaymeshLoadingView(),
      ],
    );
    content = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _appBridge.recordUserActivation(),
      child: content,
    );
    if (widget.onSystemBackHandlerChanged != null) return content;
    return PopScope(
      canPop: !_appSdkInputTakenOver,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleNativeSystemBack();
      },
      child: content,
    );
  }
}

class _WebViewFallback extends StatelessWidget {
  const _WebViewFallback({required this.assetPath, required this.title});

  final String assetPath;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff102522),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.web_asset_outlined, color: Colors.white, size: 42),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              assetPath,
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
