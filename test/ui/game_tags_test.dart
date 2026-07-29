import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/ui/game_tags.dart';

import '../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('renders every tag in one horizontally scrollable rail', (
    tester,
  ) async {
    const tags = ['本地多人', '派对游戏', '合作挑战', '家庭同乐', '快速对局'];

    await tester.pumpWidget(
      localizedTestApp(
        home: const Scaffold(
          body: Center(
            child: SizedBox(width: 210, child: GameTagList(tags: tags)),
          ),
        ),
      ),
    );

    for (final tag in tags) {
      expect(find.text(tag), findsOneWidget);
    }
    final rail = find.byType(SingleChildScrollView);
    expect(rail, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(rail).scrollDirection,
      Axis.horizontal,
    );

    final initialX = tester.getTopLeft(find.text(tags.last)).dx;
    await tester.drag(rail, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text(tags.last)).dx, lessThan(initialX));
  });
}
