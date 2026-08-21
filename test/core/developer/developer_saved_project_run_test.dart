import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('源码运行的元数据和资源根全部来自同一个已保存目录', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-saved-source-run-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    const projectId = 'com.example.saved-source';
    final projectRoot = Directory(
      '${workspace.path}${Platform.pathSeparator}$projectId',
    );
    final appRoot = Directory(
      '${projectRoot.path}${Platform.pathSeparator}app',
    );
    await appRoot.create(recursive: true);
    await File(
      '${projectRoot.path}${Platform.pathSeparator}main.json',
    ).writeAsString(
      jsonEncode({
        'id': projectId,
        'name': 'Saved source metadata',
        'author': 'Source author',
        'lastModifiedAt': 0,
        'remarks': 'Current saved project',
        'version': '2.0.0',
        'sdkVersion': '4.1.0',
        'appSdkVersion': '3.3.0',
        'orientation': 'landscape',
        'modes': ['solo'],
        'displayModes': ['multi_screen'],
        'players': {'min': 1, 'max': 1},
        'entries': {'game': 'saved.html'},
        'tags': ['source'],
      }),
    );
    await File(
      '${appRoot.path}${Platform.pathSeparator}saved.html',
    ).writeAsString('<!doctype html><title>Saved</title>');

    final repository = GameLibraryRepository(
      () async => [
        GameSummary(
          id: projectId,
          name: 'Stale cached metadata',
          version: '1.0.0',
          description: 'Must not be mixed into source run',
          minPlayers: 2,
          maxPlayers: 4,
          supportsMultiplayer: true,
          displayModeLabel: 'multi_screen',
          displayMode: 'multi_screen',
          orientation: GameOrientation.landscape,
          entry: LocalGameEntry(
            gameEntryPath: 'cached.html',
            statusLabel: 'cached',
            packageRootFilePath: projectRoot.path,
          ),
        ),
      ],
    );
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );

    final validation = await catalog.validateProject(projectId);
    final game = await catalog.prepareGame(projectId);

    expect(validation.valid, isTrue, reason: validation.toJson().toString());
    expect(game.name, 'Saved source metadata');
    expect(game.version, '2.0.0');
    expect(game.description, 'Current saved project');
    expect(game.minPlayers, 1);
    expect(game.maxPlayers, 1);
    expect(game.entry.gameEntryPath, 'saved.html');
    expect(game.entry.packageRootFilePath, projectRoot.path);
  });
}
