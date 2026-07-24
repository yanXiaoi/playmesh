import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'core/game_package/file_game_library_scanner.dart';
import 'core/game_package/game_library_local_metadata.dart';
import 'core/catalog/online_game_catalog.dart';
import 'core/game_package/game_library_manager.dart';
import 'core/game_package/game_library_repository.dart';
import 'core/game_package/game_package_transfer_service.dart';
import 'core/developer/developer_project_catalog.dart';
import 'core/developer/developer_run_controller.dart';
import 'core/profile/user_profile_store.dart';
import 'core/platform/incoming_file_service.dart';
import 'core/services/go_core_runtime.dart';
import 'core/services/go_core_status_service.dart';
import 'core/settings/game_display_preferences.dart';
import 'features/game/game_page.dart';
import 'features/game/game_orientation_controller.dart';
import 'features/game/join_game_page.dart';
import 'features/game/standalone_html_page.dart';
import 'features/games/game_detail_page.dart';
import 'features/games/game_library_page.dart';
import 'features/games/online_game_library_page.dart';
import 'features/home/home_page.dart';
import 'features/profile/profile_page.dart';
import 'features/settings/settings_page.dart';
import 'models/game_summary.dart';
import 'models/user_profile.dart';
import 'ui/playmesh_ui.dart';

class PlaymeshApp extends StatefulWidget {
  const PlaymeshApp({
    super.key,
    this.goCoreStatusProvider,
    this.gameOrientationController,
    this.games,
  });

  final GoCoreStatusProvider? goCoreStatusProvider;
  final GameOrientationController? gameOrientationController;
  final List<GameSummary>? games;

  static UserProfile createLocalUser() => UserProfile(
    userId: UserProfileStore.generateUserId(),
    nickname: '本机玩家',
    avatarLabel: 'PM',
  );

  @override
  State<PlaymeshApp> createState() => _PlaymeshAppState();
}

class _PlaymeshAppState extends State<PlaymeshApp> {
  GoCoreRuntime? _runtime;
  late final GoCoreStatusProvider _statusProvider;
  late final bool _ownsRuntime;
  late final GameLibraryManager _gameLibraryManager;
  late final GameLibraryRepository _gameLibrary;
  GameLibraryLocalMetadataStore? _gameLibraryMetadata;
  late final GamePackageTransferService _packageTransfer;
  late final GameCatalogController _catalogController;
  late final GameLibraryDeveloperProjectCatalog _developerCatalog;
  late final DeveloperRunController _developerRuns;
  late final GameDisplayPreferences _displayPreferences;
  late final UserProfileStore _profileStore;
  IncomingFileService? _incomingFiles;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late Future<List<GameSummary>> _games;
  late UserProfile _profile;
  bool _performanceVisible = true;

