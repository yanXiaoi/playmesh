import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';

class GameStorageService {
  GameStorageService._({required this.gameId, required Directory libraryRoot})
    : _dataDirectory = Directory(
        '${libraryRoot.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data',
      );

  static const _flushDelay = Duration(seconds: 2);
  static const _backgroundRetryDelay = Duration(milliseconds: 500);
  static const _dirtyFlushThreshold = 20;
  static const _maxValueBytes = 256 * 1024;
  static const _replaceAttempts = 8;
  static final _gameIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  static final _bucketPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
  static final _keyPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
  static final Map<String, Future<void>> _pathOperations = {};
  static int _temporarySequence = 0;

  final String gameId;
  final Directory _dataDirectory;
  final Map<String, _BucketState> _buckets = {};
  bool _closing = false;

  static Future<GameStorageService> create({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    if (!_gameIdPattern.hasMatch(gameId)) {
      throw const FormatException('无效的 gameId');
    }
    final root = libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    return GameStorageService._(gameId: gameId, libraryRoot: root);
  }

  Future<Object?> getData(String bucket, String key) async {
    _validateBucketAndKey(bucket, key);
    return (await _load(bucket)).values[key];
  }

  Future<void> setData(String bucket, String key, Object? value) async {
    _validateBucketAndKey(bucket, key);
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > _maxValueBytes) {
      throw const FormatException('单个游戏数据值超过 256 KiB');
    }
    final state = await _load(bucket);
    state.values[key] = jsonDecode(encoded);
    _markDirty(bucket, state);
  }

  Future<void> removeData(String bucket, String key) async {
    _validateBucketAndKey(bucket, key);
    final state = await _load(bucket);
    if (state.values.containsKey(key)) {
      state.values.remove(key);
      _markDirty(bucket, state);
    }
  }

  Future<void> clearData(String bucket) async {
    _validateBucket(bucket);
    final state = await _load(bucket);
    state.values.clear();
    _markDirty(bucket, state);
  }

  Future<void> _flushBucket(String bucket) async {
    _validateBucket(bucket);
    final state = await _load(bucket);
    state.timer?.cancel();
    state.timer = null;
    final target = File(
      '${_dataDirectory.path}${Platform.pathSeparator}$bucket.json',
    );
    await _withPathLock(target.path, () async {
      if (!state.dirty) return;
      final version = state.version;
      final content = jsonEncode(Map<String, Object?>.from(state.values));
      await _dataDirectory.create(recursive: true);
      final sequence = _temporarySequence++;
      final temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
      );
      try {
        await temporary.writeAsString(content, flush: true);
        await _replaceFileWithRetry(temporary, target);
      } finally {
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // Windows may keep a failed temporary write locked briefly. A
            // unique name prevents it from blocking subsequent flushes.
          }
        }
      }
      if (state.version == version) {
        state
          ..dirty = false
          ..dirtyWrites = 0;
      }
    });
  }

  Future<void> flushAll() async {
    for (final bucket in _buckets.keys.toList(growable: false)) {
      await _flushBucket(bucket);
    }
  }

  Future<void> close() async {
    _closing = true;
    for (final state in _buckets.values) {
      state.timer?.cancel();
      state.timer = null;
    }
    await flushAll();
  }

  static Future<void> clearGameData({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    final storage = await create(gameId: gameId, libraryRoot: libraryRoot);
    if (await storage._dataDirectory.exists()) {
      await storage._dataDirectory.delete(recursive: true);
    }
  }

  Future<_BucketState> _load(String bucket) async {
    _validateBucket(bucket);
    final cached = _buckets[bucket];
    if (cached != null) return cached;
    final file = File(
      '${_dataDirectory.path}${Platform.pathSeparator}$bucket.json',
    );
    var values = <String, Object?>{};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('Bucket 文件根节点必须是对象');
      values = decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return _buckets.putIfAbsent(bucket, () => _BucketState(values));
  }

  void _markDirty(String bucket, _BucketState state) {
    state
      ..dirty = true
      ..dirtyWrites += 1
      ..version += 1;
    state.timer?.cancel();
    if (state.dirtyWrites >= _dirtyFlushThreshold) {
      state.timer = Timer(
        Duration.zero,
        () => _flushInBackground(bucket, state),
      );
    } else {
      state.timer = Timer(_flushDelay, () => _flushInBackground(bucket, state));
    }
  }

  void _flushInBackground(String bucket, _BucketState state) {
    state.timer = null;
    unawaited(
      _flushBucket(bucket).catchError((Object _) {
        if (!_closing && state.dirty) {
          state.timer?.cancel();
          state.timer = Timer(
            _backgroundRetryDelay,
            () => _flushInBackground(bucket, state),
          );
        }
      }),
    );
  }

  static Future<void> _withPathLock(
    String path,
    Future<void> Function() action,
  ) {
    final previous = _pathOperations[path];
    late final Future<void> current;
    current =
        (() async {
          if (previous != null) {
            try {
              await previous;
            } on Object {
              // A failed write must not permanently poison the per-file queue.
            }
          }
          await action();
        })().whenComplete(() {
          if (identical(_pathOperations[path], current)) {
            _pathOperations.remove(path);
          }
        });
    _pathOperations[path] = current;
    return current;
  }

  static Future<void> _replaceFileWithRetry(File temporary, File target) async {
    for (var attempt = 0; attempt < _replaceAttempts; attempt += 1) {
      try {
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
        return;
      } on FileSystemException catch (error) {
        final retryable =
            Platform.isWindows &&
            const {5, 32, 33}.contains(error.osError?.errorCode);
        if (!retryable || attempt == _replaceAttempts - 1) rethrow;
        final backoffStep = attempt > 4 ? 4 : attempt;
        await Future<void>.delayed(
          Duration(milliseconds: 15 * (1 << backoffStep)),
        );
      }
    }
  }

  static void _validateBucketAndKey(String bucket, String key) {
    _validateBucket(bucket);
    if (!_keyPattern.hasMatch(key)) throw const FormatException('无效的游戏数据 key');
  }

  static void _validateBucket(String value) {
    if (!_bucketPattern.hasMatch(value)) {
      throw const FormatException(
        'Bucket 名称必须以字母或数字开头，只能包含字母、数字、下划线和连字符，且不超过 64 个字符',
      );
    }
  }
}

class _BucketState {
  _BucketState(this.values);

  final Map<String, Object?> values;
  bool dirty = false;
  int dirtyWrites = 0;
  int version = 0;
  Timer? timer;
}
