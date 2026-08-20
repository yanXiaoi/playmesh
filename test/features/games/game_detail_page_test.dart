import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_page.dart';
import 'package:playmesh/features/games/game_detail_page.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  final game = GameSummary(
    id: 'com.example.party',
    name: '欢乐派对',
    version: '1.2.3',
    author: 'Test Author',
    lastModifiedAt: DateTime.utc(2026, 7, 24, 8, 30),
    lastOpenedAt: DateTime.utc(2026, 7, 24, 9, 30),
    sdkVersion: '2.2.0',
    appSdkVersion: '2.1.0',
    description: '测试游戏',
    minPlayers: 1,
    maxPlayers: 4,
    supportsMultiplayer: true,
    displayModeLabel: '多屏',
    displayMode: 'multi_screen',
    orientation: GameOrientation.landscape,
    tags: const ['派对', '本地多人'],
    entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: '可运行'),
  );

  testWidgets('从游戏库详情启动时默认进入全屏', (tester) async {
    GameLaunchArguments? launched;
    await tester.pumpWidget(
      localizedTestApp(
        home: GameDetailPage(game: game, onDelete: (_) async {}),
        onGenerateRoute: (settings) {
          if (settings.name != GamePage.routeName) return null;
          launched = settings.arguments! as GameLaunchArguments;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('GAME_ROUTE')),
          );
        },
      ),
    );

    expect(find.text('导出游戏包'), findsNothing);
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    await tester.tap(find.byKey(const ValueKey('game-detail-start')));
    await tester.pumpAndSettle();

    expect(find.text('GAME_ROUTE'), findsOneWidget);
    expect(launched?.game.id, game.id);
    expect(launched?.enterFullscreenOnLaunch, isTrue);
  });

  testWidgets('点击游戏 ID 会复制并显示反馈', (tester) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: GameDetailPage(game: game, onDelete: (_) async {}),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('copy-game-id')));
    await tester.pump();

    expect(clipboardText, game.id);
    expect(find.text('Test Author'), findsOneWidget);
    expect(find.text('Game SDK'), findsNothing);
    expect(find.text('2.2.0'), findsNothing);
    expect(find.text('运行入口'), findsNothing);
    expect(find.text('2.1.0'), findsOneWidget);
    expect(find.text('游戏 ID 已复制'), findsOneWidget);
    expect(find.text('最近打开'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('派对'), findsOneWidget);
    expect(find.text('本地多人'), findsOneWidget);
    final detailContext = tester.element(find.byType(GameDetailPage));
    final uploadedAt = _formatExpectedTimestamp(
      detailContext,
      game.lastModifiedAt!,
    );
    final openedAt = _formatExpectedTimestamp(
      detailContext,
      game.lastOpenedAt!,
    );
    expect(find.text(uploadedAt), findsOneWidget);
    expect(find.text(openedAt), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(uploadedAt),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byElementPredicate(
          (element) =>
              identical(element, FocusManager.instance.primaryFocus?.context),
        ),
        matching: find.byKey(const ValueKey('game-detail-start')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('损坏清单使用 App 文案且保留非空动态简介', (tester) async {
    const repairGame = GameSummary(
      id: 'com.example.repair',
      name: 'Dynamic game name',
      version: '0.0.0',
      manifestError: 'raw parser error',
      description: '',
      minPlayers: 1,
      maxPlayers: 1,
      supportsMultiplayer: false,
      displayModeLabel: 'multi_screen',
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      entry: LocalGameEntry(
        gameEntryPath: 'index.html',
        statusLabel: 'manifest_repair_required',
      ),
    );

    Future<void> pump(GameSummary value) => tester.pumpWidget(
      localizedTestApp(
        locale: const Locale('en', 'US'),
        home: GameDetailPage(game: value, onDelete: (_) async {}),
      ),
    );

    await pump(repairGame);
    expect(
      find.text(
        'This package has an invalid main.json. '
        'Open Developer Workspace to repair it.',
      ),
      findsOneWidget,
    );
    expect(find.text('raw parser error'), findsNothing);

    const rawDescription = 'API description / 原样';
    await pump(
      const GameSummary(
        id: 'com.example.repair-with-description',
        name: 'Dynamic game name',
        version: '0.0.0',
        manifestError: 'raw parser error',
        description: rawDescription,
        minPlayers: 1,
        maxPlayers: 1,
        supportsMultiplayer: false,
        displayModeLabel: 'multi_screen',
        displayMode: 'multi_screen',
        orientation: GameOrientation.landscape,
        entry: LocalGameEntry(
          gameEntryPath: 'index.html',
          statusLabel: 'manifest_repair_required',
        ),
      ),
    );
    expect(find.text(rawDescription), findsOneWidget);
  });

  testWidgets('缺省上传元数据显示本地化未知发布者和无', (tester) async {
    const legacy = GameSummary(
      id: 'com.example.legacy',
      name: '旧游戏',
      version: '1.0.0',
      description: '',
      minPlayers: 1,
      maxPlayers: 1,
      supportsMultiplayer: false,
      displayModeLabel: '多屏',
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: '待修复'),
    );
    await tester.pumpWidget(
      localizedTestApp(
        home: GameDetailPage(game: legacy, onDelete: (_) async {}),
      ),
    );

    expect(find.text('未知发布者'), findsOneWidget);
    expect(find.text('无'), findsNWidgets(2));
  });
}

String _formatExpectedTimestamp(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}
