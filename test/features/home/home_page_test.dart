import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_page.dart';
import 'package:playmesh/features/game/game_invitation_scanner_page.dart';
import 'package:playmesh/features/game/join_game_page.dart';
import 'package:playmesh/features/developer/game_creation_page.dart';
import 'package:playmesh/features/games/game_library_page.dart';
import 'package:playmesh/features/home/home_page.dart';
import 'package:playmesh/features/profile/profile_page.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';
import 'package:playmesh/models/user_profile.dart';

import '../../support/localized_test_app.dart';

const _user = UserProfile(userId: 'u_home', nickname: '银河玩家');

GameSummary _game({
  required String id,
  required String name,
  DateTime? lastOpenedAt,
  bool multiplayer = true,
  String displayMode = 'multi_screen',
  GameOrientation orientation = GameOrientation.landscape,
  String? manifestError,
}) => GameSummary(
  id: id,
  name: name,
  version: '1.2.0',
  author: 'Playmesh Studio',
  lastOpenedAt: lastOpenedAt,
  launchCount: lastOpenedAt == null ? 0 : 1,
  description: '主页快捷入口不应显示这段简介',
  minPlayers: multiplayer ? 2 : 1,
  maxPlayers: multiplayer ? 4 : 1,
  supportsMultiplayer: multiplayer,
  displayModeLabel: displayMode,
  displayMode: displayMode,
  orientation: orientation,
  manifestError: manifestError,
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('首页把游戏库最近游戏放在资料卡下并直接启动游戏', (tester) async {
    final fallback = _game(id: 'fallback', name: '未启动补位');
    final oldest = _game(
      id: 'oldest',
      name: '较早游戏',
      lastOpenedAt: DateTime.utc(2026, 7, 1),
    );
    final latest = _game(
      id: 'latest',
      name: '最新游戏',
      lastOpenedAt: DateTime.utc(2026, 7, 3),
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.portrait,
    );
    final middle = _game(
      id: 'middle',
      name: '中间游戏',
      lastOpenedAt: DateTime.utc(2026, 7, 2),
    );
    GameLaunchArguments? launched;

    await tester.pumpWidget(
      localizedTestApp(
        home: HomePage(user: _user, games: [fallback, oldest, latest, middle]),
        routes: {
          GameLibraryPage.routeName: (_) =>
              const Scaffold(body: Text('LOCAL_LIBRARY_ROUTE')),
        },
        onGenerateRoute: (settings) {
          if (settings.name != GamePage.routeName) return null;
          launched = settings.arguments! as GameLaunchArguments;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('DIRECT_GAME_ROUTE')),
          );
        },
      ),
    );

    final profileBottom = tester
        .getBottomLeft(find.byKey(HomePage.profileHeroKey))
        .dy;
    final libraryTop = tester.getTopLeft(find.text('游戏库－最近游戏')).dy;
    final joinTop = tester.getTopLeft(find.text('加入对局')).dy;
    expect(profileBottom, lessThan(libraryTop));
    expect(libraryTop, lessThan(joinTop));

    expect(find.byKey(HomePage.gameQuickLaunchKey(latest.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(middle.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(oldest.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(fallback.id)), findsNothing);
    expect(find.text('主页快捷入口不应显示这段简介'), findsNothing);
    expect(find.text('发布者：Playmesh Studio'), findsNWidgets(3));
    expect(find.textContaining('v1.2.0'), findsNWidgets(3));
    expect(find.textContaining('单屏多人'), findsOneWidget);
    expect(find.textContaining('竖屏'), findsOneWidget);
    expect(find.byKey(HomePage.scanJoinKey), findsOneWidget);
    expect(find.byKey(HomePage.githubKey), findsOneWidget);
    expect(find.byTooltip('GitHub 开源仓库'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);

    await tester.tap(find.byKey(HomePage.gameQuickLaunchKey(latest.id)));
    await tester.pumpAndSettle();
    expect(find.text('DIRECT_GAME_ROUTE'), findsOneWidget);
    expect(launched?.game.id, latest.id);
    expect(launched?.enterFullscreenOnLaunch, isTrue);
  });

  testWidgets('最近游戏不足三项时按游戏库顺序补位且查看全部进入游戏库', (tester) async {
    final first = _game(id: 'first', name: '补位一');
    final recent = _game(
      id: 'recent',
      name: '最近启动',
      lastOpenedAt: DateTime.utc(2026, 7, 5),
    );
    final second = _game(id: 'second', name: '补位二');
    final excluded = _game(id: 'excluded', name: '第四项');

    await tester.pumpWidget(
      localizedTestApp(
        home: HomePage(user: _user, games: [first, recent, second, excluded]),
        routes: {
          GameLibraryPage.routeName: (_) =>
              const Scaffold(body: Text('LOCAL_LIBRARY_ROUTE')),
        },
      ),
    );

    expect(find.byKey(HomePage.gameQuickLaunchKey(recent.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(first.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(second.id)), findsOneWidget);
    expect(find.byKey(HomePage.gameQuickLaunchKey(excluded.id)), findsNothing);

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('LOCAL_LIBRARY_ROUTE'), findsOneWidget);
  });

  testWidgets('待修复包不会进入首页快捷启动路径', (tester) async {
    final broken = _game(
      id: 'broken',
      name: '待修复游戏',
      lastOpenedAt: DateTime.utc(2026, 7, 6),
      manifestError: 'main.json 缺少 entries.game',
    );
    final runnable = _game(id: 'runnable', name: '可运行游戏');

    await tester.pumpWidget(
      localizedTestApp(
        home: HomePage(user: _user, games: [broken, runnable]),
      ),
    );

    expect(find.byKey(HomePage.gameQuickLaunchKey(broken.id)), findsNothing);
    expect(
      find.byKey(HomePage.gameQuickLaunchKey(runnable.id)),
      findsOneWidget,
    );
  });

  testWidgets('首页在 320dp 保持三项主入口和右上角扫码、GitHub、设置', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      localizedTestApp(
        home: HomePage(
          user: _user,
          games: [_game(id: 'mobile', name: '移动端游戏')],
        ),
      ),
    );

    expect(find.text('游戏库－最近游戏'), findsOneWidget);
    expect(find.text('加入对局'), findsOneWidget);
    await tester.ensureVisible(find.text('在线游戏库'));
    expect(find.text('在线游戏库'), findsOneWidget);
    await tester.ensureVisible(find.byKey(HomePage.createGameKey));
    expect(find.text('制作游戏'), findsOneWidget);
    expect(find.byKey(HomePage.scanJoinKey), findsOneWidget);
    expect(find.byKey(HomePage.githubKey), findsOneWidget);
    expect(find.byTooltip('GitHub 开源仓库'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('制作游戏入口位于主操作下方并进入制作页', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: const HomePage(user: _user),
        routes: {
          GameCreationPage.routeName: (_) =>
              const Scaffold(body: Text('CREATE_GAME_ROUTE')),
        },
      ),
    );

    final joinTop = tester.getTopLeft(find.text('加入对局')).dy;
    final createTop = tester.getTopLeft(find.text('制作游戏')).dy;
    expect(createTop, greaterThan(joinTop));

    await tester.drag(find.byType(ListView), const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(find.text('制作游戏'));
    await tester.pumpAndSettle();
    expect(find.text('CREATE_GAME_ROUTE'), findsOneWidget);
  });

  testWidgets('主页 GitHub 图标使用外部浏览器打开开源仓库', (tester) async {
    Uri? openedUri;
    await tester.pumpWidget(
      localizedTestApp(
        home: HomePage(
          user: _user,
          externalUrlLauncher: (uri) async {
            openedUri = uri;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(HomePage.githubKey));
    await tester.pump();

    expect(openedUri, HomePage.githubRepositoryUri);
  });

  testWidgets('资料大卡不可点击，只有身份小卡进入资料页', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: const HomePage(user: _user),
        routes: {
          ProfilePage.routeName: (_) =>
              const Scaffold(body: Text('PROFILE_ROUTE')),
        },
      ),
    );

    await tester.tap(find.text('让每块屏幕一起玩'));
    await tester.pumpAndSettle();
    expect(find.text('PROFILE_ROUTE'), findsNothing);

    await tester.tap(find.byKey(HomePage.profileIdentityKey));
    await tester.pumpAndSettle();
    expect(find.text('PROFILE_ROUTE'), findsOneWidget);
  });

  testWidgets('右上角扫码直接压入相机扫码路由', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final observer = _RecordingNavigatorObserver();
    try {
      await tester.pumpWidget(
        localizedTestApp(
          home: const HomePage(user: _user),
          navigatorObservers: [observer],
        ),
      );
      observer.lastPushedName = null;

      await tester.tap(find.byKey(HomePage.scanJoinKey));

      expect(observer.lastPushedName, GameInvitationScannerPage.routeName);
      expect(observer.lastPushedName, isNot(JoinGamePage.routeName));
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  String? lastPushedName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPushedName = route.settings.name;
  }
}
