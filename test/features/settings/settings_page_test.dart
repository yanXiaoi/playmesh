import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/developer/developer_channel.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_status_service.dart';
import 'package:playmesh/features/settings/settings_page.dart';
import 'package:playmesh/ui/playmesh_ui.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('shows online Core version and request ID', (tester) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-online')),
    ]);

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(find.text('Playmesh 3.1.0'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Playmesh 3.1.0')).dy,
      lessThan(tester.getTopLeft(find.text('Core 0.1.0')).dy),
    );
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('Core 0.1.0'), findsOneWidget);
    expect(find.text('req-settings-online'), findsOneWidget);
  });

  testWidgets('refreshes from offline to online', (tester) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.offline(
        message: '无法连接 Go Core，请确认服务已启动。',
        requestId: 'req-settings-offline',
      ),
      GoCoreStatusResult.online(_onlineStatus('req-settings-recovered')),
    ]);

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(find.text('离线'), findsOneWidget);
    expect(find.text('req-settings-offline'), findsOneWidget);

    await tester.tap(find.byTooltip('重新检查 Go Core'));
    await _pumpAsync(tester);

    expect(find.text('在线'), findsOneWidget);
    expect(find.text('req-settings-recovered'), findsOneWidget);
    expect(provider.checkCalls, 2);
  });

  testWidgets('shows a protocol error separately from offline', (tester) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.error(
        message: 'Go Core 返回了无法识别的状态。',
        requestId: 'req-settings-error',
      ),
    ]);

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(find.text('错误'), findsOneWidget);
    expect(find.text('Go Core 返回了无法识别的状态。'), findsOneWidget);
  });

  testWidgets('enables developer mode with default port and custom token', (
    tester,
  ) async {
    final statusProvider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-dev-1')),
      GoCoreStatusResult.online(_onlineStatus('req-settings-dev-2')),
    ]);
    final developerProvider = _FakeDeveloperProvider();

    await tester.pumpWidget(
      localizedTestApp(
        home: SettingsPage(
          statusProvider: statusProvider,
          developerProvider: developerProvider,
        ),
      ),
    );
    await _pumpAsync(tester);

    final portField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == '端口',
      ),
    );
    expect(portField.controller?.text, '16666');

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Token',
      ),
      'my-dev-token',
    );
    await tester.tap(find.byType(Switch));
    await _pumpAsync(tester);

    expect(developerProvider.boundPort, 16666);
    expect(developerProvider.enabledToken, 'my-dev-token');
    expect(
      find.text(
        'http://192.168.1.10:16666/dev/devpath/workspace?token=my-dev-token',
      ),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsWidgets);
  });

  testWidgets('loads the persistent developer workspace identity', (
    tester,
  ) async {
    final statusProvider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-port')),
    ]);
    final developerProvider = _FakeDeveloperProvider(
      preferredPort: 17777,
      preferredToken: 'saved-dev-token',
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: SettingsPage(
          statusProvider: statusProvider,
          developerProvider: developerProvider,
        ),
      ),
    );
    await _pumpAsync(tester);

    final portField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '端口',
    );
    expect(tester.widget<TextField>(portField).controller?.text, '17777');
    final tokenField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Token',
    );
    expect(
      tester.widget<TextField>(tokenField).controller?.text,
      'saved-dev-token',
    );
    await tester.enterText(portField, '18888');
    await tester.tap(find.byType(Switch));
    await _pumpAsync(tester);

    expect(developerProvider.boundPort, 18888);
    expect(developerProvider.enabledToken, 'saved-dev-token');
  });

  testWidgets(
    'developer switch reflects the target state before startup ends',
    (tester) async {
      final statusProvider = _QueueStatusProvider([
        GoCoreStatusResult.online(_onlineStatus('req-settings-responsive')),
      ]);
      final developerProvider = _DelayedDeveloperProvider();
      await tester.pumpWidget(
        localizedTestApp(
          home: SettingsPage(
            statusProvider: statusProvider,
            developerProvider: developerProvider,
          ),
        ),
      );
      await _pumpAsync(tester);

      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('正在启动开发者通道并准备工作区地址…'), findsOneWidget);

      developerProvider.completeEnable();
      await _pumpAsync(tester);
      expect(find.textContaining('已开启，Token 尾号'), findsOneWidget);
    },
  );

  testWidgets(
    'developer workspace selection keeps readable dark-theme colors',
    (tester) async {
      final statusProvider = _QueueStatusProvider([
        GoCoreStatusResult.online(_onlineStatus('req-settings-dark-selection')),
      ]);
      final developerProvider = _FakeDeveloperProvider();

      await tester.pumpWidget(
        localizedTestApp(
          home: Theme(
            data: PlaymeshTheme.dark(),
            child: SettingsPage(
              statusProvider: statusProvider,
              developerProvider: developerProvider,
            ),
          ),
        ),
      );
      await _pumpAsync(tester);
      await tester.tap(find.byType(Switch));
      await _pumpAsync(tester);

      final selectedTile = tester.widget<ListTile>(
        find.byWidgetPredicate(
          (widget) => widget is ListTile && widget.selected,
        ),
      );
      final colors = PlaymeshTheme.dark().colorScheme;
      expect(selectedTile.selectedTileColor, colors.secondaryContainer);
      expect(selectedTile.selectedColor, colors.onSecondaryContainer);
    },
  );
}

