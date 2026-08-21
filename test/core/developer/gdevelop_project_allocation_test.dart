import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/pending_project_commit_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_allocation.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';

void main() {
  test('App staging 完整上传并以官方工程资源顺序 finalize/commit', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.prepareWorkspace(
      'com.example.allocation-complete',
    );
    final root = await fixture.projectRoot(workspace.gameId);

    expect(
      workspace.transaction.phase,
      GDevelopProjectAllocationPhase.prepared,
    );
    expect(await root.exists(), isFalse);
    final firstPresence = await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan.reversed.toList(),
    );
    expect(firstPresence.missing, hasLength(2));
    expect(firstPresence.available, isEmpty);
    expect(
      firstPresence.transaction.record.payload.resourcePlan.map(
        (resource) => resource.logicalId,
      ),
      orderedEquals(
        workspace.resourcePlan.map((resource) => resource.logicalId).toList()
          ..sort(),
      ),
      reason: 'presence batch 顺序不能成为 durable resource plan 顺序',
    );

    for (final resource in workspace.resourcePlan.reversed) {
      final bytes = workspace.resourceBytes[resource.logicalId]!;
      final staged = await fixture.coordinator.uploadResource(
        txId: workspace.txId,
        contentHash: resource.contentHash,
        bytes: Stream.value(bytes),
        contentLength: null,
      );
      expect(staged.hash, resource.contentHash);
      expect(staged.bytes, bytes.length);
    }
    final available = await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan,
    );
    expect(available.missing, isEmpty);
    expect(available.available, hasLength(2));

    final projectReference = await fixture.coordinator
        .uploadWorkspaceProjectFiles(
          txId: workspace.txId,
          bytes: Stream.value(workspace.projectBytes),
          contentLength: null,
        );
    expect(
      projectReference.contentHash,
      workspace.finalization.projectFilesHash,
    );
    final finalized = await fixture.coordinator.finalizeWorkspace(
      txId: workspace.txId,
      evidence: workspace.finalization,
    );
    expect(finalized.phase, GDevelopProjectAllocationPhase.workspaceFinalized);
    expect(finalized.record.payloadFinalizationHash, hasLength(64));
    expect(await root.exists(), isFalse);
    expect(
      (await fixture.coordinator.recover(workspace.txId)).phase,
      GDevelopProjectAllocationPhase.workspaceFinalized,
      reason: '没有 COMMIT 请求时 recover 不能自行产生 durable decision',
    );

    final committed = await fixture.coordinator.commit(workspace.txId);
    expect(committed.phase, GDevelopProjectAllocationPhase.committed);
    expect(await root.exists(), isTrue);
    expect(await fixture.stagingDirectories(), isEmpty);
    final current = await fixture.history.current(workspace.gameId);
    expect(current, isNotNull);
    expect(
      (gdevelopRootProjectFile(current!.projectFiles).content['properties']!
          as Map)['packageName'],
      workspace.gameId,
    );
    expect(
      current.resources.map((resource) => resource.logicalId).toSet(),
      workspace.resourcePlan.map((resource) => resource.logicalId).toSet(),
    );
    final initialEvidence = await fixture.history.currentReferenceSnapshot(
      workspace.gameId,
    );
    expect(initialEvidence, isNotNull);
    expect(
      initialEvidence!.version.revision,
      1,
      reason: 'allocation 首次提交直接建立独立 source/current revision 1',
    );
    final firstList = await fixture.history.listManagedProjects();
    final importedProject = firstList.projects.singleWhere(
      (project) => project.identity.gameId == workspace.gameId,
    );
    expect(importedProject.currentEvidence, isNotNull);
    expect(importedProject.currentEvidence!.version.revision, 1);
    final refreshedList = await fixture.history.listManagedProjects();
    expect(
      refreshedList.projects
          .singleWhere((project) => project.identity.gameId == workspace.gameId)
          .currentEvidence,
      isNotNull,
      reason: '再次枚举仍须从 App 权威根读出 current，不依赖浏览器 recent 列表',
    );
    final transactionJson = committed.toJson();
    expect(transactionJson['workspaceTarget'], isA<Map>());
    expect(transactionJson.containsKey('browserTarget'), isFalse);
    expect(transactionJson.containsKey('browserEvidence'), isFalse);

    expect(
      (await fixture.coordinator.finalizeWorkspace(
        txId: workspace.txId,
        evidence: workspace.finalization,
      )).phase,
      GDevelopProjectAllocationPhase.committed,
    );
    await expectLater(
      fixture.coordinator.finalizeWorkspace(
        txId: workspace.txId,
        evidence: GDevelopProjectAllocationWorkspaceFinalization(
          packageName: workspace.finalization.packageName,
          projectUuid: workspace.finalization.projectUuid,
          projectFilesHash: workspace.finalization.projectFilesHash,
          projectFilesSize: workspace.finalization.projectFilesSize,
          resourceManifestHash: await _sha(Uint8List.fromList([9])),
        ),
      ),
      throwsA(isA<GDevelopProjectAllocationEvidenceMismatch>()),
    );
  });

  test('resource plan 对重复、变更、同 hash 异 size、未计划 PUT 失败关闭', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.prepareWorkspace(
      'com.example.allocation-plan',
    );
    final first = workspace.resourcePlan.first;

    await expectLater(
      fixture.coordinator.resourcePresence(
        txId: workspace.txId,
        resources: [first, first],
      ),
      throwsA(isA<FormatException>()),
    );
    await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: [first],
    );
    final changed = GDevelopProjectResource(
      logicalId: first.logicalId,
      name: first.name,
      contentHash: await _sha(Uint8List.fromList([7, 7, 7, 7])),
      mime: first.mime,
      size: first.size,
    );
    await expectLater(
      fixture.coordinator.resourcePresence(
        txId: workspace.txId,
        resources: [changed],
      ),
      throwsA(isA<GDevelopProjectAllocationEvidenceMismatch>()),
    );
    final sameHashDifferentSize = GDevelopProjectResource(
      logicalId: '${first.logicalId}-other',
      name: '${first.name}-other',
      contentHash: first.contentHash,
      mime: first.mime,
      size: first.size + 1,
    );
    await expectLater(
      fixture.coordinator.resourcePresence(
        txId: workspace.txId,
        resources: [sameHashDifferentSize],
      ),
      throwsA(isA<FormatException>()),
    );
    final unplannedHash = await _sha(Uint8List.fromList([8, 8]));
    await expectLater(
      fixture.coordinator.uploadResource(
        txId: workspace.txId,
        contentHash: unplannedHash,
        bytes: Stream.value(const [8, 8]),
      ),
      throwsA(isA<GDevelopProjectAllocationResourceNotPlanned>()),
    );
    await expectLater(
      fixture.coordinator.uploadResource(
        txId: workspace.txId,
        contentHash: first.contentHash,
        bytes: Stream.value(const [1]),
        contentLength: 1,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('官方资源别名允许不同逻辑地址复用同一内容对象', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.prepareWorkspace(
      'com.example.allocation-resource-alias',
      shareResourceContent: true,
    );

    expect(
      workspace.resourcePlan.map((resource) => resource.logicalId).toSet(),
      hasLength(2),
    );
    expect(
      workspace.resourcePlan.map((resource) => resource.contentHash).toSet(),
      hasLength(1),
    );
    final presence = await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan,
    );
    expect(presence.missing, hasLength(1));

    final shared = workspace.resourcePlan.first;
    await fixture.coordinator.uploadResource(
      txId: workspace.txId,
      contentHash: shared.contentHash,
      bytes: Stream.value(workspace.resourceBytes[shared.logicalId]!),
    );
    final available = await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan,
    );
    expect(available.missing, isEmpty);
    expect(available.available, hasLength(1));
    expect(
      available.transaction.record.payload.resourcePlan,
      hasLength(2),
      reason: 'CAS presence 可按 hash 去重，但官方资源清单必须保留两个别名项',
    );
    await fixture.coordinator.uploadWorkspaceProjectFiles(
      txId: workspace.txId,
      bytes: Stream.value(workspace.projectBytes),
    );
    expect(
      (await fixture.coordinator.finalizeWorkspace(
        txId: workspace.txId,
        evidence: workspace.finalization,
      )).phase,
      GDevelopProjectAllocationPhase.workspaceFinalized,
    );
  });

  test('工程 PUT 校验 exact bytes、gameId/packageName/projectUuid 与大小', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.prepareWorkspace(
      'com.example.allocation-project-put',
    );
    await expectLater(
      fixture.coordinator.uploadWorkspaceProjectFiles(
        txId: workspace.txId,
        bytes: Stream.value(utf8.encode('{}')),
      ),
      throwsA(isA<GDevelopProjectAllocationEvidenceMismatch>()),
    );
    await expectLater(
      fixture.coordinator.uploadWorkspaceProjectFiles(
        txId: workspace.txId,
        bytes: Stream.value(workspace.projectBytes),
        contentLength: workspace.projectBytes.length + 1,
      ),
      throwsA(isA<FormatException>()),
    );

    final wrongIdentity = await fixture.prepareWorkspace(
      'com.example.allocation-project-identity',
      projectPackageName: 'com.example.someone-else',
    );
    await expectLater(
      fixture.coordinator.uploadWorkspaceProjectFiles(
        txId: wrongIdentity.txId,
        bytes: Stream.value(wrongIdentity.projectBytes),
      ),
      throwsA(isA<GDevelopProjectAllocationEvidenceMismatch>()),
    );
  });

  test('finalize 要求完整 project/resource CAS，batch 顺序不改变官方 manifest', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.prepareWorkspace(
      'com.example.allocation-finalize',
    );
    await fixture.coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan.reversed.toList(),
    );
    await fixture.coordinator.uploadWorkspaceProjectFiles(
      txId: workspace.txId,
      bytes: Stream.value(workspace.projectBytes),
    );
    await expectLater(
      fixture.coordinator.finalizeWorkspace(
        txId: workspace.txId,
        evidence: workspace.finalization,
      ),
      throwsA(isA<Object>()),
    );
    expect(
      (await fixture.coordinator.status(workspace.txId)).phase,
      GDevelopProjectAllocationPhase.prepared,
    );

    for (final resource in workspace.resourcePlan) {
      await fixture.coordinator.uploadResource(
        txId: workspace.txId,
        contentHash: resource.contentHash,
        bytes: Stream.value(workspace.resourceBytes[resource.logicalId]!),
      );
    }
    expect(
      (await fixture.coordinator.finalizeWorkspace(
        txId: workspace.txId,
        evidence: workspace.finalization,
      )).phase,
      GDevelopProjectAllocationPhase.workspaceFinalized,
    );
  });

  test(
    'PREPARED/WORKSPACE_FINALIZED TTL 后 ABORTED，COMMIT_REQUESTED 后只前进',
    () async {
      final preparedFixture = await _AllocationFixture.create();
      addTearDown(preparedFixture.close);
      final prepared = await preparedFixture.prepareWorkspace(
        'com.example.allocation-expire-prepared',
      );
      preparedFixture.now = preparedFixture.now.add(
        preparedFixture.preparedTtl,
      );
      expect(
        (await preparedFixture.coordinator.status(prepared.txId)).phase,
        GDevelopProjectAllocationPhase.aborted,
      );
      expect(await preparedFixture.stagingDirectories(), isEmpty);

      final finalizedFixture = await _AllocationFixture.create();
      addTearDown(finalizedFixture.close);
      final finalized = await finalizedFixture.prepareWorkspace(
        'com.example.allocation-expire-finalized',
      );
      await finalizedFixture.stageWorkspace(finalized);
      finalizedFixture.now = finalizedFixture.now.add(
        finalizedFixture.preparedTtl,
      );
      expect(
        (await finalizedFixture.coordinator.status(finalized.txId)).phase,
        GDevelopProjectAllocationPhase.aborted,
      );
      expect(await finalizedFixture.stagingDirectories(), isEmpty);
    },
  );

  test('prepare 响应丢失可同键重放；新键只替换同 gameId 的 PREPARED', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.allocation-lost-prepare-response';
    final first = await fixture.prepareWorkspace(
      gameId,
      idempotencyKey: 'allocation-lost-response',
    );
    final firstStaging = Directory(
      first.transaction.record.payload.stagingPath,
    );
    expect(await firstStaging.exists(), isTrue);

    final replay = await fixture.prepareWorkspace(
      gameId,
      idempotencyKey: 'allocation-lost-response',
    );
    expect(replay.txId, first.txId, reason: '丢失 201 后同键必须返回原事务');
    expect(replay.transaction.phase, GDevelopProjectAllocationPhase.prepared);
    await expectLater(
      fixture.prepareWorkspace(
        gameId,
        idempotencyKey: 'allocation-lost-response',
        projectPackageName: 'com.example.changed-request',
      ),
      throwsA(isA<GDevelopProjectAllocationIdempotencyConflict>()),
    );
    expect(
      (await fixture.coordinator.status(first.txId)).phase,
      GDevelopProjectAllocationPhase.prepared,
      reason: '同键不同请求仍必须失败关闭，不能被 latest-wins 替换',
    );

    final unrelated = await fixture.prepareWorkspace(
      'com.example.allocation-lost-response-unrelated',
      idempotencyKey: 'allocation-unrelated',
    );
    final unrelatedStaging = Directory(
      unrelated.transaction.record.payload.stagingPath,
    );
    final unrelatedCanonical = await fixture.projectRoot(
      'com.example.allocation-existing-unrelated',
    );
    await unrelatedCanonical.create(recursive: true);
    final unrelatedSentinel = File(
      '${unrelatedCanonical.path}${Platform.pathSeparator}keep.txt',
    );
    await unrelatedSentinel.writeAsString('keep');
    final replacement = await fixture.prepareWorkspace(
      gameId,
      idempotencyKey: 'allocation-new-request',
    );

    expect(replacement.txId, isNot(first.txId));
    expect(
      (await fixture.coordinator.status(first.txId)).phase,
      GDevelopProjectAllocationPhase.aborted,
      reason: '被替换事务必须留下稳定 ABORTED receipt',
    );
    expect(await firstStaging.exists(), isFalse);
    expect(await unrelatedStaging.exists(), isTrue);
    expect(
      (await fixture.coordinator.status(unrelated.txId)).phase,
      GDevelopProjectAllocationPhase.prepared,
    );
    expect(await (await fixture.projectRoot(gameId)).exists(), isFalse);
    expect(
      await (await fixture.projectRoot(unrelated.gameId)).exists(),
      isFalse,
      reason: '替换 PREPARED 不能发布本 gameId 或触碰其他 gameId',
    );
    expect(await unrelatedSentinel.readAsString(), 'keep');
  });

  test('新 prepare 不替换 WORKSPACE_FINALIZED 或 COMMIT_REQUESTED', () async {
    final finalizedFixture = await _AllocationFixture.create();
    addTearDown(finalizedFixture.close);
    final finalized = await finalizedFixture.prepareWorkspace(
      'com.example.allocation-finalized-not-replaced',
      idempotencyKey: 'allocation-finalized-first',
    );
    await finalizedFixture.stageWorkspace(finalized);
    await expectLater(
      finalizedFixture.prepareWorkspace(
        finalized.gameId,
        idempotencyKey: 'allocation-finalized-second',
      ),
      throwsA(
        isA<GDevelopProjectAllocationLocked>()
            .having((error) => error.txId, 'txId', finalized.txId)
            .having(
              (error) => error.phase,
              'phase',
              GDevelopProjectAllocationPhase.workspaceFinalized,
            ),
      ),
    );
    expect(
      (await finalizedFixture.coordinator.status(finalized.txId)).phase,
      GDevelopProjectAllocationPhase.workspaceFinalized,
    );
    expect(
      await Directory(
        finalized.transaction.record.payload.stagingPath,
      ).exists(),
      isTrue,
    );

    var crash = true;
    final requestedFixture = await _AllocationFixture.create(
      crashHook: (point, _) {
        if (crash &&
            point == GDevelopProjectAllocationCrashPoint.afterCommitRequested) {
          crash = false;
          throw StateError('commit response lost');
        }
      },
    );
    addTearDown(requestedFixture.close);
    final requested = await requestedFixture.prepareWorkspace(
      'com.example.allocation-commit-requested-not-replaced',
      idempotencyKey: 'allocation-requested-first',
    );
    await requestedFixture.stageWorkspace(requested);
    await expectLater(
      requestedFixture.coordinator.commit(requested.txId),
      throwsStateError,
    );
    requestedFixture.coordinator = requestedFixture.newCoordinator();
    await expectLater(
      requestedFixture.prepareWorkspace(
        requested.gameId,
        idempotencyKey: 'allocation-requested-second',
      ),
      throwsA(
        isA<GDevelopProjectAllocationLocked>()
            .having((error) => error.txId, 'txId', requested.txId)
            .having(
              (error) => error.phase,
              'phase',
              GDevelopProjectAllocationPhase.commitRequested,
            ),
      ),
    );
    expect(
      (await requestedFixture.coordinator.status(requested.txId)).phase,
      GDevelopProjectAllocationPhase.commitRequested,
    );
    expect(
      await (await requestedFixture.projectRoot(requested.gameId)).exists(),
      isFalse,
      reason: '崩溃点位于 durable decision 后、canonical rename 前',
    );
  });

  test('durable decision/rename 崩溃后 recover 只向前且禁止 abort', () async {
    for (final crashPoint in const [
      GDevelopProjectAllocationCrashPoint.afterCommitRequested,
      GDevelopProjectAllocationCrashPoint.afterCanonicalRename,
    ]) {
      var crash = true;
      final fixture = await _AllocationFixture.create();
      addTearDown(fixture.close);
      final workspace = await fixture.prepareWorkspace(
        crashPoint == GDevelopProjectAllocationCrashPoint.afterCommitRequested
            ? 'com.example.allocation-crash-decision'
            : 'com.example.allocation-crash-rename',
      );
      await fixture.stageWorkspace(workspace);
      fixture.coordinator = fixture.newCoordinator(
        crashHook: (point, _) {
          if (crash && point == crashPoint) {
            crash = false;
            throw StateError('simulated commit crash');
          }
        },
      );
      await expectLater(
        fixture.coordinator.commit(workspace.txId),
        throwsStateError,
      );
      if (crashPoint ==
          GDevelopProjectAllocationCrashPoint.afterCommitRequested) {
        await expectLater(
          fixture.coordinator.abort(workspace.txId),
          throwsA(isA<GDevelopProjectAllocationUnavailable>()),
        );
      }
      fixture.coordinator = fixture.newCoordinator();
      expect(
        (await fixture.coordinator.recover(workspace.txId)).phase,
        GDevelopProjectAllocationPhase.committed,
      );
    }
  });

  test('COMMIT 前 staging 篡改转 CONFLICT；decision 后篡改保持可恢复状态', () async {
    final beforeFixture = await _AllocationFixture.create();
    addTearDown(beforeFixture.close);
    final before = await beforeFixture.prepareWorkspace(
      'com.example.allocation-tamper-before',
    );
    await beforeFixture.stageWorkspace(before);
    await beforeFixture
        .resourceObject(before, before.resourcePlan.first)
        .delete();
    final conflict = await beforeFixture.coordinator.commit(before.txId);
    expect(conflict.phase, GDevelopProjectAllocationPhase.conflict);
    expect(conflict.record.payload.conflict?['reason'], 'staging_changed');

    var crash = true;
    final afterFixture = await _AllocationFixture.create();
    addTearDown(afterFixture.close);
    final after = await afterFixture.prepareWorkspace(
      'com.example.allocation-tamper-after',
    );
    await afterFixture.stageWorkspace(after);
    afterFixture.coordinator = afterFixture.newCoordinator(
      crashHook: (point, _) {
        if (crash &&
            point == GDevelopProjectAllocationCrashPoint.afterCommitRequested) {
          crash = false;
          throw StateError('decision persisted');
        }
      },
    );
    await expectLater(
      afterFixture.coordinator.commit(after.txId),
      throwsStateError,
    );
    final resource = after.resourcePlan.first;
    final object = afterFixture.resourceObject(after, resource);
    await object.delete();
    afterFixture.coordinator = afterFixture.newCoordinator();
    expect(
      (await afterFixture.coordinator.recover(after.txId)).phase,
      GDevelopProjectAllocationPhase.commitRequested,
    );
    await object.parent.create(recursive: true);
    await object.writeAsBytes(
      after.resourceBytes[resource.logicalId]!,
      flush: true,
    );
    expect(
      (await afterFixture.coordinator.recover(after.txId)).phase,
      GDevelopProjectAllocationPhase.committed,
    );
  });

  test('占用 gameId 零 staging，项目级锁不阻塞不同 gameId', () async {
    final fixture = await _AllocationFixture.create();
    addTearDown(fixture.close);
    final unrelatedRoot = await fixture.projectRoot(
      'com.example.allocation-unrelated',
    );
    await unrelatedRoot.create(recursive: true);
    final unrelatedSentinel = File(
      '${unrelatedRoot.path}${Platform.pathSeparator}keep.txt',
    );
    await unrelatedSentinel.writeAsString('keep');
    final occupiedRoot = await fixture.projectRoot(
      'com.example.allocation-occupied',
    );
    await occupiedRoot.create(recursive: true);
    await expectLater(
      fixture.prepareWorkspace('com.example.allocation-occupied'),
      throwsA(isA<ProjectProvisioningConflict>()),
    );
    expect(await fixture.stagingDirectories(), isEmpty);
    expect(await unrelatedRoot.exists(), isTrue);
    expect(await unrelatedSentinel.readAsString(), 'keep');

    final entered = <String>{};
    final bothEntered = Completer<void>();
    final release = Completer<void>();
    final parallel = await _AllocationFixture.create(
      crashHook: (point, txId) async {
        if (point != GDevelopProjectAllocationCrashPoint.afterPrepared) return;
        entered.add(txId);
        if (entered.length == 2) bothEntered.complete();
        await release.future;
      },
    );
    addTearDown(parallel.close);
    final one = parallel.prepareWorkspace(
      'com.example.allocation-parallel-one',
      idempotencyKey: 'parallel-one',
    );
    final two = parallel.prepareWorkspace(
      'com.example.allocation-parallel-two',
      idempotencyKey: 'parallel-two',
    );
    await bothEntered.future.timeout(const Duration(seconds: 5));
    release.complete();
    final results = await Future.wait([one, two]);
    expect(
      results.map((item) => item.transaction.phase),
      everyElement(GDevelopProjectAllocationPhase.prepared),
    );
  });
}

