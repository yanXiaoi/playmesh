import '../../models/game_summary.dart';
import '../version/semantic_version.dart';

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
      onError: (_, _) => _clearRefresh(operation),
    );
    return operation;
  }

  GameLibraryQueryResult query({
    String search = '',
    int offset = 0,
    int? limit,
  }) {
    if (offset < 0 || (limit != null && limit < 1)) {
      throw ArgumentError('offset 必须非负，limit 为空或大于 0');
    }
    final keywords = _normalizeSearchText(search)
        .trim()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final matches = keywords.isEmpty
        ? _cache
        : _cache
              .where((entry) => keywords.every(entry.searchText.contains))
              .toList(growable: false);
    final start = offset.clamp(0, matches.length);
    final end = limit == null
        ? matches.length
        : (start + limit).clamp(start, matches.length);
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
      ..sort((left, right) => compareGameLibraryOrder(left.game, right.game));
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
    final existing = _cache
        .where((entry) => entry.game.id == game.id)
        .firstOrNull
        ?.game;
    if (existing != null &&
        game.lastOpenedAt == null &&
        game.launchCount == 0) {
      game = game.withUsage(
        lastOpenedAt: existing.lastOpenedAt,
        launchCount: existing.launchCount,
      );
    }
    final games = [
      ..._cache
          .where((entry) => entry.game.id != game.id)
          .map((entry) => entry.game),
      game,
    ];
    _replace(games, markRefreshed: true);
  }

  void markLaunched(String gameId, DateTime openedAt) {
    final games = _cache.map((entry) {
      return entry.game.id == gameId
          ? entry.game.withUsage(
              lastOpenedAt: openedAt.toUtc(),
              launchCount: entry.game.launchCount >= 9007199254740991
                  ? 9007199254740991
                  : entry.game.launchCount + 1,
            )
          : entry.game;
    }).toList();
    if (!games.any((game) => game.id == gameId)) return;
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
    : searchText = _normalizeSearchText(
        [
          game.id,
          game.name,
          game.author,
          game.description,
          game.version,
          ...game.tags,
          ?game.manifestError,
        ].join('\n'),
      );

  final GameSummary game;
  final String searchText;
}

String _normalizeSearchText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    buffer.write(_isLatinRune(rune) ? character.toLowerCase() : character);
  }
  return buffer.toString();
}

bool _isLatinRune(int rune) =>
    (rune >= 0x0041 && rune <= 0x007A) ||
    (rune >= 0x00C0 && rune <= 0x024F) ||
    (rune >= 0x1D00 && rune <= 0x1DBF) ||
    (rune >= 0x1E00 && rune <= 0x1EFF) ||
    (rune >= 0x2C60 && rune <= 0x2C7F) ||
    (rune >= 0xA720 && rune <= 0xA7FF) ||
    (rune >= 0xAB30 && rune <= 0xAB6F) ||
    (rune >= 0x10780 && rune <= 0x107BF);

int compareGameLibraryOrder(GameSummary left, GameSummary right) {
  final byLaunch = right.launchCount.compareTo(left.launchCount);
  if (byLaunch != 0) return byLaunch;
  final leftOpened = left.lastOpenedAt;
  final rightOpened = right.lastOpenedAt;
  if (leftOpened != null || rightOpened != null) {
    if (leftOpened == null) return 1;
    if (rightOpened == null) return -1;
    final byOpened = rightOpened.compareTo(leftOpened);
    if (byOpened != 0) return byOpened;
  }
  final leftVersion = SemanticVersion.tryParse(left.version);
  final rightVersion = SemanticVersion.tryParse(right.version);
  if (leftVersion != null || rightVersion != null) {
    if (leftVersion == null) return 1;
    if (rightVersion == null) return -1;
    final byVersion = rightVersion.compareTo(leftVersion);
    if (byVersion != 0) return byVersion;
  }
  final byName = left.name.compareTo(right.name);
  return byName != 0 ? byName : left.id.compareTo(right.id);
}
