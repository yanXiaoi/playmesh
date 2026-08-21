import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/developer/developer_workspace_page.dart';
import 'package:playmesh/features/developer/gdevelop_workspace_route_coordinator.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('reopening in App focuses the existing GDevelop WebView route', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final coordinator = GDevelopWorkspaceRouteCoordinator();
      late BuildContext rootContext;
      await tester.pumpWidget(
        localizedTestApp(
          home: Builder(
            builder: (context) {
              rootContext = context;
              return const Scaffold(body: Text('home'));
            },
          ),
        ),
      );

      await coordinator.open(
        context: rootContext,
        workspaceUri: Uri.parse('http://127.0.0.1:16666/dev/a/gdevelop/'),
        title: 'Visual editor',
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeveloperWorkspacePage), findsOneWidget);

      final workspaceContext = tester.element(
        find.byType(DeveloperWorkspacePage),
      );
      Navigator.of(workspaceContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('overlay')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('overlay'), findsOneWidget);

      await coordinator.open(
        context: rootContext,
        workspaceUri: Uri.parse('http://127.0.0.1:16666/dev/a/gdevelop/'),
        title: 'Visual editor',
      );
      await tester.pumpAndSettle();

      expect(find.text('overlay'), findsNothing);
      expect(find.byType(DeveloperWorkspacePage), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
