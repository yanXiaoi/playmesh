import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'foundation/gdevelop_project_mutation_lock.dart';
import 'foundation/pending_project_commit_store.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_config_controller.dart';
import 'gdevelop_project_files.dart';
import 'gdevelop_project_history.dart';
import 'gdevelop_project_root_resolver.dart';
import 'project_provisioning_service.dart';

enum GDevelopRestoreCrashPoint {
  afterPrepared,
  afterCommitRequested,
  afterHistoryMutation,
  afterHistoryApplied,
  afterConfigMutation,
  afterBackendCommitted,
  afterReceipt,
  afterEvent,
}

typedef GDevelopRestoreCrashHook =
    FutureOr<void> Function(GDevelopRestoreCrashPoint point, String txId);

typedef GDevelopRestoreEventSink =
    FutureOr<void> Function(Map<String, Object?> event);

typedef GDevelopProjectMutationGuard = Future<void> Function(String gameId);

bool _sameStringLists(List<String>? left, List<String>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class GDevelopRestoreAckMismatch implements Exception {
  const GDevelopRestoreAckMismatch();

  static const code = 'gdevelop_restore_ack_mismatch';
}

class GDevelopRestoreTargetSnapshotMismatch implements Exception {
  const GDevelopRestoreTargetSnapshotMismatch();

  static const code = 'gdevelop_restore_target_snapshot_mismatch';
}

class GDevelopRestoreTransactionUnavailable implements Exception {
  const GDevelopRestoreTransactionUnavailable(this.phase);

  static const code = 'gdevelop_restore_transaction_unavailable';

  final PendingProjectCommitPhase phase;
}

class GDevelopRestoreHistoryEvidence {
  const GDevelopRestoreHistoryEvidence({
    required this.revision,
    required this.currentContentHash,
    required this.projectFilesHash,
    required this.resourceManifestHash,
  });

  final int revision;
  final String currentContentHash;
  final String projectFilesHash;
  final String resourceManifestHash;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'currentContentHash': currentContentHash,
    'projectFilesHash': projectFilesHash,
    'resourceManifestHash': resourceManifestHash,
  };

  bool matches(GDevelopRestoreHistoryEvidence other) =>
      revision == other.revision &&
      currentContentHash == other.currentContentHash &&
      projectFilesHash == other.projectFilesHash &&
      resourceManifestHash == other.resourceManifestHash;

  factory GDevelopRestoreHistoryEvidence.fromJson(Object? value) {
    final json = _strictMap(value, 'restore history evidence');
    _requireExactFields(json, const {
      'revision',
      'currentContentHash',
      'projectFilesHash',
      'resourceManifestHash',
    });
    final revision = json['revision'];
    final currentContentHash = json['currentContentHash'];
    final projectFilesHash = json['projectFilesHash'];
    final resourceManifestHash = json['resourceManifestHash'];
    if (revision is! int ||
        revision < 1 ||
        !_isHash(currentContentHash) ||
        !_isHash(projectFilesHash) ||
        !_isHash(resourceManifestHash)) {
      throw const FormatException('GDevelop restore history evidence 无效');
    }
    return GDevelopRestoreHistoryEvidence(
      revision: revision,
      currentContentHash: currentContentHash! as String,
      projectFilesHash: projectFilesHash! as String,
      resourceManifestHash: resourceManifestHash! as String,
    );
  }
}

class GDevelopRestoreConfigEvidence {
  const GDevelopRestoreConfigEvidence({
    required this.semantics,
    required this.sidecar,
  });

  final GDevelopHistoryProjectConfigSemantics semantics;
  final GDevelopProjectConfigEvidence sidecar;

  GDevelopHistoryProjectConfigSnapshot get historySnapshot =>
      switch (semantics) {
        GDevelopHistoryProjectConfigSemantics.ready =>
          GDevelopHistoryProjectConfigSnapshot.ready(sidecar.config!),
        GDevelopHistoryProjectConfigSemantics.missing =>
          const GDevelopHistoryProjectConfigSnapshot.missing(),
        GDevelopHistoryProjectConfigSemantics.legacy =>
          const GDevelopHistoryProjectConfigSnapshot.legacy(),
      };

  Map<String, Object?> toJson() => {
    'semantics': semantics.wireName,
    ...sidecar.toJson(),
  };

  factory GDevelopRestoreConfigEvidence.fromJson(
    Object? value, {
    required String gameId,
  }) {
    final json = _strictMap(value, 'restore config evidence');
    final semanticsValue = json.remove('semantics');
    if (semanticsValue is! String) {
      throw const FormatException('GDevelop restore config semantics 无效');
    }
    final semantics = GDevelopHistoryProjectConfigSemantics.values.firstWhere(
      (item) => item.wireName == semanticsValue,
      orElse: () =>
          throw const FormatException('GDevelop restore config semantics 无效'),
    );
    final sidecar = _configEvidenceFromJson(json, gameId: gameId);
    if (sidecar.status == GDevelopProjectConfigStatus.invalid ||
        (semantics == GDevelopHistoryProjectConfigSemantics.ready &&
            sidecar.status != GDevelopProjectConfigStatus.ready) ||
        (semantics == GDevelopHistoryProjectConfigSemantics.missing &&
            sidecar.status != GDevelopProjectConfigStatus.missing)) {
      throw const FormatException('GDevelop restore config evidence 无效');
    }
    return GDevelopRestoreConfigEvidence(
      semantics: semantics,
      sidecar: sidecar,
    );
  }
}

class GDevelopRestoreProjectEvidence {
  const GDevelopRestoreProjectEvidence({
    required this.history,
    required this.config,
  });

  final GDevelopRestoreHistoryEvidence history;
  final GDevelopRestoreConfigEvidence config;

  Map<String, Object?> toJson() => {
    'history': history.toJson(),
    'config': config.toJson(),
  };

  factory GDevelopRestoreProjectEvidence.fromJson(
    Object? value, {
    required String gameId,
  }) {
    final json = _strictMap(value, 'restore project evidence');
    _requireExactFields(json, const {'history', 'config'});
    return GDevelopRestoreProjectEvidence(
      history: GDevelopRestoreHistoryEvidence.fromJson(json['history']),
      config: GDevelopRestoreConfigEvidence.fromJson(
        json['config'],
        gameId: gameId,
      ),
    );
  }
}

class GDevelopRestoreBrowserEvidence {
  const GDevelopRestoreBrowserEvidence({
    required this.projectFilesHash,
    required this.resourceManifestHash,
  });

  final String projectFilesHash;
  final String resourceManifestHash;

  Map<String, Object?> toJson() => {
    'projectFilesHash': projectFilesHash,
    'resourceManifestHash': resourceManifestHash,
  };

