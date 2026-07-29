import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  Map<String, Object?> validManifest() => {
    'id': 'com.playmesh.test-game',
    'author': 'Test Author',
    'lastModifiedAt': 1784851200000,
    'name': '测试游戏',
    'remarks': '清单解析测试',
    'version': '1.0.0',
    'sdkVersion': '1.0.0',
    'orientation': 'landscape',
    'controllerOrientation': 'portrait',
    'modes': ['multiplayer'],
    'displayModes': ['single_screen_multiplayer'],
    'players': {'min': 2, 'max': 5},
    'authority': {'entry': 'app/static/js/service/index.js'},
  };

  test('解析完整的多人游戏清单', () {
    final manifest = GameManifest.fromJson(validManifest());

    expect(manifest.players.min, 2);
    expect(manifest.players.max, 5);
    expect(manifest.supportsMultiplayer, isTrue);
    expect(manifest.authority?.entry, 'app/static/js/service/index.js');
    expect(manifest.entries.game, 'app/index.html');
    expect(manifest.entries.controller, 'app/controller/index.html');
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
        'game': 'app/play/game.html',
        'controller': 'app/remote/pad.html',
      };

    final manifest = GameManifest.fromJson(json);

    expect(manifest.entries.game, 'app/play/game.html');
    expect(manifest.entries.controller, 'app/remote/pad.html');
  });

  test('拒绝缺少屏幕方向的清单', () {
    final json = validManifest()..remove('orientation');

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝不兼容的 SDK 主版本', () {
    final json = validManifest()..['sdkVersion'] = '4.0.0';

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('解析 App SDK 版本并兼容旧清单缺省值', () {
    final current = validManifest()..['appSdkVersion'] = '2.0.0';

    expect(GameManifest.fromJson(current).appSdkVersion, '2.0.0');
    expect(GameManifest.fromJson(validManifest()).appSdkVersion, '1.0.0');
  });

  test('拒绝不兼容的 App SDK 主版本', () {
    final json = validManifest()..['appSdkVersion'] = '4.0.0';

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝没有 Authority 入口的多人游戏', () {
    final json = validManifest()..remove('authority');

    expect(() => GameManifest.fromJson(json), throwsFormatException);
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
      ..['entries'] = {'game': 'https://example.com/game.html'};
    final wrongType = validManifest()
      ..['entries'] = {'controller': 'app/controller/index.js'};

    expect(() => GameManifest.fromJson(external), throwsFormatException);
    expect(() => GameManifest.fromJson(wrongType), throwsFormatException);
  });

  test('拒绝不是 JavaScript 文件的 Authority 入口', () {
    final json = validManifest()
      ..['authority'] = {'entry': 'app/service/index.html'};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });

  test('拒绝无效玩家人数范围', () {
    final json = validManifest()..['players'] = {'min': 5, 'max': 2};

    expect(() => GameManifest.fromJson(json), throwsFormatException);
  });
}
