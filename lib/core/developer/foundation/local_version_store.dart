import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

class LocalVersionRetentionPolicy {
  const LocalVersionRetentionPolicy({
    this.maxVersionsPerNamespace = 50,
    this.maxUniqueBytesPerNamespace = 256 * 1024 * 1024,
    this.maxObjectBytes = 64 * 1024 * 1024,
    this.stagingTtl = const Duration(hours: 24),
  }) : assert(maxVersionsPerNamespace > 0),
       assert(maxUniqueBytesPerNamespace > 0),
       assert(maxObjectBytes > 0);

  const LocalVersionRetentionPolicy.desktop()
    : this(
        maxVersionsPerNamespace: 100,
        maxUniqueBytesPerNamespace: 1024 * 1024 * 1024,
        maxObjectBytes: 128 * 1024 * 1024,
      );

  final int maxVersionsPerNamespace;
  final int maxUniqueBytesPerNamespace;
  final int maxObjectBytes;
  final Duration stagingTtl;
}

class LocalCasObjectReference {
  const LocalCasObjectReference({required this.hash, required this.bytes});

  final String hash;
  final int bytes;

  Map<String, Object?> toJson() => {'hash': hash, 'bytes': bytes};

  factory LocalCasObjectReference.fromJson(Map<String, Object?> json) {
    final hash = json['hash'];
    final bytes = json['bytes'];
    if (hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        bytes is! int ||
        bytes < 1) {
      throw const FormatException('本地 CAS 引用格式无效');
    }
    return LocalCasObjectReference(hash: hash, bytes: bytes);
  }
}

class LocalVersionDraft {
  const LocalVersionDraft({
    required this.content,
    required this.attributes,
    this.references = const [],
    this.deduplicateHistoryHead = true,
  });

  final Uint8List content;
  final Map<String, Object?> attributes;
  final List<LocalCasObjectReference> references;
  final bool deduplicateHistoryHead;
}

class LocalVersionRecord {
  const LocalVersionRecord({
    required this.id,
    required this.revision,
    required this.timestamp,
    required this.contentHash,
    required this.contentBytes,
    required this.references,
    required this.attributes,
  });

  final String id;
  final int revision;
  final DateTime timestamp;
  final String contentHash;
  final int contentBytes;
  final List<LocalCasObjectReference> references;
  final Map<String, Object?> attributes;

  Iterable<LocalCasObjectReference> get pinnedObjects sync* {
    yield LocalCasObjectReference(hash: contentHash, bytes: contentBytes);
    yield* references;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'contentHash': contentHash,
    'contentBytes': contentBytes,
    'references': references.map((reference) => reference.toJson()).toList(),
    'attributes': attributes,
  };

  factory LocalVersionRecord.fromJson(Map<String, Object?> json) {
    final attributes = json['attributes'];
    final references = json['references'];
    final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
    if (json['id'] is! String ||
        json['revision'] is! int ||
        timestamp == null ||
        json['contentHash'] is! String ||
        json['contentBytes'] is! int ||
        attributes is! Map ||
        references is! List) {
      throw const FormatException('本地版本索引格式无效');
    }
    return LocalVersionRecord(
      id: json['id']! as String,
      revision: json['revision']! as int,
      timestamp: timestamp.toUtc(),
      contentHash: json['contentHash']! as String,
      contentBytes: json['contentBytes']! as int,
      references: List.unmodifiable(
        references.map((raw) {
          if (raw is! Map) throw const FormatException('本地 CAS 引用格式无效');
          return LocalCasObjectReference.fromJson(
            Map<String, Object?>.from(raw),
          );
        }),
      ),
      attributes: Map<String, Object?>.from(attributes),
    );
  }
}

class LocalVersionCommitResult {
  const LocalVersionCommitResult({
    required this.created,
    required this.current,
    required this.deduplicated,
  });

  final List<LocalVersionRecord> created;
  final LocalVersionRecord current;
  final bool deduplicated;
}

