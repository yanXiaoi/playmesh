import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/game_id.dart';
import 'foundation/gdevelop_project_mutation_lock.dart';
import 'foundation/local_version_store.dart';
import 'foundation/pending_project_commit_store.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_files.dart';
import 'gdevelop_project_history.dart';
import 'gdevelop_project_root_resolver.dart';
import 'project_provisioning_service.dart';

enum GDevelopProjectAllocationOrigin {
  create('create'),
  importProject('import'),
  copy('copy');

  const GDevelopProjectAllocationOrigin(this.wireName);
  final String wireName;

  static GDevelopProjectAllocationOrigin parse(String value) =>
      values.firstWhere(
        (item) => item.wireName == value,
        orElse: () =>
            throw const FormatException('GDevelop allocation origin 无效'),
      );
}

enum GDevelopProjectAllocationPhase {
  prepared('PREPARED'),
  workspaceFinalized('WORKSPACE_FINALIZED'),
  commitRequested('COMMIT_REQUESTED'),
  committed('COMMITTED'),
  conflict('CONFLICT'),
  aborted('ABORTED');

  const GDevelopProjectAllocationPhase(this.wireName);
  final String wireName;

  static GDevelopProjectAllocationPhase fromStore(
    PendingProjectCommitPhase phase,
  ) => switch (phase) {
    PendingProjectCommitPhase.prepared => prepared,
    PendingProjectCommitPhase.payloadFinalized => workspaceFinalized,
    PendingProjectCommitPhase.commitRequested ||
    PendingProjectCommitPhase.historyApplied ||
    PendingProjectCommitPhase.backendCommitted => commitRequested,
    PendingProjectCommitPhase.browserPersisted => committed,
    PendingProjectCommitPhase.rollbackRequested ||
    PendingProjectCommitPhase.rolledBack => throw StateError(
      'GDevelop allocation 不允许 rekey rollback phase',
    ),
    PendingProjectCommitPhase.conflict => conflict,
    PendingProjectCommitPhase.aborted => aborted,
  };
}

class GDevelopProjectAllocationLocked implements Exception {
  const GDevelopProjectAllocationLocked({
    required this.txId,
    required this.gameId,
    required this.phase,
  });

  final String txId;
  final String gameId;
  final GDevelopProjectAllocationPhase phase;
}

class GDevelopProjectAllocationEvidenceMismatch implements Exception {
  const GDevelopProjectAllocationEvidenceMismatch(this.code);

  final String code;
}

class GDevelopProjectAllocationUnavailable implements Exception {
  const GDevelopProjectAllocationUnavailable(this.phase);
  final GDevelopProjectAllocationPhase phase;
}

class GDevelopProjectAllocationIdempotencyConflict implements Exception {
  const GDevelopProjectAllocationIdempotencyConflict(this.idempotencyKey);
  final String idempotencyKey;
}

class GDevelopProjectAllocationNotFound implements Exception {
  const GDevelopProjectAllocationNotFound(this.txId);
  final String txId;
}

class GDevelopProjectAllocationResourceNotPlanned implements Exception {
  const GDevelopProjectAllocationResourceNotPlanned(this.contentHash);

  final String contentHash;
}

class GDevelopProjectAllocationWorkspaceTarget {
  const GDevelopProjectAllocationWorkspaceTarget({
    required this.fileIdentifier,
    required this.gameId,
    required this.packageName,
    required this.projectUuid,
    required this.projectFilesHash,
    required this.resourceManifestHash,
  });

  final String fileIdentifier;
  final String gameId;
  final String packageName;
  final String projectUuid;
  final String projectFilesHash;
  final String resourceManifestHash;

  Map<String, Object?> toJson() => {
    'fileIdentifier': fileIdentifier,
    'gameId': gameId,
    'packageName': packageName,
    'projectUuid': projectUuid,
    'projectFilesHash': projectFilesHash,
    'resourceManifestHash': resourceManifestHash,
  };

  factory GDevelopProjectAllocationWorkspaceTarget.fromJson(Object? value) {
    final json = _strictMap(value, 'allocation workspaceTarget');
    _requireFields(json, const {
      'fileIdentifier',
      'gameId',
      'packageName',
      'projectUuid',
      'projectFilesHash',
      'resourceManifestHash',
    });
    final fileIdentifier = _fileIdentifier(json['fileIdentifier']);
    final gameId = _gameId(json['gameId']);
    final packageName = _gameId(json['packageName']);
    final projectUuid = _projectUuid(json['projectUuid']);
    if (gameId != packageName ||
        !_isHash(json['projectFilesHash']) ||
        !_isHash(json['resourceManifestHash'])) {
      throw const FormatException('GDevelop allocation workspaceTarget 无效');
    }
    return GDevelopProjectAllocationWorkspaceTarget(
      fileIdentifier: fileIdentifier,
      gameId: gameId,
      packageName: packageName,
      projectUuid: projectUuid,
      projectFilesHash: json['projectFilesHash']! as String,
      resourceManifestHash: json['resourceManifestHash']! as String,
    );
  }
}

class GDevelopProjectAllocationResourceReference {
  const GDevelopProjectAllocationResourceReference({
    required this.logicalId,
    required this.name,
  });

  final String logicalId;
  final String name;

  Map<String, Object?> toJson() => {'logicalId': logicalId, 'name': name};

  factory GDevelopProjectAllocationResourceReference.fromJson(Object? value) {
    final json = _strictMap(value, 'allocation resource reference');
    _requireFields(json, const {'logicalId', 'name'});
    final logicalId = json['logicalId'];
    final name = json['name'];
    if (logicalId is! String || name is! String) {
      throw const FormatException('GDevelop allocation resource reference 无效');
    }
    // 复用历史 DTO 的路径验证，避免 allocation 与 history 接受不同 logicalId。
    GDevelopProjectResource.fromJson({
      'logicalId': logicalId,
      'contentHash':
          '0000000000000000000000000000000000000000000000000000000000000000',
      'mime': 'application/octet-stream',
      'size': 1,
    });
    return GDevelopProjectAllocationResourceReference(
      logicalId: logicalId,
      name: name,
    );
  }
}

/// Raw `projectFiles` DTO upload evidence returned to the WebIDE.
///
/// This hash/size pair covers the exact request bytes. The authoritative
/// current/history reference is computed separately from the official
/// formatted files contained by the DTO.
class GDevelopProjectAllocationProjectFilesUploadReference {
  const GDevelopProjectAllocationProjectFilesUploadReference({
    required this.contentHash,
    required this.size,
  });

  final String contentHash;
  final int size;

  Map<String, Object?> toJson() => {'contentHash': contentHash, 'size': size};
}

class GDevelopProjectAllocationWorkspaceProject {
  const GDevelopProjectAllocationWorkspaceProject({
    required this.packageName,
    required this.projectUuid,
    required this.projectFilesHash,
    required this.projectFilesSize,
    required this.resourceReferences,
  });

  final String packageName;
  final String projectUuid;
  final String projectFilesHash;
  final int projectFilesSize;
  final List<GDevelopProjectAllocationResourceReference> resourceReferences;

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'projectUuid': projectUuid,
    'projectFilesHash': projectFilesHash,
    'projectFilesSize': projectFilesSize,
    'resourceReferences': resourceReferences
        .map((reference) => reference.toJson())
        .toList(),
  };

  factory GDevelopProjectAllocationWorkspaceProject.fromJson(Object? value) {
    final json = _strictMap(value, 'allocation workspaceProject');
    _requireFields(json, const {
      'packageName',
      'projectUuid',
      'projectFilesHash',
      'projectFilesSize',
      'resourceReferences',
    });
    if (!_isHash(json['projectFilesHash']) ||
        json['projectFilesSize'] is! int ||
        (json['projectFilesSize']! as int) < 1 ||
        (json['projectFilesSize']! as int) >
            GDevelopProjectHistoryAdapter.maxProjectFilesBytes ||
        json['resourceReferences'] is! List) {
      throw const FormatException('GDevelop allocation workspaceProject 无效');
    }
    final references = (json['resourceReferences']! as List)
        .map(GDevelopProjectAllocationResourceReference.fromJson)
        .toList(growable: false);
    if (references.map((item) => item.logicalId).toSet().length !=
        references.length) {
      throw const FormatException('GDevelop allocation 工程资源引用重复');
    }
    return GDevelopProjectAllocationWorkspaceProject(
      packageName: _gameId(json['packageName']),
      projectUuid: _projectUuid(json['projectUuid']),
      projectFilesHash: json['projectFilesHash']! as String,
      projectFilesSize: json['projectFilesSize']! as int,
      resourceReferences: List.unmodifiable(references),
    );
  }
}

