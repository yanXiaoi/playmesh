import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../../models/game_id.dart';
import 'foundation/gdevelop_project_mutation_lock.dart';
import 'foundation/pending_project_commit_store.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_config_controller.dart';
import 'gdevelop_project_files.dart';
import 'gdevelop_project_history.dart';
import 'gdevelop_project_root_resolver.dart';
import 'gdevelop_restore_transaction.dart';
import 'project_provisioning_service.dart';

const _rekeyFieldUnchanged = Object();

enum GDevelopProjectRekeyPhase {
  prepared('PREPARED'),
  commitRequested('COMMIT_REQUESTED'),
  newPublished('NEW_PUBLISHED'),
  browserUpdated('BROWSER_UPDATED'),
  rollbackRequested('ROLLBACK_REQUESTED'),
  oldCleaned('OLD_CLEANED'),
  rolledBack('ROLLED_BACK'),
  conflict('CONFLICT'),
  aborted('ABORTED');

  const GDevelopProjectRekeyPhase(this.wireName);
  final String wireName;

  static GDevelopProjectRekeyPhase fromStore(PendingProjectCommitPhase phase) =>
      switch (phase) {
        PendingProjectCommitPhase.prepared => prepared,
        // Rekey 保留 PREPARED→COMMIT_REQUESTED 直达语义，出现该阶段说明 journal 越域。
        PendingProjectCommitPhase.payloadFinalized => throw StateError(
          'GDevelop rekey 不允许 PAYLOAD_FINALIZED phase',
        ),
        PendingProjectCommitPhase.commitRequested => commitRequested,
        PendingProjectCommitPhase.historyApplied => newPublished,
        PendingProjectCommitPhase.backendCommitted => browserUpdated,
        PendingProjectCommitPhase.rollbackRequested => rollbackRequested,
        PendingProjectCommitPhase.browserPersisted => oldCleaned,
        PendingProjectCommitPhase.rolledBack => rolledBack,
        PendingProjectCommitPhase.conflict => conflict,
        PendingProjectCommitPhase.aborted => aborted,
      };
}

class GDevelopProjectRekeyMutationLocked implements Exception {
  const GDevelopProjectRekeyMutationLocked({
    required this.txId,
    required this.phase,
    required this.oldGameId,
    required this.newGameId,
  });

  final String txId;
  final GDevelopProjectRekeyPhase phase;
  final String oldGameId;
  final String newGameId;
}

class GDevelopProjectRekeyOldChanged implements Exception {
  const GDevelopProjectRekeyOldChanged();
}

class GDevelopProjectRekeyAckMismatch implements Exception {
  const GDevelopProjectRekeyAckMismatch();
}

class GDevelopProjectRekeyTargetChanged implements Exception {
  const GDevelopProjectRekeyTargetChanged();
}

class GDevelopProjectRekeyUnavailable implements Exception {
  const GDevelopProjectRekeyUnavailable(this.phase);
  final GDevelopProjectRekeyPhase phase;
}

class GDevelopProjectRekeyIdempotencyConflict implements Exception {
  const GDevelopProjectRekeyIdempotencyConflict(this.idempotencyKey);
  final String idempotencyKey;
}

class GDevelopProjectRekeyNotFound implements Exception {
  const GDevelopProjectRekeyNotFound(this.txId);
  final String txId;
}

class GDevelopProjectRekeyConflict implements Exception {
  const GDevelopProjectRekeyConflict(this.transaction);
  final GDevelopProjectRekeyTransaction transaction;
}

class GDevelopProjectRekeyExpectedEvidence {
  const GDevelopProjectRekeyExpectedEvidence({
    required this.history,
    required this.config,
  });

  final GDevelopRestoreHistoryEvidence history;
  final GDevelopProjectConfigEvidence config;

  Map<String, Object?> toJson() => {
    'history': history.toJson(),
    'config': config.toJson(),
  };

  factory GDevelopProjectRekeyExpectedEvidence.fromJson(
    Object? value, {
    required String gameId,
  }) {
    final json = _strictMap(value, 'rekey expected evidence');
    _requireFields(json, const {'history', 'config'});
    return GDevelopProjectRekeyExpectedEvidence(
      history: GDevelopRestoreHistoryEvidence.fromJson(json['history']),
      config: _configEvidenceFromJson(json['config'], gameId: gameId),
    );
  }

  bool matches(GDevelopProjectRekeyBackendEvidence evidence) =>
      history.matches(evidence.history) && config.matches(evidence.config);
}

class GDevelopProjectRekeyBrowserTarget {
  const GDevelopProjectRekeyBrowserTarget({
    required this.fileIdentifier,
    required this.projectFilesHash,
  });

  final String fileIdentifier;
  final String projectFilesHash;

  Map<String, Object?> toJson() => {
    'fileIdentifier': fileIdentifier,
    'projectFilesHash': projectFilesHash,
  };

  factory GDevelopProjectRekeyBrowserTarget.fromJson(Object? value) {
    final json = _strictMap(value, 'rekey browser target');
    _requireFields(json, const {'fileIdentifier', 'projectFilesHash'});
    final fileIdentifier = json['fileIdentifier'];
    final projectFilesHash = json['projectFilesHash'];
    if (fileIdentifier is! String ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
        ).hasMatch(fileIdentifier) ||
        !_isHash(projectFilesHash)) {
      throw const FormatException('GDevelop rekey browser target 无效');
    }
    return GDevelopProjectRekeyBrowserTarget(
      fileIdentifier: fileIdentifier,
      projectFilesHash: projectFilesHash! as String,
    );
  }
}

class GDevelopProjectRekeyBrowserEvidence {
  const GDevelopProjectRekeyBrowserEvidence({
    required this.fileIdentifier,
    required this.gameId,
    required this.packageName,
    required this.projectFilesHash,
  });

  final String fileIdentifier;
  final String gameId;
  final String packageName;
  final String projectFilesHash;

  Map<String, Object?> toJson() => {
    'fileMetadata': {'fileIdentifier': fileIdentifier, 'gameId': gameId},
    'packageName': packageName,
    'projectFilesHash': projectFilesHash,
  };

  factory GDevelopProjectRekeyBrowserEvidence.fromJson(Object? value) {
    final json = _strictMap(value, 'rekey browser evidence');
    _requireFields(json, const {
      'fileMetadata',
      'packageName',
      'projectFilesHash',
    });
    final metadata = _strictMap(json['fileMetadata'], 'rekey fileMetadata');
    _requireFields(metadata, const {'fileIdentifier', 'gameId'});
    final target = GDevelopProjectRekeyBrowserTarget.fromJson({
      'fileIdentifier': metadata['fileIdentifier'],
      'projectFilesHash': json['projectFilesHash'],
    });
    final gameId = metadata['gameId'];
    final packageName = json['packageName'];
    if (gameId is! String || packageName is! String) {
      throw const FormatException('GDevelop rekey browser evidence 无效');
    }
    return GDevelopProjectRekeyBrowserEvidence(
      fileIdentifier: target.fileIdentifier,
      gameId: ProjectProvisioningService.validateGameId(gameId),
      packageName: ProjectProvisioningService.validateGameId(packageName),
      projectFilesHash: target.projectFilesHash,
    );
  }
}

class GDevelopProjectRekeyBackendEvidence {
  const GDevelopProjectRekeyBackendEvidence({
    required this.projectMetadataHash,
    required this.rootManifestHash,
    required this.history,
    required this.config,
    required this.mainJsonHash,
  });

  final String projectMetadataHash;
  final String rootManifestHash;
  final GDevelopRestoreHistoryEvidence history;
  final GDevelopProjectConfigEvidence config;
  final String? mainJsonHash;

  Map<String, Object?> toJson() => {
    'projectMetadataHash': projectMetadataHash,
    'rootManifestHash': rootManifestHash,
    'history': history.toJson(),
    'config': config.toJson(),
    'mainJsonHash': mainJsonHash,
  };

  factory GDevelopProjectRekeyBackendEvidence.fromJson(
    Object? value, {
    required String gameId,
  }) {
    final json = _strictMap(value, 'rekey backend evidence');
    _requireFields(json, const {
      'projectMetadataHash',
      'rootManifestHash',
      'history',
      'config',
      'mainJsonHash',
    });
    if (!_isHash(json['projectMetadataHash']) ||
        !_isHash(json['rootManifestHash']) ||
        (json['mainJsonHash'] != null && !_isHash(json['mainJsonHash']))) {
      throw const FormatException('GDevelop rekey backend evidence 无效');
    }
    return GDevelopProjectRekeyBackendEvidence(
      projectMetadataHash: json['projectMetadataHash']! as String,
      rootManifestHash: json['rootManifestHash']! as String,
      history: GDevelopRestoreHistoryEvidence.fromJson(json['history']),
      config: _configEvidenceFromJson(json['config'], gameId: gameId),
      mainJsonHash: json['mainJsonHash'] as String?,
    );
  }

  bool matches(GDevelopProjectRekeyBackendEvidence other) =>
      projectMetadataHash == other.projectMetadataHash &&
      rootManifestHash == other.rootManifestHash &&
      history.matches(other.history) &&
      config.matches(other.config) &&
      mainJsonHash == other.mainJsonHash;
}

class GDevelopProjectRekeyPayload {
  const GDevelopProjectRekeyPayload({
    required this.oldGameId,
    required this.newGameId,
    required this.clientId,
    required this.browserSource,
    required this.browserTarget,
    required this.stagingPath,
    required this.tombstonePath,
    required this.oldEvidence,
    required this.targetEvidence,
    required this.grantsMigrated,
    required this.aiSessionsClosed,
    required this.servicesClosed,
    required this.cleanupPending,
    required this.eventEmitted,
    required this.browserRollbackRequired,
    this.browserEvidence,
    this.rollbackBrowserEvidence,
    this.browserUpdatedAt,
    this.cleanupError,
    this.conflict,
  });

