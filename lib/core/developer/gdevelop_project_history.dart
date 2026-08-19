import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'foundation/local_version_store.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_files.dart';
import 'gdevelop_project_root_resolver.dart';
import 'project_provisioning_service.dart';

enum GDevelopHistoryReason {
  explicitSave('explicit_save'),
  importantChange('important_change'),
  autosave('autosave'),
  beforeRestore('before_restore'),
  restore('restore');

  const GDevelopHistoryReason(this.wireName);

  final String wireName;

  static GDevelopHistoryReason parse(String value) => values.firstWhere(
    (reason) => reason.wireName == value,
    orElse: () => throw const FormatException('GDevelop 历史 reason 无效'),
  );
}

enum GDevelopHistorySource {
  user('user'),
  system('system');

  const GDevelopHistorySource(this.wireName);

  final String wireName;

  static GDevelopHistorySource parse(String value) => values.firstWhere(
    (source) => source.wireName == value,
    orElse: () => throw const FormatException('GDevelop 历史 source 无效'),
  );
}

class GDevelopHistoryRevisionConflict implements Exception {
  const GDevelopHistoryRevisionConflict(this.currentRevision);

  final int currentRevision;
}

class GDevelopHistoryRevisionNotFound implements Exception {
  const GDevelopHistoryRevisionNotFound(this.revision);

  final int revision;
}

class GDevelopProjectResource {
  const GDevelopProjectResource({
    required this.logicalId,
    required this.contentHash,
    required this.mime,
    required this.size,
    this.name,
    this.metadata = const {},
  });

  final String logicalId;
  final String contentHash;
  final String mime;
  final int size;
  final String? name;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
    'logicalId': logicalId,
    if (name != null) 'name': name,
    'contentHash': contentHash,
    'mime': mime,
    'size': size,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory GDevelopProjectResource.fromJson(Map<String, Object?> json) {
    final logicalId = json['logicalId'];
    final contentHash = json['contentHash'];
    final mime = json['mime'];
    final size = json['size'];
    final name = json['name'];
    final metadata = json['metadata'];
    if (logicalId is! String ||
        logicalId.isEmpty ||
        logicalId.length > 1024 ||
        logicalId.contains(RegExp(r'[\x00-\x1f]')) ||
        !_isSafeLogicalId(logicalId)) {
      throw const FormatException('GDevelop 资源 logicalId 无效');
    }
    if (contentHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
      throw const FormatException('GDevelop 资源 contentHash 无效');
    }
    if (mime is! String || !_isAllowedResourceMime(mime)) {
      throw const FormatException('GDevelop 资源 mime 无效');
    }
    if (size is! int || size < 1) {
      throw const FormatException('GDevelop 资源 size 无效');
    }
    if (name != null && (name is! String || name.length > 255)) {
      throw const FormatException('GDevelop 资源 name 无效');
    }
    if (metadata != null && metadata is! Map) {
      throw const FormatException('GDevelop 资源 metadata 无效');
    }
    final normalizedMetadata = metadata == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(metadata as Map);
    jsonEncode(normalizedMetadata);
    return GDevelopProjectResource(
      logicalId: logicalId,
      contentHash: contentHash,
      mime: mime,
      size: size,
      name: name as String?,
      metadata: Map.unmodifiable(normalizedMetadata),
    );
  }
}

class GDevelopHistoryChangeSummary {
  const GDevelopHistoryChangeSummary({
    required this.added,
    required this.modified,
    required this.deleted,
  });

  final int added;
  final int modified;
  final int deleted;

  Map<String, Object?> toJson() => {
    'added': added,
    'modified': modified,
    'deleted': deleted,
  };

  factory GDevelopHistoryChangeSummary.fromJson(Map<String, Object?> json) {
    final added = json['added'];
    final modified = json['modified'];
    final deleted = json['deleted'];
    if (json.length != 3 ||
        added is! int ||
        added < 0 ||
        modified is! int ||
        modified < 0 ||
        deleted is! int ||
        deleted < 0) {
      throw const FormatException('GDevelop 历史变更摘要无效');
    }
    return GDevelopHistoryChangeSummary(
      added: added,
      modified: modified,
      deleted: deleted,
    );
  }
}

class GDevelopProjectVersion {
  const GDevelopProjectVersion({
    required this.id,
    required this.projectId,
    required this.revision,
    required this.timestamp,
    required this.reason,
    required this.contentHash,
    required this.source,
    required this.contentBytes,
    this.changeSummary,
  });

  final String id;
  final String projectId;
  final int revision;
  final DateTime timestamp;
  final GDevelopHistoryReason reason;
  final String contentHash;
  final GDevelopHistorySource source;
  final int contentBytes;
  final GDevelopHistoryChangeSummary? changeSummary;

  Map<String, Object?> toJson({bool includeChangeSummary = false}) => {
    'id': id,
    'gameId': projectId,
    'revision': revision,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'reason': reason.wireName,
    'contentHash': contentHash,
    'source': source.wireName,
    'contentBytes': contentBytes,
    if (includeChangeSummary && changeSummary != null)
      'changeSummary': changeSummary!.toJson(),
  };
}

enum GDevelopHistoryProjectConfigSemantics {
  ready('ready'),
  missing('missing'),
  legacy('legacy');

  const GDevelopHistoryProjectConfigSemantics(this.wireName);

  final String wireName;
}

class GDevelopHistoryProjectConfigSnapshot {
  const GDevelopHistoryProjectConfigSnapshot.ready(this.config)
    : semantics = GDevelopHistoryProjectConfigSemantics.ready;

  const GDevelopHistoryProjectConfigSnapshot.missing()
    : semantics = GDevelopHistoryProjectConfigSemantics.missing,
      config = null;

  const GDevelopHistoryProjectConfigSnapshot.legacy()
    : semantics = GDevelopHistoryProjectConfigSemantics.legacy,
      config = null;

  final GDevelopHistoryProjectConfigSemantics semantics;
  final GDevelopProjectConfig? config;

  Object? get payloadValue => switch (semantics) {
    GDevelopHistoryProjectConfigSemantics.ready => config!.toJson(),
    GDevelopHistoryProjectConfigSemantics.missing => null,
    GDevelopHistoryProjectConfigSemantics.legacy => null,
  };
}

class GDevelopProjectSnapshot {
  const GDevelopProjectSnapshot({
    required this.version,
    required this.projectFiles,
    required this.resources,
    this.projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  });

  final GDevelopProjectVersion version;
  final List<GDevelopProjectFile> projectFiles;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'version': version.toJson(),
    'projectFiles': projectFiles.map((file) => file.toJson()).toList(),
    'resources': resources.map((resource) => resource.toJson()).toList(),
    if (projectConfigSnapshot.semantics !=
        GDevelopHistoryProjectConfigSemantics.legacy)
      'playmeshProjectConfig': projectConfigSnapshot.payloadValue,
  };
}

class GDevelopSnapshotResult {
  const GDevelopSnapshotResult({
    required this.version,
    required this.deduplicated,
    required this.historyCreated,
  });

  final GDevelopProjectVersion version;
  final bool deduplicated;
  final bool historyCreated;
}

class GDevelopPreparedProjectState {
  const GDevelopPreparedProjectState({
    required this.projectFiles,
    required this.projectFilesReference,
    required this.resources,
  });

  final List<GDevelopProjectFile> projectFiles;
  final GDevelopProjectFilesReference projectFilesReference;
  final List<GDevelopProjectResource> resources;
}

/// Lightweight authoritative current descriptor for recovery/CAS checks.
/// Unlike [GDevelopProjectSnapshot], this does not read or decode project files.
class GDevelopProjectCurrentReferenceSnapshot {
  const GDevelopProjectCurrentReferenceSnapshot({
    required this.version,
    required this.projectFiles,
    required this.resources,
    this.projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  });

  final GDevelopProjectVersion version;
  final GDevelopProjectFilesReference projectFiles;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'revision': version.revision,
    'projectFiles': projectFiles.toJson(),
    'resources': resources.map((resource) => resource.toJson()).toList(),
    if (projectConfigSnapshot.semantics !=
        GDevelopHistoryProjectConfigSemantics.legacy)
      'playmeshProjectConfig': projectConfigSnapshot.payloadValue,
  };
}

enum GDevelopAuthoritativeProjectChangeReason { currentCommitted, restored }

/// 当前进程内的最小权威失效信号；只携带 CAS 摘要，不包含工程正文或工具参数。
class GDevelopAuthoritativeProjectChange {
  const GDevelopAuthoritativeProjectChange({
    required this.gameId,
    required this.revision,
    required this.projectContentHash,
    required this.resourceManifestHash,
    required this.reason,
    required this.sequence,
  });

  final String gameId;
  final int revision;
  final String projectContentHash;
  final String resourceManifestHash;
  final GDevelopAuthoritativeProjectChangeReason reason;
  final int sequence;
}

/// App 权威项目列表的一项：身份来自 project.json，current 只携带 CAS 证据。
class GDevelopManagedProjectSummary {
  const GDevelopManagedProjectSummary({
    required this.identity,
    required this.currentEvidence,
  });

  final GDevelopProjectRootInfo identity;
  final GDevelopProjectCurrentReferenceSnapshot? currentEvidence;

  Map<String, Object?> toJson() => {
    'identity': identity.toIdentityJson(),
    'currentEvidence': currentEvidence?.toJson(),
  };
}

class GDevelopManagedProjectListResult {
  const GDevelopManagedProjectListResult({
    required this.projects,
    required this.diagnostics,
    required this.activeGameId,
  });

  final List<GDevelopManagedProjectSummary> projects;
  final List<ProjectProvisioningListDiagnostic> diagnostics;

  /// App 侧最近成功打开、且仍有 current 的工程。浏览器 Origin 不参与选择。
  final String? activeGameId;
}

class GDevelopRestoreResult extends GDevelopProjectSnapshot {
  const GDevelopRestoreResult({
    required super.version,
    required super.projectFiles,
    required super.resources,
    super.projectConfigSnapshot,
    this.backupVersion,
  });

  final GDevelopProjectVersion? backupVersion;
}

class GDevelopProjectHistoryDiff {
  const GDevelopProjectHistoryDiff({
    required this.projectId,
    required this.fromRevision,
    required this.toRevision,
    required this.changed,
    required this.before,
    required this.after,
    required this.addedLines,
    required this.removedLines,
    required this.resourceChanges,
    required this.beforeResources,
    required this.afterResources,
  });

  final String projectId;
  final int fromRevision;
  final int toRevision;
  final bool changed;
  final String before;
  final String after;
  final int addedLines;
  final int removedLines;
  final Map<String, int> resourceChanges;
  final List<GDevelopProjectResource> beforeResources;
  final List<GDevelopProjectResource> afterResources;