class GDevelopProjectAllocationWorkspaceFinalization {
  const GDevelopProjectAllocationWorkspaceFinalization({
    required this.packageName,
    required this.projectUuid,
    required this.projectFilesHash,
    required this.projectFilesSize,
    required this.resourceManifestHash,
  });

  final String packageName;
  final String projectUuid;
  final String projectFilesHash;
  final int projectFilesSize;
  final String resourceManifestHash;

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'projectUuid': projectUuid,
    'projectFilesHash': projectFilesHash,
    'projectFilesSize': projectFilesSize,
    'resourceManifestHash': resourceManifestHash,
  };

  factory GDevelopProjectAllocationWorkspaceFinalization.fromJson(
    Object? value,
  ) {
    final json = _strictMap(value, 'allocation workspace finalization');
    _requireFields(json, const {
      'packageName',
      'projectUuid',
      'projectFilesHash',
      'projectFilesSize',
      'resourceManifestHash',
    });
    if (!_isHash(json['projectFilesHash']) ||
        !_isHash(json['resourceManifestHash']) ||
        json['projectFilesSize'] is! int ||
        (json['projectFilesSize']! as int) < 1 ||
        (json['projectFilesSize']! as int) >
            GDevelopProjectHistoryAdapter.maxProjectFilesBytes) {
      throw const FormatException(
        'GDevelop allocation workspace finalization 无效',
      );
    }
    return GDevelopProjectAllocationWorkspaceFinalization(
      packageName: _gameId(json['packageName']),
      projectUuid: _projectUuid(json['projectUuid']),
      projectFilesHash: json['projectFilesHash']! as String,
      projectFilesSize: json['projectFilesSize']! as int,
      resourceManifestHash: json['resourceManifestHash']! as String,
    );
  }
}

class _GDevelopProjectAllocationWorkspaceProjectInspection {
  const _GDevelopProjectAllocationWorkspaceProjectInspection({
    required this.project,
    required this.projectFiles,
  });

  final GDevelopProjectAllocationWorkspaceProject project;
  final GDevelopProjectFilesReference projectFiles;
}

class GDevelopProjectAllocationEvidence {
  const GDevelopProjectAllocationEvidence({
    required this.projectMetadataHash,
    required this.config,
  });

  final String projectMetadataHash;
  final GDevelopProjectConfigEvidence config;

  Map<String, Object?> toJson() => {
    'projectMetadataHash': projectMetadataHash,
    'config': config.toJson(),
  };

  factory GDevelopProjectAllocationEvidence.fromJson(
    Object? value, {
    required String gameId,
  }) {
    final json = _strictMap(value, 'allocation evidence');
    _requireFields(json, const {'projectMetadataHash', 'config'});
    if (!_isHash(json['projectMetadataHash'])) {
      throw const FormatException('GDevelop allocation evidence 无效');
    }
    return GDevelopProjectAllocationEvidence(
      projectMetadataHash: json['projectMetadataHash']! as String,
      config: _configEvidence(json['config'], gameId: gameId),
    );
  }

  bool matches(GDevelopProjectAllocationEvidence other) =>
      projectMetadataHash == other.projectMetadataHash &&
      config.matches(other.config);
}

class GDevelopProjectAllocationPayload {
  const GDevelopProjectAllocationPayload({
    required this.gameId,
    required this.origin,
    required this.name,
    required this.clientId,
    required this.workspaceTarget,
    required this.stagingPath,
    required this.allocationEvidence,
    this.resourcePlan = const [],
    this.workspaceProject,
    this.workspaceFinalization,
    this.conflict,
  });

  static const schemaVersion = 3;

  final String gameId;
  final GDevelopProjectAllocationOrigin origin;
  final String name;
  final String? clientId;
  final GDevelopProjectAllocationWorkspaceTarget workspaceTarget;
  final String stagingPath;
  final GDevelopProjectAllocationEvidence allocationEvidence;
  final List<GDevelopProjectResource> resourcePlan;
  final GDevelopProjectAllocationWorkspaceProject? workspaceProject;
  final GDevelopProjectAllocationWorkspaceFinalization? workspaceFinalization;
  final Map<String, Object?>? conflict;

  GDevelopProjectAllocationPayload copyWith({
    List<GDevelopProjectResource>? resourcePlan,
    GDevelopProjectAllocationWorkspaceProject? workspaceProject,
    GDevelopProjectAllocationWorkspaceFinalization? workspaceFinalization,
    Map<String, Object?>? conflict,
  }) => GDevelopProjectAllocationPayload(
    gameId: gameId,
    origin: origin,
    name: name,
    clientId: clientId,
    workspaceTarget: workspaceTarget,
    stagingPath: stagingPath,
    allocationEvidence: allocationEvidence,
    resourcePlan: resourcePlan ?? this.resourcePlan,
    workspaceProject: workspaceProject ?? this.workspaceProject,
    workspaceFinalization: workspaceFinalization ?? this.workspaceFinalization,
    conflict: conflict ?? this.conflict,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'gameId': gameId,
    'origin': origin.wireName,
    'name': name,
    'clientId': clientId,
    'workspaceTarget': workspaceTarget.toJson(),
    'stagingPath': stagingPath,
    'allocationEvidence': allocationEvidence.toJson(),
    'resourcePlan': resourcePlan.map((resource) => resource.toJson()).toList(),
    'workspaceProject': workspaceProject?.toJson(),
    'workspaceFinalization': workspaceFinalization?.toJson(),
    'conflict': conflict,
  };

  factory GDevelopProjectAllocationPayload.fromJson(Object? value) {
    final json = _strictMap(value, 'allocation payload');
    _requireFields(json, const {
      'schemaVersion',
      'gameId',
      'origin',
      'name',
      'clientId',
      'workspaceTarget',
      'stagingPath',
      'allocationEvidence',
      'resourcePlan',
      'workspaceProject',
      'workspaceFinalization',
      'conflict',
    });
    if (json['schemaVersion'] != schemaVersion ||
        json['gameId'] is! String ||
        json['origin'] is! String ||
        json['name'] is! String ||
        (json['clientId'] != null && json['clientId'] is! String) ||
        json['stagingPath'] is! String ||
        json['resourcePlan'] is! List ||
        (json['conflict'] != null && json['conflict'] is! Map)) {
      throw const FormatException('GDevelop allocation payload 无效');
    }
    final gameId = _gameId(json['gameId']);
    final target = GDevelopProjectAllocationWorkspaceTarget.fromJson(
      json['workspaceTarget'],
    );
    if (target.gameId != gameId) {
      throw const FormatException('GDevelop allocation identity 无效');
    }
    return GDevelopProjectAllocationPayload(
      gameId: gameId,
      origin: GDevelopProjectAllocationOrigin.parse(json['origin']! as String),
      name: _name(json['name']),
      clientId: _optionalToken(json['clientId'], 'clientId'),
      workspaceTarget: target,
      stagingPath: json['stagingPath']! as String,
      allocationEvidence: GDevelopProjectAllocationEvidence.fromJson(
        json['allocationEvidence'],
        gameId: gameId,
      ),
      resourcePlan: List.unmodifiable(
        (json['resourcePlan']! as List).map((raw) {
          if (raw is! Map) {
            throw const FormatException('GDevelop allocation resourcePlan 无效');
          }
          return GDevelopProjectResource.fromJson(
            Map<String, Object?>.from(raw),
          );
        }),
      ),
      workspaceProject: json['workspaceProject'] == null
          ? null
          : GDevelopProjectAllocationWorkspaceProject.fromJson(
              json['workspaceProject'],
            ),
      workspaceFinalization: json['workspaceFinalization'] == null
          ? null
          : GDevelopProjectAllocationWorkspaceFinalization.fromJson(
              json['workspaceFinalization'],
            ),
      conflict: json['conflict'] == null
          ? null
          : Map<String, Object?>.from(json['conflict']! as Map),
    );
  }
}