  factory GDevelopRestoreBrowserEvidence.fromJson(Object? value) {
    final json = _strictMap(value, 'restore browser evidence');
    _requireExactFields(json, const {
      'projectFilesHash',
      'resourceManifestHash',
    });
    if (!_isHash(json['projectFilesHash']) ||
        !_isHash(json['resourceManifestHash'])) {
      throw const FormatException('GDevelop restore browser evidence 无效');
    }
    return GDevelopRestoreBrowserEvidence(
      projectFilesHash: json['projectFilesHash']! as String,
      resourceManifestHash: json['resourceManifestHash']! as String,
    );
  }
}

/// PREPARE 阶段供浏览器校验和落 durable journal 的不可变目标快照。
class GDevelopRestoreTargetSnapshot {
  const GDevelopRestoreTargetSnapshot({
    required this.sourceVersion,
    required this.projectFilesReference,
    required this.projectFiles,
    required this.resources,
    required this.projectConfigSnapshot,
  });

  final GDevelopProjectVersion sourceVersion;
  final List<GDevelopProjectFileReference> projectFilesReference;
  final List<GDevelopProjectFile> projectFiles;
  final List<GDevelopProjectResource> resources;
  final GDevelopHistoryProjectConfigSnapshot projectConfigSnapshot;

  Map<String, Object?> toJson() => {
    'sourceVersion': sourceVersion.toJson(),
    'projectFilesReference': projectFilesReference
        .map((reference) => reference.toJson())
        .toList(growable: false),
    'projectFiles': projectFiles
        .map((file) => file.toJson())
        .toList(growable: false),
    'resources': resources.map((resource) => resource.toJson()).toList(),
    if (projectConfigSnapshot.semantics !=
        GDevelopHistoryProjectConfigSemantics.legacy)
      'playmeshProjectConfig': projectConfigSnapshot.payloadValue,
  };
}

class GDevelopRestoreTransactionPayload {
  const GDevelopRestoreTransactionPayload({
    required this.gameId,
    required this.baseRevision,
    required this.targetRevision,
    required this.source,
    required this.clientId,
    required this.currentProjectFilesReference,
    required this.currentResources,
    required this.targetProjectFilesReference,
    required this.targetResources,
    this.sourceVersion,
    required this.oldEvidence,
    required this.targetEvidence,
    required this.eventEmitted,
    this.restoredVersion,
    this.backupVersion,
    this.browserEvidence,
    this.eventTimestamp,
    this.conflict,
  });

  static const schemaVersion = 3;

  final String gameId;
  final int baseRevision;
  final int targetRevision;
  final GDevelopHistorySource source;
  final String? clientId;
  final GDevelopProjectFilesReference currentProjectFilesReference;
  final List<GDevelopProjectResource> currentResources;
  final GDevelopProjectFilesReference targetProjectFilesReference;
  final List<GDevelopProjectResource> targetResources;
  final GDevelopProjectVersion? sourceVersion;
  final GDevelopRestoreProjectEvidence oldEvidence;
  final GDevelopRestoreProjectEvidence targetEvidence;
  final GDevelopProjectVersion? restoredVersion;
  final GDevelopProjectVersion? backupVersion;
  final GDevelopRestoreBrowserEvidence? browserEvidence;
  final DateTime? eventTimestamp;
  final bool eventEmitted;
  final Map<String, Object?>? conflict;

  GDevelopRestoreTransactionPayload withRestored({
    required GDevelopProjectVersion restoredVersion,
    required GDevelopProjectVersion? backupVersion,
  }) => GDevelopRestoreTransactionPayload(
    gameId: gameId,
    baseRevision: baseRevision,
    targetRevision: targetRevision,
    source: source,
    clientId: clientId,
    currentProjectFilesReference: currentProjectFilesReference,
    currentResources: currentResources,
    targetProjectFilesReference: targetProjectFilesReference,
    targetResources: targetResources,
    sourceVersion: sourceVersion,
    oldEvidence: oldEvidence,
    targetEvidence: targetEvidence,
    restoredVersion: restoredVersion,
    backupVersion: backupVersion,
    browserEvidence: browserEvidence,
    eventTimestamp: eventTimestamp,
    eventEmitted: eventEmitted,
    conflict: conflict,
  );

  GDevelopRestoreTransactionPayload withConflict(Map<String, Object?> value) =>
      GDevelopRestoreTransactionPayload(
        gameId: gameId,
        baseRevision: baseRevision,
        targetRevision: targetRevision,
        source: source,
        clientId: clientId,
        currentProjectFilesReference: currentProjectFilesReference,
        currentResources: currentResources,
        targetProjectFilesReference: targetProjectFilesReference,
        targetResources: targetResources,
        sourceVersion: sourceVersion,
        oldEvidence: oldEvidence,
        targetEvidence: targetEvidence,
        restoredVersion: restoredVersion,
        backupVersion: backupVersion,
        browserEvidence: browserEvidence,
        eventTimestamp: eventTimestamp,
        eventEmitted: eventEmitted,
        conflict: Map.unmodifiable(value),
      );

  GDevelopRestoreTransactionPayload withBrowserEvidence({
    required GDevelopRestoreBrowserEvidence evidence,
    required DateTime timestamp,
  }) => GDevelopRestoreTransactionPayload(
    gameId: gameId,
    baseRevision: baseRevision,
    targetRevision: targetRevision,
    source: source,
    clientId: clientId,
    currentProjectFilesReference: currentProjectFilesReference,
    currentResources: currentResources,
    targetProjectFilesReference: targetProjectFilesReference,
    targetResources: targetResources,
    sourceVersion: sourceVersion,
    oldEvidence: oldEvidence,
    targetEvidence: targetEvidence,
    restoredVersion: restoredVersion,
    backupVersion: backupVersion,
    browserEvidence: evidence,
    eventTimestamp: timestamp.toUtc(),
    eventEmitted: false,
    conflict: conflict,
  );

