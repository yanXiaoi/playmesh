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

  test('页面默认查询返回同一 revision 的全部结果且不截断一百项', () {
    final games = List<GameSummary>.generate(125, _indexedGame);
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: games,
    );

    final result = repository.query();

    expect(result.total, 125);
    expect(result.games, hasLength(125));
    expect(result.offset, 0);
    expect(result.revision, 0);
  });

  test('统一索引支持发布者和跨字段多关键词 AND', () {
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: const [
        GameSummary(
          id: 'com.example.party',
          name: '星海派对',
          version: '2.0.0',
          author: 'Example Studio',
          description: '多人竞速',
          minPlayers: 1,
          maxPlayers: 4,
          supportsMultiplayer: true,
          displayModeLabel: '多屏模式',
          displayMode: 'multi_screen',
          orientation: GameOrientation.landscape,
          tags: ['arcade'],
          entry: LocalGameEntry(
            assetPath: 'app/index.html',
            statusLabel: 'SDK',
          ),
        ),
      ],
    );

    expect(
      repository.query(search: 'Example 竞速 2.0.0').games.single.id,
      'com.example.party',
    );
    expect(repository.query(search: 'Example missing').games, isEmpty);
  });

  test('损坏摘要进入预构建索引且只折叠拉丁字符大小写', () {
    const recoverable = GameSummary(
      id: 'com.example.repair',
      name: '待修复',
      version: '0.0.0',
      description: '',
      minPlayers: 1,
      maxPlayers: 1,
      supportsMultiplayer: false,
      displayModeLabel: '',
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      manifestError: 'ÉCOLE ΩFault 解析失败',
      entry: LocalGameEntry(
        assetPath: 'app/index.html',
        statusLabel: 'manifest_repair_required',
      ),
    );
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: const [recoverable],
    );

    expect(repository.query(search: 'école 解析').games, const [recoverable]);
    expect(repository.query(search: 'Ωfault').games, const [recoverable]);
    expect(repository.query(search: 'ωfault').games, isEmpty);
  });

  test('排序优先 launchCount，再按最近打开和语义版本', () {
    final hot = _oldGame.withUsage(
      lastOpenedAt: DateTime.utc(2026, 7, 20),
      launchCount: 5,
    );
    final recent = _newGame.withUsage(
      lastOpenedAt: DateTime.utc(2026, 7, 25),
      launchCount: 2,
    );
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: [recent, hot],
    );
    expect(repository.cachedGames.first.id, 'old');
  });

  test('开发工作区项目直接进入统一游戏库缓存', () {
    final repository = GameLibraryRepository(() async => const []);

    repository.upsert(_newGame);

    expect(repository.cachedGames, const [_newGame]);
    repository.remove(_newGame.id);
    expect(repository.cachedGames, isEmpty);
  });

  test('默认按最近打开时间倒序，未打开项目排在最后', () {
    final older = _oldGame.withLastOpenedAt(DateTime.utc(2026, 7, 23));
    final newer = _newGame.withLastOpenedAt(DateTime.utc(2026, 7, 24));
    final unopened = _thirdGame;
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: [unopened, older, newer],
    );

    expect(repository.cachedGames.map((game) => game.id), [
      'new',
      'old',
      'third',
    ]);

    repository.markLaunched('third', DateTime.utc(2026, 7, 25));
    expect(repository.cachedGames.map((game) => game.id), [
      'third',
      'new',
      'old',
    ]);

    repository.upsert(_thirdGame);
    expect(
      repository.cachedGames.first.lastOpenedAt,
      DateTime.utc(2026, 7, 25),
    );
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

GameSummary _indexedGame(int index) => GameSummary(
  id: 'com.example.game$index',
  name: 'Game $index',
  version: '1.0.0',
  author: 'Publisher',
  description: 'Indexed game',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: 'multi_screen',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(
    assetPath: 'game-$index/app/index.html',
    statusLabel: 'ready',
  ),
);

const _thirdGame = GameSummary(
  id: 'third',
  name: '未打开',
  version: '1.0.0',
  description: '',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏模式',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(assetPath: 'app/index.html', statusLabel: 'SDK'),
);
