import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../library/playmesh_library_root.dart';
import '../profile/avatar_image.dart';
import '../../models/game_id.dart';

class GameStorageService {
  GameStorageService._({required this.gameId, required Directory libraryRoot})
    : _rootDataDirectory = Directory(
        '${libraryRoot.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data',
      ),
      _jsonDirectory = Directory(
        '${libraryRoot.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
        '${Platform.pathSeparator}json',
      ),
      _binaryDirectory = Directory(
        '${libraryRoot.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
        '${Platform.pathSeparator}data',
      );

  static const _flushDelay = Duration(seconds: 2);
  static const _backgroundRetryDelay = Duration(milliseconds: 500);
  static const _dirtyFlushThreshold = 20;
  static const _maxValueBytes = 256 * 1024;
  static const maxUploadBytes = 256 * 1024 * 1024;
  static const systemAvatarBucket = '_sys-user-avatars';
  static const _replaceAttempts = 8;
  static final _bucketPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
  static final _systemBucketPattern = RegExp(
    r'^_sys-[A-Za-z0-9][A-Za-z0-9_-]{0,58}$',
  );
  static final _keyPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
  static final _dataFilePattern = RegExp(
    r'^[0-9]{13,}(?:\.[A-Za-z0-9]{1,16})?$',
  );
  static final _extensionPattern = RegExp(r'^[A-Za-z0-9]{1,16}$');
  static final _playerIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
  static final Map<String, Future<void>> _pathOperations = {};
  static int _temporarySequence = 0;
  static int _lastUploadTimestamp = 0;

  final String gameId;
  final Directory _rootDataDirectory;
  final Directory _jsonDirectory;
  final Directory _binaryDirectory;
  final Map<String, _BucketState> _buckets = {};
  bool _closing = false;

  static Future<GameStorageService> create({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('无效的 gameId');
    }
    final root = libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    return GameStorageService._(gameId: gameId, libraryRoot: root);
  }

  Future<Object?> getData(String bucket, String key) async {
    _validatePublicBucketAndKey(bucket, key);
    return (await _load(bucket)).values[key];
  }