  static const schemaVersion = 3;

  final String oldGameId;
  final String newGameId;
  final String? clientId;
  final GDevelopProjectRekeyBrowserTarget browserSource;
  final GDevelopProjectRekeyBrowserTarget browserTarget;
  final String stagingPath;
  final String tombstonePath;
  final GDevelopProjectRekeyBackendEvidence oldEvidence;
  final GDevelopProjectRekeyBackendEvidence targetEvidence;
  final bool grantsMigrated;
  final bool aiSessionsClosed;
  final bool servicesClosed;
  final bool cleanupPending;
  final bool eventEmitted;
  final bool browserRollbackRequired;
  final GDevelopProjectRekeyBrowserEvidence? browserEvidence;
  final GDevelopProjectRekeyBrowserEvidence? rollbackBrowserEvidence;
  final DateTime? browserUpdatedAt;
  final String? cleanupError;
  final Map<String, Object?>? conflict;

  GDevelopProjectRekeyPayload copyWith({
    bool? grantsMigrated,
    bool? aiSessionsClosed,
    bool? servicesClosed,
    bool? cleanupPending,
    bool? eventEmitted,
    bool? browserRollbackRequired,
    GDevelopProjectRekeyBrowserEvidence? browserEvidence,
    GDevelopProjectRekeyBrowserEvidence? rollbackBrowserEvidence,
    DateTime? browserUpdatedAt,
    Object? cleanupError = _rekeyFieldUnchanged,
    Map<String, Object?>? conflict,
  }) => GDevelopProjectRekeyPayload(
    oldGameId: oldGameId,
    newGameId: newGameId,
    clientId: clientId,
    browserSource: browserSource,
    browserTarget: browserTarget,
    stagingPath: stagingPath,
    tombstonePath: tombstonePath,
    oldEvidence: oldEvidence,
    targetEvidence: targetEvidence,
    grantsMigrated: grantsMigrated ?? this.grantsMigrated,
    aiSessionsClosed: aiSessionsClosed ?? this.aiSessionsClosed,
    servicesClosed: servicesClosed ?? this.servicesClosed,
    cleanupPending: cleanupPending ?? this.cleanupPending,
    eventEmitted: eventEmitted ?? this.eventEmitted,
    browserRollbackRequired:
        browserRollbackRequired ?? this.browserRollbackRequired,
    browserEvidence: browserEvidence ?? this.browserEvidence,
    rollbackBrowserEvidence:
        rollbackBrowserEvidence ?? this.rollbackBrowserEvidence,
    browserUpdatedAt: browserUpdatedAt ?? this.browserUpdatedAt,
    cleanupError: identical(cleanupError, _rekeyFieldUnchanged)
        ? this.cleanupError
        : cleanupError as String?,
    conflict: conflict ?? this.conflict,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'oldGameId': oldGameId,
    'newGameId': newGameId,
    'clientId': clientId,
    'browserSource': browserSource.toJson(),
    'browserTarget': browserTarget.toJson(),
    'stagingPath': stagingPath,
    'tombstonePath': tombstonePath,
    'oldEvidence': oldEvidence.toJson(),
    'targetEvidence': targetEvidence.toJson(),
    'grantsMigrated': grantsMigrated,
    'aiSessionsClosed': aiSessionsClosed,
    'servicesClosed': servicesClosed,
    'cleanupPending': cleanupPending,
    'eventEmitted': eventEmitted,
    'browserRollbackRequired': browserRollbackRequired,
    'browserEvidence': browserEvidence?.toJson(),
    'rollbackBrowserEvidence': rollbackBrowserEvidence?.toJson(),
    'browserUpdatedAt': browserUpdatedAt?.toUtc().toIso8601String(),
    'cleanupError': cleanupError,
    'conflict': conflict,
  };

  factory GDevelopProjectRekeyPayload.fromJson(Object? value) {
    final json = _strictMap(value, 'rekey payload');
    _requireFields(json, const {
      'schemaVersion',
      'oldGameId',
      'newGameId',
      'clientId',
      'browserSource',
      'browserTarget',
      'stagingPath',
      'tombstonePath',
      'oldEvidence',
      'targetEvidence',
      'grantsMigrated',
      'aiSessionsClosed',
      'servicesClosed',
      'cleanupPending',
      'eventEmitted',
      'browserRollbackRequired',
      'browserEvidence',
      'rollbackBrowserEvidence',
      'browserUpdatedAt',
      'cleanupError',
      'conflict',
    });
    if (json['schemaVersion'] != schemaVersion ||
        json['oldGameId'] is! String ||
        json['newGameId'] is! String ||
        (json['clientId'] != null && json['clientId'] is! String) ||
        json['stagingPath'] is! String ||
        json['tombstonePath'] is! String ||
        json['grantsMigrated'] is! bool ||
        json['aiSessionsClosed'] is! bool ||
        json['servicesClosed'] is! bool ||
        json['cleanupPending'] is! bool ||
        json['eventEmitted'] is! bool ||
        json['browserRollbackRequired'] is! bool ||
        (json['cleanupError'] != null && json['cleanupError'] is! String) ||
        (json['conflict'] != null && json['conflict'] is! Map)) {
      throw const FormatException('GDevelop rekey payload 无效');
    }
    final oldGameId = ProjectProvisioningService.validateGameId(
      json['oldGameId']! as String,
    );
    final newGameId = ProjectProvisioningService.validateGameId(
      json['newGameId']! as String,
    );
    final updatedAt = json['browserUpdatedAt'];
    final parsedUpdatedAt = updatedAt == null
        ? null
        : DateTime.tryParse(updatedAt as String);
    if (updatedAt != null && parsedUpdatedAt == null) {
      throw const FormatException('GDevelop rekey browserUpdatedAt 无效');
    }
    return GDevelopProjectRekeyPayload(
      oldGameId: oldGameId,
      newGameId: newGameId,
      clientId: json['clientId'] as String?,
      browserSource: GDevelopProjectRekeyBrowserTarget.fromJson(
        json['browserSource'],
      ),
      browserTarget: GDevelopProjectRekeyBrowserTarget.fromJson(
        json['browserTarget'],
      ),
      stagingPath: json['stagingPath']! as String,
      tombstonePath: json['tombstonePath']! as String,
      oldEvidence: GDevelopProjectRekeyBackendEvidence.fromJson(
        json['oldEvidence'],
        gameId: oldGameId,
      ),
      targetEvidence: GDevelopProjectRekeyBackendEvidence.fromJson(
        json['targetEvidence'],
        gameId: newGameId,
      ),
      grantsMigrated: json['grantsMigrated']! as bool,
      aiSessionsClosed: json['aiSessionsClosed']! as bool,
      servicesClosed: json['servicesClosed']! as bool,
      cleanupPending: json['cleanupPending']! as bool,
      eventEmitted: json['eventEmitted']! as bool,
      browserRollbackRequired: json['browserRollbackRequired']! as bool,
      browserEvidence: json['browserEvidence'] == null
          ? null
          : GDevelopProjectRekeyBrowserEvidence.fromJson(
              json['browserEvidence'],
            ),
      rollbackBrowserEvidence: json['rollbackBrowserEvidence'] == null
          ? null
          : GDevelopProjectRekeyBrowserEvidence.fromJson(
              json['rollbackBrowserEvidence'],
            ),
      browserUpdatedAt: parsedUpdatedAt?.toUtc(),
      cleanupError: json['cleanupError'] as String?,
      conflict: json['conflict'] == null
          ? null
          : Map<String, Object?>.from(json['conflict']! as Map),
    );
  }
}

class GDevelopProjectRekeyTransaction {
  const GDevelopProjectRekeyTransaction._(this.record);

  final PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record;

  String get txId => record.txId;
  String get oldGameId => record.payload.oldGameId;
  String get newGameId => record.payload.newGameId;
  GDevelopProjectRekeyPhase get phase =>
      GDevelopProjectRekeyPhase.fromStore(record.phase);

  Map<String, Object?> toJson() => {
    'txId': txId,
    'idempotencyKey': record.idempotencyKey,
    'oldGameId': oldGameId,
    'newGameId': newGameId,
    'phase': phase.wireName,
    'clientId': record.payload.clientId,
    'browserSource': record.payload.browserSource.toJson(),
    'browserTarget': record.payload.browserTarget.toJson(),
    'oldEvidence': record.payload.oldEvidence.toJson(),
    'targetEvidence': record.payload.targetEvidence.toJson(),
    'createdAt': record.createdAt.toUtc().toIso8601String(),
    'updatedAt': record.updatedAt.toUtc().toIso8601String(),
    'expiresAt': record.expiresAt?.toUtc().toIso8601String(),
    'retainedUntil': record.retainedUntil?.toUtc().toIso8601String(),
    'browserEvidence': record.payload.browserEvidence?.toJson(),
    'rollbackBrowserEvidence': record.payload.rollbackBrowserEvidence?.toJson(),
    'cleanupPending': record.payload.cleanupPending,
    'cleanupError': record.payload.cleanupError,
    'conflict': record.payload.conflict,
  };
}

class GDevelopProjectRekeyRecoveryResult {
  const GDevelopProjectRekeyRecoveryResult({
    required this.transaction,
    required this.replayedEventTxIds,
    required this.cleanupPendingTxIds,
  });

  final GDevelopProjectRekeyTransaction? transaction;
  final List<String> replayedEventTxIds;
  final List<String> cleanupPendingTxIds;
}

