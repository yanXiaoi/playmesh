import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/capabilities/web_permission/capability_web_permission.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/game_sdk/webview_message_queue.dart';
import '../../core/game_web/android_webview_file_selector.dart';
import '../../core/game_web/game_web_external_navigation.dart';
import '../../core/game_web/game_web_gateway_contract.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/game_web/game_share_link_snapshot.dart';
import '../../core/game_web/local_tunnel_gateway.dart';
import '../../core/localization/platform_game_ui_assets.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/relay/relay_tunnel.dart';
import '../../core/developer/webview_console_capture.dart';
import '../../core/platform/app_device_service.dart';
import '../../core/platform/app_platform.dart';
import '../../core/network/lan_game_discovery_service.dart';
import '../../core/profile/user_profile_store.dart';
import '../../models/user_profile.dart';
import 'game_app_lan_host.dart';
import 'game_invitation_scanner_page.dart';
import 'game_join_router.dart';
import 'game_webview_exit.dart';
import 'windows_local_game_web_view.dart';

class RemoteGamePage extends StatefulWidget {
  const RemoteGamePage({
    super.key,
    required this.entryUri,
    required this.userId,
    required this.nickname,
    this.nativeBackHandler,
    this.prepareRuntime = true,
    this.gameId,
    this.gameName,
    this.sourceInstanceId,
    this.discoveryService,
    this.onNicknameChanged,
  });

  static const routeName = '/remote-game';

  final Uri entryUri;
  final String userId;
  final String nickname;
  final String? gameId;
  final String? gameName;
  final String? sourceInstanceId;
  final LanGameDiscoveryService? discoveryService;
  final Future<void> Function(String nickname)? onNicknameChanged;
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
  Uri? _localEntryUri;
  Object? _error;
  final int _windowsReloadKey = 0;
  late final WebViewMessageQueue _messageQueue;
  final AndroidWebViewFileSelector _androidFileSelector =
      const AndroidWebViewFileSelector();
  GameAppLanHostAdapter? _appLanHost;
  LanGameDiscoveryService? _lanGameDiscoveryService;
  bool _ownsLanGameDiscoveryService = false;
  Future<void> Function(String)? _runWindowsJavaScript;
  Future<Object?> Function(String)? _evaluateWindowsJavaScript;
  String? _platformUiConfigurationKey;
  Map<String, Object?>? _platformUiConfiguration;
  bool _allowPop = false;
  Future<void>? _nativeBackOperation;
  late String _currentNickname;

  Uri get _launchUri => _localEntryUri ?? widget.entryUri;

  bool get _usesFlutterWebView => supportsPlatformWebView;

