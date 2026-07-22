import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('后台刷新期间保留旧缓存并在完成后原子替换', () async {
    final scan = Completer<List<GameSummary>>();
    final repository = GameLibraryRepository(
      () => scan.future,
      initialGames: const [_oldGame],
      now: () => DateTime.utc(2026, 7, 16, 12),
    );

    final firstRefresh = repository.refresh();
    final duplicateRefresh = repository.refresh();
    expect(identical(firstRefresh, duplicateRefresh), true);
    expect(repository.isRefreshing, true);
    expect(repository.cachedGames, const [_oldGame]);

    scan.complete(const [_newGame, _oldGame, _newGame]);
    await firstRefresh;

    expect(repository.isRefreshing, false);
    expect(repository.cachedGames.map((game) => game.id), ['old', 'new']);
    expect(repository.revision, 1);
    expect(repository.refreshedAt, DateTime.utc(2026, 7, 16, 12));
  });

  test('缓存查询支持搜索、分页和稳定版本', () {
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: const [_newGame, _oldGame],
    );

    final searched = repository.query(search: 'party', limit: 10);
    expect(searched.total, 1);
    expect(searched.games.single.id, 'new');

    final page = repository.query(offset: 1, limit: 1);
    expect(page.total, 2);
    expect(page.offset, 1);
    expect(page.games.single.id, 'new');
    expect(page.revision, 0);
  });

  test('开发工作区项目直接进入统一游戏库缓存', () {
    final repository = GameLibraryRepository(() async => const []);

    repository.upsert(_newGame);

    expect(repository.cachedGames, const [_newGame]);
    repository.remove(_newGame.id);
    expect(repository.cachedGames, isEmpty);
  });
}

const _oldGame = GameSummary(
  id: 'old',
  name: '旧游戏',
  version: '1.0.0',
  description: '旧缓存',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.portrait,
  entry: LocalGameEntry(assetPath: 'old/app/index.html', statusLabel: 'SDK'),
);

const _newGame = GameSummary(
  id: 'new',
  name: '派对新游戏',
  version: '1.0.0',
  description: 'party game',
  minPlayers: 1,
  maxPlayers: 4,
  supportsMultiplayer: true,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  tags: ['party'],
  entry: LocalGameEntry(assetPath: 'new/app/index.html', statusLabel: 'SDK'),
);
