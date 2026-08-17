import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_package_layout.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  Map<String, Object?> validManifest() => {
    'id': 'com.playmesh.test-game',
    'author': 'Test Author',
    'lastModifiedAt': 1784851200000,
    'name': '测试游戏',
    'remarks': '清单解析测试',
    'version': '1.0.0',
    'sdkVersion': '4.1.0',
    'appSdkVersion': '3.3.0',
    'orientation': 'landscape',
    'controllerOrientation': 'portrait',
    'modes': ['multiplayer'],
    'displayModes': ['single_screen_multiplayer'],
    'players': {'min': 2, 'max': 5},
    'entries': {'game': 'index.html', 'controller': 'controller/index.html'},
    'authority': {'entry': 'static/js/service/index.js'},
  };

  test('解析完整的多人游戏清单', () {
    final manifest = GameManifest.fromJson(validManifest());

    expect(manifest.players.min, 2);
    expect(manifest.players.max, 5);
    expect(manifest.supportsMultiplayer, isTrue);
    expect(manifest.authority?.entry, 'static/js/service/index.js');
    expect(manifest.entries.game, 'index.html');
    expect(manifest.entries.controller, 'controller/index.html');
    expect(manifest.author, 'Test Author');
    expect(manifest.lastModifiedAt?.isUtc, isTrue);
    expect(manifest.controllerOrientation, GameOrientation.portrait);
  });

  test('游戏标签最多允许五个', () {
    final fiveTags = validManifest()..['tags'] = ['派对', '多人', '体感', '合作', '休闲'];
    final sixTags = validManifest()
      ..['tags'] = ['派对', '多人', '体感', '合作', '休闲', '竞速'];

    expect(GameManifest.fromJson(fiveTags).tags, hasLength(maxGameTagCount));
    expect(
      () => GameManifest.fromJson(sixTags),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('最多只能包含 5 个标签'),
        ),
      ),
    );
  });

  test('未知字段静默忽略且已知字段投影写回', () {
    final json = validManifest()
      ..['permissions'] = ['keyboard']
      ..['icon'] = 'app/legacy.png'
      ..['redundant'] = {'nested': true};

    final encoded = GameManifest.fromJson(json).toJson();

    expect(encoded, isNot(contains('permissions')));
    expect(encoded, isNot(contains('icon')));
    expect(encoded, isNot(contains('redundant')));
  });

  test('单屏多人必须声明控制器方向', () {
    final json = validManifest()..remove('controllerOrientation');

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('非单屏多人不能声明控制器方向', () {
    final json = validManifest()..['displayModes'] = ['multi_screen'];

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('旧清单缺少发布者时保留空动态值并兼容缺省时间', () {
    final missingAuthor = validManifest()..remove('author');
    final missingTimestamp = validManifest()..remove('lastModifiedAt');

    expect(GameManifest.fromJson(missingAuthor).author, isEmpty);
    expect(GameManifest.fromJson(missingTimestamp).lastModifiedAt, isNull);
  });

  test('拒绝可能逃逸安装目录或超过跨端上限的游戏 ID', () {
    final traversal = validManifest()..['id'] = '../outside';
    final overlong = validManifest()
      ..['id'] = 'a${List<String>.filled(64, 'b').join()}';

    expect(() => GameManifest.fromJson(traversal), throwsFormatException);
    expect(() => GameManifest.fromJson(overlong), throwsFormatException);
  });

  test('解析自定义游戏和控制器入口', () {
    final json = validManifest()
      ..['entries'] = {
        'game': 'play/game.html',
        'controller': 'remote/pad.html',
      };

    final manifest = GameManifest.fromJson(json);

    expect(manifest.entries.game, 'play/game.html');
    expect(manifest.entries.controller, 'remote/pad.html');
  });

  test('HTML 入口保留原始查询串并单独解析物理路径', () {
    final json = validManifest()
      ..['entries'] = {
        'game': 'play/game.html?redirect=https://example.com&player=1&player=2',
        'controller': 'remote/pad.html?return=%2Fhome',
      };

    final manifest = GameManifest.fromJson(json);
    final gameEntry = playmeshGamePackageLayout.parseWebEntry(
      manifest.entries.game,
      field: 'entries.game',
      kind: GameWebEntryKind.html,
    );
    final controllerEntry = playmeshGamePackageLayout.parseWebEntry(
      manifest.entries.controller!,
      field: 'entries.controller',
      kind: GameWebEntryKind.html,
    );

    expect(
      manifest.entries.game,
      'play/game.html?redirect=https://example.com&player=1&player=2',
    );
    expect(manifest.entries.controller, 'remote/pad.html?return=%2Fhome');
    expect(gameEntry.path, 'play/game.html');
    expect(gameEntry.query, 'redirect=https://example.com&player=1&player=2');
    expect(gameEntry.value, manifest.entries.game);
    expect(controllerEntry.path, 'remote/pad.html');
    expect(controllerEntry.query, 'return=%2Fhome');
    expect(manifest.toJson()['entries'], {
      'game': 'play/game.html?redirect=https://example.com&player=1&player=2',
      'controller': 'remote/pad.html?return=%2Fhome',
    });
  });

  test('HTML 入口拒绝 fragment、外部 URL 和无效查询串', () {
    for (final entry in [
      'index.html?',
      'index.html#game',
      'index.html?scene=main#game',
      'index.html?scene=hello world',
      'index.html?scene=%ZZ',
      r'index.html?path=folder\file',
      'https://example.com/index.html?scene=main',
      '//example.com/index.html?scene=main',
    ]) {
      final json = validManifest()
        ..['entries'] = {'game': entry, 'controller': 'controller/index.html'};
      expect(
        () => GameManifest.fromJson(json),
        throwsFormatException,
        reason: entry,
      );
    }
  });

  test('Authority JavaScript 入口仍禁止查询参数', () {
    final json = validManifest()
      ..['authority'] = {'entry': 'service/authority.js?mode=development'};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝缺少屏幕方向的清单', () {
    final json = validManifest()..remove('orientation');

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝不兼容的 SDK 主版本', () {
    final json = validManifest()..['sdkVersion'] = '3.2.0';

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('目录元数据可以延后 SDK 兼容性校验', () {
    final json = validManifest()
      ..['sdkVersion'] = '3.2.0'
      ..['appSdkVersion'] = '2.0.0';

    final manifest = GameManifest.fromJson(
      json,
      validateSdkCompatibility: false,
    );

    expect(manifest.sdkVersion, '3.2.0');
    expect(manifest.appSdkVersion, '2.0.0');
  });

  test('App SDK 版本必须显式声明', () {
    final json = validManifest()..remove('appSdkVersion');

    expect(
      () => GameManifest.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('缺少必填字段: appSdkVersion'),
        ),
      ),
    );
  });

  test('兼容旧 App SDK 声明并保留游戏请求版本', () {
    final json = validManifest()..['appSdkVersion'] = '3.2.0';

    final manifest = GameManifest.fromJson(json);

    expect(manifest.appSdkVersion, '3.2.0');
  });

  test('拒绝不兼容的 App SDK 主版本', () {
    final json = validManifest()..['appSdkVersion'] = '4.0.0';

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝没有 Authority 入口的多人游戏', () {
    final json = validManifest()..remove('authority');

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('入口必须由清单显式声明', () {
    final missingEntries = validManifest()..remove('entries');
    final missingGame = validManifest()
      ..['entries'] = {'controller': 'controller/index.html'};
    final missingController = validManifest()
      ..['entries'] = {'game': 'index.html'};

    expect(
      () => GameManifest.fromJson(missingEntries),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('缺少必填字段: entries'),
        ),
      ),
    );
    expect(
      () => GameManifest.fromJson(missingGame),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('缺少必填字段: game'),
        ),
      ),
    );
    expect(
      () => GameManifest.fromJson(missingController),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('single_screen_multiplayer 必须声明 entries.controller'),
        ),
      ),
    );
  });

  test('非单屏模式可以不声明控制器入口', () {
    final json = validManifest()
      ..['displayModes'] = ['multi_screen']
      ..remove('controllerOrientation')
      ..['entries'] = {'game': 'index.html'};

    final manifest = GameManifest.fromJson(json);

    expect(manifest.entries.controller, isNull);
    expect(manifest.toJson()['entries'], {'game': 'index.html'});
  });

  test('单机模式忽略遗留的控制器入口', () {
    final json = validManifest()
      ..['modes'] = ['solo']
      ..['displayModes'] = ['multi_screen']
      ..['players'] = {'min': 1, 'max': 1}
      ..remove('controllerOrientation')
      ..remove('authority');

    final manifest = GameManifest.fromJson(json);

    expect(manifest.entries.controller, isNull);
    expect(manifest.toJson()['entries'], {'game': 'index.html'});
  });

  test('拒绝同时声明单机和多人模式', () {
    final json = validManifest()..['modes'] = ['solo', 'multiplayer'];

    expect(
      () => GameManifest.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('modes 必须且只能声明一个游戏模式'),
        ),
      ),
    );
  });

  test('拒绝同时声明多个显示模式', () {
    final json = validManifest()
      ..['displayModes'] = ['multi_screen', 'single_screen_multiplayer'];

    expect(
      () => GameManifest.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('displayModes 必须且只能声明一个显示模式'),
        ),
      ),
    );
  });

  test('拒绝越过游戏包目录的入口', () {
    final json = validManifest()..['authority'] = {'entry': '../service.js'};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝外部 URL 和角色类型不匹配的运行入口', () {
    final external = validManifest()
      ..['entries'] = {
        'game': 'https://example.com/game.html',
        'controller': 'controller/index.html',
      };
    final wrongType = validManifest()
      ..['entries'] = {
        'game': 'index.html',
        'controller': 'controller/index.js',
      };

    expect(() => GameManifest.fromJson(external), throwsFormatException);
    expect(() => GameManifest.fromJson(wrongType), throwsFormatException);
  });

  test('拒绝不是 JavaScript 文件的 Authority 入口', () {
    final json = validManifest()
      ..['authority'] = {'entry': 'service/index.html'};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('入口允许用户 app 目录但拒绝平台保留目录', () {
    final appManifest = GameManifest.fromJson(
      validManifest()
        ..['entries'] = {
          'game': 'app/index.html',
          'controller': 'controller/index.html',
        },
    );
    expect(appManifest.entries.game, 'app/index.html');

    for (final entry in ['playmesh/index.html', 'Bucket/index.html']) {
      final json = validManifest()
        ..['entries'] = {'game': entry, 'controller': 'controller/index.html'};
      expect(
        () => GameManifest.fromJson(json),
        throwsFormatException,
        reason: entry,
      );
    }
  });

  test('入口拒绝反斜杠、编码和不规范路径段', () {
    for (final entry in [
      r'folder\index.html',
      '%2e%2e/index.html',
      'folder//index.html',
      './index.html',
      'folder/../index.html',
    ]) {
      final json = validManifest()
        ..['entries'] = {'game': entry, 'controller': 'controller/index.html'};
      expect(
        () => GameManifest.fromJson(json),
        throwsFormatException,
        reason: entry,
      );
    }
  });

  test('入口拒绝首尾空白且不会静默规范化', () {
    for (final entry in [' index.html', 'index.html ']) {
      final json = validManifest()
        ..['entries'] = {'game': entry, 'controller': 'controller/index.html'};
      expect(
        () => GameManifest.fromJson(json),
        throwsFormatException,
        reason: entry,
      );
    }
    for (final entry in [' service/authority.js', 'service/authority.js ']) {
      final json = validManifest()..['authority'] = {'entry': entry};
      expect(
        () => GameManifest.fromJson(json),
        throwsFormatException,
        reason: entry,
      );
    }
  });

  test('公共包布局把 Web 根路径映射到物理 app 目录', () {
    expect(
      playmeshGamePackageLayout.packagePathForWebPath('assets/main.js'),
      'app/assets/main.js',
    );
    expect(
      playmeshGamePackageLayout.webRequestPath('assets/main.js'),
      '/assets/main.js',
    );
    expect(
      () => playmeshGamePackageLayout.validatePackagePath(
        'app/PLAYMESH/sdk.js',
        field: 'path',
      ),
      throwsFormatException,
    );
    expect(
      () => playmeshGamePackageLayout.validatePackagePath(
        'APP/bucket/save.json',
        field: 'path',
      ),
      throwsFormatException,
    );
    expect(
      playmeshGamePackageLayout.packagePathForWebPath('app/index.html'),
      'app/app/index.html',
    );
    expect(
      playmeshGamePackageLayout.webRequestPath('app/index.html'),
      '/app/index.html',
    );
    expect(
      playmeshGamePackageLayout.packagePathForWebPath('app/playmesh/user.js'),
      'app/app/playmesh/user.js',
    );
    expect(
      () => playmeshGamePackageLayout.webRequestPath('Bucket/save.json'),
      throwsFormatException,
    );
  });

  test('拒绝无效玩家人数范围', () {
    final json = validManifest()..['players'] = {'min': 5, 'max': 2};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });
}