  Map<String, Object?> toJson() => {
    'gameId': projectId,
    'fromRevision': fromRevision,
    'toRevision': toRevision,
    'changed': changed,
    'before': before,
    'after': after,
    'summary': {
      'addedLines': addedLines,
      'removedLines': removedLines,
      'resources': resourceChanges,
    },
    'resourceEvidence': {
      'before': beforeResources
          .map((resource) => resource.toJson())
          .toList(growable: false),
      'after': afterResources
          .map((resource) => resource.toJson())
          .toList(growable: false),
    },
  };
}

class _GDevelopRevisionPayload {
  const _GDevelopRevisionPayload({
    required this.projectFilesReference,
    required this.resources,
    required this.projectConfigSnapshot,
  });

  final GDevelopProjectFilesReference projectFilesReference;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'schemaVersion': 3,
    'projectFilesHash': projectFilesReference.contentHash,
    'projectFilesSize': projectFilesReference.size,
    'projectFiles': projectFilesReference.files
        .map((file) => file.toJson())
        .toList(growable: false),
    'resources': resources.map((resource) => resource.toJson()).toList(),
    if (projectConfigSnapshot.semantics !=
        GDevelopHistoryProjectConfigSemantics.legacy)
      'playmeshProjectConfig': projectConfigSnapshot.payloadValue,
  };
}

/// GDevelop 工程历史适配器；不接收源码工作区路径或 Playmesh `projectRef`。
class GDevelopProjectHistoryAdapter {
  GDevelopProjectHistoryAdapter({
    GDevelopProjectRootResolver? rootResolver,
    this.retentionPolicy = const LocalVersionRetentionPolicy(
      maxVersionsPerNamespace: 100,
      maxUniqueBytesPerNamespace: 16 * 1024 * 1024 * 1024,
      maxObjectBytes: 1024 * 1024 * 1024,
    ),
    DateTime Function()? clock,
    @visibleForTesting this.onCurrentBundleVerification,
    @visibleForTesting this.onCurrentProjectFileWritten,
  }) : rootResolver = rootResolver ?? FileSystemGDevelopProjectRootResolver(),
       clock = clock ?? DateTime.now;

  static const capability = 'gdevelop.history.v3';
  static const maxProjectFilesBytes = 1024 * 1024 * 1024;

  final GDevelopProjectRootResolver rootResolver;
  final LocalVersionRetentionPolicy retentionPolicy;
  final DateTime Function() clock;
  @visibleForTesting
  final void Function()? onCurrentBundleVerification;
  @visibleForTesting
  final FutureOr<void> Function(File file)? onCurrentProjectFileWritten;
  final Map<String, _GDevelopDirectCurrentStore> _currentStores = {};
  final Map<String, LocalVersionStore> _uploadStores = {};
  final Map<String, LocalVersionStore> _stores = {};
  final Map<String, Set<String>> _historicalProjectIds = {};
  final StreamController<GDevelopAuthoritativeProjectChange>
  _authoritativeChanges = StreamController.broadcast(sync: true);
  final Map<String, int> _authoritativeChangeSequences = {};

  Stream<GDevelopAuthoritativeProjectChange> get authoritativeChanges =>
      _authoritativeChanges.stream;

