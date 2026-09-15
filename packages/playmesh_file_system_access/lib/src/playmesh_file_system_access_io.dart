import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class PlaymeshFileSystemAccessException implements Exception {
  const PlaymeshFileSystemAccessException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class PlaymeshFileSystemAccessHost {
  PlaymeshFileSystemAccessHost({MethodChannel? androidChannel})
    : _androidChannel =
          androidChannel ?? const MethodChannel('playmesh/file_system_access');

  static const int maxTransferBytes = 512 * 1024;

  final MethodChannel _androidChannel;
  final Map<String, _FileSystemEntry> _entries = {};
  final Map<String, _WritableFile> _writers = {};
  final Random _random = Random.secure();
  bool _closed = false;

  Future<Object?> execute(String command, Map<String, Object?> payload) async {
    if (_closed) {
      throw const PlaymeshFileSystemAccessException(
        'invalid_state',
        '文件系统桥已关闭',
      );
    }
    if (Platform.isAndroid) return _executeAndroid(command, payload);
    if (!Platform.isWindows) {
      throw const PlaymeshFileSystemAccessException(
        'not_supported',
        '当前平台不支持原生文件系统访问',
      );
    }
    try {
      return await _executeWindows(command, payload);
    } on PlaymeshFileSystemAccessException {
      rethrow;
    } on FileSystemException catch (error) {
      throw PlaymeshFileSystemAccessException(
        _fileSystemErrorCode(error),
        error.message,
      );
    } on ArgumentError catch (error) {
      throw PlaymeshFileSystemAccessException(
        'invalid_argument',
        error.message?.toString() ?? '文件系统参数无效',
      );
    }
  }

  Future<Object?> _executeAndroid(
    String command,
    Map<String, Object?> payload,
  ) async {
    try {
      return await _androidChannel.invokeMethod<Object?>(command, payload);
    } on PlatformException catch (error) {
      throw PlaymeshFileSystemAccessException(
        error.code.isEmpty ? 'native_error' : error.code,
        error.message ?? 'Android 文件系统操作失败',
      );
    } on MissingPluginException {
      throw const PlaymeshFileSystemAccessException(
        'not_supported',
        'Android 文件系统桥未安装',
      );
    }
  }

  Future<Object?> _executeWindows(
    String command,
    Map<String, Object?> payload,
  ) async {
    switch (command) {
      case 'pickOpen':
        return _pickOpen(payload);
      case 'pickSave':
        return _pickSave(payload);
      case 'pickDirectory':
        return _pickDirectory(payload);
      case 'stat':
        return _stat(_entry(payload));
      case 'read':
        return _read(payload);
      case 'createWritable':
        return _createWritable(payload);
      case 'write':
        await _write(payload);
        return null;
      case 'seek':
        await _seek(payload);
        return null;
      case 'truncate':
        await _truncate(payload);
        return null;
      case 'closeWritable':
        await _closeWritable(payload);
        return null;
      case 'abortWritable':
        await _abortWritable(payload);
        return null;
      case 'list':
        return _list(payload);
      case 'getChild':
        return _getChild(payload);
      case 'remove':
        await _remove(payload);
        return null;
      case 'same':
        return _same(payload);
      case 'resolve':
        return _resolve(payload);
      default:
        throw PlaymeshFileSystemAccessException(
          'not_supported',
          '未知文件系统命令：$command',
        );
    }
  }

  Future<List<Map<String, Object?>>> _pickOpen(
    Map<String, Object?> payload,
  ) async {
    final groups = _typeGroups(payload);
    final multiple = payload['multiple'] == true;
    final files = multiple
        ? await openFiles(acceptedTypeGroups: groups)
        : [?await openFile(acceptedTypeGroups: groups)];
    if (files.isEmpty) _cancelled();
    return files
        .map((file) => _registerPath(file.path, kind: 'file'))
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _pickSave(Map<String, Object?> payload) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: _typeGroups(payload),
      suggestedName: _optionalString(payload, 'suggestedName'),
    );
    if (location == null) _cancelled();
    return _registerPath(location.path, kind: 'file');
  }

  Future<Map<String, Object?>> _pickDirectory(
    Map<String, Object?> payload,
  ) async {
    final path = await getDirectoryPath();
    if (path == null) _cancelled();
    return _registerPath(path, kind: 'directory');
  }

  Future<Map<String, Object?>> _stat(_FileSystemEntry entry) async {
    if (entry.kind != 'file') _typeMismatch('目标不是文件');
    final file = File(entry.path);
    if (!await file.exists()) _notFound();
    final stat = await file.stat();
    return {
      ..._descriptor(entry),
      'size': stat.size,
      'lastModified': stat.modified.millisecondsSinceEpoch,
      'type': _mimeTypeForName(entry.name),
    };
  }

  Future<Map<String, Object?>> _read(Map<String, Object?> payload) async {
    final entry = _entry(payload);
    if (entry.kind != 'file') _typeMismatch('目标不是文件');
    final offset = _nonNegativeInt(payload, 'offset');
    final length = _boundedLength(payload);
    final file = File(entry.path);
    if (!await file.exists()) _notFound();
    final reader = await file.open(mode: FileMode.read);
    try {
      final size = await reader.length();
      if (offset >= size) return {'data': '', 'eof': true};
      await reader.setPosition(offset);
      final bytes = await reader.read(min(length, size - offset));
      return {
        'data': base64Encode(bytes),
        'eof': offset + bytes.length >= size,
      };
    } finally {
      await reader.close();
    }
  }

  Future<Map<String, Object?>> _createWritable(
    Map<String, Object?> payload,
  ) async {
    final entry = _entry(payload);
    if (entry.kind != 'file') _typeMismatch('目标不是文件');
    final target = File(entry.path);
    final parent = target.parent;
    if (!await parent.exists()) _notFound();
    final temporary = File('${target.path}.playmesh-${_token()}.tmp');
    await temporary.create();
    final file = await temporary.open(mode: FileMode.write);
    if (payload['keepExistingData'] == true && await target.exists()) {
      await for (final chunk in target.openRead()) {
        await file.writeFrom(chunk);
      }
    }
    await file.setPosition(0);
    final id = _token();
    _writers[id] = _WritableFile(
      id: id,
      target: target,
      temporary: temporary,
      file: file,
    );
    return {'writerId': id};
  }

  Future<void> _write(Map<String, Object?> payload) async {
    final writer = _writer(payload);
    final raw = _requiredString(payload, 'data');
    late final List<int> bytes;
    try {
      bytes = base64Decode(raw);
    } on FormatException {
      throw const PlaymeshFileSystemAccessException(
        'invalid_argument',
        '写入内容不是有效的 Base64',
      );
    }
    if (bytes.length > maxTransferBytes) {
      throw const PlaymeshFileSystemAccessException(
        'invalid_argument',
        '单次写入超过 512 KiB',
      );
    }
    await writer.file.writeFrom(bytes);
  }

  Future<void> _seek(Map<String, Object?> payload) =>
      _writer(payload).file.setPosition(_nonNegativeInt(payload, 'position'));

  Future<void> _truncate(Map<String, Object?> payload) async {
    final writer = _writer(payload);
    final position = await writer.file.position();
    await writer.file.truncate(_nonNegativeInt(payload, 'size'));
    await writer.file.setPosition(position);
  }

  Future<void> _closeWritable(Map<String, Object?> payload) async {
    final writer = _takeWriter(payload);
    await writer.file.flush();
    await writer.file.close();
    try {
      await writer.temporary.copy(writer.target.path);
    } finally {
      if (await writer.temporary.exists()) await writer.temporary.delete();
    }
  }

  Future<void> _abortWritable(Map<String, Object?> payload) async {
    final writer = _takeWriter(payload);
    await writer.file.close();
    if (await writer.temporary.exists()) await writer.temporary.delete();
  }

  Future<Map<String, Object?>> _list(Map<String, Object?> payload) async {
    final parent = _entry(payload);
    if (parent.kind != 'directory') _typeMismatch('目标不是目录');
    final directory = Directory(parent.path);
    if (!await directory.exists()) _notFound();
    final cursor = payload['cursor'] == null
        ? 0
        : _nonNegativeInt(payload, 'cursor');
    final children = <FileSystemEntity>[];
    await for (final child in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(child.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory) {
        children.add(child);
      }
    }
    children.sort(
      (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
    );
    const pageSize = 128;
    final end = min(cursor + pageSize, children.length);
    final items = <Map<String, Object?>>[];
    for (var index = cursor; index < end; index += 1) {
      final child = children[index];
      final kind = child is Directory ? 'directory' : 'file';
      items.add(
        _registerPath(child.path, kind: kind, grantRoot: parent.grantRoot),
      );
    }
    return {'items': items, if (end < children.length) 'cursor': end};
  }

  Future<Map<String, Object?>> _getChild(Map<String, Object?> payload) async {
    final parent = _entry(payload);
    if (parent.kind != 'directory') _typeMismatch('目标不是目录');
    final name = _safeChildName(_requiredString(payload, 'name'));
    final kind = _requiredKind(payload);
    final path = '${parent.path}${Platform.pathSeparator}$name';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (payload['create'] != true) _notFound();
      if (kind == 'file') {
        await File(path).create();
      } else {
        await Directory(path).create();
      }
    } else if ((kind == 'file' && type != FileSystemEntityType.file) ||
        (kind == 'directory' && type != FileSystemEntityType.directory)) {
      _typeMismatch('同名条目的类型不匹配');
    }
    return _registerPath(path, kind: kind, grantRoot: parent.grantRoot);
  }

  Future<void> _remove(Map<String, Object?> payload) async {
    final parent = _entry(payload);
    if (parent.kind != 'directory') _typeMismatch('目标不是目录');
    final name = _safeChildName(_requiredString(payload, 'name'));
    final path = '${parent.path}${Platform.pathSeparator}$name';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) _notFound();
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: payload['recursive'] == true);
    } else {
      await File(path).delete();
    }
  }

  bool _same(Map<String, Object?> payload) {
    final left = _entry(payload);
    final right = _entry(payload, key: 'otherId');
    return _normalizedPath(left.path) == _normalizedPath(right.path);
  }

  List<String>? _resolve(Map<String, Object?> payload) {
    final parent = _entry(payload);
    final child = _entry(payload, key: 'otherId');
    if (parent.kind != 'directory') _typeMismatch('目标不是目录');
    final base = _normalizedPath(parent.path);
    final target = _normalizedPath(child.path);
    if (target == base) return const [];
    final prefix = '$base${Platform.pathSeparator}';
    if (!target.startsWith(prefix)) return null;
    return target
        .substring(prefix.length)
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, Object?> _registerPath(
    String path, {
    required String kind,
    String? grantRoot,
  }) {
    final absolute = kind == 'directory'
        ? Directory(path).absolute.path
        : File(path).absolute.path;
    final id = _token();
    final entry = _FileSystemEntry(
      id: id,
      path: absolute,
      kind: kind,
      grantRoot: grantRoot ?? absolute,
    );
    _entries[id] = entry;
    return _descriptor(entry);
  }

  Map<String, Object?> _descriptor(_FileSystemEntry entry) => {
    'id': entry.id,
    'kind': entry.kind,
    'name': entry.name,
  };

  _FileSystemEntry _entry(Map<String, Object?> payload, {String key = 'id'}) {
    final id = _requiredString(payload, key);
    final entry = _entries[id];
    if (entry == null) {
      throw const PlaymeshFileSystemAccessException('invalid_state', '文件句柄已失效');
    }
    return entry;
  }

  _WritableFile _writer(Map<String, Object?> payload) {
    final id = _requiredString(payload, 'writerId');
    final writer = _writers[id];
    if (writer == null) {
      throw const PlaymeshFileSystemAccessException('invalid_state', '可写流已关闭');
    }
    return writer;
  }

  _WritableFile _takeWriter(Map<String, Object?> payload) {
    final writer = _writer(payload);
    _writers.remove(writer.id);
    return writer;
  }

  List<XTypeGroup> _typeGroups(Map<String, Object?> payload) {
    final rawTypes = payload['types'];
    if (rawTypes is! List) return const [];
    final groups = <XTypeGroup>[];
    for (final rawGroup in rawTypes) {
      if (rawGroup is! Map) continue;
      final group = Map<Object?, Object?>.from(rawGroup);
      final extensions = <String>{};
      final accept = group['accept'];
      if (accept is Map) {
        for (final rawExtensions in accept.values) {
          if (rawExtensions is! List) continue;
          for (final rawExtension in rawExtensions) {
            if (rawExtension is String && rawExtension.startsWith('.')) {
              extensions.add(rawExtension.substring(1).toLowerCase());
            }
          }
        }
      }
      if (extensions.isNotEmpty) {
        groups.add(
          XTypeGroup(
            label: group['description'] is String
                ? group['description']! as String
                : '文件',
            extensions: extensions.toList(growable: false),
          ),
        );
      }
    }
    return groups;
  }

  int _boundedLength(Map<String, Object?> payload) {
    final length = _nonNegativeInt(payload, 'length');
    if (length < 1 || length > maxTransferBytes) {
      throw const PlaymeshFileSystemAccessException(
        'invalid_argument',
        '读取长度必须在 1 到 512 KiB 之间',
      );
    }
    return length;
  }

  int _nonNegativeInt(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is! int || value < 0) {
      throw PlaymeshFileSystemAccessException(
        'invalid_argument',
        '$key 必须是非负整数',
      );
    }
    return value;
  }

  String _requiredString(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is! String || value.isEmpty) {
      throw PlaymeshFileSystemAccessException(
        'invalid_argument',
        '$key 必须是非空字符串',
      );
    }
    return value;
  }

  String? _optionalString(Map<String, Object?> payload, String key) {
    final value = payload[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  String _requiredKind(Map<String, Object?> payload) {
    final value = payload['kind'];
    if (value != 'file' && value != 'directory') {
      throw const PlaymeshFileSystemAccessException(
        'invalid_argument',
        'kind 必须是 file 或 directory',
      );
    }
    return value! as String;
  }

  String _safeChildName(String value) {
    if (value == '.' ||
        value == '..' ||
        value.length > 255 ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      throw const PlaymeshFileSystemAccessException(
        'invalid_argument',
        '目录条目名称无效',
      );
    }
    return value;
  }

  String _normalizedPath(String value) {
    var normalized = File(value).absolute.path.replaceAll('/', '\\');
    while (normalized.endsWith('\\')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.toLowerCase();
  }

  String _token() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Never _cancelled() => throw const PlaymeshFileSystemAccessException(
    'user_cancelled',
    '用户取消了文件选择',
  );

  Never _notFound() =>
      throw const PlaymeshFileSystemAccessException('not_found', '文件或目录不存在');

  Never _typeMismatch(String message) =>
      throw PlaymeshFileSystemAccessException('type_mismatch', message);

  String _fileSystemErrorCode(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 2 || code == 3) return 'not_found';
    if (code == 5 || code == 13) return 'not_allowed';
    return 'native_error';
  }

  String _mimeTypeForName(String name) {
    final extension = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (extension) {
      'json' => 'application/json',
      'txt' || 'log' || 'md' => 'text/plain',
      'html' || 'htm' => 'text/html',
      'css' => 'text/css',
      'js' || 'mjs' => 'text/javascript',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'mp4' => 'video/mp4',
      'zip' => 'application/zip',
      _ => '',
    };
  }

  Future<void> resetDocument() async {
    final writers = _writers.values.toList(growable: false);
    _writers.clear();
    for (final writer in writers) {
      try {
        await writer.file.close();
      } on Object {
        // 继续清理其他临时文件。
      }
      try {
        if (await writer.temporary.exists()) await writer.temporary.delete();
      } on Object {
        // 文档失效不能因为临时文件清理失败而卡住。
      }
    }
    _entries.clear();
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod<void>('resetDocument');
      } on MissingPluginException {
        // 不支持的平台不需要清理原生状态。
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await resetDocument();
    _closed = true;
  }
}

final class _FileSystemEntry {
  const _FileSystemEntry({
    required this.id,
    required this.path,
    required this.kind,
    required this.grantRoot,
  });

  final String id;
  final String path;
  final String kind;
  final String grantRoot;

  String get name {
    final separator = Platform.pathSeparator;
    final parts = path.split(separator).where((part) => part.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

final class _WritableFile {
  const _WritableFile({
    required this.id,
    required this.target,
    required this.temporary,
    required this.file,
  });

  final String id;
  final File target;
  final File temporary;
  final RandomAccessFile file;
}
