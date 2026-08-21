import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/pending_project_commit_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_restore_transaction.dart';

void main() {
  test('ready config 恢复生成新单调 revision，ACK receipt 后才发事件', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();

    final prepared = await fixture.prepare(scenario);
    expect(prepared.phase, PendingProjectCommitPhase.prepared);
    expect(prepared.oldEvidence.history.revision, 2);
    expect(prepared.targetEvidence.history.revision, 3);
    expect(prepared.targetEvidence.config.sidecar.revision, 3);
    expect(
      prepared.targetEvidence.config.sidecar.config?.gameType,
      GDevelopProjectGameType.single,
    );
    final targetSnapshot = await fixture.coordinator.targetSnapshot(prepared);
    expect(targetSnapshot.sourceVersion.revision, scenario.targetRevision);
    expect(targetSnapshot.sourceVersion.revision, 1);
    expect(_rootContent(targetSnapshot.projectFiles), const {'name': 'first'});
    expect(
      await hashGDevelopProjectFiles(targetSnapshot.projectFiles),
      prepared.targetEvidence.history.projectFilesHash,
    );
    expect(targetSnapshot.resources, isEmpty);
    expect(targetSnapshot.projectConfigSnapshot.config?.revision, 3);
    expect(
      await fixture.coordinator.restoredSnapshot(prepared),
      isNull,
      reason: '计划 revision 不能伪装成已提交 restored.version',
    );

    fixture.now = fixture.now.add(const Duration(minutes: 1));
    final replayedPrepare = await fixture.prepare(scenario);
    expect(replayedPrepare.txId, prepared.txId);
    expect(
      replayedPrepare.targetEvidence.config.sidecar.contentHash,
      prepared.targetEvidence.config.sidecar.contentHash,
      reason: '重试不得重算服务端冻结 updatedAt',
    );
    expect(
      (await fixture.coordinator.targetSnapshot(replayedPrepare)).toJson(),
      targetSnapshot.toJson(),
    );

    final committed = await fixture.coordinator.commit(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    expect(committed.phase, PendingProjectCommitPhase.backendCommitted);
    final restored = await fixture.coordinator.restoredSnapshot(committed);
    expect(_snapshotRootContent(restored), const {'name': 'first'});
    expect(restored?.version.revision, 3);
    expect(restored?.projectConfigSnapshot.config?.revision, 3);
    expect(
      restored?.toJson()['playmeshProjectConfig'],
      prepared.targetEvidence.config.sidecar.config?.toJson(),
      reason: 'ready 必须序列化为 canonical config 对象',
    );
    expect((await fixture.config.read(fixture.gameId)).config?.revision, 3);
    expect(fixture.events, isEmpty, reason: '后端提交不得先于浏览器 ACK 发事件');

    final acknowledged = await fixture.coordinator.acknowledge(
      gameId: fixture.gameId,
      txId: prepared.txId,
      browserEvidence: _ackFor(committed),
    );
    expect(acknowledged.phase, PendingProjectCommitPhase.browserPersisted);
    expect(fixture.events, hasLength(1));
    expect(fixture.events.single['txId'], prepared.txId);

    final repeatedAck = await fixture.coordinator.acknowledge(
      gameId: fixture.gameId,
      txId: prepared.txId,
      browserEvidence: _ackFor(committed),
    );
    expect(repeatedAck.txId, prepared.txId);
    expect(fixture.events, hasLength(1));
    expect(
      await fixture.coordinator.runProjectMutation(
        fixture.gameId,
        () async => 'allowed',
      ),
      'allowed',
    );
  });

  test('restore 响应保留 explicit missing config 的 null 语义', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final config = (await fixture.config.read(fixture.gameId)).config!;
    final first = await fixture.history.snapshot(
      projectId: fixture.gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'missing-target'}),
      resources: const [],
      projectConfigSnapshot:
          const GDevelopHistoryProjectConfigSnapshot.missing(),
    );
    final second = await fixture.history.snapshot(
      projectId: fixture.gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'ready-current'}),
      resources: const [],
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(config),
    );
    final prepared = await fixture.prepare(
      _ReadyScenario(
        baseRevision: second.version.revision,
        targetRevision: first.version.revision,
      ),
    );
    final targetSnapshot = await fixture.coordinator.targetSnapshot(prepared);
    expect(
      targetSnapshot.toJson(),
      containsPair('playmeshProjectConfig', null),
    );
    final committed = await fixture.coordinator.commit(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    final restored = await fixture.coordinator.restoredSnapshot(committed);

    expect(
      committed.targetEvidence.config.semantics,
      GDevelopHistoryProjectConfigSemantics.missing,
    );
    expect(
      restored?.toJson(),
      containsPair('playmeshProjectConfig', null),
      reason: 'explicit missing 必须保留键并写 null',
    );
    expect(
      (await fixture.config.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.missing,
    );
  });

  test('PREPARED TTL 只写 ABORTED receipt，不修改 history 或 config', () async {
    final fixture = await _RestoreFixture.create(
      preparedTtl: const Duration(minutes: 5),
    );
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    final prepared = await fixture.prepare(scenario);
    fixture.now = fixture.now.add(const Duration(minutes: 6));

    final expired = await fixture.coordinator.status(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    expect(expired.phase, PendingProjectCommitPhase.aborted);
    expect(
      _snapshotRootContent(await fixture.history.current(fixture.gameId)),
      {'name': 'second'},
    );
    expect((await fixture.config.read(fixture.gameId)).config?.revision, 2);
  });

  for (final crashPoint in const [
    GDevelopRestoreCrashPoint.afterCommitRequested,
    GDevelopRestoreCrashPoint.afterHistoryMutation,
    GDevelopRestoreCrashPoint.afterHistoryApplied,
    GDevelopRestoreCrashPoint.afterConfigMutation,
    GDevelopRestoreCrashPoint.afterBackendCommitted,
  ]) {
    test('重启在 ${crashPoint.name} 后只向前恢复', () async {
      final fixture = await _RestoreFixture.create();
      addTearDown(fixture.close);
      final scenario = await fixture.seedReadyHistory();
      final prepared = await fixture.prepare(scenario);
      var crashed = false;
      final crashing = fixture.newCoordinator(
        crashHook: (point, txId) {
          if (!crashed && point == crashPoint) {
            crashed = true;
            throw StateError('simulated crash at ${point.name}');
          }
        },
      );

      await expectLater(
        crashing.commit(gameId: fixture.gameId, txId: prepared.txId),
        throwsA(isA<StateError>()),
      );
      final restarted = fixture.newCoordinator();
      final recovery = await restarted.recover(fixture.gameId);
      expect(
        recovery.transaction?.phase,
        PendingProjectCommitPhase.backendCommitted,
      );
      expect(
        _rootContent(
          (await restarted.targetSnapshot(recovery.transaction!)).projectFiles,
        ),
        const {'name': 'first'},
      );
      expect(
        _snapshotRootContent(await fixture.history.current(fixture.gameId)),
        {'name': 'first'},
      );
      expect((await fixture.config.read(fixture.gameId)).config?.revision, 3);
      await restarted.acknowledge(
        gameId: fixture.gameId,
        txId: prepared.txId,
        browserEvidence: _ackFor(recovery.transaction!),
      );
    });
  }

  test('PREPARE 响应丢失后同一请求返回同 txId', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    var crashed = false;
    final crashing = fixture.newCoordinator(
      crashHook: (point, txId) {
        if (!crashed && point == GDevelopRestoreCrashPoint.afterPrepared) {
          crashed = true;
          throw StateError('prepare response lost');
        }
      },
    );
    await expectLater(
      fixture.prepare(scenario, coordinator: crashing),
      throwsA(isA<StateError>()),
    );

    final replayed = await fixture.prepare(
      scenario,
      coordinator: fixture.newCoordinator(),
    );
    expect(replayed.phase, PendingProjectCommitPhase.prepared);
    expect(replayed.txId, 'restore-tx-0');
  });

  test('receipt 后崩溃由 ACK 重试补发事件', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    final prepared = await fixture.prepare(scenario);
    final committed = await fixture.coordinator.commit(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    var crashed = false;
    final crashing = fixture.newCoordinator(
      crashHook: (point, txId) {
        if (!crashed && point == GDevelopRestoreCrashPoint.afterReceipt) {
          crashed = true;
          throw StateError('receipt response lost');
        }
      },
    );
    await expectLater(
      crashing.acknowledge(
        gameId: fixture.gameId,
        txId: prepared.txId,
        browserEvidence: _ackFor(committed),
      ),
      throwsA(isA<StateError>()),
    );
    expect(fixture.events, isEmpty);

    final replayed = await fixture.newCoordinator().acknowledge(
      gameId: fixture.gameId,
      txId: prepared.txId,
      browserEvidence: _ackFor(committed),
    );
    expect(replayed.phase, PendingProjectCommitPhase.browserPersisted);
    expect(fixture.events, hasLength(1));
  });

  test('事件发出后标记前崩溃允许按 txId 至少一次补发', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    final prepared = await fixture.prepare(scenario);
    final committed = await fixture.coordinator.commit(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    var crashed = false;
    final crashing = fixture.newCoordinator(
      crashHook: (point, txId) {
        if (!crashed && point == GDevelopRestoreCrashPoint.afterEvent) {
          crashed = true;
          throw StateError('event marker lost');
        }
      },
    );
    await expectLater(
      crashing.acknowledge(
        gameId: fixture.gameId,
        txId: prepared.txId,
        browserEvidence: _ackFor(committed),
      ),
      throwsA(isA<StateError>()),
    );
    expect(fixture.events, hasLength(1));

    final recovery = await fixture.newCoordinator().recover(fixture.gameId);
    expect(recovery.replayedEventTxIds, [prepared.txId]);
    expect(fixture.events, hasLength(2));
    expect(fixture.events.map((event) => event['txId']).toSet(), {
      prepared.txId,
    });
  });

  test('COMMIT_REQUESTED 后观测到第三 config 状态进入 CONFLICT 并持续锁', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    final prepared = await fixture.prepare(scenario);
    var crashed = false;
    final crashing = fixture.newCoordinator(
      crashHook: (point, txId) {
        if (!crashed &&
            point == GDevelopRestoreCrashPoint.afterCommitRequested) {
          crashed = true;
          throw StateError('stop after durable commit request');
        }
      },
    );
    await expectLater(
      crashing.commit(gameId: fixture.gameId, txId: prepared.txId),
      throwsA(isA<StateError>()),
    );
    await fixture.config.update(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.online,
      minPlayers: 2,
      maxPlayers: 5,
      tags: const ['联机'],
      expectedRevision: 2,
    );

    final restarted = fixture.newCoordinator();
    final recovery = await restarted.recover(fixture.gameId);
    expect(recovery.transaction?.phase, PendingProjectCommitPhase.conflict);
    await expectLater(
      restarted.runProjectMutation(fixture.gameId, () async => null),
      throwsA(isA<PendingProjectCommitLocked>()),
    );
    final aborted = await restarted.abort(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );
    expect(aborted.phase, PendingProjectCommitPhase.aborted);
    expect(
      await restarted.runProjectMutation(
        fixture.gameId,
        () async => 'unlocked',
      ),
      'unlocked',
    );
  });

  test('ACK 必须精确匹配 target project/resource evidence', () async {
    final fixture = await _RestoreFixture.create();
    addTearDown(fixture.close);
    final scenario = await fixture.seedReadyHistory();
    final prepared = await fixture.prepare(scenario);
    final committed = await fixture.coordinator.commit(
      gameId: fixture.gameId,
      txId: prepared.txId,
    );

    await expectLater(
      fixture.coordinator.acknowledge(
        gameId: fixture.gameId,
        txId: prepared.txId,
        browserEvidence: GDevelopRestoreBrowserEvidence(
          projectFilesHash: 'f' * 64,
          resourceManifestHash:
              committed.targetEvidence.history.resourceManifestHash,
        ),
      ),
      throwsA(isA<GDevelopRestoreAckMismatch>()),
    );
    expect(
      (await fixture.coordinator.status(
        gameId: fixture.gameId,
        txId: prepared.txId,
      )).phase,
      PendingProjectCommitPhase.backendCommitted,
    );
  });

  test(
    'PREPARED target CAS 被篡改时 materializer fail-closed 且 current 不变',
    () async {
      final fixture = await _RestoreFixture.create();
      addTearDown(fixture.close);
      final scenario = await fixture.seedReadyHistory();
      final prepared = await fixture.prepare(scenario);
      final historyRoot = await fixture.resolver.resolveHistoryRoot(
        fixture.gameId,
      );
      final targetSnapshot = await fixture.coordinator.targetSnapshot(prepared);
      final targetObject = File(
        '${historyRoot.path}${Platform.pathSeparator}cas'
        '${Platform.pathSeparator}'
        '${targetSnapshot.projectFilesReference.single.contentHash}.blob',
      );
      expect(await targetObject.exists(), isTrue);
      await targetObject.delete();

      await expectLater(
        fixture.coordinator.targetSnapshot(prepared),
        throwsA(isA<GDevelopRestoreTargetSnapshotMismatch>()),
      );
      expect(
        _snapshotRootContent(await fixture.history.current(fixture.gameId)),
        {'name': 'second'},
      );
      expect((await fixture.config.read(fixture.gameId)).config?.revision, 2);
      expect(
        (await fixture.coordinator.status(
          gameId: fixture.gameId,
          txId: prepared.txId,
        )).phase,
        PendingProjectCommitPhase.prepared,
      );
    },
  );
}