class LocalVersionRevisionConflict implements Exception {
  const LocalVersionRevisionConflict(this.currentRevision);

  final int currentRevision;
}

class LocalVersionQuotaExceeded implements Exception {
  const LocalVersionQuotaExceeded({required this.scope, required this.limit});

  final String scope;
  final int limit;
}

class LocalVersionObjectMissing implements Exception {
  const LocalVersionObjectMissing(this.hash);

  final String hash;
}

class _LocalVersionNamespaceState {
  _LocalVersionNamespaceState({
    this.current,
    List<LocalVersionRecord>? versions,
  }) : versions = versions ?? [];

  LocalVersionRecord? current;
  final List<LocalVersionRecord> versions;

  Map<String, Object?> toJson() => {
    if (current != null) 'current': current!.toJson(),
    'versions': versions.map((record) => record.toJson()).toList(),
  };
}

/// 单项目 CAS/事务核心。命名空间只是一段稳定 key，不含编辑器领域语义。
///
/// `current` 与每个历史记录分别 pin 内容和资源；状态索引一次原子替换，
/// 未被任何 current/history pin 的对象才会被 GC。
class LocalVersionStore {
  LocalVersionStore({
    required this.root,
    this.retentionPolicy = const LocalVersionRetentionPolicy(),
    DateTime Function()? clock,
    @visibleForTesting this.onGarbageCollection,
  }) : clock = clock ?? DateTime.now;

  static const schemaVersion = 1;

  final Directory root;
  final LocalVersionRetentionPolicy retentionPolicy;
  final DateTime Function() clock;
  @visibleForTesting
  final void Function()? onGarbageCollection;
  static final Map<String, Future<void>> _projectTails = {};
  Future<void> _tail = Future<void>.value();

  Future<LocalCasObjectReference> stageObject(Uint8List content) async =>
      (await stageObjects([content])).single;

  /// 将一批内存对象写入 CAS，并在整批结束后只执行一次 GC。
  ///
  /// 返回值与 [contents] 顺序一致；已经存在的 hash 只复用目标对象，不创建
  /// 临时文件。整批与同一项目的其他 stage/commit/delete 操作串行执行。
  Future<List<LocalCasObjectReference>> stageObjects(
    Iterable<Uint8List> contents,
  ) {
    final batch = contents.toList(growable: false);
    if (batch.isEmpty) {
      return Future.value(const <LocalCasObjectReference>[]);
    }
    return _serialize(
      () => _serializeProject(
        () => _withStoreLock(() async {
          final references = <LocalCasObjectReference>[];
          for (final content in batch) {
            references.add(await _stageObjectUnlocked(content));
          }
          await _deleteUnpinnedObjects(
            await _readState(),
            protectedHashes: references.map((reference) => reference.hash),
          );
          return List<LocalCasObjectReference>.unmodifiable(references);
        }),
      ),
    );
  }

  /// 以临时文件流式写入 CAS；`timeout` 是相邻数据块的空闲超时。
  ///
  /// `expectedBytes` 可省略，因为浏览器的 chunked PUT 不一定携带
  /// Content-Length；无论是否提供，实际接收量与 `maxBytes` 才是最终边界。
  Future<LocalCasObjectReference> stageStream(
    Stream<List<int>> source, {
    int? expectedBytes,
    String? expectedHash,
    int? maxBytes,
    Duration timeout = const Duration(seconds: 30),
  }) => _serialize(
    () => _serializeProject(
      () => _withStoreLock(
        () => _stageStreamUnlocked(
          source,
          expectedBytes: expectedBytes,
          expectedHash: expectedHash,
          maxBytes: maxBytes,
          timeout: timeout,
        ),
      ),
    ),
  );