  @override
  void initState() {
    super.initState();
    _profile = PlaymeshApp.createLocalUser();
    final injectedGames = widget.games;
    _gameLibraryManager = GameLibraryManager();
    _packageTransfer = GamePackageTransferService();
    _displayPreferences = GameDisplayPreferences();
    _profileStore = const UserProfileStore();
    late GameLibraryScan scan;
    _gameLibrary = GameLibraryRepository(
      () => scan(),
      initialGames: injectedGames ?? const [],
    );
    _developerCatalog = GameLibraryDeveloperProjectCatalog(_gameLibrary);
    if (injectedGames == null) {
      final metadata = GameLibraryLocalMetadataStore();
      _gameLibraryMetadata = metadata;
      scan = FileGameLibraryScanner(metadataStore: metadata).scan;
    } else {
      scan = () async => injectedGames;
    }
    _catalogController = GameCatalogController(
      library: _gameLibrary,
      transfer: _packageTransfer,
      onImported: _catalogGameImported,
    );
    if (injectedGames == null) unawaited(_catalogController.initialize());
    _games = injectedGames == null
        ? _gameLibrary.refresh()
        : SynchronousFuture(_gameLibrary.cachedGames);
    _developerRuns = DeveloperRunController(onLaunch: _launchDeveloperProject);
    // The Android embedding currently owns the ACTION_VIEW/open-file bridge.
    // Harmony file picking is provided through file_selector_ohos, but external
    // file intents are not advertised until an equivalent native bridge exists.
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
      unawaited(
        _displayPreferences.loadPerformanceVisible().then((visible) {
          if (mounted) setState(() => _performanceVisible = visible);
        }),
      );
    }
    final injectedProvider = widget.goCoreStatusProvider;
    if (injectedProvider is GoCoreRuntime) {
      _runtime = injectedProvider;
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
    _incomingFiles?.dispose();
    unawaited(_catalogController.close());
    if (_ownsRuntime) {
      unawaited(_runtime?.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<GameSummary>>(
      future: _games,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(child: Text('游戏库扫描失败\n${snapshot.error}')),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        return _buildApp(snapshot.data!);
      },
    );
  }

  Widget _buildApp(List<GameSummary> games) {
    final primaryGame = games.isEmpty ? null : games.first;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Playmesh',
      debugShowCheckedModeBanner: false,
      theme: PlaymeshTheme.light(),
      home: HomePage(user: _profile, featuredGame: primaryGame),
      routes: {
        ProfilePage.routeName: (_) =>
            ProfilePage(user: _profile, onSave: _saveProfile),
        GameLibraryPage.routeName: (_) => GameLibraryPage(
          games: _gameLibrary.cachedGames,
          onRefresh: _gameLibrary.refresh,
          onImport: _importGame,
          onOpenOnline: widget.games == null
              ? () => _navigatorKey.currentState?.pushNamed<void>(
                  OnlineGameLibraryPage.routeName,
                )
              : null,
        ),
        SettingsPage.routeName: (_) => SettingsPage(
          statusProvider: _statusProvider,
          catalogController: widget.games == null ? _catalogController : null,
        ),
        OnlineGameLibraryPage.routeName: (_) =>
            OnlineGameLibraryPage(controller: _catalogController),
        JoinGamePage.routeName: (_) => JoinGamePage(
          game: primaryGame,
          initialUserId: _profile.userId,
          initialNickname: _profile.nickname,
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
                  final game? => GameLaunchArguments(game: game),
                  null => null,
                };
          if (launchArguments == null) return null;
          unawaited(_recordGameOpened(launchArguments.game.id));

          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => GamePage(
              game: launchArguments.game,
              localUserId: _profile.userId,
              localNickname: _profile.nickname,
              orientationController: widget.gameOrientationController,
              goCoreRuntime: _runtime,
              joinRequest: launchArguments.joinRequest,
              developerProjectId: launchArguments.developerProjectId,
              initialPerformanceVisible: _performanceVisible,
              onPerformanceVisibilityChanged: widget.games == null
                  ? _savePerformanceVisible
                  : null,
            ),
          );
        }

        return null;
      },
    );
  }

  Future<void> _recordGameOpened(String gameId) async {
    final openedAt = DateTime.now().toUtc();
    try {
      await _gameLibraryMetadata?.markOpened(gameId, openedAt);
    } on Object catch (error) {
      debugPrint('保存最近打开时间失败: $error');
    }
    _gameLibrary.markOpened(gameId, openedAt);
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

  Future<void> _catalogGameImported(GameSummary game) async {
    _gameLibrary.upsert(game);
    if (!mounted) return;
    setState(() {
      _games = SynchronousFuture(_gameLibrary.cachedGames);
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
    if (navigator == null) throw StateError('App 导航尚未就绪');

    if (file.isArchive) {
      final game = await _importGame(file.path);
      if (!mounted) return;
      unawaited(navigator.pushNamed<void>(GameLibraryPage.routeName));
      _showAppMessage('已导入 ${game.name} ${game.version}');
      return;
    }
    if (file.isHtml) {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => StandaloneHtmlPage(filePath: file.path),
        ),
      );
      return;
    }
    throw FormatException('不支持的外部文件：${file.name}');
  }

  void _showIncomingFileError(Object error) {
    debugPrint('处理外部文件失败: $error');
    _showAppMessage('打开文件失败：$error');
  }

  void _showAppMessage(String message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _savePerformanceVisible(bool visible) {
    _performanceVisible = visible;
    unawaited(
      _displayPreferences.savePerformanceVisible(visible).catchError((
        Object error,
      ) {
        debugPrint('保存性能悬浮层设置失败: $error');
      }),
    );
  }

  Future<void> _launchDeveloperProject(String projectId) async {
    await _games;
    final game = await _developerCatalog.prepareGame(projectId);
    var navigator = _navigatorKey.currentState;
    if (navigator == null) {
      await WidgetsBinding.instance.endOfFrame;
      navigator = _navigatorKey.currentState;
    }
    if (navigator == null) throw StateError('App 导航尚未就绪');
    unawaited(
      navigator.pushNamedAndRemoveUntil<void>(
        GamePage.routeName,
        (route) => route.isFirst,
        arguments: GameLaunchArguments(
          game: game,
          developerProjectId: projectId,
        ),
      ),
    );
  }
}