class GDevelopProjectAllocationTransaction {
  const GDevelopProjectAllocationTransaction._(this.record);

  final PendingProjectCommitRecord<GDevelopProjectAllocationPayload> record;

  String get txId => record.txId;
  String get gameId => record.payload.gameId;
  GDevelopProjectAllocationPhase get phase =>
      GDevelopProjectAllocationPhase.fromStore(record.phase);

  Map<String, Object?> toJson() => {
    'txId': txId,
    'idempotencyKey': record.idempotencyKey,
    'gameId': gameId,
    'origin': record.payload.origin.wireName,
    'phase': phase.wireName,
    'name': record.payload.name,
    'clientId': record.payload.clientId,
    'workspaceTarget': record.payload.workspaceTarget.toJson(),
    'allocationEvidence': record.payload.allocationEvidence.toJson(),
    'resourcePlan': record.payload.resourcePlan
        .map((resource) => resource.toJson())
        .toList(),
    'createdAt': record.createdAt.toUtc().toIso8601String(),
    'updatedAt': record.updatedAt.toUtc().toIso8601String(),
    'expiresAt': record.expiresAt?.toUtc().toIso8601String(),
    'retainedUntil': record.retainedUntil?.toUtc().toIso8601String(),
    'workspaceProject': record.payload.workspaceProject?.toJson(),
    'workspaceFinalization': record.payload.workspaceFinalization?.toJson(),
    'conflict': record.payload.conflict,
  };
}

enum GDevelopProjectAllocationCrashPoint {
  afterPrepared,
  afterWorkspaceFinalized,
  afterCommitRequested,
  afterCanonicalRename,
  afterBackendCommitted,
  afterReceipt,
}

class GDevelopProjectAllocationResourcePresence {
  const GDevelopProjectAllocationResourcePresence({
    required this.transaction,
    required this.missing,
    required this.available,
  });

  final GDevelopProjectAllocationTransaction transaction;
  final List<LocalCasObjectReference> missing;
  final List<LocalCasObjectReference> available;

  Map<String, Object?> toJson() => {
    'transaction': transaction.toJson(),
    'missing': missing.map((reference) => reference.toJson()).toList(),
    'available': available.map((reference) => reference.toJson()).toList(),
  };
}

typedef GDevelopProjectAllocationCrashHook =
    FutureOr<void> Function(
      GDevelopProjectAllocationCrashPoint point,
      String txId,
    );
typedef GDevelopProjectAllocationMutationGuard =
    Future<void> Function(String gameId);

class GDevelopProjectAllocationCoordinator {
  GDevelopProjectAllocationCoordinator({
    required this.rootResolver,
    GDevelopProjectHistoryAdapter? history,
    GDevelopProjectMutationLock? mutationLock,
    this.preparedTtl = const Duration(minutes: 10),
    this.receiptRetention = const Duration(days: 7),
    DateTime Function()? clock,
    String Function()? idFactory,
    this.crashHook,
  }) : history =
           history ?? GDevelopProjectHistoryAdapter(rootResolver: rootResolver),
       mutationLock = mutationLock ?? const GDevelopProjectMutationLock(),
       clock = clock ?? DateTime.now,
       idFactory = idFactory ?? _defaultId;

  static const namespace = 'gdevelop.allocation.v1';
  static int _sequence = 0;

  final GDevelopProjectRootResolver rootResolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectMutationLock mutationLock;
  final Duration preparedTtl;
  final Duration receiptRetention;
  final DateTime Function() clock;
  final String Function() idFactory;
  final GDevelopProjectAllocationCrashHook? crashHook;
  final List<GDevelopProjectAllocationMutationGuard> _mutationGuards = [];
  final Map<
    String,
    Future<PendingProjectCommitStore<GDevelopProjectAllocationPayload>>
  >
  _stores = {};

  void registerMutationGuard(GDevelopProjectAllocationMutationGuard guard) {
    if (!_mutationGuards.contains(guard)) _mutationGuards.add(guard);
  }