  Future<LocalCasObjectReference> _stageStreamUnlocked(
    Stream<List<int>> source, {
    int? expectedBytes,
    String? expectedHash,
    int? maxBytes,
    required Duration timeout,
  }) async {
    if (maxBytes != null && maxBytes < 1) {
      throw const FormatException('CAS 上传上限无效');
    }
    final effectiveMaxBytes =
        maxBytes == null || maxBytes > retentionPolicy.maxObjectBytes
        ? retentionPolicy.maxObjectBytes
        : maxBytes;
    if (expectedBytes != null && expectedBytes < 1) {
      throw const FormatException('CAS 对象不能为空');
    }
    if (expectedHash != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedHash)) {
      throw const FormatException('CAS 对象 hash 无效');
    }
    if (expectedBytes != null && expectedBytes > effectiveMaxBytes) {
      throw LocalVersionQuotaExceeded(
        scope: 'object',
        limit: effectiveMaxBytes,
      );
    }
    await root.create(recursive: true);
    File? temporary;
    IOSink? output;
    if (expectedHash == null ||
        !await File(
          '${_objects.path}${Platform.pathSeparator}$expectedHash.blob',
        ).exists()) {
      final staging = Directory('${root.path}${Platform.pathSeparator}staging');
      await staging.create(recursive: true);
      temporary = File(
        '${staging.path}${Platform.pathSeparator}'
        'upload-${clock().microsecondsSinceEpoch}-${ProcessInfo.currentRss}.tmp',
      );
      output = temporary.openWrite();
    }
    final hashSink = Sha256().toSync().newHashSink();
    var received = 0;
    var outputClosed = false;
    var hashClosed = false;
    try {
      await for (final chunk in source.timeout(timeout)) {
        received += chunk.length;
        if (received > effectiveMaxBytes) {
          throw LocalVersionQuotaExceeded(
            scope: 'object',
            limit: effectiveMaxBytes,
          );
        }
        if (expectedBytes != null && received > expectedBytes) {
          throw const FormatException('CAS 上传实际字节数与预期不一致');
        }
        hashSink.add(chunk);
        output?.add(chunk);
      }
      if (received < 1) throw const FormatException('CAS 对象不能为空');
      if (expectedBytes != null && received != expectedBytes) {
        throw const FormatException('CAS 上传实际字节数与预期不一致');
      }
      if (output != null) {
        await output.flush();
        await output.close();
        outputClosed = true;
      }
      hashSink.close();
      hashClosed = true;
      final digest = await hashSink.hash();
      final hash = _hex(digest.bytes);
      if (expectedHash != null && hash != expectedHash) {
        throw const FormatException('CAS 上传内容 hash 与预期不一致');
      }
      final target = File(
        '${_objects.path}${Platform.pathSeparator}$hash.blob',
      );
      if (temporary != null) {
        await _objects.create(recursive: true);
        if (await target.exists()) {
          await temporary.delete();
        } else {
          await temporary.rename(target.path);
        }
      }
      await _deleteUnpinnedObjects(await _readState(), protectedHashes: [hash]);
      return LocalCasObjectReference(hash: hash, bytes: received);
    } on Object {
      if (output != null && !outputClosed) await output.close();
      if (!hashClosed) hashSink.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  Future<List<LocalVersionRecord>> list(String namespace) => _serialize(
    () async => List.unmodifiable(
      (await _readState())[namespace]?.versions ?? const [],
    ),
  );

  Future<LocalVersionRecord?> current(String namespace) =>
      _serialize(() async => (await _readState())[namespace]?.current);

  Future<LocalVersionRecord> recordAtRevision(String namespace, int revision) =>
      _serialize(() async {
        final records = (await _readState())[namespace]?.versions ?? const [];
        return records.firstWhere(
          (record) => record.revision == revision,
          orElse: () => throw StateError('本地版本不存在'),
        );
      });

  Future<Uint8List> readRecordContent(LocalVersionRecord record) => _serialize(
    () => _readObject(
      LocalCasObjectReference(
        hash: record.contentHash,
        bytes: record.contentBytes,
      ),
    ),
  );

  Future<Uint8List> readObject(LocalCasObjectReference reference) =>
      _serialize(() => _readObject(reference));

  Future<bool> containsObject(LocalCasObjectReference reference) =>
      _serialize(() async {
        try {
          await _verifyObject(reference);
          return true;
        } on LocalVersionObjectMissing {
          return false;
        }
      });

  Future<LocalVersionCommitResult> commit({
    required String namespace,
    required int expectedRevision,
    required LocalVersionDraft current,
    List<LocalVersionDraft> history = const [],
  }) => _serialize(
    () => _serializeProject(
      () => _withStoreLock(() async {
        _validateNamespace(namespace);
        final state = await _readState();
        final target = state.putIfAbsent(
          namespace,
          () => _LocalVersionNamespaceState(),
        );
        final currentRevision = _latestRevision(target);
        if (currentRevision != expectedRevision) {
          throw LocalVersionRevisionConflict(currentRevision);
        }

        final currentRecord = await _buildRecord(
          draft: current,
          revision: currentRevision,
          idPrefix: 'current',
        );
        final created = <LocalVersionRecord>[];
        var deduplicated = false;
        for (final draft in history) {
          final candidate = await _buildRecord(
            draft: draft,
            revision:
                (target.versions.lastOrNull?.revision ?? currentRevision) + 1,
            idPrefix: 'v',
          );
          if (draft.deduplicateHistoryHead &&
              target.versions.lastOrNull?.contentHash ==
                  candidate.contentHash) {
            deduplicated = true;
            continue;
          }
          target.versions.add(candidate);
          created.add(candidate);
        }
        target.current =
            created.lastOrNull?.contentHash == currentRecord.contentHash
            ? created.last
            : currentRecord;

        _applyRetention(state, namespace);
        _enforceQuotas(state, namespace);
        await _writeState(state);
        await _deleteUnpinnedObjects(state);
        return LocalVersionCommitResult(
          created: List.unmodifiable(created),
          current: target.current!,
          deduplicated: deduplicated,
        );
      }),
    ),
  );

  /// 在项目级事务锁内删除该 store 的 state/CAS/staging。
  Future<void> deleteStore() => _serialize(
    () => _serializeProject(() async {
      await root.create(recursive: true);
      final lockPath = '${root.path}${Platform.pathSeparator}.store.lock';
      final lockFile = File(lockPath);
      final lock = await lockFile.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        await for (final entity in root.list(followLinks: false)) {
          if (entity.path == lockPath) continue;
          await entity.delete(recursive: true);
        }
      } finally {
        try {
          await lock.unlock();
        } finally {
          await lock.close();
        }
      }
      if (await lockFile.exists()) await lockFile.delete();
      if (await root.exists() && await root.list().isEmpty) {
        await root.delete();
      }
    }),
  );

