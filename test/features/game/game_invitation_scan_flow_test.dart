import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_invitation_scan_flow.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('扫码返回后在邀请预检开始前显示阻止交互的统一加入遮罩', (tester) async {
    final preparation = Completer<void>();
    var operationStarted = false;

    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('start-scan-preparation'),
              onPressed: () {
                unawaited(
                  runGameInvitationScanPreparation<void>(context, () {
                    operationStarted = true;
                    return preparation.future;
                  }),
                );
              },
              child: const Text('开始预检'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('start-scan-preparation')));
    expect(operationStarted, isFalse, reason: '对话框绘制前不能先执行耗时预检');
    await tester.pump();

    expect(
      find.byKey(gameInvitationScanJoiningOverlayKey),
      findsOneWidget,
      reason: '扫码页退出后的第一帧必须先显示遮罩，不能先执行耗时预检',
    );
    expect(find.text('正在加入…'), findsOneWidget);
    expect(
      tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .any((barrier) => !barrier.dismissible),
      isTrue,
    );
    expect(find.byType(PopScope<void>), findsOneWidget);
    expect(operationStarted, isFalse, reason: '预检必须等待遮罩至少绘制一帧');

    await tester.pump();
    expect(operationStarted, isTrue, reason: '遮罩首帧完成后才开始预检');
    expect(find.byKey(gameInvitationScanJoiningOverlayKey), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(gameInvitationScanJoiningOverlayKey),
      findsOneWidget,
      reason: '加入准备期间系统返回也不能绕过阻塞遮罩',
    );

    preparation.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(gameInvitationScanJoiningOverlayKey), findsNothing);
  });
}
