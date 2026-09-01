import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../library/playmesh_library_root.dart';
import '../profile/avatar_image.dart';
import '../../models/game_id.dart';

class GameStorageService {
  GameStorageService._({
    required this.gameId,
    required Directory libraryRoot,
    required this._coordinator,
    required this._lease,
  }) : _binaryDirectory = Directory(
         '${libraryRoot.path}${Platform.pathSeparator}packages'
         '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
         '${Platform.pathSeparator}data',
       );

  static const _flushDelay = Duration(seconds: 2);
  static const _backgroundRetryDelay = Duration(milliseconds: 500);
  static const _dirtyFlushThreshold = 20;
  static const maxStandardJsonBytes = 10 * 1024 * 1024;
  static const maxLogicalBucketNameBytes = 64 * 1024;
  static const maxSynchronousBucketNameBytes = 4 * 1024;
  static const maxUploadBytes = 512 * 1024 * 1024;
  static const systemAvatarBucket = '_sys-user-avatars';
  static const gdevelopStorageRootKey = r'$playmesh.gdevelop.root.v1';
  static const _mappedBucketFormat = 'playmesh.logical-bucket.v1';
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
  static final _revisionPattern = RegExp(r'^[a-f0-9]{64}$');
  static final Map<String, Future<void>> _pathOperations = {};
  static final Map<String, _GameStorageCoordinator> _gameCoordinators = {};
  static int _temporarySequence = 0;
  static int _lastUploadTimestamp = 0;

  final String gameId;
  final _GameStorageCoordinator _coordinator;
  final _GameStorageLease _lease;
  final Directory _binaryDirectory;
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeOperation;

  static Future<GameStorageService> create({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('无效的 gameId');
    }
    final root = libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    final packageDirectory = _packageDirectoryFor(root, gameId);
    final coordinator = _coordinatorFor(packageDirectory);
    final lease = await coordinator.acquire(packageDirectory);
    return GameStorageService._(
      gameId: gameId,
      libraryRoot: root,
      coordinator: coordinator,
      lease: lease,
    );
  }

