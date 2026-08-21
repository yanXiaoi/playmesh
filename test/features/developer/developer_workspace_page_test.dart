import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/developer/developer_workspace_page.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('应用内开发者工作区不加入键盘和遥控器焦点遍历', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        localizedTestApp(
          home: DeveloperWorkspacePage(
            workspaceUri: Uri.parse(
              'http://127.0.0.1:16666/dev/example/workspace',
            ),
          ),
        ),
      );

      final exclusion = tester.widget<ExcludeFocus>(
        find.byKey(const Key('developer-workspace-focus-exclusion')),
      );
      expect(exclusion.excluding, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('工作区刷新协调器复用当前 WebView 和统一稳定地址', () async {
    Uri? loadedUri;
    var recoveries = 0;
    final reloadUri = Uri.parse('http://127.0.0.1:16666/dev/example/gdevelop/');

    await reloadDeveloperWorkspaceWebView(
      load: (uri) async => loadedUri = uri,
      reloadUri: reloadUri,
      recoverUnavailableLoader: (_) async => recoveries += 1,
    );

    expect(loadedUri, reloadUri);
    expect(recoveries, 0);
  });

  test('工作区 WebView 加载器尚未就绪时只恢复一次', () async {
    var recoveries = 0;
    Uri? recoveryUri;
    final reloadUri = Uri.parse('http://127.0.0.1/workspace');

    await reloadDeveloperWorkspaceWebView(
      load: null,
      reloadUri: reloadUri,
      recoverUnavailableLoader: (uri) async {
        recoveries += 1;
        recoveryUri = uri;
      },
    );

    expect(recoveries, 1);
    expect(recoveryUri, reloadUri);
  });

  test('Android 工作区刷新只加载无一次性 capability 的稳定地址', () async {
    final bootstrapUri = Uri.parse(
      'http://127.0.0.1:16666/dev/example/gdevelop/'
      '?token=developer-token&editorBootstrap=one-shot-capability#editor',
    );
    Uri? loadedUri;
    var recoveries = 0;

    await reloadDeveloperWorkspaceWebView(
      load: (uri) async => loadedUri = uri,
      reloadUri: developerWorkspaceReloadUri(bootstrapUri),
      recoverUnavailableLoader: (_) async => recoveries += 1,
    );

    expect(
      loadedUri,
      Uri.parse('http://127.0.0.1:16666/dev/example/gdevelop/'),
    );
    expect(loadedUri?.query, isEmpty);
    expect(loadedUri?.fragment, isEmpty);
    expect(recoveries, 0);
  });
}