  /// 聚合 App 托管身份与轻量 current evidence，不读取完整工程文件树。
  Future<GDevelopManagedProjectListResult> listManagedProjects() async {
    final roots = await rootResolver.listProjectRoots();
    final projects = <GDevelopManagedProjectSummary>[];
    final diagnostics = <ProjectProvisioningListDiagnostic>[
      ...roots.diagnostics,
    ];
    for (final identity in roots.projects) {
      GDevelopProjectCurrentReferenceSnapshot? currentEvidence;
      try {
        currentEvidence = await currentReferenceSnapshot(identity.gameId);
      } on Object catch (error) {
        if (error is! FileSystemException &&
            error is! FormatException &&
            error is! StateError &&
            error is! ProjectProvisioningMissing &&
            error is! ProjectProvisioningConflict) {
          rethrow;
        }
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic
                .currentEvidenceUnavailableCode,
            directoryName: identity.gameId,
            gameId: identity.gameId,
          ),
        );
      }
      projects.add(
        GDevelopManagedProjectSummary(
          identity: identity,
          currentEvidence: currentEvidence,
        ),
      );
    }
    projects.sort((left, right) {
      final updated = right.identity.updatedAt.compareTo(
        left.identity.updatedAt,
      );
      return updated != 0
          ? updated
          : left.identity.gameId.compareTo(right.identity.gameId);
    });
    diagnostics.sort((left, right) {
      final directory = left.directoryName.compareTo(right.directoryName);
      return directory != 0 ? directory : left.code.compareTo(right.code);
    });
    final openableProjects = projects.where(
      (project) => project.currentEvidence != null,
    );
    return GDevelopManagedProjectListResult(
      projects: List.unmodifiable(projects),
      diagnostics: List.unmodifiable(diagnostics),
      activeGameId: openableProjects.firstOrNull?.identity.gameId,
    );
  }

  void releaseProjectCaches(Iterable<String> gameIds) {
    for (final gameId in gameIds) {
      final normalized = _normalizeProjectId(gameId);
      _currentStores.remove(normalized);
      _uploadStores.remove(normalized);
      _stores.remove(normalized);
      _historicalProjectIds.remove(normalized);
    }
  }

  Future<GDevelopProjectRootInfo> createProjectRoot({
    required String gameId,
    required GDevelopProjectEnsureOrigin origin,
    String? fileIdentifier,
    String? name,
  }) => rootResolver.ensureProjectRoot(
    gameId: gameId,
    origin: origin,
    fileIdentifier: fileIdentifier,
    name: name,
  );

  Future<GDevelopProjectRootInfo> openProjectRoot({
    required String gameId,
    String? fileIdentifier,
    String? name,
  }) => rootResolver.ensureProjectRoot(
    gameId: gameId,
    origin: GDevelopProjectEnsureOrigin.open,
    fileIdentifier: fileIdentifier,
    name: name,
  );

  Future<GDevelopProjectRootInfo> updateProjectMetadata({
    required String gameId,
    String? fileIdentifier,
    String? name,
  }) => rootResolver.updateMetadata(
    gameId: gameId,
    fileIdentifier: fileIdentifier,
    name: name,
  );

  Future<GDevelopProjectCleanupResult> deleteProject(String gameId) async {
    final normalized = _normalizeProjectId(gameId);
    // 完整项目删除以项目根同卷 rename 为唯一原子提交点；失败时
    // current 源码、历史、配置与保护资源必须仍完整存在。
    final result = await rootResolver.deleteProject(normalized);
    _currentStores.remove(normalized);
    _uploadStores.remove(normalized);
    _stores.remove(normalized);
    _historicalProjectIds.remove(normalized);
    return result;
  }

  Future<void> clearHistory(String gameId) async {
    final normalized = _normalizeProjectId(gameId);
    final store = await _store(normalized);
    await store.deleteStore();
    _stores.remove(normalized);
    _historicalProjectIds.remove(normalized);
  }

  Future<LocalCasObjectReference> stageResourceStream({
    required String projectId,
    required String expectedHash,
    required int? contentLength,
    required Stream<List<int>> bytes,
    Duration inactivityTimeout = const Duration(seconds: 30),
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedHash)) {
      throw const FormatException('GDevelop 资源 hash 无效');
    }
    final staged = await (await _uploadStore(normalized)).stageStream(
      bytes,
      expectedBytes: contentLength,
      expectedHash: expectedHash,
      timeout: inactivityTimeout,
    );
    if (staged.hash != expectedHash) {
      throw const FormatException('GDevelop 资源 hash 校验失败');
    }
    return staged;
  }

  Future<List<LocalCasObjectReference>> missingResources({
    required String projectId,
    required List<LocalCasObjectReference> resources,
  }) async {
    final normalizedProjectId = _normalizeProjectId(projectId);
    if (resources.length > 2048) {
      throw const FormatException('GDevelop 资源预检最多支持 2048 项');
    }
    final unique = <String, LocalCasObjectReference>{};
    for (final resource in resources) {
      final normalized = LocalCasObjectReference.fromJson(resource.toJson());
      if (normalized.bytes > retentionPolicy.maxObjectBytes) {
        throw LocalVersionQuotaExceeded(
          scope: 'object',
          limit: retentionPolicy.maxObjectBytes,
        );
      }
      final previous = unique[normalized.hash];
      if (previous != null && previous.bytes != normalized.bytes) {
        throw const FormatException('同一 GDevelop 资源 hash 的 size 不一致');
      }
      unique[normalized.hash] = normalized;
    }
    final currentStore = await _currentStore(normalizedProjectId);
    final uploadStore = await _uploadStore(normalizedProjectId);
    final availableInCurrent = await currentStore.containedResourceHashes(
      unique.values,
    );
    final missing = <LocalCasObjectReference>[];
    for (final resource in unique.values) {
      if (!availableInCurrent.contains(resource.hash) &&
          !await uploadStore.containsObject(resource)) {
        missing.add(resource);
      }
    }
    return List.unmodifiable(missing);
  }

  Future<List<GDevelopProjectVersion>> list(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    final records = await (await _store(normalized)).list(_namespace);
    return List.unmodifiable(
      records.reversed.map((record) => _version(normalized, record)),
    );
  }

  Future<GDevelopProjectSnapshot?> current(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).read(normalized);
  }

  /// Reads the authoritative current tree from an allocation staging root.
  ///
  /// Allocation uses this after the raw upload has been materialized into the
  /// same multi-file current layout used by normal projects. The upload DTO is
  /// transport evidence only and is not retained as a second project source.
  Future<GDevelopProjectSnapshot?> currentAtProjectRoot({
    required Directory projectRoot,
    required String projectId,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    return _directCurrentStoreAtProjectRoot(projectRoot).read(normalized);
  }

  /// Returns the current files in the wire shape used by normal WebIDE open.
  ///
  /// This path deliberately does not validate persisted content. JSON decode
  /// is only required because the HTTP response embeds project files as JSON
  /// values. Mutation, restore and history APIs keep using the typed methods.
  Future<Map<String, Object?>?> openCurrent(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).readOpenCurrent();
  }

  Future<GDevelopProjectFilesReference?> currentProjectFilesReference(
    String projectId,
  ) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).projectFilesReference(normalized);
  }

  Future<GDevelopProjectCurrentReferenceSnapshot?> currentReferenceSnapshot(
    String projectId,
  ) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).referenceSnapshot(normalized);
  }

  Future<GDevelopProjectCurrentReferenceSnapshot> referenceAtRevision({
    required String projectId,
    required int revision,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (revision < 1) {
      throw const FormatException('GDevelop 历史修订号无效');
    }
    final store = await _store(normalized);
    late final LocalVersionRecord record;
    try {
      record = await store.recordAtRevision(_namespace, revision);
    } on StateError {
      throw GDevelopHistoryRevisionNotFound(revision);
    }
    return _referenceSnapshot(normalized, store, record);
  }

  Future<GDevelopProjectCurrentReferenceSnapshot> _referenceSnapshot(
    String projectId,
    LocalVersionStore store,
    LocalVersionRecord record,
  ) async {
    final payload = await _payload(store, record);
    await _verifyPayloadObjects(store, payload);
    return GDevelopProjectCurrentReferenceSnapshot(
      version: _version(projectId, record),
      projectFiles: payload.projectFilesReference,
      resources: payload.resources,
      projectConfigSnapshot: payload.projectConfigSnapshot,
    );
  }

  Future<List<GDevelopProjectFile>> readHistoryProjectFilesReference({
    required String projectId,
    required GDevelopProjectFilesReference reference,
  }) async {
    final store = await _store(_normalizeProjectId(projectId));
    return _readProjectFilesReference(store, reference);
  }

  Future<GDevelopPreparedProjectState> prepareProjectState({
    required String projectId,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final store = await _store(normalized);
    final normalizedProjectFiles = _normalizeProjectFiles(projectFiles);
    final projectFilesReference = await _stageProjectFiles(
      store,
      normalizedProjectFiles,
    );
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: normalizedResources,
      projectConfigSnapshot:
          const GDevelopHistoryProjectConfigSnapshot.missing(),
    );
    await _verifyPayloadObjects(store, payload);
    return GDevelopPreparedProjectState(
      projectFiles: normalizedProjectFiles,
      projectFilesReference: projectFilesReference,
      resources: normalizedResources,
    );
  }

  Future<String> revisionPayloadContentHash({
    required String projectId,
    required GDevelopProjectFilesReference projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final normalizedConfig = _validateProjectConfigSnapshot(
      normalized,
      projectConfigSnapshot,
    );
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFiles,
      resources: _validateResources(resources),
      projectConfigSnapshot: normalizedConfig,
    );
    final digest = await Sha256().hash(
      utf8.encode(jsonEncode(payload.toJson())),
    );
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<Uint8List> readProjectFileBytes({
    required String projectId,
    required GDevelopProjectFileReference reference,
  }) async {
    final store = await _store(_normalizeProjectId(projectId));
    final casReference = _projectFileCasReference(reference);
    return store.readObject(casReference);
  }

  /// 在 allocation sibling staging 中建立首个权威 current。
  ///
  /// 该入口复用同一 LocalVersionStore/CAS 格式，但不把临时根加入 canonical
  /// project cache；重复调用只接受完全相同的工程、资源与配置证据。
  Future<GDevelopProjectCurrentReferenceSnapshot>
  initializeCurrentAtProjectRoot({
    required Directory projectRoot,
    required Directory historyRoot,
    required String projectId,
    required GDevelopProjectFilesReference projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final store = LocalVersionStore(
      root: historyRoot,
      retentionPolicy: retentionPolicy,
      clock: clock,
    );
    final normalizedResources = _validateResources(resources);
    final normalizedConfig = _validateProjectConfigSnapshot(
      normalized,
      projectConfigSnapshot,
    );
    await _readProjectFilesReference(store, projectFiles);
    final currentStore = _directCurrentStoreAtProjectRoot(projectRoot);
    final current = await currentStore.referenceSnapshot(normalized);
    if (current != null) {
      _requireCurrentEvidence(
        current,
        projectFiles: projectFiles,
        resources: normalizedResources,
        projectConfigSnapshot: normalizedConfig,
      );
      return current;
    }
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFiles,
      resources: normalizedResources,
      projectConfigSnapshot: normalizedConfig,
    );
    await _verifyPayloadObjects(store, payload);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      attributes: _attributes(
        projectId: normalized,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        changeSummary: _changeSummary(null, payload),
      ),
      references: [
        ...projectFiles.files.map(_projectFileCasReference),
        for (final resource in normalizedResources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
      ],
    );
    final committed = await store.commit(
      namespace: _namespace,
      expectedRevision: 0,
      current: draft,
      history: [draft],
    );
    final projectFileValues = await _readProjectFilesReference(
      store,
      projectFiles,
    );
    final snapshot = await currentStore.commit(
      projectId: normalized,
      expectedRevision: 0,
      revisionDelta: 1,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: projectFileValues,
      resources: normalizedResources,
      projectConfigSnapshot: normalizedConfig,
      readResource: (reference) => store.readObject(reference),
    );
    if (committed.created.length != 1) {
      throw StateError('GDevelop 初始历史版本未创建');
    }
    return snapshot;
  }

  /// COMMIT 前只读复核 staging current；缺失或任何 evidence 变化都失败关闭。
  Future<GDevelopProjectCurrentReferenceSnapshot> verifyCurrentAtProjectRoot({
    required Directory projectRoot,
    required String projectId,
    required GDevelopProjectFilesReference projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final snapshot = await _directCurrentStoreAtProjectRoot(
      projectRoot,
    ).referenceSnapshot(normalized);
    if (snapshot == null) throw StateError('GDevelop staging current 不存在');
    _requireCurrentEvidence(
      snapshot,
      projectFiles: projectFiles,
      resources: _validateResources(resources),
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        normalized,
        projectConfigSnapshot,
      ),
    );
    return snapshot;
  }

  void _requireCurrentEvidence(
    GDevelopProjectCurrentReferenceSnapshot snapshot, {
    required GDevelopProjectFilesReference projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) {
    final actual = {
      'projectFiles': snapshot.projectFiles.toJson(),
      'resources': snapshot.resources
          .map((resource) => resource.toJson())
          .toList(),
      'playmeshProjectConfig': snapshot.projectConfigSnapshot.payloadValue,
      'playmeshProjectConfigSemantics':
          snapshot.projectConfigSnapshot.semantics.wireName,
    };
    final expected = {
      'projectFiles': projectFiles.toJson(),
      'resources': resources.map((resource) => resource.toJson()).toList(),
      'playmeshProjectConfig': projectConfigSnapshot.payloadValue,
      'playmeshProjectConfigSemantics':
          projectConfigSnapshot.semantics.wireName,
    };
    if (jsonEncode(actual) != jsonEncode(expected)) {
      throw StateError('GDevelop staging current evidence 不一致');
    }
  }

  Future<GDevelopSnapshotResult> saveCurrent({
    required String projectId,
    required int baseRevision,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  }) => _commitProject(
    projectId: projectId,
    baseRevision: baseRevision,
    reason: GDevelopHistoryReason.explicitSave,
    source: source,
    projectFiles: projectFiles,
    resources: resources,
    projectConfigSnapshot: projectConfigSnapshot,
    createHistory: false,
  );

  Future<GDevelopSnapshotResult> snapshot({
    required String projectId,
    required int baseRevision,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  }) {
    if ({
      GDevelopHistoryReason.beforeRestore,
      GDevelopHistoryReason.restore,
    }.contains(reason)) {
      throw const FormatException('该 reason 只能由恢复流程写入');
    }
    return _commitProject(
      projectId: projectId,
      baseRevision: baseRevision,
      reason: reason,
      source: source,
      projectFiles: projectFiles,
      resources: resources,
      projectConfigSnapshot: projectConfigSnapshot,
      createHistory: true,
    );
  }

  Future<GDevelopSnapshotResult> _commitProject({
    required String projectId,
    required int baseRevision,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    required bool createHistory,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final normalizedProjectFiles = _normalizeProjectFiles(projectFiles);
    final normalizedResources = _validateResources(resources);
    final normalizedConfig = _validateProjectConfigSnapshot(
      normalized,
      projectConfigSnapshot,
    );
    final currentStore = await _currentStore(normalized);
    final uploadStore = await _uploadStore(normalized);
    final missing = await missingResources(
      projectId: normalized,
      resources: normalizedResources
          .map(
            (resource) => LocalCasObjectReference(
              hash: resource.contentHash,
              bytes: resource.size,
            ),
          )
          .toList(growable: false),
    );
    if (missing.isNotEmpty) {
      throw LocalVersionObjectMissing(missing.first.hash);
    }
    try {
      final currentSnapshot = await currentStore.commit(
        projectId: normalized,
        expectedRevision: baseRevision,
        revisionDelta: createHistory || baseRevision == 0 ? 1 : 0,
        reason: reason,
        source: source,
        projectFiles: normalizedProjectFiles,
        resources: normalizedResources,
        projectConfigSnapshot: normalizedConfig,
        readResource: uploadStore.readObject,
      );
      await _emitAuthoritativeChange(
        currentSnapshot,
        GDevelopAuthoritativeProjectChangeReason.currentCommitted,
      );
      var deduplicated = false;
      var historyCreated = false;
      if (createHistory) {
        try {
          final appended = await _appendCurrentToHistory(
            projectId: normalized,
            current: currentSnapshot,
            projectFiles: normalizedProjectFiles,
            resources: normalizedResources,
            projectConfigSnapshot: normalizedConfig,
            reason: reason,
            source: source,
          );
          deduplicated = appended.deduplicated;
          historyCreated = appended.created.isNotEmpty;
        } on Object {
          // current 是唯一权威源码。历史写入失败不能把已成功的保存伪装成失败，
          // 也不能回滚 current；调用方通过 historyCreated=false 展示诊断。
        }
      }
      return GDevelopSnapshotResult(
        version: currentSnapshot.version,
        deduplicated: deduplicated,
        historyCreated: historyCreated,
      );
    } on _GDevelopDirectCurrentRevisionConflict catch (error) {
      throw GDevelopHistoryRevisionConflict(error.currentRevision);
    }
  }

  Future<LocalVersionCommitResult> _appendCurrentToHistory({
    required String projectId,
    required GDevelopProjectCurrentReferenceSnapshot current,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    bool deduplicateHistoryHead = true,
  }) async {
    final currentStore = await _currentStore(projectId);
    final historyStore = await _store(projectId);
    final resourcesMissingFromHistory = <LocalCasObjectReference>[];
    for (final resource in resources) {
      final reference = LocalCasObjectReference(
        hash: resource.contentHash,
        bytes: resource.size,
      );
      if (!await historyStore.containsObject(reference)) {
        resourcesMissingFromHistory.add(reference);
      }
    }
    final currentResourceBytes = await currentStore.readResourceObjects(
      resourcesMissingFromHistory,
      verifyContentHash: false,
    );
    final projectFileBytes = projectFiles
        .map((file) => encodeOfficialGDevelopProjectFileBytes(file.content))
        .toList(growable: false);
    final stagedObjects = await historyStore.stageObjects([
      ...projectFileBytes,
      for (final reference in resourcesMissingFromHistory)
        currentResourceBytes[reference.hash]!,
    ]);
    if (current.projectFiles.files.length != projectFiles.length) {
      throw StateError('GDevelop current 工程分片证据不一致');
    }
    for (var index = 0; index < projectFiles.length; index += 1) {
      final expected = current.projectFiles.files[index];
      final staged = stagedObjects[index];
      if (expected.path != projectFiles[index].path ||
          expected.contentHash != staged.hash ||
          expected.size != staged.bytes) {
        throw StateError('GDevelop current 工程分片证据不一致');
      }
    }
    final projectFilesReference = current.projectFiles;
    _requireCurrentEvidence(
      current,
      projectFiles: projectFilesReference,
      resources: resources,
      projectConfigSnapshot: projectConfigSnapshot,
    );
    for (
      var index = 0;
      index < resourcesMissingFromHistory.length;
      index += 1
    ) {
      final reference = resourcesMissingFromHistory[index];
      final staged = stagedObjects[projectFileBytes.length + index];
      if (staged.hash != reference.hash || staged.bytes != reference.bytes) {
        throw StateError('GDevelop current 资源写入历史时发生变化');
      }
    }
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: resources,
      projectConfigSnapshot: projectConfigSnapshot,
    );
    final head = await historyStore.current(_namespace);
    final previousPayload = head == null
        ? null
        : await _payload(historyStore, head);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      attributes: _attributes(
        projectId: projectId,
        reason: reason,
        source: source,
        changeSummary: _changeSummary(previousPayload, payload),
      ),
      references: [
        ...projectFilesReference.files.map(_projectFileCasReference),
        for (final resource in resources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
      ],
      deduplicateHistoryHead: deduplicateHistoryHead,
    );
    return historyStore.commit(
      namespace: _namespace,
      expectedRevision: head?.revision ?? 0,
      current: draft,
      history: [draft],
    );
  }

  Future<GDevelopProjectHistoryDiff> diff({
    required String projectId,
    required int fromRevision,
    required int toRevision,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (fromRevision < 1 || toRevision < 1 || fromRevision == toRevision) {
      throw const FormatException('GDevelop 历史 diff 修订号无效');
    }
    final store = await _store(normalized);
    final from = await store.recordAtRevision(_namespace, fromRevision);
    final to = await store.recordAtRevision(_namespace, toRevision);
    final beforeSnapshot = await _snapshot(normalized, store, from);
    final afterSnapshot = await _snapshot(normalized, store, to);
    final before = const JsonEncoder.withIndent(
      '  ',
    ).convert(unsplitGDevelopProjectFiles(beforeSnapshot.projectFiles));
    final after = const JsonEncoder.withIndent(
      '  ',
    ).convert(unsplitGDevelopProjectFiles(afterSnapshot.projectFiles));
    final beforeLines = const LineSplitter().convert(before);
    final afterLines = const LineSplitter().convert(after);
    final commonPrefix = _commonPrefixLength(beforeLines, afterLines);
    final commonSuffix = _commonSuffixLength(
      beforeLines,
      afterLines,
      commonPrefix,
    );
    final beforeResources = {
      for (final item in beforeSnapshot.resources)
        item.logicalId: item.contentHash,
    };
    final afterResources = {
      for (final item in afterSnapshot.resources)
        item.logicalId: item.contentHash,
    };
    final resourceKeys = {...beforeResources.keys, ...afterResources.keys};
    return GDevelopProjectHistoryDiff(
      projectId: normalized,
      fromRevision: fromRevision,
      toRevision: toRevision,
      changed: from.contentHash != to.contentHash,
      before: before,
      after: after,
      addedLines: afterLines.length - commonPrefix - commonSuffix,
      removedLines: beforeLines.length - commonPrefix - commonSuffix,
      resourceChanges: {
        'added': resourceKeys
            .where((key) => !beforeResources.containsKey(key))
            .length,
        'removed': resourceKeys
            .where((key) => !afterResources.containsKey(key))
            .length,
        'changed': resourceKeys
            .where(
              (key) =>
                  beforeResources.containsKey(key) &&
                  afterResources.containsKey(key) &&
                  beforeResources[key] != afterResources[key],
            )
            .length,
      },
      beforeResources: beforeSnapshot.resources,
      afterResources: afterSnapshot.resources,
    );
  }

  Future<GDevelopRestoreResult> restore({
    required String projectId,
    required int baseRevision,
    required int targetRevision,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> currentProjectFiles,
    required List<GDevelopProjectResource> currentResources,
    GDevelopHistoryProjectConfigSnapshot currentProjectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
    GDevelopHistoryProjectConfigSnapshot? restoredProjectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (targetRevision < 1) {
      throw const FormatException('GDevelop 历史目标修订号无效');
    }
    final store = await _store(normalized);
    final current = await _draft(
      store: store,
      projectId: normalized,
      reason: GDevelopHistoryReason.beforeRestore,
      source: source,
      projectFiles: currentProjectFiles,
      resources: currentResources,
      projectConfigSnapshot: currentProjectConfigSnapshot,
      deduplicateHistoryHead: false,
    );
    return _commitRestore(
      projectId: normalized,
      store: store,
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      source: source,
      currentDraft: current.draft,
      currentPayload: current.payload,
      restoredProjectConfigSnapshot: restoredProjectConfigSnapshot,
    );
  }

  /// 使用 PREPARE 阶段已校验的 CAS 引用恢复，避免在 durable journal 里复制工程文件树。
  Future<GDevelopRestoreResult> restorePrepared({
    required String projectId,
    required int baseRevision,
    required int targetRevision,
    required GDevelopHistorySource source,
    required GDevelopProjectFilesReference currentProjectFiles,
    required List<GDevelopProjectResource> currentResources,
    GDevelopHistoryProjectConfigSnapshot currentProjectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
    GDevelopHistoryProjectConfigSnapshot? restoredProjectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (targetRevision < 1) {
      throw const FormatException('GDevelop 历史目标修订号无效');
    }
    final store = await _store(normalized);
    await _readProjectFilesReference(store, currentProjectFiles);
    final current = await _draftPreparedReference(
      store: store,
      projectId: normalized,
      reason: GDevelopHistoryReason.beforeRestore,
      source: source,
      projectFilesReference: currentProjectFiles,
      resources: currentResources,
      projectConfigSnapshot: currentProjectConfigSnapshot,
    );
    return _commitRestore(
      projectId: normalized,
      store: store,
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      source: source,
      currentDraft: current.draft,
      currentPayload: current.payload,
      restoredProjectConfigSnapshot: restoredProjectConfigSnapshot,
    );
  }

  Future<GDevelopRestoreResult> _commitRestore({
    required String projectId,
    required LocalVersionStore store,
    required int baseRevision,
    required int targetRevision,
    required GDevelopHistorySource source,
    required LocalVersionDraft currentDraft,
    required _GDevelopRevisionPayload currentPayload,
    required GDevelopHistoryProjectConfigSnapshot?
    restoredProjectConfigSnapshot,
  }) async {
    final target = await store.recordAtRevision(_namespace, targetRevision);
    final targetPayload = await _payload(store, target);
    await _verifyPayloadObjects(store, targetPayload);
    final targetProjectFiles = await _readProjectFilesReference(
      store,
      targetPayload.projectFilesReference,
    );
    final restoredPayload = _GDevelopRevisionPayload(
      projectFilesReference: targetPayload.projectFilesReference,
      resources: targetPayload.resources,
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        projectId,
        restoredProjectConfigSnapshot ?? targetPayload.projectConfigSnapshot,
      ),
    );
    final restoredDraft = LocalVersionDraft(
      content: Uint8List.fromList(
        utf8.encode(jsonEncode(restoredPayload.toJson())),
      ),
      attributes: _attributes(
        projectId: projectId,
        reason: GDevelopHistoryReason.restore,
        source: source,
      ),
      references: target.references,
      deduplicateHistoryHead: false,
    );
    try {
      final currentSnapshot = await (await _currentStore(projectId)).commit(
        projectId: projectId,
        expectedRevision: baseRevision,
        revisionDelta: 1,
        reason: GDevelopHistoryReason.restore,
        source: source,
        projectFiles: targetProjectFiles,
        resources: targetPayload.resources,
        projectConfigSnapshot: restoredPayload.projectConfigSnapshot,
        readResource: (reference) => store.readObject(reference),
      );
      final historyHead = await store.current(_namespace);
      final previousPayload = historyHead == null
          ? null
          : await _payload(store, historyHead);
      final summarizedCurrentDraft = _withChangeSummary(
        currentDraft,
        _changeSummary(previousPayload, currentPayload),
      );
      final summarizedRestoredDraft = _withChangeSummary(
        restoredDraft,
        _changeSummary(currentPayload, restoredPayload),
      );
      final result = await store.commit(
        namespace: _namespace,
        expectedRevision: historyHead?.revision ?? 0,
        current: summarizedRestoredDraft,
        history: [summarizedCurrentDraft, summarizedRestoredDraft],
      );
      final backup = result.created.length > 1 ? result.created.first : null;
      await _emitAuthoritativeChange(
        currentSnapshot,
        GDevelopAuthoritativeProjectChangeReason.restored,
      );
      return GDevelopRestoreResult(
        version: currentSnapshot.version,
        backupVersion: backup == null ? null : _version(projectId, backup),
        projectFiles: targetProjectFiles,
        resources: targetPayload.resources,
        projectConfigSnapshot: restoredPayload.projectConfigSnapshot,
      );
    } on _GDevelopDirectCurrentRevisionConflict catch (error) {
      throw GDevelopHistoryRevisionConflict(error.currentRevision);
    }
  }

  Future<({Uint8List bytes, GDevelopProjectResource resource})> readResource({
    required String projectId,
    required String contentHash,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
      throw const FormatException('GDevelop 资源 hash 无效');
    }
    final currentStore = await _currentStore(normalized);
    final current = await currentStore.referenceSnapshot(normalized);
    if (current != null) {
      for (final resource in current.resources) {
        if (resource.contentHash != contentHash) continue;
        final reference = LocalCasObjectReference(
          hash: resource.contentHash,
          bytes: resource.size,
        );
        return (
          bytes: await currentStore.readResourceObject(reference),
          resource: resource,
        );
      }
    }
    final store = await _store(normalized);
    final records = <LocalVersionRecord>[...await store.list(_namespace)];
    for (final record in records) {
      final payload = await _payload(store, record);
      for (final resource in payload.resources) {
        if (resource.contentHash != contentHash) continue;
        final reference = LocalCasObjectReference(
          hash: resource.contentHash,
          bytes: resource.size,
        );
        return (bytes: await store.readObject(reference), resource: resource);
      }
    }
    throw StateError('GDevelop 资源不存在或未被工程引用');
  }

  /// Relays a current resource for normal WebIDE open.
  ///
  /// The URL hash is validated solely to keep path construction contained.
  /// The resource does not have to be present in or agree with the manifest.
  Future<Uint8List> readOpenResource({
    required String projectId,
    required String contentHash,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
      throw const FormatException('GDevelop 资源 hash 无效');
    }
    final current = await (await _currentStore(
      normalized,
    )).readOpenResource(contentHash);
    if (current != null) return current;
    final historyStore = await _store(normalized);
    final historicalFile = File(
      '${historyStore.root.path}${Platform.pathSeparator}cas'
      '${Platform.pathSeparator}$contentHash.blob',
    );
    if (await historicalFile.exists()) return historicalFile.readAsBytes();
    throw StateError('GDevelop 资源不存在');
  }

  Future<({Uint8List bytes, GDevelopProjectResource resource})>
  readResourceAtRevision({
    required String projectId,
    required int revision,
    required String logicalId,
    required String contentHash,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    if (revision < 1) {
      throw const FormatException('GDevelop 历史资源修订号无效');
    }
    if (logicalId.isEmpty ||
        logicalId.length > 1024 ||
        logicalId.contains(RegExp(r'[\x00-\x1f]')) ||
        !_isSafeLogicalId(logicalId)) {
      throw const FormatException('GDevelop 资源 logicalId 无效');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
      throw const FormatException('GDevelop 资源 hash 无效');
    }
    final store = await _store(normalized);
    final record = await store.recordAtRevision(_namespace, revision);
    final payload = await _payload(store, record);
    final resource = payload.resources
        .where((item) => item.logicalId == logicalId)
        .firstOrNull;
    if (resource == null || resource.contentHash != contentHash) {
      throw StateError('GDevelop 资源不属于指定历史修订');
    }
    final reference = LocalCasObjectReference(
      hash: resource.contentHash,
      bytes: resource.size,
    );
    return (bytes: await store.readObject(reference), resource: resource);
  }

  Future<({LocalVersionDraft draft, _GDevelopRevisionPayload payload})> _draft({
    required LocalVersionStore store,
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    bool deduplicateHistoryHead = true,
  }) async {
    final projectFilesReference = await _stageProjectFiles(
      store,
      _normalizeProjectFiles(projectFiles),
    );
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: normalizedResources,
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        projectId,
        projectConfigSnapshot,
      ),
    );
    await _verifyPayloadObjects(store, payload);
    return (
      draft: LocalVersionDraft(
        content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
        attributes: _attributes(
          projectId: projectId,
          reason: reason,
          source: source,
        ),
        references: [
          ...projectFilesReference.files.map(_projectFileCasReference),
          for (final resource in normalizedResources)
            LocalCasObjectReference(
              hash: resource.contentHash,
              bytes: resource.size,
            ),
        ],
        deduplicateHistoryHead: deduplicateHistoryHead,
      ),
      payload: payload,
    );
  }

  Future<({LocalVersionDraft draft, _GDevelopRevisionPayload payload})>
  _draftPreparedReference({
    required LocalVersionStore store,
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required GDevelopProjectFilesReference projectFilesReference,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: normalizedResources,
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        projectId,
        projectConfigSnapshot,
      ),
    );
    await _verifyPayloadObjects(store, payload);
    return (
      draft: LocalVersionDraft(
        content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
        attributes: _attributes(
          projectId: projectId,
          reason: reason,
          source: source,
        ),
        references: [
          ...projectFilesReference.files.map(_projectFileCasReference),
          for (final resource in normalizedResources)
            LocalCasObjectReference(
              hash: resource.contentHash,
              bytes: resource.size,
            ),
        ],
        deduplicateHistoryHead: false,
      ),
      payload: payload,
    );
  }

  Future<List<GDevelopProjectFile>> _readProjectFilesReference(
    LocalVersionStore store,
    GDevelopProjectFilesReference reference,
  ) async {
    if (reference.size < 1 || reference.size > maxProjectFilesBytes) {
      throw const FormatException('GDevelop 工程大小必须在 1 B 至 1 GiB 之间');
    }
    final files = <GDevelopProjectFile>[];
    for (final fileReference in reference.files) {
      final bytes = await store.readObject(
        _projectFileCasReference(fileReference),
      );
      late final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on Object {
        throw const FormatException('GDevelop 工程必须是 UTF-8 JSON');
      }
      if (decoded is! Map) {
        throw const FormatException('GDevelop 工程 JSON 根节点必须是对象');
      }
      files.add(
        GDevelopProjectFile(
          path: fileReference.path,
          content: Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(decoded),
          ),
        ),
      );
    }
    final result = List<GDevelopProjectFile>.unmodifiable(files);
    final computed = await referenceGDevelopProjectFiles(result);
    if (computed.contentHash != reference.contentHash ||
        computed.size != reference.size) {
      throw StateError('GDevelop 工程文件树与引用不一致');
    }
    return result;
  }

  Future<void> _emitAuthoritativeChange(
    GDevelopProjectCurrentReferenceSnapshot snapshot,
    GDevelopAuthoritativeProjectChangeReason reason,
  ) async {
    final digest = await Sha256().hash(
      utf8.encode(
        jsonEncode(
          _canonicalizeJson(
            snapshot.resources.map((resource) => resource.toJson()).toList(),
          ),
        ),
      ),
    );
    final resourceManifestHash = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final change = GDevelopAuthoritativeProjectChange(
      gameId: snapshot.version.projectId,
      revision: snapshot.version.revision,
      projectContentHash: snapshot.projectFiles.contentHash,
      resourceManifestHash: resourceManifestHash,
      reason: reason,
      sequence: _authoritativeChangeSequences.update(
        snapshot.version.projectId,
        (value) => value + 1,
        ifAbsent: () => 1,
      ),
    );
    try {
      _authoritativeChanges.add(change);
    } on Object {
      // 当前已经提交；任何监听器异常都不能破坏权威历史结果。
    }
  }

  List<GDevelopProjectResource> _validateResources(
    List<GDevelopProjectResource> resources,
  ) {
    final logicalIdIndexes = <String, int>{};
    final result = <GDevelopProjectResource>[];
    for (var index = 0; index < resources.length; index += 1) {
      final resource = resources[index];
      final normalized = GDevelopProjectResource.fromJson(resource.toJson());
      final previousIndex = logicalIdIndexes[normalized.logicalId];
      if (previousIndex != null) {
        throw FormatException(
          'GDevelop resources[$index].logicalId 与 '
          'resources[$previousIndex].logicalId 重复',
        );
      }
      logicalIdIndexes[normalized.logicalId] = index;
      result.add(normalized);
    }
    result.sort((left, right) => left.logicalId.compareTo(right.logicalId));
    return List.unmodifiable(result);
  }

  GDevelopHistoryProjectConfigSnapshot _validateProjectConfigSnapshot(
    String projectId,
    GDevelopHistoryProjectConfigSnapshot snapshot,
  ) {
    if (snapshot.semantics != GDevelopHistoryProjectConfigSemantics.ready) {
      return snapshot;
    }
    return GDevelopHistoryProjectConfigSnapshot.ready(
      GDevelopProjectConfig.fromJson(
        snapshot.config!.toJson(),
        expectedGameId: projectId,
      ),
    );
  }

  Future<void> _verifyPayloadObjects(
    LocalVersionStore store,
    _GDevelopRevisionPayload payload,
  ) async {
    for (final file in payload.projectFilesReference.files) {
      await store.readObject(_projectFileCasReference(file));
    }
    for (final resource in payload.resources) {
      await store.readObject(
        LocalCasObjectReference(
          hash: resource.contentHash,
          bytes: resource.size,
        ),
      );
    }
  }

  Future<_GDevelopRevisionPayload> _payload(
    LocalVersionStore store,
    LocalVersionRecord record,
  ) async {
    final decoded = jsonDecode(
      utf8.decode(await store.readRecordContent(record)),
    );
    if (decoded is! Map || decoded['schemaVersion'] != 3) {
      throw StateError('GDevelop 历史资源清单无效');
    }
    final projectFilesHash = decoded['projectFilesHash'];
    final projectFilesSize = decoded['projectFilesSize'];
    final projectFiles = decoded['projectFiles'];
    final resources = decoded['resources'];
    if (projectFilesHash is! String ||
        projectFilesSize is! int ||
        projectFiles is! List ||
        resources is! List) {
      throw StateError('GDevelop 历史资源清单无效');
    }
    late final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;
    if (!decoded.containsKey('playmeshProjectConfig')) {
      throw StateError('GDevelop 历史资源清单无效');
    }
    final rawConfig = decoded['playmeshProjectConfig'];
    if (rawConfig == null) {
      projectConfigSnapshot =
          const GDevelopHistoryProjectConfigSnapshot.missing();
    } else if (rawConfig is Map) {
      final projectId = record.attributes['projectId'];
      if (projectId is! String) {
        throw StateError('GDevelop 历史资源清单无效');
      }
      try {
        projectConfigSnapshot = GDevelopHistoryProjectConfigSnapshot.ready(
          GDevelopProjectConfig.fromJson(
            Map<String, Object?>.from(rawConfig),
            expectedGameId: projectId,
          ),
        );
      } on FormatException {
        throw StateError('GDevelop 历史资源清单无效');
      }
    } else {
      throw StateError('GDevelop 历史资源清单无效');
    }
    return _GDevelopRevisionPayload(
      projectFilesReference: GDevelopProjectFilesReference(
        contentHash: projectFilesHash,
        size: projectFilesSize,
        files: List<GDevelopProjectFileReference>.unmodifiable(
          projectFiles.map((raw) {
            if (raw is! Map) {
              throw StateError('GDevelop 历史资源清单无效');
            }
            return GDevelopProjectFileReference.fromJson(
              Map<String, Object?>.from(raw),
            );
          }),
        ),
      ),
      resources: List.unmodifiable(
        resources.map((raw) {
          if (raw is! Map) throw StateError('GDevelop 历史资源清单无效');
          return GDevelopProjectResource.fromJson(
            Map<String, Object?>.from(raw),
          );
        }),
      ),
      projectConfigSnapshot: projectConfigSnapshot,
    );
  }

  Future<GDevelopProjectSnapshot> _snapshot(
    String projectId,
    LocalVersionStore store,
    LocalVersionRecord record,
  ) async {
    final payload = await _payload(store, record);
    await _verifyPayloadObjects(store, payload);
    final projectFiles = await _readProjectFilesReference(
      store,
      payload.projectFilesReference,
    );
    return GDevelopProjectSnapshot(
      version: _version(projectId, record),
      projectFiles: projectFiles,
      resources: payload.resources,
      projectConfigSnapshot: payload.projectConfigSnapshot,
    );
  }

  Future<_GDevelopDirectCurrentStore> _currentStore(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    final cached = _currentStores[normalized];
    if (cached != null) return cached;
    final projectRoot = await rootResolver.runInProjectRoot(
      normalized,
      (root) async => root,
    );
    return _currentStores[normalized] = _directCurrentStoreAtProjectRoot(
      projectRoot,
    );
  }

  Future<LocalVersionStore> _uploadStore(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    final cached = _uploadStores[normalized];
    if (cached != null) return cached;
    final projectRoot = await rootResolver.runInProjectRoot(
      normalized,
      (root) async => root,
    );
    return _uploadStores[normalized] = LocalVersionStore(
      root: _sourceUploadsRoot(projectRoot),
      retentionPolicy: retentionPolicy,
      clock: clock,
    );
  }

  _GDevelopDirectCurrentStore _directCurrentStoreAtProjectRoot(
    Directory projectRoot,
  ) => _GDevelopDirectCurrentStore(
    root: _sourceCurrentRoot(projectRoot),
    clock: clock,
    maxProjectFilesBytes: maxProjectFilesBytes,
    onBundleVerification: onCurrentBundleVerification,
    onProjectFileWritten: onCurrentProjectFileWritten,
  );

  Directory _sourceCurrentRoot(Directory projectRoot) => Directory(
    '${projectRoot.path}${Platform.pathSeparator}.playmesh'
    '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}source'
    '${Platform.pathSeparator}current',
  );

  Directory _sourceUploadsRoot(Directory projectRoot) => Directory(
    '${projectRoot.path}${Platform.pathSeparator}.playmesh'
    '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}source'
    '${Platform.pathSeparator}uploads',
  );

  Future<LocalVersionStore> _store(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    final cached = _stores[normalized];
    if (cached != null) return cached;
    _historicalProjectIds[normalized] = Set.unmodifiable(
      await rootResolver.historicalGameIds(normalized),
    );
    final projectRoot = await rootResolver.resolveHistoryRoot(normalized);
    return _stores[normalized] = LocalVersionStore(
      root: projectRoot,
      retentionPolicy: retentionPolicy,
      clock: clock,
    );
  }

  String _normalizeProjectId(String projectId) {
    final value = projectId.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
      throw const FormatException('GDevelop gameId 无效');
    }
    return value;
  }

  static const _namespace = 'gdevelop.history.v3';

  List<GDevelopProjectFile> _normalizeProjectFiles(
    List<GDevelopProjectFile> projectFiles,
  ) => gdevelopProjectFilesFromJson(
    projectFiles.map((file) => file.toJson()).toList(growable: false),
  );

  Future<GDevelopProjectFilesReference> _stageProjectFiles(
    LocalVersionStore store,
    List<GDevelopProjectFile> projectFiles,
  ) async {
    final staged = await store.stageObjects(
      projectFiles.map(
        (file) => encodeOfficialGDevelopProjectFileBytes(file.content),
      ),
    );
    return _projectFilesReferenceFromStaged(projectFiles, staged);
  }

  Future<GDevelopProjectFilesReference> _projectFilesReferenceFromStaged(
    List<GDevelopProjectFile> projectFiles,
    List<LocalCasObjectReference> staged,
  ) async {
    if (projectFiles.length != staged.length) {
      throw StateError('GDevelop 工程分片暂存结果不完整');
    }
    final references = <GDevelopProjectFileReference>[];
    var totalBytes = 0;
    for (var index = 0; index < projectFiles.length; index += 1) {
      final file = projectFiles[index];
      final object = staged[index];
      totalBytes += object.bytes;
      references.add(
        GDevelopProjectFileReference(
          path: file.path,
          contentHash: object.hash,
          size: object.bytes,
        ),
      );
    }
    if (totalBytes < 1 || totalBytes > maxProjectFilesBytes) {
      throw const FormatException('GDevelop 工程大小必须在 1 B 至 1 GiB 之间');
    }
    return GDevelopProjectFilesReference(
      contentHash: await hashGDevelopProjectFiles(projectFiles),
      size: totalBytes,
      files: List<GDevelopProjectFileReference>.unmodifiable(references),
    );
  }

  Map<String, Object?> _attributes({
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    GDevelopHistoryChangeSummary? changeSummary,
  }) => {
    'projectId': projectId,
    'reason': reason.wireName,
    'source': source.wireName,
    if (changeSummary != null) 'changeSummary': changeSummary.toJson(),
  };

  GDevelopHistoryChangeSummary _changeSummary(
    _GDevelopRevisionPayload? before,
    _GDevelopRevisionPayload after,
  ) {
    var added = 0;
    var modified = 0;
    var deleted = 0;

    void compare(
      Map<String, String> beforeHashes,
      Map<String, String> afterHashes,
    ) {
      for (final entry in afterHashes.entries) {
        final previousHash = beforeHashes[entry.key];
        if (previousHash == null) {
          added += 1;
        } else if (previousHash != entry.value) {
          modified += 1;
        }
      }
      for (final key in beforeHashes.keys) {
        if (!afterHashes.containsKey(key)) deleted += 1;
      }
    }

    compare(
      {
        for (final file
            in before?.projectFilesReference.files ??
                const <GDevelopProjectFileReference>[])
          file.path: file.contentHash,
      },
      {
        for (final file in after.projectFilesReference.files)
          file.path: file.contentHash,
      },
    );
    compare(
      {
        for (final resource
            in before?.resources ?? const <GDevelopProjectResource>[])
          resource.logicalId: resource.contentHash,
      },
      {
        for (final resource in after.resources)
          resource.logicalId: resource.contentHash,
      },
    );
    return GDevelopHistoryChangeSummary(
      added: added,
      modified: modified,
      deleted: deleted,
    );
  }

  LocalVersionDraft _withChangeSummary(
    LocalVersionDraft draft,
    GDevelopHistoryChangeSummary changeSummary,
  ) => LocalVersionDraft(
    content: draft.content,
    attributes: {...draft.attributes, 'changeSummary': changeSummary.toJson()},
    references: draft.references,
    deduplicateHistoryHead: draft.deduplicateHistoryHead,
  );

  GDevelopProjectVersion _version(String projectId, LocalVersionRecord record) {
    final historicalIds = _historicalProjectIds[projectId] ?? {projectId};
    if (!historicalIds.contains(record.attributes['projectId'])) {
      throw StateError('GDevelop 历史命名空间不匹配');
    }
    final rawChangeSummary = record.attributes['changeSummary'];
    if (rawChangeSummary != null && rawChangeSummary is! Map) {
      throw StateError('GDevelop 历史变更摘要无效');
    }
    late final GDevelopHistoryChangeSummary? changeSummary;
    try {
      changeSummary = rawChangeSummary == null
          ? null
          : GDevelopHistoryChangeSummary.fromJson(
              Map<String, Object?>.from(rawChangeSummary as Map),
            );
    } on FormatException {
      throw StateError('GDevelop 历史变更摘要无效');
    }
    return GDevelopProjectVersion(
      id: record.id,
      projectId: projectId,
      revision: record.revision,
      timestamp: record.timestamp,
      reason: GDevelopHistoryReason.parse(
        record.attributes['reason'] as String? ?? '',
      ),
      contentHash: record.contentHash,
      source: GDevelopHistorySource.parse(
        record.attributes['source'] as String? ?? '',
      ),
      contentBytes: record.contentBytes,
      changeSummary: changeSummary,
    );
  }
}

