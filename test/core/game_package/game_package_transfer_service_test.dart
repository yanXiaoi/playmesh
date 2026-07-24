import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('导入并导出根目录含 main.json 的 Playmesh 游戏包', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-transfer-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    await _writeZip(source, {
      'main.json': _manifest('com.example.transfer'),
      'app/index.html': '<!doctype html><title>Transfer</title>',
      'app/static/game.js': 'console.log("ok")',
    });
    final service = GamePackageTransferService(libraryRoot: root);

    final game = await service.importPackage(source);

    expect(game.id, 'com.example.transfer');
    final installed = Directory(game.entry.packageRootFilePath!);
    expect(
      await File(
        '${installed.path}${Platform.pathSeparator}main.json',
      ).exists(),
      isTrue,
    );
    expect(
      await Directory(
        '${installed.path}${Platform.pathSeparator}.playmesh',
      ).exists(),
      isFalse,
    );

    final exported = File(
      '${root.path}${Platform.pathSeparator}exported.playmesh.zip',
    );
    await service.exportPackage(game, exported);
    final entries = ZipDecoder()
        .decodeBytes(await exported.readAsBytes())
        .where((entry) => entry.isFile)
        .map((entry) => entry.name)
        .toSet();
    expect(
      entries,
      containsAll(['main.json', 'app/index.html', 'app/static/game.js']),
    );
    expect(entries.any((path) => path.startsWith('.playmesh/')), isFalse);
  });

  test('同 ID 更新只替换发布文件并保留 data 和 cache', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-update-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    final service = GamePackageTransferService(libraryRoot: root);
    await _writeZip(source, {
      'main.json': _manifest('com.example.update'),
      'capabilities.json': jsonEncode({
        'required': ['sensor.accelerometer'],
      }),
      'app/index.html': '<!doctype html><title>Old</title>',
      'app/removed.js': 'old',
    });
    final first = await service.importPackage(source);
    final installed = Directory(first.entry.packageRootFilePath!);
    final data = File(
      '${installed.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}save.json',
    );
    final cache = File(
      '${installed.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}preview.bin',
    );
    await data.parent.create(recursive: true);
    await cache.parent.create(recursive: true);
    await data.writeAsString('{"score":7}');
    await cache.writeAsString('cached');

    await _writeZip(source, {
      'main.json': _manifest('com.example.update', version: '1.1.0'),
      'capabilities.json': jsonEncode({
        'required': ['sensor.gyroscope'],
      }),
      'app/index.html': '<!doctype html><title>New</title>',
    });
    await service.importPackage(source);

    expect(await data.readAsString(), '{"score":7}');
    expect(await cache.readAsString(), 'cached');
    expect(
      await File(
        '${installed.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}removed.js',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${installed.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}index.html',
      ).readAsString(),
      contains('New'),
    );
  });

  test('非单屏多人游戏拒绝声明控制器能力', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-transfer-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    await _writeZip(source, {
      'main.json': _manifest('com.example.invalid-controller-capability'),
      'capabilities.json': jsonEncode({
        'required': <String>[],
        'controllerRequired': ['device.vibration'],
      }),
      'app/index.html': '<!doctype html>',
    });

    await expectLater(
      GamePackageTransferService(libraryRoot: root).importPackage(source),
      throwsFormatException,
    );
  });

  test('拒绝把完整 HTML 目录当作应用游戏包导入', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-transfer-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}html.zip');
    await _writeZip(source, {
      'html-game/index.html': '<!doctype html>',
      'html-game/main.json': _manifest('com.example.nested'),
    });

    await expectLater(
      GamePackageTransferService(libraryRoot: root).importPackage(source),
      throwsFormatException,
    );
  });

  test('宽松项目拉取保留损坏能力文件且不要求 app 目录', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-transfer-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.broken',
    );
    await package.create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString('{"id":"com.example.broken"}');
    await File(
      '${package.path}${Platform.pathSeparator}capabilities.json',
    ).writeAsString('{broken');
    const game = GameSummary(
      id: 'com.example.broken',
      name: 'Broken',
      version: '0.0.0',
      description: '',
      minPlayers: 1,
      maxPlayers: 1,
      supportsMultiplayer: false,
      displayModeLabel: '',
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      entry: LocalGameEntry(assetPath: 'app/index.html', statusLabel: '待修复'),
    );
    final recoverable = GameSummary(
      id: game.id,
      name: game.name,
      version: game.version,
      description: game.description,
      minPlayers: game.minPlayers,
      maxPlayers: game.maxPlayers,
      supportsMultiplayer: game.supportsMultiplayer,
      displayModeLabel: game.displayModeLabel,
      displayMode: game.displayMode,
      orientation: game.orientation,
      entry: LocalGameEntry(
        assetPath: game.entry.assetPath,
        statusLabel: game.entry.statusLabel,
        packageRootFilePath: package.path,
      ),
    );
    final destination = File(
      '${root.path}${Platform.pathSeparator}recovery.zip',
    );

    await GamePackageTransferService(
      libraryRoot: root,
    ).exportPackage(recoverable, destination, validate: false);

    final entries = ZipDecoder()
        .decodeBytes(await destination.readAsBytes())
        .where((entry) => entry.isFile)
        .map((entry) => entry.name)
        .toSet();
    expect(entries, {'main.json', 'capabilities.json'});
  });
}

Future<void> _writeZip(File output, Map<String, String> files) async {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
}

String _manifest(String id, {String version = '1.0.0'}) => jsonEncode({
  'id': id,
  'name': 'Transfer Game',
  'author': 'Test Author',
  'lastModifiedAt': 1784851200000,
  'version': version,
  'sdkVersion': '1.0.0',
  'orientation': 'portrait',
  'modes': ['solo'],
  'displayModes': ['multi_screen'],
  'players': {'min': 1, 'max': 1},
});
