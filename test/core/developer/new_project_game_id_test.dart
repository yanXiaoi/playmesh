import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/models/game_id.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new source project game ID matches the shared Android contract', () {
    final fixture =
        jsonDecode(
              File('test/fixtures/new_project_game_id.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    for (final value in (fixture['valid']! as List).cast<String>()) {
      expect(isValidPlaymeshNewProjectGameId(value), isTrue, reason: value);
    }
    for (final value in (fixture['invalid']! as List).cast<String>()) {
      expect(isValidPlaymeshNewProjectGameId(value), isFalse, reason: value);
    }
    final boundary = fixture['boundary']! as Map;
    final prefix = boundary['prefix']! as String;
    final character = boundary['segmentCharacter']! as String;
    final maximum = fixture['maxLength']! as int;
    String repeatedToLength(int length) =>
        prefix + List.filled(length - prefix.length, character).join();
    expect(isValidPlaymeshNewProjectGameId(repeatedToLength(maximum)), isTrue);
    expect(
      isValidPlaymeshNewProjectGameId(repeatedToLength(maximum + 1)),
      isFalse,
    );

    // The global installed-game contract remains backward compatible.
    expect(isValidPlaymeshGameId('com.example.legacy-game'), isTrue);
    expect(isValidPlaymeshNewProjectGameId('com.example.legacy-game'), isFalse);
  });

  test(
    'only an explicitly marked source creation uses the Android policy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playmesh-new-project-id-',
      );
      addTearDown(() => root.delete(recursive: true));
      final service = ProjectProvisioningService(projectsRoot: root);

      final created = await service.createProject(
        gameId: 'Com.Example.Game_2',
        name: 'Android Identity',
        kind: PlaymeshProjectKind.source,
        requireAndroidApplicationId: true,
      );
      final reopened = await service.openProject(
        gameId: created.gameId,
        kind: PlaymeshProjectKind.source,
      );
      expect(reopened.gameId, 'Com.Example.Game_2');
      expect(reopened.metadata['identityPolicy'], 'android_application_id_v1');

      await expectLater(
        () => service.createProject(
          gameId: 'com.example.new-game',
          name: 'Rejected New Identity',
          kind: PlaymeshProjectKind.source,
          requireAndroidApplicationId: true,
        ),
        throwsA(isA<FormatException>()),
      );

      final legacy = await service.createProject(
        gameId: 'com.example.legacy-game',
        name: 'Legacy Identity',
        kind: PlaymeshProjectKind.source,
      );
      expect(legacy.metadata.containsKey('identityPolicy'), isFalse);
      await expectLater(
        () => service.createProject(
          gameId: 'com.example.Visual_2',
          name: 'Visual Identity',
          kind: PlaymeshProjectKind.gdevelop,
          requireAndroidApplicationId: true,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'source workspace create policy survives normal catalog access',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playmesh-new-source-project-id-',
      );
      addTearDown(() => root.delete(recursive: true));
      final catalog = GameLibraryDeveloperProjectCatalog(
        GameLibraryRepository(() async => const []),
        workspaceRoot: root,
      );
      final project = await catalog.createProject(
        DeveloperProjectDraft(
          id: 'Com.Example.Game_2',
          name: 'Android Identity',
          author: 'Test Author',
          lastModifiedAt: DateTime.utc(2026, 8, 20),
          orientation: GameOrientation.landscape,
          displayMode: 'multi_screen',
          minPlayers: 1,
          maxPlayers: 1,
          mode: 'solo',
          requireAndroidApplicationId: true,
        ),
      );

      expect(project.id, 'Com.Example.Game_2');
      expect(await catalog.listFiles(project.id), contains('main.json'));
      expect(
        (await catalog.readFile(project.id, 'main.json')).bytes,
        isNotEmpty,
      );
    },
  );

  test('only source workspace create and CLI init opt into the new rule', () {
    final operation = File(
      'lib/core/developer/operations/projects/projects_operation.dart',
    ).readAsStringSync();
    final catalog = File(
      'lib/core/developer/developer_project_catalog.dart',
    ).readAsStringSync();
    final workspaceHtml = File(
      'assets/playmesh-library/public/developer/workspace.html',
    ).readAsStringSync();
    final workspaceScript = File(
      'assets/playmesh-library/public/developer/workspace.js',
    ).readAsStringSync();

    expect(operation, contains('requireAndroidApplicationId: true'));
    expect(catalog, contains('this.requireAndroidApplicationId = false'));
    expect(
      workspaceHtml,
      contains(
        'maxlength="64" pattern="[A-Za-z][A-Za-z0-9_]*'
        '(\\.[A-Za-z][A-Za-z0-9_]*)+"',
      ),
    );
    expect(
      workspaceScript,
      contains("fillRandomProjectId('projectId','android')"),
    );
    expect(
      workspaceScript,
      contains('PlaymeshGameManifest.isValidNewProjectGameId(id)'),
    );
    expect(
      workspaceScript,
      contains(
        "q('randomCopyProjectId').onclick=()=>fillRandomProjectId('copyProjectId')",
      ),
      reason: 'Copy remains on its legacy identity contract.',
    );
  });
}