enum GDevelopProjectRekeyCrashPoint {
  afterPrepared,
  afterCommitRequested,
  afterNewPublished,
  afterBrowserUpdated,
  afterRollbackRequested,
  afterBrowserRollbackRecorded,
  afterNewRollbackCleanup,
  afterRollbackReceipt,
  afterOldTombstoneRename,
  afterReceipt,
  afterGrantsMigrated,
  afterServicesClosed,
  afterTombstoneCleanup,
  afterEvent,
}

enum _GDevelopRekeyLogicalCommitState { preCommit, committed, ambiguous }

typedef GDevelopProjectRekeyCrashHook =
    FutureOr<void> Function(GDevelopProjectRekeyCrashPoint point, String txId);
typedef GDevelopProjectRekeyApprovalMigrator =
    Future<void> Function(String oldGameId, String newGameId);
typedef GDevelopProjectRekeyProjectCloser =
    FutureOr<void> Function(String gameId);
typedef GDevelopProjectRekeyEventSink =
    FutureOr<void> Function(Map<String, Object?> event);
typedef GDevelopProjectRekeyDirectoryDelete =
    Future<void> Function(Directory directory);
typedef GDevelopProjectRekeyMutationGuard =
    Future<void> Function(String gameId);

class GDevelopProjectRekeyCoordinator {
  GDevelopProjectRekeyCoordinator({
    required this.history,
    required this.projectConfig,
    required this.restoreTransactions,
    GDevelopProjectRootResolver? rootResolver,
    GDevelopProjectMutationLock? mutationLock,
    this.approvalMigrator,
    this.closeAiSessions,
    this.stopPreview,
    this.eventSink,
    this.crashHook,
    GDevelopProjectRekeyDirectoryDelete? deleteDirectory,
    this.preparedTtl = const Duration(minutes: 10),
    this.receiptRetention = const Duration(days: 7),
    DateTime Function()? clock,
    String Function()? idFactory,
  }) : rootResolver = rootResolver ?? history.rootResolver,
       mutationLock = mutationLock ?? restoreTransactions.mutationLock,
       deleteDirectory = deleteDirectory ?? _deleteRecursively,
       clock = clock ?? DateTime.now,
       idFactory = idFactory ?? _defaultTransactionId;

  static const namespace = 'gdevelop.rekey.v2';
  static int _sequence = 0;

  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController projectConfig;
  final GDevelopRestoreTransactionCoordinator restoreTransactions;
  final GDevelopProjectRootResolver rootResolver;
  final GDevelopProjectMutationLock mutationLock;
  final GDevelopProjectRekeyApprovalMigrator? approvalMigrator;
  final GDevelopProjectRekeyProjectCloser? closeAiSessions;
  final GDevelopProjectRekeyProjectCloser? stopPreview;
  final GDevelopProjectRekeyEventSink? eventSink;
  final GDevelopProjectRekeyCrashHook? crashHook;
  final GDevelopProjectRekeyDirectoryDelete deleteDirectory;
  final Duration preparedTtl;
  final Duration receiptRetention;
  final DateTime Function() clock;
  final String Function() idFactory;
  final List<GDevelopProjectRekeyMutationGuard> _additionalMutationGuards = [];
  final Map<
    String,
    Future<PendingProjectCommitStore<GDevelopProjectRekeyPayload>>
  >
  _stores = {};

  Future<GDevelopProjectRekeyTransaction> prepare({
    required String oldGameId,
    required String newGameId,
    required String idempotencyKey,
    required GDevelopProjectRekeyExpectedEvidence expectedOldEvidence,
    required GDevelopProjectRekeyBrowserTarget browserSource,
    required GDevelopProjectRekeyBrowserTarget browserTarget,
    String? clientId,
  }) async {
    final oldId = ProjectProvisioningService.validateGameId(oldGameId);
    final newId = ProjectProvisioningService.validateGameId(newGameId);
    if (oldId == newId) throw const FormatException('rekey 新旧 gameId 不能相同');
    final normalizedClientId = _optionalToken(clientId, 'clientId');
    final oldRoot = await rootResolver.projectRootLocation(oldId);
    final newRoot = await rootResolver.projectRootLocation(newId);
    if (browserSource.fileIdentifier != browserTarget.fileIdentifier) {
      throw const FormatException('rekey 浏览器 source/target 必须指向同一项目');
    }
    final requestValue = {
      'newGameId': newId,
      'expectedOldEvidence': expectedOldEvidence.toJson(),
      'browserSource': browserSource.toJson(),
      'browserTarget': browserTarget.toJson(),
      'clientId': normalizedClientId,
    };
    final store = await _store(oldId);
    try {
      final existing = await store.findByIdempotencyKey(
        idempotencyKey: idempotencyKey,
        requestValue: requestValue,
      );
      if (existing != null) return GDevelopProjectRekeyTransaction._(existing);
    } on PendingProjectCommitIdempotencyConflict {
      throw GDevelopProjectRekeyIdempotencyConflict(idempotencyKey);
    }

    return mutationLock.run(
      projectRoots: [oldRoot, newRoot],
      action: () async {
        try {
          final existing = await store.findByIdempotencyKey(
            idempotencyKey: idempotencyKey,
            requestValue: requestValue,
          );
          if (existing != null) {
            return GDevelopProjectRekeyTransaction._(existing);
          }
        } on PendingProjectCommitIdempotencyConflict {
          throw GDevelopProjectRekeyIdempotencyConflict(idempotencyKey);
        }
        await _ensureNoOtherRekey([oldId, newId]);
        await restoreTransactions.ensureNoActiveRestore(oldId);
        await restoreTransactions.ensureNoActiveRestore(newId);
        if (await _pathExists(newRoot.path)) {
          throw ProjectProvisioningConflict(
            gameId: newId,
            requestedKind: PlaymeshProjectKind.gdevelop,
          );
        }
        final oldEvidence = await _inspectProject(oldId, oldRoot);
        if (!expectedOldEvidence.matches(oldEvidence)) {
          throw const GDevelopProjectRekeyOldChanged();
        }

        final staging = await _stagingRoot(
          oldRoot: oldRoot,
          newGameId: newId,
          idempotencyKey: idempotencyKey,
        );
        final tombstone = await _tombstoneRoot(
          oldRoot: oldRoot,
          newGameId: newId,
          idempotencyKey: idempotencyKey,
        );
        var durablePrepared = false;
        try {
          if (await staging.exists()) await deleteDirectory(staging);
          if (await _pathExists(tombstone.path)) {
            throw const FormatException('rekey tombstone 已被占用');
          }
          await _copyDirectory(oldRoot, staging);
          await _rewriteStagingIdentity(
            staging: staging,
            oldGameId: oldId,
            newGameId: newId,
          );
          final targetEvidence = await _inspectStaging(
            staging: staging,
            newGameId: newId,
          );
          final verifiedOld = await _inspectProject(oldId, oldRoot);
          if (!oldEvidence.matches(verifiedOld) ||
              await _pathExists(newRoot.path)) {
            if (await _pathExists(newRoot.path)) {
              throw ProjectProvisioningConflict(
                gameId: newId,
                requestedKind: PlaymeshProjectKind.gdevelop,
              );
            }
            throw const GDevelopProjectRekeyOldChanged();
          }
          final payload = GDevelopProjectRekeyPayload(
            oldGameId: oldId,
            newGameId: newId,
            clientId: normalizedClientId,
            browserSource: browserSource,
            browserTarget: browserTarget,
            stagingPath: staging.path,
            tombstonePath: tombstone.path,
            oldEvidence: oldEvidence,
            targetEvidence: targetEvidence,
            grantsMigrated: false,
            aiSessionsClosed: false,
            servicesClosed: false,
            cleanupPending: false,
            eventEmitted: false,
            browserRollbackRequired: false,
          );
          final prepared = await store.prepare(
            gameId: oldId,
            idempotencyKey: idempotencyKey,
            payload: payload,
            requestValue: requestValue,
          );
          durablePrepared = true;
          await _crash(
            GDevelopProjectRekeyCrashPoint.afterPrepared,
            prepared.txId,
          );
          return GDevelopProjectRekeyTransaction._(prepared);
        } on PendingProjectCommitIdempotencyConflict {
          throw GDevelopProjectRekeyIdempotencyConflict(idempotencyKey);
        } on PendingProjectCommitLocked catch (error) {
          throw await _lockedFromStore(error, store);
        } finally {
          if (!durablePrepared && await staging.exists()) {
            await deleteDirectory(staging);
          }
        }
      },
    );
  }

  Future<GDevelopProjectRekeyTransaction> commit({
    required String oldGameId,
    required String txId,
  }) async {
    final store = await _store(oldGameId);
    final initial = await _statusRecord(store, txId);
    return _withTransactionRoots(initial.payload, () async {
      final current = await _statusRecord(store, txId);
      final driven = await _drive(store, current, startCommit: true);
      return GDevelopProjectRekeyTransaction._(driven);
    });
  }

  Future<GDevelopProjectRekeyTransaction> status({
    required String oldGameId,
    required String txId,
  }) async => GDevelopProjectRekeyTransaction._(
    await _statusRecord(await _store(oldGameId), txId),
  );

