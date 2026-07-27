import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/ui/playmesh_ui.dart';

void main() {
  test('交互控件的遥控器焦点态比悬浮态更醒目', () {
    final theme = PlaymeshTheme.light();
    final focused = <WidgetState>{WidgetState.focused};
    final hovered = <WidgetState>{WidgetState.hovered};

    final filled = theme.filledButtonTheme.style!;
    expect(
      filled.overlayColor!.resolve(focused)!.a,
      greaterThan(filled.overlayColor!.resolve(hovered)!.a),
    );
    expect(filled.side!.resolve(focused)!.width, 3);
    expect(filled.elevation!.resolve(focused), greaterThan(0));

    final outlined = theme.outlinedButtonTheme.style!;
    expect(outlined.backgroundColor!.resolve(focused), isNotNull);
    expect(
      outlined.backgroundColor!.resolve(focused),
      isNot(outlined.backgroundColor!.resolve(hovered)),
    );

    final icon = theme.iconButtonTheme.style!;
    expect(icon.backgroundColor!.resolve(focused), isNotNull);
    expect(icon.side!.resolve(focused)!.width, 3);
  });

  testWidgets('返回动画立即移开当前页面并露出上一页', (tester) async {
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
    final slides = tester.widgetList<SlideTransition>(
      find.byType(SlideTransition),
    );
    expect(slides, isNotEmpty);
    expect(
      slides.any((slide) => slide.position.value.dx > 0.1),
      isTrue,
      reason: '返回首帧期间当前页面应明显移开，不能持续遮挡上一页。',
    );
    await tester.pumpAndSettle();
  });
}