  Future<T> _withStoreLock<T>(Future<T> Function() action) async {
    await root.create(recursive: true);
    final lock = await File(
      '${root.path}${Platform.pathSeparator}.store.lock',
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      return await action();
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<T> _serializeProject<T>(Future<T> Function() action) {
    final key = Platform.isWindows
        ? root.absolute.path.toLowerCase()
        : root.absolute.path;
    final previous = _projectTails[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final tail = operation.then<void>((_) {}, onError: (_, _) {});
    _projectTails[key] = tail;
    tail.whenComplete(() {
      if (identical(_projectTails[key], tail)) _projectTails.remove(key);
    });
    return operation;
  }

  Future<LocalVersionRecord> _buildRecord({
    required LocalVersionDraft draft,
    required int revision,
    required String idPrefix,
  }) async {
    if (draft.content.isEmpty) throw const FormatException('本地版本内容不能为空');
    jsonEncode(draft.attributes);
    final content = await _stageObjectUnlocked(draft.content);
    for (final reference in draft.references) {
      await _verifyObject(reference);
    }
    final timestamp = clock().toUtc();
    return LocalVersionRecord(
      id: '$idPrefix$revision-${timestamp.microsecondsSinceEpoch}',
      revision: revision,
      timestamp: timestamp,
      contentHash: content.hash,
      contentBytes: content.bytes,
      references: List.unmodifiable(draft.references),
      attributes: Map.unmodifiable(draft.attributes),
    );
  }

  Future<Map<String, _LocalVersionNamespaceState>> _readState() async {
    await root.create(recursive: true);
    final index = File('${root.path}${Platform.pathSeparator}state.json');
    final backup = File('${index.path}.backup');
    if (!await index.exists() && await backup.exists()) {
      await backup.rename(index.path);
    }
    if (!await index.exists()) return {};
    final decoded = jsonDecode(await index.readAsString());
    if (decoded is! Map || decoded['schemaVersion'] != schemaVersion) {
      throw const FormatException('本地版本状态格式无效');
    }
    final namespaces = decoded['namespaces'];
    if (namespaces is! Map) throw const FormatException('本地版本状态格式无效');
    return <String, _LocalVersionNamespaceState>{
      for (final entry in namespaces.entries)
        entry.key as String: _decodeNamespace(entry.value),
    };
  }

  _LocalVersionNamespaceState _decodeNamespace(Object? raw) {
    if (raw is! Map || raw['versions'] is! List) {
      throw const FormatException('本地版本命名空间格式无效');
    }
    LocalVersionRecord? current;
    if (raw['current'] case final Map value) {
      current = LocalVersionRecord.fromJson(Map<String, Object?>.from(value));
    }
    final versions = <LocalVersionRecord>[];
    var previousRevision = 0;
    for (final item in raw['versions']! as List) {
      if (item is! Map) throw const FormatException('本地版本索引格式无效');
      final record = LocalVersionRecord.fromJson(
        Map<String, Object?>.from(item),
      );
      if (record.revision <= previousRevision) {
        throw const FormatException('本地版本修订顺序无效');
      }
      previousRevision = record.revision;
      versions.add(record);
    }
    return _LocalVersionNamespaceState(current: current, versions: versions);
  }

  Future<void> _writeState(
    Map<String, _LocalVersionNamespaceState> state,
  ) async {
    await root.create(recursive: true);
    final index = File('${root.path}${Platform.pathSeparator}state.json');
    final temporary = File(
      '${index.path}.tmp-${clock().microsecondsSinceEpoch}',
    );
    final backup = File('${index.path}.backup');
    await temporary.writeAsString(
      jsonEncode({
        'schemaVersion': schemaVersion,
        'namespaces': {
          for (final entry in state.entries) entry.key: entry.value.toJson(),
        },
      }),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await index.exists()) await index.rename(backup.path);
    try {
      await temporary.rename(index.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (!await index.exists() && await backup.exists()) {
        await backup.rename(index.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _applyRetention(
    Map<String, _LocalVersionNamespaceState> state,
    String changedNamespace,
  ) {
    final changed = state[changedNamespace]!;
    while (changed.versions.length > retentionPolicy.maxVersionsPerNamespace) {
      changed.versions.removeAt(0);
    }
    while (_namespaceBytes(changed) >
            retentionPolicy.maxUniqueBytesPerNamespace &&
        _removeOldestEvictable(changed)) {}
  }

  void _enforceQuotas(
    Map<String, _LocalVersionNamespaceState> state,
    String changedNamespace,
  ) {
    if (_namespaceBytes(state[changedNamespace]!) >
        retentionPolicy.maxUniqueBytesPerNamespace) {
      throw LocalVersionQuotaExceeded(
        scope: 'project',
        limit: retentionPolicy.maxUniqueBytesPerNamespace,
      );
    }
  }

  int _namespaceBytes(_LocalVersionNamespaceState state) => _uniqueBytes([
    if (state.current != null) state.current!,
    ...state.versions,
  ]);

  int _uniqueBytes(Iterable<LocalVersionRecord> records) {
    final sizes = <String, int>{};
    for (final record in records) {
      for (final reference in record.pinnedObjects) {
        sizes[reference.hash] = reference.bytes;
      }
    }
    return sizes.values.fold(0, (total, bytes) => total + bytes);
  }

  int _latestRevision(_LocalVersionNamespaceState state) {
    final historyRevision = state.versions.lastOrNull?.revision ?? 0;
    final currentRevision = state.current?.revision ?? 0;
    return historyRevision > currentRevision
        ? historyRevision
        : currentRevision;
  }

  bool _removeOldestEvictable(_LocalVersionNamespaceState state) {
    final index = state.versions.indexWhere(
      (record) => record.id != state.current?.id,
    );
    if (index < 0) return false;
    state.versions.removeAt(index);
    return true;
  }

  Future<String> _contentHash(Uint8List content) async {
    final digest = await Sha256().hash(content);
    return _hex(digest.bytes);
  }

  Directory get _objects =>
      Directory('${root.path}${Platform.pathSeparator}cas');

  Future<LocalCasObjectReference> _stageObjectUnlocked(
    Uint8List content,
  ) async {
    if (content.isEmpty) throw const FormatException('CAS 对象不能为空');
    if (content.length > retentionPolicy.maxObjectBytes) {
      throw LocalVersionQuotaExceeded(
        scope: 'object',
        limit: retentionPolicy.maxObjectBytes,
      );
    }
    final hash = await _contentHash(content);
    await _writeObject(hash, content);
    return LocalCasObjectReference(hash: hash, bytes: content.length);
  }

  Future<void> _writeObject(String hash, Uint8List content) async {
    await _objects.create(recursive: true);
    final target = File('${_objects.path}${Platform.pathSeparator}$hash.blob');
    if (await target.exists()) return;
    final temporary = File(
      '${target.path}.tmp-${clock().microsecondsSinceEpoch}',
    );
    await temporary.writeAsBytes(content, flush: true);
    try {
      if (!await target.exists()) await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _verifyObject(LocalCasObjectReference reference) async {
    final file = File(
      '${_objects.path}${Platform.pathSeparator}${reference.hash}.blob',
    );
    if (!await file.exists()) throw LocalVersionObjectMissing(reference.hash);
    if (await file.length() != reference.bytes) {
      throw LocalVersionObjectMissing(reference.hash);
    }
  }

  Future<Uint8List> _readObject(LocalCasObjectReference reference) async {
    await _verifyObject(reference);
    final file = File(
      '${_objects.path}${Platform.pathSeparator}${reference.hash}.blob',
    );
    final bytes = await file.readAsBytes();
    if (await _contentHash(bytes) != reference.hash) {
      throw StateError('本地 CAS 内容校验失败');
    }
    return bytes;
  }

  Future<void> _deleteUnpinnedObjects(
    Map<String, _LocalVersionNamespaceState> state, {
    Iterable<String> protectedHashes = const <String>[],
  }) async {
    onGarbageCollection?.call();
    if (!await _objects.exists()) return;
    final pinned = <String>{...protectedHashes};
    for (final namespace in state.values) {
      for (final record in [
        if (namespace.current != null) namespace.current!,
        ...namespace.versions,
      ]) {
        pinned.addAll(record.pinnedObjects.map((reference) => reference.hash));
      }
    }
    final expiresBefore = clock().toUtc().subtract(retentionPolicy.stagingTtl);
    await for (final entity in _objects.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.blob')) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      final hash = name.substring(0, name.length - 5);
      if (pinned.contains(hash)) continue;
      final modified = (await entity.stat()).modified.toUtc();
      if (!modified.isAfter(expiresBefore)) await entity.delete();
    }
  }

  void _validateNamespace(String namespace) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$').hasMatch(namespace)) {
      throw const FormatException('本地版本命名空间无效');
    }
  }
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