  Future<Object?> getData(String bucket, String key) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    return _coordinator.withBucket(bucket, (state) => state.values[key]);
  }

  Future<void> setData(String bucket, String key, Object? value) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > maxStandardJsonBytes) {
      throw const FormatException('单个游戏数据值超过 10 MiB');
    }
    await _coordinator.withBucket(bucket, (state) {
      final next = Map<String, Object?>.from(state.values)
        ..[key] = jsonDecode(encoded);
      _validateStandardBucketSize(next);
      state.values
        ..clear()
        ..addAll(next);
      _coordinator.markDirty(bucket, state);
    });
  }

  Future<void> removeData(String bucket, String key) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    await _coordinator.withBucket(bucket, (state) {
      if (state.values.containsKey(key)) {
        state.values.remove(key);
        _coordinator.markDirty(bucket, state);
      }
    });
  }

  Future<void> clearData(String bucket) async {
    _ensureOpen();
    _validatePublicBucket(bucket);
    await _coordinator.withBucket(bucket, (state) {
      state.values.clear();
      _coordinator.markDirty(bucket, state);
    });
  }

  /// 平台内部逻辑桶允许 GDevelop 原始 storageFile 名称。
  /// 名称只进入哈希映射和可校验 envelope，不作为物理路径。
  Future<Object?> getLogicalData(String bucket, String key) async {
    _ensureOpen();
    _validateLogicalBucketName(bucket);
    return _coordinator.withBucket(bucket, (state) => state.values[key]);
  }

  Future<void> setLogicalData(String bucket, String key, Object? value) async {
    _ensureOpen();
    _validateLogicalBucketName(bucket);
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > maxStandardJsonBytes) {
      throw const FormatException('单个游戏数据值超过 10 MiB');
    }
    await _coordinator.withBucket(bucket, (state) {
      final next = Map<String, Object?>.from(state.values)
        ..[key] = jsonDecode(encoded);
      _validateStandardBucketSize(next);
      state.values
        ..clear()
        ..addAll(next);
      _coordinator.markDirty(bucket, state);
    });
  }

  /// 仅供已鉴权的同源私有协议读取逻辑桶及内存中的当前修订。
  ///
  /// 这个入口不是游戏公开 Bucket API；它允许 GDevelop 的原始
  /// storageFile 名和平台保留根 key，但仍受 4096 UTF-8 字节名称与
  /// 10 MiB JSON 限制。
  Future<GameStorageVersionedValue> getLogicalDataVersioned(
    String bucket,
    String key,
  ) async {
    _ensureOpen();
    _validateSynchronousBucketName(bucket);
    _validatePrivateLogicalKey(key);
    return _getDataVersioned(bucket, key);
  }

  /// 在同一项目、同一逻辑桶队列中原子比较修订并写入。
  Future<String> setLogicalDataIfRevision(
    String bucket,
    String key,
    Object? value, {
    required String expectedRevision,
  }) async {
    _ensureOpen();
    _validateSynchronousBucketName(bucket);
    _validatePrivateLogicalKey(key);
    return _setDataIfRevision(
      bucket,
      key,
      value,
      expectedRevision: expectedRevision,
    );
  }

  /// 仅供已鉴权的标准 JSON HTTP 路由使用；公开 SDK 仍只暴露
  /// `getData`/`setData`/`removeData`/`clearData` 的原有形状。
  Future<GameStorageVersionedValue> getDataVersioned(
    String bucket,
    String key,
  ) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    return _getDataVersioned(bucket, key);
  }

  Future<String> setDataIfRevision(
    String bucket,
    String key,
    Object? value, {
    required String expectedRevision,
  }) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    return _setDataIfRevision(
      bucket,
      key,
      value,
      expectedRevision: expectedRevision,
    );
  }

  Future<String> removeDataIfRevision(
    String bucket,
    String key, {
    required String expectedRevision,
  }) async {
    _ensureOpen();
    _validatePublicBucketAndKey(bucket, key);
    _validateRevision(expectedRevision);
    return _coordinator.withBucket(bucket, (state) async {
      final currentRevision = await _bucketRevision(state.values);
      if (currentRevision != expectedRevision) {
        throw GameStorageRevisionConflictException(currentRevision);
      }
      if (state.values.containsKey(key)) {
        state.values.remove(key);
        _coordinator.markDirty(bucket, state);
      }
      return _bucketRevision(state.values);
    });
  }

  Future<String> clearDataIfRevision(
    String bucket, {
    required String expectedRevision,
  }) async {
    _ensureOpen();
    _validatePublicBucket(bucket);
    _validateRevision(expectedRevision);
    return _coordinator.withBucket(bucket, (state) async {
      final currentRevision = await _bucketRevision(state.values);
      if (currentRevision != expectedRevision) {
        throw GameStorageRevisionConflictException(currentRevision);
      }
      state.values.clear();
      _coordinator.markDirty(bucket, state);
      return _bucketRevision(state.values);
    });
  }

  Future<GameStorageVersionedValue> _getDataVersioned(
    String bucket,
    String key,
  ) {
    return _coordinator.withBucket(bucket, (state) async {
      final revision = await _bucketRevision(state.values);
      return GameStorageVersionedValue(
        value: state.values[key],
        revision: revision,
      );
    });
  }

  Future<String> _setDataIfRevision(
    String bucket,
    String key,
    Object? value, {
    required String expectedRevision,
  }) async {
    _validateRevision(expectedRevision);
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > maxStandardJsonBytes) {
      throw const FormatException('单个游戏数据值超过 10 MiB');
    }
    return _coordinator.withBucket(bucket, (state) async {
      final currentRevision = await _bucketRevision(state.values);
      if (currentRevision != expectedRevision) {
        throw GameStorageRevisionConflictException(currentRevision);
      }
      final next = Map<String, Object?>.from(state.values)
        ..[key] = jsonDecode(encoded);
      _validateStandardBucketSize(next);
      state.values
        ..clear()
        ..addAll(next);
      _coordinator.markDirty(bucket, state);
      return _bucketRevision(state.values);
    });
  }

  static void _validateRevision(String value) {
    if (!_revisionPattern.hasMatch(value)) {
      throw const FormatException('存储修订号无效');
    }
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
      throw const FormatException('上传文件不能超过 512 MiB');
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
            throw const FormatException('上传文件不能超过 512 MiB');
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

  Future<void> flushAll() {
    _ensureOpen();
    return _coordinator.flushAll();
  }

  Future<void> close() => _closeOperation ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    try {
      await _lease.release();
    } finally {
      _closed = true;
    }
  }

  static Future<void> clearGameData({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('无效的 gameId');
    }
    final root = libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    final packageDirectory = _packageDirectoryFor(root, gameId);
    final coordinator = _coordinatorFor(packageDirectory);
    await coordinator.clear(packageDirectory, () async {
      final dataDirectory = Directory(
        '${packageDirectory.path}${Platform.pathSeparator}data',
      );
      if (await dataDirectory.exists()) {
        await dataDirectory.delete(recursive: true);
      }
    });
  }

  static Directory _packageDirectoryFor(Directory root, String gameId) =>
      Directory(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId',
      );

  static _GameStorageCoordinator _coordinatorFor(Directory packageDirectory) {
    final normalizedPath = packageDirectory.absolute.uri
        .normalizePath()
        .toFilePath(windows: Platform.isWindows);
    var key = normalizedPath;
    if (Platform.isWindows) key = key.toLowerCase();
    return _gameCoordinators.putIfAbsent(
      key,
      () => _GameStorageCoordinator(
        packageDirectory: Directory(normalizedPath),
        onIdle: (coordinator) {
          if (identical(_gameCoordinators[key], coordinator)) {
            _gameCoordinators.remove(key);
          }
        },
      ),
    );
  }

  void _ensureOpen() {
    if (_closing || _closed) {
      throw StateError('游戏存储实例已关闭');
    }
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

  static void _validateLogicalBucketName(String value) {
    if (utf8.encode(value).length > maxLogicalBucketNameBytes) {
      throw const FormatException('Bucket 逻辑名称超过 64 KiB');
    }
  }

  static void _validateSynchronousBucketName(String value) {
    final length = utf8.encode(value).length;
    if (length < 1 || length > maxSynchronousBucketNameBytes) {
      throw const FormatException('同步 Bucket 逻辑名必须为 1 至 4096 个 UTF-8 字节');
    }
  }

  static bool _isLegacyBucketName(String value) =>
      !value.startsWith('_sys-') && _bucketPattern.hasMatch(value);

  static void _validateStandardBucketSize(Map<String, Object?> values) {
    if (utf8.encode(jsonEncode(values)).length > maxStandardJsonBytes) {
      throw const FormatException('Bucket JSON 序列化总量超过 10 MiB');
    }
  }

  static void _validatePlayerId(String value) {
    if (!_playerIdPattern.hasMatch(value)) {
      throw const FormatException('无效的会话玩家 ID');
    }
  }

  static void _validatePrivateLogicalKey(String value) {
    if (value == gdevelopStorageRootKey) return;
    if (!_keyPattern.hasMatch(value)) {
      throw const FormatException('无效的游戏数据 key');
    }
  }

  static Future<String> _bucketRevision(Map<String, Object?> values) async {
    final hash = await Sha256().hash(utf8.encode(jsonEncode(values)));
    return hash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
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
  _BucketState(this.values, this.file);

  final Map<String, Object?> values;
  final _BucketFile file;
  bool dirty = false;
  int dirtyWrites = 0;
  int version = 0;
  Timer? timer;
}

class _BucketFile {
  const _BucketFile(this.target, {this.digest});

  final File target;
  final String? digest;

  bool get mapped => digest != null;
}

class GameStorageBusyException implements Exception {
  const GameStorageBusyException();

  @override
  String toString() => '当前游戏仍有运行中的存储实例';
}

class GameStorageVersionedValue {
  const GameStorageVersionedValue({
    required this.value,
    required this.revision,
  });

  final Object? value;
  final String revision;
}

class GameStorageRevisionConflictException implements Exception {
  const GameStorageRevisionConflictException(this.currentRevision);

  final String currentRevision;

  @override
  String toString() => '存储修订已发生变化';
}

class _GameStorageCoordinator {
  _GameStorageCoordinator({
    required Directory packageDirectory,
    required this._onIdle,
  }) : _jsonDirectory = Directory(
         '${packageDirectory.path}${Platform.pathSeparator}data'
         '${Platform.pathSeparator}json',
       );

  final Directory _jsonDirectory;
  final void Function(_GameStorageCoordinator coordinator) _onIdle;
  final Map<String, _BucketSlot> _buckets = {};
  Future<void> _tail = Future<void>.value();
  Future<void> _flushTail = Future<void>.value();
  int _activeInstances = 0;
  int _pendingLifecycleOperations = 0;
  RandomAccessFile? _sharedLockHandle;

  Future<_GameStorageLease> acquire(Directory packageDirectory) {
    return _synchronized(() async {
      await packageDirectory.create(recursive: true);
      if (_sharedLockHandle == null) {
        final handle = await _lockFile(
          packageDirectory,
        ).open(mode: FileMode.append);
        try {
          await handle.lock(FileLock.shared);
        } on Object {
          await handle.close();
          rethrow;
        }
        _sharedLockHandle = handle;
      }
      _activeInstances += 1;
      return _GameStorageLease(this);
    });
  }

  Future<void> release(_GameStorageLease lease) {
    return _synchronized(() async {
      if (lease._released) return;
      lease._released = true;
      _activeInstances -= 1;
      if (_activeInstances != 0) return;

      for (final slot in _buckets.values) {
        slot.state?.timer?.cancel();
        if (slot.state != null) slot.state!.timer = null;
      }
      Object? flushError;
      StackTrace? flushStackTrace;
      try {
        await flushAll();
      } on Object catch (error, stackTrace) {
        flushError = error;
        flushStackTrace = stackTrace;
      }

      final handle = _sharedLockHandle;
      _sharedLockHandle = null;
      try {
        if (handle != null) await handle.unlock();
      } finally {
        await handle?.close();
      }
      _buckets.clear();
      if (flushError != null) {
        Error.throwWithStackTrace(flushError, flushStackTrace!);
      }
    });
  }

  Future<T> withBucket<T>(
    String bucket,
    FutureOr<T> Function(_BucketState state) action,
  ) {
    final slot = _buckets.putIfAbsent(bucket, _BucketSlot.new);
    return slot.synchronized(() async {
      final state = slot.state ??= await _loadBucket(bucket);
      return action(state);
    });
  }

  void markDirty(String bucket, _BucketState state) {
    state
      ..dirty = true
      ..dirtyWrites += 1
      ..version += 1;
    state.timer?.cancel();
    if (state.dirtyWrites >= GameStorageService._dirtyFlushThreshold) {
      state.timer = Timer(
        Duration.zero,
        () => _flushInBackground(bucket, state),
      );
    } else {
      state.timer = Timer(
        GameStorageService._flushDelay,
        () => _flushInBackground(bucket, state),
      );
    }
  }

  Future<void> flushAll() {
    final previous = _flushTail;
    late final Future<void> current;
    current = () async {
      try {
        await previous;
      } on Object {
        // 一次刷新失败不能破坏后续项目刷新队列。
      }
      final buckets = _buckets.entries
          .where((entry) => entry.value.state != null)
          .map((entry) => entry.key)
          .toList(growable: false);
      await Future.wait(buckets.map(_flushBucket));
    }();
    _flushTail = current;
    return current;
  }

  Future<_BucketState> _loadBucket(String bucket) async {
    final bucketFile = await _bucketFile(bucket);
    final file = bucketFile.target;
    var values = <String, Object?>{};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (bucketFile.mapped) {
        if (decoded is! Map ||
            decoded['format'] != GameStorageService._mappedBucketFormat ||
            decoded['bucket'] != bucket ||
            decoded['bucketSha256'] != bucketFile.digest ||
            decoded['values'] is! Map) {
          throw const FormatException('Bucket 映射 envelope 校验失败');
        }
        values = (decoded['values'] as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        );
      } else {
        if (decoded is! Map) {
          throw const FormatException('Bucket 文件根节点必须是对象');
        }
        values = decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      GameStorageService._validateStandardBucketSize(values);
    }
    return _BucketState(values, bucketFile);
  }

  Future<_BucketFile> _bucketFile(String bucket) async {
    if (GameStorageService._isLegacyBucketName(bucket)) {
      return _BucketFile(
        File('${_jsonDirectory.path}${Platform.pathSeparator}$bucket.json'),
      );
    }
    final hash = await Sha256().hash(utf8.encode(bucket));
    final digest = hash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return _BucketFile(
      File(
        '${_jsonDirectory.path}${Platform.pathSeparator}logical'
        '${Platform.pathSeparator}sha256-$digest.json',
      ),
      digest: digest,
    );
  }

  Future<void> _flushBucket(String bucket) {
    return withBucket(bucket, (state) async {
      state.timer?.cancel();
      state.timer = null;
      if (!state.dirty) return;
      final target = state.file.target;
      final version = state.version;
      final values = Map<String, Object?>.from(state.values);
      GameStorageService._validateStandardBucketSize(values);
      final content = jsonEncode(
        state.file.mapped
            ? <String, Object?>{
                'format': GameStorageService._mappedBucketFormat,
                'bucket': bucket,
                'bucketSha256': state.file.digest,
                'values': values,
              }
            : values,
      );
      await GameStorageService._withPathLock(target.path, () async {
        await target.parent.create(recursive: true);
        final sequence = GameStorageService._temporarySequence++;
        final temporary = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
        );
        try {
          await temporary.writeAsString(content, flush: true);
          await GameStorageService._replaceFileWithRetry(temporary, target);
        } finally {
          if (await temporary.exists()) {
            try {
              await temporary.delete();
            } on FileSystemException {
              // Windows 可能短暂锁定写入失败的临时文件；唯一名称可避免阻塞后续刷新。
            }
          }
        }
      });
      if (state.version == version) {
        state
          ..dirty = false
          ..dirtyWrites = 0;
      }
    });
  }

  void _flushInBackground(String bucket, _BucketState state) {
    state.timer = null;
    unawaited(
      _flushBucket(bucket).catchError((Object _) {
        if (_activeInstances != 0 && state.dirty) {
          state.timer?.cancel();
          state.timer = Timer(
            GameStorageService._backgroundRetryDelay,
            () => _flushInBackground(bucket, state),
          );
        }
      }),
    );
  }

  Future<void> clear(
    Directory packageDirectory,
    Future<void> Function() action,
  ) {
    return _synchronized(() async {
      if (_activeInstances != 0) throw const GameStorageBusyException();
      await packageDirectory.create(recursive: true);
      final handle = await _lockFile(
        packageDirectory,
      ).open(mode: FileMode.append);
      var locked = false;
      try {
        try {
          await handle.lock(FileLock.exclusive);
          locked = true;
        } on FileSystemException {
          throw const GameStorageBusyException();
        }
        await action();
        _buckets.clear();
      } finally {
        if (locked) await handle.unlock();
        await handle.close();
      }
    });
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    _pendingLifecycleOperations += 1;
    final previous = _tail;
    final result = Completer<T>();
    _tail = () async {
      try {
        await previous;
      } on Object {
        // 一次项目存储操作失败不能破坏后续项目队列。
      }
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pendingLifecycleOperations -= 1;
        if (_pendingLifecycleOperations == 0 &&
            _activeInstances == 0 &&
            _sharedLockHandle == null) {
          _onIdle(this);
        }
      }
    }();
    return result.future;
  }

  static File _lockFile(Directory packageDirectory) => File(
    '${packageDirectory.path}${Platform.pathSeparator}.playmesh-storage.lock',
  );
}

class _GameStorageLease {
  _GameStorageLease(this._coordinator);

  final _GameStorageCoordinator _coordinator;
  bool _released = false;

  Future<void> release() => _coordinator.release(this);
}

class _BucketSlot {
  Future<void> _tail = Future<void>.value();
  _BucketState? state;

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final result = Completer<T>();
    _tail = () async {
      try {
        await previous;
      } on Object {
        // 一次桶操作失败不能破坏同桶后续队列。
      }
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }
}
