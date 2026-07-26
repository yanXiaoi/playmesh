import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/games/game_detail_page.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
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
    entry: LocalGameEntry(assetPath: 'app/index.html', statusLabel: '可运行'),
  );

  test('导出包使用游戏名称-v版本.zip', () {
    expect(gamePackageExportFileName(game), '欢乐派对-v1.2.3.zip');
    expect(
      gamePackageExportFileName(
        const GameSummary(
          id: 'com.example.unsafe',
          name: '派对/问答:* ',
          version: '2.0.0',
          description: '',
          minPlayers: 1,
          maxPlayers: 1,
          supportsMultiplayer: false,
          displayModeLabel: '单屏',
          displayMode: 'multi_screen',
          orientation: GameOrientation.portrait,
          entry: LocalGameEntry(
            assetPath: 'app/index.html',
            statusLabel: '可运行',
          ),
        ),
      ),
      '派对_问答__-v2.0.0.zip',
    );
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
      MaterialApp(
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
    final uploadedAt = _formatExpectedTimestamp(game.lastModifiedAt!);
    final openedAt = _formatExpectedTimestamp(game.lastOpenedAt!);
    expect(find.text(uploadedAt), findsOneWidget);
    expect(find.text(openedAt), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(uploadedAt),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('缺省上传元数据显示为佚名和无', (tester) async {
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
      entry: LocalGameEntry(assetPath: 'app/index.html', statusLabel: '待修复'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailPage(game: legacy, onDelete: (_) async {}),
      ),
    );

    expect(find.text('佚名'), findsOneWidget);
    expect(find.text('无'), findsNWidgets(2));
  });
}

String _formatExpectedTimestamp(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}:'
      '${twoDigits(local.second)}';
}
