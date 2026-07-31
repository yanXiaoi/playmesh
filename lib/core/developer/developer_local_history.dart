import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum DeveloperHistoryVersion { before, after }

class DeveloperLocalHistoryOperation {
  const DeveloperLocalHistoryOperation({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.changeCount,
    required this.labels,
    required this.paths,
    this.summaryCode,
    this.summaryArguments = const {},
  });

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int changeCount;
  final List<String> labels;
  final List<String> paths;
  final String? summaryCode;
  final Map<String, Object?> summaryArguments;

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'changeCount': changeCount,
    'labels': labels,
    'paths': paths,
    'summary': labels.isEmpty ? '' : labels.last,
    if (summaryCode != null) 'summaryCode': summaryCode,
    if (summaryCode != null) 'summaryArguments': summaryArguments,
  };
}

class DeveloperLocalHistoryChange {
  const DeveloperLocalHistoryChange({
    required this.path,
    required this.kind,
    required this.change,
    required this.beforeSize,
    required this.afterSize,
    required this.addedLines,
    required this.removedLines,
    this.before,
    this.after,
    this.truncated = false,
  });

  final String path;
  final String kind;
  final String change;
  final int beforeSize;
  final int afterSize;
  final int addedLines;
  final int removedLines;
  final String? before;
  final String? after;
  final bool truncated;

  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind,
    'change': change,
    'beforeSize': beforeSize,
    'afterSize': afterSize,
    'addedLines': addedLines,
    'removedLines': removedLines,
    'before': before,
    'after': after,
    'binary': kind == 'file' && before == null && after == null,
    'truncated': truncated,
  };
}

class DeveloperLocalHistoryDiff {
  const DeveloperLocalHistoryDiff({
    required this.operationId,
    required this.path,
    required this.changes,
  });

  final String operationId;
  final String path;
  final List<DeveloperLocalHistoryChange> changes;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'path': path,
    'changes': changes.map((change) => change.toJson()).toList(),
  };
}

class DeveloperLocalHistoryStore {
  static const mergeWindow = Duration(minutes: 5);
  static const _maxOperations = 100;
  static const _maxTextPreviewBytes = 256 * 1024;

  Future<void> _tail = Future<void>.value();

