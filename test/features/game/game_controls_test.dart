import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_controls.dart';
import 'package:playmesh/ui/playmesh_ui.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('扫码加入工具区与主机一致但不提供分享或退出游戏', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
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
                onOpenLogs: () {},
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
    expect(find.byTooltip('运行日志'), findsOneWidget);
    expect(find.byTooltip('隐藏性能信息'), findsNothing);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(find.byTooltip('二维码与链接'), findsNothing);
    expect(find.byTooltip('退出游戏'), findsNothing);

    await tester.tap(find.byTooltip('更多游戏操作'));
    await tester.pumpAndSettle();
    final menu = tester.widget<Material>(
      find.byKey(const Key('game-action-menu')),
    );
    expect(
      menu.color,
      Theme.of(
        tester.element(find.byKey(const Key('game-action-menu'))),
      ).colorScheme.surface,
    );
    expect(find.text('游戏信息'), findsOneWidget);
    expect(find.text('隐藏性能信息'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
  });

  testWidgets('分享入口作为主机工具区一级按钮显示', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
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

  testWidgets('运行时重置后工具区和二级菜单恢复收起', (tester) async {
    var resetKey = 0;
    late StateSetter update;
    await tester.pumpWidget(
      localizedTestApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: Stack(
                children: [
                  GameToolDock(
                    resetKey: resetKey,
                    backTooltip: '返回',
                    onBack: () {},
                    onReload: () {},
                    showPerformance: false,
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
            );
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip('展开游戏工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多游戏操作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-action-menu')), findsOneWidget);

    update(() => resetKey += 1);
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开游戏工具'), findsOneWidget);
    expect(find.byKey(const Key('game-action-menu')), findsNothing);
  });

  testWidgets('F10 打开工具且返回键依次关闭菜单和工具', (tester) async {
    final controller = GameToolDockController();
    var pageBackCount = 0;
    var toolBackCount = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: GameRuntimeShortcutScope(
          controller: controller,
          onBack: () {
            if (!controller.closeTopLayer()) pageBackCount += 1;
          },
          onOpenTools: controller.openTools,
          onMoveTools: controller.beginMoveMode,
          child: Scaffold(
            body: Stack(
              children: [
                GameToolDock(
                  controller: controller,
                  backTooltip: '返回',
                  onBack: () => toolBackCount += 1,
                  onReload: () {},
                  showPerformance: false,
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
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f10);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起游戏工具'), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-tools-collapse',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-tools-back',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(toolBackCount, 1);
    expect(find.byTooltip('展开游戏工具'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f10);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多游戏操作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-action-menu')), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-tools-menu-0',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-action-menu')), findsNothing);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-tools-more',
    );
    expect(pageBackCount, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开游戏工具'), findsOneWidget);
    expect(pageBackCount, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(pageBackCount, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起游戏工具'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开游戏工具'), findsOneWidget);
  });

  testWidgets('SDK 显示工具后自动聚焦，任一操作完成后隐藏整个工具', (tester) async {
    final controller = GameToolDockController();
    var reloadCount = 0;
    var infoCount = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: Stack(
            children: [
              GameToolDock(
                controller: controller,
                backTooltip: '返回',
                onBack: () {},
                onReload: () => reloadCount += 1,
                showPerformance: false,
                onTogglePerformance: () {},
                onEnterFullscreen: () {},
                onExitFullscreen: () {},
                secondaryActions: [
                  GameToolAction(
                    icon: Icons.info_outline,
                    label: '游戏信息',
                    onPressed: () => infoCount += 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    controller.showFromSdk();
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起游戏工具'), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-tools-collapse',
    );

    await tester.tap(find.byKey(const Key('game-tool-reload')));
    await tester.pumpAndSettle();
    expect(reloadCount, 1);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    expect(find.byKey(const Key('game-tool-collapse')), findsNothing);

    controller.showFromSdk();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-tool-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('游戏信息'));
    await tester.pumpAndSettle();
    expect(infoCount, 1);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);

    controller.showFromSdk();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-tool-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);

    controller.showFromSdk();
    await tester.pumpAndSettle();
    controller.hideFromSdk();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
  });

  testWidgets('悬浮球移动模式可还原或确认且不会误展开菜单', (tester) async {
    final controller = GameToolDockController();
    await tester.pumpWidget(
      localizedTestApp(
        home: GameRuntimeShortcutScope(
          controller: controller,
          onBack: controller.closeTopLayer,
          onOpenTools: controller.openTools,
          onMoveTools: controller.beginMoveMode,
          child: Scaffold(
            body: Stack(
              children: [
                GameToolDock(
                  controller: controller,
                  backTooltip: '返回',
                  onBack: () {},
                  onReload: () {},
                  showPerformance: false,
                  onTogglePerformance: () {},
                  onEnterFullscreen: () {},
                  onExitFullscreen: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final handle = find.byKey(const Key('game-tool-dock-handle'));
    final initial = tester.getTopLeft(handle);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(controller.isMoving, isTrue);
    await tester.tap(handle);
    await tester.pump();
    expect(controller.isMoving, isTrue);
    expect(find.byTooltip('收起游戏工具'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(tester.getTopLeft(handle).dx, lessThan(initial.dx));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isMoving, isFalse);
    expect(tester.getTopLeft(handle), initial);
    expect(find.byTooltip('展开游戏工具'), findsOneWidget);

    controller.beginMoveMode();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.isMoving, isFalse);
    expect(tester.getTopLeft(handle).dx, lessThan(initial.dx));
    expect(find.byTooltip('收起游戏工具'), findsNothing);
  });

  testWidgets('低高度运行面把展开工具横向排列', (tester) async {
    tester.view.physicalSize = const Size(760, 250);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: Stack(
            children: [
              GameToolDock(
                backTooltip: '返回',
                onBack: () {},
                onReload: () {},
                showPerformance: false,
                onTogglePerformance: () {},
                onEnterFullscreen: () {},
                onExitFullscreen: () {},
                onShare: () {},
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

    final scrollViews = tester.widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(
      scrollViews.any(
        (scrollView) => scrollView.scrollDirection == Axis.horizontal,
      ),
      isTrue,
    );
  });

  testWidgets('日志层只翻译固定外壳并原样显示运行时日志正文', (tester) async {
    const rawMessage =
        '日志正文 Ω / platform.game.logs.empty / User Source API Value';
    await tester.pumpWidget(
      localizedTestApp(
        home: GameRuntimeLogOverlay(
          logs: const [
            {
              'timestamp': 1785060000000,
              'source': 'game',
              'level': 'warn',
              'eventType': 'console',
              'message': rawMessage,
              'stack': 'RawStack: developer-value',
            },
          ],
          onClear: _noop,
          onClose: _noop,
        ),
      ),
    );

    expect(find.text('运行日志'), findsOneWidget);
    expect(find.textContaining(rawMessage), findsOneWidget);
    expect(find.textContaining('RawStack: developer-value'), findsOneWidget);
  });

  testWidgets('日间主题运行日志文字保持可读对比度', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: Theme(
          data: PlaymeshTheme.light(),
          child: GameRuntimeLogOverlay(
            logs: const [
              {'level': 'error', 'message': 'ERROR_LOG'},
              {'level': 'warn', 'message': 'WARN_LOG'},
              {'level': 'debug', 'message': 'DEBUG_LOG'},
              {'level': 'info', 'message': 'INFO_LOG'},
            ],
            onClear: _noop,
            onClose: _noop,
          ),
        ),
      ),
    );

    final surface = PlaymeshTheme.light().colorScheme.surface;
    for (final marker in const [
      'ERROR_LOG',
      'WARN_LOG',
      'DEBUG_LOG',
      'INFO_LOG',
    ]) {
      final text = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText && (widget.data ?? '').contains(marker),
        ),
      );
      expect(
        _contrastRatio(text.style!.color!, surface),
        greaterThanOrEqualTo(4.5),
        reason: '$marker 在日间主题下需要满足正文文字对比度。',
      );
    }
  });
}

void _noop() {}

double _contrastRatio(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground
      : background;
  final darker = identical(lighter, foreground) ? background : foreground;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
