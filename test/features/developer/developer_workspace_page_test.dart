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
}