  Future<GDevelopProjectRekeyTransaction> acknowledge({
    required String oldGameId,
    required String txId,
    required GDevelopProjectRekeyBrowserEvidence browserEvidence,
  }) async {
    final store = await _store(oldGameId);
    final initial = await _statusRecord(store, txId);
    return _withTransactionRoots(initial.payload, () async {
      var record = await _statusRecord(store, txId);
      if (record.phase == PendingProjectCommitPhase.browserPersisted) {
        final persisted = record.payload.browserEvidence;
        if (persisted == null ||
            !_browserEvidenceMatches(persisted, browserEvidence)) {
          throw const GDevelopProjectRekeyAckMismatch();
        }
        record = await _runPostCommitCleanup(store, record);
        record = await _emitReceiptIfNeeded(store, record);
        return GDevelopProjectRekeyTransaction._(record);
      }
      if (record.phase == PendingProjectCommitPhase.backendCommitted) {
        final persisted = record.payload.browserEvidence;
        if (persisted == null ||
            !_browserEvidenceMatches(persisted, browserEvidence)) {
          throw const GDevelopProjectRekeyAckMismatch();
        }
        record = await _finalizeBrowserUpdated(store, record);
        return GDevelopProjectRekeyTransaction._(record);
      }
      if (record.phase != PendingProjectCommitPhase.historyApplied) {
        throw GDevelopProjectRekeyUnavailable(
          GDevelopProjectRekeyPhase.fromStore(record.phase),
        );
      }
      final payload = record.payload;
      if (browserEvidence.fileIdentifier !=
              payload.browserTarget.fileIdentifier ||
          browserEvidence.gameId != payload.newGameId ||
          browserEvidence.packageName != payload.newGameId ||
          browserEvidence.projectFilesHash !=
              payload.browserTarget.projectFilesHash) {
        throw const GDevelopProjectRekeyAckMismatch();
      }
      if (!await _projectEvidenceMatches(
        gameId: payload.newGameId,
        root: await rootResolver.projectRootLocation(payload.newGameId),
        expected: payload.targetEvidence,
      )) {
        throw const GDevelopProjectRekeyTargetChanged();
      }
      record = await store.advance(
        txId: txId,
        phase: PendingProjectCommitPhase.backendCommitted,
        payload: payload.copyWith(
          browserEvidence: browserEvidence,
          browserUpdatedAt: clock().toUtc(),
        ),
      );
      await _crash(GDevelopProjectRekeyCrashPoint.afterBrowserUpdated, txId);
      record = await _finalizeBrowserUpdated(store, record);
      return GDevelopProjectRekeyTransaction._(record);
    });
  }

  /// 请求撤销尚未越过旧根墓碑 rename 提交点的 rekey。
  ///
  /// 浏览器曾切到新身份时，调用方必须先在同一 IndexedDB 事务中反向切回，
  /// 再把 source evidence 传入；缺少 evidence 时事务停在 ROLLBACK_REQUESTED。
  Future<GDevelopProjectRekeyTransaction> rollback({
    required String oldGameId,
    required String txId,
    GDevelopProjectRekeyBrowserEvidence? browserEvidence,
  }) async {
    final store = await _store(oldGameId);
    final initial = await _statusRecord(store, txId);
    return _withTransactionRoots(initial.payload, () async {
      var record = await _statusRecord(store, txId);
      if (record.phase == PendingProjectCommitPhase.rolledBack) {
        if (browserEvidence != null &&
            !_sourceBrowserEvidenceMatches(record.payload, browserEvidence)) {
          throw const GDevelopProjectRekeyAckMismatch();
        }
        return GDevelopProjectRekeyTransaction._(record);
      }
      if (record.phase == PendingProjectCommitPhase.browserPersisted) {
        throw const GDevelopProjectRekeyUnavailable(
          GDevelopProjectRekeyPhase.oldCleaned,
        );
      }
      if (browserEvidence != null) {
        if (!_sourceBrowserEvidenceMatches(record.payload, browserEvidence)) {
          throw const GDevelopProjectRekeyAckMismatch();
        }
        final persisted = record.payload.rollbackBrowserEvidence;
        if (persisted != null &&
            !_browserEvidenceMatches(persisted, browserEvidence)) {
          throw const GDevelopProjectRekeyAckMismatch();
        }
        if (persisted == null &&
            record.phase == PendingProjectCommitPhase.rollbackRequested) {
          record = await store.updateActive(
            txId: txId,
            payload: record.payload.copyWith(
              rollbackBrowserEvidence: browserEvidence,
            ),
          );
          await _crash(
            GDevelopProjectRekeyCrashPoint.afterBrowserRollbackRecorded,
            txId,
          );
        }
      }
      if (record.phase != PendingProjectCommitPhase.rollbackRequested) {
        final rollbackRequired =
            record.phase == PendingProjectCommitPhase.historyApplied ||
            record.phase == PendingProjectCommitPhase.backendCommitted;
        if (record.phase != PendingProjectCommitPhase.commitRequested &&
            !rollbackRequired) {
          throw GDevelopProjectRekeyUnavailable(
            GDevelopProjectRekeyPhase.fromStore(record.phase),
          );
        }
        record = await _requestRollback(
          store,
          record,
          browserRollbackRequired: rollbackRequired,
          browserEvidence: browserEvidence,
        );
      }
      record = await _driveRollback(store, record);
      return GDevelopProjectRekeyTransaction._(record);
    });
  }

  Future<GDevelopProjectRekeyRecoveryResult> recover(String oldGameId) async {
    final store = await _store(oldGameId);
    var active = await store.active();
    if (active != null) {
      active = await _withTransactionRoots(active.payload, () async {
        var current = await _statusRecord(store, active!.txId);
        switch (current.phase) {
          case PendingProjectCommitPhase.prepared:
            final staging = Directory(current.payload.stagingPath);
            if (await staging.exists()) await deleteDirectory(staging);
            return store.abortPrepared(current.txId);
          case PendingProjectCommitPhase.commitRequested:
            current = await _requestRollback(
              store,
              current,
              browserRollbackRequired: false,
            );
            return _driveRollback(store, current);
          case PendingProjectCommitPhase.historyApplied:
            current = await _requestRollback(
              store,
              current,
              browserRollbackRequired: true,
            );
            return _driveRollback(store, current);
          case PendingProjectCommitPhase.backendCommitted:
            final state = await _logicalCommitState(current.payload);
            if (state == _GDevelopRekeyLogicalCommitState.committed) {
              return _finalizeBrowserUpdated(store, current);
            }
            if (state == _GDevelopRekeyLogicalCommitState.preCommit) {
              current = await _requestRollback(
                store,
                current,
                browserRollbackRequired: true,
              );
              return _driveRollback(store, current);
            }
            return _markConflict(
              store,
              current,
              reason: 'logical_commit_state_ambiguous',
            );
          case PendingProjectCommitPhase.rollbackRequested:
            return _driveRollback(store, current);
          case PendingProjectCommitPhase.conflict:
            return current;
          case PendingProjectCommitPhase.payloadFinalized ||
              PendingProjectCommitPhase.browserPersisted ||
              PendingProjectCommitPhase.rolledBack ||
              PendingProjectCommitPhase.aborted:
            throw StateError('GDevelop rekey active journal phase 越域');
        }
      });
    }
    final replayed = await _recoverReceipts(store);
    final cleanupPending = <String>{
      if (active?.payload.cleanupPending ?? false) active!.txId,
      for (final receipt in await store.receipts())
        if (receipt.payload.cleanupPending) receipt.txId,
    }.toList()..sort();
    return GDevelopProjectRekeyRecoveryResult(
      transaction: active == null
          ? null
          : GDevelopProjectRekeyTransaction._(active),
      replayedEventTxIds: List.unmodifiable(replayed),
      cleanupPendingTxIds: List.unmodifiable(cleanupPending),
    );
  }

  Future<GDevelopProjectRekeyTransaction> abort({
    required String oldGameId,
    required String txId,
  }) async {
    final store = await _store(oldGameId);
    final initial = await _statusRecord(store, txId);
    return _withTransactionRoots(initial.payload, () async {
      final current = await _statusRecord(store, txId);
      if (current.payload.grantsMigrated ||
          current.payload.aiSessionsClosed ||
          current.payload.servicesClosed) {
        throw GDevelopProjectRekeyUnavailable(
          GDevelopProjectRekeyPhase.fromStore(current.phase),
        );
      }
      final staging = Directory(current.payload.stagingPath);
      if (await staging.exists()) await deleteDirectory(staging);
      final aborted = switch (current.phase) {
        PendingProjectCommitPhase.prepared => await store.abortPrepared(txId),
        PendingProjectCommitPhase.conflict => await store.abortConflict(txId),
        PendingProjectCommitPhase.aborted => current,
        _ => throw GDevelopProjectRekeyUnavailable(
          GDevelopProjectRekeyPhase.fromStore(current.phase),
        ),
      };
      return GDevelopProjectRekeyTransaction._(aborted);
    });
  }