  Future<GDevelopProjectAllocationTransaction> prepare({
    required String gameId,
    required String idempotencyKey,
    required GDevelopProjectAllocationOrigin origin,
    required GDevelopProjectAllocationWorkspaceTarget workspaceTarget,
    String? name,
    String? clientId,
  }) async {
    final normalized = _gameId(gameId);
    if (workspaceTarget.gameId != normalized) {
      throw const FormatException(
        'GDevelop allocation workspaceTarget gameId 无效',
      );
    }
    final normalizedName = _name(name ?? normalized);
    final normalizedClientId = _optionalToken(clientId, 'clientId');
    final requestValue = {
      'gameId': normalized,
      'origin': origin.wireName,
      'name': normalizedName,
      'clientId': normalizedClientId,
      'workspaceTarget': workspaceTarget.toJson(),
    };
    final store = await _store(normalized);
    final root = await rootResolver.projectRootLocation(normalized);
    return mutationLock.run(
      projectRoots: [root],
      action: () async {
        var insideReplay = await _findIdempotent(
          store,
          idempotencyKey: idempotencyKey,
          requestValue: requestValue,
        );
        if (insideReplay != null) {
          if (insideReplay.phase == PendingProjectCommitPhase.aborted) {
            await _deleteStaging(insideReplay.payload);
          }
          return GDevelopProjectAllocationTransaction._(insideReplay);
        }
        for (final guard in _mutationGuards) {
          await guard(normalized);
        }
        await _replacePreparedAllocation(store, normalized);
        if (await _pathExists(root.path)) {
          throw ProjectProvisioningConflict(
            gameId: normalized,
            requestedKind: PlaymeshProjectKind.gdevelop,
          );
        }
        final staging = await _stagingRoot(
          root: root,
          gameId: normalized,
          idempotencyKey: idempotencyKey,
        );
        var durable = false;
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
          final now = clock().toUtc();
          final metadata = <String, Object?>{
            'schemaVersion': ProjectProvisioningService.metadataSchemaVersion,
            'kind': PlaymeshProjectKind.gdevelop.wireName,
            'gameId': normalized,
            'name': normalizedName,
            if (isValidPlaymeshNewProjectGameId(normalized))
              'identityPolicy':
                  ProjectProvisioningService.androidApplicationIdIdentityPolicy,
            'fileIdentifiers': [workspaceTarget.fileIdentifier],
            'createdAt': now.toIso8601String(),
            'updatedAt': now.toIso8601String(),
          };
          final config = GDevelopProjectConfig(
            gameId: normalized,
            revision: 1,
            gameType: GDevelopProjectGameType.single,
            minPlayers: 1,
            maxPlayers: 1,
            tags: const [],
            updatedAt: now,
          );
          await _writeJson(_metadataFile(staging), metadata);
          await _writeJson(_configFile(staging), config.toJson());
          final evidence = await _inspectStaging(staging, gameId: normalized);
          if (await _pathExists(root.path)) {
            throw ProjectProvisioningConflict(
              gameId: normalized,
              requestedKind: PlaymeshProjectKind.gdevelop,
            );
          }
          final prepared = await store.prepare(
            gameId: normalized,
            idempotencyKey: idempotencyKey,
            requestValue: requestValue,
            payload: GDevelopProjectAllocationPayload(
              gameId: normalized,
              origin: origin,
              name: normalizedName,
              clientId: normalizedClientId,
              workspaceTarget: workspaceTarget,
              stagingPath: staging.path,
              allocationEvidence: evidence,
            ),
          );
          durable = true;
          await _crash(
            GDevelopProjectAllocationCrashPoint.afterPrepared,
            prepared.txId,
          );
          return GDevelopProjectAllocationTransaction._(prepared);
        } on PendingProjectCommitIdempotencyConflict {
          throw GDevelopProjectAllocationIdempotencyConflict(idempotencyKey);
        } on PendingProjectCommitLocked catch (error) {
          throw GDevelopProjectAllocationLocked(
            txId: error.activeTxId,
            gameId: normalized,
            phase: GDevelopProjectAllocationPhase.fromStore(error.phase),
          );
        } finally {
          if (!durable && await staging.exists()) {
            await staging.delete(recursive: true);
          }
        }
      },
    );
  }

  Future<GDevelopProjectAllocationResourcePresence> resourcePresence({
    required String txId,
    required List<GDevelopProjectResource> resources,
  }) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      var record = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (record.phase != PendingProjectCommitPhase.prepared) {
        throw GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.fromStore(record.phase),
        );
      }
      final batch = _normalizeResourceBatch(resources);
      final merged = _mergeResourcePlan(record.payload.resourcePlan, batch);
      if (!_sameResourceLists(merged, record.payload.resourcePlan)) {
        record = await located.store.updateActive(
          txId: txId,
          payload: record.payload.copyWith(resourcePlan: merged),
        );
      }
      final cas = _workspaceStore(record.payload);
      final references = <String, LocalCasObjectReference>{};
      for (final resource in batch) {
        references.putIfAbsent(
          resource.contentHash,
          () => LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
        );
      }
      final missing = <LocalCasObjectReference>[];
      final available = <LocalCasObjectReference>[];
      final orderedReferences = references.values.toList()
        ..sort((left, right) => left.hash.compareTo(right.hash));
      for (final reference in orderedReferences) {
        (await cas.containsObject(reference) ? available : missing).add(
          reference,
        );
      }
      return GDevelopProjectAllocationResourcePresence(
        transaction: GDevelopProjectAllocationTransaction._(record),
        missing: List.unmodifiable(missing),
        available: List.unmodifiable(available),
      );
    });
  }

  Future<LocalCasObjectReference> uploadResource({
    required String txId,
    required String contentHash,
    required Stream<List<int>> bytes,
    int? contentLength,
    Duration inactivityTimeout = const Duration(seconds: 30),
  }) async {
    final normalizedHash = _hash(contentHash, 'resource contentHash');
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      final record = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (record.phase != PendingProjectCommitPhase.prepared) {
        throw GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.fromStore(record.phase),
        );
      }
      final planned = record.payload.resourcePlan
          .where((resource) => resource.contentHash == normalizedHash)
          .toList(growable: false);
      if (planned.isEmpty) {
        throw GDevelopProjectAllocationResourceNotPlanned(normalizedHash);
      }
      final expectedBytes = planned.first.size;
      if (planned.any((resource) => resource.size != expectedBytes)) {
        throw const FormatException('GDevelop allocation 同 hash 资源大小不一致');
      }
      if (contentLength != null && contentLength != expectedBytes) {
        throw const FormatException('GDevelop allocation 资源上传大小不一致');
      }
      final staged = await _workspaceStore(record.payload).stageStream(
        bytes,
        expectedBytes: expectedBytes,
        maxBytes: expectedBytes,
        timeout: inactivityTimeout,
      );
      if (staged.hash != normalizedHash) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'resource_content_hash_mismatch',
        );
      }
      return staged;
    });
  }

  Future<GDevelopProjectAllocationProjectFilesUploadReference>
  uploadWorkspaceProjectFiles({
    required String txId,
    required Stream<List<int>> bytes,
    int? contentLength,
    Duration inactivityTimeout = const Duration(seconds: 30),
  }) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      var record = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (record.phase != PendingProjectCommitPhase.prepared) {
        throw GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.fromStore(record.phase),
        );
      }
      if (contentLength != null &&
          (contentLength < 1 ||
              contentLength >
                  GDevelopProjectHistoryAdapter.maxProjectFilesBytes)) {
        throw const FormatException('GDevelop allocation 工程大小无效');
      }
      final staged = await _workspaceStore(record.payload).stageStream(
        bytes,
        expectedBytes: contentLength,
        maxBytes: GDevelopProjectHistoryAdapter.maxProjectFilesBytes,
        timeout: inactivityTimeout,
      );
      if (staged.hash != record.payload.workspaceTarget.projectFilesHash) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'workspace_project_files_hash_mismatch',
        );
      }
      final inspection = await _inspectWorkspaceProjectFiles(
        record.payload,
        LocalCasObjectReference(hash: staged.hash, bytes: staged.bytes),
      );
      final project = inspection.project;
      final previous = record.payload.workspaceProject;
      if (previous != null && !_sameWorkspaceProject(previous, project)) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'workspace_project_changed',
        );
      }
      if (previous == null) {
        record = await located.store.updateActive(
          txId: txId,
          payload: record.payload.copyWith(workspaceProject: project),
        );
      }
      return GDevelopProjectAllocationProjectFilesUploadReference(
        contentHash: staged.hash,
        size: staged.bytes,
      );
    });
  }

  Future<GDevelopProjectAllocationTransaction> finalizeWorkspace({
    required String txId,
    required GDevelopProjectAllocationWorkspaceFinalization evidence,
  }) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      var record = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (record.phase != PendingProjectCommitPhase.prepared) {
        final persisted = record.payload.workspaceFinalization;
        if (persisted == null || !_sameFinalization(persisted, evidence)) {
          throw const GDevelopProjectAllocationEvidenceMismatch(
            'workspace_finalization_changed',
          );
        }
        final inspection = await _inspectFinalizedWorkspace(
          record.payload,
          projectRoot: await _materializedProjectRoot(record.payload),
        );
        try {
          record = await located.store.markPayloadFinalized(
            txId: txId,
            payload: record.payload,
            evidence: _payloadFinalizationEvidence(
              record.payload,
              inspection.projectFiles,
            ),
          );
        } on PendingProjectCommitPayloadFinalizationConflict {
          throw const GDevelopProjectAllocationEvidenceMismatch(
            'workspace_finalization_changed',
          );
        }
        return GDevelopProjectAllocationTransaction._(record);
      }
      final workspaceProject = record.payload.workspaceProject;
      if (workspaceProject == null) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'workspace_project_missing',
        );
      }
      final inspection = await _inspectWorkspace(record.payload);
      if (!_sameFinalization(inspection.finalization, evidence)) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'workspace_finalization_mismatch',
        );
      }
      final conflict = await _preDecisionConflict(record);
      if (conflict != null) {
        record = await _markConflict(located.store, record, conflict);
        return GDevelopProjectAllocationTransaction._(record);
      }
      final config = record.payload.allocationEvidence.config.config;
      if (config == null) {
        throw const FormatException('GDevelop allocation staging config 缺失');
      }
      await history.initializeCurrentAtProjectRoot(
        projectRoot: Directory(record.payload.stagingPath),
        historyRoot: _historyRoot(Directory(record.payload.stagingPath)),
        projectId: record.payload.gameId,
        projectFiles: inspection.projectFiles,
        resources: inspection.orderedResources,
        projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(
          config,
        ),
      );
      final finalizedPayload = record.payload.copyWith(
        workspaceFinalization: inspection.finalization,
      );
      try {
        record = await located.store.markPayloadFinalized(
          txId: txId,
          payload: finalizedPayload,
          evidence: _payloadFinalizationEvidence(
            finalizedPayload,
            inspection.projectFiles,
          ),
        );
      } on PendingProjectCommitPayloadFinalizationConflict {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'workspace_finalization_changed',
        );
      }
      await _crash(
        GDevelopProjectAllocationCrashPoint.afterWorkspaceFinalized,
        txId,
      );
      return GDevelopProjectAllocationTransaction._(record);
    });
  }

  Future<GDevelopProjectAllocationTransaction> commit(String txId) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      var current = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (current.phase == PendingProjectCommitPhase.prepared) {
        throw const GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.prepared,
        );
      }
      if (current.phase == PendingProjectCommitPhase.payloadFinalized) {
        final conflict = await _preDecisionConflict(current);
        if (conflict != null || !await _finalizedStagingMatches(current)) {
          current = await _markConflict(
            located.store,
            current,
            conflict ?? 'staging_changed',
          );
          return GDevelopProjectAllocationTransaction._(current);
        }
        current = await located.store.advance(
          txId: txId,
          phase: PendingProjectCommitPhase.commitRequested,
          payload: current.payload,
        );
        await _crash(
          GDevelopProjectAllocationCrashPoint.afterCommitRequested,
          txId,
        );
      }
      final driven = await _drive(located.store, current);
      return GDevelopProjectAllocationTransaction._(driven);
    });
  }

  Future<GDevelopProjectAllocationTransaction> status(String txId) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      final current = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      return GDevelopProjectAllocationTransaction._(current);
    });
  }

  Future<GDevelopProjectAllocationTransaction> recover(String txId) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      final current = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      final driven = await _drive(located.store, current);
      return GDevelopProjectAllocationTransaction._(driven);
    });
  }

  Future<GDevelopProjectAllocationTransaction> abort(String txId) async {
    final located = await _locate(txId);
    return _withGameRoot(located.gameId, () async {
      final current = await _settledStatus(
        located.store,
        txId,
        expectedGameId: located.gameId,
      );
      if (current.phase == PendingProjectCommitPhase.browserPersisted ||
          current.phase == PendingProjectCommitPhase.aborted) {
        if (current.phase == PendingProjectCommitPhase.browserPersisted) {
          throw const GDevelopProjectAllocationUnavailable(
            GDevelopProjectAllocationPhase.committed,
          );
        }
        return GDevelopProjectAllocationTransaction._(current);
      }
      if (current.phase == PendingProjectCommitPhase.commitRequested ||
          current.phase == PendingProjectCommitPhase.historyApplied ||
          current.phase == PendingProjectCommitPhase.backendCommitted) {
        throw GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.fromStore(current.phase),
        );
      }
      await _deleteStaging(current.payload);
      final aborted = switch (current.phase) {
        PendingProjectCommitPhase.prepared ||
        PendingProjectCommitPhase.payloadFinalized =>
          await located.store.abortPreDecision(txId),
        PendingProjectCommitPhase.conflict => await located.store.abortConflict(
          txId,
        ),
        _ => throw GDevelopProjectAllocationUnavailable(
          GDevelopProjectAllocationPhase.fromStore(current.phase),
        ),
      };
      return GDevelopProjectAllocationTransaction._(aborted);
    });
  }

  Future<void> ensureMutationAllowed(String gameId) async {
    final normalized = _gameId(gameId);
    final store = await _store(normalized);
    final active = await store.active();
    if (active == null) {
      await _cleanupAbortedStaging(store);
      return;
    }
    throw GDevelopProjectAllocationLocked(
      txId: active.txId,
      gameId: normalized,
      phase: GDevelopProjectAllocationPhase.fromStore(active.phase),
    );
  }

  Future<PendingProjectCommitRecord<GDevelopProjectAllocationPayload>> _drive(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
    PendingProjectCommitRecord<GDevelopProjectAllocationPayload> record,
  ) async {
    if (record.phase == PendingProjectCommitPhase.prepared ||
        record.phase == PendingProjectCommitPhase.payloadFinalized) {
      return record;
    }
    if (record.phase == PendingProjectCommitPhase.commitRequested) {
      if (!await _finalizedStagingMatches(record)) return record;
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.historyApplied,
        payload: record.payload,
      );
    }
    if (record.phase == PendingProjectCommitPhase.historyApplied) {
      final root = await rootResolver.projectRootLocation(
        record.payload.gameId,
      );
      final staging = Directory(record.payload.stagingPath);
      if (await _pathExists(root.path)) {
        if (!await _directoryMatchesPayload(root, record.payload)) {
          return record;
        }
      } else {
        if (!await _finalizedStagingMatches(record)) return record;
        await _renameDirectory(staging, root.path);
      }
      await _crash(
        GDevelopProjectAllocationCrashPoint.afterCanonicalRename,
        record.txId,
      );
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.backendCommitted,
        payload: record.payload,
      );
      await _crash(
        GDevelopProjectAllocationCrashPoint.afterBackendCommitted,
        record.txId,
      );
    }
    if (record.phase == PendingProjectCommitPhase.backendCommitted) {
      record = await store.complete(txId: record.txId, payload: record.payload);
      await _crash(
        GDevelopProjectAllocationCrashPoint.afterReceipt,
        record.txId,
      );
    }
    return record;
  }

  Future<String?> _preDecisionConflict(
    PendingProjectCommitRecord<GDevelopProjectAllocationPayload> record,
  ) async {
    final root = await rootResolver.projectRootLocation(record.payload.gameId);
    if (await _pathExists(root.path)) return 'target_became_occupied';
    if (!await _stagingMatches(record.payload)) return 'staging_changed';
    return null;
  }

  Future<bool> _stagingMatches(GDevelopProjectAllocationPayload payload) async {
    try {
      final staging = Directory(payload.stagingPath);
      if (!await staging.exists()) return false;
      return payload.allocationEvidence.matches(
        await _inspectStaging(staging, gameId: payload.gameId),
      );
    } on Object {
      return false;
    }
  }

  Future<GDevelopProjectAllocationEvidence> _inspectStaging(
    Directory staging, {
    required String gameId,
  }) async {
    final metadata = _metadataFile(staging);
    final decodedMetadata = jsonDecode(await metadata.readAsString());
    if (decodedMetadata is! Map) {
      throw const FormatException('GDevelop allocation metadata 无效');
    }
    final metadataJson = Map<String, Object?>.from(decodedMetadata);
    if (metadataJson['schemaVersion'] !=
            ProjectProvisioningService.metadataSchemaVersion ||
        metadataJson['kind'] != PlaymeshProjectKind.gdevelop.wireName ||
        metadataJson['gameId'] != gameId ||
        metadataJson['name'] is! String ||
        metadataJson['fileIdentifiers'] is! List ||
        metadataJson['createdAt'] is! String ||
        metadataJson['updatedAt'] is! String) {
      throw const FormatException('GDevelop allocation metadata 无效');
    }
    final decodedConfig = jsonDecode(await _configFile(staging).readAsString());
    if (decodedConfig is! Map) {
      throw const GDevelopProjectConfigInvalidState();
    }
    final config = GDevelopProjectConfig.fromJson(
      Map<String, Object?>.from(decodedConfig),
      expectedGameId: gameId,
    );
    return GDevelopProjectAllocationEvidence(
      projectMetadataHash: await PendingProjectCommitComparator.hashJson(
        metadataJson,
      ),
      config: await GDevelopProjectConfigEvidence.forReady(config),
    );
  }

  LocalVersionStore _workspaceStore(
    GDevelopProjectAllocationPayload payload, {
    Directory? projectRoot,
  }) => LocalVersionStore(
    root: _historyRoot(projectRoot ?? Directory(payload.stagingPath)),
    retentionPolicy: history.retentionPolicy,
    clock: clock,
  );

  List<GDevelopProjectResource> _normalizeResourceBatch(
    List<GDevelopProjectResource> resources, {
    bool allowEmpty = false,
  }) {
    if ((!allowEmpty && resources.isEmpty) || resources.length > 2048) {
      throw const FormatException('GDevelop allocation 资源批次必须为 1 至 2048 项');
    }
    final logicalIds = <String>{};
    final normalized = <GDevelopProjectResource>[];
    for (final resource in resources) {
      final item = GDevelopProjectResource.fromJson(resource.toJson());
      if (item.name == null || item.name!.isEmpty) {
        throw const FormatException(
          'GDevelop allocation 资源必须携带官方 resource name',
        );
      }
      if (!logicalIds.add(item.logicalId)) {
        throw const FormatException('GDevelop allocation 资源批次 logicalId 重复');
      }
      if (item.size > history.retentionPolicy.maxObjectBytes) {
        throw LocalVersionQuotaExceeded(
          scope: 'object',
          limit: history.retentionPolicy.maxObjectBytes,
        );
      }
      normalized.add(item);
    }
    normalized.sort((left, right) => left.logicalId.compareTo(right.logicalId));
    return List.unmodifiable(normalized);
  }

  List<GDevelopProjectResource> _mergeResourcePlan(
    List<GDevelopProjectResource> existing,
    List<GDevelopProjectResource> batch,
  ) {
    final byLogicalId = <String, GDevelopProjectResource>{
      for (final resource in existing) resource.logicalId: resource,
    };
    final sizeByHash = <String, int>{};
    for (final resource in [...existing, ...batch]) {
      final previousSize = sizeByHash[resource.contentHash];
      if (previousSize != null && previousSize != resource.size) {
        throw const FormatException('GDevelop allocation 同一资源 hash 的 size 不一致');
      }
      sizeByHash[resource.contentHash] = resource.size;
      final previous = byLogicalId[resource.logicalId];
      if (previous != null && !_sameResource(previous, resource)) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'resource_plan_changed',
        );
      }
      byLogicalId[resource.logicalId] = resource;
    }
    if (byLogicalId.length > 2048) {
      throw const FormatException('GDevelop allocation 资源计划最多支持 2048 项');
    }
    final uniqueBytes = sizeByHash.values.fold<int>(
      0,
      (sum, size) => sum + size,
    );
    if (uniqueBytes > history.retentionPolicy.maxUniqueBytesPerNamespace) {
      throw LocalVersionQuotaExceeded(
        scope: 'namespace',
        limit: history.retentionPolicy.maxUniqueBytesPerNamespace,
      );
    }
    final merged = byLogicalId.values.toList()
      ..sort((left, right) => left.logicalId.compareTo(right.logicalId));
    return List.unmodifiable(merged);
  }

  Future<_GDevelopProjectAllocationWorkspaceProjectInspection>
  _inspectWorkspaceProjectFiles(
    GDevelopProjectAllocationPayload payload,
    LocalCasObjectReference reference, {
    Directory? projectRoot,
  }) async {
    final store = _workspaceStore(payload, projectRoot: projectRoot);
    final bytes = await store.readObject(reference);
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const FormatException(
        'GDevelop allocation projectFiles 必须是 UTF-8 JSON',
      );
    }
    final projectFiles = gdevelopProjectFilesFromJson(decoded);
    final projectFilesReference = await referenceGDevelopProjectFiles(
      projectFiles,
    );
    if (projectFilesReference.size >
        GDevelopProjectHistoryAdapter.maxProjectFilesBytes) {
      throw const FormatException('GDevelop allocation 工程大小无效');
    }
    for (var index = 0; index < projectFiles.length; index += 1) {
      final staged = await store.stageObject(
        encodeOfficialGDevelopProjectFileBytes(projectFiles[index].content),
      );
      final expected = projectFilesReference.files[index];
      if (staged.hash != expected.contentHash ||
          staged.bytes != expected.size) {
        throw StateError('GDevelop allocation 工程文件写入 CAS 时发生变化');
      }
    }
    final project = gdevelopRootProjectFile(projectFiles).content;
    final properties = project['properties'];
    if (properties is! Map) {
      throw const FormatException('GDevelop allocation 工程 properties 无效');
    }
    final propertyJson = Map<String, Object?>.from(properties);
    final packageName = _gameId(propertyJson['packageName']);
    final projectUuid = _projectUuid(propertyJson['projectUuid']);
    final target = payload.workspaceTarget;
    if (packageName != target.gameId ||
        packageName != target.packageName ||
        projectUuid != target.projectUuid ||
        reference.hash != target.projectFilesHash) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_identity_mismatch',
      );
    }
    final references = _officialResourceReferences(project);
    return _GDevelopProjectAllocationWorkspaceProjectInspection(
      project: GDevelopProjectAllocationWorkspaceProject(
        packageName: packageName,
        projectUuid: projectUuid,
        projectFilesHash: reference.hash,
        projectFilesSize: reference.bytes,
        resourceReferences: references,
      ),
      projectFiles: projectFilesReference,
    );
  }

  Future<
    ({
      GDevelopProjectAllocationWorkspaceFinalization finalization,
      List<GDevelopProjectResource> orderedResources,
      GDevelopProjectFilesReference projectFiles,
    })
  >
  _inspectWorkspace(
    GDevelopProjectAllocationPayload payload, {
    Directory? projectRoot,
  }) async {
    final normalizedPlan = _normalizeResourceBatch(
      payload.resourcePlan,
      allowEmpty: true,
    );
    final validatedPlan = _mergeResourcePlan(const [], normalizedPlan);
    if (!_sameResourceLists(validatedPlan, payload.resourcePlan)) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_plan_noncanonical',
      );
    }
    final persistedProject = payload.workspaceProject;
    if (persistedProject == null) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_missing',
      );
    }
    final projectInspection = await _inspectWorkspaceProjectFiles(
      payload,
      LocalCasObjectReference(
        hash: persistedProject.projectFilesHash,
        bytes: persistedProject.projectFilesSize,
      ),
      projectRoot: projectRoot,
    );
    final project = projectInspection.project;
    if (!_sameWorkspaceProject(project, persistedProject)) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_changed',
      );
    }
    final orderedResources = _orderedResources(payload);
    final cas = _workspaceStore(payload, projectRoot: projectRoot);
    final verified = <String>{};
    for (final resource in orderedResources) {
      if (!verified.add(resource.contentHash)) continue;
      await cas.readObject(
        LocalCasObjectReference(
          hash: resource.contentHash,
          bytes: resource.size,
        ),
      );
    }
    final resourceManifestHash = await PendingProjectCommitComparator.hashJson(
      orderedResources.map((resource) => resource.toJson()).toList(),
    );
    if (resourceManifestHash != payload.workspaceTarget.resourceManifestHash) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_manifest_mismatch',
      );
    }
    return (
      finalization: GDevelopProjectAllocationWorkspaceFinalization(
        packageName: project.packageName,
        projectUuid: project.projectUuid,
        projectFilesHash: project.projectFilesHash,
        projectFilesSize: project.projectFilesSize,
        resourceManifestHash: resourceManifestHash,
      ),
      orderedResources: orderedResources,
      projectFiles: projectInspection.projectFiles,
    );
  }

  Future<
    ({
      GDevelopProjectAllocationWorkspaceFinalization finalization,
      List<GDevelopProjectResource> orderedResources,
      GDevelopProjectFilesReference projectFiles,
    })
  >
  _inspectFinalizedWorkspace(
    GDevelopProjectAllocationPayload payload, {
    required Directory projectRoot,
  }) async {
    final normalizedPlan = _normalizeResourceBatch(
      payload.resourcePlan,
      allowEmpty: true,
    );
    final validatedPlan = _mergeResourcePlan(const [], normalizedPlan);
    if (!_sameResourceLists(validatedPlan, payload.resourcePlan)) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_plan_noncanonical',
      );
    }
    final persistedProject = payload.workspaceProject;
    final config = payload.allocationEvidence.config.config;
    if (persistedProject == null || config == null) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_missing',
      );
    }
    final snapshot = await history.currentAtProjectRoot(
      projectRoot: projectRoot,
      projectId: payload.gameId,
    );
    if (snapshot == null) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_missing',
      );
    }
    final projectFiles = await referenceGDevelopProjectFiles(
      snapshot.projectFiles,
    );
    final rootProject = gdevelopRootProjectFile(snapshot.projectFiles).content;
    final properties = rootProject['properties'];
    if (properties is! Map) {
      throw const FormatException('GDevelop allocation 工程 properties 无效');
    }
    final propertyJson = Map<String, Object?>.from(properties);
    final project = GDevelopProjectAllocationWorkspaceProject(
      packageName: _gameId(propertyJson['packageName']),
      projectUuid: _projectUuid(propertyJson['projectUuid']),
      projectFilesHash: persistedProject.projectFilesHash,
      projectFilesSize: persistedProject.projectFilesSize,
      resourceReferences: _officialResourceReferences(rootProject),
    );
    if (!_sameWorkspaceProject(project, persistedProject)) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_changed',
      );
    }
    final orderedResources = _orderedResources(payload);
    await history.verifyCurrentAtProjectRoot(
      projectRoot: projectRoot,
      projectId: payload.gameId,
      projectFiles: projectFiles,
      resources: orderedResources,
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(config),
    );
    final resourceManifestHash = await PendingProjectCommitComparator.hashJson(
      orderedResources.map((resource) => resource.toJson()).toList(),
    );
    if (resourceManifestHash != payload.workspaceTarget.resourceManifestHash) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_manifest_mismatch',
      );
    }
    return (
      finalization: GDevelopProjectAllocationWorkspaceFinalization(
        packageName: project.packageName,
        projectUuid: project.projectUuid,
        projectFilesHash: project.projectFilesHash,
        projectFilesSize: project.projectFilesSize,
        resourceManifestHash: resourceManifestHash,
      ),
      orderedResources: orderedResources,
      projectFiles: projectFiles,
    );
  }

  Future<Directory> _materializedProjectRoot(
    GDevelopProjectAllocationPayload payload,
  ) async {
    final staging = Directory(payload.stagingPath);
    if (await staging.exists()) return staging;
    return rootResolver.projectRootLocation(payload.gameId);
  }

  List<GDevelopProjectResource> _orderedResources(
    GDevelopProjectAllocationPayload payload,
  ) {
    final project = payload.workspaceProject;
    if (project == null) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'workspace_project_missing',
      );
    }
    final byLogicalId = <String, GDevelopProjectResource>{
      for (final resource in payload.resourcePlan) resource.logicalId: resource,
    };
    if (byLogicalId.length != payload.resourcePlan.length ||
        project.resourceReferences.length != payload.resourcePlan.length) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_plan_incomplete',
      );
    }
    final ordered = <GDevelopProjectResource>[];
    for (final reference in project.resourceReferences) {
      final resource = byLogicalId.remove(reference.logicalId);
      if (resource == null || resource.name != reference.name) {
        throw const GDevelopProjectAllocationEvidenceMismatch(
          'resource_plan_incomplete',
        );
      }
      ordered.add(resource);
    }
    if (byLogicalId.isNotEmpty) {
      throw const GDevelopProjectAllocationEvidenceMismatch(
        'resource_plan_incomplete',
      );
    }
    return List.unmodifiable(ordered);
  }

  Future<bool> _finalizedStagingMatches(
    PendingProjectCommitRecord<GDevelopProjectAllocationPayload> record,
  ) => _directoryMatchesPayload(
    Directory(record.payload.stagingPath),
    record.payload,
    expectedFinalizationHash: record.payloadFinalizationHash,
  );

  Future<bool> _directoryMatchesPayload(
    Directory root,
    GDevelopProjectAllocationPayload payload, {
    String? expectedFinalizationHash,
  }) async {
    try {
      if (!await root.exists() ||
          !payload.allocationEvidence.matches(
            await _inspectStaging(root, gameId: payload.gameId),
          )) {
        return false;
      }
      final persistedFinalization = payload.workspaceFinalization;
      final workspaceProject = payload.workspaceProject;
      final config = payload.allocationEvidence.config.config;
      if (persistedFinalization == null ||
          workspaceProject == null ||
          config == null) {
        return false;
      }
      final inspection = await _inspectFinalizedWorkspace(
        payload,
        projectRoot: root,
      );
      if (!_sameFinalization(inspection.finalization, persistedFinalization)) {
        return false;
      }
      await history.verifyCurrentAtProjectRoot(
        projectRoot: root,
        projectId: payload.gameId,
        projectFiles: inspection.projectFiles,
        resources: inspection.orderedResources,
        projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(
          config,
        ),
      );
      if (expectedFinalizationHash != null &&
          await PendingProjectCommitComparator.hashJson(
                _payloadFinalizationEvidence(payload, inspection.projectFiles),
              ) !=
              expectedFinalizationHash) {
        return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  Object _payloadFinalizationEvidence(
    GDevelopProjectAllocationPayload payload,
    GDevelopProjectFilesReference projectFiles,
  ) {
    final project = payload.workspaceProject;
    final finalization = payload.workspaceFinalization;
    final config = payload.allocationEvidence.config.config;
    if (project == null || finalization == null || config == null) {
      throw const FormatException(
        'GDevelop allocation finalization evidence 缺失',
      );
    }
    final orderedResources = _orderedResources(payload);
    return {
      'workspaceTarget': payload.workspaceTarget.toJson(),
      'workspaceProject': project.toJson(),
      'workspaceFinalization': finalization.toJson(),
      'allocationEvidence': payload.allocationEvidence.toJson(),
      'resourceManifest': orderedResources
          .map((resource) => resource.toJson())
          .toList(),
      'stagedCurrent': {
        'revision': 1,
        'projectFilesHash': projectFiles.contentHash,
        'projectFilesSize': projectFiles.size,
        'projectFiles': projectFiles.files
            .map((file) => file.toJson())
            .toList(growable: false),
        'resources': orderedResources
            .map((resource) => resource.toJson())
            .toList(),
        'playmeshProjectConfig': config.toJson(),
      },
    };
  }

  Future<PendingProjectCommitRecord<GDevelopProjectAllocationPayload>>
  _settledStatus(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
    String txId, {
    required String expectedGameId,
  }) async {
    late final PendingProjectCommitRecord<GDevelopProjectAllocationPayload>
    record;
    try {
      record = await store.status(txId);
    } on PendingProjectCommitNotFound {
      throw GDevelopProjectAllocationNotFound(txId);
    }
    if (record.gameId != expectedGameId ||
        record.payload.gameId != expectedGameId) {
      throw const FormatException('GDevelop allocation journal identity 无效');
    }
    await _requireStagingPath(record.payload);
    if (record.phase == PendingProjectCommitPhase.aborted ||
        record.phase == PendingProjectCommitPhase.conflict) {
      await _deleteStaging(record.payload);
      return record;
    }
    return record;
  }

  Future<void> _requireStagingPath(
    GDevelopProjectAllocationPayload payload,
  ) async {
    final root = await rootResolver.projectRootLocation(payload.gameId);
    final staging = Directory(payload.stagingPath);
    if (!_pathEquals(staging.parent.absolute.path, root.parent.absolute.path) ||
        !_basename(staging.path).startsWith('.playmesh-allocation-')) {
      throw const FormatException('GDevelop allocation staging 路径越界');
    }
  }

  Future<void> _cleanupAbortedStaging(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
  ) async {
    for (final receipt in await store.receipts()) {
      if (receipt.phase == PendingProjectCommitPhase.aborted) {
        await _deleteStaging(receipt.payload);
      }
    }
  }

  /// A PREPARED allocation has neither finalized a complete workspace nor made
  /// a commit decision. It can contain partial uploads, but they remain inside
  /// allocation-owned sibling staging. Under the product's single-WebIDE
  /// contract, a new prepare for the same gameId is therefore the recovery
  /// signal for a client that lost (or rejected) the previous 201 response.
  /// Release only that sibling staging and retain an ABORTED receipt before the
  /// new transaction is created.
  ///
  /// Later phases are deliberately not replaced: they may contain a complete
  /// workspace or a durable commit decision and must continue through the
  /// explicit status/recover/abort flow.
  Future<void> _replacePreparedAllocation(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
    String gameId,
  ) async {
    final active = await store.active();
    if (active == null) {
      await _cleanupAbortedStaging(store);
      return;
    }
    if (active.phase == PendingProjectCommitPhase.prepared) {
      await _deleteStaging(active.payload);
      await store.abortPrepared(active.txId);
      return;
    }
    throw GDevelopProjectAllocationLocked(
      txId: active.txId,
      gameId: gameId,
      phase: GDevelopProjectAllocationPhase.fromStore(active.phase),
    );
  }

  Future<PendingProjectCommitRecord<GDevelopProjectAllocationPayload>?>
  _findIdempotent(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store, {
    required String idempotencyKey,
    required Object? requestValue,
  }) async {
    try {
      return await store.findByIdempotencyKey(
        idempotencyKey: idempotencyKey,
        requestValue: requestValue,
      );
    } on PendingProjectCommitIdempotencyConflict {
      throw GDevelopProjectAllocationIdempotencyConflict(idempotencyKey);
    }
  }

  Future<PendingProjectCommitRecord<GDevelopProjectAllocationPayload>>
  _markConflict(
    PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
    PendingProjectCommitRecord<GDevelopProjectAllocationPayload> record,
    String reason,
  ) async {
    final conflicted = await store.markConflict(
      txId: record.txId,
      payload: record.payload.copyWith(
        conflict: {
          'reason': reason,
          'observedAt': clock().toUtc().toIso8601String(),
        },
      ),
    );
    await _deleteStaging(conflicted.payload);
    return conflicted;
  }

  Future<T> _withGameRoot<T>(String gameId, Future<T> Function() action) async {
    final root = await rootResolver.projectRootLocation(gameId);
    return mutationLock.run(projectRoots: [root], action: action);
  }

  Future<
    ({
      PendingProjectCommitStore<GDevelopProjectAllocationPayload> store,
      String gameId,
    })
  >
  _locate(String txId) async {
    _transactionId(txId);
    final root = await _transactionsRoot('com.playmesh.allocation-registry');
    if (!await root.exists()) throw GDevelopProjectAllocationNotFound(txId);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final gameId = _basename(entity.path);
      try {
        _gameId(gameId);
      } on FormatException {
        continue;
      }
      final store = await _store(gameId);
      final receipt = File(
        '${entity.path}${Platform.pathSeparator}receipts'
        '${Platform.pathSeparator}$txId.json',
      );
      final candidates = <File>[
        receipt,
        File('${receipt.path}.backup'),
        File('${entity.path}${Platform.pathSeparator}active.json'),
        File('${entity.path}${Platform.pathSeparator}active.json.backup'),
      ];
      for (final candidate in candidates) {
        if (await _journalClaimsTransaction(candidate, txId)) {
          return (store: store, gameId: gameId);
        }
      }
    }
    throw GDevelopProjectAllocationNotFound(txId);
  }

  Future<PendingProjectCommitStore<GDevelopProjectAllocationPayload>> _store(
    String gameId,
  ) {
    final normalized = _gameId(gameId);
    final existing = _stores[normalized];
    if (existing != null) return existing;
    final created = () async {
      final root = await _transactionsRoot(normalized);
      return PendingProjectCommitStore<GDevelopProjectAllocationPayload>(
        root: Directory('${root.path}${Platform.pathSeparator}$normalized'),
        namespace: namespace,
        codec: PendingProjectCommitCodec(
          encode: (payload) => payload.toJson(),
          decode: GDevelopProjectAllocationPayload.fromJson,
        ),
        preparedTtl: preparedTtl,
        receiptRetention: receiptRetention,
        clock: clock,
        idFactory: idFactory,
      );
    }();
    _stores[normalized] = created;
    return created;
  }

  Future<Directory> _transactionsRoot(String gameId) async {
    final root = await rootResolver.projectRootLocation(gameId);
    return Directory(
      '${root.parent.path}${Platform.pathSeparator}.playmesh-transactions'
      '${Platform.pathSeparator}gdevelop-allocation',
    );
  }

  Future<Directory> _stagingRoot({
    required Directory root,
    required String gameId,
    required String idempotencyKey,
  }) async {
    final hash = await PendingProjectCommitComparator.hashJson({
      'gameId': gameId,
      'idempotencyKey': idempotencyKey,
    });
    return Directory(
      '${root.parent.path}${Platform.pathSeparator}.playmesh-allocation-'
      '${hash.substring(0, 24)}',
    );
  }

  Future<void> _deleteStaging(GDevelopProjectAllocationPayload payload) async {
    final root = await rootResolver.projectRootLocation(payload.gameId);
    final staging = Directory(payload.stagingPath);
    if (!_pathEquals(staging.parent.absolute.path, root.parent.absolute.path) ||
        !_basename(staging.path).startsWith('.playmesh-allocation-')) {
      throw StateError('GDevelop allocation staging 路径越界');
    }
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  Future<void> _crash(
    GDevelopProjectAllocationCrashPoint point,
    String txId,
  ) async => crashHook?.call(point, txId);

  static String _defaultId() =>
      'gdevelop-allocation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '${_sequence++}';
}

Future<void> _writeJson(File file, Map<String, Object?> value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(value), flush: true);
}

Future<void> _renameDirectory(Directory source, String destination) async {
  Object? lastError;
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await source.rename(destination);
      return;
    } on FileSystemException catch (error) {
      lastError = error;
      if (await _pathExists(destination)) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
    }
  }
  throw lastError ?? FileSystemException('GDevelop allocation rename 失败');
}

