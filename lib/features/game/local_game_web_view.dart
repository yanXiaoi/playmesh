import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'windows_local_game_web_view.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/game_sdk/webview_message_queue.dart';
import '../../core/game_package/game_asset_gateway.dart';

class LocalGameWebView extends StatefulWidget {
  const LocalGameWebView({
    super.key,
    required this.assetPath,
    this.gameRootAssetPath,
    this.gameRootFilePath,
    required this.title,
    this.bridge,
    this.localUserId = 'u_local',
    this.localNickname = '本机玩家',
    this.declaredCapabilities = const [],
    this.onExitRequested,
  });

  final String assetPath;
  final String? gameRootAssetPath;
  final String? gameRootFilePath;
  final String title;
  final GameSdkBridge? bridge;
  final String localUserId;
  final String localNickname;
  final List<String> declaredCapabilities;
  final Future<void> Function()? onExitRequested;

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
  late final WebViewMessageQueue _messageQueue;

  bool get _canUsePlatformWebView {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
  }

  @override
  void initState() {
    super.initState();
    _appBridge = AppWebViewBridge(
      userId: widget.localUserId,
      nickname: widget.localNickname,
      gameName: widget.title,
      declaredCapabilities: widget.declaredCapabilities,
      onExitRequested: widget.onExitRequested,
    );
    _messageQueue = WebViewMessageQueue(_runJavaScript);
    final supportsGateway =
        !kIsWeb &&
        (_canUsePlatformWebView ||
            defaultTargetPlatform == TargetPlatform.windows);
    if (!supportsGateway) {
      return;
    }
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final gateway = await startGameAssetGateway(
        gameRootAssetPath: widget.gameRootAssetPath,
        gameRootFilePath: widget.gameRootFilePath,
        entryAssetPath: widget.assetPath,
      );
      _assetGateway = gateway;
      _entryUri = gateway.entryUri;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        if (mounted) setState(() {});
        return;
      }
      _controller = WebViewController()
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
            unawaited(widget.bridge?.handleJavaScriptMessage(message.message));
          },
        )
        ..addJavaScriptChannel(
          'PlaymeshAppBridge',
          onMessageReceived: (message) {
            unawaited(
              _appBridge.handleJavaScriptMessage(
                message.message,
                _sendAppMessage,
              ),
            );
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
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
              _messageQueue.pause(clearPending: true);
              unawaited(_appBridge.resetDeviceSubscriptions());
            },
            onPageFinished: (_) {
              unawaited(
                _messageQueue.resume().catchError((Object error) {
                  debugPrint('发送启动阶段 WebView Bridge 消息失败: $error');
                }),
              );
            },
          ),
        );
      _bridgeSubscription = widget.bridge?.outboundMessages.listen(
        (message) => unawaited(_sendToWebView(message)),
      );
      await _controller!.loadRequest(gateway.entryUri);
      if (mounted) setState(() {});
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

  Future<void> _sendAppMessage(String message) async {
    await _messageQueue.add(
      'window.playmeshApp && window.playmeshApp.__receive(${jsonEncode(message)});',
    );
  }

  Future<void> _sendToWebView(String message) async {
    try {
      await _messageQueue.add(gameSdkReceiveScript(message));
    } on Object catch (error) {
      debugPrint('向游戏 WebView 发送 SDK 消息失败: $error');
    }
  }

  Future<void> _runJavaScript(String script) async {
    final controller = _controller;
    if (controller == null) throw StateError('游戏 WebView 尚未创建');
    await controller.runJavaScript(script);
  }

  @override
  void dispose() {
    unawaited(_appBridge.close());
    unawaited(_bridgeSubscription?.cancel());
    unawaited(_assetGateway?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final useWindowsWebView =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final entryUri = _entryUri;

    return useWindowsWebView
        ? entryUri == null || _loadFailed
              ? _WebViewFallback(
                  assetPath: widget.assetPath,
                  title: widget.title,
                )
              : WindowsLocalGameWebView(
                  assetPath: widget.assetPath,
                  entryUri: entryUri,
                  title: widget.title,
                  bridge: widget.bridge,
                  appBridge: _appBridge,
                )
        : controller == null || _loadFailed
        ? _WebViewFallback(assetPath: widget.assetPath, title: widget.title)
        : WebViewWidget(controller: controller);
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