  Future<void> ensureMutationAllowed(String gameId) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    final root = await _transactionsRoot(normalized);
    if (!await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final oldId = _basename(entity.path);
      try {
        ProjectProvisioningService.validateGameId(oldId);
      } on FormatException {
        continue;
      }
      final store = await _store(oldId);
      final active = await store.active();
      if (active != null &&
          (active.payload.oldGameId == normalized ||
              active.payload.newGameId == normalized)) {
        final onlyOldCleanupRemains =
            active.phase == PendingProjectCommitPhase.backendCommitted &&
            active.payload.grantsMigrated &&
            active.payload.aiSessionsClosed &&
            active.payload.servicesClosed &&
            active.payload.cleanupPending;
        if (onlyOldCleanupRemains && active.payload.newGameId == normalized) {
          continue;
        }
        throw GDevelopProjectRekeyMutationLocked(
          txId: active.txId,
          phase: GDevelopProjectRekeyPhase.fromStore(active.phase),
          oldGameId: active.payload.oldGameId,
          newGameId: active.payload.newGameId,
        );
      }
      if (oldId == normalized) {
        for (final receipt in await store.receipts()) {
          if (receipt.payload.cleanupPending) {
            throw GDevelopProjectRekeyMutationLocked(
              txId: receipt.txId,
              phase: GDevelopProjectRekeyPhase.oldCleaned,
              oldGameId: receipt.payload.oldGameId,
              newGameId: receipt.payload.newGameId,
            );
          }
        }
      }
    }
  }

  void registerMutationGuard(GDevelopProjectRekeyMutationGuard guard) {
    if (!_additionalMutationGuards.contains(guard)) {
      _additionalMutationGuards.add(guard);
    }
  }

  /// 以规范项目根为粒度冻结发布等身份相关写入，不要求目标已经存在。
  Future<T> runIdentityMutation<T>(
    String gameId,
    Future<T> Function() action,
  ) async {
    late final String normalized;
    try {
      normalized = ProjectProvisioningService.validateGameId(gameId);
    } on FormatException {
      // 非 GDevelop 项目标识不可能参与 rekey，不改变原有通用发布行为。
      return action();
    }
    final root = await rootResolver.projectRootLocation(normalized);
    return mutationLock.run(
      projectRoots: [root],
      action: () async {
        await ensureMutationAllowed(normalized);
        await _ensureAdditionalMutationsAllowed([normalized]);
        return action();
      },
    );
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>> _drive(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record, {
    required bool startCommit,
  }) async {
    if (record.phase == PendingProjectCommitPhase.prepared) {
      if (!startCommit) return record;
      final oldRoot = await rootResolver.projectRootLocation(
        record.payload.oldGameId,
      );
      final newRoot = await rootResolver.projectRootLocation(
        record.payload.newGameId,
      );
      final staging = Directory(record.payload.stagingPath);
      final targetOccupied = await _pathExists(newRoot.path);
      final oldMatches = await _projectEvidenceMatches(
        gameId: record.payload.oldGameId,
        root: oldRoot,
        expected: record.payload.oldEvidence,
      );
      final stagingMatches = await _stagingEvidenceMatches(
        staging: staging,
        newGameId: record.payload.newGameId,
        expected: record.payload.targetEvidence,
      );
      if (targetOccupied || !oldMatches || !stagingMatches) {
        return _markConflict(
          store,
          record,
          reason: targetOccupied
              ? 'target_became_occupied'
              : !oldMatches
              ? 'old_changed_before_commit'
              : 'staging_changed_before_commit',
        );
      }
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.commitRequested,
        payload: record.payload,
      );
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterCommitRequested,
        record.txId,
      );
    }

    if (record.phase == PendingProjectCommitPhase.commitRequested) {
      var payload = record.payload;
      final oldRoot = await rootResolver.projectRootLocation(payload.oldGameId);
      final newRoot = await rootResolver.projectRootLocation(payload.newGameId);
      final staging = Directory(payload.stagingPath);
      if (await _pathExists(newRoot.path)) {
        history.releaseProjectCaches([payload.oldGameId, payload.newGameId]);
      } else {
        final oldMatches = await _projectEvidenceMatches(
          gameId: payload.oldGameId,
          root: oldRoot,
          expected: payload.oldEvidence,
        );
        final stagingMatches = await _stagingEvidenceMatches(
          staging: staging,
          newGameId: payload.newGameId,
          expected: payload.targetEvidence,
        );
        if (!oldMatches || !stagingMatches) {
          return _markConflict(
            store,
            record,
            reason: 'commit_source_or_staging_changed',
          );
        }
        await _renameDirectoryWithRetry(staging, newRoot.path);
        history.releaseProjectCaches([payload.oldGameId, payload.newGameId]);
      }
      if (!await _projectEvidenceMatches(
        gameId: payload.newGameId,
        root: newRoot,
        expected: payload.targetEvidence,
      )) {
        return _markConflict(
          store,
          record,
          reason: 'published_target_mismatch',
        );
      }
      record = await store.advance(
        txId: record.txId,
        phase: PendingProjectCommitPhase.historyApplied,
        payload: payload,
      );
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterNewPublished,
        record.txId,
      );
    }

    if (record.phase == PendingProjectCommitPhase.backendCommitted) {
      record = await _finalizeBrowserUpdated(store, record);
    }
    return record;
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>>
  _finalizeBrowserUpdated(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record,
  ) async {
    var payload = record.payload;
    if (record.phase != PendingProjectCommitPhase.backendCommitted ||
        payload.browserEvidence == null) {
      throw GDevelopProjectRekeyUnavailable(
        GDevelopProjectRekeyPhase.fromStore(record.phase),
      );
    }
    final oldRoot = await rootResolver.projectRootLocation(payload.oldGameId);
    final newRoot = await rootResolver.projectRootLocation(payload.newGameId);
    if (!await _projectEvidenceMatches(
      gameId: payload.newGameId,
      root: newRoot,
      expected: payload.targetEvidence,
    )) {
      return _markConflict(
        store,
        record,
        reason: 'target_changed_before_logical_commit',
      );
    }
    var logicalState = await _logicalCommitState(payload);
    if (logicalState == _GDevelopRekeyLogicalCommitState.ambiguous) {
      return _markConflict(
        store,
        record,
        reason: 'logical_commit_state_ambiguous',
      );
    }
    if (logicalState == _GDevelopRekeyLogicalCommitState.preCommit) {
      final tombstone = Directory(payload.tombstonePath);
      history.releaseProjectCaches([payload.oldGameId, payload.newGameId]);
      await _renameDirectoryWithRetry(oldRoot, tombstone.path);
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterOldTombstoneRename,
        record.txId,
      );
      logicalState = await _logicalCommitState(payload);
      if (logicalState != _GDevelopRekeyLogicalCommitState.committed) {
        return _markConflict(
          store,
          record,
          reason: 'tombstone_evidence_mismatch',
        );
      }
    }
    // 旧根进入墓碑后身份已经逻辑提交；此时立即撤销旧 gameId 的 AI lease、
    // 审批与执行，回滚路径则绝不能提前关闭仍有效的编辑器会话。
    var cleanupError = 'post_commit_cleanup_pending';
    var aiSessionsClosed = false;
    try {
      await closeAiSessions?.call(payload.oldGameId);
      aiSessionsClosed = true;
    } on Object {
      // 身份提交点不可回滚；关闭失败进入 receipt cleanup，由 recover 幂等重试。
      cleanupError = 'service_cleanup_pending';
    }
    payload = payload.copyWith(
      cleanupPending: true,
      cleanupError: cleanupError,
      aiSessionsClosed: aiSessionsClosed,
    );
    record = await store.complete(txId: record.txId, payload: payload);
    await _crash(GDevelopProjectRekeyCrashPoint.afterReceipt, record.txId);
    record = await _runPostCommitCleanup(
      store,
      record,
      retryServices: payload.aiSessionsClosed,
    );
    return _emitReceiptIfNeeded(store, record);
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>>
  _requestRollback(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record, {
    required bool browserRollbackRequired,
    GDevelopProjectRekeyBrowserEvidence? browserEvidence,
  }) async {
    if (record.phase != PendingProjectCommitPhase.commitRequested &&
        record.phase != PendingProjectCommitPhase.historyApplied &&
        record.phase != PendingProjectCommitPhase.backendCommitted) {
      throw GDevelopProjectRekeyUnavailable(
        GDevelopProjectRekeyPhase.fromStore(record.phase),
      );
    }
    final payload = record.payload;
    final state = await _logicalCommitState(payload);
    if (state != _GDevelopRekeyLogicalCommitState.preCommit) {
      return _markConflict(
        store,
        record,
        reason: state == _GDevelopRekeyLogicalCommitState.committed
            ? 'rollback_after_logical_commit'
            : 'rollback_old_evidence_ambiguous',
      );
    }
    final newRoot = await rootResolver.projectRootLocation(payload.newGameId);
    final staging = Directory(payload.stagingPath);
    if (record.phase == PendingProjectCommitPhase.commitRequested) {
      final newExists = await _pathExists(newRoot.path);
      final stagingExists = await staging.exists();
      if (newExists == stagingExists ||
          (newExists &&
              !await _projectEvidenceMatches(
                gameId: payload.newGameId,
                root: newRoot,
                expected: payload.targetEvidence,
              )) ||
          (stagingExists &&
              !await _stagingEvidenceMatches(
                staging: staging,
                newGameId: payload.newGameId,
                expected: payload.targetEvidence,
              ))) {
        return _markConflict(
          store,
          record,
          reason: 'rollback_commit_artifacts_ambiguous',
        );
      }
    } else if (!await _projectEvidenceMatches(
      gameId: payload.newGameId,
      root: newRoot,
      expected: payload.targetEvidence,
    )) {
      return _markConflict(
        store,
        record,
        reason: 'rollback_target_evidence_mismatch',
      );
    }
    record = await store.requestRollback(
      txId: record.txId,
      payload: payload.copyWith(
        browserRollbackRequired: browserRollbackRequired,
        rollbackBrowserEvidence: browserEvidence,
        cleanupPending: false,
        cleanupError: null,
      ),
    );
    await _crash(
      GDevelopProjectRekeyCrashPoint.afterRollbackRequested,
      record.txId,
    );
    if (browserEvidence != null) {
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterBrowserRollbackRecorded,
        record.txId,
      );
    }
    return record;
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>>
  _driveRollback(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record,
  ) async {
    if (record.phase == PendingProjectCommitPhase.conflict ||
        record.phase == PendingProjectCommitPhase.rolledBack) {
      return record;
    }
    if (record.phase != PendingProjectCommitPhase.rollbackRequested) {
      throw GDevelopProjectRekeyUnavailable(
        GDevelopProjectRekeyPhase.fromStore(record.phase),
      );
    }
    final payload = record.payload;
    if (payload.browserRollbackRequired &&
        payload.rollbackBrowserEvidence == null) {
      return record;
    }
    final rollbackEvidence = payload.rollbackBrowserEvidence;
    if (rollbackEvidence != null &&
        !_sourceBrowserEvidenceMatches(payload, rollbackEvidence)) {
      return _markConflict(
        store,
        record,
        reason: 'rollback_browser_evidence_mismatch',
      );
    }
    final state = await _logicalCommitState(payload);
    if (state != _GDevelopRekeyLogicalCommitState.preCommit) {
      return _markConflict(
        store,
        record,
        reason: state == _GDevelopRekeyLogicalCommitState.committed
            ? 'rollback_crossed_logical_commit'
            : 'rollback_old_evidence_ambiguous',
      );
    }
    final newRoot = await rootResolver.projectRootLocation(payload.newGameId);
    if (await _pathExists(newRoot.path)) {
      history.releaseProjectCaches([payload.oldGameId, payload.newGameId]);
      await deleteDirectory(newRoot);
    }
    final staging = Directory(payload.stagingPath);
    if (await staging.exists()) await deleteDirectory(staging);
    await _crash(
      GDevelopProjectRekeyCrashPoint.afterNewRollbackCleanup,
      record.txId,
    );
    record = await store.completeRollback(
      txId: record.txId,
      payload: payload.copyWith(cleanupPending: false, cleanupError: null),
    );
    await _crash(
      GDevelopProjectRekeyCrashPoint.afterRollbackReceipt,
      record.txId,
    );
    return record;
  }

  Future<_GDevelopRekeyLogicalCommitState> _logicalCommitState(
    GDevelopProjectRekeyPayload payload,
  ) async {
    final oldRoot = await rootResolver.projectRootLocation(payload.oldGameId);
    final tombstone = Directory(payload.tombstonePath);
    final oldExists = await _pathExists(oldRoot.path);
    final tombstoneExists = await _pathExists(tombstone.path);
    if (oldExists && !tombstoneExists) {
      return await _projectEvidenceMatches(
            gameId: payload.oldGameId,
            root: oldRoot,
            expected: payload.oldEvidence,
          )
          ? _GDevelopRekeyLogicalCommitState.preCommit
          : _GDevelopRekeyLogicalCommitState.ambiguous;
    }
    if (!oldExists && tombstoneExists) {
      return await _detachedProjectEvidenceMatches(
            gameId: payload.oldGameId,
            root: tombstone,
            expected: payload.oldEvidence,
          )
          ? _GDevelopRekeyLogicalCommitState.committed
          : _GDevelopRekeyLogicalCommitState.ambiguous;
    }
    return _GDevelopRekeyLogicalCommitState.ambiguous;
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>>
  _runPostCommitCleanup(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> receipt, {
    bool retryServices = true,
  }) async {
    if (receipt.phase != PendingProjectCommitPhase.browserPersisted) {
      return receipt;
    }
    var payload = receipt.payload;
    if (!payload.grantsMigrated) {
      try {
        await approvalMigrator?.call(payload.oldGameId, payload.newGameId);
      } on Object {
        return store.updateReceipt(
          txId: receipt.txId,
          payload: payload.copyWith(
            cleanupPending: true,
            cleanupError: 'approval_migration_pending',
          ),
        );
      }
      payload = payload.copyWith(grantsMigrated: true);
      receipt = await store.updateReceipt(txId: receipt.txId, payload: payload);
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterGrantsMigrated,
        receipt.txId,
      );
    }
    if (!payload.aiSessionsClosed) {
      if (!retryServices) return receipt;
      try {
        await closeAiSessions?.call(payload.oldGameId);
      } on Object {
        return store.updateReceipt(
          txId: receipt.txId,
          payload: payload.copyWith(
            cleanupPending: true,
            cleanupError: 'service_cleanup_pending',
          ),
        );
      }
      payload = payload.copyWith(aiSessionsClosed: true);
      receipt = await store.updateReceipt(txId: receipt.txId, payload: payload);
    }
    if (!payload.servicesClosed) {
      try {
        await stopPreview?.call(payload.oldGameId);
      } on Object {
        return store.updateReceipt(
          txId: receipt.txId,
          payload: payload.copyWith(
            cleanupPending: true,
            cleanupError: 'service_cleanup_pending',
          ),
        );
      }
      payload = payload.copyWith(servicesClosed: true);
      receipt = await store.updateReceipt(txId: receipt.txId, payload: payload);
      await _crash(
        GDevelopProjectRekeyCrashPoint.afterServicesClosed,
        receipt.txId,
      );
    }
    final tombstone = Directory(payload.tombstonePath);
    try {
      if (await tombstone.exists()) await deleteDirectory(tombstone);
    } on Object {
      return store.updateReceipt(
        txId: receipt.txId,
        payload: payload.copyWith(
          cleanupPending: true,
          cleanupError: 'tombstone_cleanup_pending',
        ),
      );
    }
    await _crash(
      GDevelopProjectRekeyCrashPoint.afterTombstoneCleanup,
      receipt.txId,
    );
    payload = payload.copyWith(cleanupPending: false, cleanupError: null);
    return store.updateReceipt(txId: receipt.txId, payload: payload);
  }

  Future<List<String>> _recoverReceipts(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
  ) async {
    final replayed = <String>[];
    for (var receipt in await store.receipts()) {
      if (receipt.phase != PendingProjectCommitPhase.browserPersisted) continue;
      if (receipt.payload.cleanupPending) {
        receipt = await _runPostCommitCleanup(store, receipt);
      }
      if (!receipt.payload.eventEmitted) {
        await _emitReceiptIfNeeded(store, receipt);
        replayed.add(receipt.txId);
      }
    }
    return replayed;
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>>
  _emitReceiptIfNeeded(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> receipt,
  ) async {
    if (receipt.payload.eventEmitted ||
        receipt.phase != PendingProjectCommitPhase.browserPersisted) {
      return receipt;
    }
    await eventSink?.call({
      'type': 'gdevelop.project.rekeyed',
      'txId': receipt.txId,
      'oldGameId': receipt.payload.oldGameId,
      'newGameId': receipt.payload.newGameId,
      'cleanupPending': receipt.payload.cleanupPending,
      'clientId': receipt.payload.clientId,
      'timestamp': clock().toUtc().millisecondsSinceEpoch,
    });
    await _crash(GDevelopProjectRekeyCrashPoint.afterEvent, receipt.txId);
    return store.updateReceipt(
      txId: receipt.txId,
      payload: receipt.payload.copyWith(eventEmitted: true),
    );
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>> _markConflict(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    PendingProjectCommitRecord<GDevelopProjectRekeyPayload> record, {
    required String reason,
  }) => store.markConflict(
    txId: record.txId,
    payload: record.payload.copyWith(
      conflict: {
        'reason': reason,
        'observedAt': clock().toUtc().toIso8601String(),
      },
    ),
  );

  Future<GDevelopProjectRekeyBackendEvidence> _inspectProject(
    String gameId,
    Directory root,
  ) async {
    if (!await root.exists()) throw ProjectProvisioningMissing(gameId);
    final metadata = File(
      '${root.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    final metadataJson = await _readProjectMetadata(metadata, gameId: gameId);
    if (metadataJson['kind'] != PlaymeshProjectKind.gdevelop.wireName) {
      throw ProjectProvisioningConflict(
        gameId: gameId,
        requestedKind: PlaymeshProjectKind.gdevelop,
      );
    }
    final current = await history.currentReferenceSnapshot(gameId);
    if (current == null) throw const GDevelopHistoryRevisionNotFound(0);
    final config = await projectConfig.inspect(gameId);
    if (config.status == GDevelopProjectConfigStatus.invalid) {
      throw const GDevelopProjectConfigInvalidState();
    }
    final main = File('${root.path}${Platform.pathSeparator}main.json');
    String? mainHash;
    if (await main.exists()) {
      await _readMainJson(main, expectedGameId: gameId);
      mainHash = await _hashFile(main);
    }
    return GDevelopProjectRekeyBackendEvidence(
      projectMetadataHash: await _hashFile(metadata),
      rootManifestHash: await _treeManifestHash(root),
      history: await _historyEvidence(current),
      config: config,
      mainJsonHash: mainHash,
    );
  }

  Future<bool> _projectEvidenceMatches({
    required String gameId,
    required Directory root,
    required GDevelopProjectRekeyBackendEvidence expected,
  }) async {
    try {
      final observed = await _inspectProject(gameId, root);
      return expected.matches(observed);
    } on Object {
      return false;
    }
  }

  Future<bool> _detachedProjectEvidenceMatches({
    required String gameId,
    required Directory root,
    required GDevelopProjectRekeyBackendEvidence expected,
  }) async {
    if (!await root.exists()) return false;
    try {
      final metadata = File(
        '${root.path}${Platform.pathSeparator}.playmesh'
        '${Platform.pathSeparator}project.json',
      );
      await _readProjectMetadata(metadata, gameId: gameId);
      if (await _hashFile(metadata) != expected.projectMetadataHash ||
          await _treeManifestHash(root) != expected.rootManifestHash) {
        return false;
      }
      final config = await _inspectConfigFile(
        _configFile(root),
        gameId: gameId,
      );
      if (!expected.config.matches(config)) return false;
      final main = File('${root.path}${Platform.pathSeparator}main.json');
      String? mainHash;
      if (await main.exists()) {
        await _readMainJson(main, expectedGameId: gameId);
        mainHash = await _hashFile(main);
      }
      return mainHash == expected.mainJsonHash;
    } on Object {
      return false;
    }
  }

  Future<bool> _stagingEvidenceMatches({
    required Directory staging,
    required String newGameId,
    required GDevelopProjectRekeyBackendEvidence expected,
  }) async {
    if (!await staging.exists()) return false;
    try {
      return expected.matches(
        await _inspectStaging(staging: staging, newGameId: newGameId),
      );
    } on Object {
      return false;
    }
  }

  Future<GDevelopProjectRekeyBackendEvidence> _inspectStaging({
    required Directory staging,
    required String newGameId,
  }) async {
    final metadata = File(
      '${staging.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    await _readProjectMetadata(metadata, gameId: newGameId);
    final configFile = _configFile(staging);
    final config = await _inspectConfigFile(configFile, gameId: newGameId);
    final main = File('${staging.path}${Platform.pathSeparator}main.json');
    String? mainHash;
    if (await main.exists()) {
      await _readMainJson(main, expectedGameId: newGameId);
      mainHash = await _hashFile(main);
    }
    return GDevelopProjectRekeyBackendEvidence(
      projectMetadataHash: await _hashFile(metadata),
      rootManifestHash: await _treeManifestHash(staging),
      history: await _inspectDirectCurrentEvidence(staging, newGameId),
      config: config,
      mainJsonHash: mainHash,
    );
  }

  Future<GDevelopRestoreHistoryEvidence> _inspectDirectCurrentEvidence(
    Directory projectRoot,
    String gameId,
  ) async {
    final manifestFile = File(
      '${projectRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}source'
      '${Platform.pathSeparator}current${Platform.pathSeparator}manifest.json',
    );
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map ||
        decoded['schemaVersion'] != 3 ||
        decoded['gameId'] != gameId ||
        decoded['revision'] is! int ||
        decoded['contentHash'] is! String ||
        decoded['projectFilesHash'] is! String ||
        decoded['resources'] is! List) {
      throw const FormatException('GDevelop current manifest evidence 无效');
    }
    return GDevelopRestoreHistoryEvidence(
      revision: decoded['revision']! as int,
      currentContentHash: decoded['contentHash']! as String,
      projectFilesHash: decoded['projectFilesHash']! as String,
      resourceManifestHash: await _hashJson(decoded['resources']),
    );
  }

  Future<void> _rewriteStagingIdentity({
    required Directory staging,
    required String oldGameId,
    required String newGameId,
  }) async {
    final metadataFile = File(
      '${staging.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    final metadata = await _readProjectMetadata(
      metadataFile,
      gameId: oldGameId,
    );
    final previous = <String>{oldGameId};
    final rawPrevious = metadata['previousGameIds'];
    if (rawPrevious != null) {
      if (rawPrevious is! List) {
        throw const FormatException('GDevelop 历史身份别名无效');
      }
      for (final value in rawPrevious) {
        if (value is! String) {
          throw const FormatException('GDevelop 历史身份别名无效');
        }
        previous.add(ProjectProvisioningService.validateGameId(value));
      }
    }
    final sortedPrevious = previous.toList()..sort();
    metadata
      ..['gameId'] = newGameId
      ..['previousGameIds'] = sortedPrevious
      ..['updatedAt'] = clock().toUtc().toIso8601String();
    if (isValidPlaymeshNewProjectGameId(newGameId)) {
      metadata['identityPolicy'] =
          ProjectProvisioningService.androidApplicationIdIdentityPolicy;
    } else {
      metadata.remove('identityPolicy');
    }
    await _writeJson(metadataFile, metadata);

    final currentRoot = Directory(
      '${staging.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}source'
      '${Platform.pathSeparator}current',
    );
    final currentManifest = File(
      '${currentRoot.path}${Platform.pathSeparator}manifest.json',
    );
    final currentManifestJson = jsonDecode(
      await currentManifest.readAsString(),
    );
    if (currentManifestJson is! Map ||
        currentManifestJson['schemaVersion'] != 3 ||
        currentManifestJson['gameId'] != oldGameId ||
        currentManifestJson['projectFiles'] is! List) {
      throw const FormatException('GDevelop current manifest 身份无效');
    }
    final currentManifestMap = Map<String, Object?>.from(currentManifestJson);
    final currentProjectFilesReference =
        GDevelopProjectFilesReference.fromJson({
          'contentHash': currentManifestMap['projectFilesHash'],
          'size': currentManifestMap['projectFilesSize'],
          'files': currentManifestMap['projectFiles'],
        });
    final projectFiles = <GDevelopProjectFile>[];
    for (final reference in currentProjectFilesReference.files) {
      final file = File(
        '${currentRoot.path}${Platform.pathSeparator}project'
        '${Platform.pathSeparator}'
        '${reference.path.replaceAll('/', Platform.pathSeparator)}',
      );
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('GDevelop current 工程文件无效');
      }
      final content = Map<String, Object?>.from(decoded);
      if (reference.path == 'game.json') {
        final properties = content['properties'];
        if (properties is! Map) {
          throw const FormatException('GDevelop game.json properties 无效');
        }
        final rewrittenProperties = Map<String, Object?>.from(properties);
        final packageName = rewrittenProperties['packageName'];
        if (packageName is! String ||
            ProjectProvisioningService.validateGameId(packageName) !=
                oldGameId) {
          throw const FormatException('GDevelop game.json packageName 身份无效');
        }
        rewrittenProperties['packageName'] = newGameId;
        content['properties'] = rewrittenProperties;
      }
      projectFiles.add(
        GDevelopProjectFile(path: reference.path, content: content),
      );
    }
    final rootProjectFile = gdevelopRootProjectFile(projectFiles);
    await File(
      '${currentRoot.path}${Platform.pathSeparator}project'
      '${Platform.pathSeparator}game.json',
    ).writeAsBytes(
      encodeOfficialGDevelopProjectFileBytes(rootProjectFile.content),
      flush: true,
    );
    final rewrittenProjectFilesReference = await referenceGDevelopProjectFiles(
      projectFiles,
    );

    final main = File('${staging.path}${Platform.pathSeparator}main.json');
    if (await main.exists()) {
      final decoded = await _readMainJson(main, expectedGameId: oldGameId);
      decoded['id'] = newGameId;
      await _writeJson(main, decoded);
    }

    final configFile = _configFile(staging);
    Map<String, Object?>? targetConfigJson;
    if (await configFile.exists()) {
      final decoded = jsonDecode(await configFile.readAsString());
      if (decoded is! Map) {
        throw const GDevelopProjectConfigInvalidState();
      }
      final oldConfig = GDevelopProjectConfig.fromJson(
        Map<String, Object?>.from(decoded),
        expectedGameId: oldGameId,
      );
      final target = GDevelopProjectConfig(
        gameId: newGameId,
        revision: oldConfig.revision + 1,
        gameType: oldConfig.gameType,
        minPlayers: oldConfig.minPlayers,
        maxPlayers: oldConfig.maxPlayers,
        tags: oldConfig.tags,
        updatedAt: clock().toUtc(),
      );
      targetConfigJson = target.toJson();
      await _writeJson(configFile, targetConfigJson);
    }

    final rewrittenCurrentManifest = currentManifestMap
      ..['gameId'] = newGameId
      ..['projectFilesHash'] = rewrittenProjectFilesReference.contentHash
      ..['projectFilesSize'] = rewrittenProjectFilesReference.size
      ..['projectFiles'] = rewrittenProjectFilesReference.files
          .map((file) => file.toJson())
          .toList(growable: false)
      ..['playmeshProjectConfig'] = targetConfigJson;
    final currentPayload = <String, Object?>{
      'schemaVersion': 3,
      'projectFilesHash': rewrittenCurrentManifest['projectFilesHash'],
      'projectFilesSize': rewrittenCurrentManifest['projectFilesSize'],
      'projectFiles': rewrittenCurrentManifest['projectFiles'],
      'resources': rewrittenCurrentManifest['resources'],
      'playmeshProjectConfig': targetConfigJson,
    };
    final currentPayloadBytes = utf8.encode(jsonEncode(currentPayload));
    rewrittenCurrentManifest
      ..['contentHash'] = await _hashBytes(currentPayloadBytes)
      ..['contentBytes'] = currentPayloadBytes.length;
    await _writeJson(currentManifest, rewrittenCurrentManifest);
  }

  Future<GDevelopRestoreHistoryEvidence> _historyEvidence(
    GDevelopProjectCurrentReferenceSnapshot snapshot,
  ) async => GDevelopRestoreHistoryEvidence(
    revision: snapshot.version.revision,
    currentContentHash: snapshot.version.contentHash,
    projectFilesHash: snapshot.projectFiles.contentHash,
    resourceManifestHash: await _hashJson(
      snapshot.resources.map((resource) => resource.toJson()).toList(),
    ),
  );

  Future<void> _ensureNoOtherRekey(Iterable<String> gameIds) async {
    for (final gameId in gameIds) {
      await ensureMutationAllowed(gameId);
    }
    await _ensureAdditionalMutationsAllowed(gameIds);
  }

  Future<void> _ensureAdditionalMutationsAllowed(
    Iterable<String> gameIds,
  ) async {
    for (final gameId in gameIds) {
      for (final guard in _additionalMutationGuards) {
        await guard(gameId);
      }
    }
  }

  Future<T> _withTransactionRoots<T>(
    GDevelopProjectRekeyPayload payload,
    Future<T> Function() action,
  ) async {
    final oldRoot = await rootResolver.projectRootLocation(payload.oldGameId);
    final newRoot = await rootResolver.projectRootLocation(payload.newGameId);
    return mutationLock.run(
      projectRoots: [oldRoot, newRoot],
      action: () async {
        await _ensureAdditionalMutationsAllowed([
          payload.oldGameId,
          payload.newGameId,
        ]);
        return action();
      },
    );
  }

  Future<PendingProjectCommitStore<GDevelopProjectRekeyPayload>> _store(
    String oldGameId,
  ) async {
    final normalized = ProjectProvisioningService.validateGameId(oldGameId);
    final existing = _stores[normalized];
    if (existing != null) return existing;
    final future = () async {
      final transactions = await _transactionsRoot(normalized);
      return PendingProjectCommitStore<GDevelopProjectRekeyPayload>(
        root: Directory(
          '${transactions.path}${Platform.pathSeparator}$normalized',
        ),
        namespace: namespace,
        codec: PendingProjectCommitCodec(
          encode: (payload) => payload.toJson(),
          decode: GDevelopProjectRekeyPayload.fromJson,
        ),
        preparedTtl: preparedTtl,
        receiptRetention: receiptRetention,
        clock: clock,
        idFactory: idFactory,
      );
    }();
    _stores[normalized] = future;
    return future;
  }

  Future<Directory> _transactionsRoot(String anyGameId) async {
    final project = await rootResolver.projectRootLocation(anyGameId);
    return Directory(
      '${project.parent.path}${Platform.pathSeparator}.playmesh-transactions'
      '${Platform.pathSeparator}gdevelop-rekey',
    );
  }

  Future<PendingProjectCommitRecord<GDevelopProjectRekeyPayload>> _statusRecord(
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
    String txId,
  ) async {
    try {
      return await store.status(txId);
    } on PendingProjectCommitNotFound {
      throw GDevelopProjectRekeyNotFound(txId);
    }
  }

  Future<GDevelopProjectRekeyMutationLocked> _lockedFromStore(
    PendingProjectCommitLocked error,
    PendingProjectCommitStore<GDevelopProjectRekeyPayload> store,
  ) async {
    final record = await store.status(error.activeTxId);
    return GDevelopProjectRekeyMutationLocked(
      txId: record.txId,
      phase: GDevelopProjectRekeyPhase.fromStore(record.phase),
      oldGameId: record.payload.oldGameId,
      newGameId: record.payload.newGameId,
    );
  }

  Future<Directory> _stagingRoot({
    required Directory oldRoot,
    required String newGameId,
    required String idempotencyKey,
  }) async {
    final suffix = (await _hashJson({
      'old': _basename(oldRoot.path),
      'new': newGameId,
      'key': idempotencyKey,
    })).substring(0, 20);
    return Directory(
      '${oldRoot.parent.path}${Platform.pathSeparator}.playmesh-rekey-$suffix',
    );
  }

  Future<Directory> _tombstoneRoot({
    required Directory oldRoot,
    required String newGameId,
    required String idempotencyKey,
  }) async {
    final suffix = (await _hashJson({
      'old': _basename(oldRoot.path),
      'new': newGameId,
      'key': idempotencyKey,
      'kind': 'tombstone',
    })).substring(0, 20);
    return Directory(
      '${oldRoot.parent.path}${Platform.pathSeparator}'
      '.playmesh-rekey-tombstone-$suffix',
    );
  }

  Future<void> _crash(GDevelopProjectRekeyCrashPoint point, String txId) async {
    await crashHook?.call(point, txId);
  }

  static String _defaultTransactionId() =>
      'rekey-${DateTime.now().toUtc().microsecondsSinceEpoch}-${_sequence++}';
}

Future<Map<String, Object?>> _readProjectMetadata(
  File file, {
  required String gameId,
}) async {
  if (!await file.exists()) throw ProjectProvisioningMissing(gameId);
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) throw const FormatException('Playmesh 项目元数据无效');
  final json = Map<String, Object?>.from(decoded);
  if (json['schemaVersion'] !=
          ProjectProvisioningService.metadataSchemaVersion ||
      json['kind'] != PlaymeshProjectKind.gdevelop.wireName ||
      json['gameId'] != gameId ||
      json['name'] is! String ||
      json['createdAt'] is! String ||
      json['updatedAt'] is! String ||
      DateTime.tryParse(json['createdAt']! as String) == null ||
      DateTime.tryParse(json['updatedAt']! as String) == null) {
    throw const FormatException('Playmesh 项目元数据无效');
  }
  return json;
}