  GDevelopRestoreTransactionPayload markEventEmitted() =>
      GDevelopRestoreTransactionPayload(
        gameId: gameId,
        baseRevision: baseRevision,
        targetRevision: targetRevision,
        source: source,
        clientId: clientId,
        currentProjectFilesReference: currentProjectFilesReference,
        currentResources: currentResources,
        targetProjectFilesReference: targetProjectFilesReference,
        targetResources: targetResources,
        sourceVersion: sourceVersion,
        oldEvidence: oldEvidence,
        targetEvidence: targetEvidence,
        restoredVersion: restoredVersion,
        backupVersion: backupVersion,
        browserEvidence: browserEvidence,
        eventTimestamp: eventTimestamp,
        eventEmitted: true,
        conflict: conflict,
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'gameId': gameId,
    'baseRevision': baseRevision,
    'targetRevision': targetRevision,
    'source': source.wireName,
    if (clientId != null) 'clientId': clientId,
    'currentProjectFilesReference': currentProjectFilesReference.toJson(),
    'currentResources': currentResources
        .map((resource) => resource.toJson())
        .toList(),
    'targetProjectFilesReference': targetProjectFilesReference.toJson(),
    'targetResources': targetResources
        .map((resource) => resource.toJson())
        .toList(),
    if (sourceVersion != null) 'sourceVersion': sourceVersion!.toJson(),
    'oldEvidence': oldEvidence.toJson(),
    'targetEvidence': targetEvidence.toJson(),
    if (restoredVersion != null) 'restoredVersion': restoredVersion!.toJson(),
    if (backupVersion != null) 'backupVersion': backupVersion!.toJson(),
    if (browserEvidence != null) 'browserEvidence': browserEvidence!.toJson(),
    if (eventTimestamp != null)
      'eventTimestamp': eventTimestamp!.toUtc().toIso8601String(),
    'eventEmitted': eventEmitted,
    if (conflict != null) 'conflict': conflict,
  };

  factory GDevelopRestoreTransactionPayload.fromJson(Object? value) {
    final json = _strictMap(value, 'restore transaction payload');
    const required = {
      'schemaVersion',
      'gameId',
      'baseRevision',
      'targetRevision',
      'source',
      'currentProjectFilesReference',
      'currentResources',
      'targetProjectFilesReference',
      'targetResources',
      'oldEvidence',
      'targetEvidence',
      'eventEmitted',
    };
    const optional = {
      'clientId',
      'sourceVersion',
      'restoredVersion',
      'backupVersion',
      'browserEvidence',
      'eventTimestamp',
      'conflict',
    };
    if (!json.keys.every(
          (key) => required.contains(key) || optional.contains(key),
        ) ||
        !required.every(json.containsKey) ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException(
        'GDevelop restore transaction payload schema 无效',
      );
    }
    final gameIdValue = json['gameId'];
    final baseRevision = json['baseRevision'];
    final targetRevision = json['targetRevision'];
    final sourceValue = json['source'];
    final clientIdValue = json['clientId'];
    final currentResourcesValue = json['currentResources'];
    final targetResourcesValue = json['targetResources'];
    final eventEmitted = json['eventEmitted'];
    if (gameIdValue is! String ||
        baseRevision is! int ||
        baseRevision < 1 ||
        targetRevision is! int ||
        targetRevision < 1 ||
        sourceValue is! String ||
        (clientIdValue != null && clientIdValue is! String) ||
        currentResourcesValue is! List ||
        targetResourcesValue is! List ||
        eventEmitted is! bool) {
      throw const FormatException('GDevelop restore transaction payload 无效');
    }
    final gameId = ProjectProvisioningService.validateGameId(gameIdValue);
    final clientId = _optionalClientId(clientIdValue as String?);
    final eventTimestamp = json['eventTimestamp'] == null
        ? null
        : DateTime.tryParse(json['eventTimestamp'] as String? ?? '')?.toUtc();
    if (json.containsKey('eventTimestamp') && eventTimestamp == null) {
      throw const FormatException('GDevelop restore eventTimestamp 无效');
    }
    final conflictValue = json['conflict'];
    if (conflictValue != null && conflictValue is! Map) {
      throw const FormatException('GDevelop restore conflict evidence 无效');
    }
    final payload = GDevelopRestoreTransactionPayload(
      gameId: gameId,
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      source: GDevelopHistorySource.parse(sourceValue),
      clientId: clientId,
      currentProjectFilesReference: GDevelopProjectFilesReference.fromJson(
        _strictMap(
          json['currentProjectFilesReference'],
          'current project files reference',
        ),
      ),
      currentResources: _resourceList(currentResourcesValue),
      targetProjectFilesReference: GDevelopProjectFilesReference.fromJson(
        _strictMap(
          json['targetProjectFilesReference'],
          'target project files reference',
        ),
      ),
      targetResources: _resourceList(targetResourcesValue),
      sourceVersion: json['sourceVersion'] == null
          ? null
          : _versionFromJson(json['sourceVersion'], gameId: gameId),
      oldEvidence: GDevelopRestoreProjectEvidence.fromJson(
        json['oldEvidence'],
        gameId: gameId,
      ),
      targetEvidence: GDevelopRestoreProjectEvidence.fromJson(
        json['targetEvidence'],
        gameId: gameId,
      ),
      restoredVersion: json['restoredVersion'] == null
          ? null
          : _versionFromJson(json['restoredVersion'], gameId: gameId),
      backupVersion: json['backupVersion'] == null
          ? null
          : _versionFromJson(json['backupVersion'], gameId: gameId),
      browserEvidence: json['browserEvidence'] == null
          ? null
          : GDevelopRestoreBrowserEvidence.fromJson(json['browserEvidence']),
      eventTimestamp: eventTimestamp,
      eventEmitted: eventEmitted,
      conflict: conflictValue == null
          ? null
          : Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(conflictValue as Map),
            ),
    );
    if (payload.oldEvidence.history.revision != baseRevision ||
        payload.targetEvidence.history.revision != baseRevision + 1 ||
        (payload.sourceVersion != null &&
            payload.sourceVersion!.revision != targetRevision) ||
        (payload.restoredVersion != null &&
            payload.restoredVersion!.revision != baseRevision + 1) ||
        payload.eventEmitted && payload.eventTimestamp == null) {
      throw const FormatException('GDevelop restore transaction invariant 无效');
    }
    return payload;
  }
}

class GDevelopRestoreTransaction {
  const GDevelopRestoreTransaction._(this.record);

  final PendingProjectCommitRecord<GDevelopRestoreTransactionPayload> record;

  String get txId => record.txId;
  String get gameId => record.gameId;
  PendingProjectCommitPhase get phase => record.phase;
  GDevelopRestoreProjectEvidence get oldEvidence => record.payload.oldEvidence;
  GDevelopRestoreProjectEvidence get targetEvidence =>
      record.payload.targetEvidence;

  Map<String, Object?> toJson({
    GDevelopRestoreTargetSnapshot? targetSnapshot,
    GDevelopProjectSnapshot? restored,
  }) => {
    'txId': record.txId,
    'gameId': record.gameId,
    'idempotencyKey': record.idempotencyKey,
    'phase': record.phase.wireName,
    'baseRevision': record.payload.baseRevision,
    'targetRevision': record.payload.targetRevision,
    'source': record.payload.source.wireName,
    if (record.payload.clientId != null) 'clientId': record.payload.clientId,
    'oldEvidence': record.payload.oldEvidence.toJson(),
    'targetEvidence': record.payload.targetEvidence.toJson(),
    'createdAt': record.createdAt.toUtc().toIso8601String(),
    'updatedAt': record.updatedAt.toUtc().toIso8601String(),
    if (record.expiresAt != null)
      'expiresAt': record.expiresAt!.toUtc().toIso8601String(),
    if (record.retainedUntil != null)
      'retainedUntil': record.retainedUntil!.toUtc().toIso8601String(),
    if (targetSnapshot != null) 'targetSnapshot': targetSnapshot.toJson(),
    if (restored != null) 'restored': restored.toJson(),
    if (record.payload.backupVersion != null)
      'backupVersion': record.payload.backupVersion!.toJson(),
    if (record.payload.browserEvidence != null)
      'browserEvidence': record.payload.browserEvidence!.toJson(),
    if (record.payload.conflict != null) 'conflict': record.payload.conflict,
  };
}