class _GDevelopDirectCurrentRevisionConflict implements Exception {
  const _GDevelopDirectCurrentRevisionConflict(this.currentRevision);

  final int currentRevision;
}

class _GDevelopDirectCurrentStore {
  _GDevelopDirectCurrentStore({
    required this.root,
    required this.clock,
    required this.maxProjectFilesBytes,
    this.onBundleVerification,
    this.onProjectFileWritten,
  });

  static const schemaVersion = 3;

  final Directory root;
  final DateTime Function() clock;
  final int maxProjectFilesBytes;
  final void Function()? onBundleVerification;
  final FutureOr<void> Function(File file)? onProjectFileWritten;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, Object?>?> readOpenCurrent() => _serialize(() async {
    await _recoverSwap();
    if (!await root.exists()) return null;
    final manifestValue = jsonDecode(
      await File(
        '${root.path}${Platform.pathSeparator}manifest.json',
      ).readAsString(),
    );
    final manifest = manifestValue is Map
        ? Map<String, Object?>.from(manifestValue)
        : const <String, Object?>{};
    final revision = manifest['revision'];
    final contentHash = manifest['contentHash'];
    final contentHashText = contentHash?.toString() ?? 'raw';
    final idSuffix = contentHashText.length <= 12
        ? contentHashText
        : contentHashText.substring(0, 12);
    final projectFiles = <Object?>[];
    final rawProjectFiles = manifest['projectFiles'];
    if (rawProjectFiles is List) {
      for (final raw in rawProjectFiles) {
        if (raw is! Map || raw['path'] is! String) continue;
        final path = raw['path']! as String;
        projectFiles.add({
          'path': path,
          'content': jsonDecode(await _projectFile(root, path).readAsString()),
        });
      }
    }
    return <String, Object?>{
      'version': <String, Object?>{
        'id': 'current-$revision-$idSuffix',
        'gameId': manifest['gameId'],
        'revision': revision,
        'timestamp': manifest['timestamp'],
        'reason': manifest['reason'],
        'contentHash': contentHash,
        'source': manifest['source'],
        'contentBytes': manifest['contentBytes'],
      },
      'projectFiles': projectFiles,
      'resources': manifest['resources'],
      if (manifest.containsKey('playmeshProjectConfig'))
        'playmeshProjectConfig': manifest['playmeshProjectConfig'],
      if (manifestValue is! Map) 'manifest': manifestValue,
    };
  });

