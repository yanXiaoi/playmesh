import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_status_service.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/update/app_update_models.dart';
import 'package:playmesh/core/update/app_update_service.dart';
import 'package:playmesh/core/version/semantic_version.dart';
import 'package:playmesh/features/settings/settings_page.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('renders settings before the initial Core check starts', (
    tester,
  ) async {
    final result = Completer<GoCoreStatusResult>();
    var settingsRenderedWhenCheckStarted = false;
    final provider = _DelayedStatusProvider(
      onCheck: () {
        settingsRenderedWhenCheckStarted = find
            .text('设置')
            .evaluate()
            .isNotEmpty;
      },
      result: result.future,
    );

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );

    expect(settingsRenderedWhenCheckStarted, isTrue);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('正在检查'), findsOneWidget);

    result.complete(
      GoCoreStatusResult.online(_onlineStatus('req-settings-async')),
    );
    await _pumpAsync(tester);

    expect(find.text('req-settings-async'), findsOneWidget);
  });

  testWidgets('shows online Core version and request ID', (tester) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-online')),
    ]);

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(find.text('Playmesh 5.1.0'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Playmesh 5.1.0')).dy,
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

  testWidgets('does not expose developer mode from Settings', (tester) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-no-developer')),
    ]);

    await tester.pumpWidget(
      localizedTestApp(home: SettingsPage(statusProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(find.text('开发者模式'), findsNothing);
    expect(find.text('制作游戏'), findsNothing);
  });

  testWidgets(
    'does not expose GDevelop distribution notices in Settings/About',
    (tester) async {
      final provider = _QueueStatusProvider([
        GoCoreStatusResult.online(_onlineStatus('req-settings-no-gdevelop')),
      ]);

      await tester.pumpWidget(
        localizedTestApp(home: SettingsPage(statusProvider: provider)),
      );
      await _pumpAsync(tester);

      expect(
        find.byKey(const Key('game-creation-gdevelop-notices')),
        findsNothing,
      );
      expect(find.text('开源与第三方声明'), findsNothing);
      expect(find.textContaining('GDevelop'), findsNothing);
    },
  );

  testWidgets('shows update details and opens a route in the browser', (
    tester,
  ) async {
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-update')),
    ]);
    final checker = _FakeUpdateChecker();
    await tester.pumpWidget(
      localizedTestApp(
        home: SettingsPage(statusProvider: provider, updateChecker: checker),
      ),
    );
    await _pumpAsync(tester);

    await tester.tap(find.byKey(const Key('check-app-update-button')));
    await _pumpAsync(tester);

    expect(find.byKey(const Key('app-update-dialog')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('app-update-dialog')),
        matching: find.text('检查更新'),
      ),
      findsOneWidget,
    );
    expect(find.text('检查 Playmesh 更新'), findsNothing);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('4.2.0'), findsOneWidget);
    expect(find.text('4.3.0'), findsOneWidget);
    expect(find.text('新增手动检查更新。'), findsNothing);
    expect(find.text('查看版本说明'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('36ms'), findsOneWidget);
    expect(find.textContaining('延迟'), findsNothing);

    final comparison = find.byKey(const Key('app-update-version-comparison'));
    final currentLabel = tester.getRect(find.text('当前版本'));
    final currentVersion = tester.getRect(find.text('4.2.0'));
    final latestLabel = tester.getRect(find.text('最新版本'));
    final latestVersion = tester.getRect(find.text('4.3.0'));
    final comparisonLeft = currentLabel.left < currentVersion.left
        ? currentLabel.left
        : currentVersion.left;
    final comparisonRight = latestLabel.right > latestVersion.right
        ? latestLabel.right
        : latestVersion.right;
    expect(
      (comparisonLeft + comparisonRight) / 2,
      closeTo(tester.getCenter(comparison).dx, 1),
    );

    await tester.tap(find.text('查看版本说明'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('app-update-release-notes-dialog')),
      findsOneWidget,
    );
    expect(find.text('新版本说明'), findsOneWidget);
    expect(find.text('新增手动检查更新。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-update-release-notes-close')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'app-update-download-open-https://example.com/playmesh.exe',
        ),
      ),
    );
    await _pumpAsync(tester);

    expect(checker.opened.single.endpoint.name, 'GitHub');
    expect(find.text('已在浏览器中打开'), findsOneWidget);
  });

  testWidgets('keeps update controls usable on a narrow screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = _QueueStatusProvider([
      GoCoreStatusResult.online(_onlineStatus('req-settings-update-narrow')),
    ]);
    await tester.pumpWidget(
      localizedTestApp(
        home: SettingsPage(
          statusProvider: provider,
          updateChecker: _FakeUpdateChecker(
            endpointName: '主线路 · Windows x64 便携版下载',
          ),
        ),
      ),
    );
    await _pumpAsync(tester);

    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('check-app-update-button')));
    await _pumpAsync(tester);

    expect(find.byKey(const Key('app-update-dialog')), findsOneWidget);
    expect(find.text('查看版本说明'), findsOneWidget);
    expect(find.text('新版本说明'), findsNothing);
    expect(find.text('主线路 · Windows x64 便携版下载'), findsOneWidget);
    expect(find.text('打开'), findsNothing);
    expect(find.text('36ms'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'app-update-download-open-https://example.com/playmesh.exe',
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
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

class _DelayedStatusProvider implements GoCoreStatusProvider {
  const _DelayedStatusProvider({required this.onCheck, required this.result});

  final VoidCallback onCheck;
  final Future<GoCoreStatusResult> result;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatusResult> check() {
    onCheck();
    return result;
  }

  @override
  Future<void> close() async {}
}

final class _FakeUpdateChecker implements AppUpdateChecker {
  _FakeUpdateChecker({this.endpointName = 'GitHub'});

  final String endpointName;
  final List<AppUpdateDownload> opened = [];

  @override
  Future<AppUpdateCheckResult> checkForUpdates() async {
    final endpoint = NamedDownloadEndpoint(
      name: endpointName,
      url: Uri.parse('https://example.com/playmesh.exe'),
    );
    return AppUpdateCheckResult(
      currentVersion: SemanticVersion.parse('4.2.0'),
      latestVersion: SemanticVersion.parse('4.3.0'),
      releaseNotes: '新增手动检查更新。',
      source: NamedDownloadEndpoint(
        name: 'Gitee',
        url: Uri.parse('https://example.com/app_update.json'),
      ),
      platform: 'windows',
      platformAvailable: true,
      downloads: [
        AppUpdateDownload(
          endpoint: endpoint,
          probe: EndpointProbeResult(
            url: endpoint.url,
            state: EndpointProbeState.reachable,
            latency: const Duration(milliseconds: 36),
          ),
        ),
      ],
      sourceCount: 2,
      successfulSourceCount: 2,
    );
  }

  @override
  Future<bool> openDownload(AppUpdateDownload download) async {
    opened.add(download);
    return true;
  }

  @override
  void close() {}
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