Future<Map<String, Object?>> _readMainJson(
  File file, {
  required String expectedGameId,
}) async {
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) throw const FormatException('main.json 根必须是对象');
  final json = Map<String, Object?>.from(decoded);
  if (json['id'] != expectedGameId) {
    throw const FormatException('main.json id 与项目身份不一致');
  }
  return json;
}

File _configFile(Directory root) => File(
  '${root.path}${Platform.pathSeparator}.playmesh'
  '${Platform.pathSeparator}gdevelop'
  '${Platform.pathSeparator}project-config.json',
);

Future<GDevelopProjectConfigEvidence> _inspectConfigFile(
  File file, {
  required String gameId,
}) async {
  if (!await file.exists()) {
    return const GDevelopProjectConfigEvidence.missing();
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) throw const GDevelopProjectConfigInvalidState();
  final config = GDevelopProjectConfig.fromJson(
    Map<String, Object?>.from(decoded),
    expectedGameId: gameId,
  );
  return GDevelopProjectConfigEvidence.forReady(config);
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = _basename(entity.path);
    final destination = '${target.path}${Platform.pathSeparator}$name';
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(destination));
    } else if (entity is File) {
      await entity.openRead().pipe(File(destination).openWrite());
    } else {
      throw const FormatException('GDevelop rekey 不允许符号链接或特殊文件');
    }
  }
}

