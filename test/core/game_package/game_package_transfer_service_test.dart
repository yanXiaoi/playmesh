import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('游戏包导入预算覆盖大型 Cocos HTML 资源', () {
    expect(GamePackageTransferService.maxCompressedBytes, 100 * 1024 * 1024);
    expect(GamePackageTransferService.maxExpandedBytes, 512 * 1024 * 1024);
    expect(GamePackageTransferService.maxSingleFileBytes, 128 * 1024 * 1024);
    expect(GamePackageTransferService.maxFileCount, 8000);
  });

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

  test('App 导入保留用户 app 目录及其入口语义', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-user-app-import-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    await _writeZip(source, {
      'main.json': _manifest(
        'com.example.user-app-import',
        gameEntry: 'app/index.html?scene=main&player=1&player=2',
      ),
      'app/app/index.html': '<!doctype html><title>User App</title>',
      'app/app/playmesh/user.js': 'window.userAppRoute = true;',
    });

    final game = await GamePackageTransferService(
      libraryRoot: root,
    ).importPackage(source);

    expect(
      game.entry.gameEntryPath,
      'app/index.html?scene=main&player=1&player=2',
    );
    final installed = Directory(game.entry.packageRootFilePath!);
    expect(
      await File(
        '${installed.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}app'
        '${Platform.pathSeparator}index.html',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${installed.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}app'
        '${Platform.pathSeparator}playmesh'
        '${Platform.pathSeparator}user.js',
      ).exists(),
      isTrue,
    );
  });

  test('同 ID 更新只替换发布文件并保留 data 和 cache', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-update-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    final service = GamePackageTransferService(libraryRoot: root);
    await _writeZip(source, {
      'main.json': _manifest('com.example.update'),
      'capabilities.json': jsonEncode({
        'required': ['media.camera'],
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
    final removedEntries = <FileSystemEntity>[
      File(
        '${installed.path}${Platform.pathSeparator}sdk'
        '${Platform.pathSeparator}legacy.js',
      ),
      File(
        '${installed.path}${Platform.pathSeparator}.playmesh'
        '${Platform.pathSeparator}state.json',
      ),
      File('${installed.path}${Platform.pathSeparator}arbitrary.txt'),
      Directory('${installed.path}${Platform.pathSeparator}other-root'),
    ];
    for (final entry in removedEntries) {
      if (entry is Directory) {
        await entry.create(recursive: true);
        await File(
          '${entry.path}${Platform.pathSeparator}state.bin',
        ).writeAsString('legacy');
      } else if (entry is File) {
        await entry.parent.create(recursive: true);
        await entry.writeAsString('legacy');
      }
    }
    final outside = File(
      '${root.path}${Platform.pathSeparator}outside-preserved-link.txt',
    );
    await outside.writeAsString('outside');
    final rootLink = Link(
      '${installed.path}${Platform.pathSeparator}legacy-link',
    );
    final dataLink = Link(
      '${data.parent.path}${Platform.pathSeparator}linked-save',
    );
    var linksCreated = false;
    try {
      await rootLink.create(outside.path);
      await dataLink.create(outside.path);
      linksCreated = true;
    } on FileSystemException {
      // 未获符号链接权限的 Windows 环境无法执行链接断言。
    }

    await _writeZip(source, {
      'main.json': _manifest('com.example.update', version: '1.1.0'),
      'capabilities.json': jsonEncode({
        'required': ['media.microphone'],
      }),
      'app/index.html': '<!doctype html><title>New</title>',
    });
    await service.importPackage(source);

    expect(await data.readAsString(), '{"score":7}');
    expect(await cache.readAsString(), 'cached');
    for (final entry in removedEntries) {
      expect(
        await FileSystemEntity.type(entry.path, followLinks: false),
        FileSystemEntityType.notFound,
        reason: '${entry.path} must not survive a package update',
      );
    }
    if (linksCreated) {
      expect(
        await FileSystemEntity.type(rootLink.path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(
        await FileSystemEntity.type(dataLink.path, followLinks: false),
        FileSystemEntityType.notFound,
      );
    }
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
    final packageEntries = await installed.parent
        .list()
        .map((entity) => entity.path)
        .toList();
    expect(
      packageEntries.any(
        (path) =>
            path.contains('.playmesh-import-') ||
            path.contains('.playmesh-backup-'),
      ),
      isFalse,
    );
  });

  test('启动恢复目录交换中断时的上一份完整游戏包', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-update-recovery-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    final service = GamePackageTransferService(libraryRoot: root);
    await _writeZip(source, {
      'main.json': _manifest('com.example.recovery'),
      'app/index.html': '<!doctype html><title>Stable</title>',
    });
    final game = await service.importPackage(source);
    final target = Directory(game.entry.packageRootFilePath!);
    final packages = target.parent;
    final backup = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-backup-test',
    );
    final staging = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-import-test',
    );
    await target.rename(backup.path);
    await staging.create();
    await File(
      '${staging.path}${Platform.pathSeparator}partial.tmp',
    ).writeAsString('partial');

    await service.recoverInterruptedImports();

    expect(await target.exists(), isTrue);
    expect(await backup.exists(), isFalse);
    expect(await staging.exists(), isFalse);
    expect(
      await File(
        '${target.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}index.html',
      ).readAsString(),
      contains('Stable'),
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

  test('拒绝物理 app 下的平台保留目录和编码或大小写绕过', () {
    final service = GamePackageTransferService();
    for (final path in [
      'app/playmesh/sdk.js',
      'app/PLAYMESH/sdk.js',
      'app/Bucket/file.json',
      r'app\bucket\file.json',
      'app/%70laymesh/sdk.js',
    ]) {
      expect(
        () => service.validatePackageFiles({
          'main.json': utf8.encode(_manifest('com.example.reserved')),
          'app/index.html': utf8.encode('<!doctype html>'),
          path: [0],
        }),
        throwsFormatException,
        reason: path,
      );
    }
  });

  test('允许嵌套目录继续使用 playmesh 和 bucket 名称', () {
    final package = GamePackageTransferService().validatePackageFiles({
      'main.json': utf8.encode(_manifest('com.example.nested-names')),
      'app/index.html': utf8.encode('<!doctype html>'),
      'app/assets/playmesh/logo.png': [0],
      'app/data/bucket/level.json': utf8.encode('{}'),
    });

    expect(
      package.files.keys,
      containsAll([
        'app/assets/playmesh/logo.png',
        'app/data/bucket/level.json',
      ]),
    );
  });

  test('根 icon.png 被导入导出且清单未知字段被统一投影丢弃', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-icon-v2-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}icon.zip');
    final archive = Archive();
    final manifestBytes = utf8.encode(
      jsonEncode({
        ...(jsonDecode(_manifest('com.example.icon')) as Map),
        'icon': 'app/legacy.png',
        'permissions': ['keyboard'],
        'redundant': true,
      }),
    );
    archive
      ..addFile(ArchiveFile('main.json', manifestBytes.length, manifestBytes))
      ..addFile(ArchiveFile('app/index.html', 1, [0]))
      ..addFile(ArchiveFile('icon.png', _pngBytes.length, _pngBytes));
    await source.writeAsBytes(ZipEncoder().encode(archive)!);

    final service = GamePackageTransferService(libraryRoot: root);
    final game = await service.importPackage(source);
    expect(game.localIconPath, endsWith('icon.png'));
    final installedManifest =
        jsonDecode(
              await File(
                '${game.entry.packageRootFilePath}${Platform.pathSeparator}main.json',
              ).readAsString(),
            )
            as Map;
    expect(installedManifest.containsKey('icon'), isFalse);
    expect(installedManifest.containsKey('permissions'), isFalse);
    expect(installedManifest.containsKey('redundant'), isFalse);
    installedManifest
      ..['icon'] = 'app/legacy.png'
      ..['permissions'] = ['keyboard']
      ..['redundant'] = true;
    await File(
      '${game.entry.packageRootFilePath}${Platform.pathSeparator}main.json',
    ).writeAsString(jsonEncode(installedManifest));

    final exported = File('${root.path}${Platform.pathSeparator}export.zip');
    await service.exportPackage(game, exported);
    final exportedArchive = ZipDecoder().decodeBytes(
      await exported.readAsBytes(),
    );
    final names = exportedArchive
        .where((entry) => entry.isFile)
        .map((entry) => entry.name)
        .toSet();
    expect(names, contains('icon.png'));
    final exportedManifest =
        jsonDecode(
              utf8.decode(
                exportedArchive
                        .singleWhere((entry) => entry.name == 'main.json')
                        .content
                    as List<int>,
              ),
            )
            as Map;
    expect(exportedManifest.containsKey('icon'), isFalse);
    expect(exportedManifest.containsKey('permissions'), isFalse);
    expect(exportedManifest.containsKey('redundant'), isFalse);
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
      entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: '待修复'),
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
        gameEntryPath: game.entry.gameEntryPath,
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

  test(
    'downloaded package tampering cannot change id version or publisher',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playmesh-tampered-download-',
      );
      addTearDown(() => root.delete(recursive: true));
      final service = GamePackageTransferService(libraryRoot: root);
      final cases = [
        (
          id: 'com.attacker.replacement',
          version: '2.0.0',
          author: 'Trusted Publisher',
        ),
        (
          id: 'com.example.expected',
          version: '9.9.9',
          author: 'Trusted Publisher',
        ),
        (
          id: 'com.example.expected',
          version: '2.0.0',
          author: 'Attacker Publisher',
        ),
      ];

      for (var index = 0; index < cases.length; index += 1) {
        final value = cases[index];
        final source = File(
          '${root.path}${Platform.pathSeparator}tampered-$index.zip',
        );
        await _writeZip(source, {
          'main.json': _manifest(
            value.id,
            version: value.version,
            author: value.author,
          ),
          'app/index.html': '<!doctype html>',
        });

        await expectLater(
          service.importPackage(
            source,
            expectedGameId: 'com.example.expected',
            expectedVersion: '2.0.0',
            expectedPublisher: 'Trusted Publisher',
          ),
          throwsFormatException,
        );
      }

      final packages = Directory(
        '${root.path}${Platform.pathSeparator}packages',
      );
      expect(
        await packages.exists()
            ? await packages.list().toList()
            : const <FileSystemEntity>[],
        isEmpty,
      );
    },
  );
}

Future<void> _writeZip(File output, Map<String, String> files) async {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
}

String _manifest(
  String id, {
  String version = '1.0.0',
  String author = 'Test Author',
  String gameEntry = 'index.html',
}) => jsonEncode({
  'id': id,
  'name': 'Transfer Game',
  'author': author,
  'lastModifiedAt': 1784851200000,
  'version': version,
  'sdkVersion': '4.0.0',
  'appSdkVersion': '3.2.0',
  'orientation': 'portrait',
  'modes': ['solo'],
  'displayModes': ['multi_screen'],
  'players': {'min': 1, 'max': 1},
  'entries': {'game': gameEntry},
});

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
  'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
