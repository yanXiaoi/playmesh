import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';
import '../../models/game_id.dart';

final class GameLibraryUsageStats {
  const GameLibraryUsageStats({this.lastOpenedAt, this.launchCount = 0})
    : extensions = const {};

  GameLibraryUsageStats.withExtensions({
    this.lastOpenedAt,
    this.launchCount = 0,
    required Map<String, Object?> extensions,
  }) : extensions = _immutableJsonObject(extensions);

  static const maxLaunchCount = 9007199254740991;

  final DateTime? lastOpenedAt;
  final int launchCount;
  final Map<String, Object?> extensions;

  GameLibraryUsageStats launchedAt(DateTime value) =>
      GameLibraryUsageStats.withExtensions(
        lastOpenedAt: value.toUtc(),
        launchCount: launchCount >= maxLaunchCount
            ? maxLaunchCount
            : launchCount + 1,
        extensions: extensions,
      );

  Map<String, Object?> toJson({bool includeExtensions = true}) => {
    if (lastOpenedAt case final value?)
      'lastOpenedAt': value.millisecondsSinceEpoch,
    'launchCount': launchCount,
    if (includeExtensions) ...extensions,
  };
}

/// App-local usage state, never included in game packages or Catalog payloads.
class GameLibraryLocalMetadataStore {
  GameLibraryLocalMetadataStore({
    Directory? libraryRoot,
    DateTime Function()? now,
  }) : _injectedRoot = libraryRoot,
       _now = now ?? DateTime.now;

  static const formatVersion = 2;
  static const maxEntries = 2048;
  static const maxEntryBytes = 16 * 1024;
  static const maxFileBytes = 4 * 1024 * 1024;

  final Directory? _injectedRoot;
  final DateTime Function() _now;
  Map<String, GameLibraryUsageStats>? _cache;
  Future<void> _writeTail = Future<void>.value();

