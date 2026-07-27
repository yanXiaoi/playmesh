import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_library_local_metadata.dart';

void main() {
  test('usage extensions are defensive recursively immutable snapshots', () {
    final nestedMap = <String, Object?>{'enabled': true};
    final nestedList = <Object?>[
      nestedMap,
      <Object?>['seed'],
    ];
    final input = <String, Object?>{'nested': nestedMap, 'items': nestedList};

    final stats = GameLibraryUsageStats.withExtensions(extensions: input);

    nestedMap['enabled'] = false;
    (nestedList[1] as List<Object?>).add('caller mutation');
    nestedList.add('caller mutation');
    input['added'] = true;

    expect(stats.extensions, {
      'nested': {'enabled': true},
      'items': [
        {'enabled': true},
        ['seed'],
      ],
    });
    expect(() => stats.extensions['added'] = true, throwsUnsupportedError);
    final frozenMap = stats.extensions['nested']! as Map<String, Object?>;
    expect(() => frozenMap['enabled'] = false, throwsUnsupportedError);
    final frozenList = stats.extensions['items']! as List<Object?>;
    expect(() => frozenList.add('mutation'), throwsUnsupportedError);
    expect(
      () => (frozenList[1]! as List<Object?>).add('mutation'),
      throwsUnsupportedError,
    );
  });

  test(
    'v2 markLaunched atomically updates time/count and preserves extensions',
    () async {
      final root = await Directory.systemTemp.createTemp('playmesh-usage-v2-');
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
            'game': {
              'lastOpenedAt': 1,
              'launchCount': 4,
              'futureField': {'value': true},
            },
          },
        }),
      );
      final store = GameLibraryLocalMetadataStore(libraryRoot: root);
      final openedAt = DateTime.utc(2026, 7, 26);
      await store.markLaunched('game', openedAt);
      final stats = (await store.readUsageStats())['game']!;
      expect(stats.lastOpenedAt, openedAt);
      expect(stats.launchCount, 5);
      expect(stats.extensions['futureField'], {'value': true});
    },
  );

  test(
    'read snapshots cannot mutate cached extensions or later writes',
    () async {
      final root = await Directory.systemTemp.createTemp('playmesh-usage-v2-');
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
            'game': {
              'lastOpenedAt': 1,
              'launchCount': 4,
              'futureField': {
                'settings': {'mode': 'safe'},
                'items': [
                  1,
                  {'label': 'original'},
                ],
              },
            },
          },
        }),
      );
      final store = GameLibraryLocalMetadataStore(libraryRoot: root);
      final snapshot = await store.readUsageStats();
      final stats = snapshot['game']!;
      final futureField =
          stats.extensions['futureField']! as Map<String, Object?>;
      final settings = futureField['settings']! as Map<String, Object?>;
      final items = futureField['items']! as List<Object?>;
      final item = items[1]! as Map<String, Object?>;

      expect(
        () => snapshot['other'] = const GameLibraryUsageStats(),
        throwsUnsupportedError,
      );
      expect(() => stats.extensions['other'] = true, throwsUnsupportedError);
      expect(() => futureField['other'] = true, throwsUnsupportedError);
      expect(() => settings['mode'] = 'mutated', throwsUnsupportedError);
      expect(() => items.add('mutated'), throwsUnsupportedError);
      expect(() => item['label'] = 'mutated', throwsUnsupportedError);

      final openedAt = DateTime.utc(2026, 7, 26);
      await store.markLaunched('game', openedAt);

      final persisted = jsonDecode(await file.readAsString()) as Map;
      final persistedGame = (persisted['games'] as Map)['game'] as Map;
      expect(persistedGame['futureField'], {
        'settings': {'mode': 'safe'},
        'items': [
          1,
          {'label': 'original'},
        ],
      });
      final reread = (await store.readUsageStats())['game']!;
      expect(reread.extensions['futureField'], persistedGame['futureField']);
    },
  );

  test('v1 metadata is isolated instead of migrated', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-usage-old-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(
      '${root.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}app'
      '${Platform.pathSeparator}game-library.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'lastOpenedAt': {'game': 1},
      }),
    );
    final store = GameLibraryLocalMetadataStore(
      libraryRoot: root,
      now: () => DateTime.utc(2026, 7, 26),
    );
    expect(await store.readUsageStats(), isEmpty);
    expect(
      await file.parent
          .list()
          .where((entry) => entry.path.endsWith('.unsupported'))
          .length,
      1,
    );
  });
}