File _metadataFile(Directory root) => File(
  '${root.path}${Platform.pathSeparator}.playmesh'
  '${Platform.pathSeparator}project.json',
);

File _configFile(Directory root) => File(
  '${root.path}${Platform.pathSeparator}.playmesh'
  '${Platform.pathSeparator}gdevelop'
  '${Platform.pathSeparator}project-config.json',
);

Directory _historyRoot(Directory projectRoot) => Directory(
  '${projectRoot.path}${Platform.pathSeparator}.playmesh'
  '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}history',
);

List<GDevelopProjectAllocationResourceReference> _officialResourceReferences(
  Map<String, Object?> project,
) {
  final resources = project['resources'];
  if (resources == null) return const [];
  if (resources is! Map) {
    throw const FormatException('GDevelop allocation 工程 resources 无效');
  }
  final entries = resources['resources'];
  if (entries == null) return const [];
  if (entries is! List) {
    throw const FormatException(
      'GDevelop allocation 工程 resources.resources 无效',
    );
  }
  final result = <GDevelopProjectAllocationResourceReference>[];
  final logicalIds = <String>{};
  for (final raw in entries) {
    if (raw is! Map) {
      throw const FormatException('GDevelop allocation 工程 resource 无效');
    }
    final entry = Map<String, Object?>.from(raw);
    final file = entry['file'];
    if (file is! String) {
      throw const FormatException('GDevelop allocation 工程 resource.file 无效');
    }
    if (!file.startsWith('playmesh-local-resource://')) continue;
    final reference = GDevelopProjectAllocationResourceReference.fromJson({
      'logicalId': file,
      'name': entry['name'],
    });
    if (!logicalIds.add(reference.logicalId)) {
      throw const FormatException('GDevelop allocation 工程资源引用重复');
    }
    result.add(reference);
  }
  return List.unmodifiable(result);
}