  Future<Uint8List?> readOpenResource(String contentHash) =>
      _serialize(() async {
        final file = _resourceFile(
          root,
          LocalCasObjectReference(hash: contentHash, bytes: 1),
        );
        if (!await file.exists()) return null;
        return file.readAsBytes();
      });

  Future<GDevelopProjectSnapshot?> read(String projectId) =>
      _serialize(() async {
        final bundle = await _readBundle(root, expectedProjectId: projectId);
        if (bundle == null) return null;
        return GDevelopProjectSnapshot(
          version: bundle.version,
          projectFiles: bundle.projectFiles,
          resources: bundle.payload.resources,
          projectConfigSnapshot: bundle.payload.projectConfigSnapshot,
        );
      });

  Future<GDevelopProjectFilesReference?> projectFilesReference(
    String projectId,
  ) => _serialize(() async {
    final manifest = await _readManifest(root, expectedProjectId: projectId);
    return manifest?.payload.projectFilesReference;
  });

  Future<GDevelopProjectCurrentReferenceSnapshot?> referenceSnapshot(
    String projectId,
  ) => _serialize(() async {
    final manifest = await _readManifest(root, expectedProjectId: projectId);
    if (manifest == null) return null;
    return GDevelopProjectCurrentReferenceSnapshot(
      version: manifest.version,
      projectFiles: manifest.payload.projectFilesReference,
      resources: manifest.payload.resources,
      projectConfigSnapshot: manifest.payload.projectConfigSnapshot,
    );
  });

