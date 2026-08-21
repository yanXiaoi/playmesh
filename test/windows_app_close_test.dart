import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/app.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_status_service.dart';

import 'support/localized_test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeLocalizedTestApp);

  testWidgets('Windows 关闭请求必须确认，取消不会销毁窗口', (tester) async {
    const channel = MethodChannel('window_manager');
    final methodCalls = <MethodCall>[];
    final shutdownEvents = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls.add(call);
          if (call.method == 'close') shutdownEvents.add('close');
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      PlaymeshApp(
        goCoreStatusProvider: const _FakeStatusProvider(),
        games: const [],
        uiBootstrap: localizedTestUiBootstrap(),
        onShutdownStarted: () => shutdownEvents.add('shutdown'),
      ),
    );
    await tester.pumpAndSettle();

    final dynamic appState = tester.state(find.byType(PlaymeshApp));
    appState.onWindowClose();
    appState.onWindowClose();
    await tester.pumpAndSettle();

    expect(find.text('退出 Playmesh？'), findsOneWidget);
    expect(find.text('确认要退出 Playmesh 吗？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认退出'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('退出 Playmesh？'), findsNothing);
    expect(methodCalls.where((call) => call.method == 'close'), isEmpty);
    expect(shutdownEvents, isEmpty);

    appState.onWindowClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认退出'));
    await tester.pumpAndSettle();

    final closeCalls = methodCalls
        .where(
          (call) => call.method == 'setPreventClose' || call.method == 'close',
        )
        .toList(growable: false);
    expect(closeCalls.map((call) => call.method), ['setPreventClose', 'close']);
    expect(closeCalls.first.arguments, {'isPreventClose': false});
    expect(shutdownEvents, ['shutdown', 'close']);
  });
}

class _FakeStatusProvider implements GoCoreStatusProvider {
  const _FakeStatusProvider();

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatusResult> check() async {
    return GoCoreStatusResult.online(
      GoCoreStatus(
        requestId: 'req-window-close',
        status: 'online',
        coreVersion: '0.1.0',
        timestamp: DateTime.utc(2026, 8, 10, 8, 30),
        startedAt: DateTime.utc(2026, 8, 10, 8),
      ),
    );
  }

  @override
  Future<void> close() async {}
}
