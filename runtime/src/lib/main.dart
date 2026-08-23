import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:playmesh_share_ui/playmesh_share_ui.dart';
import 'package:playmesh_ui/playmesh_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'runtime/capabilities/default_capability_plugins.dart';
import 'runtime/runtime_app_bridge.dart';
import 'runtime/runtime_asset_server.dart';
import 'runtime/runtime_data_directory.dart';
import 'runtime/runtime_display_controller.dart';
import 'runtime/runtime_game_bridge.dart';
import 'runtime/runtime_game_view.dart';
import 'runtime/runtime_go_core.dart';
import 'runtime/runtime_identity.dart';
import 'runtime/runtime_lan_coordinator.dart';
import 'runtime/runtime_lan_host.dart';
import 'runtime/runtime_module_catalog.dart';
import 'runtime/runtime_navigation.dart';
import 'runtime/runtime_nickname_coordinator.dart';
import 'runtime/runtime_package.dart';
import 'runtime/runtime_platform_ui.dart';
import 'runtime/runtime_qr_scanner.dart';
import 'runtime/runtime_session.dart';
import 'runtime/runtime_share_panel_adapter.dart';
import 'runtime/runtime_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FullScreen.ensureInitialized();
  if (Platform.isWindows) await windowManager.ensureInitialized();
  runApp(const PlaymeshRuntimeApp());
}

final class PlaymeshRuntimeApp extends StatelessWidget {
  const PlaymeshRuntimeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const RuntimeBootstrapPage(),
  );
}

final class RuntimeBootstrapPage extends StatefulWidget {
  const RuntimeBootstrapPage({super.key});

  @override
  State<RuntimeBootstrapPage> createState() => _RuntimeBootstrapPageState();
}

