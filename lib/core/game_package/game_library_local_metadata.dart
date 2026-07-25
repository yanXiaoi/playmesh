import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';

/// App-local library state. This file is outside every game package and is
/// never included in imports, exports, Developer Gateway downloads or history.
class GameLibraryLocalMetadataStore {
  GameLibraryLocalMetadataStore({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;
  static const maxEntries = 2048;
  Map<String, DateTime>? _cache;
  Future<void> _writeTail = Future<void>.value();

  Future<Map<String, DateTime>> readLastOpenedAt() async {
    final cached = _cache;
    if (cached != null) return Map.unmodifiable(cached);
    final file = await _file();
    final values = <String, DateTime>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final entries = decoded['lastOpenedAt'];
          if (entries is Map) {
            for (final entry in entries.entries) {
              final id = entry.key.toString().trim();
              final milliseconds = entry.value;
              if (id.isEmpty || milliseconds is! int || milliseconds < 0) {
                continue;
              }
              values[id] = DateTime.fromMillisecondsSinceEpoch(
                milliseconds,
                isUtc: true,
              );
            }
          }
        }
      } on Object {
        // Corrupt local metadata must never make the game library unavailable.
      }
    }
    _cache = values;
    return Map.unmodifiable(values);
  }

  Future<void> markOpened(String gameId, DateTime value) {
    final id = gameId.trim();
    if (id.isEmpty) throw ArgumentError.value(gameId, 'gameId');
    final normalized = value.toUtc();
    final operation = _writeTail.then((_) async {
      final values = Map<String, DateTime>.from(await readLastOpenedAt());
      values[id] = normalized;
      if (values.length > maxEntries) {
        final oldest = values.entries.toList()
          ..sort((left, right) => left.value.compareTo(right.value));
        for (final entry in oldest.take(values.length - maxEntries)) {
          values.remove(entry.key);
        }
      }
      _cache = values;
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'lastOpenedAt': {
            for (final entry in values.entries)
              entry.key: entry.value.millisecondsSinceEpoch,
          },
        }),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> remove(String gameId) {
    final id = gameId.trim();
    if (id.isEmpty) return Future<void>.value();
    final operation = _writeTail.then((_) async {
      final values = Map<String, DateTime>.from(await readLastOpenedAt());
      if (values.remove(id) == null) return;
      _cache = values;
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'lastOpenedAt': {
            for (final entry in values.entries)
              entry.key: entry.value.millisecondsSinceEpoch,
          },
        }),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<File> _file() async {
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    return File(
      '${root.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}app${Platform.pathSeparator}game-library.json',
    );
  }
}
