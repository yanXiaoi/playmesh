import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/models/game_manifest.dart';

void main() {
  test(
    'staged preview metadata is built only from its runtime declaration',
    () {
      final manifest = GameManifest.fromJson({
        'id': 'com.example.gdevelop-preview',
        'name': 'Imported example',
        'author': 'GDevelop',
        'lastModifiedAt': 0,
        'remarks': 'staged preview',
        'version': '1.0.0',
        'sdkVersion': '4.1.0',
        'appSdkVersion': '3.3.0',
        'orientation': 'landscape',
        'modes': ['solo'],
        'displayModes': ['multi_screen'],
        'players': {'min': 1, 'max': 1},
        'entries': {'game': 'index.html'},
        'tags': <String>[],
      });

      final game = DeveloperRuntimeDeclaration(
        manifest: manifest,
      ).toDevelopmentGame();

      expect(game.id, manifest.id);
      expect(game.name, 'Imported example');
      expect(game.entry.gameEntryPath, 'index.html');
      expect(game.entry.packageRootFilePath, isNull);
    },
  );

  test(
    'gameId-only developer run never falls back to an installed package',
    () async {
      var launches = 0;
      final controller = DeveloperRunController(
        onLaunch: (_) async => launches++,
      );

      await expectLater(
        controller.run('com.example.installed'),
        throwsA(isA<DeveloperPreviewPackageRequired>()),
      );

      expect(launches, 0);
      expect(controller.activeStatus, isNull);
    },
  );

  test(
    'external development source without a staged declaration is rejected',
    () async {
      var launches = 0;
      final controller = DeveloperRunController(
        onLaunch: (_) async => launches++,
      );
      final session = DeveloperResourceSession(
        projectId: 'com.example.installed',
        resourceBaseUri: Uri.parse('http://127.0.0.1:54321/'),
        credential: 'preview-credential',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );

      await expectLater(
        controller.runDevelopment(session),
        throwsA(isA<DeveloperPreviewPackageRequired>()),
      );

      expect(launches, 0);
      expect(controller.resourceSession(session.projectId), isNull);
    },
  );
}