class GDevelopRestoreRecoveryResult {
  const GDevelopRestoreRecoveryResult({
    required this.transaction,
    required this.replayedEventTxIds,
  });

  final GDevelopRestoreTransaction? transaction;
  final List<String> replayedEventTxIds;
}

/// 协调 history、project-config sidecar 与浏览器 IndexedDB 的可恢复提交。
class GDevelopRestoreTransactionCoordinator {
  GDevelopRestoreTransactionCoordinator({
    required this.history,
    required this.projectConfig,
    GDevelopProjectRootResolver? rootResolver,
    this.preparedTtl = const Duration(minutes: 10),
    this.receiptRetention = const Duration(days: 7),
    DateTime Function()? clock,
    String Function()? idFactory,
    this.crashHook,
    this.eventSink,
    GDevelopProjectMutationLock? mutationLock,
  }) : rootResolver = rootResolver ?? history.rootResolver,
       clock = clock ?? DateTime.now,
       idFactory = idFactory ?? _defaultTransactionId,
       mutationLock = mutationLock ?? const GDevelopProjectMutationLock();

  static const namespace = 'gdevelop.restore.v3';
  static int _transactionSequence = 0;

  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController projectConfig;
  final GDevelopProjectRootResolver rootResolver;
  final Duration preparedTtl;
  final Duration receiptRetention;
  final DateTime Function() clock;
  final String Function() idFactory;
  final GDevelopRestoreCrashHook? crashHook;
  final GDevelopRestoreEventSink? eventSink;
  final GDevelopProjectMutationLock mutationLock;
  final List<GDevelopProjectMutationGuard> _additionalMutationGuards = [];
  final Map<
    String,
    Future<PendingProjectCommitStore<GDevelopRestoreTransactionPayload>>
  >
  _stores = {};

  Future<GDevelopHistoryProjectConfigSnapshot> captureProjectConfigSnapshot(
    String gameId,
  ) async {
    final evidence = await projectConfig.inspect(gameId);
    return switch (evidence.status) {
      GDevelopProjectConfigStatus.ready =>
        GDevelopHistoryProjectConfigSnapshot.ready(evidence.config!),
      GDevelopProjectConfigStatus.missing =>
        const GDevelopHistoryProjectConfigSnapshot.missing(),
      GDevelopProjectConfigStatus.invalid =>
        throw const GDevelopProjectConfigInvalidState(),
    };
  }

  Future<T> runProjectMutation<T>(String gameId, Future<T> Function() action) =>
      _withProject(gameId, (store) async {
        await store.ensureMutationAllowed();
        for (final guard in _additionalMutationGuards) {
          await guard(gameId);
        }
        return action();
      });

  /// 项目分配时目标根可能尚不存在；该方法只占位和检查，不创建任何文件。
  Future<T> runProjectAllocation<T>(
    String gameId,
    Future<T> Function() action,
  ) async {
    final root = await rootResolver.projectRootLocation(gameId);
    return mutationLock.run(
      projectRoots: [root],
      action: () async {
        for (final guard in _additionalMutationGuards) {
          await guard(gameId);
        }
        try {
          await (await _store(gameId)).ensureMutationAllowed();
        } on ProjectProvisioningMissing {
          // 尚未分配的根不可能持有 restore journal。
        }
        return action();
      },
    );
  }

  void registerMutationGuard(GDevelopProjectMutationGuard guard) {
    _additionalMutationGuards.add(guard);
  }

  /// 供持有同一公共项目锁的跨项目事务检查，避免嵌套获取项目锁。
  Future<void> ensureNoActiveRestore(String gameId) async {
    try {
      await (await _store(gameId)).ensureMutationAllowed();
    } on ProjectProvisioningMissing {
      return;
    }
  }

  Future<GDevelopRestoreTransaction> prepare({
    required String gameId,
    required String idempotencyKey,
    required int baseRevision,
    required int targetRevision,
    required GDevelopHistorySource source,
    required List<GDevelopProjectFile> currentProjectFiles,
    required List<GDevelopProjectResource> currentResources,
    String? clientId,
  }) => _withProject(gameId, (store) async {
    if (baseRevision < 1 || targetRevision < 1) {
      throw const FormatException('GDevelop restore revision 无效');
    }
    final normalizedClientId = _optionalClientId(clientId);
    final preparedCurrent = await history.prepareProjectState(
      projectId: gameId,
      projectFiles: currentProjectFiles,
      resources: currentResources,
    );
    final requestValue = {
      'baseRevision': baseRevision,
      'targetRevision': targetRevision,
      'source': source.wireName,
      'currentProjectFilesReference': preparedCurrent.projectFilesReference
          .toJson(),
      'currentResources': preparedCurrent.resources
          .map((resource) => resource.toJson())
          .toList(),
      'clientId': ?normalizedClientId,
    };
    final existing = await store.findByIdempotencyKey(
      idempotencyKey: idempotencyKey,
      requestValue: requestValue,
    );
    if (existing != null) return GDevelopRestoreTransaction._(existing);

    final current = await history.currentReferenceSnapshot(gameId);
    if (current == null || current.version.revision != baseRevision) {
      throw GDevelopHistoryRevisionConflict(current?.version.revision ?? 0);
    }
    final target = await history.referenceAtRevision(
      projectId: gameId,
      revision: targetRevision,
    );
    final oldSidecar = await projectConfig.inspect(gameId);
    if (oldSidecar.status == GDevelopProjectConfigStatus.invalid) {
      throw const GDevelopProjectConfigInvalidState();
    }
    final oldConfig = GDevelopRestoreConfigEvidence(
      semantics: oldSidecar.status == GDevelopProjectConfigStatus.ready
          ? GDevelopHistoryProjectConfigSemantics.ready
          : GDevelopHistoryProjectConfigSemantics.missing,
      sidecar: oldSidecar,
    );
    final targetConfig = await _prepareTargetConfig(
      gameId: gameId,
      oldSidecar: oldSidecar,
      historical: target.projectConfigSnapshot,
    );
    final oldHistory = await _historyEvidence(current);
    final targetPayloadHash = await history.revisionPayloadContentHash(
      projectId: gameId,
      projectFiles: target.projectFiles,
      resources: target.resources,
      projectConfigSnapshot: targetConfig.historySnapshot,
    );
    final targetHistory = GDevelopRestoreHistoryEvidence(
      revision: baseRevision + 1,
      currentContentHash: targetPayloadHash,
      projectFilesHash: target.projectFiles.contentHash,
      resourceManifestHash: await _resourceManifestHash(target.resources),
    );
    final payload = GDevelopRestoreTransactionPayload(
      gameId: ProjectProvisioningService.validateGameId(gameId),
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      source: source,
      clientId: normalizedClientId,
      currentProjectFilesReference: preparedCurrent.projectFilesReference,
      currentResources: preparedCurrent.resources,
      targetProjectFilesReference: target.projectFiles,
      targetResources: target.resources,
      sourceVersion: target.version,
      oldEvidence: GDevelopRestoreProjectEvidence(
        history: oldHistory,
        config: oldConfig,
      ),
      targetEvidence: GDevelopRestoreProjectEvidence(
        history: targetHistory,
        config: targetConfig,
      ),
      eventEmitted: false,
    );
    final prepared = await store.prepare(
      gameId: gameId,
      idempotencyKey: idempotencyKey,
      requestValue: requestValue,
      payload: payload,
    );
    await _crash(GDevelopRestoreCrashPoint.afterPrepared, prepared.txId);
    return GDevelopRestoreTransaction._(prepared);
  });