Future<void> _writeJson(File file, Map<String, Object?> value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(value), flush: true);
}

Future<String> _treeManifestHash(Directory root) async {
  final entries = <Map<String, Object?>>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    final relative = entity.path
        .substring(root.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    if (entity is Directory) {
      entries.add({'path': relative, 'type': 'directory'});
    } else if (entity is File) {
      entries.add({
        'path': relative,
        'type': 'file',
        'bytes': await entity.length(),
        'hash': await _hashFile(entity),
      });
    } else {
      throw const FormatException('GDevelop rekey 不允许符号链接或特殊文件');
    }
  }
  entries.sort(
    (left, right) =>
        (left['path']! as String).compareTo(right['path']! as String),
  );
  return _hashJson(entries);
}

Future<String> _hashFile(File file) async =>
    _hashBytes(await file.readAsBytes());

Future<String> _hashJson(Object? value) async =>
    _hashBytes(utf8.encode(jsonEncode(_canonicalize(value))));

Future<String> _hashBytes(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Object? _canonicalize(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List) return value.map(_canonicalize).toList();
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) throw const FormatException('JSON key 必须是字符串');
      return key;
    }).toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  throw const FormatException('JSON 值不可序列化');
}

Future<Directory> _renameDirectoryWithRetry(
  Directory source,
  String destination,
) async {
  FileSystemException? lastError;
  for (var attempt = 0; attempt < 10; attempt += 1) {
    try {
      return await source.rename(destination);
    } on FileSystemException catch (error) {
      lastError = error;
      final code = error.osError?.errorCode;
      if (!Platform.isWindows || (code != 5 && code != 32) || attempt == 9) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
    }
  }
  throw lastError ?? FileSystemException('GDevelop rekey 原子发布失败', source.path);
}

