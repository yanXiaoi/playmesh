import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_controls.dart';

void main() {
  testWidgets('扫码加入工具区与主机一致但不提供分享或退出游戏', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.white),
              GameToolDock(
                backTooltip: '返回加入页面',
                onBack: () {},
                onReload: () {},
                showPerformance: true,
                onTogglePerformance: () {},
                onEnterFullscreen: () {},
                onExitFullscreen: () {},
                secondaryActions: [
                  GameToolAction(
                    icon: Icons.info_outline,
                    label: '游戏信息',
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('展开游戏工具'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('返回加入页面'), findsOneWidget);
    expect(find.byTooltip('刷新游戏'), findsOneWidget);
    expect(find.byTooltip('隐藏性能信息'), findsOneWidget);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(find.byTooltip('二维码与链接'), findsNothing);
    expect(find.byTooltip('退出游戏'), findsNothing);

    await tester.tap(find.byTooltip('更多游戏操作'));
    await tester.pumpAndSettle();
    final menu = tester.widget<Material>(
      find.byKey(const Key('game-action-menu')),
    );
    expect(menu.color, const Color(0xff20242b));
    expect(find.text('游戏信息'), findsOneWidget);
  });

  testWidgets('分享入口作为主机工具区一级按钮显示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GameToolDock(
                backTooltip: '返回游戏详情',
                onBack: () {},
                onReload: () {},
                showPerformance: true,
                onTogglePerformance: () {},
                onEnterFullscreen: () {},
                onExitFullscreen: () {},
                onShare: () {},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('展开游戏工具'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('二维码与链接'), findsOneWidget);
  });
}