  Future<GDevelopRestoreTransaction> commit({
    required String gameId,
    required String txId,
  }) => _withProject(gameId, (store) async {
    final initial = await store.status(txId);
    if (initial.gameId != gameId) throw PendingProjectCommitNotFound(txId);
    final driven = await _drive(store, initial, startCommit: true);
    return GDevelopRestoreTransaction._(driven);
  });

  Future<GDevelopRestoreTransaction> status({
    required String gameId,
    required String txId,
  }) => _withProject(gameId, (store) async {
    final record = await store.status(txId);
    if (record.gameId != gameId) throw PendingProjectCommitNotFound(txId);
    return GDevelopRestoreTransaction._(record);
  });

  Future<GDevelopRestoreTransaction> acknowledge({
    required String gameId,
    required String txId,
    required GDevelopRestoreBrowserEvidence browserEvidence,
  }) => _withProject(gameId, (store) async {
    var record = await store.status(txId);
    if (record.gameId != gameId) throw PendingProjectCommitNotFound(txId);
    if (record.phase == PendingProjectCommitPhase.browserPersisted) {
      record = await _emitReceiptIfNeeded(store, record);
      return GDevelopRestoreTransaction._(record);
    }
    if (record.phase != PendingProjectCommitPhase.backendCommitted) {
      throw GDevelopRestoreTransactionUnavailable(record.phase);
    }
    final expected = record.payload.targetEvidence.history;
    if (browserEvidence.projectFilesHash != expected.projectFilesHash ||
        browserEvidence.resourceManifestHash != expected.resourceManifestHash) {
      throw const GDevelopRestoreAckMismatch();
    }
    final current = await _inspectCurrent(record.payload.gameId);
    if (!_matchesTarget(record.payload, current)) {
      record = await _conflict(
        store,
        record,
        reason: 'backend_changed_before_browser_ack',
        current: current,
      );
      return GDevelopRestoreTransaction._(record);
    }
    final completedPayload = record.payload.withBrowserEvidence(
      evidence: browserEvidence,
      timestamp: clock().toUtc(),
    );
    record = await store.complete(txId: txId, payload: completedPayload);
    await _crash(GDevelopRestoreCrashPoint.afterReceipt, txId);
    record = await _emitReceiptIfNeeded(store, record);
    return GDevelopRestoreTransaction._(record);
  });

  Future<GDevelopRestoreRecoveryResult> recover(String gameId) =>
      _withProject(gameId, (store) async {
        var active = await store.active();
        if (active != null &&
            active.phase != PendingProjectCommitPhase.prepared &&
            active.phase != PendingProjectCommitPhase.conflict) {
          active = await _drive(store, active, startCommit: false);
        }
        final replayed = await _replayReceipts(store);
        return GDevelopRestoreRecoveryResult(
          transaction: active == null
              ? null
              : GDevelopRestoreTransaction._(active),
          replayedEventTxIds: List.unmodifiable(replayed),
        );
      });

  Future<GDevelopRestoreTransaction> abort({
    required String gameId,
    required String txId,
  }) => _withProject(gameId, (store) async {
    final current = await store.status(txId);
    final aborted = switch (current.phase) {
      PendingProjectCommitPhase.prepared => await store.abortPrepared(txId),
      PendingProjectCommitPhase.conflict => await store.abortConflict(txId),
      PendingProjectCommitPhase.aborted => current,
      _ => throw GDevelopRestoreTransactionUnavailable(current.phase),
    };
    return GDevelopRestoreTransaction._(aborted);
  });

  Future<GDevelopRestoreTargetSnapshot> targetSnapshot(
    GDevelopRestoreTransaction transaction,
  ) async {
    final payload = transaction.record.payload;
    try {
      final source = await history.referenceAtRevision(
        projectId: payload.gameId,
        revision: payload.targetRevision,
      );
      final sourceVersion = payload.sourceVersion ?? source.version;
      final sourceResourcesHash = await _resourceManifestHash(source.resources);
      final targetResourcesHash = await _resourceManifestHash(
        payload.targetResources,
      );
      final preparedConfig = payload.targetEvidence.config.historySnapshot;
      final sourceConfig = source.projectConfigSnapshot.config;
      final targetConfig = preparedConfig.config;
      final configMatches =
          source.projectConfigSnapshot.semantics == preparedConfig.semantics &&
          (preparedConfig.semantics !=
                  GDevelopHistoryProjectConfigSemantics.ready ||
              (sourceConfig?.gameType == targetConfig?.gameType &&
                  sourceConfig?.minPlayers == targetConfig?.minPlayers &&
                  sourceConfig?.maxPlayers == targetConfig?.maxPlayers &&
                  _sameStringLists(sourceConfig?.tags, targetConfig?.tags)));
      final plannedPayloadHash = await history.revisionPayloadContentHash(
        projectId: payload.gameId,
        projectFiles: payload.targetProjectFilesReference,
        resources: payload.targetResources,
        projectConfigSnapshot: preparedConfig,
      );
      if (jsonEncode(sourceVersion.toJson()) !=
              jsonEncode(source.version.toJson()) ||
          source.projectFiles.contentHash !=
              payload.targetProjectFilesReference.contentHash ||
          source.projectFiles.size !=
              payload.targetProjectFilesReference.size ||
          sourceResourcesHash != targetResourcesHash ||
          targetResourcesHash !=
              payload.targetEvidence.history.resourceManifestHash ||
          payload.targetProjectFilesReference.contentHash !=
              payload.targetEvidence.history.projectFilesHash ||
          plannedPayloadHash !=
              payload.targetEvidence.history.currentContentHash ||
          payload.targetEvidence.history.revision != payload.baseRevision + 1 ||
          !configMatches) {
        throw const GDevelopRestoreTargetSnapshotMismatch();
      }
      for (final resource in payload.targetResources) {
        await history.readResourceAtRevision(
          projectId: payload.gameId,
          revision: payload.targetRevision,
          logicalId: resource.logicalId,
          contentHash: resource.contentHash,
        );
      }
      final projectFiles = await history.readHistoryProjectFilesReference(
        projectId: payload.gameId,
        reference: payload.targetProjectFilesReference,
      );
      return GDevelopRestoreTargetSnapshot(
        sourceVersion: sourceVersion,
        projectFilesReference: List<GDevelopProjectFileReference>.unmodifiable(
          payload.targetProjectFilesReference.files,
        ),
        projectFiles: List<GDevelopProjectFile>.unmodifiable(projectFiles),
        resources: List<GDevelopProjectResource>.unmodifiable(
          payload.targetResources,
        ),
        projectConfigSnapshot: preparedConfig,
      );
    } on GDevelopRestoreTargetSnapshotMismatch {
      rethrow;
    } on Object {
      throw const GDevelopRestoreTargetSnapshotMismatch();
    }
  }

