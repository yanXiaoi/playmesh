import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_library_local_metadata.dart';

void main() {
  test('最近打开时间只写入游戏包外的 App 本地缓存', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final store = GameLibraryLocalMetadataStore(libraryRoot: root);
    final openedAt = DateTime.utc(2026, 7, 24, 12, 34, 56);

    await store.markLaunched('com.example.game', openedAt);

    expect((await store.readLastOpenedAt())['com.example.game'], openedAt);
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}app'
        '${Platform.pathSeparator}game-library.json',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.example.game'
        '${Platform.pathSeparator}main.json',
      ).exists(),
      isFalse,
    );

    await store.remove('com.example.game');
    expect(
      (await store.readLastOpenedAt()).containsKey('com.example.game'),
      isFalse,
    );
  });

  test('损坏的本地元数据不会阻断游戏库', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(
      '${root.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}app'
      '${Platform.pathSeparator}game-library.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');

    expect(
      await GameLibraryLocalMetadataStore(libraryRoot: root).readLastOpenedAt(),
      isEmpty,
    );
  });

  test('损坏条目被逐项忽略且不会隔离同文件中的有效统计', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-library-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(
      '${root.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}app'
      '${Platform.pathSeparator}game-library.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'version': 2,
        'games': {
          'com.example.valid': {
            'lastOpenedAt': 1785060000000,
            'launchCount': 4,
          },
          'Game_1': {'lastOpenedAt': 1785060000001, 'launchCount': 2},
          'com.example.out-of-range-time': {
            'lastOpenedAt': GameLibraryUsageStats.maxLaunchCount,
            'launchCount': 1,
          },
          '../invalid id': {'lastOpenedAt': 1785060000000, 'launchCount': 2},
        },
      }),
    );

    final values = await GameLibraryLocalMetadataStore(
      libraryRoot: root,
    ).readUsageStats();

    expect(values.keys, ['com.example.valid', 'Game_1']);
    expect(values['com.example.valid']!.launchCount, 4);
    expect(values['Game_1']!.launchCount, 2);
    expect(await file.exists(), isTrue);
    expect(
      await file.parent
          .list()
          .where((entry) => entry.path.endsWith('.unsupported'))
          .isEmpty,
      isTrue,
    );
  });
}