  @override
  void initState() {
    super.initState();
    _currentNickname = widget.nickname;
    final gameId = widget.gameId;
    if (gameId != null) {
      final discoveryService =
          widget.discoveryService ?? LanGameDiscoveryService();
      _lanGameDiscoveryService = discoveryService;
      _ownsLanGameDiscoveryService = widget.discoveryService == null;
      _appLanHost = GameAppLanHostAdapter(
        gameId: () => gameId,
        discoveryService: discoveryService,
        isActive: () => mounted,
        isAuthority: () => false,
        selfInstanceId: () => widget.sourceInstanceId,
        isSelfInvitation: (invitation) =>
            invitation.entryUri == widget.entryUri,
        scanQr: _scanQrFromAppSdk,
        replaceGame: _replaceFromAppSdk,
        publish: _rejectLanAuthorityOperation,
        readShareLinks: _rejectLanShareLinks,
      );
    }
    developerEventHub.beginRuntime();
    _messageQueue = WebViewMessageQueue(_runJavaScript);
    HardwareKeyboard.instance.addHandler(_recordHardwareUserActivation);
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
    try {
      final entryUri = widget.entryUri;
      final usesRelay = _isRelayInvitation(entryUri);
      if (entryUri.host.isEmpty ||
          (usesRelay
              ? !{'http', 'https'}.contains(entryUri.scheme)
              : entryUri.scheme != 'http')) {
        throw const FormatException('App 游戏入口地址无效');
      }
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
        final invitationFragment = _invitationFragment(entryUri);
        final shareToken =
            invitationFragment[playmeshGameInvitationTokenParameter];
        if (invitationFragment.length != 1 ||
            shareToken == null ||
            shareToken.isEmpty) {
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
        await coreGateway.close();
        await webGateway.close();
        return;
      }
      _webGateway = webGateway;
      _coreGateway = coreGateway;
      _localEntryUri = usesRelay
          ? (webGateway as RelayClientGateway).localEntryUri
          : webGateway.localBaseUri.replace(
              path: entryUri.path,
              fragment: entryUri.fragment,
            );
      _appBridge = AppWebViewBridge(
        userId: widget.userId,
        nickname: _currentNickname,
        webPermissionRole: AppWebPermissionRole.joiner,
        acceptRuntimeGameDeclaration: true,
        coreBaseUri: coreGateway.localBaseUri,
        playerSource: usesRelay ? 'server' : 'lan_app',
        platformUiConfiguration: _platformUiConfiguration,
        onOpenSharePanel: _rejectShareFromRemote,
        showShareAction: false,
        lanHost: _appLanHost,
        onExitRequested: _exitFromAppGameMenu,
        onNicknameChanged: _persistNickname,
      );
      if (_usesFlutterWebView) {
        await _initialize();
      } else if (mounted) {
        setState(() {});
      }
    } on Object catch (error) {
      await coreGateway?.close();
      await webGateway?.close();
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _initialize() async {
    try {
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
              'PlaymeshAppBridge',
              onMessageReceived: (message) {
                final generation = _messageQueue.generation;
                unawaited(
                  _appBridge!.handleJavaScriptMessage(
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
                onPageStarted: (_) {
                  _handleNavigationStarted();
                  unawaited(
                    _runJavaScript(playmeshGameWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('安装远程 Android 游戏外部导航脚本失败: $error');
                    }),
                  );
                },
                onPageFinished: (_) {
                  unawaited(
                    _runJavaScript(playmeshGameWindowOpenScript).catchError((
                      Object error,
                    ) {
                      debugPrint('确认远程 Android 游戏外部导航脚本失败: $error');
                    }),
                  );
                  unawaited(
                    _messageQueue
                        .resume()
                        .then((_) async {
                          await _syncPlatformUiConfiguration();
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
      if (controller.platform case final AndroidWebViewController android) {
        await android.setOnShowFileSelector(_androidFileSelector.select);
      }
      _controller = controller;
      await controller.loadRequest(_launchUri);
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
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
      debugPrint('系统未能处理远程游戏外部链接: $uri');
    }
  }

  bool _recordHardwareUserActivation(KeyEvent event) {
    if (event is KeyDownEvent) _appBridge?.recordUserActivation();
    return false;
  }

  Future<void> _runJavaScript(String script) async {
    final controller = _controller;
    if (controller == null) throw StateError('远程游戏 WebView 尚未创建');
    await controller.runJavaScript(script);
  }

  Future<void> _handleWebPermissionRequest(
    WebViewPermissionRequest request,
  ) async {
    try {
      final allowed = await _appBridge!.authorizeWebPermissions(
        request.types.map((type) => type.name),
        sourceUri: _localEntryUri,
      );
      if (allowed) {
        await request.grant();
      } else {
        await request.deny();
      }
    } on Object catch (error) {
      debugPrint('处理加入端游戏 WebView 权限请求失败: $error');
      await request.deny();
    }
  }

  void _handleNavigationStarted() {
    _messageQueue.pause(clearPending: true);
    unawaited(_appBridge?.resetCapabilities());
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
    final appScript = appSdkConfigurePlatformUiScript(configuration);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _runWindowsJavaScript?.call('$appScript$script');
      return;
    }
    if (_controller != null) await _messageQueue.add('$appScript$script');
  }

  @override
  void dispose() {
    _evaluateWindowsJavaScript = null;
    HardwareKeyboard.instance.removeHandler(_recordHardwareUserActivation);
    unawaited(_closeAppLanResources());
    unawaited(_appBridge?.close());
    unawaited(_coreGateway?.close());
    unawaited(_webGateway?.close());
    unawaited(
      const AppDeviceService().setFullscreen(false).catchError((Object _) {}),
    );
    super.dispose();
  }

  Future<void> _closeAppLanResources() async {
    await _appLanHost?.close();
    if (_ownsLanGameDiscoveryService) {
      await _lanGameDiscoveryService?.dispose();
    }
  }

  Future<String?> _scanQrFromAppSdk() {
    final supported =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (!supported) {
      throw const SdkCommandException('scanner_unavailable', '当前平台扫码不可用');
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GameInvitationScannerPage()),
    );
  }

  Future<void> _replaceFromAppSdk(RemoteGameLaunch launch) async {
    if (!mounted) {
      throw const SdkCommandException('operation_cancelled', '游戏退出，操作已取消');
    }
    await const GameJoinRouter().replace(
      context,
      launch: launch,
      userId: widget.userId,
      nickname: _currentNickname,
      discoveryService: _ownsLanGameDiscoveryService
          ? null
          : _lanGameDiscoveryService,
      onNicknameChanged: widget.onNicknameChanged,
    );
  }

  Future<void> _persistNickname(String nickname) async {
    final callback = widget.onNicknameChanged;
    if (callback != null) {
      await callback(nickname);
    } else {
      final store = const UserProfileStore();
      final profile = await store.load(
        UserProfile(userId: widget.userId, nickname: _currentNickname),
      );
      if (profile.userId != widget.userId) {
        throw const SdkCommandException('identity_mismatch', '本机身份与当前玩家不一致');
      }
      await store.save(profile.copyWith(nickname: nickname));
    }
    _currentNickname = nickname;
  }

  Future<void> _rejectLanAuthorityOperation() async {
    throw const SdkCommandException('not_authority', '当前页面不是本机房主');
  }

  Future<GameShareLinkSnapshot> _rejectLanShareLinks() async {
    throw const SdkCommandException('not_authority', '当前页面不是本机房主');
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _appBridge?.recordUserActivation(),
      child: PopScope(
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
      ),
    );
  }

  Widget _buildWebView() {
    if (_error != null) {
      return ColoredBox(
        color: const Color(0xff241516),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.tr('game.remote_open_failed'),
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
        gameExternalNavigationEnabled: true,
        onNavigationStarted: _handleNavigationStarted,
        onRunJavaScriptReady: (runJavaScript) {
          _runWindowsJavaScript = runJavaScript;
          unawaited(_syncPlatformUiConfiguration());
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

      final script = appSdkHandleNativeBackScript();
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

  Future<void> _exitFromAppGameMenu() async {
    final controller = _controller;
    await exitGameMenuWithBlankPage(
      exit: _exitRemotePage,
      loadRequest: controller?.loadRequest,
      runJavaScript: _runWindowsJavaScript,
    );
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
    return parsePlaymeshInvitationFragment(
          value.fragment,
        )[playmeshGameInvitationTokenParameter]?.isNotEmpty ==
        true;
  } on FormatException {
    return false;
  }
}

Map<String, String> _invitationFragment(Uri value) {
  try {
    return parsePlaymeshInvitationFragment(value.fragment);
  } on FormatException {
    throw const FormatException('游戏邀请凭据编码无效');
  }
}