  Future<GDevelopProjectSnapshot?> restoredSnapshot(
    GDevelopRestoreTransaction transaction,
  ) async {
    final payload = transaction.record.payload;
    final version = payload.restoredVersion;
    if (version == null) return null;
    final projectFiles = await history.readHistoryProjectFilesReference(
      projectId: payload.gameId,
      reference: payload.targetProjectFilesReference,
    );
    return GDevelopProjectSnapshot(
      version: version,
      projectFiles: projectFiles,
      resources: payload.targetResources,
      projectConfigSnapshot: payload.targetEvidence.config.historySnapshot,
    );
  }

  Future<PendingProjectCommitRecord<GDevelopRestoreTransactionPayload>> _drive(
    PendingProjectCommitStore<GDevelopRestoreTransactionPayload> store,
    PendingProjectCommitRecord<GDevelopRestoreTransactionPayload> record, {
    required bool startCommit,
  }) async {
    if (record.phase == PendingProjectCommitPhase.prepared) {
      if (!startCommit) return record;
      final current = await _inspectCurrent(record.payload.gameId);
      if (!_matchesOld(record.payload, current)) {
        return _conflict(
          store,
          record,
          reason: 'prepared_baseline_changed',
          current: current,
        );
      }
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.commitRequested,
        payload: record.payload,
      );
      await _crash(GDevelopRestoreCrashPoint.afterCommitRequested, record.txId);
    }