  Future<T> recordMutation<T>({
    required Directory workspace,
    required String label,
    required String path,
    required Future<T> Function() action,
    String? summaryCode,
    Map<String, Object?> summaryArguments = const {},
    bool forceNew = false,
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    Directory? operation;
    var created = false;
    try {
      final selected = await _selectOperation(workspace, forceNew: forceNew);
      operation = selected.$1;
      created = selected.$2;
      final result = await action();
      await _finishOperation(
        workspace,
        operation,
        label: label,
        path: path,
        summaryCode: summaryCode,
        summaryArguments: summaryArguments,
        sealed: forceNew,
      );
      await _prune(workspace);
      return result;
    } on Object {
      if (created && operation != null && await operation.exists()) {
        await operation.delete(recursive: true);
      }
      rethrow;
    } finally {
      release.complete();
    }
  }

  Future<List<DeveloperLocalHistoryOperation>> list(
    Directory workspace,
    String path,
  ) async {
    final directories = await _operationDirectories(workspace);
    final operations = <DeveloperLocalHistoryOperation>[];
    for (final directory in directories.reversed) {
      final metadata = await _readMetadata(directory);
      if (metadata == null) continue;
      final paths = (metadata['paths'] as List? ?? const [])
          .whereType<String>()
          .toList();
      if (path.isNotEmpty && !paths.any((item) => _pathsOverlap(path, item))) {
        continue;
      }
      operations.add(_operationFromJson(metadata));
    }
    return List.unmodifiable(operations);
  }

  Future<({bool initialized, Uint8List? bytes})> readBaselineFile(
    Directory workspace,
    String path,
  ) async {
    final baseline = _baselineDirectory(workspace);
    if (!await baseline.exists()) {
      return (initialized: false, bytes: null);
    }
    final file = File(_join(baseline.path, path));
    return (
      initialized: true,
      bytes: await file.exists() ? await file.readAsBytes() : null,
    );
  }

  Future<DeveloperLocalHistoryDiff> diff(
    Directory workspace,
    String operationId,
    String path,
  ) async {
    final operation = _operationDirectory(workspace, operationId);
    final metadata = await _readMetadata(operation);
    if (metadata == null) throw StateError('本地历史操作不存在');
    final before = await _snapshotEntries(
      await _beforeSnapshot(workspace, operationId),
      path,
    );
    final after = await _snapshotEntries(
      Directory('${operation.path}${Platform.pathSeparator}snapshot'),
      path,
    );
    final paths = {...before.keys, ...after.keys}.toList()..sort();
    final changes = <DeveloperLocalHistoryChange>[];
    for (final itemPath in paths) {
      final oldEntry = before[itemPath];
      final newEntry = after[itemPath];
      if (_entriesEqual(oldEntry, newEntry)) continue;
      changes.add(_buildChange(itemPath, oldEntry, newEntry));
    }
    return DeveloperLocalHistoryDiff(
      operationId: operationId,
      path: path,
      changes: List.unmodifiable(changes),
    );
  }

  Future<void> restore(
    Directory workspace,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  ) async {
    final operation = _operationDirectory(workspace, operationId);
    if (await _readMetadata(operation) == null) {
      throw StateError('本地历史操作不存在');
    }
    final snapshot = version == DeveloperHistoryVersion.before
        ? await _beforeSnapshot(workspace, operationId)
        : Directory('${operation.path}${Platform.pathSeparator}snapshot');
    if (path.isEmpty) {
      await _restoreWorkspace(workspace, snapshot);
      return;
    }
    await _replacePath(workspace, snapshot, path);
  }

  Future<(Directory, bool)> _selectOperation(
    Directory workspace, {
    required bool forceNew,
  }) async {
    final now = DateTime.now().toUtc();
    final directories = await _operationDirectories(workspace);
    if (!forceNew && directories.isNotEmpty) {
      final latest = directories.last;
      final metadata = await _readMetadata(latest);
      final updatedAt = metadata?['updatedAt'];
      if (metadata?['sealed'] != true &&
          updatedAt is int &&
          now.difference(
                DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
              ) <=
              mergeWindow) {
        return (latest, false);
      }
    }
    final id = now.microsecondsSinceEpoch.toString();
    final operation = _operationDirectory(workspace, id);
    final baseline = _baselineDirectory(workspace);
    if (!await baseline.exists()) await _snapshot(workspace, baseline);
    await operation.create(recursive: true);
    return (operation, true);
  }

  Future<void> _finishOperation(
    Directory workspace,
    Directory operation, {
    required String label,
    required String path,
    required String? summaryCode,
    required Map<String, Object?> summaryArguments,
    required bool sealed,
  }) async {
    final snapshot = Directory(
      '${operation.path}${Platform.pathSeparator}snapshot',
    );
    await _snapshot(workspace, snapshot);
    final now = DateTime.now().toUtc();
    final existing = await _readMetadata(operation);
    final labels =
        (existing?['labels'] as List? ?? const []).whereType<String>().toList()
          ..add(label);
    final paths =
        (existing?['paths'] as List? ?? const []).whereType<String>().toSet()
          ..add(path);
    await _metadataFile(operation).writeAsString(
      jsonEncode({
        'id': _basename(operation.path),
        'createdAt': existing?['createdAt'] ?? now.millisecondsSinceEpoch,
        'updatedAt': now.millisecondsSinceEpoch,
        'changeCount': (existing?['changeCount'] as int? ?? 0) + 1,
        'labels': labels,
        'paths': paths.toList()..sort(),
        'sealed': existing?['sealed'] == true || sealed,
        'summaryCode': ?summaryCode,
        if (summaryCode != null) 'summaryArguments': summaryArguments,
      }),
      flush: true,
    );
  }

  Future<void> _snapshot(Directory workspace, Directory target) async {
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    await for (final entity in workspace.list()) {
      if ({'.playmesh', 'cache', 'data'}.contains(_basename(entity.path))) {
        continue;
      }
      await _copyEntity(entity, target);
    }
  }

  Future<void> _copyEntity(FileSystemEntity source, Directory target) async {
    final destinationPath =
        '${target.path}${Platform.pathSeparator}${_basename(source.path)}';
    if (source is File) {
      await source.copy(destinationPath);
      return;
    }
    if (source is Directory) {
      final destination = Directory(destinationPath);
      await destination.create(recursive: true);
      await for (final child in source.list()) {
        await _copyEntity(child, destination);
      }
    }
  }

  Future<void> _restoreWorkspace(
    Directory workspace,
    Directory snapshot,
  ) async {
    await for (final entity in workspace.list()) {
      final name = _basename(entity.path);
      if ({'.playmesh', 'cache', 'data'}.contains(name)) continue;
      await entity.delete(recursive: true);
    }
    if (!await snapshot.exists()) return;
    await for (final entity in snapshot.list()) {
      await _copyEntity(entity, workspace);
    }
  }

  Future<void> _replacePath(
    Directory workspace,
    Directory snapshot,
    String path,
  ) async {
    final targetPath = _join(workspace.path, path);
    final targetFile = File(targetPath);
    final targetDirectory = Directory(targetPath);
    if (await targetFile.exists()) await targetFile.delete();
    if (await targetDirectory.exists()) {
      await targetDirectory.delete(recursive: true);
    }
    final sourcePath = _join(snapshot.path, path);
    final sourceFile = File(sourcePath);
    final sourceDirectory = Directory(sourcePath);
    final parent = Directory(
      targetPath.substring(0, targetPath.lastIndexOf(Platform.pathSeparator)),
    );
    await parent.create(recursive: true);
    if (await sourceFile.exists()) {
      await sourceFile.copy(targetPath);
    } else if (await sourceDirectory.exists()) {
      await _copyEntity(sourceDirectory, parent);
    }
  }

  Future<Map<String, _SnapshotEntry>> _snapshotEntries(
    Directory snapshot,
    String path,
  ) async {
    final entries = <String, _SnapshotEntry>{};
    if (!await snapshot.exists()) return entries;
    final root = path.isEmpty ? snapshot.path : _join(snapshot.path, path);
    final file = File(root);
    if (await file.exists()) {
      entries[path] = _SnapshotEntry.file(await file.readAsBytes());
      return entries;
    }
    final directory = Directory(root);
    if (!await directory.exists()) return entries;
    if (path.isNotEmpty) entries[path] = _SnapshotEntry.directory();
    await for (final entity in directory.list(recursive: true)) {
      final relative = _relative(snapshot, entity.path);
      if (entity is File) {
        entries[relative] = _SnapshotEntry.file(await entity.readAsBytes());
      } else if (entity is Directory) {
        entries[relative] = _SnapshotEntry.directory();
      }
    }
    return entries;
  }

  DeveloperLocalHistoryChange _buildChange(
    String path,
    _SnapshotEntry? before,
    _SnapshotEntry? after,
  ) {
    final kind = (after ?? before)!.isDirectory ? 'directory' : 'file';
    final change = before == null
        ? 'added'
        : after == null
        ? 'deleted'
        : 'modified';
    String? oldText;
    String? newText;
    var truncated = false;
    if (kind == 'file' && _isTextPath(path)) {
      if ((before?.bytes.length ?? 0) <= _maxTextPreviewBytes &&
          (after?.bytes.length ?? 0) <= _maxTextPreviewBytes) {
        oldText = _decodeText(before?.bytes);
        newText = _decodeText(after?.bytes);
      } else {
        truncated = true;
      }
    }
    final lineCounts = _lineCounts(oldText ?? '', newText ?? '');
    return DeveloperLocalHistoryChange(
      path: path,
      kind: kind,
      change: change,
      beforeSize: before?.bytes.length ?? 0,
      afterSize: after?.bytes.length ?? 0,
      addedLines: lineCounts.$1,
      removedLines: lineCounts.$2,
      before: oldText,
      after: newText,
      truncated: truncated,
    );
  }

  Future<List<Directory>> _operationDirectories(Directory workspace) async {
    final root = _operationsRoot(workspace);
    if (!await root.exists()) return [];
    final directories = <Directory>[];
    await for (final entity in root.list()) {
      if (entity is Directory) directories.add(entity);
    }
    directories.sort((a, b) => a.path.compareTo(b.path));
    return directories;
  }

  Future<void> _prune(Directory workspace) async {
    final directories = await _operationDirectories(workspace);
    final excess = directories.length - _maxOperations;
    for (var index = 0; index < excess; index += 1) {
      final snapshot = Directory(
        '${directories[index].path}${Platform.pathSeparator}snapshot',
      );
      await _copySnapshot(snapshot, _baselineDirectory(workspace));
      await directories[index].delete(recursive: true);
    }
  }

  Future<Directory> _beforeSnapshot(
    Directory workspace,
    String operationId,
  ) async {
    final directories = await _operationDirectories(workspace);
    final index = directories.indexWhere(
      (directory) => _basename(directory.path) == operationId,
    );
    if (index < 0) throw StateError('本地历史操作不存在');
    if (index == 0) return _baselineDirectory(workspace);
    return Directory(
      '${directories[index - 1].path}${Platform.pathSeparator}snapshot',
    );
  }

  Future<void> _copySnapshot(Directory source, Directory target) async {
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    if (!await source.exists()) return;
    await for (final entity in source.list()) {
      await _copyEntity(entity, target);
    }
  }

  Future<Map<String, Object?>?> _readMetadata(Directory operation) async {
    final file = _metadataFile(operation);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  }

  DeveloperLocalHistoryOperation _operationFromJson(
    Map<String, Object?> json,
  ) => DeveloperLocalHistoryOperation(
    id: json['id'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['createdAt'] as int,
      isUtc: true,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      json['updatedAt'] as int,
      isUtc: true,
    ),
    changeCount: json['changeCount'] as int? ?? 0,
    labels: (json['labels'] as List? ?? const []).whereType<String>().toList(),
    paths: (json['paths'] as List? ?? const []).whereType<String>().toList(),
    summaryCode: json['summaryCode'] is String
        ? json['summaryCode'] as String
        : null,
    summaryArguments: json['summaryArguments'] is Map
        ? Map<String, Object?>.from(json['summaryArguments'] as Map)
        : const {},
  );

  Directory _historyRoot(Directory workspace) => Directory(
    '${workspace.path}${Platform.pathSeparator}cache'
    '${Platform.pathSeparator}developer'
    '${Platform.pathSeparator}local-history',
  );

  Directory _operationsRoot(Directory workspace) => Directory(
    '${_historyRoot(workspace).path}${Platform.pathSeparator}operations',
  );

  Directory _baselineDirectory(Directory workspace) => Directory(
    '${_historyRoot(workspace).path}${Platform.pathSeparator}baseline',
  );

  Directory _operationDirectory(Directory workspace, String id) {
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw const FormatException('本地历史操作 ID 无效');
    }
    return Directory(
      '${_operationsRoot(workspace).path}${Platform.pathSeparator}$id',
    );
  }