bool _sameResource(
  GDevelopProjectResource left,
  GDevelopProjectResource right,
) => jsonEncode(left.toJson()) == jsonEncode(right.toJson());

bool _sameResourceLists(
  List<GDevelopProjectResource> left,
  List<GDevelopProjectResource> right,
) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => _sameResource(left[index], right[index]),
    ).every((same) => same);

bool _sameWorkspaceProject(
  GDevelopProjectAllocationWorkspaceProject left,
  GDevelopProjectAllocationWorkspaceProject right,
) => jsonEncode(left.toJson()) == jsonEncode(right.toJson());

bool _sameFinalization(
  GDevelopProjectAllocationWorkspaceFinalization left,
  GDevelopProjectAllocationWorkspaceFinalization right,
) => jsonEncode(left.toJson()) == jsonEncode(right.toJson());

GDevelopProjectConfigEvidence _configEvidence(
  Object? value, {
  required String gameId,
}) {
  final json = _strictMap(value, 'allocation config evidence');
  final status = json['status'];
  if (status == GDevelopProjectConfigStatus.missing.wireName) {
    _requireFields(json, const {'status'});
    return const GDevelopProjectConfigEvidence.missing();
  }
  _requireFields(json, const {'status', 'revision', 'contentHash', 'config'});
  if (status != GDevelopProjectConfigStatus.ready.wireName ||
      json['revision'] is! int ||
      !_isHash(json['contentHash'])) {
    throw const FormatException('GDevelop allocation config evidence 无效');
  }
  final config = GDevelopProjectConfig.fromJson(
    _strictMap(json['config'], 'allocation config'),
    expectedGameId: gameId,
  );
  if (config.revision != json['revision']) {
    throw const FormatException('GDevelop allocation config evidence 无效');
  }
  return GDevelopProjectConfigEvidence.ready(
    contentHash: json['contentHash']! as String,
    config: config,
  );
}