    if (record.phase == PendingProjectCommitPhase.commitRequested) {
      final current = await _inspectCurrent(record.payload.gameId);
      final historyIsOld =
          current.history?.matches(record.payload.oldEvidence.history) ?? false;
      final historyIsTarget =
          current.history?.matches(record.payload.targetEvidence.history) ??
          false;
      final configIsOld = current.config.matches(
        record.payload.oldEvidence.config.sidecar,
      );
      final configIsTarget = current.config.matches(
        record.payload.targetEvidence.config.sidecar,
      );
      if (historyIsOld && configIsOld) {
        final restored = await history.restorePrepared(
          projectId: record.payload.gameId,
          baseRevision: record.payload.baseRevision,
          targetRevision: record.payload.targetRevision,
          source: record.payload.source,
          currentProjectFiles: record.payload.currentProjectFilesReference,
          currentResources: record.payload.currentResources,
          currentProjectConfigSnapshot:
              record.payload.oldEvidence.config.historySnapshot,
          restoredProjectConfigSnapshot:
              record.payload.targetEvidence.config.historySnapshot,
        );
        record = _recordWithPayload(
          record,
          record.payload.withRestored(
            restoredVersion: restored.version,
            backupVersion: restored.backupVersion,
          ),
        );
        await _crash(
          GDevelopRestoreCrashPoint.afterHistoryMutation,
          record.txId,
        );
      } else if (historyIsTarget && (configIsOld || configIsTarget)) {
        record = _recordWithPayload(
          record,
          await _recoverRestoredVersions(record.payload),
        );
      } else {
        return _conflict(
          store,
          record,
          reason: 'history_or_config_third_state',
          current: current,
        );
      }
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.historyApplied,
        payload: record.payload,
      );
      await _crash(GDevelopRestoreCrashPoint.afterHistoryApplied, record.txId);
    }

    if (record.phase == PendingProjectCommitPhase.historyApplied) {
      var current = await _inspectCurrent(record.payload.gameId);
      final historyIsTarget =
          current.history?.matches(record.payload.targetEvidence.history) ??
          false;
      if (!historyIsTarget) {
        return _conflict(
          store,
          record,
          reason: 'history_changed_after_apply',
          current: current,
        );
      }
      final configIsOld = current.config.matches(
        record.payload.oldEvidence.config.sidecar,
      );
      final configIsTarget = current.config.matches(
        record.payload.targetEvidence.config.sidecar,
      );
      if (!configIsOld && !configIsTarget) {
        return _conflict(
          store,
          record,
          reason: 'config_third_state',
          current: current,
        );
      }
      if (configIsOld && !configIsTarget) {
        try {
          await projectConfig.applyPreparedTarget(
            gameId: record.payload.gameId,
            oldEvidence: record.payload.oldEvidence.config.sidecar,
            targetEvidence: record.payload.targetEvidence.config.sidecar,
          );
        } on GDevelopProjectConfigApplyConflict catch (error) {
          current = _CurrentProjectEvidence(
            history: current.history,
            config: error.currentEvidence,
          );
          return _conflict(
            store,
            record,
            reason: 'config_compare_and_swap_failed',
            current: current,
          );
        }
        await _crash(
          GDevelopRestoreCrashPoint.afterConfigMutation,
          record.txId,
        );
      }
      final verified = await _inspectCurrent(record.payload.gameId);
      if (!_matchesTarget(record.payload, verified)) {
        return _conflict(
          store,
          record,
          reason: 'backend_target_verification_failed',
          current: verified,
        );
      }
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.backendCommitted,
        payload: record.payload,
      );
      await _crash(
        GDevelopRestoreCrashPoint.afterBackendCommitted,
        record.txId,
      );
    }

    if (record.phase == PendingProjectCommitPhase.backendCommitted) {
      final current = await _inspectCurrent(record.payload.gameId);
      if (!_matchesTarget(record.payload, current)) {
        return _conflict(
          store,
          record,
          reason: 'backend_changed_after_commit',
          current: current,
        );
      }
    }
    return record;
  }

  Future<GDevelopRestoreConfigEvidence> _prepareTargetConfig({
    required String gameId,
    required GDevelopProjectConfigEvidence oldSidecar,
    required GDevelopHistoryProjectConfigSnapshot historical,
  }) async {
    switch (historical.semantics) {
      case GDevelopHistoryProjectConfigSemantics.ready:
        final historicalConfig = historical.config!;
        final revision =
            [
              oldSidecar.revision ?? 0,
              historicalConfig.revision,
            ].reduce((left, right) => left > right ? left : right) +
            1;
        final config = GDevelopProjectConfig(
          gameId: gameId,
          revision: revision,
          gameType: historicalConfig.gameType,
          minPlayers: historicalConfig.minPlayers,
          maxPlayers: historicalConfig.maxPlayers,
          tags: historicalConfig.tags,
          updatedAt: clock().toUtc(),
        );
        return GDevelopRestoreConfigEvidence(
          semantics: GDevelopHistoryProjectConfigSemantics.ready,
          sidecar: await GDevelopProjectConfigEvidence.forReady(config),
        );
      case GDevelopHistoryProjectConfigSemantics.missing:
        return const GDevelopRestoreConfigEvidence(
          semantics: GDevelopHistoryProjectConfigSemantics.missing,
          sidecar: GDevelopProjectConfigEvidence.missing(),
        );
      case GDevelopHistoryProjectConfigSemantics.legacy:
        return GDevelopRestoreConfigEvidence(
          semantics: GDevelopHistoryProjectConfigSemantics.legacy,
          sidecar: oldSidecar,
        );
    }
  }

  Future<GDevelopRestoreHistoryEvidence> _historyEvidence(
    GDevelopProjectCurrentReferenceSnapshot snapshot,
  ) async => GDevelopRestoreHistoryEvidence(
    revision: snapshot.version.revision,
    currentContentHash: snapshot.version.contentHash,
    projectFilesHash: snapshot.projectFiles.contentHash,
    resourceManifestHash: await _resourceManifestHash(snapshot.resources),
  );

  Future<_CurrentProjectEvidence> _inspectCurrent(String gameId) async {
    final current = await history.currentReferenceSnapshot(gameId);
    return _CurrentProjectEvidence(
      history: current == null ? null : await _historyEvidence(current),
      config: await projectConfig.inspect(gameId),
    );
  }

  bool _matchesOld(
    GDevelopRestoreTransactionPayload payload,
    _CurrentProjectEvidence current,
  ) =>
      (current.history?.matches(payload.oldEvidence.history) ?? false) &&
      current.config.matches(payload.oldEvidence.config.sidecar);

  bool _matchesTarget(
    GDevelopRestoreTransactionPayload payload,
    _CurrentProjectEvidence current,
  ) =>
      (current.history?.matches(payload.targetEvidence.history) ?? false) &&
      current.config.matches(payload.targetEvidence.config.sidecar);

  Future<PendingProjectCommitRecord<GDevelopRestoreTransactionPayload>>
  _conflict(
    PendingProjectCommitStore<GDevelopRestoreTransactionPayload> store,
    PendingProjectCommitRecord<GDevelopRestoreTransactionPayload> record, {
    required String reason,
    required _CurrentProjectEvidence current,
  }) {
    final payload = record.payload.withConflict({
      'reason': reason,
      'observedAt': clock().toUtc().toIso8601String(),
      'current': current.toJson(),
    });
    return store.markConflict(txId: record.txId, payload: payload);
  }

  Future<GDevelopRestoreTransactionPayload> _recoverRestoredVersions(
    GDevelopRestoreTransactionPayload payload,
  ) async {
    if (payload.restoredVersion != null) return payload;
    final restored = await history.currentReferenceSnapshot(payload.gameId);
    if (restored == null ||
        restored.version.revision != payload.targetEvidence.history.revision) {
      throw StateError('GDevelop restore current 不可恢复');
    }
    GDevelopProjectVersion? backup;
    final versions = await history.list(payload.gameId);
    final restoredHistoryIndex = versions.indexWhere(
      (version) =>
          version.reason == GDevelopHistoryReason.restore &&
          version.contentHash ==
              payload.targetEvidence.history.currentContentHash,
    );
    if (restoredHistoryIndex >= 0) {
      for (
        var index = restoredHistoryIndex + 1;
        index < versions.length;
        index += 1
      ) {
        if (versions[index].reason == GDevelopHistoryReason.beforeRestore) {
          backup = versions[index];
          break;
        }
      }
    }
    return payload.withRestored(
      restoredVersion: restored.version,
      backupVersion: backup,
    );
  }

  Future<PendingProjectCommitRecord<GDevelopRestoreTransactionPayload>>
  _emitReceiptIfNeeded(
    PendingProjectCommitStore<GDevelopRestoreTransactionPayload> store,
    PendingProjectCommitRecord<GDevelopRestoreTransactionPayload> receipt,
  ) async {
    if (receipt.phase != PendingProjectCommitPhase.browserPersisted ||
        receipt.payload.eventEmitted) {
      return receipt;
    }
    final payload = receipt.payload;
    final version = payload.restoredVersion;
    final timestamp = payload.eventTimestamp;
    if (version == null || timestamp == null) {
      throw StateError('GDevelop restore receipt 缺少事件证据');
    }
    await eventSink?.call({
      'type': 'gdevelop.history.restored',
      'gameId': payload.gameId,
      'txId': receipt.txId,
      'revision': version.revision,
      'targetRevision': payload.targetRevision,
      'clientId': payload.clientId,
      'timestamp': timestamp.millisecondsSinceEpoch,
    });
    await _crash(GDevelopRestoreCrashPoint.afterEvent, receipt.txId);
    return store.updateReceipt(
      txId: receipt.txId,
      payload: payload.markEventEmitted(),
    );
  }

  Future<List<String>> _replayReceipts(
    PendingProjectCommitStore<GDevelopRestoreTransactionPayload> store,
  ) async {
    final replayed = <String>[];
    for (final receipt in await store.receipts()) {
      if (receipt.phase != PendingProjectCommitPhase.browserPersisted ||
          receipt.payload.eventEmitted) {
        continue;
      }
      await _emitReceiptIfNeeded(store, receipt);
      replayed.add(receipt.txId);
    }
    return replayed;
  }

  Future<String> _resourceManifestHash(
    List<GDevelopProjectResource> resources,
  ) => PendingProjectCommitComparator.hashJson(
    resources.map((resource) => resource.toJson()).toList(),
  );

  Future<PendingProjectCommitStore<GDevelopRestoreTransactionPayload>> _store(
    String gameId,
  ) {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    final existing = _stores[normalized];
    if (existing != null) return existing;
    final created = () async {
      final root = await rootResolver.runInProjectRoot(
        normalized,
        (projectRoot) async => projectRoot,
      );
      return PendingProjectCommitStore<GDevelopRestoreTransactionPayload>(
        root: Directory(
          '${root.path}${Platform.pathSeparator}.playmesh'
          '${Platform.pathSeparator}gdevelop'
          '${Platform.pathSeparator}pending-project-commits'
          '${Platform.pathSeparator}restore-v3',
        ),
        namespace: namespace,
        codec: const PendingProjectCommitCodec(
          encode: _encodeRestorePayload,
          decode: _decodeRestorePayload,
        ),
        preparedTtl: preparedTtl,
        receiptRetention: receiptRetention,
        clock: clock,
        idFactory: idFactory,
      );
    }();
    _stores[normalized] = created;
    unawaited(
      created.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // 只驱逐自己对应的失败 future，避免晚到回调误删后继成功值。
          if (identical(_stores[normalized], created)) {
            _stores.remove(normalized);
          }
        },
      ),
    );
    return created;
  }

  Future<T> _withProject<T>(
    String gameId,
    Future<T> Function(
      PendingProjectCommitStore<GDevelopRestoreTransactionPayload> store,
    )
    action,
  ) async {
    final projectRoot = await rootResolver.projectRootLocation(gameId);
    final store = await _store(gameId);
    return mutationLock.run(
      projectRoots: [projectRoot],
      action: () => action(store),
    );
  }

  Future<void> _crash(GDevelopRestoreCrashPoint point, String txId) async {
    await crashHook?.call(point, txId);
  }

  static String _defaultTransactionId() =>
      'restore-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '${_transactionSequence++}';
}

