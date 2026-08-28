import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/app.dart';
import 'package:playmesh/core/developer/developer_event_hub.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_status_service.dart';
import 'package:playmesh/features/game/game_launcher.dart';
import 'package:playmesh/features/game/game_orientation_controller.dart';
import 'package:playmesh/features/game/game_page.dart';
import 'package:playmesh/features/game/join_game_page.dart';
import 'package:playmesh/features/game/local_game_web_view.dart';
import 'package:playmesh/features/games/game_library_page.dart';
import 'package:playmesh/features/home/home_page.dart';
import 'package:playmesh/models/game_capabilities.dart';
import 'package:playmesh/models/local_game_entry.dart';
import 'package:playmesh/models/game_summary.dart';

import 'support/localized_test_app.dart';

const _primaryGame = GameSummary(
  id: 'com.playmesh.test-game',
  name: '测试游戏',
  version: '1.0.0',
  description: '用于验证应用游戏流程',
  minPlayers: 1,
  maxPlayers: 4,
  supportsMultiplayer: true,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(
    gameEntryPath: 'index.html',
    statusLabel: 'Game SDK 1.0',
  ),
);
const _updatedGame = GameSummary(
  id: 'com.playmesh.updated-game',
  name: '更新后的游戏',
  version: '2.0.0',
  description: '用于验证同一 GamePage State 切换运行实例',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.portrait,
  entry: LocalGameEntry(
    gameEntryPath: 'index.html',
    statusLabel: 'Game SDK 2.3',
  ),
);
const _games = [_primaryGame];

