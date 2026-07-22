import 'package:flutter/services.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/asset_game_package_loader.dart';
import 'package:playmesh/core/game_package/asset_game_library_scanner.dart';

void main() {
  test('加载清单并校验大屏游戏所需入口', () async {
    final bundle = _MemoryAssetBundle({
      'assets/games/test-game/main.json': '''
        {
          "id": "com.playmesh.test-game",
          "name": "测试游戏",
          "version": "1.0.0",
          "sdkVersion": "1.0.0",
          "orientation": "landscape",
          "modes": ["multiplayer"],
          "displayModes": ["single_screen_multiplayer"],
          "players": {"min": 2, "max": 5},
          "authority": {"entry": "app/static/js/service/index.js"}
        }
      ''',
      'assets/games/test-game/app/index.html': '<html></html>',
      'assets/games/test-game/app/controller/index.html': '<html></html>',
      'assets/games/test-game/app/static/js/service/index.js': 'export {}',
    });

    final package = await AssetGamePackageLoader(
      bundle: bundle,
    ).load('assets/games/test-game/');

    expect(package.manifest.name, '测试游戏');
    expect(
      package.controllerEntryAssetPath,
      'assets/games/test-game/app/controller/index.html',
    );
  });

  test('缺少控制器入口时加载失败', () async {
    final bundle = _MemoryAssetBundle({
      'assets/game/main.json': '''
        {
          "id": "game", "name": "game", "version": "1.0.0",
          "sdkVersion": "1.0.0", "orientation": "portrait",
          "modes": ["multiplayer"],
          "displayModes": ["single_screen_multiplayer"],
          "players": {"min": 2, "max": 2},
          "authority": {"entry": "app/service.js"}
        }
      ''',
      'assets/game/app/index.html': '<html></html>',
      'assets/game/app/service.js': 'export {}',
    });

    expect(
      () => AssetGamePackageLoader(bundle: bundle).load('assets/game'),
      throwsA(isA<FlutterError>()),
    );
  });

  test('加载 main.json 声明的自定义页面入口', () async {
    final bundle = _MemoryAssetBundle({
      'assets/game/main.json': '''
        {
          "id": "game", "name": "game", "version": "1.0.0",
          "sdkVersion": "1.0.0", "orientation": "landscape",
          "modes": ["multiplayer"],
          "displayModes": ["single_screen_multiplayer"],
          "players": {"min": 2, "max": 4},
          "entries": {
            "game": "app/play/main.html",
            "controller": "app/remote/pad.html"
          },
          "authority": {"entry": "app/service/authority.mjs"}
        }
      ''',
      'assets/game/app/play/main.html': '<html></html>',
      'assets/game/app/remote/pad.html': '<html></html>',
      'assets/game/app/service/authority.mjs': 'export {}',
    });

    final package = await AssetGamePackageLoader(
      bundle: bundle,
    ).load('assets/game');

    expect(package.appEntryAssetPath, 'assets/game/app/play/main.html');
    expect(package.controllerEntryAssetPath, 'assets/game/app/remote/pad.html');
  });

  test('从统一游戏目录扫描 main.json 并生成游戏库条目', () async {
    const root = 'assets/playmesh-library/packages/com.playmesh.test-game';
    final bundle = _MemoryAssetBundle({
      '$root/main.json': '''
        {
          "id": "com.playmesh.test-game",
          "name": "测试游戏",
          "remarks": "扫描测试",
          "version": "1.0.0",
          "sdkVersion": "1.0.0",
          "orientation": "landscape",
          "modes": ["multiplayer"],
          "displayModes": ["single_screen_multiplayer"],
          "players": {"min": 2, "max": 5},
          "authority": {"entry": "app/static/js/service/index.js"},
          "tags": ["test", "multiplayer"]
        }
      ''',
      '$root/app/index.html': '<html></html>',
      '$root/app/controller/index.html': '<html></html>',
      '$root/app/static/js/service/index.js': 'export {}',
    });

    final games = await AssetGameLibraryScanner(
      bundle: bundle,
    ).scan(assetKeys: ['$root/main.json']);

    expect(games, hasLength(1));
    expect(games.single.id, 'com.playmesh.test-game');
    expect(games.single.entry.packageRootAssetPath, root);
    expect(games.single.displayMode, 'single_screen_multiplayer');
    expect(games.single.tags, ['test', 'multiplayer']);
  });

  test('拒绝目录名与 main.json id 不一致的游戏包', () async {
    const root = 'assets/playmesh-library/packages/wrong-id';
    final bundle = _MemoryAssetBundle({
      '$root/main.json': '''
        {
          "id": "actual-id", "name": "game", "version": "1.0.0",
          "sdkVersion": "1.0.0", "orientation": "portrait",
          "modes": ["solo"], "displayModes": ["multi_screen"],
          "players": {"min": 1, "max": 1}
        }
      ''',
      '$root/app/index.html': '<html></html>',
    });

    expect(
      () => AssetGameLibraryScanner(
        bundle: bundle,
      ).scan(assetKeys: ['$root/main.json']),
      throwsFormatException,
    );
  });

  test('重新扫描会清除已读取清单缓存', () async {
    const root = 'assets/playmesh-library/packages/refresh-game';
    final bundle = _MemoryAssetBundle({
      '$root/main.json': _soloManifest('刷新前'),
      '$root/app/index.html': '<html></html>',
    });
    final scanner = AssetGameLibraryScanner(bundle: bundle);

    final first = await scanner.scan(assetKeys: ['$root/main.json']);
    bundle.assets['$root/main.json'] = _soloManifest('刷新后');
    final refreshed = await scanner.scan(assetKeys: ['$root/main.json']);

    expect(first.single.name, '刷新前');
    expect(refreshed.single.name, '刷新后');
  });
}

String _soloManifest(String name) =>
    '''
  {
    "id": "refresh-game", "name": "$name", "version": "1.0.0",
    "sdkVersion": "1.0.0", "orientation": "portrait",
    "modes": ["solo"], "displayModes": ["multi_screen"],
    "players": {"min": 1, "max": 1}
  }
''';

class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw FlutterError('缺少测试资源: $key');
    }
    final bytes = Uint8List.fromList(utf8.encode(value));
    return ByteData.view(bytes.buffer);
  }
}