  Future<Set<String>> containedResourceHashes(
    Iterable<LocalCasObjectReference> references,
  ) => _serialize(() async {
    final normalized = references
        .map(
          (reference) => LocalCasObjectReference.fromJson(reference.toJson()),
        )
        .toList(growable: false);
    if (normalized.isEmpty) return const <String>{};
    final manifest = await _readManifest(root);
    if (manifest == null) return const <String>{};
    final currentResourceSizes = <String, int>{
      for (final resource in manifest.payload.resources)
        resource.contentHash: resource.size,
    };
    return Set<String>.unmodifiable(
      normalized
          .where(
            (reference) =>
                currentResourceSizes[reference.hash] == reference.bytes,
          )
          .map((reference) => reference.hash),
    );
  });

  Future<Uint8List> readResourceObject(
    LocalCasObjectReference reference,
  ) async {
    final resources = await readResourceObjects([reference]);
    return resources[reference.hash]!;
  }

  Future<Map<String, Uint8List>> readResourceObjects(
    Iterable<LocalCasObjectReference> references, {
    bool verifyContentHash = true,
  }) => _serialize(() async {
    final normalized = <String, LocalCasObjectReference>{};
    for (final reference in references) {
      final value = LocalCasObjectReference.fromJson(reference.toJson());
      final previous = normalized[value.hash];
      if (previous != null && previous.bytes != value.bytes) {
        throw const FormatException('同一 GDevelop 资源 hash 的 size 不一致');
      }
      normalized[value.hash] = value;
    }
    if (normalized.isEmpty) return const <String, Uint8List>{};
    final manifest = await _readManifest(root);
    if (manifest == null) {
      throw StateError('GDevelop current 资源不存在或未被引用');
    }
    final currentResourceSizes = <String, int>{
      for (final resource in manifest.payload.resources)
        resource.contentHash: resource.size,
    };
    final result = <String, Uint8List>{};
    for (final reference in normalized.values) {
      if (currentResourceSizes[reference.hash] != reference.bytes) {
        throw StateError('GDevelop current 资源不存在或未被引用');
      }
      final bytes = await _resourceFile(root, reference).readAsBytes();
      if (verifyContentHash &&
          (bytes.length != reference.bytes ||
              await _sha256Bytes(bytes) != reference.hash)) {
        throw StateError('GDevelop current 对象 hash 不一致');
      }
      result[reference.hash] = bytes;
    }
    return Map<String, Uint8List>.unmodifiable(result);
  });

