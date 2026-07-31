import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/core/game_package/ordinary_web_package_importer.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  late Directory temporary;
  late OrdinaryWebPackageImporter importer;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'playmesh-web-package-import-',
    );
    importer = const OrdinaryWebPackageImporter();
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('根目录 main.json 继续识别为标准游戏包', () async {
    final source = await _writeArchive(temporary, {
      'main.json': '{}',
      'app/index.html': '<title>Standard</title>',
    });

    expect(
      await importer.inspect(source),
      isA<StandardGamePackageInspection>(),
    );
  });

  test('没有 main.json 和 HTML 时识别为非网页包', () async {
    final source = await _writeArchive(temporary, {
      'readme.txt': 'not a web package',
      'assets/data.json': '{}',
    });

    expect(
      await importer.inspect(source),
      isA<UnsupportedGamePackageInspection>(),
    );
  });

  test('剥离公共外层目录并使用 index.html title 推荐名称', () async {
    final source = await _writeArchive(temporary, {
      'release/site/index.html':
          '<!doctype html><title>  Party &amp; Play  </title>',
      'release/site/controller.html': '<title>Controller</title>',
      'release/site/assets/main.js': '',
    });

    final inspection =
        await importer.inspect(source) as OrdinaryWebPackageInspection;

    expect(inspection.strippedRootDirectory, 'release');
    expect(inspection.suggestedGameEntry, 'site/index.html');
    expect(inspection.suggestedControllerEntry, 'site/controller.html');
    expect(inspection.suggestedName, 'Party & Play');
    expect(inspection.htmlEntries, ['site/index.html', 'site/controller.html']);
  });

  test('没有 index.html 时游戏名称默认使用压缩包文件名', () async {
    final source = await _writeArchive(temporary, {
      'play.html': '<title>Ignored title</title>',
    }, name: 'plain-web.zip');

    final inspection =
        await importer.inspect(source) as OrdinaryWebPackageInspection;

    expect(inspection.suggestedGameEntry, 'play.html');
    expect(inspection.suggestedName, 'plain-web');
  });

  test('转换单机网页包并保留根路径资源引用', () async {
    final source = await _writeArchive(temporary, {
      'index.html': '''
<!doctype html>
<head>
  <base href="/">
  <link rel="stylesheet" href="/assets/style.css">
</head>
<body>
  <img src="/images/logo.png">
  <img src="/favicon.ico">
  <script>import("/scripts/module.js"); fetch("/api/save");</script>
</body>
''',
      'assets/style.css':
          'body{background:url(/images/bg.png)} @import "/assets/theme.css";',
      'assets/theme.css': '',
      'images/logo.png': [1, 2, 3],
      'images/bg.png': [4, 5, 6],
      'scripts/module.js': '''
import value from "/scripts/value.js";
const remote = "https://example.com/images/logo.png";
const route = "/api/save";
const matcher = /images\\/(.+)/;
''',
      'scripts/value.js': 'export default 1;',
      'favicon.ico': [0, 1],
    });
    final inspection =
        await importer.inspect(source) as OrdinaryWebPackageInspection;

    final package = await importer.convert(
      source,
      configuration: OrdinaryWebPackageConfiguration(
        name: inspection.suggestedName,
        orientation: GameOrientation.landscape,
        mode: GameMode.solo,
        displayMode: GameDisplayMode.multiScreen,
        gameEntry: inspection.suggestedGameEntry,
      ),
      author: 'Tester',
      lastModifiedAt: DateTime.utc(2026, 7, 30),
    );

    expect(
      package.files.keys,
      containsAll([
        'main.json',
        'app/index.html',
        'app/assets/style.css',
        'app/images/logo.png',
        'app/scripts/module.js',
        'app/favicon.ico',
      ]),
    );
    final html = utf8.decode(package.files['app/index.html']!);
    expect(html, contains('<base href="/">'));
    expect(html, contains('href="/assets/style.css"'));
    expect(html, contains('src="/images/logo.png"'));
    expect(html, contains('src="/favicon.ico"'));
    expect(html, contains('import("/scripts/module.js")'));
    expect(html, contains('fetch("/api/save")'));

    final css = utf8.decode(package.files['app/assets/style.css']!);
    expect(css, contains('url(/images/bg.png)'));
    expect(css, contains('@import "/assets/theme.css"'));

    final script = utf8.decode(package.files['app/scripts/module.js']!);
    expect(script, contains('from "/scripts/value.js"'));
    expect(script, contains('"https://example.com/images/logo.png"'));
    expect(script, contains('"/api/save"'));
    expect(script, contains(r'/images\/(.+)/'));

    final manifest = package.manifest;
    expect(manifest.name, 'plain-web-package');
    expect(manifest.modes, {GameMode.solo});
    expect(manifest.players.min, 1);
    expect(manifest.players.max, 1);
    expect(manifest.entries.game, 'index.html');
    expect(manifest.entries.controller, isNull);
    expect(manifest.toJson()['entries'], {'game': 'index.html'});
    expect(manifest.authority, isNull);
    expect(
      GamePackageTransferService(
        libraryRoot: temporary,
      ).validatePackageFiles(package.files).manifest.id,
      manifest.id,
    );
  });

  test('单屏多人转换生成双入口和内部兼容 Authority 入口', () async {
    final source = await _writeArchive(temporary, {
      'index.html': '<title>Dual Entry</title>',
      'controller.html': '<title>Controller</title>',
    });
    final inspection =
        await importer.inspect(source) as OrdinaryWebPackageInspection;

    final package = await importer.convert(
      source,
      configuration: OrdinaryWebPackageConfiguration(
        name: inspection.suggestedName,
        orientation: GameOrientation.landscape,
        mode: GameMode.multiplayer,
        displayMode: GameDisplayMode.singleScreenMultiplayer,
        gameEntry: 'index.html?scene=lobby&player=1&player=2',
        controllerOrientation: GameOrientation.portrait,
        controllerEntry: 'controller.html?layout=compact',
      ),
      author: 'Tester',
      lastModifiedAt: DateTime.utc(2026, 7, 30),
    );

    expect(
      package.manifest.entries.game,
      'index.html?scene=lobby&player=1&player=2',
    );
    expect(
      package.manifest.entries.controller,
      'controller.html?layout=compact',
    );
    expect(package.manifest.controllerOrientation, GameOrientation.portrait);
    expect(package.manifest.players.min, 2);
    expect(package.manifest.players.max, 5);
    expect(package.manifest.authority, isNotNull);
    expect(
      package.files.containsKey('app/${package.manifest.authority!.entry}'),
      isTrue,
    );
  });

  test('普通网页导入保留用户顶层 app 目录', () async {
    final source = await _writeArchive(temporary, {
      'app/index.html':
          '<!doctype html><title>User App</title>'
          '<script src="/app/playmesh/user.js"></script>',
      'app/playmesh/user.js': 'window.userAppRoute = true;',
      'shared.css': 'body { color: white; }',
    });
    final inspection =
        await importer.inspect(source) as OrdinaryWebPackageInspection;
    expect(inspection.strippedRootDirectory, isNull);
    expect(inspection.htmlEntries, contains('app/index.html'));

    final package = await importer.convert(
      source,
      configuration: const OrdinaryWebPackageConfiguration(
        name: 'User App Directory',
        orientation: GameOrientation.landscape,
        mode: GameMode.solo,
        displayMode: GameDisplayMode.multiScreen,
        gameEntry: 'app/index.html',
      ),
      author: 'Tester',
      lastModifiedAt: DateTime.utc(2026, 7, 30),
    );

    expect(package.manifest.entries.game, 'app/index.html');
    expect(
      package.files.keys,
      containsAll([
        'app/app/index.html',
        'app/app/playmesh/user.js',
        'app/shared.css',
      ]),
    );
  });

  test('普通网页包拒绝占用平台运行时根目录', () async {
    final source = await _writeArchive(temporary, {
      'index.html': '<title>Reserved</title>',
      'PLAYMESH/sdk.js': 'export {}',
    });

    await expectLater(
      importer.convert(
        source,
        configuration: const OrdinaryWebPackageConfiguration(
          name: 'Reserved',
          orientation: GameOrientation.landscape,
          mode: GameMode.solo,
          displayMode: GameDisplayMode.multiScreen,
          gameEntry: 'index.html',
        ),
        author: 'Tester',
        lastModifiedAt: DateTime.utc(2026, 7, 30),
      ),
      throwsFormatException,
    );
  });
}

Future<File> _writeArchive(
  Directory directory,
  Map<String, Object> files, {
  String name = 'plain-web-package.zip',
}) async {
  final archive = Archive();
  for (final item in files.entries) {
    final bytes = switch (item.value) {
      String value => utf8.encode(value),
      List<int> value => value,
      _ => throw ArgumentError.value(item.value),
    };
    archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
  }
  final output = File('${directory.path}${Platform.pathSeparator}$name');
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
  return output;
}
