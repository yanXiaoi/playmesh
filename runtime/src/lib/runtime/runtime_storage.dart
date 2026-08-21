import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

final class RuntimeStorage {
  RuntimeStorage({required this.gameId, required this.file});

  final String gameId;
  final File file;
  final Map<String, Map<String, Object?>> _buckets = {};
  final Map<String, Future<void>> _pathOperations = {};
  Future<void> _writes = Future<void>.value();
  int _lastUploadTimestamp = 0;
  int _temporarySequence = 0;

  static const maxUploadBytes = 256 * 1024 * 1024;
  static const maxAvatarBytes = 512 * 1024;
  static const systemAvatarBucket = '_sys-user-avatars';
  static final _bucketPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
  static final _dataFilePattern = RegExp(
    r'^[0-9]{13,}(?:\.[A-Za-z0-9]{1,16})?$',
  );
  static final _extensionPattern = RegExp(r'^[A-Za-z0-9]{1,16}$');
  static final _playerIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  Directory get _binaryDirectory =>
      Directory('${file.parent.path}${Platform.pathSeparator}data');

  Future<void> load() async {
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return;
    for (final entry in decoded.entries) {
      if (entry.key is String && entry.value is Map) {
        _buckets[entry.key! as String] = Map<String, Object?>.from(
          entry.value! as Map,
        );
      }
    }
  }

  Future<Map<String, Object?>> execute(Map<String, Object?> request) async {
    final operation = _requiredString(request, 'operation');
    final bucketName = _requiredString(request, 'bucket');
    final bucket = _buckets.putIfAbsent(bucketName, () => {});
    final beforeRevision = _revision(bucket);
    final expected = request['expectedRevision'];
    if (expected != null && expected != beforeRevision) {
      throw const RuntimeStorageConflict();
    }
    switch (operation) {
      case 'get':
      case 'sync.get':
        return {
          'value': bucket[(_requiredString(request, 'key'))],
          'revision': beforeRevision,
        };
      case 'set':
      case 'sync.set':
        if (!request.containsKey('value')) {
          throw const FormatException('存储请求缺少 value');
        }
        bucket[_requiredString(request, 'key')] = request['value'];
      case 'remove':
        bucket.remove(_requiredString(request, 'key'));
      case 'clear':
        bucket.clear();
      default:
        throw FormatException('未知存储操作: $operation');
    }
    await _persist();
    return {'revision': _revision(bucket)};
  }

  String _revision(Map<String, Object?> bucket) =>
      sha256.convert(utf8.encode(jsonEncode(bucket))).toString();

  Future<void> _persist() {
    _writes = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(_buckets), flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    return _writes;
  }

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
      final temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}'
        '.${_temporarySequence++}.tmp',
      );
      IOSink? sink;
      var written = 0;
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
        await _replaceFile(temporary, target);
      } finally {
        await sink?.close();
        if (await temporary.exists()) await temporary.delete();
      }
    });
    return '/bucket/$bucket/$fileName';
  }

  Future<String> writeUserAvatar({
    required String playerId,
    required Uint8List pngBytes,
    required String sha256Digest,
  }) async {
    _validatePlayerId(playerId);
    final digest = await _validateAvatar(pngBytes);
    if (digest != sha256Digest) {
      throw const FormatException('系统头像摘要不匹配');
    }
    final target = _userAvatarFile(playerId);
    await _withPathLock(target.path, () async {
      await target.parent.create(recursive: true);
      final temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}'
        '.${_temporarySequence++}.tmp',
      );
      try {
        await temporary.writeAsBytes(pngBytes, flush: true);
        await _replaceFile(temporary, target);
      } finally {
        if (await temporary.exists()) await temporary.delete();
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
    final digest = await _validateAvatar(
      await _userAvatarFile(playerId).readAsBytes(),
    );
    return '"sha256-$digest"';
  }

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

  File _userAvatarFile(String playerId) => File(
    '${_binaryDirectory.path}${Platform.pathSeparator}$systemAvatarBucket'
    '${Platform.pathSeparator}$playerId.png',
  );

  Future<T> _withPathLock<T>(String path, Future<T> Function() action) async {
    final previous = _pathOperations[path] ?? Future<void>.value();
    final completer = Completer<void>();
    _pathOperations[path] = completer.future;
    try {
      await previous;
      return await action();
    } finally {
      completer.complete();
      if (identical(_pathOperations[path], completer.future)) {
        _pathOperations.remove(path);
      }
    }
  }

  Future<void> _replaceFile(File temporary, File target) async {
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static void _validatePublicBucket(String bucket) {
    if (!_bucketPattern.hasMatch(bucket) || bucket.startsWith('_sys-')) {
      throw const FormatException('Bucket 名称无效');
    }
  }

  static void _validatePlayerId(String playerId) {
    if (!_playerIdPattern.hasMatch(playerId)) {
      throw const FormatException('玩家 ID 无效');
    }
  }

  static String? _safeExtension(String originalName) {
    final normalized = originalName.replaceAll('\\', '/').split('/').last;
    final dot = normalized.lastIndexOf('.');
    if (dot <= 0 || dot == normalized.length - 1) return null;
    final extension = normalized.substring(dot + 1).toLowerCase();
    return _extensionPattern.hasMatch(extension) ? extension : null;
  }

  static Future<String> _validateAvatar(Uint8List bytes) async {
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.isEmpty || bytes.length > maxAvatarBytes || bytes.length < 24) {
      throw const FormatException('头像 PNG 不能超过 512 KiB');
    }
    for (var index = 0; index < signature.length; index += 1) {
      if (bytes[index] != signature[index]) {
        throw const FormatException('头像必须是 256 x 256 PNG');
      }
    }
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(16) != 256 || header.getUint32(20) != 256) {
      throw const FormatException('头像必须是 256 x 256 PNG');
    }
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      if (image.width != 256 || image.height != 256) {
        throw const FormatException('头像必须是 256 x 256 PNG');
      }
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('头像 PNG 数据损坏');
    } finally {
      image?.dispose();
      codec?.dispose();
    }
    return sha256.convert(bytes).toString();
  }
}

final class RuntimeStorageConflict implements Exception {
  const RuntimeStorageConflict();
}

String _requiredString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) throw FormatException('$key 无效');
  return value;
}