  Future<GDevelopProjectCurrentReferenceSnapshot> commit({
    required String projectId,
    required int expectedRevision,
    required int revisionDelta,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> projectFiles,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    required Future<Uint8List> Function(LocalCasObjectReference reference)
    readResource,
  }) => _serialize(() async {
    if (expectedRevision < 0 || revisionDelta < 0 || revisionDelta > 1) {
      throw const FormatException('GDevelop current revision 参数无效');
    }
    await _recoverSwap();
    final before = await _readManifest(root, expectedProjectId: projectId);
    final currentRevision = before?.version.revision ?? 0;
    if (currentRevision != expectedRevision) {
      throw _GDevelopDirectCurrentRevisionConflict(currentRevision);
    }
    final projectFilesReference = await referenceGDevelopProjectFiles(
      projectFiles,
    );
    if (projectFilesReference.size < 1 ||
        projectFilesReference.size > maxProjectFilesBytes) {
      throw const FormatException('GDevelop current 工程大小无效');
    }
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: resources,
      projectConfigSnapshot: projectConfigSnapshot,
    );
    final payloadBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(payload.toJson())),
    );
    final contentHash = await _sha256Bytes(payloadBytes);
    final revision = before == null ? 1 : currentRevision + revisionDelta;
    final timestamp = clock().toUtc();
    final next = Directory(
      '${root.path}.next-${timestamp.microsecondsSinceEpoch}-${ProcessInfo.currentRss}',
    );
    if (await next.exists()) await next.delete(recursive: true);
    await Directory(
      '${next.path}${Platform.pathSeparator}project',
    ).create(recursive: true);
    try {
      Future<void> writeProjectFile(GDevelopProjectFile file) async {
        final destination = _projectFile(next, file.path);
        await destination.parent.create(recursive: true);
        final encoded = encodeOfficialGDevelopProjectFile(file.content);
        await destination.writeAsString(encoded, flush: true);
        await onProjectFileWritten?.call(destination);
        if (await destination.readAsString() != encoded) {
          throw StateError('GDevelop current 工程分片写入失败');
        }
      }

      final rootProjectFile = projectFiles.firstWhere(
        (file) => file.path == 'game.json',
      );
      await Future.wait(
        projectFiles
            .where((file) => file.path != 'game.json')
            .map(writeProjectFile),
      );
      await writeProjectFile(rootProjectFile);
      final written = <String>{};
      final reusedResources = <LocalCasObjectReference>[];
      for (final resource in resources) {
        final reference = LocalCasObjectReference(
          hash: resource.contentHash,
          bytes: resource.size,
        );
        if (!written.add(reference.hash)) continue;
        Uint8List bytes;
        final existedBefore =
            before != null &&
            before.payload.resources.any(
              (item) =>
                  item.contentHash == reference.hash &&
                  item.size == reference.bytes,
            );
        if (existedBefore) {
          reusedResources.add(reference);
          continue;
        }
        bytes = await readResource(reference);
        final destination = _resourceFile(next, reference);
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes, flush: true);
      }
      final manifest = <String, Object?>{
        'schemaVersion': schemaVersion,
        'gameId': projectId,
        'revision': revision,
        'timestamp': timestamp.toIso8601String(),
        'reason': reason.wireName,
        'source': source.wireName,
        'contentHash': contentHash,
        'contentBytes': payloadBytes.length,
        ...payload.toJson(),
      };
      await File(
        '${next.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString(jsonEncode(manifest), flush: true);
      String resourceKey(GDevelopProjectResource resource) =>
          '${resource.contentHash}:${resource.size}';
      final previousResourceKeys = before == null
          ? const <String>{}
          : before.payload.resources.map(resourceKey).toSet();
      final nextResourceKeys = resources.map(resourceKey).toSet();
      await _replaceCurrent(
        next,
        reusedResources: reusedResources,
        reuseWholeResourcesDirectory:
            before != null &&
            previousResourceKeys.length == nextResourceKeys.length &&
            previousResourceKeys.containsAll(nextResourceKeys),
      );
      final version = GDevelopProjectVersion(
        id: 'current-$revision-${contentHash.substring(0, 12)}',
        projectId: projectId,
        revision: revision,
        timestamp: timestamp,
        reason: reason,
        contentHash: contentHash,
        source: source,
        contentBytes: payloadBytes.length,
      );
      return GDevelopProjectCurrentReferenceSnapshot(
        version: version,
        projectFiles: projectFilesReference,
        resources: resources,
        projectConfigSnapshot: projectConfigSnapshot,
      );
    } on Object {
      if (await next.exists()) await next.delete(recursive: true);
      rethrow;
    }
  });

  Future<void> _replaceCurrent(
    Directory next, {
    required List<LocalCasObjectReference> reusedResources,
    required bool reuseWholeResourcesDirectory,
  }) async {
    await root.parent.create(recursive: true);
    final backup = Directory('${root.path}.backup');
    if (await backup.exists()) await backup.delete(recursive: true);
    if (reusedResources.isNotEmpty) {
      await _resourceReuseJournal(next).writeAsString(
        jsonEncode({
          'wholeDirectory': reuseWholeResourcesDirectory,
          'resources': reusedResources
              .map((reference) => reference.toJson())
              .toList(growable: false),
        }),
        flush: true,
      );
    }
    if (await root.exists()) await root.rename(backup.path);
    try {
      await next.rename(root.path);
    } on Object {
      if (await backup.exists()) {
        await backup.rename(root.path);
      }
      rethrow;
    }
    try {
      await _completeResourceReuse(root, backup);
    } on Object {
      await _rollbackActivatedCurrent(root, backup);
      rethrow;
    }
    if (await backup.exists()) {
      try {
        await backup.delete(recursive: true);
      } on FileSystemException {
        // current 已完整切换；遗留 backup 由下次访问恢复流程清理。
      }
    }
  }

  Future<void> _recoverSwap() async {
    await root.parent.create(recursive: true);
    final backup = Directory('${root.path}.backup');
    if (!await root.exists() && await backup.exists()) {
      await backup.rename(root.path);
      return;
    }
    if (await root.exists() && await backup.exists()) {
      await _completeResourceReuse(root, backup);
      await backup.delete(recursive: true);
    }
  }

  Future<void> _completeResourceReuse(
    Directory activated,
    Directory backup,
  ) async {
    final journal = _resourceReuseJournal(activated);
    if (!await journal.exists()) return;
    final decoded = jsonDecode(await journal.readAsString());
    if (decoded is! Map ||
        decoded['wholeDirectory'] is! bool ||
        decoded['resources'] is! List) {
      throw StateError('GDevelop current 资源复用日志无效');
    }
    final wholeDirectory = decoded['wholeDirectory']! as bool;
    final references = (decoded['resources']! as List)
        .map((raw) {
          if (raw is! Map) {
            throw StateError('GDevelop current 资源复用日志无效');
          }
          return LocalCasObjectReference.fromJson(
            Map<String, Object?>.from(raw),
          );
        })
        .toList(growable: false);
    final sourceDirectory = Directory(
      '${backup.path}${Platform.pathSeparator}resources',
    );
    final destinationDirectory = Directory(
      '${activated.path}${Platform.pathSeparator}resources',
    );
    if (wholeDirectory) {
      if (await sourceDirectory.exists()) {
        if (await destinationDirectory.exists()) {
          await destinationDirectory.delete(recursive: true);
        }
        await sourceDirectory.rename(destinationDirectory.path);
      } else if (!await destinationDirectory.exists()) {
        throw StateError('GDevelop current 复用资源目录不存在');
      }
    } else {
      await destinationDirectory.create(recursive: true);
      for (final reference in references) {
        final source = _resourceFile(backup, reference);
        final destination = _resourceFile(activated, reference);
        if (await destination.exists()) continue;
        if (!await source.exists()) {
          throw StateError('GDevelop current 复用资源不存在');
        }
        await source.rename(destination.path);
      }
    }
    await journal.delete();
  }

  Future<void> _rollbackActivatedCurrent(
    Directory activated,
    Directory backup,
  ) async {
    if (!await backup.exists()) return;
    final journal = _resourceReuseJournal(activated);
    if (await journal.exists()) {
      final decoded = jsonDecode(await journal.readAsString());
      if (decoded is Map && decoded['resources'] is List) {
        final wholeDirectory = decoded['wholeDirectory'] == true;
        if (wholeDirectory) {
          final sourceDirectory = Directory(
            '${activated.path}${Platform.pathSeparator}resources',
          );
          final destinationDirectory = Directory(
            '${backup.path}${Platform.pathSeparator}resources',
          );
          if (!await destinationDirectory.exists() &&
              await sourceDirectory.exists()) {
            await sourceDirectory.rename(destinationDirectory.path);
          }
        } else {
          for (final raw in decoded['resources']! as List) {
            if (raw is! Map) continue;
            final reference = LocalCasObjectReference.fromJson(
              Map<String, Object?>.from(raw),
            );
            final source = _resourceFile(activated, reference);
            final destination = _resourceFile(backup, reference);
            if (!await destination.exists() && await source.exists()) {
              await source.rename(destination.path);
            }
          }
        }
      }
    }
    if (await activated.exists()) await activated.delete(recursive: true);
    await backup.rename(root.path);
  }

  File _resourceReuseJournal(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}resource-reuse.json');

  /// Reads only the authoritative manifest metadata.
  ///
  /// Presence and commit conflict checks intentionally use this metadata-only
  /// path. Project writes retain GDevelop's write-then-read-string comparison;
  /// [_readBundle] is reserved for APIs that explicitly materialize a snapshot.
  Future<_GDevelopDirectCurrentManifest?> _readManifest(
    Directory directory, {
    String? expectedProjectId,
  }) async {
    await _recoverSwapIfCanonical(directory);
    if (!await directory.exists()) return null;
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    final projectDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}project',
    );
    if (!await manifestFile.exists() || !await projectDirectory.exists()) {
      throw StateError('GDevelop current 文件不完整');
    }
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) throw StateError('GDevelop current manifest 无效');
    final manifest = Map<String, Object?>.from(decoded);
    const fields = {
      'schemaVersion',
      'gameId',
      'revision',
      'timestamp',
      'reason',
      'source',
      'contentHash',
      'contentBytes',
      'projectFilesHash',
      'projectFilesSize',
      'projectFiles',
      'resources',
      'playmeshProjectConfig',
    };
    if (manifest.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(manifest.keys.toSet()).isNotEmpty ||
        manifest['schemaVersion'] != schemaVersion ||
        manifest['gameId'] is! String ||
        manifest['revision'] is! int ||
        (manifest['revision']! as int) < 1 ||
        manifest['timestamp'] is! String ||
        manifest['reason'] is! String ||
        manifest['source'] is! String ||
        manifest['contentHash'] is! String ||
        manifest['contentBytes'] is! int ||
        manifest['projectFilesHash'] is! String ||
        manifest['projectFilesSize'] is! int ||
        manifest['projectFiles'] is! List ||
        manifest['resources'] is! List) {
      throw StateError('GDevelop current manifest 无效');
    }
    final projectId = manifest['gameId']! as String;
    if (expectedProjectId != null && projectId != expectedProjectId) {
      throw StateError('GDevelop current gameId 不匹配');
    }
    final projectFilesReference = GDevelopProjectFilesReference.fromJson({
      'contentHash': manifest['projectFilesHash'],
      'size': manifest['projectFilesSize'],
      'files': manifest['projectFiles'],
    });
    if (projectFilesReference.size > maxProjectFilesBytes) {
      throw StateError('GDevelop current 工程过大');
    }
    final resources = List<GDevelopProjectResource>.unmodifiable(
      (manifest['resources']! as List).map((raw) {
        if (raw is! Map) throw StateError('GDevelop current 资源清单无效');
        return GDevelopProjectResource.fromJson(Map<String, Object?>.from(raw));
      }),
    );
    final resourcesByHash = <String, GDevelopProjectResource>{};
    for (final resource in resources) {
      final previous = resourcesByHash[resource.contentHash];
      if (previous != null && previous.size != resource.size) {
        throw StateError('GDevelop current 同一资源 hash 的 size 不一致');
      }
      resourcesByHash.putIfAbsent(resource.contentHash, () => resource);
    }
    final rawConfig = manifest['playmeshProjectConfig'];
    final configSnapshot = rawConfig == null
        ? const GDevelopHistoryProjectConfigSnapshot.missing()
        : rawConfig is Map
        ? GDevelopHistoryProjectConfigSnapshot.ready(
            GDevelopProjectConfig.fromJson(
              Map<String, Object?>.from(rawConfig),
              expectedGameId: projectId,
            ),
          )
        : throw StateError('GDevelop current project config 无效');
    final payload = _GDevelopRevisionPayload(
      projectFilesReference: projectFilesReference,
      resources: resources,
      projectConfigSnapshot: configSnapshot,
    );
    final contentReference = LocalCasObjectReference.fromJson({
      'hash': manifest['contentHash'],
      'bytes': manifest['contentBytes'],
    });
    final timestamp = DateTime.tryParse(manifest['timestamp']! as String);
    if (timestamp == null) throw StateError('GDevelop current 时间无效');
    final reason = GDevelopHistoryReason.parse(manifest['reason']! as String);
    final source = GDevelopHistorySource.parse(manifest['source']! as String);
    final revision = manifest['revision']! as int;
    return _GDevelopDirectCurrentManifest(
      version: GDevelopProjectVersion(
        id:
            'current-$revision-'
            '${contentReference.hash.substring(0, 12)}',
        projectId: projectId,
        revision: revision,
        timestamp: timestamp.toUtc(),
        reason: reason,
        contentHash: contentReference.hash,
        source: source,
        contentBytes: contentReference.bytes,
      ),
      payload: payload,
    );
  }

  /// Materializes and verifies a typed snapshot for explicit snapshot reads.
  Future<_GDevelopDirectCurrentBundle?> _readBundle(
    Directory directory, {
    String? expectedProjectId,
  }) async {
    final manifest = await _readManifest(
      directory,
      expectedProjectId: expectedProjectId,
    );
    if (manifest == null) return null;
    onBundleVerification?.call();
    final projectFiles = <GDevelopProjectFile>[];
    for (final reference in manifest.payload.projectFilesReference.files) {
      final projectFile = _projectFile(directory, reference.path);
      await _verifyFile(projectFile, _projectFileCasReference(reference));
      final projectDecoded = jsonDecode(
        utf8.decode(await projectFile.readAsBytes()),
      );
      if (projectDecoded is! Map) {
        throw StateError('GDevelop current 工程无效');
      }
      projectFiles.add(
        GDevelopProjectFile(
          path: reference.path,
          content: Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(projectDecoded),
          ),
        ),
      );
    }
    final computedProjectFilesReference = await referenceGDevelopProjectFiles(
      projectFiles,
    );
    if (computedProjectFilesReference.contentHash !=
            manifest.payload.projectFilesReference.contentHash ||
        computedProjectFilesReference.size !=
            manifest.payload.projectFilesReference.size) {
      throw StateError('GDevelop current 工程文件树与清单不一致');
    }
    final sorted = [...manifest.payload.resources]
      ..sort((left, right) => left.logicalId.compareTo(right.logicalId));
    if (jsonEncode(
          manifest.payload.resources.map((item) => item.toJson()).toList(),
        ) !=
        jsonEncode(sorted.map((item) => item.toJson()).toList())) {
      throw StateError('GDevelop current 资源清单非规范顺序');
    }
    for (final resource in manifest.payload.resources) {
      final reference = LocalCasObjectReference(
        hash: resource.contentHash,
        bytes: resource.size,
      );
      await _verifyFile(_resourceFile(directory, reference), reference);
    }
    final payloadBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(manifest.payload.toJson())),
    );
    final contentHash = await _sha256Bytes(payloadBytes);
    if (manifest.version.contentHash != contentHash ||
        manifest.version.contentBytes != payloadBytes.length) {
      throw StateError('GDevelop current 内容证据无效');
    }
    return _GDevelopDirectCurrentBundle(
      version: manifest.version,
      projectFiles: List<GDevelopProjectFile>.unmodifiable(projectFiles),
      payload: manifest.payload,
    );
  }

  Future<void> _recoverSwapIfCanonical(Directory directory) async {
    if (directory.absolute.path == root.absolute.path) await _recoverSwap();
  }

  File _resourceFile(Directory directory, LocalCasObjectReference reference) =>
      File(
        '${directory.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}${reference.hash}.blob',
      );

  File _projectFile(Directory directory, String path) => File(
    '${directory.path}${Platform.pathSeparator}project'
    '${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}',
  );

  Future<void> _verifyFile(File file, LocalCasObjectReference reference) async {
    if (!await file.exists() || await file.length() != reference.bytes) {
      throw StateError('GDevelop current 对象缺失或大小不一致');
    }
    if (await _sha256File(file) != reference.hash) {
      throw StateError('GDevelop current 对象 hash 不一致');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}

class _GDevelopDirectCurrentBundle {
  const _GDevelopDirectCurrentBundle({
    required this.version,
    required this.projectFiles,
    required this.payload,
  });

  final GDevelopProjectVersion version;
  final List<GDevelopProjectFile> projectFiles;
  final _GDevelopRevisionPayload payload;
}

class _GDevelopDirectCurrentManifest {
  const _GDevelopDirectCurrentManifest({
    required this.version,
    required this.payload,
  });

  final GDevelopProjectVersion version;
  final _GDevelopRevisionPayload payload;
}

LocalCasObjectReference _projectFileCasReference(
  GDevelopProjectFileReference reference,
) =>
    LocalCasObjectReference(hash: reference.contentHash, bytes: reference.size);

Future<String> _sha256Bytes(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<String> _sha256File(File file) async {
  final sink = Sha256().newHashSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  final digest = await sink.hash();
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

bool _isAllowedResourceMime(String mime) {
  final normalized = mime.trim().toLowerCase();
  if (normalized.length > 127 ||
      !RegExp(
        r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$',
      ).hasMatch(normalized)) {
    return false;
  }
  return const [
        'image/',
        'audio/',
        'video/',
        'font/',
        'model/',
      ].any(normalized.startsWith) ||
      const {
        'application/octet-stream',
        'application/json',
        'application/wasm',
        'text/plain',
      }.contains(normalized);
}

bool _isSafeLogicalId(String value) {
  if (value.startsWith('playmesh-local-resource://')) {
    final parsed = Uri.tryParse(value);
    return parsed != null &&
        parsed.scheme == 'playmesh-local-resource' &&
        parsed.pathSegments.every(
          (segment) => segment != '.' && segment != '..',
        );
  }
  if (value.startsWith('/') || value.contains('\\')) return false;
  final segments = value.split('/');
  return segments.isNotEmpty &&
      segments.every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

Object? _canonicalizeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) return value.map(_canonicalizeJson).toList();
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) {
        throw const FormatException('GDevelop 工程对象键必须是字符串');
      }
      return key;
    }).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalizeJson(value[key]),
    };
  }
  throw const FormatException('GDevelop 工程包含不可序列化值');
}

int _commonPrefixLength(List<String> left, List<String> right) {
  var index = 0;
  while (index < left.length &&
      index < right.length &&
      left[index] == right[index]) {
    index += 1;
  }
  return index;
}

int _commonSuffixLength(
  List<String> left,
  List<String> right,
  int commonPrefix,
) {
  var count = 0;
  while (left.length - count - 1 >= commonPrefix &&
      right.length - count - 1 >= commonPrefix &&
      left[left.length - count - 1] == right[right.length - count - 1]) {
    count += 1;
  }
  return count;
}
