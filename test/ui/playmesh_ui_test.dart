import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/ui/playmesh_ui.dart';

void main() {
  testWidgets('返回页面使用平移而不做整屏透明合成', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: PlaymeshTheme.light(),
        home: const Scaffold(body: Text('首页')),
      ),
    );

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(FadeTransition), findsWidgets);
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('首页'), findsOneWidget);
    expect(find.byType(FractionalTranslation), findsWidgets);
    expect(find.byType(FadeTransition), findsNothing);
    await tester.pumpAndSettle();
  });
}