class _CurrentProjectEvidence {
  const _CurrentProjectEvidence({required this.history, required this.config});

  final GDevelopRestoreHistoryEvidence? history;
  final GDevelopProjectConfigEvidence config;

  Map<String, Object?> toJson() => {
    'history': history?.toJson(),
    'config': config.toJson(),
  };
}

PendingProjectCommitRecord<GDevelopRestoreTransactionPayload>
_recordWithPayload(
  PendingProjectCommitRecord<GDevelopRestoreTransactionPayload> record,
  GDevelopRestoreTransactionPayload payload,
) => PendingProjectCommitRecord(
  namespace: record.namespace,
  gameId: record.gameId,
  txId: record.txId,
  idempotencyKey: record.idempotencyKey,
  requestHash: record.requestHash,
  phase: record.phase,
  payload: payload,
  createdAt: record.createdAt,
  updatedAt: record.updatedAt,
  expiresAt: record.expiresAt,
  retainedUntil: record.retainedUntil,
);

Object? _encodeRestorePayload(GDevelopRestoreTransactionPayload payload) =>
    payload.toJson();

GDevelopRestoreTransactionPayload _decodeRestorePayload(Object? value) =>
    GDevelopRestoreTransactionPayload.fromJson(value);

Map<String, Object?> _strictMap(Object? value, String name) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('GDevelop $name 无效');
  }
  return Map<String, Object?>.from(value);
}

void _requireExactFields(Map<String, Object?> json, Set<String> fields) {
  if (json.length != fields.length || !json.keys.every(fields.contains)) {
    throw const FormatException('GDevelop restore evidence schema 无效');
  }
}

bool _isHash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String? _optionalClientId(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw const FormatException('GDevelop restore clientId 无效');
  }
  return normalized;
}

GDevelopProjectConfigEvidence _configEvidenceFromJson(
  Map<String, Object?> json, {
  required String gameId,
}) {
  final statusValue = json['status'];
  if (statusValue is! String) {
    throw const FormatException('GDevelop restore config status 无效');
  }
  switch (statusValue) {
    case 'ready':
      _requireExactFields(json, const {
        'status',
        'revision',
        'contentHash',
        'config',
      });
      final config = GDevelopProjectConfig.fromJson(
        _strictMap(json['config'], 'restore config'),
        expectedGameId: gameId,
      );
      if (json['revision'] != config.revision ||
          !_isHash(json['contentHash'])) {
        throw const FormatException(
          'GDevelop restore ready config evidence 无效',
        );
      }
      return GDevelopProjectConfigEvidence.ready(
        config: config,
        contentHash: json['contentHash']! as String,
      );
    case 'missing':
      _requireExactFields(json, const {'status'});
      return const GDevelopProjectConfigEvidence.missing();
    case 'invalid':
      if (!json.keys.every(const {'status', 'contentHash'}.contains) ||
          (json.containsKey('contentHash') && !_isHash(json['contentHash']))) {
        throw const FormatException(
          'GDevelop restore invalid config evidence 无效',
        );
      }
      return GDevelopProjectConfigEvidence.invalid(
        contentHash: json['contentHash'] as String?,
      );
    default:
      throw const FormatException('GDevelop restore config status 无效');
  }
}

List<GDevelopProjectResource> _resourceList(List<Object?> values) {
  final resources = values.map((value) {
    return GDevelopProjectResource.fromJson(
      _strictMap(value, 'restore resource'),
    );
  }).toList();
  resources.sort((left, right) => left.logicalId.compareTo(right.logicalId));
  if (resources.map((resource) => resource.logicalId).toSet().length !=
      resources.length) {
    throw const FormatException('GDevelop restore resource logicalId 重复');
  }
  return List.unmodifiable(resources);
}

GDevelopProjectVersion _versionFromJson(
  Object? value, {
  required String gameId,
}) {
  final json = _strictMap(value, 'restore version');
  _requireExactFields(json, const {
    'id',
    'gameId',
    'revision',
    'timestamp',
    'reason',
    'contentHash',
    'source',
    'contentBytes',
  });
  final id = json['id'];
  final revision = json['revision'];
  final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
  final reason = json['reason'];
  final source = json['source'];
  final contentBytes = json['contentBytes'];
  if (id is! String ||
      id.isEmpty ||
      json['gameId'] != gameId ||
      revision is! int ||
      revision < 1 ||
      timestamp == null ||
      reason is! String ||
      !_isHash(json['contentHash']) ||
      source is! String ||
      contentBytes is! int ||
      contentBytes < 1) {
    throw const FormatException('GDevelop restore version 无效');
  }
  return GDevelopProjectVersion(
    id: id,
    projectId: gameId,
    revision: revision,
    timestamp: timestamp.toUtc(),
    reason: GDevelopHistoryReason.parse(reason),
    contentHash: json['contentHash']! as String,
    source: GDevelopHistorySource.parse(source),
    contentBytes: contentBytes,
  );
}