Widget _gamePreview(GameSummary game) => Text('Fake WebView: ${game.id}');

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('shows home while the local game library is still scanning', (
    WidgetTester tester,
  ) async {
    final scanResult = Completer<List<GameSummary>>();

    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        uiBootstrap: localizedTestUiBootstrap(),
        gameLibraryScan: () => scanResult.future,
      ),
    );
    await tester.pump();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byKey(HomePage.profileHeroKey), findsOneWidget);
    expect(find.byKey(HomePage.gameLibraryLoadingKey), findsOneWidget);

    scanResult.complete(_games);
    await tester.pumpAndSettle();

    expect(find.byKey(HomePage.gameLibraryLoadingKey), findsNothing);
    expect(find.text(_primaryGame.name), findsOneWidget);
  });

  testWidgets('join action works without an installed game', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        games: const [],
        uiBootstrap: localizedTestUiBootstrap(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入对局').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(JoinGamePage), findsOneWidget);
    expect(find.text('加入主机对局'), findsWidgets);
    expect(find.text('对局邀请链接'), findsOneWidget);
    expect(find.text('主机地址'), findsNothing);
    expect(find.text('加入码'), findsNothing);
    expect(find.text('玩家昵称'), findsNothing);
    expect(find.text(_primaryGame.name), findsNothing);
  });

  testWidgets('shows Playmesh home and primary navigation entries', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        games: _games,
        uiBootstrap: localizedTestUiBootstrap(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Playmesh'), findsOneWidget);
    expect(find.byKey(HomePage.profileHeroKey), findsOneWidget);
    expect(find.text('用户资料'), findsNothing);
    expect(find.text('游戏库－最近游戏'), findsOneWidget);
    expect(find.byKey(HomePage.scanJoinKey), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);

    await tester.ensureVisible(find.text('测试游戏').last);

    expect(find.text('测试游戏'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('Windows 首页支持初始焦点、方向键与 Enter 激活', (WidgetTester tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        PlaymeshApp(
          goCoreStatusProvider: const _FakeStatusProvider(),
          games: _games,
          uiBootstrap: localizedTestUiBootstrap(),
        ),
      );
      await tester.pumpAndSettle();

      final initialFocus = FocusManager.instance.primaryFocus;
      expect(initialFocus, isNotNull);
      final initialContext = initialFocus!.context;
      expect(initialContext, isNotNull);
      expect(
        find.ancestor(
          of: find.byElementPredicate(
            (element) => identical(element, initialContext),
          ),
          matching: find.byKey(HomePage.profileHeroKey),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, isNot(same(initialFocus)));

      initialFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('opens profile and settings pages from home', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        games: _games,
        uiBootstrap: localizedTestUiBootstrap(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HomePage.profileIdentityKey));
    await tester.pumpAndSettle();

    expect(find.text('唯一 ID'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^u_[a-f0-9]{32}$')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('Playmesh 5.0.1'), findsOneWidget);
    expect(find.text('Core 0.1.0'), findsOneWidget);
  });

  testWidgets('opens details, starts, restarts, and returns from a game', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        gameOrientationController: _ImmediateOrientationController(),
        games: _games,
        uiBootstrap: localizedTestUiBootstrap(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();

    expect(find.text('游戏库'), findsOneWidget);
    expect(find.text('单机卡片 Demo'), findsNothing);
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text(_primaryGame.description), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '查看详情').first);
    await tester.pumpAndSettle();

    expect(find.text('游戏详情'), findsOneWidget);
    expect(find.text('游戏简介'), findsOneWidget);
    expect(find.text('开始游戏'), findsOneWidget);

    developerEventHub.emit({
      'type': 'runtime.log',
      'message': 'previous game log',
    });
    await tester.tap(find.widgetWithText(FilledButton, '开始游戏'));
    await tester.pumpAndSettle();

    expect(
      developerEventHub.recentLogs.where(
        (event) => event['message'] == 'previous game log',
      ),
      isEmpty,
    );
    expect(find.byKey(GamePage.gameSurfaceKey), findsOneWidget);
    expect(find.byKey(GamePage.runtimeKey(0)), findsOneWidget);
    final gamePage = tester.widget<GamePage>(find.byType(GamePage));
    expect(gamePage.localProfile, isNotNull);
    expect(gamePage.localProfile!.userId, gamePage.localUserId);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    expect(find.text('-- FPS'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byKey(GamePage.gameSurfaceKey),
      findsNothing,
      reason: 'App SDK 接管前，原生 Esc 必须可以直接退出加载中的游戏',
    );
    expect(find.byKey(const Key('game-sidebar')), findsNothing);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(GamePage.gameSurfaceKey), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '开始游戏'));
    await tester.pumpAndSettle();
    expect(find.byKey(GamePage.gameSurfaceKey), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(GamePage.gameSurfaceKey),
      findsNothing,
      reason: 'App SDK 接管前，Android 系统返回必须由原生直接退出游戏',
    );
  });

  testWidgets('developer game route returns to the existing workspace route', (
    WidgetTester tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    GameLaunchArguments? launched;
    await tester.pumpWidget(
      localizedTestApp(
        navigatorKey: navigatorKey,
        home: const Text('HOME'),
        routes: {'/developer-workspace': (_) => const Text('WORKSPACE')},
        onGenerateRoute: (settings) {
          if (settings.name != GamePage.routeName) return null;
          launched = settings.arguments! as GameLaunchArguments;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Text('DEVELOPER_GAME'),
          );
        },
      ),
    );

    unawaited(
      navigatorKey.currentState!.pushNamed<void>('/developer-workspace'),
    );
    await tester.pumpAndSettle();
    launchDeveloperGameRoute(
      navigatorKey.currentState!,
      const GameLaunchArguments(
        game: _primaryGame,
        enterFullscreenOnLaunch: false,
        developerProjectId: 'com.playmesh.test-game',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('DEVELOPER_GAME'), findsOneWidget);
    expect(launched?.enterFullscreenOnLaunch, isFalse);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('game page gives the local WebView the full body surface', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: const _ImmediateOrientationController(),
          previewBuilder: (game) => ColoredBox(
            color: Colors.black,
            child: Text('Fake WebView: ${game.entry.gameEntryPath}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = tester.widget<Stack>(find.byKey(GamePage.gameSurfaceKey));
    expect(surface.fit, StackFit.expand);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(GamePage.runtimeKey(0)), findsOneWidget);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    expect(find.byKey(const Key('game-sidebar')), findsNothing);
    expect(find.text('-- FPS'), findsNothing);
    expect(find.text('Fake WebView: index.html'), findsOneWidget);
  });

  testWidgets('native game page does not intercept SDK menu shortcuts', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: const _ImmediateOrientationController(),
          previewBuilder: (_) => const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f10);
    await tester.pumpAndSettle();
    expect(find.text('显示性能信息'), findsNothing);
    expect(find.byKey(const Key('game-sidebar')), findsNothing);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
  });

  testWidgets('changing the GamePage runtime identity clears transient UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          key: ValueKey('reused-game-page'),
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: _ImmediateOrientationController(),
          previewBuilder: _gamePreview,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          key: ValueKey('reused-game-page'),
          game: _updatedGame,
          enterFullscreenOnLaunch: true,
          orientationController: _ImmediateOrientationController(),
          previewBuilder: _gamePreview,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.byKey(GamePage.runtimeKey(1)), findsOneWidget);
    expect(
      find.text('Fake WebView: com.playmesh.updated-game'),
      findsOneWidget,
    );
    expect(find.byTooltip('关闭运行日志'), findsNothing);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    expect(find.byKey(const Key('game-sidebar')), findsNothing);
    expect(find.text('显示性能信息'), findsNothing);
  });

  testWidgets('rotating a developer resource session remounts the runtime', (
    WidgetTester tester,
  ) async {
    final firstSession = DeveloperResourceSession(
      projectId: _primaryGame.id,
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'a').join(),
      expiresAt: DateTime.utc(2026, 7, 30, 13),
    );
    final secondSession = DeveloperResourceSession(
      projectId: _primaryGame.id,
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'b').join(),
      expiresAt: DateTime.utc(2026, 7, 30, 14),
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          key: const ValueKey('developer-session-game-page'),
          game: _primaryGame,
          enterFullscreenOnLaunch: false,
          developerProjectId: _primaryGame.id,
          developerResourceSession: firstSession,
          orientationController: const _ImmediateOrientationController(),
          previewBuilder: _gamePreview,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(GamePage.runtimeKey(0)), findsOneWidget);

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          key: const ValueKey('developer-session-game-page'),
          game: _primaryGame,
          enterFullscreenOnLaunch: false,
          developerProjectId: _primaryGame.id,
          developerResourceSession: secondSession,
          orientationController: const _ImmediateOrientationController(),
          previewBuilder: _gamePreview,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(GamePage.runtimeKey(1)), findsOneWidget);
  });

  testWidgets('single-screen authority display receives only required', (
    WidgetTester tester,
  ) async {
    const game = GameSummary(
      id: 'com.playmesh.role-capabilities',
      name: '角色能力测试',
      version: '1.0.0',
      description: '验证显示端不会取得控制器能力',
      minPlayers: 2,
      maxPlayers: 4,
      supportsMultiplayer: true,
      displayModeLabel: '大屏模式',
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      capabilities: GameCapabilities(
        required: {},
        controllerRequired: {
          'media.camera',
          'media.microphone',
          'device.vibration',
        },
      ),
      entry: LocalGameEntry(
        gameEntryPath:
            'index.html?scene=current_scene&mode=touch&mode=keyboard',
        controllerEntryPath: 'controller/index.html',
        statusLabel: 'Game SDK test',
        packageRootFilePath: 'test-role-capabilities',
      ),
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: GameLauncher(
          game: game,
          localUserId: 'u-authority',
          localNickname: 'Authority',
        ),
      ),
    );
    await tester.pump();

    final webView = tester.widget<LocalGameWebView>(
      find.byType(LocalGameWebView),
    );
    expect(
      webView.entryPath,
      'index.html?scene=current_scene&mode=touch&mode=keyboard',
    );
    expect(webView.declaredCapabilities, isEmpty);
  });

  testWidgets('landscape game page does not mount a native sidebar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: const _ImmediateOrientationController(),
          previewBuilder: (_) => const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-sidebar')), findsNothing);
    expect(find.byKey(const Key('game-sidebar')), findsNothing);
    expect(find.byKey(GamePage.runtimeKey(0)), findsOneWidget);
    expect(
      tester.getSize(find.byKey(GamePage.gameSurfaceKey)),
      const Size(640, 320),
    );
  });

  testWidgets('refreshes the game library without restarting the app', (
    WidgetTester tester,
  ) async {
    const addedGame = GameSummary(
      id: 'com.playmesh.added',
      name: '新加入的游戏',
      version: '1.0.0',
      description: '刷新后出现',
      minPlayers: 1,
      maxPlayers: 1,
      supportsMultiplayer: false,
      displayModeLabel: '多屏模式',
      displayMode: 'multi_screen',
      orientation: GameOrientation.portrait,
      entry: LocalGameEntry(
        gameEntryPath: 'index.html',
        statusLabel: 'Game SDK 1.0',
      ),
    );
    var refreshCalls = 0;
    final refreshResult = Completer<List<GameSummary>>();
    var indexedGames = _games;
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: _games,
          onRefresh: () async {
            refreshCalls += 1;
            indexedGames = await refreshResult.future;
            return indexedGames;
          },
          onQuery: (_, {required offset, required limit}) {
            final start = offset.clamp(0, indexedGames.length);
            final end = (offset + limit).clamp(start, indexedGames.length);
            return GameLibraryQueryResult(
              games: indexedGames.sublist(start, end),
              total: indexedGames.length,
              offset: start,
              revision: refreshCalls,
              refreshedAt: null,
            );
          },
        ),
      ),
    );

    expect(find.text('新加入的游戏'), findsNothing);
    await tester.tap(find.byTooltip('重新扫描游戏库'));
    await tester.pump();

    expect(refreshCalls, 1);
    expect(find.text('测试游戏'), findsOneWidget);
    expect(find.text('新加入的游戏'), findsNothing);
    expect(
      find.descendant(
        of: find.byTooltip('重新扫描游戏库'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    refreshResult.complete(const [..._games, addedGame]);
    await tester.pumpAndSettle();

    expect(find.text('新加入的游戏'), findsOneWidget);
    expect(find.text('已发现 2 个游戏。'), findsOneWidget);
  });

  testWidgets('windowed developer launch does not request startup fullscreen', (
    WidgetTester tester,
  ) async {
    final orientationController = _RecordingOrientationController();

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: false,
          orientationController: orientationController,
          previewBuilder: (_) => const Text('窗口化开发游戏'),
        ),
      ),
    );
    await tester.pump();

    expect(orientationController.entered, isEmpty);
    expect(find.text('窗口化开发游戏'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(orientationController.exitFullscreenCalls, 1);
    expect(orientationController.restoreCalls, 1);
  });

  testWidgets('requests orientation without blocking WebView and restores it', (
    WidgetTester tester,
  ) async {
    final orientationController = _RecordingOrientationController();

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: orientationController,
          previewBuilder: (_) => const Text('方向就绪后的 WebView'),
        ),
      ),
    );

    expect(orientationController.entered, [GameOrientation.landscape]);
    await tester.pump();
    expect(find.text('方向就绪后的 WebView'), findsOneWidget);

    orientationController.completeEnter();
    await tester.pumpAndSettle();

    expect(find.text('方向就绪后的 WebView'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(orientationController.restoreCalls, 1);
  });

  testWidgets('fullscreen failure is optional and does not block game HTML', (
    WidgetTester tester,
  ) async {
    final orientationController = _RetryOrientationController();

    await tester.pumpWidget(
      localizedTestApp(
        home: GamePage(
          game: _primaryGame,
          enterFullscreenOnLaunch: true,
          orientationController: orientationController,
          previewBuilder: (_) => const Text('Game or controller HTML'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('未能进入全屏，游戏仍可正常游玩'), findsOneWidget);
    expect(find.text('Game or controller HTML'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(orientationController.enterCalls, 2);
    expect(find.text('Game or controller HTML'), findsOneWidget);
  });
}

class _RecordingOrientationController implements GameOrientationController {
  final Completer<void> _enterCompleter = Completer<void>();
  final List<GameOrientation> entered = [];
  int exitFullscreenCalls = 0;
  int restoreCalls = 0;

  void completeEnter() => _enterCompleter.complete();

  @override
  Future<void> enter(GameOrientation orientation) {
    entered.add(orientation);
    return _enterCompleter.future;
  }

  @override
  Future<void> exitFullscreen() async {
    exitFullscreenCalls += 1;
  }

  @override
  Future<void> restore() async {
    restoreCalls += 1;
  }
}

class _ImmediateOrientationController implements GameOrientationController {
  const _ImmediateOrientationController();

  @override
  Future<void> enter(GameOrientation orientation) async {}

  @override
  Future<void> exitFullscreen() async {}

  @override
  Future<void> restore() async {}
}

class _RetryOrientationController implements GameOrientationController {
  int enterCalls = 0;

  @override
  Future<void> enter(GameOrientation orientation) async {
    enterCalls += 1;
    if (enterCalls == 1) {
      throw StateError('fullscreen requires a user gesture');
    }
  }

  @override
  Future<void> exitFullscreen() async {}

  @override
  Future<void> restore() async {}
}

class _FakeStatusProvider implements GoCoreStatusProvider {
  const _FakeStatusProvider();

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatusResult> check() async {
    return GoCoreStatusResult.online(
      GoCoreStatus(
        requestId: 'req-widget',
        status: 'online',
        coreVersion: '0.1.0',
        timestamp: DateTime.utc(2026, 7, 15, 8, 30),
        startedAt: DateTime.utc(2026, 7, 15, 8),
      ),
    );
  }

  @override
  Future<void> close() async {}
}