class _PreparedWorkspace {
  const _PreparedWorkspace({
    required this.transaction,
    required this.projectBytes,
    required this.resourcePlan,
    required this.resourceBytes,
    required this.finalization,
  });

  final GDevelopProjectAllocationTransaction transaction;
  final Uint8List projectBytes;
  final List<GDevelopProjectResource> resourcePlan;
  final Map<String, Uint8List> resourceBytes;
  final GDevelopProjectAllocationWorkspaceFinalization finalization;

  String get txId => transaction.txId;
  String get gameId => transaction.gameId;
}

class _AllocationFixture {
  _AllocationFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.preparedTtl,
  });

  final Directory root;
  final FileSystemGDevelopProjectRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final Duration preparedTtl;
  DateTime now = DateTime.utc(2026, 8, 5, 8);
  int sequence = 0;
  late GDevelopProjectAllocationCoordinator coordinator;

  static Future<_AllocationFixture> create({
    Duration preparedTtl = const Duration(minutes: 10),
    GDevelopProjectAllocationCrashHook? crashHook,
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-allocation-');
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final fixture = _AllocationFixture(
      root: root,
      resolver: resolver,
      history: GDevelopProjectHistoryAdapter(rootResolver: resolver),
      preparedTtl: preparedTtl,
    );
    fixture.coordinator = fixture.newCoordinator(crashHook: crashHook);
    return fixture;
  }

  GDevelopProjectAllocationCoordinator newCoordinator({
    GDevelopProjectAllocationCrashHook? crashHook,
  }) => GDevelopProjectAllocationCoordinator(
    rootResolver: resolver,
    history: history,
    preparedTtl: preparedTtl,
    clock: () => now,
    idFactory: () => 'allocation-tx-${sequence++}',
    crashHook: crashHook,
  );

  Future<_PreparedWorkspace> prepareWorkspace(
    String gameId, {
    String idempotencyKey = 'allocation-click-1',
    String? projectPackageName,
    bool shareResourceContent = false,
  }) async {
    final projectUuid = 'project-$gameId';
    final firstLogical = 'playmesh-local-resource://file-$gameId/first';
    final secondLogical = 'playmesh-local-resource://file-$gameId/second';
    final firstBytes = Uint8List.fromList([1, 2, 3, 4]);
    final secondBytes = shareResourceContent
        ? Uint8List.fromList(firstBytes)
        : Uint8List.fromList([5, 6, 7]);
    final first = GDevelopProjectResource(
      logicalId: firstLogical,
      name: 'First',
      contentHash: await _sha(firstBytes),
      mime: 'image/png',
      size: firstBytes.length,
    );
    final second = GDevelopProjectResource(
      logicalId: secondLogical,
      name: 'Second',
      contentHash: await _sha(secondBytes),
      mime: shareResourceContent ? 'image/png' : 'audio/ogg',
      size: secondBytes.length,
    );
    // 官方工程顺序刻意与 logicalId 排序相反，用于锁定 manifest 语义。
    final officialOrder = [second, first];
    final project = {
      'gdVersion': {'major': 5, 'minor': 6},
      'properties': {
        'name': gameId,
        'packageName': projectPackageName ?? gameId,
        'projectUuid': projectUuid,
        'folderProject': true,
      },
      'resources': {
        'resources': [
          for (final resource in officialOrder)
            {
              'name': resource.name,
              'file': resource.logicalId,
              'kind': resource.mime.startsWith('image/') ? 'image' : 'audio',
            },
        ],
      },
      'layouts': [
        {
          '__REFERENCE_TO_SPLIT_OBJECT': true,
          'referenceTo': '/layouts/Main-scene',
        },
      ],
    };
    final projectBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          {'path': 'game.json', 'content': project},
          {
            'path': 'layouts/Main-scene.json',
            'content': {
              'name': 'Main scene',
              'mangledName': 'Main-scene',
              'objects': const [],
              'instances': const [],
            },
          },
        ]),
      ),
    );
    final projectHash = await _sha(projectBytes);
    final manifestHash = await PendingProjectCommitComparator.hashJson(
      officialOrder.map((resource) => resource.toJson()).toList(),
    );
    final finalization = GDevelopProjectAllocationWorkspaceFinalization(
      packageName: gameId,
      projectUuid: projectUuid,
      projectFilesHash: projectHash,
      projectFilesSize: projectBytes.length,
      resourceManifestHash: manifestHash,
    );
    final transaction = await coordinator.prepare(
      gameId: gameId,
      idempotencyKey: idempotencyKey,
      origin: GDevelopProjectAllocationOrigin.create,
      workspaceTarget: GDevelopProjectAllocationWorkspaceTarget(
        fileIdentifier: 'file-$gameId',
        gameId: gameId,
        packageName: gameId,
        projectUuid: projectUuid,
        projectFilesHash: projectHash,
        resourceManifestHash: manifestHash,
      ),
      name: gameId,
      clientId: 'web-ide-1',
    );
    return _PreparedWorkspace(
      transaction: transaction,
      projectBytes: projectBytes,
      resourcePlan: officialOrder,
      resourceBytes: {firstLogical: firstBytes, secondLogical: secondBytes},
      finalization: finalization,
    );
  }

  Future<void> stageWorkspace(_PreparedWorkspace workspace) async {
    await coordinator.resourcePresence(
      txId: workspace.txId,
      resources: workspace.resourcePlan.reversed.toList(),
    );
    for (final resource in workspace.resourcePlan) {
      await coordinator.uploadResource(
        txId: workspace.txId,
        contentHash: resource.contentHash,
        bytes: Stream.value(workspace.resourceBytes[resource.logicalId]!),
      );
    }
    await coordinator.uploadWorkspaceProjectFiles(
      txId: workspace.txId,
      bytes: Stream.value(workspace.projectBytes),
    );
    final transaction = await coordinator.finalizeWorkspace(
      txId: workspace.txId,
      evidence: workspace.finalization,
    );
    expect(
      transaction.phase,
      GDevelopProjectAllocationPhase.workspaceFinalized,
    );
  }

  File resourceObject(
    _PreparedWorkspace workspace,
    GDevelopProjectResource resource,
  ) => File(
    '${workspace.transaction.record.payload.stagingPath}'
    '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
    '${Platform.pathSeparator}source${Platform.pathSeparator}current'
    '${Platform.pathSeparator}resources'
    '${Platform.pathSeparator}${resource.contentHash}.blob',
  );

  Future<Directory> projectRoot(String gameId) =>
      resolver.projectRootLocation(gameId);

  Future<List<Directory>> stagingDirectories() async =>
      (await root.list(followLinks: false).toList())
          .whereType<Directory>()
          .where(
            (directory) =>
                _name(directory.path).startsWith('.playmesh-allocation-'),
          )
          .toList();

  Future<void> close() => root.delete(recursive: true);
}

Future<String> _sha(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String _name(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