class _ReadyScenario {
  const _ReadyScenario({
    required this.baseRevision,
    required this.targetRevision,
  });

  final int baseRevision;
  final int targetRevision;
}

class _RestoreFixture {
  _RestoreFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.config,
    required this.preparedTtl,
  });

  static const testGameId = 'com.example.restore-transaction';

  String get gameId => testGameId;

  final Directory root;
  final FileSystemGDevelopProjectRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController config;
  final Duration preparedTtl;
  final List<Map<String, Object?>> events = [];
  DateTime now = DateTime.utc(2026, 8, 5, 1);
  int idSequence = 0;
  late final GDevelopRestoreTransactionCoordinator coordinator =
      newCoordinator();

  static Future<_RestoreFixture> create({
    Duration preparedTtl = const Duration(minutes: 10),
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-restore-tx-');
    late _RestoreFixture fixture;
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final history = GDevelopProjectHistoryAdapter(
      rootResolver: resolver,
      clock: () => fixture.now,
    );
    final config = GDevelopProjectConfigController(
      GDevelopProjectConfigStore(
        rootResolver: resolver,
        clock: () => fixture.now,
      ),
    );
    fixture = _RestoreFixture(
      root: root,
      resolver: resolver,
      history: history,
      config: config,
      preparedTtl: preparedTtl,
    );
    await history.createProjectRoot(
      gameId: testGameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: 'Restore transaction',
    );
    expect(await config.initializeNewProject(testGameId), isTrue);
    return fixture;
  }

  Future<_ReadyScenario> seedReadyHistory() async {
    final initialConfig = (await config.read(gameId)).config!;
    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'first'}),
      resources: const [],
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(
        initialConfig,
      ),
    );
    now = now.add(const Duration(minutes: 1));
    final currentConfig = await config.update(
      gameId: gameId,
      gameType: GDevelopProjectGameType.online,
      minPlayers: 2,
      maxPlayers: 5,
      tags: const ['联机'],
      expectedRevision: initialConfig.revision,
    );
    final second = await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'second'}),
      resources: const [],
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(
        currentConfig,
      ),
    );
    return _ReadyScenario(
      baseRevision: second.version.revision,
      targetRevision: first.version.revision,
    );
  }

  GDevelopRestoreTransactionCoordinator newCoordinator({
    GDevelopRestoreCrashHook? crashHook,
  }) => GDevelopRestoreTransactionCoordinator(
    history: history,
    projectConfig: config,
    rootResolver: resolver,
    preparedTtl: preparedTtl,
    clock: () => now,
    idFactory: () => 'restore-tx-${idSequence++}',
    crashHook: crashHook,
    eventSink: (event) => events.add(Map.unmodifiable(event)),
  );

  Future<GDevelopRestoreTransaction> prepare(
    _ReadyScenario scenario, {
    GDevelopRestoreTransactionCoordinator? coordinator,
  }) => (coordinator ?? this.coordinator).prepare(
    gameId: gameId,
    idempotencyKey: 'restore-click-1',
    baseRevision: scenario.baseRevision,
    targetRevision: scenario.targetRevision,
    source: GDevelopHistorySource.user,
    currentProjectFiles: _projectFiles(const {'name': 'browser-unsaved'}),
    currentResources: const [],
    clientId: 'webide-tab-1',
  );

  Future<void> close() => root.delete(recursive: true);
}

GDevelopRestoreBrowserEvidence _ackFor(
  GDevelopRestoreTransaction transaction,
) => GDevelopRestoreBrowserEvidence(
  projectFilesHash: transaction.targetEvidence.history.projectFilesHash,
  resourceManifestHash: transaction.targetEvidence.history.resourceManifestHash,
);

List<GDevelopProjectFile> _projectFiles(Map<String, Object?> content) => [
  GDevelopProjectFile(path: 'game.json', content: content),
];

Map<String, Object?> _rootContent(List<GDevelopProjectFile> projectFiles) =>
    gdevelopRootProjectFile(projectFiles).content;

Map<String, Object?>? _snapshotRootContent(GDevelopProjectSnapshot? snapshot) =>
    snapshot == null ? null : _rootContent(snapshot.projectFiles);