  Future<Map<String, GameLibraryUsageStats>> readUsageStats() async {
    final cached = _cache;
    if (cached != null) return Map.unmodifiable(cached);
    final file = await _file();
    var values = <String, GameLibraryUsageStats>{};
    var isolated = false;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map ||
            decoded['version'] != formatVersion ||
            decoded['games'] is! Map) {
          await _isolateUnsupported(file);
          isolated = true;
        } else {
          for (final entry in (decoded['games'] as Map).entries) {
            final id = entry.key.toString().trim();
            final raw = entry.value;
            if (!isValidPlaymeshGameId(id) || raw is! Map) continue;
            final stats = _parseStats(Map<String, Object?>.from(raw));
            if (stats != null) values[id] = stats;
          }
        }
      } on Object {
        await _isolateUnsupported(file);
        isolated = true;
        values = {};
      }
    }
    values = _prune(values);
    if (isolated) await _write(values);
    _cache = values;
    return Map.unmodifiable(values);
  }

  Future<Map<String, DateTime>> readLastOpenedAt() async => Map.unmodifiable({
    for (final entry in (await readUsageStats()).entries)
      entry.key: ?entry.value.lastOpenedAt,
  });

  Future<void> markLaunched(String gameId, DateTime openedAt) {
    final id = gameId.trim();
    if (!isValidPlaymeshGameId(id)) {
      throw ArgumentError.value(gameId, 'gameId', '游戏 ID 格式无效');
    }
    return _mutate((values) {
      values[id] = (values[id] ?? const GameLibraryUsageStats()).launchedAt(
        openedAt,
      );
    });
  }

  Future<void> remove(String gameId) {
    final id = gameId.trim();
    if (id.isEmpty) return Future<void>.value();
    return _mutate((values) => values.remove(id));
  }

  Future<void> retainGameIds(Iterable<String> gameIds) {
    final retained = gameIds.map((value) => value.trim()).toSet();
    return _mutate(
      (values) => values.removeWhere((key, _) => !retained.contains(key)),
    );
  }

  Future<void> _mutate(
    void Function(Map<String, GameLibraryUsageStats> values) action,
  ) {
    final operation = _writeTail.then((_) async {
      final values = Map<String, GameLibraryUsageStats>.from(
        await readUsageStats(),
      );
      action(values);
      final pruned = _prune(values);
      await _write(pruned);
      _cache = pruned;
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  GameLibraryUsageStats? _parseStats(Map<String, Object?> raw) {
    final timestamp = raw['lastOpenedAt'];
    final count = raw['launchCount'];
    if (timestamp != null && (timestamp is! int || timestamp < 0)) return null;
    if (count is! int ||
        count < 0 ||
        count > GameLibraryUsageStats.maxLaunchCount) {
      return null;
    }
    final extensions = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key != 'lastOpenedAt' &&
            entry.key != 'launchCount' &&
            _isJsonValue(entry.value))
          entry.key: entry.value,
    };
    DateTime? lastOpenedAt;
    if (timestamp is int) {
      try {
        lastOpenedAt = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
          isUtc: true,
        );
      } on Object {
        return null;
      }
    }
    var stats = GameLibraryUsageStats.withExtensions(
      lastOpenedAt: lastOpenedAt,
      launchCount: count,
      extensions: extensions,
    );
    if (utf8.encode(jsonEncode(stats.toJson())).length > maxEntryBytes) {
      stats = GameLibraryUsageStats(
        lastOpenedAt: stats.lastOpenedAt,
        launchCount: stats.launchCount,
      );
    }
    return stats;
  }

  Map<String, GameLibraryUsageStats> _prune(
    Map<String, GameLibraryUsageStats> input,
  ) {
    final values = Map<String, GameLibraryUsageStats>.from(input);
    final ordered = values.entries.toList()..sort(_evictionOrder);
    while (values.length > maxEntries && ordered.isNotEmpty) {
      values.remove(ordered.removeAt(0).key);
    }
    while (_encoded(values).length > maxFileBytes && ordered.isNotEmpty) {
      values.remove(ordered.removeAt(0).key);
    }
    return values;
  }

  int _evictionOrder(
    MapEntry<String, GameLibraryUsageStats> left,
    MapEntry<String, GameLibraryUsageStats> right,
  ) {
    final leftAt = left.value.lastOpenedAt;
    final rightAt = right.value.lastOpenedAt;
    if (leftAt == null || rightAt == null) {
      if (leftAt == null && rightAt != null) return -1;
      if (leftAt != null && rightAt == null) return 1;
    } else {
      final byTime = leftAt.compareTo(rightAt);
      if (byTime != 0) return byTime;
    }
    final byCount = left.value.launchCount.compareTo(right.value.launchCount);
    return byCount != 0 ? byCount : left.key.compareTo(right.key);
  }

  List<int> _encoded(Map<String, GameLibraryUsageStats> values) => utf8.encode(
    const JsonEncoder.withIndent('  ').convert({
      'version': formatVersion,
      'games': {
        for (final entry in values.entries) entry.key: entry.value.toJson(),
      },
    }),
  );

  Future<void> _write(Map<String, GameLibraryUsageStats> values) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final nonce = _now().toUtc().microsecondsSinceEpoch;
    final temporary = File('${file.path}.$nonce.tmp');
    final previous = File('${file.path}.$nonce.previous');
    await temporary.writeAsBytes(_encoded(values), flush: true);
    var movedPrevious = false;
    try {
      if (await file.exists()) {
        await file.rename(previous.path);
        movedPrevious = true;
      }
      await temporary.rename(file.path);
      if (movedPrevious && await previous.exists()) await previous.delete();
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      if (movedPrevious && await previous.exists() && !await file.exists()) {
        await previous.rename(file.path);
      }
      rethrow;
    }
  }

  Future<void> _isolateUnsupported(File file) async {
    if (!await file.exists()) return;
    final stamp = _now().toUtc().millisecondsSinceEpoch;
    var backup = File('${file.path}.$stamp.unsupported');
    var suffix = 0;
    while (await backup.exists()) {
      suffix += 1;
      backup = File('${file.path}.$stamp.$suffix.unsupported');
    }
    await file.rename(backup.path);
  }

  Future<File> _file() async {
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    return File(
      '${root.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}app${Platform.pathSeparator}game-library.json',
    );
  }
}

bool _isJsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return true;
  }
  if (value is List) return value.every(_isJsonValue);
  if (value is Map) {
    return value.keys.every((key) => key is String) &&
        value.values.every(_isJsonValue);
  }
  return false;
}

Map<String, Object?> _immutableJsonObject(Map<String, Object?> value) {
  return Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key: _immutableJsonValue(entry.value),
  });
}

Object? _immutableJsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJsonValue));
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(value, 'extensions', 'must be JSON data');
      }
      result[key] = _immutableJsonValue(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw ArgumentError.value(value, 'extensions', 'must be JSON data');
}
