import '../../models/game_summary.dart';

typedef GameLibraryScan = Future<List<GameSummary>> Function();

class GameLibraryQueryResult {
  const GameLibraryQueryResult({
    required this.games,
    required this.total,
    required this.offset,
    required this.revision,
    required this.refreshedAt,
  });

  final List<GameSummary> games;
  final int total;
  final int offset;
  final int revision;
  final DateTime? refreshedAt;
}

class GameLibraryRepository {
  GameLibraryRepository(
    this._scan, {
    List<GameSummary> initialGames = const [],
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _replace(initialGames, markRefreshed: false);
  }

  final GameLibraryScan _scan;
  final DateTime Function() _now;
  List<_IndexedGame> _cache = const [];
  Future<List<GameSummary>>? _refreshOperation;
  int _revision = 0;
  DateTime? _refreshedAt;

  List<GameSummary> get cachedGames =>
      List.unmodifiable(_cache.map((entry) => entry.game));
  int get revision => _revision;
  DateTime? get refreshedAt => _refreshedAt;
  bool get isRefreshing => _refreshOperation != null;

  Future<List<GameSummary>> refresh() {
    final active = _refreshOperation;
    if (active != null) return active;
    final operation = _scanAndCache();
    _refreshOperation = operation;
    operation.then<void>(
      (_) => _clearRefresh(operation),
      onError: (Object _, StackTrace _) => _clearRefresh(operation),
    );
    return operation;
  }

  GameLibraryQueryResult query({
    String search = '',
    int offset = 0,
    int limit = 50,
  }) {
    if (offset < 0 || limit < 1) {
      throw ArgumentError('offset 必须非负且 limit 必须大于 0');
    }
    final keyword = search.trim().toLowerCase();
    final matches = keyword.isEmpty
        ? _cache
        : _cache
              .where((entry) => entry.searchText.contains(keyword))
              .toList(growable: false);
    final start = offset.clamp(0, matches.length);
    final end = (start + limit).clamp(start, matches.length);
    return GameLibraryQueryResult(
      games: List.unmodifiable(
        matches.sublist(start, end).map((entry) => entry.game),
      ),
      total: matches.length,
      offset: start,
      revision: _revision,
      refreshedAt: _refreshedAt,
    );
  }

  Future<List<GameSummary>> _scanAndCache() async {
    final games = await _scan();
    _replace(games, markRefreshed: true);
    return cachedGames;
  }

  void _replace(List<GameSummary> games, {required bool markRefreshed}) {
    final uniqueGames = <String, GameSummary>{};
    for (final game in games) {
      uniqueGames[game.id] = game;
    }
    final indexed = uniqueGames.values.map(_IndexedGame.new).toList()
      ..sort((left, right) {
        final byName = left.game.name.compareTo(right.game.name);
        return byName != 0 ? byName : left.game.id.compareTo(right.game.id);
      });
    _cache = List.unmodifiable(indexed);
    if (markRefreshed) {
      _revision += 1;
      _refreshedAt = _now();
    }
  }

  void remove(String gameId) {
    final next = _cache.where((entry) => entry.game.id != gameId).toList();
    if (next.length == _cache.length) return;
    _cache = List.unmodifiable(next);
    _revision += 1;
    _refreshedAt = _now();
  }

  void upsert(GameSummary game) {
    final games = [
      ..._cache
          .where((entry) => entry.game.id != game.id)
          .map((entry) => entry.game),
      game,
    ];
    _replace(games, markRefreshed: true);
  }

  void _clearRefresh(Future<List<GameSummary>> operation) {
    if (identical(_refreshOperation, operation)) {
      _refreshOperation = null;
    }
  }
}

class _IndexedGame {
  _IndexedGame(this.game)
    : searchText = [
        game.id,
        game.name,
        game.description,
        game.version,
        ...game.tags,
      ].join('\n').toLowerCase();

  final GameSummary game;
  final String searchText;
}
