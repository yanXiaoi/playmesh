import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'core/game_package/file_game_library_scanner.dart';
import 'core/game_package/game_library_local_metadata.dart';
import 'core/catalog/online_game_catalog.dart';
import 'core/game_package/game_library_manager.dart';
import 'core/game_package/game_library_repository.dart';
import 'core/game_package/game_package_transfer_service.dart';
import 'core/game_package/ordinary_web_package_importer.dart';
import 'core/localization/playmesh_localization.dart';
import 'core/localization/playmesh_ui_controller.dart';
import 'core/localization/playmesh_ui_preferences.dart';
import 'core/network/lan_game_discovery_service.dart';
import 'core/developer/developer_background_host.dart';
import 'core/developer/developer_channel.dart';
import 'core/developer/developer_game_catalog_publisher.dart';
import 'core/developer/developer_project_catalog.dart';
import 'core/developer/developer_run_controller.dart';
import 'core/developer/developer_web_gateway_contract.dart';
import 'core/platform/app_platform.dart';
import 'core/profile/user_profile_store.dart';
import 'core/platform/incoming_file_service.dart';
import 'core/services/go_core_runtime.dart';
import 'core/services/go_core_status_service.dart';
import 'features/game/game_page.dart';
import 'features/game/game_orientation_controller.dart';
import 'features/game/join_game_page.dart';
import 'features/game/standalone_html_page.dart';
import 'features/developer/game_creation_page.dart';
import 'features/games/game_detail_page.dart';
import 'features/games/game_library_page.dart';
import 'features/games/online_game_library_page.dart';
import 'features/home/home_page.dart';
import 'features/profile/profile_page.dart';
import 'features/settings/settings_page.dart';
import 'models/game_summary.dart';
import 'models/user_profile.dart';
import 'ui/focus/playmesh_shortcuts.dart';
import 'ui/playmesh_ui.dart';

@visibleForTesting
void launchDeveloperGameRoute(
  NavigatorState navigator,
  GameLaunchArguments arguments,
) {
  // 开发者运行属于临时覆盖页，必须保留工作区及其之前的导航栈。
  unawaited(
    navigator.pushNamed<void>(GamePage.routeName, arguments: arguments),
  );
}

class PlaymeshApp extends StatefulWidget {
  const PlaymeshApp({
    super.key,
    this.goCoreStatusProvider,
    this.gameOrientationController,
    this.games,
    this.uiBootstrap,
    this.gameLibraryScan,
    this.onShutdownStarted,
    this.lanGameDiscoveryService,
  });

  final GoCoreStatusProvider? goCoreStatusProvider;
  final GameOrientationController? gameOrientationController;
  final List<GameSummary>? games;
  final PlaymeshUiBootstrap? uiBootstrap;

  @visibleForTesting
  final GameLibraryScan? gameLibraryScan;

  @visibleForTesting
  final VoidCallback? onShutdownStarted;

  @visibleForTesting
  final LanGameDiscoveryService? lanGameDiscoveryService;

  static UserProfile createLocalUser() => UserProfile(
    userId: UserProfileStore.generateUserId(),
    nickname: playmeshDefaultLocalNickname,
  );

  @override
  State<PlaymeshApp> createState() => _PlaymeshAppState();
}

