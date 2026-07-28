import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'windows_local_game_web_view.dart';

class RemoteGamePage extends StatefulWidget {
  const RemoteGamePage({
    super.key,
    required this.entryUri,
    required this.userId,
    required this.nickname,
    this.nativeBackHandler,
    this.prepareRuntime = true,
  });

  final Uri entryUri;
  final String userId;
  final String nickname;
  @visibleForTesting
  final Future<bool> Function()? nativeBackHandler;
  @visibleForTesting
  final bool prepareRuntime;

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
  final int _windowsReloadKey = 0;
  late final WebViewMessageQueue _messageQueue;
  Future<void> Function(String)? _runWindowsJavaScript;
  Future<Object?> Function(String)? _evaluateWindowsJavaScript;
  String? _platformUiConfigurationKey;
  Map<String, Object?>? _platformUiConfiguration;
  bool _showPerformance = false;
  bool _allowPop = false;
  Future<void>? _nativeBackOperation;

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
    if (widget.prepareRuntime) unawaited(_prepare());
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
        acceptRuntimeGameDeclaration: true,
        coreBaseUri: coreGateway.localBaseUri,
        playerSource: usesRelay ? 'server' : 'lan_app',
        platformUiConfiguration: _platformUiConfiguration,
        onOpenSharePanel: _rejectShareFromRemote,
        showShareAction: false,
        onExitRequested: _exitRemotePage,
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
    final appScript =
        'window.playmeshApp?.__configurePlatformUi?.('
        '${jsonEncode(configuration)});';
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _runWindowsJavaScript?.call('$appScript$script');
      return;
    }
    if (_controller != null) await _messageQueue.add('$appScript$script');
  }

  @override
  void dispose() {
    _evaluateWindowsJavaScript = null;
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
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleNativeBack());
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleNativeBackKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(fit: StackFit.expand, children: [_buildWebView()]),
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
        onEvaluateJavaScriptReady: (evaluateJavaScript) {
          _evaluateWindowsJavaScript = evaluateJavaScript;
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

  void _resetTransientUiForLoad() {
    if (!mounted) return;
    setState(() {
      _showPerformance = false;
    });
    unawaited(_syncPerformanceVisible());
  }

  KeyEventResult _handleNativeBackKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape &&
        key != LogicalKeyboardKey.browserBack &&
        key != LogicalKeyboardKey.goBack &&
        key != LogicalKeyboardKey.gameButtonB) {
      return KeyEventResult.ignored;
    }
    unawaited(_handleNativeBack());
    return KeyEventResult.handled;
  }

  Future<void> _handleNativeBack() {
    return _nativeBackOperation ??= _performNativeBack().whenComplete(() {
      _nativeBackOperation = null;
    });
  }

  Future<void> _performNativeBack() async {
    if (_allowPop || !mounted) return;
    try {
      final injectedHandler = widget.nativeBackHandler;
      if (injectedHandler != null && await injectedHandler()) return;

      const script = 'Boolean(window.playmeshApp?.__handleNativeBack?.())';
      final Object? handled;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        final evaluate = _evaluateWindowsJavaScript;
        handled = evaluate == null ? null : await evaluate(script);
      } else {
        final controller = _controller;
        handled = controller == null
            ? null
            : await controller.runJavaScriptReturningResult(script);
      }
      if (handled == true || handled.toString() == 'true') return;
    } on Object catch (error) {
      debugPrint('游戏加入端系统返回未能交给 App SDK: $error');
    }
    await _exitRemotePage();
  }

  Future<void> _exitRemotePage() async {
    if (_allowPop || !mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _rejectShareFromRemote() {
    throw const SdkCommandException(
      'not_authority',
      '只有当前 Authority 游戏可以打开分享界面',
    );
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