class _QueueStatusProvider implements GoCoreStatusProvider {
  _QueueStatusProvider(this.results);

  final List<GoCoreStatusResult> results;
  int checkCalls = 0;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatusResult> check() async {
    final index = checkCalls.clamp(0, results.length - 1);
    checkCalls += 1;
    return results[index];
  }

  @override
  Future<void> close() async {}
}

class _FakeDeveloperProvider
    implements DeveloperModeProvider, DeveloperWorkspacePreferenceProvider {
  _FakeDeveloperProvider({
    this.preferredPort = defaultDeveloperPort,
    this.preferredToken = 'persisted-dev-token',
  });

  final int preferredPort;
  final String preferredToken;
  int? boundPort;
  String? enabledToken;

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) async {
    boundPort = port;
    enabledToken = token;
    return DeveloperSession(
      enabled: true,
      port: port,
      path: 'devpath',
      token: token,
      tokenHint: token?.substring(token.length - 6),
      workspacePath: '/dev/devpath/workspace',
      docsPath: '/dev/docs',
      openApiPath: '/dev/openapi.json',
      sdkManifestPath: '/dev/sdk-manifest.json',
      createdAt: DateTime.utc(2026, 7, 16),
    );
  }

  @override
  Future<DeveloperSession> developerModeStatus() async {
    return const DeveloperSession(enabled: false);
  }

  @override
  Future<DeveloperWorkspacePreference>
  loadDeveloperWorkspacePreference() async => DeveloperWorkspacePreference(
    port: preferredPort,
    token: preferredToken,
    path: 'devpath',
  );

  @override
  Future<void> disableDeveloperMode() async {}

  @override
  Future<List<Uri>> developerWorkspaceLinks(DeveloperSession session) async {
    return [
      Uri.parse(
        'http://192.168.1.10:${boundPort ?? 16666}${session.workspacePath}?token=${session.token}',
      ),
    ];
  }
}

class _DelayedDeveloperProvider extends _FakeDeveloperProvider {
  final Completer<DeveloperSession> _enableCompleter = Completer();

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) {
    boundPort = port;
    enabledToken = token;
    return _enableCompleter.future;
  }

  void completeEnable() {
    _enableCompleter.complete(
      DeveloperSession(
        enabled: true,
        port: boundPort,
        path: 'devpath',
        token: enabledToken,
        tokenHint: enabledToken?.substring(enabledToken!.length - 6),
        workspacePath: '/dev/devpath/workspace',
        docsPath: '/dev/docs',
        openApiPath: '/dev/openapi.json',
        sdkManifestPath: '/dev/sdk-manifest.json',
        createdAt: DateTime.utc(2026, 7, 18),
      ),
    );
  }
}

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 250));
}

GoCoreStatus _onlineStatus(String requestId) {
  return GoCoreStatus(
    requestId: requestId,
    status: 'online',
    coreVersion: '0.1.0',
    timestamp: DateTime.utc(2026, 7, 15, 8, 30),
    startedAt: DateTime.utc(2026, 7, 15, 8),
  );
}
