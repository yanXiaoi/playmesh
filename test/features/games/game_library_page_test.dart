import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/games/game_library_page.dart';

void main() {
  testWidgets('本地游戏库内提供唯一的在线游戏库入口', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GameLibraryPage(
          games: const [],
          onRefresh: () async => const [],
          onOpenOnline: () => opened = true,
        ),
      ),
    );

    expect(find.byTooltip('在线游戏库'), findsOneWidget);
    await tester.tap(find.byTooltip('在线游戏库'));
    expect(opened, isTrue);
  });
}
