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

  test('Windows 工作区刷新复用当前 WebView，不重放初始入口地址', () async {
    var nativeReloads = 0;
    var flutterReloads = 0;
    var windowsRestarts = 0;
    var flutterInitializations = 0;

    await reloadDeveloperWorkspaceWebView(
      usesWindowsWebView: true,
      windowsReload: () async => nativeReloads += 1,
      flutterReload: () async => flutterReloads += 1,
      restartWindowsWebView: () => windowsRestarts += 1,
      initializeFlutterWebView: () async => flutterInitializations += 1,
    );

    expect(nativeReloads, 1);
    expect(flutterReloads, 0);
    expect(windowsRestarts, 0);
    expect(flutterInitializations, 0);
  });

  test('Windows WebView 尚未就绪时仅重建一次', () async {
    var windowsRestarts = 0;

    await reloadDeveloperWorkspaceWebView(
      usesWindowsWebView: true,
      windowsReload: null,
      flutterReload: null,
      restartWindowsWebView: () => windowsRestarts += 1,
      initializeFlutterWebView: null,
    );

    expect(windowsRestarts, 1);
  });
}