final class _RuntimeBootstrapPageState extends State<RuntimeBootstrapPage> {
  RuntimeLaunch? _launch;
  Object? _error;
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final launch = await RuntimeLaunch.create(
        onProgress: (phase) {
          debugPrint('[Runtime Bootstrap] $phase');
        },
      );
      if (!mounted) {
        await launch.close();
        return;
      }
      setState(() => _launch = launch);
    } on Object catch (error, stackTrace) {
      debugPrint('Runtime 启动失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) setState(() => _error = error);
    } finally {
      _initializing = false;
    }
  }

  void _retry() {
    if (_initializing) return;
    setState(() {
      _error = null;
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_launch?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Playmesh Runtime 启动失败'),
                const SizedBox(height: 8),
                SelectableText('$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final launch = _launch;
    if (launch == null) {
      return const Scaffold(body: PlaymeshLoadingView());
    }
    return RuntimeGamePage(launch: launch);
  }
}

final class RuntimeLaunch {
  RuntimeLaunch._({
    required this.package,
    required this.goCore,
    required this.server,
    required this.bridge,
    required this.identity,
    required this.nicknameCoordinator,
    required this.modules,
    required this.platformUi,
  });

  static Future<RuntimeLaunch> create({
    void Function(String phase)? onProgress,
  }) async {
    onProgress?.call('正在读取内置游戏包…');
    final package = await RuntimeGamePackage.load();
    if (Platform.isWindows) {
      await windowManager.setTitle(package.manifest.name);
    }
    onProgress?.call('正在校验 Runtime 能力模块…');
    final modules = await RuntimeModuleCatalog.load();
    onProgress?.call('正在加载平台界面资源…');
    final platformUi = await RuntimePlatformUiCatalog.load();
    final missingCapabilities = {
      ...package.manifest.requiredCapabilities,
      ...package.manifest.controllerRequiredCapabilities,
    }.difference(modules.capabilityCodes);
    if (missingCapabilities.isNotEmpty) {
      throw StateError(
        'Runtime 缺少游戏要求的能力模块: ${missingCapabilities.join(', ')}',
      );
    }
    onProgress?.call('正在准备游戏数据目录…');
    final root = await resolveRuntimeDataDirectory(package.manifest.id);
    await root.create(recursive: true);
    final identity = await RuntimeIdentity.load(root);
    final goCore = RuntimeGoCore();
    RuntimeSession? session;
    RuntimeAssetServer? server;
    RuntimeGameBridge? bridge;
    RuntimeNicknameCoordinator? nicknameCoordinator;
    try {
      onProgress?.call('正在启动内置 Go Core…');
      await goCore.start();
      if (package.manifest.multiplayer) {
        onProgress?.call('正在创建本机会话…');
        session = await RuntimeSession.create(
          coreBase: goCore.baseUri,
          gameId: package.manifest.id,
          displayMode: package.manifest.displayMode,
          minPlayers: package.manifest.minPlayers,
          maxPlayers: package.manifest.maxPlayers,
          nickname: identity.nickname,
        );
        onProgress?.call('正在建立分享与加入通道…');
        await session.openShare();
      }
      final safeGameId = sha256
          .convert(utf8.encode(package.manifest.id))
          .toString();
      final storage = RuntimeStorage(
        gameId: package.manifest.id,
        file: File(
          '${root.path}${Platform.pathSeparator}storage'
          '${Platform.pathSeparator}$safeGameId.json',
        ),
      );
      nicknameCoordinator = RuntimeNicknameCoordinator(
        session: session,
        readNickname: () => identity.nickname,
        persistNickname: identity.updateNickname,
      );
      bridge = RuntimeGameBridge(
        game: package.manifest,
        session: session,
        storage: storage,
        onNicknameUpdate: nicknameCoordinator.update,
      );
      server = RuntimeAssetServer(
        game: package,
        shareAccess: session == null
            ? RuntimeShareAccess.standalone()
            : RuntimeShareAccess.multiplayer(
                corePort: goCore.baseUri.port,
                joinCode: session.joinCode,
                shareToken: session.shareToken!,
              ),
        browserCapabilityRegistry: [
          for (final descriptor in defaultCapabilityDescriptors)
            if (modules.capabilityCodes.contains(descriptor.code))
              descriptor.toJson(),
        ],
        platformUi: platformUi,
        storage: storage,
      );
      onProgress?.call('正在启动游戏资源网关…');
      await server.start();
      onProgress?.call('正在打开游戏…');
      return RuntimeLaunch._(
        package: package,
        goCore: goCore,
        server: server,
        bridge: bridge,
        identity: identity,
        nicknameCoordinator: nicknameCoordinator,
        modules: modules,
        platformUi: platformUi,
      );
    } on Object {
      await server?.close();
      await bridge?.close();
      if (bridge == null) await session?.close();
      await goCore.close();
      rethrow;
    }
  }

  final RuntimeGamePackage package;
  final RuntimeGoCore goCore;
  final RuntimeAssetServer server;
  final RuntimeGameBridge bridge;
  final RuntimeIdentity identity;
  final RuntimeNicknameCoordinator nicknameCoordinator;
  final RuntimeModuleCatalog modules;
  final RuntimePlatformUiCatalog platformUi;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
    await bridge.close();
    await goCore.close();
  }
}

final class RuntimeGamePage extends StatefulWidget {
  const RuntimeGamePage({super.key, required this.launch});

  final RuntimeLaunch launch;

  @override
  State<RuntimeGamePage> createState() => _RuntimeGamePageState();
}

final class _RuntimeGamePageState extends State<RuntimeGamePage>
    with WidgetsBindingObserver {
  late final RuntimeDisplayController _display = RuntimeDisplayController();
  final ValueNotifier<bool> _inputTakenOver = ValueNotifier(false);
  late final RuntimeNavigation _navigation = RuntimeNavigation();
  late final RuntimeLanCoordinator _lanHost = RuntimeLanCoordinator(
    game: widget.launch.package.manifest,
    session: widget.launch.bridge.session,
    server: widget.launch.server,
    qrAvailable: widget.launch.modules.contains('service.lan.qr'),
    scanQr: _scanQr,
    beforeRemoteNavigation: _prepareRemoteNavigation,
    navigate: (uri) async => _navigation.navigate(uri),
  );

  Future<void> _prepareRemoteNavigation(
    Uri coreBase,
    String playerSource,
  ) async {
    _appBridge.enterRemoteMode(coreBase: coreBase, playerSource: playerSource);
    await widget.launch.bridge.detachForRemote();
  }

  late final RuntimeAppBridge _appBridge = RuntimeAppBridge(
    game: widget.launch.package.manifest,
    userId: widget.launch.identity.userId,
    nickname: widget.launch.identity.nickname,
    coreBase: widget.launch.goCore.baseUri,
    modules: widget.launch.modules,
    platformUi: widget.launch.platformUi,
    display: _display,
    lanHost: _lanHost,
    onOpenSharePanel: _openSharePanel,
    onInputTakeover: () => _inputTakenOver.value = true,
    autoApproveCapabilities: widget.launch.package.autoApproveCapabilities,
    onExit: _exitRuntime,
    onNicknameChanged: widget.launch.identity.updateNickname,
    onLocalNicknameUpdate: _updateLocalNickname,
  );

  Future<Map<String, Object?>> _updateLocalNickname(String nickname) async {
    try {
      final update = await widget.launch.nicknameCoordinator.update(nickname);
      return {
        'session': update.session,
        'player': update.player,
        'identity': {
          'userId': widget.launch.identity.userId,
          'nickname': widget.launch.identity.nickname,
          'source': 'playmesh_app',
        },
      };
    } on RuntimeNicknameUpdateException catch (error) {
      throw RuntimeAppSdkException(error.code, error.message);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _display.enter(widget.launch.package.manifest.orientation).catchError((
        Object error,
      ) {
        debugPrint('Runtime 初始全屏/方向设置失败: $error');
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.launch.bridge.notifyLifecycle('resume'));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.launch.bridge.notifyLifecycle('pause'));
    }
  }

  Future<String?> _scanQr() {
    if (!Platform.isAndroid) {
      throw const RuntimeLanException('scanner_unavailable', '当前平台扫码不可用');
    }
    if (!mounted) {
      throw const RuntimeLanException('operation_cancelled', '游戏退出，操作已取消');
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const RuntimeQrScannerPage()),
    );
  }

  Future<void> _openSharePanel() async {
    await _lanHost.setPublished();
    final links = await _lanHost.getShareLinks();
    final session = widget.launch.bridge.session;
    if (session != null) {
      try {
        await session.refreshSnapshot();
      } on Object catch (error) {
        debugPrint('Runtime 刷新分享房间玩家失败: $error');
      }
    }
    if (!mounted) return;
    final useChinese = Platform.localeName.toLowerCase().startsWith('zh');
    final relay = _lanHost.bundledRelayPresentation;
    final presentation = buildRuntimeSharePanelPresentation(
      title: runtimeSharePanelTitle(useChinese: useChinese),
      links: links,
      session: session,
      bundledRelayName: relay == null
          ? null
          : relay.name ??
                runtimeBundledRelayFallbackName(useChinese: useChinese),
      bundledRelayLatencyMilliseconds: relay?.latencyMilliseconds,
    );
    final strings = runtimeSharePanelStrings(useChinese: useChinese);
    final actionMode = Platform.isWindows
        ? PlaymeshShareActionMode.copy
        : PlaymeshShareActionMode.share;
    var selectedLanLinkId = presentation.model.selectedLanLinkId;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 20,
            ),
            clipBehavior: Clip.none,
            backgroundColor: Colors.transparent,
            child: PlaymeshSharePanel(
              model: selectedLanLinkId == null
                  ? presentation.model
                  : presentation.selectLanLink(selectedLanLinkId!),
              strings: strings,
              actionMode: actionMode,
              onClose: () => Navigator.of(dialogContext).pop(),
              onSelectLanLink: (id) {
                if (presentation.linkForId(id) == null) return;
                setDialogState(() => selectedLanLinkId = id);
              },
              onLinkAction: (link) async {
                final url = presentation.linkForId(link.id);
                if (url == null) return;
                try {
                  if (Platform.isWindows) {
                    await Clipboard.setData(
                      ClipboardData(text: url.toString()),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              runtimeShareLinkCopiedMessage(
                                useChinese: useChinese,
                              ),
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                    }
                    return;
                  }
                  await SharePlus.instance.share(
                    ShareParams(text: url.toString()),
                  );
                } on Object catch (error) {
                  debugPrint('Runtime 分享链接操作失败: $error');
                }
              },
            ),
          ),
        ),
      );
    } finally {
      widget.launch.bridge.restoreGameContentFocus();
    }
  }

  Future<void> _exitRuntime() async {
    await widget.launch.bridge.notifyLifecycle('exit');
    await _display.restore();
    if (Platform.isWindows) {
      await windowManager.close();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.launch.bridge.notifyLifecycle('exit'));
    unawaited(_appBridge.close());
    unawaited(_navigation.close());
    unawaited(_display.restore());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: RuntimeGameView(
      entryUri: widget.launch.server.entryUri,
      game: widget.launch.package.manifest,
      gameBridge: widget.launch.bridge,
      appBridge: _appBridge,
      navigation: _navigation,
      inputTakenOver: _inputTakenOver,
      onExitRequested: _exitRuntime,
    ),
  );
}
