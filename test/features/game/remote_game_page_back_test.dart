import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/remote_game_page.dart';

void main() {
  testWidgets('Android 加入端把全面屏返回转交 App SDK 菜单', (tester) async {
    var backCalls = 0;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => RemoteGamePage(
            entryUri: Uri.parse('http://127.0.0.1/game'),
            userId: 'u-joiner',
            nickname: '加入玩家',
            prepareRuntime: false,
            nativeBackHandler: () async {
              backCalls += 1;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(backCalls, 1);
    expect(find.byType(RemoteGamePage), findsOneWidget);
  });

  testWidgets('Windows 加入端在 WebView 外也把 Esc 转交 App SDK 菜单', (tester) async {
    var backCalls = 0;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => RemoteGamePage(
            entryUri: Uri.parse('http://127.0.0.1/game'),
            userId: 'u-joiner',
            nickname: '加入玩家',
            prepareRuntime: false,
            nativeBackHandler: () async {
              backCalls += 1;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(backCalls, 1);
    expect(find.byType(RemoteGamePage), findsOneWidget);
  });
}