  File _metadataFile(Directory operation) =>
      File('${operation.path}${Platform.pathSeparator}operation.json');
}

class _SnapshotEntry {
  _SnapshotEntry.directory() : isDirectory = true, bytes = Uint8List(0);

  _SnapshotEntry.file(this.bytes) : isDirectory = false;

  final bool isDirectory;
  final Uint8List bytes;
}

bool _entriesEqual(_SnapshotEntry? first, _SnapshotEntry? second) {
  if (first == null || second == null) return first == second;
  if (first.isDirectory != second.isDirectory ||
      first.bytes.length != second.bytes.length) {
    return false;
  }
  for (var index = 0; index < first.bytes.length; index += 1) {
    if (first.bytes[index] != second.bytes[index]) return false;
  }
  return true;
}

bool _pathsOverlap(String selected, String changed) =>
    selected.isEmpty ||
    changed.isEmpty ||
    selected == changed ||
    selected.startsWith('$changed/') ||
    changed.startsWith('$selected/');

String? _decodeText(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

(int, int) _lineCounts(String before, String after) {
  final oldLines = const LineSplitter().convert(before);
  final newLines = const LineSplitter().convert(after);
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix += 1;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - suffix - 1] ==
          newLines[newLines.length - suffix - 1]) {
    suffix += 1;
  }
  return (newLines.length - prefix - suffix, oldLines.length - prefix - suffix);
}

bool _isTextPath(String path) => RegExp(
  r'\.(html?|css|js|mjs|json|md|txt|xml|yaml|yml|svg)$',
  caseSensitive: false,
).hasMatch(path);

String _join(String root, String path) =>
    '$root${Platform.pathSeparator}'
    '${path.replaceAll('/', Platform.pathSeparator)}';

String _relative(Directory root, String path) => path
    .substring('${root.path}${Platform.pathSeparator}'.length)
    .replaceAll(Platform.pathSeparator, '/');

String _basename(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
