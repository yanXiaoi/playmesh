import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_controls.dart';
import 'package:playmesh/ui/playmesh_ui.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('游戏运行面初始没有悬浮入口且侧边栏不可交互', (tester) async {
    final controller = GameSidebarController();
    await tester.pumpWidget(
      localizedTestApp(home: _sidebarSurface(controller: controller)),
    );

    expect(controller.isOpen, isFalse);
    expect(find.byKey(const Key('game-tool-dock-handle')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AnimatedOpacity && widget.opacity == 0,
      ),
      findsOneWidget,
    );
  });

  testWidgets('侧边栏把全部工具显示为图标加文字并由继续游戏关闭', (tester) async {
    final controller = GameSidebarController();
    var continueCount = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: _sidebarSurface(
          controller: controller,
          onContinue: () => continueCount += 1,
          showPerformance: true,
          onShare: () {},
          onOpenLogs: () {},
          secondaryActions: [
            GameSidebarAction(
              icon: Icons.info_outline,
              label: '游戏信息',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    controller.open();
    await tester.pumpAndSettle();

    expect(find.text('游戏菜单'), findsOneWidget);
    for (final label in const [
      '继续游戏',
      '刷新游戏',
      '二维码与链接',
      '运行日志',
      '进入全屏',
      '退出全屏',
      '游戏信息',
      '隐藏性能信息',
      '返回游戏详情',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      tester.widgetList<Icon>(
        find.descendant(
          of: find.byKey(const Key('game-sidebar')),
          matching: find.byType(Icon),
        ),
      ),
      isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('game-sidebar-continue')));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(continueCount, 1);

    controller.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-sidebar-dismiss-area')));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(continueCount, 2);
  });

  testWidgets('返回键只打开或关闭侧边栏，侧边栏退出项目可以离开游戏', (tester) async {
    final controller = GameSidebarController();
    var exitCount = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: GameRuntimeShortcutScope(
          controller: controller,
          onBack: () {
            if (!controller.closeTopLayer()) controller.open();
          },
          onOpenSidebar: controller.open,
          child: _sidebarSurface(
            controller: controller,
            onBack: () => exitCount += 1,
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    expect(exitCount, 0);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-sidebar-continue',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(exitCount, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f10);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-sidebar-exit')));
    await tester.pumpAndSettle();
    expect(exitCount, 1);
    expect(controller.isOpen, isFalse);
  });

  testWidgets('SDK 显示侧边栏后聚焦继续游戏且实际操作后关闭', (tester) async {
    final controller = GameSidebarController();
    var reloadCount = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: _sidebarSurface(
          controller: controller,
          onReload: () => reloadCount += 1,
        ),
      ),
    );

    expect(controller.showFromSdk(), isTrue);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'game-sidebar-continue',
    );

    await tester.tap(find.byKey(const Key('game-sidebar-reload')));
    await tester.pumpAndSettle();
    expect(reloadCount, 1);
    expect(controller.isOpen, isFalse);

    controller.showFromSdk();
    await tester.pumpAndSettle();
    expect(controller.hideFromSdk(), isTrue);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
  });

  testWidgets('运行时重置会关闭已经打开的侧边栏', (tester) async {
    final controller = GameSidebarController();
    var resetKey = 0;
    late StateSetter update;
    await tester.pumpWidget(
      localizedTestApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _sidebarSurface(controller: controller, resetKey: resetKey);
          },
        ),
      ),
    );

    controller.open();
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);

    update(() => resetKey += 1);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
  });

  testWidgets('侧边栏在竖屏与横屏使用受限自适应宽度', (tester) async {
    final controller = GameSidebarController();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      localizedTestApp(home: _sidebarSurface(controller: controller)),
    );
    controller.open();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('game-sidebar'))).width, 343.2);

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('game-sidebar'))).width,
      closeTo(388.24, 0.01),
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

Widget _sidebarSurface({
  required GameSidebarController controller,
  Object? resetKey,
  VoidCallback? onBack,
  VoidCallback? onContinue,
  VoidCallback? onReload,
  bool showPerformance = false,
  VoidCallback? onShare,
  VoidCallback? onOpenLogs,
  List<GameSidebarAction> secondaryActions = const [],
}) {
  return Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        GameSidebar(
          controller: controller,
          resetKey: resetKey,
          backLabel: '返回游戏详情',
          onContinue: onContinue ?? _noop,
          onBack: onBack ?? _noop,
          onReload: onReload ?? _noop,
          showPerformance: showPerformance,
          onTogglePerformance: _noop,
          onEnterFullscreen: _noop,
          onExitFullscreen: _noop,
          onShare: onShare,
          onOpenLogs: onOpenLogs,
          secondaryActions: secondaryActions,
        ),
      ],
    ),
  );
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
