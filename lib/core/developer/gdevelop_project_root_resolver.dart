import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';
import 'project_provisioning_service.dart';

enum GDevelopProjectEnsureOrigin {
  create('create'),
  open('open'),
  legacyOpen('legacy_open'),
  importProject('import'),
  saveAs('save_as'),
  duplicate('duplicate');

  const GDevelopProjectEnsureOrigin(this.wireName);
  final String wireName;

  static GDevelopProjectEnsureOrigin parse(String value) => values.firstWhere(
    (origin) => origin.wireName == value,
    orElse: () => throw const FormatException('GDevelop ensure origin 无效'),
  );
}

@Deprecated('Use ProjectProvisioningConflict')
typedef GDevelopProjectRootConflict = ProjectProvisioningConflict;

@Deprecated('Use ProjectProvisioningMissing')
typedef GDevelopProjectRootMissing = ProjectProvisioningMissing;

class GDevelopProjectRootInfo {
  const GDevelopProjectRootInfo({
    required this.gameId,
    required this.root,
    required this.historyRoot,
    required this.created,
    required this.name,
    required this.fileIdentifiers,
    required this.createdAt,
    required this.updatedAt,
  });

  final String gameId;
  final Directory root;
  final Directory historyRoot;
  final bool created;
  final String? name;
  final List<String> fileIdentifiers;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'gameId': gameId,
    'created': created,
    if (name != null) 'name': name,
    'fileIdentifiers': fileIdentifiers,
  };

  /// 只返回 `.playmesh/project.json` 的产品身份字段，不暴露本地目录。
  Map<String, Object?> toIdentityJson() => {
    'schemaVersion': FileSystemGDevelopProjectRootResolver.schemaVersion,
    'kind': PlaymeshProjectKind.gdevelop.wireName,
    'gameId': gameId,
    if (name != null) 'name': name,
    'fileIdentifiers': fileIdentifiers,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class GDevelopProjectRootListResult {
  const GDevelopProjectRootListResult({
    required this.projects,
    required this.diagnostics,
  });

  final List<GDevelopProjectRootInfo> projects;
  final List<ProjectProvisioningListDiagnostic> diagnostics;
}

class GDevelopProjectCleanupResult {
  const GDevelopProjectCleanupResult({required this.pendingRetry});
  final bool pendingRetry;
}

abstract interface class GDevelopProjectRootResolver {
  Future<GDevelopProjectRootListResult> listProjectRoots();

  Future<GDevelopProjectRootInfo> ensureProjectRoot({
    required String gameId,
    required GDevelopProjectEnsureOrigin origin,
    String? fileIdentifier,
    String? name,
  });

  Future<Directory> resolveHistoryRoot(String gameId);

  /// 返回规范项目根位置，不创建目录，也不要求项目已经存在。
  Future<Directory> projectRootLocation(String gameId);

  Future<Set<String>> historicalGameIds(String gameId);

  Future<T> runInProjectRoot<T>(
    String gameId,
    Future<T> Function(Directory root) action,
  );

  Future<GDevelopProjectRootInfo> updateMetadata({
    required String gameId,
    String? fileIdentifier,
    String? name,
  });

  Future<GDevelopProjectCleanupResult> deleteProject(String gameId);
}

/// 把 GDevelop `gameId` 映射到
/// `playmesh-library/GDevelop/packages/{gameId}` 项目根。
///
/// 该 resolver 只维护 App 权威的项目根身份与平台 sidecar，不创建伪
/// `game.json`、`main.json` 或资源文件；WebIDE 存储只能作为可丢弃缓存。
class FileSystemGDevelopProjectRootResolver
    implements GDevelopProjectRootResolver {
  FileSystemGDevelopProjectRootResolver({
    Directory? projectsRoot,
    ProjectProvisioningService? provisioning,
    File? cleanupJournal,
    Future<void> Function(Directory directory)? deleteDirectory,
    Future<Directory> Function(Directory directory, String targetPath)?
    renameDirectory,
    DateTime Function()? clock,
  }) : _injectedProjectsRoot = projectsRoot,
       _injectedProvisioning = provisioning,
       _injectedCleanupJournal = cleanupJournal,
       _deleteDirectory = deleteDirectory ?? _deleteRecursively,
       _renameDirectory = renameDirectory ?? _rename,
       clock = clock ?? DateTime.now;

  static const schemaVersion = 1;
  static final Map<String, Future<void>> _projectTails = {};
  static Future<void> _cleanupTail = Future<void>.value();

  final Directory? _injectedProjectsRoot;
  final ProjectProvisioningService? _injectedProvisioning;
  final File? _injectedCleanupJournal;
  final Future<void> Function(Directory directory) _deleteDirectory;
  final Future<Directory> Function(Directory directory, String targetPath)
  _renameDirectory;
  final DateTime Function() clock;
  Directory? _resolvedProjectsRoot;
  ProjectProvisioningService? _resolvedProvisioning;
  File? _resolvedCleanupJournal;

  @override
  Future<GDevelopProjectRootListResult> listProjectRoots() async {
    final listed = await (await _provisioning()).listProjects(
      kind: PlaymeshProjectKind.gdevelop,
    );
    final projects = <GDevelopProjectRootInfo>[];
    final diagnostics = <ProjectProvisioningListDiagnostic>[
      ...listed.diagnostics,
    ];
    for (final project in listed.projects) {
      try {
        final metadata = _GDevelopProjectRootMetadata.fromJson(
          project.metadata,
        );
        projects.add(
          _info(
            project.root,
            _historyRoot(project.root),
            metadata,
            created: false,
          ),
        );
      } on FormatException {
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic.gdevelopMetadataInvalidCode,
            directoryName: project.gameId,
            gameId: project.gameId,
          ),
        );
      }
    }
    diagnostics.sort((left, right) {
      final directory = left.directoryName.compareTo(right.directoryName);
      return directory != 0 ? directory : left.code.compareTo(right.code);
    });
    return GDevelopProjectRootListResult(
      projects: List.unmodifiable(projects),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  @override
  Future<GDevelopProjectRootInfo> ensureProjectRoot({
    required String gameId,
    required GDevelopProjectEnsureOrigin origin,
    String? fileIdentifier,
    String? name,
  }) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    final normalizedFileIdentifier = _normalizeOptionalFileIdentifier(
      fileIdentifier,
    );
    final normalizedName = _normalizeOptionalName(name, gameId: normalized);
    return _serializeProject(normalized, () async {
      await _retryCleanup(normalized);
      final provisioning = await _provisioning();
      final fallbackName = normalizedName ?? normalized;
      ProvisionedProject project;
      switch (origin) {
        case GDevelopProjectEnsureOrigin.create:
        case GDevelopProjectEnsureOrigin.importProject:
        case GDevelopProjectEnsureOrigin.duplicate:
          project = await provisioning.createProject(
            gameId: normalized,
            name: fallbackName,
            kind: PlaymeshProjectKind.gdevelop,
            additionalMetadata: {
              'fileIdentifiers': [?normalizedFileIdentifier],
            },
          );
          break;
        case GDevelopProjectEnsureOrigin.open:
          project = await provisioning.openProject(
            gameId: normalized,
            kind: PlaymeshProjectKind.gdevelop,
          );
          break;
        case GDevelopProjectEnsureOrigin.legacyOpen:
          project = await provisioning.bindProject(
            gameId: normalized,
            name: fallbackName,
            kind: PlaymeshProjectKind.gdevelop,
            additionalMetadata: {
              'fileIdentifiers': [?normalizedFileIdentifier],
            },
          );
          break;
        case GDevelopProjectEnsureOrigin.saveAs:
          try {
            project = await provisioning.openProject(
              gameId: normalized,
              kind: PlaymeshProjectKind.gdevelop,
            );
          } on ProjectProvisioningMissing {
            project = await provisioning.createProject(
              gameId: normalized,
              name: fallbackName,
              kind: PlaymeshProjectKind.gdevelop,
              additionalMetadata: {
                'fileIdentifiers': [?normalizedFileIdentifier],
              },
            );
          }
          break;
      }
      if (!project.created &&
          (normalizedFileIdentifier != null || normalizedName != null)) {
        project = await provisioning.updateMetadata(
          gameId: normalized,
          kind: PlaymeshProjectKind.gdevelop,
          name: normalizedName,
          update: (metadata) {
            final identifiers = <String>{
              ..._metadataFileIdentifiers(metadata),
              ?normalizedFileIdentifier,
            }.toList()..sort();
            return metadata..['fileIdentifiers'] = identifiers;
          },
        );
      }
      final root = project.root;
      final metadata = _GDevelopProjectRootMetadata.fromJson(project.metadata);
      final historyRoot = _historyRoot(root);
      await historyRoot.create(recursive: true);
      return _info(root, historyRoot, metadata, created: project.created);
    });
  }

  @override
  Future<Directory> resolveHistoryRoot(String gameId) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return _serializeProject(normalized, () async {
      final project = await (await _provisioning()).openProject(
        gameId: normalized,
        kind: PlaymeshProjectKind.gdevelop,
      );
      final root = project.root;
      final historyRoot = _historyRoot(root);
      await historyRoot.create(recursive: true);
      return historyRoot;
    });
  }

  @override
  Future<Directory> projectRootLocation(String gameId) =>
      _projectRoot(ProjectProvisioningService.validateGameId(gameId));

  @override
  Future<Set<String>> historicalGameIds(String gameId) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    final project = await (await _provisioning()).openProject(
      gameId: normalized,
      kind: PlaymeshProjectKind.gdevelop,
    );
    final raw = project.metadata['previousGameIds'];
    if (raw == null) return {normalized};
    if (raw is! List) throw const FormatException('GDevelop 历史身份别名无效');
    return {
      normalized,
      for (final value in raw)
        if (value is String)
          ProjectProvisioningService.validateGameId(value)
        else
          throw const FormatException('GDevelop 历史身份别名无效'),
    };
  }

  @override
  Future<T> runInProjectRoot<T>(
    String gameId,
    Future<T> Function(Directory root) action,
  ) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return _serializeProject(normalized, () async {
      final root = (await (await _provisioning()).openProject(
        gameId: normalized,
        kind: PlaymeshProjectKind.gdevelop,
      )).root;
      return action(root);
    });
  }

  @override
  Future<GDevelopProjectRootInfo> updateMetadata({
    required String gameId,
    String? fileIdentifier,
    String? name,
  }) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    final normalizedFileIdentifier = _normalizeOptionalFileIdentifier(
      fileIdentifier,
    );
    final normalizedName = _normalizeOptionalName(name, gameId: normalized);
    return _serializeProject(normalized, () async {
      final project = await (await _provisioning()).updateMetadata(
        gameId: normalized,
        kind: PlaymeshProjectKind.gdevelop,
        name: normalizedName,
        update: (metadata) {
          final identifiers = <String>{
            ..._metadataFileIdentifiers(metadata),
            ?normalizedFileIdentifier,
          }.toList()..sort();
          return metadata..['fileIdentifiers'] = identifiers;
        },
      );
      final metadata = _GDevelopProjectRootMetadata.fromJson(project.metadata);
      return _info(
        project.root,
        _historyRoot(project.root),
        metadata,
        created: false,
      );
    });
  }

  @override
  Future<GDevelopProjectCleanupResult> deleteProject(String gameId) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return _serializeProject(normalized, () async {
      final root = (await (await _provisioning()).openProject(
        gameId: normalized,
        kind: PlaymeshProjectKind.gdevelop,
      )).root;
      final tombstone = await _projectDeletionTombstone(normalized);
      await _retryCleanup(normalized);
      if (await tombstone.exists()) {
        throw FileSystemException('此前的 GDevelop 源工程清理仍未完成', tombstone.path);
      }
      await tombstone.parent.create(recursive: true);
      // 同卷 rename 是删除操作的唯一提交点：失败时原工程完整保留；成功后
      // packages/{gameId} 立即消失，后台清理失败只留下不可见 tombstone。
      await _renameDirectory(root, tombstone.path);
      try {
        await _deleteDirectory(tombstone);
        await _removeCleanupEntry(normalized);
        return const GDevelopProjectCleanupResult(pendingRetry: false);
      } on FileSystemException {
        try {
          await _recordCleanup(normalized);
        } on FileSystemException {
          // tombstone 路径由 gameId 确定；journal 写失败也能在下一次
          // ensure/delete 时通过目录存在性恢复清理。
        }
        return const GDevelopProjectCleanupResult(pendingRetry: true);
      }
    });
  }

  Future<Directory> _projectsRoot() async {
    final cached = _resolvedProjectsRoot;
    if (cached != null) return cached;
    final injected = _injectedProjectsRoot;
    if (injected != null) {
      await injected.create(recursive: true);
      return _resolvedProjectsRoot = injected;
    }
    final injectedProvisioning = _injectedProvisioning;
    if (injectedProvisioning != null) {
      return _resolvedProjectsRoot = await injectedProvisioning.projectsRoot();
    }
    final library = await PlaymeshLibraryRoot.resolve();
    final root = Directory(
      '${library.path}${Platform.pathSeparator}GDevelop'
      '${Platform.pathSeparator}packages',
    );
    await root.create(recursive: true);
    return _resolvedProjectsRoot = root;
  }

  Future<ProjectProvisioningService> _provisioning() async {
    final injected = _injectedProvisioning;
    if (injected != null) return injected;
    final cached = _resolvedProvisioning;
    if (cached != null) return cached;
    return _resolvedProvisioning = ProjectProvisioningService(
      projectsRoot: await _projectsRoot(),
      clock: clock,
    );
  }

  Future<Directory> _projectRoot(String gameId) async {
    return (await _provisioning()).projectRoot(gameId);
  }

  Directory _historyRoot(Directory root) => Directory(
    '${root.path}${Platform.pathSeparator}.playmesh'
    '${Platform.pathSeparator}gdevelop'
    '${Platform.pathSeparator}history',
  );

  Future<File> _cleanupJournal() async {
    final cached = _resolvedCleanupJournal;
    if (cached != null) return cached;
    final injected = _injectedCleanupJournal;
    if (injected != null) return _resolvedCleanupJournal = injected;
    final library = await PlaymeshLibraryRoot.resolve();
    return _resolvedCleanupJournal = File(
      '${library.path}${Platform.pathSeparator}GDevelop'
      '${Platform.pathSeparator}history-cleanup-v1.json',
    );
  }

  GDevelopProjectRootInfo _info(
    Directory root,
    Directory historyRoot,
    _GDevelopProjectRootMetadata metadata, {
    required bool created,
  }) => GDevelopProjectRootInfo(
    gameId: metadata.gameId,
    root: root,
    historyRoot: historyRoot,
    created: created,
    name: metadata.name,
    fileIdentifiers: List.unmodifiable(metadata.fileIdentifiers),
    createdAt: metadata.createdAt,
    updatedAt: metadata.updatedAt,
  );

  Future<void> _retryCleanup(String gameId) async {
    final tombstone = await _projectDeletionTombstone(gameId);
    final pending = await _readCleanupEntries();
    if (!pending.contains(gameId) && !await tombstone.exists()) return;
    try {
      if (await tombstone.exists()) await _deleteDirectory(tombstone);
      await _removeCleanupEntry(gameId);
    } on FileSystemException {
      // ensure/open 不被旧 tombstone 清理失败阻断，后续继续重试。
    }
  }

  Future<Directory> _projectDeletionTombstone(String gameId) async {
    final projectsRoot = await _projectsRoot();
    return Directory(
      '${projectsRoot.path}.deletions${Platform.pathSeparator}$gameId',
    );
  }

  Future<void> _recordCleanup(String gameId) => _serializeCleanup(() async {
    final entries = await _readCleanupEntriesUnlocked();
    entries.add(gameId);
    await _writeCleanupEntries(entries);
  });

  Future<void> _removeCleanupEntry(String gameId) =>
      _serializeCleanup(() async {
        final entries = await _readCleanupEntriesUnlocked();
        if (!entries.remove(gameId)) return;
        await _writeCleanupEntries(entries);
      });

  Future<Set<String>> _readCleanupEntries() =>
      _serializeCleanup(_readCleanupEntriesUnlocked);

  Future<Set<String>> _readCleanupEntriesUnlocked() async {
    final file = await _cleanupJournal();
    if (!await file.exists()) return <String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['pending'] is! List) return <String>{};
    return (decoded['pending']! as List).whereType<String>().where((value) {
      try {
        ProjectProvisioningService.validateGameId(value);
        return true;
      } on FormatException {
        return false;
      }
    }).toSet();
  }

  Future<void> _writeCleanupEntries(Set<String> entries) async {
    final file = await _cleanupJournal();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final sorted = entries.toList()..sort();
    await temporary.writeAsString(
      jsonEncode({'schemaVersion': schemaVersion, 'pending': sorted}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<T> _serializeProject<T>(String gameId, Future<T> Function() action) {
    final rootKey = _injectedProjectsRoot?.absolute.path ?? 'default';
    final key = '$rootKey\n$gameId';
    final previous = _projectTails[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final tail = operation.then<void>((_) {}, onError: (_, _) {});
    _projectTails[key] = tail;
    tail.whenComplete(() {
      if (identical(_projectTails[key], tail)) _projectTails.remove(key);
    });
    return operation;
  }

  Future<T> _serializeCleanup<T>(Future<T> Function() action) {
    final operation = _cleanupTail.then((_) => action());
    _cleanupTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}

Future<Directory> _rename(Directory directory, String targetPath) =>
    directory.rename(targetPath);

class _GDevelopProjectRootMetadata {
  const _GDevelopProjectRootMetadata({
    required this.gameId,
    required this.name,
    required this.fileIdentifiers,
    required this.createdAt,
    required this.updatedAt,
  });

  final String gameId;
  final String? name;
  final List<String> fileIdentifiers;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'schemaVersion': FileSystemGDevelopProjectRootResolver.schemaVersion,
    'kind': 'gdevelop',
    'gameId': gameId,
    if (name != null) 'name': name,
    'fileIdentifiers': fileIdentifiers,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory _GDevelopProjectRootMetadata.fromJson(Map<String, Object?> json) {
    final gameId = json['gameId'];
    final name = json['name'];
    final identifiers = json['fileIdentifiers'];
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (json['schemaVersion'] !=
            FileSystemGDevelopProjectRootResolver.schemaVersion ||
        json['kind'] != 'gdevelop' ||
        gameId is! String ||
        (name != null && name is! String) ||
        identifiers is! List ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException('GDevelop 项目元数据无效');
    }
    return _GDevelopProjectRootMetadata(
      gameId: ProjectProvisioningService.validateGameId(gameId),
      name: name as String?,
      fileIdentifiers:
          identifiers
              .map((value) {
                if (value is! String) {
                  throw const FormatException('GDevelop fileIdentifier 无效');
                }
                return _normalizeOptionalFileIdentifier(value)!;
              })
              .toSet()
              .toList()
            ..sort(),
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
    );
  }
}

String? _normalizeOptionalFileIdentifier(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(normalized)) {
    throw const FormatException('GDevelop fileIdentifier 无效');
  }
  return normalized;
}

String? _normalizeOptionalName(String? value, {required String gameId}) {
  if (value == null) return null;
  return ProjectProvisioningService.validateIdentity(
    gameId: gameId,
    name: value,
  ).name;
}

List<String> _metadataFileIdentifiers(Map<String, Object?> metadata) {
  final value = metadata['fileIdentifiers'];
  if (value == null) return const [];
  if (value is! List) throw const FormatException('GDevelop 项目元数据无效');
  return value.map((identifier) {
    if (identifier is! String) {
      throw const FormatException('GDevelop fileIdentifier 无效');
    }
    return _normalizeOptionalFileIdentifier(identifier)!;
  }).toList();
}

Future<void> _deleteRecursively(Directory directory) =>
    directory.delete(recursive: true);
