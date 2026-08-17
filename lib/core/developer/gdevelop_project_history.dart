import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'foundation/local_version_store.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_root_resolver.dart';
import 'project_provisioning_service.dart';

enum GDevelopHistoryReason {
  explicitSave('explicit_save'),
  importantChange('important_change'),
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
  });

  final String id;
  final String projectId;
  final int revision;
  final DateTime timestamp;
  final GDevelopHistoryReason reason;
  final String contentHash;
  final GDevelopHistorySource source;
  final int contentBytes;

  Map<String, Object?> toJson() => {
    'id': id,
    'gameId': projectId,
    'revision': revision,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'reason': reason.wireName,
    'contentHash': contentHash,
    'source': source.wireName,
    'contentBytes': contentBytes,
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
    required this.project,
    required this.resources,
    this.projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  });

  final GDevelopProjectVersion version;
  final Map<String, Object?> project;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'version': version.toJson(),
    'project': project,
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

class GDevelopProjectReference {
  const GDevelopProjectReference({
    required this.contentHash,
    required this.size,
  });

  final String contentHash;
  final int size;

  Map<String, Object?> toJson() => {'contentHash': contentHash, 'size': size};

  factory GDevelopProjectReference.fromJson(Map<String, Object?> json) {
    final reference = LocalCasObjectReference.fromJson({
      'hash': json['contentHash'],
      'bytes': json['size'],
    });
    if (reference.bytes > GDevelopProjectHistoryAdapter.maxProjectBytes) {
      throw const FormatException('GDevelop 工程不能超过 1 GiB');
    }
    return GDevelopProjectReference(
      contentHash: reference.hash,
      size: reference.bytes,
    );
  }

  LocalCasObjectReference get casReference =>
      LocalCasObjectReference(hash: contentHash, bytes: size);
}

class GDevelopPreparedProjectState {
  const GDevelopPreparedProjectState({
    required this.project,
    required this.projectReference,
    required this.resources,
  });

  final Map<String, Object?> project;
  final GDevelopProjectReference projectReference;
  final List<GDevelopProjectResource> resources;
}

/// Lightweight authoritative current descriptor for recovery/CAS checks.
/// Unlike [GDevelopProjectSnapshot], this does not read or decode project JSON.
class GDevelopProjectCurrentReferenceSnapshot {
  const GDevelopProjectCurrentReferenceSnapshot({
    required this.version,
    required this.project,
    required this.resources,
    this.projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  });

