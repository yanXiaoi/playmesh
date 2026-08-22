import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/game_id.dart';

/// 当前 Runtime 设备独占的 App SDK JSON Bucket。
final class RuntimeAppLocalBucketStore {
  RuntimeAppLocalBucketStore({
    required this.gameId,
    required String gameName,
    Directory? libraryRoot,
  }) : gameName = gameName.trim(),
       // 保留公开参数名 libraryRoot，同时不把测试用根目录暴露为字段。
       // ignore: prefer_initializing_formals
       _libraryRoot = libraryRoot {
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('App Bucket gameId 无效');
    }
    if (this.gameName.isEmpty) {
      throw const FormatException('App Bucket 游戏名称不能为空');
    }
  }

  static const maxBucketJsonBytes = 10 * 1024 * 1024;
  static const _replaceAttempts = 8;
  static final _bucketPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
  static final _keyPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
  static final Map<String, Future<void>> _pathOperations = {};
  static int _temporarySequence = 0;

  final String gameId;
  final String gameName;
  final Directory? _libraryRoot;

  Future<Object?> getData(String bucket, String key) {
    _validateBucketAndKey(bucket, key);
    return _withBucket(bucket, (values) => values[key]);
  }

  Future<void> setData(String bucket, String key, Object? value) {
    _validateBucketAndKey(bucket, key);
    final cloned = _cloneJson(value);
    return _withBucket(bucket, (values) async {
      values[key] = cloned;
      await _writeBucket(bucket, values);
    });
  }

  Future<void> removeData(String bucket, String key) {
    _validateBucketAndKey(bucket, key);
    return _withBucket(bucket, (values) async {
      values.remove(key);
      await _writeBucket(bucket, values);
    });
  }

  Future<void> clearData(String bucket) {
    _validateBucket(bucket);
    return _withBucket(bucket, (_) => _writeBucket(bucket, const {}));
  }

  Future<T> _withBucket<T>(
    String bucket,
    FutureOr<T> Function(Map<String, Object?> values) action,
  ) async {
    final file = await _bucketFile(bucket);
    return _withPathLock(file.absolute.path, () async {
      final values = await _readBucket(file);
      return action(values);
    });
  }

  Future<Map<String, Object?>> _readBucket(File file) async {
    if (!await file.exists()) return {};
    if (await file.length() > maxBucketJsonBytes) {
      throw const FormatException('App Bucket JSON 超过 10 MiB');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('App Bucket JSON 根节点必须是对象');
    }
    final values = <String, Object?>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String || !_keyPattern.hasMatch(key)) {
        throw const FormatException('App Bucket JSON 包含无效 key');
      }
      values[key] = entry.value;
    }
    return values;
  }

  Future<void> _writeBucket(String bucket, Map<String, Object?> values) async {
    final encoded = jsonEncode(values);
    if (utf8.encode(encoded).length > maxBucketJsonBytes) {
      throw const FormatException('App Bucket JSON 超过 10 MiB');
    }
    final target = await _bucketFile(bucket);
    await target.parent.create(recursive: true);
    final sequence = _temporarySequence++;
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
    );
    try {
      await temporary.writeAsString(encoded, flush: true);
      await _replaceFile(temporary, target);
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // 唯一临时文件不会影响后续 Bucket 操作。
        }
      }
    }
  }

  Future<File> _bucketFile(String bucket) async {
    final root = _libraryRoot ?? await _resolveLibraryRoot();
    return File(
      '${root.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}${_safeGameNameSegment(gameName)}'
      '${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}$bucket.json',
    );
  }

  static Future<Directory> _resolveLibraryRoot() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      return Directory(
        '${support.path}${Platform.pathSeparator}playmesh-library',
      );
    }
    return Directory(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}playmesh-library',
    );
  }

  static Object? _cloneJson(Object? value) {
    try {
      return jsonDecode(jsonEncode(value));
    } on Object {
      throw const FormatException('App Bucket 只能写入 JSON 值');
    }
  }

  static void _validateBucketAndKey(String bucket, String key) {
    _validateBucket(bucket);
    if (!_keyPattern.hasMatch(key)) {
      throw const FormatException(
        'App Bucket key 只能包含字母、数字、点、下划线和连字符，且长度为 1 至 128',
      );
    }
  }

  static void _validateBucket(String bucket) {
    if (!_bucketPattern.hasMatch(bucket)) {
      throw const FormatException(
        'App Bucket 名称必须以字母或数字开头，只能包含字母、数字、下划线和连字符，且不超过 64 个字符',
      );
    }
  }

  static String _safeGameNameSegment(String value) {
    final runes = value.runes.toList(growable: false);
    final buffer = StringBuffer();
    final encodeAllDots = value == '.' || value == '..';
    const invalid = '<>:"/\\|?*~';
    for (var index = 0; index < runes.length; index += 1) {
      final rune = runes[index];
      final character = String.fromCharCode(rune);
      final trailingUnsafe =
          index == runes.length - 1 && (character == '.' || character == ' ');
      if (encodeAllDots ||
          trailingUnsafe ||
          rune < 32 ||
          rune == 127 ||
          invalid.contains(character)) {
        buffer.write('~${rune.toRadixString(16).toUpperCase()}~');
      } else {
        buffer.write(character);
      }
    }
    var result = buffer.toString();
    final base = result.split('.').first.toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(base)) {
      final first = result.runes.first;
      result =
          '~${first.toRadixString(16).toUpperCase()}~'
          '${result.substring(String.fromCharCode(first).length)}';
    }
    if (utf8.encode(result).length <= 160) return result;
    final digest = sha256.convert(utf8.encode(value)).toString();
    final prefix = String.fromCharCodes(result.runes.take(48));
    return '$prefix~sha256-$digest';
  }

  static Future<T> _withPathLock<T>(String path, Future<T> Function() action) {
    final normalized = Platform.isWindows ? path.toLowerCase() : path;
    final previous = _pathOperations[normalized];
    late final Future<T> current;
    late final Future<void> barrier;
    current = (() async {
      if (previous != null) {
        try {
          await previous;
        } on Object {
          // 一次失败不能永久破坏同一 Bucket 的操作队列。
        }
      }
      return action();
    })();
    barrier = current.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pathOperations[normalized] = barrier;
    unawaited(
      barrier.whenComplete(() {
        if (identical(_pathOperations[normalized], barrier)) {
          _pathOperations.remove(normalized);
        }
      }),
    );
    return current;
  }

  static Future<void> _replaceFile(File temporary, File target) async {
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
}