  Future<void> setData(String bucket, String key, Object? value) async {
    _validatePublicBucketAndKey(bucket, key);
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > _maxValueBytes) {
      throw const FormatException('单个游戏数据值超过 256 KiB');
    }
    final state = await _load(bucket);
    state.values[key] = jsonDecode(encoded);
    _markDirty(bucket, state);
  }

  Future<void> removeData(String bucket, String key) async {
    _validatePublicBucketAndKey(bucket, key);
    final state = await _load(bucket);
    if (state.values.containsKey(key)) {
      state.values.remove(key);
      _markDirty(bucket, state);
    }
  }

  Future<void> clearData(String bucket) async {
    _validatePublicBucket(bucket);
    final state = await _load(bucket);
    state.values.clear();
    _markDirty(bucket, state);
  }

  /// 将文件流保存到公开数据区，返回游戏页面可直接访问的同源路径。
  Future<String> upload({
    required String bucket,
    required String originalName,
    required Stream<List<int>> data,
    int? contentLength,
  }) async {
    _validatePublicBucket(bucket);
    if (contentLength != null && contentLength > maxUploadBytes) {
      throw const FormatException('上传文件不能超过 256 MiB');
    }
    final extension = _safeExtension(originalName);
    final now = DateTime.now().millisecondsSinceEpoch;
    final timestamp = now > _lastUploadTimestamp
        ? now
        : _lastUploadTimestamp + 1;
    _lastUploadTimestamp = timestamp;
    final fileName = '$timestamp${extension == null ? '' : '.$extension'}';
    final bucketDirectory = Directory(
      '${_binaryDirectory.path}${Platform.pathSeparator}$bucket',
    );
    final target = File(
      '${bucketDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await _withPathLock(target.path, () async {
      await bucketDirectory.create(recursive: true);
      final sequence = _temporarySequence++;
      final temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
      );
      var written = 0;
      IOSink? sink;
      try {
        sink = temporary.openWrite();
        await for (final chunk in data) {
          written += chunk.length;
          if (written > maxUploadBytes) {
            throw const FormatException('上传文件不能超过 256 MiB');
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        await _replaceFileWithRetry(temporary, target);
      } finally {
        await sink?.close();
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // 临时文件名唯一，Windows 短暂占用不会阻塞后续上传。
          }
        }
      }
    });
    return '/bucket/$bucket/$fileName';
  }

  /// 将会话头像写入平台私有 Bucket。游戏脚本无法通过数据或上传 API
  /// 创建、覆盖或枚举该路径。
  Future<String> writeUserAvatar({
    required String playerId,
    required Uint8List pngBytes,
    required String sha256,
  }) async {
    _validatePlayerId(playerId);
    final avatar = await AvatarImage.validate(pngBytes);
    if (avatar.sha256 != sha256) {
      throw const FormatException('系统头像摘要不匹配');
    }
    final target = _userAvatarFile(playerId);
    await _withPathLock(target.path, () async {
      await target.parent.create(recursive: true);
      final sequence = _temporarySequence++;
      final temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
      );
      try {
        await temporary.writeAsBytes(avatar.pngBytes, flush: true);
        await _replaceFileWithRetry(temporary, target);
      } finally {
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // 唯一临时文件不会影响下一次头像提交。
          }
        }
      }
    });
    return '/bucket/$systemAvatarBucket/$playerId.png';
  }

  Future<void> clearSystemAvatars() async {
    final directory = Directory(
      '${_binaryDirectory.path}${Platform.pathSeparator}$systemAvatarBucket',
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<String> avatarEtag(String playerId) async {
    _validatePlayerId(playerId);
    final avatar = await AvatarImage.validate(
      await _userAvatarFile(playerId).readAsBytes(),
    );
    return '"sha256-${avatar.sha256}"';
  }

  /// 解析同源数据区文件。普通 Bucket 公开；系统头像 Bucket 只允许精确文件名。
  /// JSON 数据目录不会经过此入口。
  File dataFile(String bucket, String fileName) {
    if (bucket == systemAvatarBucket) {
      if (!fileName.endsWith('.png')) {
        throw const FormatException('系统头像文件名无效');
      }
      final playerId = fileName.substring(0, fileName.length - 4);
      _validatePlayerId(playerId);
      return _userAvatarFile(playerId);
    }
    _validatePublicBucket(bucket);
    if (!_dataFilePattern.hasMatch(fileName)) {
      throw const FormatException('Bucket 文件名无效');
    }
    return File(
      '${_binaryDirectory.path}${Platform.pathSeparator}$bucket'
      '${Platform.pathSeparator}$fileName',
    );
  }

  Future<void> _flushBucket(String bucket) async {
    _validatePublicBucket(bucket);
    final state = await _load(bucket);
    state.timer?.cancel();
    state.timer = null;
    final target = File(
      '${_jsonDirectory.path}${Platform.pathSeparator}$bucket.json',
    );
    await _withPathLock(target.path, () async {
      if (!state.dirty) return;
      final version = state.version;
      final content = jsonEncode(Map<String, Object?>.from(state.values));
      await _jsonDirectory.create(recursive: true);
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
            // Windows 可能短暂锁定写入失败的临时文件；唯一名称可避免阻塞后续刷新。
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
    if (await storage._rootDataDirectory.exists()) {
      await storage._rootDataDirectory.delete(recursive: true);
    }
  }

  Future<_BucketState> _load(String bucket) async {
    _validatePublicBucket(bucket);
    final cached = _buckets[bucket];
    if (cached != null) return cached;
    final file = File(
      '${_jsonDirectory.path}${Platform.pathSeparator}$bucket.json',
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
              // 一次写入失败不能永久破坏单文件队列。
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

  File _userAvatarFile(String playerId) {
    _validateSystemBucket(systemAvatarBucket);
    return File(
      '${_binaryDirectory.path}${Platform.pathSeparator}$systemAvatarBucket'
      '${Platform.pathSeparator}$playerId.png',
    );
  }

  static void _validatePublicBucketAndKey(String bucket, String key) {
    _validatePublicBucket(bucket);
    if (!_keyPattern.hasMatch(key)) throw const FormatException('无效的游戏数据 key');
  }

  static void _validatePublicBucket(String value) {
    if (value.startsWith('_sys-')) {
      throw const FormatException('Bucket 名称使用了平台保留前缀 _sys-');
    }
    if (!_bucketPattern.hasMatch(value)) {
      throw const FormatException(
        'Bucket 名称必须以字母或数字开头，只能包含字母、数字、下划线和连字符，且不超过 64 个字符',
      );
    }
  }

  static void _validatePlayerId(String value) {
    if (!_playerIdPattern.hasMatch(value)) {
      throw const FormatException('无效的会话玩家 ID');
    }
  }

  static void _validateSystemBucket(String value) {
    if (!_systemBucketPattern.hasMatch(value)) {
      throw const FormatException('无效的平台系统 Bucket');
    }
  }

  static String? _safeExtension(String originalName) {
    if (originalName.isEmpty || originalName.contains('\u0000')) {
      throw const FormatException('上传文件名无效');
    }
    final normalized = originalName.replaceAll('\\', '/');
    final baseName = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = baseName.lastIndexOf('.');
    if (dot <= 0 || dot == baseName.length - 1) return null;
    final extension = baseName.substring(dot + 1);
    if (!_extensionPattern.hasMatch(extension)) {
      throw const FormatException('文件后缀只能包含 1 至 16 个字母或数字');
    }
    return extension;
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