Future<bool> _pathExists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<void> _deleteRecursively(Directory directory) =>
    directory.delete(recursive: true);

bool _browserEvidenceMatches(
  GDevelopProjectRekeyBrowserEvidence left,
  GDevelopProjectRekeyBrowserEvidence right,
) =>
    left.fileIdentifier == right.fileIdentifier &&
    left.gameId == right.gameId &&
    left.packageName == right.packageName &&
    left.projectFilesHash == right.projectFilesHash;

bool _sourceBrowserEvidenceMatches(
  GDevelopProjectRekeyPayload payload,
  GDevelopProjectRekeyBrowserEvidence evidence,
) =>
    evidence.fileIdentifier == payload.browserSource.fileIdentifier &&
    evidence.gameId == payload.oldGameId &&
    evidence.packageName == payload.oldGameId &&
    evidence.projectFilesHash == payload.browserSource.projectFilesHash;

String _basename(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;

String? _optionalToken(String? value, String field) {
  if (value == null) return null;
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(normalized)) {
    throw FormatException('GDevelop rekey $field 无效');
  }
  return normalized;
}

Map<String, Object?> _strictMap(Object? value, String name) {
  if (value is! Map) throw FormatException('GDevelop $name 必须是对象');
  return Map<String, Object?>.from(value);
}

void _requireFields(Map<String, Object?> json, Set<String> fields) {
  if (json.length != fields.length || !json.keys.every(fields.contains)) {
    throw const FormatException('GDevelop rekey 字段无效');
  }
}

bool _isHash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

GDevelopProjectConfigEvidence _configEvidenceFromJson(
  Object? value, {
  required String gameId,
}) {
  final json = _strictMap(value, 'rekey config evidence');
  final status = json['status'];
  switch (status) {
    case 'missing':
      _requireFields(json, const {'status'});
      return const GDevelopProjectConfigEvidence.missing();
    case 'ready':
      _requireFields(json, const {
        'status',
        'revision',
        'contentHash',
        'config',
      });
      if (json['revision'] is! int || !_isHash(json['contentHash'])) {
        throw const FormatException('GDevelop rekey config evidence 无效');
      }
      final configJson = _strictMap(json['config'], 'rekey config');
      final config = GDevelopProjectConfig.fromJson(
        configJson,
        expectedGameId: gameId,
      );
      if (config.revision != json['revision']) {
        throw const FormatException('GDevelop rekey config revision 无效');
      }
      return GDevelopProjectConfigEvidence.ready(
        config: config,
        contentHash: json['contentHash']! as String,
      );
    default:
      throw const FormatException('GDevelop rekey config status 无效');
  }
}
