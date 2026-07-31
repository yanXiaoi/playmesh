import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/ordinary_web_package_importer.dart';
import 'package:playmesh/features/games/ordinary_web_package_import_dialog.dart';
import 'package:playmesh/models/game_manifest.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('普通网页包向导默认单机并在单屏多人时展开控制器配置', (tester) async {
    OrdinaryWebPackageConfiguration? result;
    const inspection = OrdinaryWebPackageInspection(
      htmlEntries: ['index.html', 'controller.html', 'pages/help.html'],
      suggestedGameEntry: 'index.html',
      suggestedControllerEntry: 'controller.html',
      suggestedName: '网页派对',
      strippedRootDirectory: 'release',
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showOrdinaryWebPackageImportDialog(
                    context: context,
                    inspection: inspection,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('ordinary-web-package-import-dialog')),
      findsOneWidget,
    );
    expect(find.text('网页派对'), findsOneWidget);
    expect(find.text('已自动移除公共外层目录：release'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ordinary-web-package-controller-entry')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey(GameDisplayMode.multiScreen)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单屏多人').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('ordinary-web-package-controller-entry')),
      findsOneWidget,
    );
    expect(find.text('app/index.html'), findsOneWidget);
    expect(find.text('app/controller.html'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('ordinary-web-package-import-confirm')),
    );
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, GameMode.multiplayer);
    expect(result!.displayMode, GameDisplayMode.singleScreenMultiplayer);
    expect(result!.gameEntry, 'index.html');
    expect(result!.controllerEntry, 'controller.html');
  });
}
