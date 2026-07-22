import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/file_game_library_scanner.dart';

void main() {
  test('从统一 packages 目录扫描开发项目和正式项目', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.game',
    );
    await package.create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString('''{
  "id": "com.example.game",
  "name": "Example Game",
  "version": "1.0.0",
  "sdkVersion": "1.0.0",
  "orientation": "portrait",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1}
}''');
    final entry = File(
      '${package.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}index.html',
    );
    await entry.parent.create(recursive: true);
    await entry.writeAsString('<!doctype html>');

    final games = await FileGameLibraryScanner(libraryRoot: root).scan();

    expect(games, hasLength(1));
    expect(games.single.id, 'com.example.game');
    expect(games.single.entry.packageRootFilePath, package.path);
  });

  test('拒绝目录名与 main.json id 不一致的项目', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}wrong-id',
    );
    await package.create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString('''{
  "id": "com.example.actual",
  "name": "Example Game",
  "version": "1.0.0",
  "sdkVersion": "1.0.0",
  "orientation": "portrait",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1}
}''');
    final entry = File(
      '${package.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}index.html',
    );
    await entry.parent.create(recursive: true);
    await entry.writeAsString('<!doctype html>');

    await expectLater(
      FileGameLibraryScanner(libraryRoot: root).scan(),
      throwsFormatException,
    );
  });

  test('扫描并返回自定义页面入口', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.custom-entry',
    );
    await package.create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString('''{
  "id": "com.example.custom-entry",
  "name": "Custom Entry",
  "version": "1.0.0",
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": {"min": 2, "max": 4},
  "entries": {
    "game": "app/play/main.html",
    "controller": "app/remote/pad.html"
  },
  "authority": {"entry": "app/service/authority.js"}
}''');
    for (final path in [
      'app/play/main.html',
      'app/remote/pad.html',
      'app/service/authority.js',
    ]) {
      final file = File(
        '${package.path}${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    final games = await FileGameLibraryScanner(libraryRoot: root).scan();

    expect(games.single.entry.assetPath, 'app/play/main.html');
    expect(games.single.entry.controllerEntryPath, 'app/remote/pad.html');
  });

  test('拒绝缺少 Authority 文件的多人项目', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.missing-authority',
    );
    await package.create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString('''{
  "id": "com.example.missing-authority",
  "name": "Missing Authority",
  "version": "1.0.0",
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "displayModes": ["multi_screen"],
  "players": {"min": 2, "max": 4},
  "authority": {"entry": "app/service/missing.js"}
}''');
    final entry = File(
      '${package.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}index.html',
    );
    await entry.parent.create(recursive: true);
    await entry.writeAsString('');

    await expectLater(
      FileGameLibraryScanner(libraryRoot: root).scan(),
      throwsFormatException,
    );
  });
}
