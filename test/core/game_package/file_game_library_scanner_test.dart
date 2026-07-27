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
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
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
    expect(games.single.displayModeLabel, 'multi_screen');
    expect(games.single.entry.packageRootFilePath, package.path);
  });

  test('目录名与 id 不一致时仍保留待修复项目', () async {
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
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
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

    expect(games.single.id, 'com.example.actual');
    expect(games.single.manifestError, contains('不一致'));
    expect(games.single.description, isEmpty);
    expect(games.single.displayModeLabel, 'multi_screen');
    expect(games.single.entry.statusLabel, 'manifest_repair_required');
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
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "name": "Custom Entry",
  "version": "1.0.0",
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "controllerOrientation": "portrait",
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

  test('缺少 Authority 文件时仍保留待修复项目', () async {
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
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
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

    final games = await FileGameLibraryScanner(libraryRoot: root).scan();

    expect(games.single.id, 'com.example.missing-authority');
    expect(games.single.manifestError, contains('缺少'));
  });

  test('只有 id 的损坏清单不会阻断其他游戏扫描', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    final broken = Directory(
      '${packages.path}${Platform.pathSeparator}com.example.broken',
    );
    final unidentifiable = Directory(
      '${packages.path}${Platform.pathSeparator}no-id',
    );
    await broken.create(recursive: true);
    await unidentifiable.create(recursive: true);
    await File(
      '${broken.path}${Platform.pathSeparator}main.json',
    ).writeAsString(
      '{"id":"com.example.broken","name":42,'
      '"remarks":"API repair note / 原样"}',
    );
    await File(
      '${unidentifiable.path}${Platform.pathSeparator}main.json',
    ).writeAsString('{"name":"No id"}');

    final games = await FileGameLibraryScanner(libraryRoot: root).scan();

    expect(games, hasLength(1));
    expect(games.single.id, 'com.example.broken');
    expect(games.single.name, 'com.example.broken');
    expect(games.single.author, isEmpty);
    expect(games.single.lastModifiedAt, isNull);
    expect(games.single.manifestError, isNotNull);
    expect(games.single.description, 'API repair note / 原样');
  });
}
