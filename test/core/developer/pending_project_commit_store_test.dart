import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/pending_project_commit_store.dart';

void main() {
  const codec = PendingProjectCommitCodec<Map<String, Object?>>(
    encode: _identityEncode,
    decode: _identityDecode,
  );

  test('prepare 以 idempotencyKey 幂等，复用 key 改请求或并发 tx 会冲突', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);

    final first = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'restore-click-1',
      payload: const {'targetRevision': 2},
    );
    final repeated = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'restore-click-1',
      payload: const {'targetRevision': 2},
    );
    expect(repeated.txId, first.txId);
    expect(repeated.phase, PendingProjectCommitPhase.prepared);

    await expectLater(
      fixture.store.prepare(
        gameId: 'com.example.pending',
        idempotencyKey: 'restore-click-1',
        payload: const {'targetRevision': 3},
      ),
      throwsA(isA<PendingProjectCommitIdempotencyConflict>()),
    );
    await expectLater(
      fixture.store.prepare(
        gameId: 'com.example.pending',
        idempotencyKey: 'restore-click-2',
        payload: const {'targetRevision': 2},
      ),
      throwsA(
        isA<PendingProjectCommitLocked>().having(
          (error) => error.activeTxId,
          'activeTxId',
          first.txId,
        ),
      ),
    );
  });

  test('PREPARED TTL 到期写稳定 ABORTED receipt，并允许新事务', () async {
    var now = DateTime.utc(2026, 8, 5);
    final fixture = await _PendingFixture.create(
      codec: codec,
      clock: () => now,
      preparedTtl: const Duration(minutes: 5),
    );
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'expired-prepare',
      payload: const {'targetRevision': 1},
    );
    now = now.add(const Duration(minutes: 6));

    final aborted = await fixture.store.status(prepared.txId);
    expect(aborted.phase, PendingProjectCommitPhase.aborted);
    expect(await fixture.store.active(), isNull);
    final repeated = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'expired-prepare',
      payload: const {'targetRevision': 1},
    );
    expect(repeated.txId, prepared.txId);
    expect(repeated.phase, PendingProjectCommitPhase.aborted);

    final next = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'next-prepare',
      payload: const {'targetRevision': 2},
    );
    expect(next.phase, PendingProjectCommitPhase.prepared);
  });

  test('COMMIT_REQUESTED 后不因 TTL 回滚，phase 只允许幂等前进', () async {
    var now = DateTime.utc(2026, 8, 5);
    final fixture = await _PendingFixture.create(
      codec: codec,
      clock: () => now,
      preparedTtl: const Duration(minutes: 1),
    );
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'commit-forward',
      payload: const {'step': 0},
    );
    final requested = await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.commitRequested,
      payload: const {'step': 1},
    );
    now = now.add(const Duration(days: 30));
    expect(
      (await fixture.store.status(prepared.txId)).phase,
      PendingProjectCommitPhase.commitRequested,
    );
    expect(
      (await fixture.store.advance(
        txId: prepared.txId,
        phase: PendingProjectCommitPhase.commitRequested,
        payload: const {'step': 1},
      )).updatedAt,
      requested.updatedAt,
      reason: '重复 phase 不能改写 durable evidence',
    );
    await expectLater(
      fixture.store.advance(
        txId: prepared.txId,
        phase: PendingProjectCommitPhase.backendCommitted,
        payload: const {'step': 3},
      ),
      throwsA(isA<PendingProjectCommitInvalidTransition>()),
    );
  });

  test('PAYLOAD_FINALIZED 冻结证据，重启后相同证据幂等且不同证据冲突', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'payload-finalized',
      payload: const {'step': 0},
    );
    final finalized = await fixture.store.markPayloadFinalized(
      txId: prepared.txId,
      payload: const {'step': 1, 'workspaceHash': 'project-a'},
      evidence: const {
        'resourceManifestHash': 'manifest-a',
        'projectFilesHash': 'project-a',
      },
    );

    expect(finalized.phase, PendingProjectCommitPhase.payloadFinalized);
    expect(finalized.payloadFinalizationHash, hasLength(64));
    expect(finalized.payloadFinalizationEvidence, const {
      'projectFilesHash': 'project-a',
      'resourceManifestHash': 'manifest-a',
    });

    final restarted = PendingProjectCommitStore<Map<String, Object?>>(
      root: fixture.root,
      namespace: 'test.pending-commit.v1',
      codec: codec,
      idFactory: () => 'unused',
    );
    final replayed = await restarted.markPayloadFinalized(
      txId: prepared.txId,
      payload: const {'step': 99},
      evidence: const {
        'projectFilesHash': 'project-a',
        'resourceManifestHash': 'manifest-a',
      },
    );
    expect(replayed.updatedAt, finalized.updatedAt);
    expect(replayed.payload, finalized.payload);
    await expectLater(
      restarted.markPayloadFinalized(
        txId: prepared.txId,
        payload: const {'step': 2},
        evidence: const {
          'projectFilesHash': 'project-b',
          'resourceManifestHash': 'manifest-a',
        },
      ),
      throwsA(isA<PendingProjectCommitPayloadFinalizationConflict>()),
    );
  });

  test('PAYLOAD_FINALIZED 可在决议前超时/放弃，COMMIT_REQUESTED 后只能前进', () async {
    var now = DateTime.utc(2026, 8, 5);
    final fixture = await _PendingFixture.create(
      codec: codec,
      clock: () => now,
      preparedTtl: const Duration(minutes: 5),
    );
    addTearDown(fixture.close);
    final first = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'finalized-expiry',
      payload: const {'step': 0},
    );
    await fixture.store.markPayloadFinalized(
      txId: first.txId,
      payload: const {'step': 1},
      evidence: const {'projectFilesHash': 'project-a'},
    );
    now = now.add(const Duration(minutes: 6));
    expect(
      (await fixture.store.status(first.txId)).phase,
      PendingProjectCommitPhase.aborted,
    );

    final second = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'finalized-commit',
      payload: const {'step': 0},
    );
    await fixture.store.markPayloadFinalized(
      txId: second.txId,
      payload: const {'step': 1},
      evidence: const {'projectFilesHash': 'project-b'},
    );
    await fixture.store.advance(
      txId: second.txId,
      phase: PendingProjectCommitPhase.commitRequested,
      payload: const {'step': 2},
    );
    await expectLater(
      fixture.store.abortPreDecision(second.txId),
      throwsA(isA<PendingProjectCommitInvalidTransition>()),
    );
    now = now.add(const Duration(days: 30));
    expect(
      (await fixture.store.status(second.txId)).phase,
      PendingProjectCommitPhase.commitRequested,
    );
  });

  test('ACK completion 先写 receipt 再释放 active，重启与响应丢失可重放', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'ack-replay',
      payload: const {'step': 0},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.commitRequested,
      payload: const {'step': 1},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.historyApplied,
      payload: const {'step': 2},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.backendCommitted,
      payload: const {'step': 3},
    );
    final completed = await fixture.store.complete(
      txId: prepared.txId,
      payload: const {'step': 4, 'eventEmitted': false},
    );
    expect(completed.phase, PendingProjectCommitPhase.browserPersisted);
    expect(await fixture.store.active(), isNull);

    final restarted = PendingProjectCommitStore<Map<String, Object?>>(
      root: fixture.root,
      namespace: 'test.pending-commit.v1',
      codec: codec,
      idFactory: () => 'unused',
    );
    final replayed = await restarted.complete(
      txId: prepared.txId,
      payload: const {'ignored': true},
    );
    expect(replayed.phase, PendingProjectCommitPhase.browserPersisted);
    expect(replayed.payload, const {'step': 4, 'eventEmitted': false});
  });

  test('提交决议后可进入幂等回滚链，ROLLED_BACK receipt 可跨重启重放', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'rollback-replay',
      payload: const {'step': 0},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.commitRequested,
      payload: const {'step': 1},
    );
    final requested = await fixture.store.requestRollback(
      txId: prepared.txId,
      payload: const {'step': 2},
    );
    expect(requested.phase, PendingProjectCommitPhase.rollbackRequested);
    final repeatedRequest = await fixture.store.requestRollback(
      txId: prepared.txId,
      payload: const {'ignored': true},
    );
    expect(repeatedRequest.updatedAt, requested.updatedAt);
    expect(repeatedRequest.payload, const {'step': 2});

    final completed = await fixture.store.completeRollback(
      txId: prepared.txId,
      payload: const {'step': 3},
    );
    expect(completed.phase, PendingProjectCommitPhase.rolledBack);
    expect(await fixture.store.active(), isNull);

    final restarted = PendingProjectCommitStore<Map<String, Object?>>(
      root: fixture.root,
      namespace: 'test.pending-commit.v1',
      codec: codec,
      idFactory: () => 'unused',
    );
    expect(
      (await restarted.requestRollback(
        txId: prepared.txId,
        payload: const {'ignored': true},
      )).payload,
      const {'step': 3},
    );
    expect(
      (await restarted.completeRollback(
        txId: prepared.txId,
        payload: const {'ignored': true},
      )).phase,
      PendingProjectCommitPhase.rolledBack,
    );
  });

  test('回滚链拒绝 PREPARED 与非回滚终态，ROLLED_BACK 计入 receipt', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'rollback-transitions',
      payload: const {'step': 0},
    );
    await expectLater(
      fixture.store.requestRollback(
        txId: prepared.txId,
        payload: const {'step': 1},
      ),
      throwsA(isA<PendingProjectCommitInvalidTransition>()),
    );
    await expectLater(
      fixture.store.completeRollback(
        txId: prepared.txId,
        payload: const {'step': 1},
      ),
      throwsA(isA<PendingProjectCommitInvalidTransition>()),
    );
    await fixture.store.abortPrepared(prepared.txId);
    await expectLater(
      fixture.store.requestRollback(
        txId: prepared.txId,
        payload: const {'step': 2},
      ),
      throwsA(isA<PendingProjectCommitInvalidTransition>()),
    );
  });

  test('完成 receipt 保留 payload finalization 证据并继续拒绝证据替换', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'finalization-receipt',
      payload: const {'step': 0},
    );
    await fixture.store.markPayloadFinalized(
      txId: prepared.txId,
      payload: const {'step': 1},
      evidence: const {'projectFilesHash': 'project-a'},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.commitRequested,
      payload: const {'step': 2},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.historyApplied,
      payload: const {'step': 3},
    );
    await fixture.store.advance(
      txId: prepared.txId,
      phase: PendingProjectCommitPhase.backendCommitted,
      payload: const {'step': 4},
    );
    final receipt = await fixture.store.complete(
      txId: prepared.txId,
      payload: const {'step': 5},
    );
    expect(receipt.payloadFinalizationEvidence, const {
      'projectFilesHash': 'project-a',
    });
    expect(
      (await fixture.store.markPayloadFinalized(
        txId: prepared.txId,
        payload: const {'ignored': true},
        evidence: const {'projectFilesHash': 'project-a'},
      )).phase,
      PendingProjectCommitPhase.browserPersisted,
    );
    await expectLater(
      fixture.store.markPayloadFinalized(
        txId: prepared.txId,
        payload: const {'ignored': true},
        evidence: const {'projectFilesHash': 'project-b'},
      ),
      throwsA(isA<PendingProjectCommitPayloadFinalizationConflict>()),
    );
  });

  test('CONFLICT 持续锁项目，普通恢复与TTL均不会自动覆盖', () async {
    var now = DateTime.utc(2026, 8, 5);
    final fixture = await _PendingFixture.create(
      codec: codec,
      clock: () => now,
      preparedTtl: const Duration(seconds: 1),
    );
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'third-state',
      payload: const {'step': 0},
    );
    await fixture.store.markConflict(
      txId: prepared.txId,
      payload: const {'current': 'neither-old-nor-target'},
    );
    now = now.add(const Duration(days: 1));

    expect(
      (await fixture.store.status(prepared.txId)).phase,
      PendingProjectCommitPhase.conflict,
    );
    await expectLater(
      fixture.store.ensureMutationAllowed(),
      throwsA(isA<PendingProjectCommitLocked>()),
    );

    final aborted = await fixture.store.abortConflict(prepared.txId);
    expect(aborted.phase, PendingProjectCommitPhase.aborted);
    expect(await fixture.store.active(), isNull);
  });

  test('requestValue 把客户意图与服务端冻结 payload 分离', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);

    final first = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'frozen-server-fields',
      requestValue: const {'targetRevision': 2},
      payload: const {'targetRevision': 2, 'updatedAt': 'first'},
    );
    final repeated = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'frozen-server-fields',
      requestValue: const {'targetRevision': 2},
      payload: const {'targetRevision': 2, 'updatedAt': 'second'},
    );

    expect(repeated.txId, first.txId);
    expect(repeated.payload['updatedAt'], 'first');
    await expectLater(
      fixture.store.prepare(
        gameId: 'com.example.pending',
        idempotencyKey: 'frozen-server-fields',
        requestValue: const {'targetRevision': 3},
        payload: const {'targetRevision': 3, 'updatedAt': 'third'},
      ),
      throwsA(isA<PendingProjectCommitIdempotencyConflict>()),
    );
  });

  test('findByIdempotencyKey 和 receipts 可用于重启恢复与事件补发', () async {
    final fixture = await _PendingFixture.create(codec: codec);
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'lookup-and-list',
      requestValue: const {'targetRevision': 2},
      payload: const {'step': 0},
    );
    expect(
      (await fixture.store.findByIdempotencyKey(
        idempotencyKey: 'lookup-and-list',
        requestValue: const {'targetRevision': 2},
      ))?.txId,
      prepared.txId,
    );
    await fixture.store.abortPrepared(prepared.txId);

    final receipts = await fixture.store.receipts();
    expect(receipts, hasLength(1));
    expect(receipts.single.txId, prepared.txId);
    expect(
      (await fixture.store.findByIdempotencyKey(
        idempotencyKey: 'lookup-and-list',
        requestValue: const {'targetRevision': 2},
      ))?.phase,
      PendingProjectCommitPhase.aborted,
    );
  });

  test('receipt 在保留期覆盖浏览器重启，过期后才被清理', () async {
    var now = DateTime.utc(2026, 8, 5);
    final fixture = await _PendingFixture.create(
      codec: codec,
      clock: () => now,
      receiptRetention: const Duration(days: 7),
    );
    addTearDown(fixture.close);
    final prepared = await fixture.store.prepare(
      gameId: 'com.example.pending',
      idempotencyKey: 'retained-receipt',
      payload: const {'step': 0},
    );
    await fixture.store.abortPrepared(prepared.txId);
    now = now.add(const Duration(days: 6));
    expect(
      (await fixture.store.status(prepared.txId)).phase,
      PendingProjectCommitPhase.aborted,
    );
    now = now.add(const Duration(days: 2));
    await expectLater(
      fixture.store.status(prepared.txId),
      throwsA(isA<PendingProjectCommitNotFound>()),
    );
  });

  test('不同项目 store 并行，单项目 journal 写入仍串行', () async {
    final parent = await Directory.systemTemp.createTemp('pending-parallel-');
    addTearDown(() => parent.delete(recursive: true));
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondEntered = Completer<void>();

    Future<File> renameFile(File source, String destination) async {
      if (source.path.endsWith('active.json.tmp')) {
        if (source.path.contains('project-a')) {
          firstEntered.complete();
          await releaseFirst.future;
        } else {
          secondEntered.complete();
        }
      }
      return source.rename(destination);
    }

    final first = PendingProjectCommitStore<Map<String, Object?>>(
      root: Directory('${parent.path}${Platform.pathSeparator}project-a'),
      namespace: 'test.pending-commit.v1',
      codec: codec,
      renameFile: renameFile,
      idFactory: () => 'tx-a',
    );
    final second = PendingProjectCommitStore<Map<String, Object?>>(
      root: Directory('${parent.path}${Platform.pathSeparator}project-b'),
      namespace: 'test.pending-commit.v1',
      codec: codec,
      renameFile: renameFile,
      idFactory: () => 'tx-b',
    );
    final firstFuture = first.prepare(
      gameId: 'com.example.a',
      idempotencyKey: 'a',
      payload: const {},
    );
    await firstEntered.future;
    final secondFuture = second.prepare(
      gameId: 'com.example.b',
      idempotencyKey: 'b',
      payload: const {},
    );
    await secondEntered.future.timeout(const Duration(seconds: 2));
    releaseFirst.complete();
    await Future.wait([firstFuture, secondFuture]);
  });

  test('canonical comparator 对 map 顺序稳定并区分真实变化', () async {
    expect(
      await PendingProjectCommitComparator.hashJson({
        'b': 2,
        'a': [1, true],
      }),
      await PendingProjectCommitComparator.hashJson({
        'a': [1, true],
        'b': 2,
      }),
    );
    expect(
      await PendingProjectCommitComparator.hashJson({'a': 1}),
      isNot(await PendingProjectCommitComparator.hashJson({'a': 2})),
    );
  });
}

class _PendingFixture {
  _PendingFixture(this.root, this.store);

  final Directory root;
  final PendingProjectCommitStore<Map<String, Object?>> store;

  Future<void> close() => root.delete(recursive: true);

  static Future<_PendingFixture> create({
    required PendingProjectCommitCodec<Map<String, Object?>> codec,
    DateTime Function()? clock,
    Duration preparedTtl = const Duration(minutes: 10),
    Duration receiptRetention = const Duration(days: 7),
  }) async {
    final root = await Directory.systemTemp.createTemp('pending-store-');
    var sequence = 0;
    return _PendingFixture(
      root,
      PendingProjectCommitStore<Map<String, Object?>>(
        root: root,
        namespace: 'test.pending-commit.v1',
        codec: codec,
        clock: clock,
        preparedTtl: preparedTtl,
        receiptRetention: receiptRetention,
        idFactory: () => 'tx-${sequence++}',
      ),
    );
  }
}

Object? _identityEncode(Map<String, Object?> value) => value;

Map<String, Object?> _identityDecode(Object? value) =>
    Map<String, Object?>.from(value! as Map);
