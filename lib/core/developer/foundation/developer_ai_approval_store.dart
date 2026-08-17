import 'dart:convert';
import 'dart:io';

import '../../library/playmesh_library_root.dart';

class DeveloperAiApprovalGrant {
  const DeveloperAiApprovalGrant({
    required this.scopeKind,
    required this.scopeId,
    required this.operationId,
  });

  final String scopeKind;
  final String scopeId;
  final String operationId;

  String get cacheKey => '$scopeKind::$scopeId::$operationId';

  String get id => base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');

  Map<String, Object?> toJson() => {
    'scopeKind': scopeKind,
    'scopeId': scopeId,
    'operationId': operationId,
  };

  Map<String, Object?> toPublicJson() => {
    'grantId': id,
    ...toJson(),
    if (scopeKind == 'source') 'projectId': scopeId,
    if (scopeKind == 'gdevelop') 'gameId': scopeId,
  };

  factory DeveloperAiApprovalGrant.fromJson(Map<String, Object?> json) {
    final scopeKind = json['scopeKind'];
    final scopeId = json['scopeId'];
    final operationId = json['operationId'];
    if (scopeKind is! String ||
        !RegExp(r'^[a-z][a-z0-9._-]{0,31}$').hasMatch(scopeKind) ||
        scopeId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(scopeId) ||
        operationId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(operationId)) {
      throw const FormatException('持久 AI 审批授权格式无效');
    }
    return DeveloperAiApprovalGrant(
      scopeKind: scopeKind,
      scopeId: scopeId,
      operationId: operationId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeveloperAiApprovalGrant && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}

abstract interface class DeveloperAiApprovalPersistence {
  Future<Set<DeveloperAiApprovalGrant>> load();

  Future<void> save(Iterable<DeveloperAiApprovalGrant> grants);
}

class FileDeveloperAiApprovalPersistence
    implements DeveloperAiApprovalPersistence {
  FileDeveloperAiApprovalPersistence({Directory? libraryRoot, File? file})
    : this._(libraryRoot, file);

  FileDeveloperAiApprovalPersistence._(this._libraryRoot, this._injectedFile);

  static const formatVersion = '1.0.0';

  final Directory? _libraryRoot;
  final File? _injectedFile;
  File? _resolvedFile;
  Future<void> _tail = Future<void>.value();

  @override
  Future<Set<DeveloperAiApprovalGrant>> load() => _serialize(() async {
    final file = await _file();
    final backup = File('${file.path}.playmesh-backup');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    if (!await file.exists()) return <DeveloperAiApprovalGrant>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['formatVersion'] != formatVersion) {
      throw const FormatException('持久 AI 审批授权根格式无效');
    }
    final rawGrants = decoded['grants'];
    if (rawGrants is! List) {
      throw const FormatException('持久 AI 审批授权列表无效');
    }
    return {
      for (final raw in rawGrants)
        if (raw is Map)
          DeveloperAiApprovalGrant.fromJson(Map<String, Object?>.from(raw))
        else
          throw const FormatException('持久 AI 审批授权项无效'),
    };
  });

  @override
  Future<void> save(
    Iterable<DeveloperAiApprovalGrant> grants,
  ) => _serialize(() async {
    final normalized =
        {for (final grant in grants) grant.cacheKey: grant}.values.toList()
          ..sort((left, right) => left.cacheKey.compareTo(right.cacheKey));
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.playmesh-tmp');
    final backup = File('${file.path}.playmesh-backup');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'formatVersion': formatVersion, 'grants': normalized.map((grant) => grant.toJson()).toList()})}\n',
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await file.exists()) await file.delete();
      if (await backup.exists()) await backup.rename(file.path);
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<File> _file() async {
    final cached = _resolvedFile;
    if (cached != null) return cached;
    final injected = _injectedFile;
    if (injected != null) return _resolvedFile = injected;
    final root = _libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    return _resolvedFile = File(
      '${root.path}${Platform.pathSeparator}developer'
      '${Platform.pathSeparator}ai-approval-grants-v1.json',
    );
  }
}