  final GDevelopProjectVersion version;
  final GDevelopProjectReference project;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'revision': version.revision,
    'project': project.toJson(),
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
    required super.project,
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
    required this.projectReference,
    required this.resources,
    required this.projectConfigSnapshot,
  });

  final LocalCasObjectReference projectReference;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'schemaVersion':
        projectConfigSnapshot.semantics ==
            GDevelopHistoryProjectConfigSemantics.legacy
        ? 1
        : 2,
    'projectJsonHash': projectReference.hash,
    'projectJsonBytes': projectReference.bytes,
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
  }) : rootResolver = rootResolver ?? FileSystemGDevelopProjectRootResolver(),
       clock = clock ?? DateTime.now;

  static const capability = 'gdevelop.history.v2';
  static const maxProjectBytes = 1024 * 1024 * 1024;

  final GDevelopProjectRootResolver rootResolver;
  final LocalVersionRetentionPolicy retentionPolicy;
  final DateTime Function() clock;
  @visibleForTesting
  final void Function()? onCurrentBundleVerification;
  final Map<String, _GDevelopDirectCurrentStore> _currentStores = {};
  final Map<String, LocalVersionStore> _uploadStores = {};
  final Map<String, LocalVersionStore> _stores = {};
  final Map<String, Set<String>> _historicalProjectIds = {};
  final StreamController<GDevelopAuthoritativeProjectChange>
  _authoritativeChanges = StreamController.broadcast(sync: true);
  final Map<String, int> _authoritativeChangeSequences = {};

  Stream<GDevelopAuthoritativeProjectChange> get authoritativeChanges =>
      _authoritativeChanges.stream;

  /// 聚合 App 托管身份与轻量 current evidence，不读取完整工程 JSON。
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

  /// Returns the current files in the wire shape used by normal WebIDE open.
  ///
  /// This path deliberately does not validate persisted content. JSON decode
  /// is only required because the existing HTTP response embeds both files as
  /// JSON values. Mutation, restore and history APIs keep using the typed,
  /// fully verified methods below.
  Future<Map<String, Object?>?> openCurrent(String projectId) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).readOpenCurrent();
  }

  Future<GDevelopProjectReference?> currentProjectReference(
    String projectId,
  ) async {
    final normalized = _normalizeProjectId(projectId);
    return (await _currentStore(normalized)).projectReference(normalized);
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
      project: GDevelopProjectReference(
        contentHash: payload.projectReference.hash,
        size: payload.projectReference.bytes,
      ),
      resources: payload.resources,
      projectConfigSnapshot: payload.projectConfigSnapshot,
    );
  }

  Future<Map<String, Object?>> readHistoryProjectReference({
    required String projectId,
    required GDevelopProjectReference reference,
  }) async {
    final store = await _store(_normalizeProjectId(projectId));
    return _validateProjectReference(store, reference);
  }

  Future<GDevelopPreparedProjectState> prepareProjectState({
    required String projectId,
    required Map<String, Object?> project,
    required List<GDevelopProjectResource> resources,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final store = await _store(normalized);
    final canonical = Map<String, Object?>.from(
      _canonicalizeJson(project)! as Map,
    );
    final projectReference = await store.stageObject(_encodeProject(canonical));
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectReference: projectReference,
      resources: normalizedResources,
      projectConfigSnapshot:
          const GDevelopHistoryProjectConfigSnapshot.missing(),
    );
    await _verifyPayloadObjects(store, payload);
    return GDevelopPreparedProjectState(
      project: Map.unmodifiable(canonical),
      projectReference: GDevelopProjectReference(
        contentHash: projectReference.hash,
        size: projectReference.bytes,
      ),
      resources: normalizedResources,
    );
  }

  Future<String> revisionPayloadContentHash({
    required String projectId,
    required GDevelopProjectReference project,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalized = _normalizeProjectId(projectId);
    final normalizedConfig = _validateProjectConfigSnapshot(
      normalized,
      projectConfigSnapshot,
    );
    final payload = _GDevelopRevisionPayload(
      projectReference: project.casReference,
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

  /// Reads the original project JSON bytes without re-encoding them, so the
  /// advertised SHA-256 remains the exact content-addressed object identity.
  Future<Uint8List> readProjectBytes({
    required String projectId,
    required GDevelopProjectReference reference,
  }) async {
    final store = await _store(_normalizeProjectId(projectId));
    await _validateProjectReference(store, reference);
    return store.readObject(reference.casReference);
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
    required GDevelopProjectReference project,
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
    await _validateProjectReference(store, project);
    final currentStore = _directCurrentStoreAtProjectRoot(projectRoot);
    final current = await currentStore.referenceSnapshot(normalized);
    if (current != null) {
      _requireCurrentEvidence(
        current,
        project: project,
        resources: normalizedResources,
        projectConfigSnapshot: normalizedConfig,
      );
      return current;
    }
    final payload = _GDevelopRevisionPayload(
      projectReference: project.casReference,
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
      ),
      references: [
        project.casReference,
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
    final projectValue = await _validateProjectReference(store, project);
    final projectBytes = await store.readObject(project.casReference);
    final snapshot = await currentStore.commit(
      projectId: normalized,
      expectedRevision: 0,
      revisionDelta: 1,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      project: projectValue,
      exactProjectBytes: projectBytes,
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
    required GDevelopProjectReference project,
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
      project: project,
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
    required GDevelopProjectReference project,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) {
    final actual = {
      'project': snapshot.project.toJson(),
      'resources': snapshot.resources
          .map((resource) => resource.toJson())
          .toList(),
      'playmeshProjectConfig': snapshot.projectConfigSnapshot.payloadValue,
      'playmeshProjectConfigSemantics':
          snapshot.projectConfigSnapshot.semantics.wireName,
    };
    final expected = {
      'project': project.toJson(),
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
    required Map<String, Object?> project,
    required List<GDevelopProjectResource> resources,
    GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot =
        const GDevelopHistoryProjectConfigSnapshot.missing(),
  }) => _commitProject(
    projectId: projectId,
    baseRevision: baseRevision,
    reason: GDevelopHistoryReason.explicitSave,
    source: source,
    project: project,
    resources: resources,
    projectConfigSnapshot: projectConfigSnapshot,
    createHistory: false,
  );

  Future<GDevelopSnapshotResult> snapshot({
    required String projectId,
    required int baseRevision,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required Map<String, Object?> project,
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
      project: project,
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
    required Map<String, Object?> project,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    required bool createHistory,
  }) async {
    final normalized = _normalizeProjectId(projectId);
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
        project: Map<String, Object?>.from(_canonicalizeJson(project)! as Map),
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
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    bool deduplicateHistoryHead = true,
  }) async {
    final currentStore = await _currentStore(projectId);
    final materialized = await currentStore.read(projectId);
    if (materialized == null ||
        materialized.version.revision != current.version.revision ||
        materialized.projectConfigSnapshot.semantics !=
            current.projectConfigSnapshot.semantics) {
      throw StateError('GDevelop current 在历史写入前发生变化');
    }
    final historyStore = await _store(projectId);
    final projectReference = await historyStore.stageObject(
      _encodeProject(materialized.project),
    );
    final resourcesMissingFromHistory = <LocalCasObjectReference>[];
    for (final resource in materialized.resources) {
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
    );
    for (final reference in resourcesMissingFromHistory) {
      final staged = await historyStore.stageObject(
        currentResourceBytes[reference.hash]!,
      );
      if (staged.hash != reference.hash || staged.bytes != reference.bytes) {
        throw StateError('GDevelop current 资源写入历史时发生变化');
      }
    }
    final payload = _GDevelopRevisionPayload(
      projectReference: projectReference,
      resources: materialized.resources,
      projectConfigSnapshot: materialized.projectConfigSnapshot,
    );
    final draft = LocalVersionDraft(
      content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      attributes: _attributes(
        projectId: projectId,
        reason: reason,
        source: source,
      ),
      references: [
        projectReference,
        for (final resource in materialized.resources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
      ],
      deduplicateHistoryHead: deduplicateHistoryHead,
    );
    final head = await historyStore.current(_namespace);
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
    final before = jsonEncode(_canonicalizeJson(beforeSnapshot.project));
    final after = jsonEncode(_canonicalizeJson(afterSnapshot.project));
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
    required Map<String, Object?> currentProject,
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
    final currentDraft = await _draft(
      store: store,
      projectId: normalized,
      reason: GDevelopHistoryReason.beforeRestore,
      source: source,
      project: currentProject,
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
      currentDraft: currentDraft,
      restoredProjectConfigSnapshot: restoredProjectConfigSnapshot,
    );
  }

  /// 使用 PREPARE 阶段已校验的 CAS 引用恢复，避免在 durable journal 里复制大型工程 JSON。
  Future<GDevelopRestoreResult> restorePrepared({
    required String projectId,
    required int baseRevision,
    required int targetRevision,
    required GDevelopHistorySource source,
    required GDevelopProjectReference currentProject,
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
    await _validateProjectReference(store, currentProject);
    final currentDraft = await _draftPreparedReference(
      store: store,
      projectId: normalized,
      reason: GDevelopHistoryReason.beforeRestore,
      source: source,
      projectReference: currentProject,
      resources: currentResources,
      projectConfigSnapshot: currentProjectConfigSnapshot,
    );
    return _commitRestore(
      projectId: normalized,
      store: store,
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      source: source,
      currentDraft: currentDraft,
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
    required GDevelopHistoryProjectConfigSnapshot?
    restoredProjectConfigSnapshot,
  }) async {
    final target = await store.recordAtRevision(_namespace, targetRevision);
    final targetPayload = await _payload(store, target);
    await _verifyPayloadObjects(store, targetPayload);
    final targetProjectBytes = await store.readObject(
      targetPayload.projectReference,
    );
    final targetProjectValue = jsonDecode(utf8.decode(targetProjectBytes));
    if (targetProjectValue is! Map) {
      throw StateError('GDevelop 历史目标工程格式无效');
    }
    final restoredPayload = _GDevelopRevisionPayload(
      projectReference: targetPayload.projectReference,
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
        project: Map<String, Object?>.from(targetProjectValue),
        exactProjectBytes: targetProjectBytes,
        resources: targetPayload.resources,
        projectConfigSnapshot: restoredPayload.projectConfigSnapshot,
        readResource: (reference) => store.readObject(reference),
      );
      final historyHead = await store.current(_namespace);
      final result = await store.commit(
        namespace: _namespace,
        expectedRevision: historyHead?.revision ?? 0,
        current: restoredDraft,
        history: [currentDraft, restoredDraft],
      );
      final backup = result.created.length > 1 ? result.created.first : null;
      await _emitAuthoritativeChange(
        currentSnapshot,
        GDevelopAuthoritativeProjectChangeReason.restored,
      );
      return GDevelopRestoreResult(
        version: currentSnapshot.version,
        backupVersion: backup == null ? null : _version(projectId, backup),
        project: Map<String, Object?>.from(targetProjectValue),
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

  Future<LocalVersionDraft> _draft({
    required LocalVersionStore store,
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required Map<String, Object?> project,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    bool deduplicateHistoryHead = true,
  }) async {
    final projectBytes = _encodeProject(project);
    final projectReference = await store.stageObject(projectBytes);
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectReference: projectReference,
      resources: normalizedResources,
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        projectId,
        projectConfigSnapshot,
      ),
    );
    await _verifyPayloadObjects(store, payload);
    return LocalVersionDraft(
      content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      attributes: _attributes(
        projectId: projectId,
        reason: reason,
        source: source,
      ),
      references: [
        projectReference,
        for (final resource in normalizedResources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
      ],
      deduplicateHistoryHead: deduplicateHistoryHead,
    );
  }

  Future<LocalVersionDraft> _draftPreparedReference({
    required LocalVersionStore store,
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
    required GDevelopProjectReference projectReference,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
  }) async {
    final normalizedResources = _validateResources(resources);
    final payload = _GDevelopRevisionPayload(
      projectReference: projectReference.casReference,
      resources: normalizedResources,
      projectConfigSnapshot: _validateProjectConfigSnapshot(
        projectId,
        projectConfigSnapshot,
      ),
    );
    await _verifyPayloadObjects(store, payload);
    return LocalVersionDraft(
      content: Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson()))),
      attributes: _attributes(
        projectId: projectId,
        reason: reason,
        source: source,
      ),
      references: [
        projectReference.casReference,
        for (final resource in normalizedResources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
      ],
      deduplicateHistoryHead: false,
    );
  }

  Future<Map<String, Object?>> _validateProjectReference(
    LocalVersionStore store,
    GDevelopProjectReference reference,
  ) async {
    if (reference.size < 1 || reference.size > maxProjectBytes) {
      throw const FormatException('GDevelop 工程大小必须在 1 B 至 1 GiB 之间');
    }
    final bytes = await store.readObject(reference.casReference);
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const FormatException('GDevelop 工程必须是 UTF-8 JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('GDevelop 工程 JSON 根节点必须是对象');
    }
    return Map<String, Object?>.unmodifiable(
      Map<String, Object?>.from(decoded),
    );
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
      projectContentHash: snapshot.project.contentHash,
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
    await store.readObject(payload.projectReference);
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
    if (decoded is! Map ||
        (decoded['schemaVersion'] != 1 && decoded['schemaVersion'] != 2)) {
      throw StateError('GDevelop 历史资源清单无效');
    }
    final projectHash = decoded['projectJsonHash'];
    final projectBytes = decoded['projectJsonBytes'];
    final resources = decoded['resources'];
    if (projectHash is! String || projectBytes is! int || resources is! List) {
      throw StateError('GDevelop 历史资源清单无效');
    }
    late final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;
    if (decoded['schemaVersion'] == 1) {
      projectConfigSnapshot =
          const GDevelopHistoryProjectConfigSnapshot.legacy();
    } else {
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
    }
    return _GDevelopRevisionPayload(
      projectReference: LocalCasObjectReference(
        hash: projectHash,
        bytes: projectBytes,
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
    final projectBytes = await store.readObject(payload.projectReference);
    final decoded = jsonDecode(utf8.decode(projectBytes));
    if (decoded is! Map) throw StateError('GDevelop 历史工程格式无效');
    return GDevelopProjectSnapshot(
      version: _version(projectId, record),
      project: Map<String, Object?>.from(decoded),
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
    maxProjectBytes: maxProjectBytes,
    onBundleVerification: onCurrentBundleVerification,
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

  static const _namespace = 'gdevelop.history.v2';

  Uint8List _encodeProject(Map<String, Object?> project) {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_canonicalizeJson(project))),
    );
    if (bytes.length > maxProjectBytes) {
      throw const FormatException('GDevelop 工程不能超过 1 GiB');
    }
    return bytes;
  }

  Map<String, Object?> _attributes({
    required String projectId,
    required GDevelopHistoryReason reason,
    required GDevelopHistorySource source,
  }) => {
    'projectId': projectId,
    'reason': reason.wireName,
    'source': source.wireName,
  };

  GDevelopProjectVersion _version(String projectId, LocalVersionRecord record) {
    final historicalIds = _historicalProjectIds[projectId] ?? {projectId};
    if (!historicalIds.contains(record.attributes['projectId'])) {
      throw StateError('GDevelop 历史命名空间不匹配');
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
    required this.maxProjectBytes,
    this.onBundleVerification,
  });

  static const schemaVersion = 2;

  final Directory root;
  final DateTime Function() clock;
  final int maxProjectBytes;
  final void Function()? onBundleVerification;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, Object?>?> readOpenCurrent() => _serialize(() async {
    await _recoverSwap();
    if (!await root.exists()) return null;
    final manifestValue = jsonDecode(
      await File(
        '${root.path}${Platform.pathSeparator}manifest.json',
      ).readAsString(),
    );
    final projectValue = jsonDecode(await _projectFile(root).readAsString());
    final manifest = manifestValue is Map
        ? Map<String, Object?>.from(manifestValue)
        : const <String, Object?>{};
    final revision = manifest['revision'];
    final contentHash = manifest['contentHash'];
    final contentHashText = contentHash?.toString() ?? 'raw';
    final idSuffix = contentHashText.length <= 12
        ? contentHashText
        : contentHashText.substring(0, 12);
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
      'project': projectValue,
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
          project: bundle.project,
          resources: bundle.payload.resources,
          projectConfigSnapshot: bundle.payload.projectConfigSnapshot,
        );
      });

  Future<GDevelopProjectReference?> projectReference(String projectId) =>
      _serialize(() async {
        final bundle = await _readBundle(root, expectedProjectId: projectId);
        if (bundle == null) return null;
        return GDevelopProjectReference(
          contentHash: bundle.payload.projectReference.hash,
          size: bundle.payload.projectReference.bytes,
        );
      });

  Future<GDevelopProjectCurrentReferenceSnapshot?> referenceSnapshot(
    String projectId,
  ) => _serialize(() async {
    final bundle = await _readBundle(root, expectedProjectId: projectId);
    if (bundle == null) return null;
    return GDevelopProjectCurrentReferenceSnapshot(
      version: bundle.version,
      project: GDevelopProjectReference(
        contentHash: bundle.payload.projectReference.hash,
        size: bundle.payload.projectReference.bytes,
      ),
      resources: bundle.payload.resources,
      projectConfigSnapshot: bundle.payload.projectConfigSnapshot,
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
    final bundle = await _readBundle(root);
    if (bundle == null) return const <String>{};
    final currentResourceSizes = <String, int>{
      for (final resource in bundle.payload.resources)
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
    Iterable<LocalCasObjectReference> references,
  ) => _serialize(() async {
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
    final bundle = await _readBundle(root);
    if (bundle == null) {
      throw StateError('GDevelop current 资源不存在或未被引用');
    }
    final currentResourceSizes = <String, int>{
      for (final resource in bundle.payload.resources)
        resource.contentHash: resource.size,
    };
    final result = <String, Uint8List>{};
    for (final reference in normalized.values) {
      if (currentResourceSizes[reference.hash] != reference.bytes) {
        throw StateError('GDevelop current 资源不存在或未被引用');
      }
      final bytes = await _resourceFile(root, reference).readAsBytes();
      if (bytes.length != reference.bytes ||
          await _sha256Bytes(bytes) != reference.hash) {
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
    required Map<String, Object?> project,
    Uint8List? exactProjectBytes,
    required List<GDevelopProjectResource> resources,
    required GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot,
    required Future<Uint8List> Function(LocalCasObjectReference reference)
    readResource,
  }) => _serialize(() async {
    if (expectedRevision < 0 || revisionDelta < 0 || revisionDelta > 1) {
      throw const FormatException('GDevelop current revision 参数无效');
    }
    await _recoverSwap();
    final before = await _readBundle(root, expectedProjectId: projectId);
    final currentRevision = before?.version.revision ?? 0;
    if (currentRevision != expectedRevision) {
      throw _GDevelopDirectCurrentRevisionConflict(currentRevision);
    }
    final projectBytes = exactProjectBytes == null
        ? Uint8List.fromList(
            utf8.encode(jsonEncode(_canonicalizeJson(project))),
          )
        : Uint8List.fromList(exactProjectBytes);
    if (projectBytes.isEmpty || projectBytes.length > maxProjectBytes) {
      throw const FormatException('GDevelop current 工程大小无效');
    }
    final exactDecoded = jsonDecode(utf8.decode(projectBytes));
    if (exactDecoded is! Map ||
        jsonEncode(_canonicalizeJson(exactDecoded)) !=
            jsonEncode(_canonicalizeJson(project))) {
      throw StateError('GDevelop current 工程字节与解析结果不一致');
    }
    final projectReference = LocalCasObjectReference(
      hash: await _sha256Bytes(projectBytes),
      bytes: projectBytes.length,
    );
    final payload = _GDevelopRevisionPayload(
      projectReference: projectReference,
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
      '${next.path}${Platform.pathSeparator}resources',
    ).create(recursive: true);
    try {
      await File(
        '${next.path}${Platform.pathSeparator}project.json',
      ).writeAsBytes(projectBytes, flush: true);
      final written = <String>{};
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
          final existing = _resourceFile(root, reference);
          await _verifyFile(existing, reference);
          bytes = await existing.readAsBytes();
        } else {
          bytes = await readResource(reference);
        }
        if (bytes.length != reference.bytes ||
            await _sha256Bytes(bytes) != reference.hash) {
          throw StateError('GDevelop current 资源内容与清单不一致');
        }
        await _resourceFile(next, reference).writeAsBytes(bytes, flush: true);
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
      final verified = await _readBundle(next, expectedProjectId: projectId);
      if (verified == null ||
          verified.version.revision != revision ||
          verified.version.contentHash != contentHash) {
        throw StateError('GDevelop current staging 验证失败');
      }
      await _replaceCurrent(next);
      return GDevelopProjectCurrentReferenceSnapshot(
        version: verified.version,
        project: GDevelopProjectReference(
          contentHash: verified.payload.projectReference.hash,
          size: verified.payload.projectReference.bytes,
        ),
        resources: verified.payload.resources,
        projectConfigSnapshot: verified.payload.projectConfigSnapshot,
      );
    } on Object {
      if (await next.exists()) await next.delete(recursive: true);
      rethrow;
    }
  });

  Future<void> _replaceCurrent(Directory next) async {
    await root.parent.create(recursive: true);
    final backup = Directory('${root.path}.backup');
    if (await backup.exists()) await backup.delete(recursive: true);
    if (await root.exists()) await root.rename(backup.path);
    try {
      await next.rename(root.path);
      if (await backup.exists()) await backup.delete(recursive: true);
    } on Object {
      if (!await root.exists() && await backup.exists()) {
        await backup.rename(root.path);
      }
      rethrow;
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
      await backup.delete(recursive: true);
    }
  }

  /// Reads only the authoritative manifest metadata.
  ///
  /// This is the read/open path. It intentionally does not hash project or
  /// resource contents and does not scan resource files. Normal opening leaves
  /// the stored bytes to GDevelop; every write/commit path uses [_readBundle]
  /// below and retains full fail-closed content validation.
  Future<_GDevelopDirectCurrentManifest?> _readManifest(
    Directory directory, {
    String? expectedProjectId,
  }) async {
    await _recoverSwapIfCanonical(directory);
    if (!await directory.exists()) return null;
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    final projectFile = _projectFile(directory);
    if (!await manifestFile.exists() || !await projectFile.exists()) {
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
      'projectJsonHash',
      'projectJsonBytes',
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
        manifest['projectJsonHash'] is! String ||
        manifest['projectJsonBytes'] is! int ||
        manifest['resources'] is! List) {
      throw StateError('GDevelop current manifest 无效');
    }
    final projectId = manifest['gameId']! as String;
    if (expectedProjectId != null && projectId != expectedProjectId) {
      throw StateError('GDevelop current gameId 不匹配');
    }
    final projectReference = LocalCasObjectReference.fromJson({
      'hash': manifest['projectJsonHash'],
      'bytes': manifest['projectJsonBytes'],
    });
    if (projectReference.bytes > maxProjectBytes) {
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
      projectReference: projectReference,
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

  /// Full content verification used exclusively by mutation/commit paths.
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
    final projectFile = _projectFile(directory);
    await _verifyFile(projectFile, manifest.payload.projectReference);
    final projectDecoded = jsonDecode(
      utf8.decode(await projectFile.readAsBytes()),
    );
    if (projectDecoded is! Map) throw StateError('GDevelop current 工程无效');
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
      project: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(projectDecoded),
      ),
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

  File _projectFile(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}project.json');

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
    required this.project,
    required this.payload,
  });

  final GDevelopProjectVersion version;
  final Map<String, Object?> project;
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