class _PlaymeshAppState extends State<PlaymeshApp>
    with WidgetsBindingObserver, WindowListener {
  GoCoreRuntime? _runtime;
  late final GoCoreStatusProvider _statusProvider;
  late final bool _ownsRuntime;
  late final GameLibraryManager _gameLibraryManager;
  late final GameLibraryRepository _gameLibrary;
  GameLibraryLocalMetadataStore? _gameLibraryMetadata;
  late final GamePackageTransferService _packageTransfer;
  late final OrdinaryWebPackageImporter _ordinaryWebPackageImporter;
  late final GameCatalogController _catalogController;
  late final GameLibraryDeveloperProjectCatalog _developerCatalog;
  late final DeveloperRunController _developerRuns;
  late final UserProfileStore _profileStore;
  IncomingFileService? _incomingFiles;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late Future<List<GameSummary>> _games;
  late final Future<PlaymeshUiBootstrap> _uiBootstrap;
  PlaymeshUiController? _uiController;
  late final DeveloperWorkspaceLocalizationBridge
  _developerWorkspaceLocalizationBridge;
  late UserProfile _profile;
  bool _windowCloseDialogVisible = false;
  bool _windowCloseConfirmed = false;
  bool _shutdownStarted = false;
  late final LanGameDiscoveryService _lanGameDiscoveryService;
  late final bool _ownsLanGameDiscoveryService;

  @override
  void initState() {
    super.initState();
    final injectedDiscoveryService = widget.lanGameDiscoveryService;
    _lanGameDiscoveryService =
        injectedDiscoveryService ?? LanGameDiscoveryService();
    _ownsLanGameDiscoveryService = injectedDiscoveryService == null;
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
    }
    _developerWorkspaceLocalizationBridge =
        DeveloperWorkspaceLocalizationBridge(
          current: _currentDeveloperWorkspaceLocalization,
          resolve: _resolveDeveloperWorkspaceLocalization,
          useLocale: _useDeveloperWorkspaceLocale,
          useTheme: _useDeveloperWorkspaceTheme,
        );
    final injectedUiBootstrap = widget.uiBootstrap;
    _uiBootstrap = injectedUiBootstrap == null
        ? PlaymeshUiBootstrap.load()
        : SynchronousFuture(injectedUiBootstrap);
    if (injectedUiBootstrap != null) {
      _attachUiController(injectedUiBootstrap);
    }
    _profile = PlaymeshApp.createLocalUser();
    final injectedGames = widget.games;
    _gameLibraryManager = GameLibraryManager();
    _packageTransfer = GamePackageTransferService();
    _ordinaryWebPackageImporter = const OrdinaryWebPackageImporter();
    _profileStore = const UserProfileStore();
    late GameLibraryScan scan;
    _gameLibrary = GameLibraryRepository(
      () => scan(),
      initialGames: injectedGames ?? const [],
    );
    _developerCatalog = GameLibraryDeveloperProjectCatalog(
      _gameLibrary,
      packageTransfer: _packageTransfer,
      ordinaryWebPackageImporter: _ordinaryWebPackageImporter,
    );
    if (injectedGames == null) {
      final metadata = GameLibraryLocalMetadataStore();
      _gameLibraryMetadata = metadata;
      scan =
          widget.gameLibraryScan ??
          FileGameLibraryScanner(metadataStore: metadata).scan;
    } else {
      scan = () async => injectedGames;
    }
    _catalogController = GameCatalogController(
      library: _gameLibrary,
      transfer: _packageTransfer,
      onImported: _catalogGameImported,
      nicknameProvider: () => _profile.nickname,
    );
    if (injectedGames == null) unawaited(_catalogController.initialize());
    _games = injectedGames == null
        ? widget.gameLibraryScan == null
              ? _recoverImportsAndRefreshLibrary()
              : _gameLibrary.refresh()
        : SynchronousFuture(_gameLibrary.cachedGames);
    _developerRuns = DeveloperRunController(onLaunch: _launchDeveloperProject);
    unawaited(cleanupStaleGamePackageExport());
    // Android 嵌入层目前负责 ACTION_VIEW/打开文件桥接。
    if (!kIsWeb && Platform.isAndroid) {
      final incomingFiles = IncomingFileService();
      _incomingFiles = incomingFiles;
      unawaited(
        incomingFiles.initialize(
          onFile: _handleIncomingFile,
          onError: _showIncomingFileError,
        ),
      );
    }
    if (injectedGames == null) {
      unawaited(
        _profileStore.load(_profile).then((profile) {
          if (mounted) setState(() => _profile = profile);
        }),
      );
    }
    final injectedProvider = widget.goCoreStatusProvider;
    if (injectedProvider is GoCoreRuntime) {
      _runtime = injectedProvider;
      injectedProvider.setDeveloperWorkspaceLocalizationBridge(
        _developerWorkspaceLocalizationBridge,
      );
      injectedProvider.setDeveloperBackgroundNotificationLocalizationProvider(
        _currentDeveloperBackgroundNotificationLocalization,
      );
      _statusProvider = injectedProvider;
      _ownsRuntime = false;
    } else if (injectedProvider != null) {
      _statusProvider = injectedProvider;
      _ownsRuntime = false;
    } else {
      _runtime = GoCoreRuntime.bundled(
        developerProjectCatalog: _developerCatalog,
        developerRunController: _developerRuns,
        developerAuthorProvider: () => _profile.nickname,
        developerProjectPublisher: GameCatalogDeveloperProjectPublisher(
          _catalogController,
        ),
        developerWorkspaceLocalizationBridge:
            _developerWorkspaceLocalizationBridge,
        developerBackgroundNotificationLocalizationProvider:
            _currentDeveloperBackgroundNotificationLocalization,
      );
      _statusProvider = _runtime!;
      _ownsRuntime = true;
    }
    final runtime = _runtime;
    if (runtime != null) {
      unawaited(
        runtime.start().catchError((Object error) {
          debugPrint('App 启动 Go Core 失败: $error');
        }),
      );
    }
  }

  @override
  void dispose() {
    _beginShutdown();
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    _uiController?.removeListener(_uiChanged);
    _uiController?.dispose();
    _incomingFiles?.dispose();
    super.dispose();
  }

  void _beginShutdown() {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    widget.onShutdownStarted?.call();

    final runtime = _runtime;
    if (_ownsRuntime && runtime != null) {
      unawaited(_observeShutdownOperation('Go Core', runtime.close()));
    }
    if (_ownsLanGameDiscoveryService) {
      unawaited(
        _observeShutdownOperation(
          '局域网发现服务',
          _lanGameDiscoveryService.dispose(),
        ),
      );
    }
    unawaited(_observeShutdownOperation('游戏目录服务', _catalogController.close()));
  }

  Future<void> _observeShutdownOperation(
    String name,
    Future<void> operation,
  ) async {
    try {
      await operation;
    } on Object catch (error, stackTrace) {
      debugPrint('$name 关闭失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void onWindowClose() {
    if (_windowCloseConfirmed) return;
    unawaited(_confirmWindowClose());
  }

  Future<void> _confirmWindowClose() async {
    if (_windowCloseDialogVisible || !mounted) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;

    _windowCloseDialogVisible = true;
    try {
      final confirmed = await showDialog<bool>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(context.tr('app.exit_confirm_title')),
          content: Text(context.tr('app.exit_confirm_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.tr('app.exit_confirm_action')),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        _windowCloseConfirmed = true;
        _beginShutdown();
        await windowManager.setPreventClose(false);
        await windowManager.close();
      }
    } on Object catch (error, stackTrace) {
      _windowCloseConfirmed = false;
      try {
        await windowManager.setPreventClose(true);
      } on Object {
        // 保留原始关闭错误，恢复拦截失败不覆盖诊断。
      }
      debugPrint('关闭 Windows 应用窗口失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _windowCloseDialogVisible = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PlaymeshUiBootstrap>(
      future: _uiBootstrap,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Text(
                  'playmesh_localization_bootstrap_failed\n${snapshot.error}',
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        final uiController = _attachUiController(snapshot.data!);
        return FutureBuilder<List<GameSummary>>(
          future: _games,
          builder: (context, gameSnapshot) {
            return _buildApp(
              gameSnapshot.data ?? _gameLibrary.cachedGames,
              uiController,
              gameLibraryLoading:
                  gameSnapshot.connectionState != ConnectionState.done,
              gameLibraryError: gameSnapshot.error,
            );
          },
        );
      },
    );
  }

  PlaymeshUiController _attachUiController(PlaymeshUiBootstrap bootstrap) {
    final existing = _uiController;
    if (existing != null) return existing;
    final created = PlaymeshUiController(bootstrap)..addListener(_uiChanged);
    _uiController = created;
    return created;
  }

  void _uiChanged() {
    if (mounted) setState(() {});
    _refreshDeveloperBackgroundNotification();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final ui = _uiController;
    if (ui?.preferences.localeMode != PlaymeshLocaleMode.system) return;
    if (mounted) setState(() {});
    _refreshDeveloperBackgroundNotification();
  }

  DeveloperWorkspaceLocalization _currentDeveloperWorkspaceLocalization() {
    final ui = _uiController;
    if (ui == null) {
      throw StateError('app_localization_not_ready');
    }
    final manifest = ui.catalog.manifest;
    final preferences = ui.preferences;
    final localeId = preferences.localeMode == PlaymeshLocaleMode.fixed
        ? manifest.resolveEnabledLocale(preferences.localeId!)
        : manifest.resolvePlatformLocales(
            WidgetsBinding.instance.platformDispatcher.locales,
          );
    final effectiveTheme = switch (preferences.theme) {
      PlaymeshThemePreference.light => 'light',
      PlaymeshThemePreference.dark => 'dark',
      PlaymeshThemePreference.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark
            ? 'dark'
            : 'light',
    };
    return DeveloperWorkspaceLocalization(
      localeId: localeId,
      localeMode: preferences.localeMode.wireName,
      defaultLocale: manifest.defaultLocale,
      allowLocaleSwitch: manifest.allowLocaleSwitch,
      themeMode: preferences.theme.wireName,
      effectiveTheme: effectiveTheme,
      allowThemeSwitch: manifest.allowThemeSwitch,
      locales: manifest.enabledLocales
          .map(
            (locale) =>
                DeveloperWorkspaceLocale(id: locale.id, label: locale.label),
          )
          .toList(growable: false),
      messages: Map.unmodifiable({
        for (final entry
            in ui.catalog
                .resolvedMessages(localeId, PlaymeshLocalizationBundle.app)
                .entries)
          if (entry.key.startsWith('workspace.')) entry.key: entry.value,
      }),
    );
  }

  DeveloperWorkspaceLocalization _resolveDeveloperWorkspaceLocalization(
    String requestedLocaleId,
  ) {
    final ui = _uiController;
    if (ui == null) {
      throw StateError('app_localization_not_ready');
    }
    final current = _currentDeveloperWorkspaceLocalization();
    final manifest = ui.catalog.manifest;
    final normalized = requestedLocaleId.trim().replaceAll('_', '-');
    final enabled = manifest.enabledLocales.toList(growable: false);
    final exact = enabled
        .where(
          (candidate) => candidate.id.toLowerCase() == normalized.toLowerCase(),
        )
        .firstOrNull;
    final language = normalized.split('-').first.toLowerCase();
    final resolvedLocale =
        exact?.id ??
        enabled
            .where(
              (candidate) =>
                  candidate.locale.languageCode.toLowerCase() == language,
            )
            .firstOrNull
            ?.id ??
        manifest.defaultLocale;
    final resolvedMessages = ui.catalog.resolvedMessages(
      resolvedLocale,
      PlaymeshLocalizationBundle.app,
    );
    return DeveloperWorkspaceLocalization(
      localeId: resolvedLocale,
      localeMode: current.localeMode,
      defaultLocale: current.defaultLocale,
      allowLocaleSwitch: current.allowLocaleSwitch,
      themeMode: current.themeMode,
      effectiveTheme: current.effectiveTheme,
      allowThemeSwitch: current.allowThemeSwitch,
      locales: current.locales,
      messages: Map.unmodifiable({
        for (final entry in resolvedMessages.entries)
          if (entry.key.startsWith('workspace.gdevelop_'))
            entry.key: entry.value,
      }),
    );
  }

  DeveloperBackgroundNotificationLocalization?
  _currentDeveloperBackgroundNotificationLocalization() {
    final ui = _uiController;
    if (ui == null) return null;
    final manifest = ui.catalog.manifest;
    final preferences = ui.preferences;
    final localeId = preferences.localeMode == PlaymeshLocaleMode.fixed
        ? manifest.resolveEnabledLocale(preferences.localeId!)
        : manifest.resolvePlatformLocales(
            WidgetsBinding.instance.platformDispatcher.locales,
          );
    return DeveloperBackgroundNotificationLocalization.fromAppMessages(
      localeId: localeId,
      messages: ui.catalog.resolvedMessages(
        localeId,
        PlaymeshLocalizationBundle.app,
      ),
    );
  }

  void _refreshDeveloperBackgroundNotification() {
    final runtime = _runtime;
    if (runtime == null) return;
    unawaited(
      runtime.refreshDeveloperBackgroundNotification().catchError((
        Object error,
      ) {
        debugPrint('developer_foreground_notification_refresh_failed: $error');
      }),
    );
  }

  Future<void> _useDeveloperWorkspaceLocale(String? localeId) async {
    final ui = _uiController;
    if (ui == null) {
      throw StateError('app_localization_not_ready');
    }
    final normalized = localeId?.trim() ?? '';
    if (normalized.isEmpty) {
      await ui.useSystemLocale();
      return;
    }
    await ui.useLocale(normalized);
  }

  Future<void> _useDeveloperWorkspaceTheme(String themeMode) async {
    final ui = _uiController;
    if (ui == null) {
      throw StateError('app_localization_not_ready');
    }
    final normalized = themeMode.trim();
    final theme = PlaymeshThemePreference.values
        .where((candidate) => candidate.wireName == normalized)
        .firstOrNull;
    if (theme == null) {
      throw FormatException('Unknown themeMode: $themeMode');
    }
    await ui.useTheme(theme);
  }

  Widget _buildApp(
    List<GameSummary> games,
    PlaymeshUiController uiController, {
    required bool gameLibraryLoading,
    Object? gameLibraryError,
  }) {
    final primaryGame = games.isEmpty ? null : games.first;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Playmesh',
      debugShowCheckedModeBanner: false,
      locale: uiController.fixedLocale,
      supportedLocales: uiController.supportedLocales,
      localeResolutionCallback: (locale, _) => uiController.resolveLocale(
        locale,
        WidgetsBinding.instance.platformDispatcher.locales,
      ),
      localizationsDelegates: [
        PlaymeshLocalizationsDelegate(uiController.catalog),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PlaymeshTheme.light(),
      darkTheme: PlaymeshTheme.dark(),
      themeMode: uiController.themeMode,
      builder: _buildRootInteractionLayer,
      home: HomePage(
        user: _profile,
        games: games,
        gameLibraryLoading: gameLibraryLoading,
        gameLibraryError: gameLibraryError,
        onRetryGameLibrary: gameLibraryError == null
            ? null
            : _retryGameLibraryScan,
        lanGameDiscoveryService: _lanGameDiscoveryService,
      ),
      routes: {
        ProfilePage.routeName: (_) =>
            ProfilePage(user: _profile, onSave: _saveProfile),
        GameLibraryPage.routeName: (routeContext) => GameLibraryPage(
          games: _gameLibrary.cachedGames,
          onRefresh: _gameLibrary.refresh,
          onImport: _importGame,
          onInspectImport: _inspectGameImport,
          onImportOrdinaryWebPackage: _importOrdinaryWebGame,
          onQuery: (search, {required offset, required limit}) =>
              _gameLibrary.query(search: search, offset: offset, limit: limit),
          onCheckUpdates: widget.games == null
              ? _catalogController.checkUpdates
              : null,
          onDownloadUpdate: widget.games == null
              ? (offer) async {
                  await showGameDownloadProgressDialog(
                    routeContext,
                    controller: _catalogController,
                    offer: offer,
                  );
                }
              : null,
          onOpenOnline: widget.games == null
              ? () => _navigatorKey.currentState?.pushNamed<void>(
                  OnlineGameLibraryPage.routeName,
                )
              : null,
        ),
        SettingsPage.routeName: (_) => SettingsPage(
          statusProvider: _statusProvider,
          catalogController: widget.games == null ? _catalogController : null,
          uiController: uiController,
        ),
        GameCreationPage.routeName: (_) => GameCreationPage(
          developerProvider: _statusProvider is DeveloperModeProvider
              ? _statusProvider as DeveloperModeProvider
              : null,
        ),
        OnlineGameLibraryPage.routeName: (_) => OnlineGameLibraryPage(
          controller: _catalogController,
          usage: {
            for (final game in _gameLibrary.cachedGames)
              game.id: GameLibraryUsageStats(
                lastOpenedAt: game.lastOpenedAt,
                launchCount: game.launchCount,
              ),
          },
        ),
        JoinGamePage.routeName: (_) => JoinGamePage(
          initialUserId: _profile.userId,
          initialNickname: _profile.nickname,
          discoveryService: _lanGameDiscoveryService,
        ),
      },
      onGenerateRoute: (settings) {
        if (settings.name == GameDetailPage.routeName) {
          final game = settings.arguments as GameSummary?;
          if (game == null) return null;

          return MaterialPageRoute<String>(
            settings: settings,
            builder: (_) => GameDetailPage(
              game: game,
              onDelete: _deleteGame,
              onExport: _exportGame,
            ),
          );
        }

        if (settings.name == GamePage.routeName) {
          final arguments = settings.arguments;
          final launchArguments = arguments is GameLaunchArguments
              ? arguments
              : switch (arguments as GameSummary? ?? primaryGame) {
                  final game? => GameLaunchArguments(
                    game: game,
                    enterFullscreenOnLaunch: true,
                  ),
                  null => null,
                };
          if (launchArguments == null) return null;
          if (launchArguments.developerProjectId == null) {
            unawaited(_recordGameOpened(launchArguments.game.id));
          }

          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => GamePage(
              game: launchArguments.game,
              enterFullscreenOnLaunch: launchArguments.enterFullscreenOnLaunch,
              localUserId: _profile.userId,
              localNickname: _profile.nickname,
              localProfile: _profile,
              orientationController: widget.gameOrientationController,
              goCoreRuntime: _runtime,
              catalogController: widget.games == null
                  ? _catalogController
                  : null,
              lanGameDiscoveryService: _lanGameDiscoveryService,
              developerProjectId: launchArguments.developerProjectId,
              developerRunId: launchArguments.developerRunId,
              developerResourceSession:
                  launchArguments.developerResourceSession,
            ),
          );
        }

        return null;
      },
    );
  }

  Widget _buildRootInteractionLayer(BuildContext context, Widget? child) {
    return Shortcuts(
      shortcuts: PlaymeshShortcutRegistry.shortcuts,
      child: Actions(
        actions: _rootShortcutActions(),
        child: FocusTraversalGroup(
          policy: PlaymeshFocusPolicy(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  Map<Type, Action<Intent>> _rootShortcutActions() => {
    PlaymeshBackIntent: CallbackAction<PlaymeshBackIntent>(
      onInvoke: (_) {
        final navigator = _navigatorKey.currentState;
        if (navigator != null && navigator.canPop()) navigator.maybePop();
        return null;
      },
    ),
  };

  Future<void> _recordGameOpened(String gameId) async {
    final openedAt = DateTime.now().toUtc();
    try {
      await _gameLibraryMetadata?.markLaunched(gameId, openedAt);
    } on Object catch (error) {
      debugPrint('保存最近打开时间失败: $error');
    }
    _gameLibrary.markLaunched(gameId, openedAt);
    if (!mounted) return;
    setState(() {
      _games = SynchronousFuture(_gameLibrary.cachedGames);
    });
  }

  Future<void> _deleteGame(GameSummary game) async {
    await _gameLibraryManager.deleteGame(game);
    try {
      await _gameLibraryMetadata?.remove(game.id);
    } on Object catch (error) {
      debugPrint('删除最近打开记录失败: $error');
    }
    _gameLibrary.remove(game.id);
    if (!mounted) return;
    setState(() {
      _games = SynchronousFuture(_gameLibrary.cachedGames);
    });
  }

  Future<void> _saveProfile(UserProfile profile) async {
    await _profileStore.save(profile);
    if (mounted) setState(() => _profile = profile);
  }

  Future<GameSummary> _importGame(String sourcePath) async {
    final game = await _developerCatalog.publishPackage(
      File(sourcePath),
      author: _profile.nickname,
      lastModifiedAt: DateTime.now().toUtc(),
    );
    _gameLibrary.upsert(game);
    if (mounted) {
      setState(() {
        _games = SynchronousFuture(_gameLibrary.cachedGames);
      });
    }
    return game;
  }

  Future<GamePackageImportInspection> _inspectGameImport(String sourcePath) {
    return _ordinaryWebPackageImporter.inspect(File(sourcePath));
  }

  Future<GameSummary> _importOrdinaryWebGame(
    String sourcePath,
    OrdinaryWebPackageConfiguration configuration,
  ) async {
    final game = await _developerCatalog.publishOrdinaryWebPackage(
      File(sourcePath),
      configuration: configuration,
      author: _profile.nickname,
      lastModifiedAt: DateTime.now().toUtc(),
    );
    _gameLibrary.upsert(game);
    if (mounted) {
      setState(() {
        _games = SynchronousFuture(_gameLibrary.cachedGames);
      });
    }
    return game;
  }

  Future<void> _catalogGameImported(GameSummary _) async {
    await _gameLibrary.refresh();
    if (!mounted) return;
    setState(() {
      _games = SynchronousFuture(_gameLibrary.cachedGames);
    });
  }

  Future<List<GameSummary>> _recoverImportsAndRefreshLibrary() async {
    await _packageTransfer.recoverInterruptedImports();
    return _gameLibrary.refresh();
  }

  void _retryGameLibraryScan() {
    setState(() {
      _games = _gameLibrary.refresh();
    });
  }

  Future<void> _exportGame(GameSummary game, String destinationPath) async {
    await _packageTransfer.exportPackage(game, File(destinationPath));
  }

  Future<void> _handleIncomingFile(IncomingFile file) async {
    await _games;
    var navigator = _navigatorKey.currentState;
    if (navigator == null) {
      await WidgetsBinding.instance.endOfFrame;
      navigator = _navigatorKey.currentState;
    }
    if (navigator == null) {
      throw StateError('App navigator is not ready.');
    }
    if (file.isArchive) {
      final game = await _importGame(file.path);
      if (!mounted || !navigator.mounted) return;
      unawaited(navigator.pushNamed<void>(GameLibraryPage.routeName));
      _showAppMessage(
        navigator.context.tr(
          'app.file_imported',
          arguments: {'name': game.name, 'version': game.version},
        ),
      );
      return;
    }
    if (file.isHtml) {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => StandaloneHtmlPage(
            filePath: file.path,
            enterFullscreenOnLaunch: isMobileAppPlatform,
          ),
        ),
      );
      return;
    }
    if (!mounted || !navigator.mounted) return;
    throw FormatException(
      navigator.context.tr(
        'app.file_unsupported',
        arguments: {'name': file.name},
      ),
    );
  }

  void _showIncomingFileError(Object error) {
    debugPrint('incoming_file_open_failed: $error');
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    _showAppMessage(
      context.tr('app.file_open_failed', arguments: {'error': error}),
    );
  }

  void _showAppMessage(String message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _launchDeveloperProject(
    DeveloperProjectLaunchRequest request,
  ) async {
    await _games;
    final projectId = request.projectId;
    final game = switch (request.source) {
      DeveloperSavedProjectLaunchSource(:final game) => game,
      DeveloperResourceSessionLaunchSource(:final session) =>
        session.runtimeDeclaration?.toDevelopmentGame() ??
            (throw const DeveloperPreviewPackageRequired()),
    };
    var navigator = _navigatorKey.currentState;
    if (navigator == null) {
      await WidgetsBinding.instance.endOfFrame;
      navigator = _navigatorKey.currentState;
    }
    if (navigator == null) {
      throw StateError('App navigator is not ready.');
    }
    launchDeveloperGameRoute(
      navigator,
      GameLaunchArguments(
        game: game,
        enterFullscreenOnLaunch: isMobileAppPlatform,
        developerProjectId: projectId,
        developerRunId: request.runId,
        developerResourceSession: request.resourceSession,
      ),
    );
  }
}