Map<String, Object?> _strictMap(Object? value, String name) {
  if (value is! Map) throw FormatException('GDevelop $name 必须是对象');
  return Map<String, Object?>.from(value);
}

void _requireFields(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains)) {
    throw const FormatException('GDevelop allocation 字段无效');
  }
}

String _gameId(Object? value) {
  if (value is! String) throw const FormatException('GDevelop gameId 无效');
  return ProjectProvisioningService.validateGameId(value);
}

String _fileIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw const FormatException('GDevelop fileIdentifier 无效');
  }
  return value;
}

String _projectUuid(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw const FormatException('GDevelop projectUuid 无效');
  }
  return value;
}

String _name(Object? value) {
  if (value is! String) throw const FormatException('GDevelop name 无效');
  return ProjectProvisioningService.validateProjectName(value);
}

String? _optionalToken(Object? value, String field) {
  if (value == null) return null;
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw FormatException('GDevelop allocation $field 无效');
  }
  return value;
}

bool _isHash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String _hash(Object? value, String field) {
  if (!_isHash(value)) throw FormatException('GDevelop allocation $field 无效');
  return value! as String;
}

String _transactionId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw const FormatException('GDevelop allocation txId 无效');
  }
  return value;
}

Future<bool> _journalClaimsTransaction(File file, String txId) async {
  if (!await file.exists()) return false;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('GDevelop allocation journal 无效');
  }
  return decoded['txId'] == txId;
}

Future<bool> _pathExists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

String _basename(String path) =>
    path.split(Platform.pathSeparator).where((item) => item.isNotEmpty).last;

bool _pathEquals(String left, String right) => Platform.isWindows
    ? left.toLowerCase() == right.toLowerCase()
    : left == right;
