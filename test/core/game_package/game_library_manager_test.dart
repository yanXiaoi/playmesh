import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_library_manager.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('永久删除 packages 中的整个游戏目录', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.delete',
    );
    for (final path in ['app/index.html', 'data/save.json', 'cache/log.txt']) {
      final file = File(
        '${package.path}${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(path);
    }
    final game = _game(package.path);

    await GameLibraryManager(libraryRoot: root).deleteGame(game);

    expect(await package.exists(), isFalse);
  });

  test('拒绝删除 packages 之外的声明目录', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    final outside = await Directory.systemTemp.createTemp('playmesh-outside-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });

    await expectLater(
      GameLibraryManager(libraryRoot: root).deleteGame(_game(outside.path)),
      throwsStateError,
    );
    expect(await outside.exists(), isTrue);
  });
}

GameSummary _game(String packageRoot) => GameSummary(
  id: 'com.example.delete',
  name: 'Delete Test',
  version: '1.0.0',
  description: 'delete test',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.portrait,
  entry: LocalGameEntry(
    gameEntryPath: 'index.html',
    statusLabel: 'Game SDK 1.0',
    packageRootFilePath: packageRoot,
  ),
);
