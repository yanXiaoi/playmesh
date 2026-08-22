import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/storage/app_local_bucket_store.dart';

void main() {
  test('App Bucket 按当前设备、游戏名称和 gameId 保存独立 JSON 文件', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-app-bucket-');
    addTearDown(() => root.delete(recursive: true));
    final store = AppLocalBucketStore(
      gameId: 'com.playmesh.local-player',
      gameName: '本地玩家游戏',
      libraryRoot: root,
    );

    final source = <String, Object?>{
      'level': 3,
      'items': <Object?>['map', 'key'],
    };
    await store.setData('player_save', 'progress', source);
    source['level'] = 99;

    expect(await store.getData('player_save', 'progress'), {
      'level': 3,
      'items': ['map', 'key'],
    });
    final file = File(
      '${root.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}本地玩家游戏'
      '${Platform.pathSeparator}com.playmesh.local-player'
      '${Platform.pathSeparator}player_save.json',
    );
    expect(await file.exists(), isTrue);
    expect(jsonDecode(await file.readAsString()), {
      'progress': {
        'level': 3,
        'items': ['map', 'key'],
      },
    });

    await store.removeData('player_save', 'progress');
    expect(await store.getData('player_save', 'progress'), isNull);
    await store.setData('player_save', 'progress', {'level': 4});
    await store.clearData('player_save');
    expect(jsonDecode(await file.readAsString()), <String, Object?>{});
  });

  test('App Bucket 拒绝路径注入并隔离不同设备根目录', () async {
    final firstRoot = await Directory.systemTemp.createTemp(
      'playmesh-app-bucket-first-',
    );
    final secondRoot = await Directory.systemTemp.createTemp(
      'playmesh-app-bucket-second-',
    );
    addTearDown(() => firstRoot.delete(recursive: true));
    addTearDown(() => secondRoot.delete(recursive: true));
    final first = AppLocalBucketStore(
      gameId: 'com.playmesh.local-player',
      gameName: '同一游戏',
      libraryRoot: firstRoot,
    );
    final second = AppLocalBucketStore(
      gameId: 'com.playmesh.local-player',
      gameName: '同一游戏',
      libraryRoot: secondRoot,
    );

    await first.setData('save', 'score', 12);
    expect(await second.getData('save', 'score'), isNull);
    expect(() => first.getData('../escape', 'score'), throwsFormatException);
    expect(() => first.getData('save', '../score'), throwsFormatException);
  });
}
