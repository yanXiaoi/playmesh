import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/pending_project_commit_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_rekey.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_restore_transaction.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';

void main() {
  test('Rekey 保留直达 commit 语义并拒绝不可达 PAYLOAD_FINALIZED', () {
    expect(
      () => GDevelopProjectRekeyPhase.fromStore(
        PendingProjectCommitPhase.payloadFinalized,
      ),
      throwsStateError,
    );
    expect(
      GDevelopProjectRekeyPhase.fromStore(
        PendingProjectCommitPhase.commitRequested,
      ),
      GDevelopProjectRekeyPhase.commitRequested,
    );
  });

  test('PREPARE 只写 sibling staging，COMMIT 发布新根，ACK 后才删除旧根', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.rekey-old');
    final oldRoot = await fixture.resolver.projectRootLocation(seed.gameId);
    final newRoot = await fixture.resolver.projectRootLocation(
      'com.example.rekey_new',
    );
    final sourceBefore = await fixture.identityBytes(oldRoot);

    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.rekey_new',
    );
    expect(prepared.phase, GDevelopProjectRekeyPhase.prepared);
    expect(await oldRoot.exists(), isTrue);
    expect(await newRoot.exists(), isFalse);
    expect(await fixture.identityBytes(oldRoot), sourceBefore);
    final siblings = await oldRoot.parent.list(followLinks: false).toList();
    expect(
      siblings.where(
        (entry) => _name(entry.path).startsWith('.playmesh-rekey-'),
      ),
      hasLength(1),
    );
    expect(
      () => fixture.resolver.ensureProjectRoot(
        gameId: 'com.example.rekey_new',
        origin: GDevelopProjectEnsureOrigin.open,
      ),
      throwsA(isA<ProjectProvisioningMissing>()),
      reason: 'resolver 只能发现 canonical target，不能发现 hidden staging',
    );

    final committed = await fixture.rekey.commit(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(
      committed.phase,
      GDevelopProjectRekeyPhase.newPublished,
      reason: committed.toJson().toString(),
    );
    expect(await oldRoot.exists(), isTrue, reason: '浏览器 ACK 前禁止删除 old');
    expect(await newRoot.exists(), isTrue);
    final targetMetadata = Map<String, Object?>.from(
      jsonDecode(
            await File(
              '${newRoot.path}${Platform.pathSeparator}.playmesh'
              '${Platform.pathSeparator}project.json',
            ).readAsString(),
          )
          as Map,
    );
    expect(
      targetMetadata['identityPolicy'],
      ProjectProvisioningService.androidApplicationIdIdentityPolicy,
    );
    expect(
      jsonDecode(
        await File(
          '${newRoot.path}${Platform.pathSeparator}main.json',
        ).readAsString(),
      )['id'],
      'com.example.rekey_new',
    );
    final targetConfig = await fixture.config.read('com.example.rekey_new');
    expect(targetConfig.config?.gameId, 'com.example.rekey_new');
    expect(targetConfig.config?.revision, seed.config.revision + 1);
    expect(
      (await fixture.history.current(
        'com.example.rekey_new',
      ))?.version.projectId,
      'com.example.rekey_new',
      reason: '旧历史不重写，通过 metadata alias 以新身份读取',
    );
    expect(fixture.approvalMigrations, isEmpty);
    expect(fixture.closedAiSessions, isEmpty);
    expect(fixture.stoppedPreviews, isEmpty);

    final acknowledged = await fixture.rekey.acknowledge(
      oldGameId: seed.gameId,
      txId: prepared.txId,
      browserEvidence: fixture.ackFor(newGameId: 'com.example.rekey_new'),
    );
    expect(acknowledged.phase, GDevelopProjectRekeyPhase.oldCleaned);
    expect(await oldRoot.exists(), isFalse);
    expect(await newRoot.exists(), isTrue);
    expect(fixture.approvalMigrations, [
      'com.example.rekey-old->com.example.rekey_new',
    ]);
    expect(fixture.closedAiSessions, ['com.example.rekey-old']);
    expect(fixture.stoppedPreviews, ['com.example.rekey-old']);
    expect(fixture.events.single['txId'], prepared.txId);
  });

  test('main.json 缺失时 rekey 不生成伪入口文件', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.rekey-no-main');
    final oldRoot = await fixture.resolver.projectRootLocation(seed.gameId);
    await File('${oldRoot.path}${Platform.pathSeparator}main.json').delete();

    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.rekey-no-main-target',
    );
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
    final newRoot = await fixture.resolver.projectRootLocation(
      'com.example.rekey-no-main-target',
    );

    expect(
      await File('${newRoot.path}${Platform.pathSeparator}main.json').exists(),
      isFalse,
    );
  });

  test('staging 身份重写失败会清理 staging 且 source 保持原样', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.rekey-invalid-alias');
    final oldRoot = await fixture.resolver.projectRootLocation(seed.gameId);
    final metadata = File(
      '${oldRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    final decoded = Map<String, Object?>.from(
      jsonDecode(await metadata.readAsString()) as Map,
    )..['previousGameIds'] = 'invalid';
    await metadata.writeAsString(jsonEncode(decoded), flush: true);
    final sourceBefore = await fixture.identityBytes(oldRoot);

    await expectLater(
      fixture.prepare(
        seed,
        newGameId: 'com.example.rekey-invalid-alias-target',
      ),
      throwsFormatException,
    );

    expect(await fixture.identityBytes(oldRoot), sourceBefore);
    expect(
      (await oldRoot.parent.list(followLinks: false).toList()).where(
        (entry) => _name(entry.path).startsWith('.playmesh-rekey-'),
      ),
      isEmpty,
    );
  });

  test('完成后的 ACK 重试仍必须精确匹配已持久化 evidence', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.rekey-ack-replay');
    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.rekey-ack-replay-target',
    );
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
    await fixture.rekey.acknowledge(
      oldGameId: seed.gameId,
      txId: prepared.txId,
      browserEvidence: fixture.ackFor(
        newGameId: 'com.example.rekey-ack-replay-target',
      ),
    );

    await expectLater(
      fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: GDevelopProjectRekeyBrowserEvidence(
          fileIdentifier: 'web-file-1',
          gameId: 'com.example.rekey-ack-replay-target',
          packageName: 'com.example.rekey-ack-replay-target',
          projectFilesHash: 'c' * 64,
        ),
      ),
      throwsA(isA<GDevelopProjectRekeyAckMismatch>()),
    );
  });

  test(
    'target 已占用返回 project_id_conflict 且 source/target/staging 零变化',
    () async {
      final fixture = await _RekeyFixture.create();
      addTearDown(fixture.close);
      final source = await fixture.seed('com.example.conflict-source');
      await fixture.seed('com.example.conflict-target');
      final oldRoot = await fixture.resolver.projectRootLocation(source.gameId);
      final targetRoot = await fixture.resolver.projectRootLocation(
        'com.example.conflict-target',
      );
      final oldBefore = await fixture.identityBytes(oldRoot);
      final targetBefore = await fixture.identityBytes(targetRoot);

      await expectLater(
        fixture.prepare(source, newGameId: 'com.example.conflict-target'),
        throwsA(isA<ProjectProvisioningConflict>()),
      );
      expect(await fixture.identityBytes(oldRoot), oldBefore);
      expect(await fixture.identityBytes(targetRoot), targetBefore);
      expect(
        (await oldRoot.parent.list(followLinks: false).toList()).where(
          (entry) => _name(entry.path).startsWith('.playmesh-rekey-'),
        ),
        isEmpty,
      );
    },
  );

  test('COMMIT_REQUESTED 默认回滚，BROWSER_UPDATED 等浏览器反向 ACK 后回滚', () async {
    for (final crashPoint in const [
      GDevelopProjectRekeyCrashPoint.afterCommitRequested,
      GDevelopProjectRekeyCrashPoint.afterBrowserUpdated,
    ]) {
      final fixture = await _RekeyFixture.create();
      addTearDown(fixture.close);
      final seed = await fixture.seed('com.example.crash-old');
      final prepared = await fixture.prepare(
        seed,
        newGameId: 'com.example.crash-new',
      );
      var crashed = false;
      fixture.rekey = fixture.newCoordinator(
        crashHook: (point, _) {
          if (!crashed && point == crashPoint) {
            crashed = true;
            throw StateError('simulated crash');
          }
        },
      );
      if (crashPoint == GDevelopProjectRekeyCrashPoint.afterCommitRequested) {
        await expectLater(
          fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId),
          throwsStateError,
        );
        fixture.rekey = fixture.newCoordinator();
        final recovered = await fixture.rekey.recover(seed.gameId);
        expect(
          recovered.transaction?.phase,
          GDevelopProjectRekeyPhase.rolledBack,
        );
        expect(
          await (await fixture.resolver.projectRootLocation(
            seed.gameId,
          )).exists(),
          isTrue,
        );
        expect(
          await (await fixture.resolver.projectRootLocation(
            'com.example.crash-new',
          )).exists(),
          isFalse,
        );
      } else {
        await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
        await expectLater(
          fixture.rekey.acknowledge(
            oldGameId: seed.gameId,
            txId: prepared.txId,
            browserEvidence: fixture.ackFor(newGameId: 'com.example.crash-new'),
          ),
          throwsStateError,
        );
        fixture.rekey = fixture.newCoordinator();
        final recovered = await fixture.rekey.recover(seed.gameId);
        expect(
          recovered.transaction?.phase,
          GDevelopProjectRekeyPhase.rollbackRequested,
        );
        final rolledBack = await fixture.rekey.rollback(
          oldGameId: seed.gameId,
          txId: prepared.txId,
          browserEvidence: fixture.rollbackAckFor(oldGameId: seed.gameId),
        );
        expect(rolledBack.phase, GDevelopProjectRekeyPhase.rolledBack);
        expect(
          await (await fixture.resolver.projectRootLocation(
            seed.gameId,
          )).exists(),
          isTrue,
        );
        expect(
          await (await fixture.resolver.projectRootLocation(
            'com.example.crash-new',
          )).exists(),
          isFalse,
        );
      }
    }
  });

  test('浏览器反向 evidence 缺失时持续锁定，重启与重复请求不会删除新根', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.rollback-reverse-old');
    const newGameId = 'com.example.rollback-reverse-new';
    final prepared = await fixture.prepare(seed, newGameId: newGameId);
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);

    final requested = await fixture.rekey.rollback(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(requested.phase, GDevelopProjectRekeyPhase.rollbackRequested);
    await expectLater(
      fixture.rekey.ensureMutationAllowed(seed.gameId),
      throwsA(isA<GDevelopProjectRekeyMutationLocked>()),
    );
    final repeated = await fixture.rekey.rollback(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(repeated.record.updatedAt, requested.record.updatedAt);

    fixture.rekey = fixture.newCoordinator();
    final recovered = await fixture.rekey.recover(seed.gameId);
    expect(
      recovered.transaction?.phase,
      GDevelopProjectRekeyPhase.rollbackRequested,
    );
    expect(
      await (await fixture.resolver.projectRootLocation(newGameId)).exists(),
      isTrue,
    );
    await expectLater(
      fixture.rekey.rollback(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: GDevelopProjectRekeyBrowserEvidence(
          fileIdentifier: 'web-file-1',
          gameId: seed.gameId,
          packageName: seed.gameId,
          projectFilesHash: 'c' * 64,
        ),
      ),
      throwsA(isA<GDevelopProjectRekeyAckMismatch>()),
    );

    final rolledBack = await fixture.rekey.rollback(
      oldGameId: seed.gameId,
      txId: prepared.txId,
      browserEvidence: fixture.rollbackAckFor(oldGameId: seed.gameId),
    );
    expect(rolledBack.phase, GDevelopProjectRekeyPhase.rolledBack);
    expect(
      await (await fixture.resolver.projectRootLocation(seed.gameId)).exists(),
      isTrue,
    );
    expect(
      await (await fixture.resolver.projectRootLocation(newGameId)).exists(),
      isFalse,
    );
  });

  test('回滚各 durable crash point 可恢复，响应丢失后的重复 rollback 返回同一 receipt', () async {
    for (final crashPoint in const [
      GDevelopProjectRekeyCrashPoint.afterRollbackRequested,
      GDevelopProjectRekeyCrashPoint.afterBrowserRollbackRecorded,
      GDevelopProjectRekeyCrashPoint.afterNewRollbackCleanup,
      GDevelopProjectRekeyCrashPoint.afterRollbackReceipt,
    ]) {
      final fixture = await _RekeyFixture.create();
      addTearDown(fixture.close);
      final suffix = crashPoint.name.toLowerCase();
      final seed = await fixture.seed('com.example.$suffix-old');
      final newGameId = 'com.example.$suffix-new';
      final prepared = await fixture.prepare(seed, newGameId: newGameId);
      await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
      var crashed = false;
      fixture.rekey = fixture.newCoordinator(
        crashHook: (point, _) {
          if (!crashed && point == crashPoint) {
            crashed = true;
            throw StateError('simulated rollback response loss');
          }
        },
      );
      await expectLater(
        fixture.rekey.rollback(
          oldGameId: seed.gameId,
          txId: prepared.txId,
          browserEvidence: fixture.rollbackAckFor(oldGameId: seed.gameId),
        ),
        throwsStateError,
      );

      fixture.rekey = fixture.newCoordinator();
      await fixture.rekey.recover(seed.gameId);
      final status = await fixture.rekey.status(
        oldGameId: seed.gameId,
        txId: prepared.txId,
      );
      expect(status.phase, GDevelopProjectRekeyPhase.rolledBack);
      final repeated = await fixture.rekey.rollback(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: fixture.rollbackAckFor(oldGameId: seed.gameId),
      );
      expect(repeated.record.updatedAt, status.record.updatedAt);
      expect(
        await (await fixture.resolver.projectRootLocation(
          seed.gameId,
        )).exists(),
        isTrue,
      );
      expect(
        await (await fixture.resolver.projectRootLocation(newGameId)).exists(),
        isFalse,
      );
    }
  });

  test('旧根已原子 rename 为墓碑但 receipt 响应丢失时，重启识别提交点并完成', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.tombstone-crash-old');
    const newGameId = 'com.example.tombstone-crash-new';
    final prepared = await fixture.prepare(seed, newGameId: newGameId);
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
    var crashed = false;
    fixture.rekey = fixture.newCoordinator(
      crashHook: (point, _) {
        if (!crashed &&
            point == GDevelopProjectRekeyCrashPoint.afterOldTombstoneRename) {
          crashed = true;
          throw StateError('simulated tombstone rename response loss');
        }
      },
    );
    await expectLater(
      fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: fixture.ackFor(newGameId: newGameId),
      ),
      throwsStateError,
    );
    expect(
      await (await fixture.resolver.projectRootLocation(seed.gameId)).exists(),
      isFalse,
    );

    fixture.rekey = fixture.newCoordinator();
    await fixture.rekey.recover(seed.gameId);
    final completed = await fixture.rekey.status(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(completed.phase, GDevelopProjectRekeyPhase.oldCleaned);
    expect(fixture.approvalMigrations, hasLength(1));
    expect(fixture.closedAiSessions, hasLength(1));
    expect(fixture.stoppedPreviews, hasLength(1));
  });

  test('decision 前冲突与 decision 后 target 验证失败均不触发 AI/approval 副作用', () async {
    final preDecision = await _RekeyFixture.create();
    addTearDown(preDecision.close);
    final preSeed = await preDecision.seed('com.example.no-ai-pre-old');
    final prePrepared = await preDecision.prepare(
      preSeed,
      newGameId: 'com.example.no-ai-pre-new',
    );
    final occupied = await preDecision.resolver.projectRootLocation(
      'com.example.no-ai-pre-new',
    );
    await occupied.create(recursive: true);
    await File(
      '${occupied.path}${Platform.pathSeparator}external',
    ).writeAsString('keep');
    final preConflict = await preDecision.rekey.commit(
      oldGameId: preSeed.gameId,
      txId: prePrepared.txId,
    );
    expect(preConflict.phase, GDevelopProjectRekeyPhase.conflict);
    expect(preDecision.approvalMigrations, isEmpty);
    expect(preDecision.closedAiSessions, isEmpty);
    expect(preDecision.stoppedPreviews, isEmpty);

    final postDecision = await _RekeyFixture.create();
    addTearDown(postDecision.close);
    final postSeed = await postDecision.seed('com.example.no-ai-post-old');
    final postPrepared = await postDecision.prepare(
      postSeed,
      newGameId: 'com.example.no-ai-post-new',
    );
    var crashed = false;
    postDecision.rekey = postDecision.newCoordinator(
      crashHook: (point, _) {
        if (!crashed &&
            point == GDevelopProjectRekeyCrashPoint.afterCommitRequested) {
          crashed = true;
          throw StateError('simulated decision response loss');
        }
      },
    );
    await expectLater(
      postDecision.rekey.commit(
        oldGameId: postSeed.gameId,
        txId: postPrepared.txId,
      ),
      throwsStateError,
    );
    final postTarget = await postDecision.resolver.projectRootLocation(
      'com.example.no-ai-post-new',
    );
    await postTarget.create(recursive: true);
    await File(
      '${postTarget.path}${Platform.pathSeparator}external',
    ).writeAsString('mismatch');
    postDecision.rekey = postDecision.newCoordinator();

    final recovered = await postDecision.rekey.recover(postSeed.gameId);
    expect(recovered.transaction?.phase, GDevelopProjectRekeyPhase.conflict);
    expect(
      recovered.transaction?.record.payload.conflict?['reason'],
      'rollback_commit_artifacts_ambiguous',
    );
    expect(postDecision.approvalMigrations, isEmpty);
    expect(postDecision.closedAiSessions, isEmpty);
    expect(postDecision.stoppedPreviews, isEmpty);
  });

  test('ACK 前 target 篡改保持 NEW_PUBLISHED，修复后原 ACK 幂等收敛', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.ack-tamper-old');
    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.ack-tamper-new',
    );
    final committed = await fixture.rekey.commit(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(committed.phase, GDevelopProjectRekeyPhase.newPublished);
    final target = await fixture.resolver.projectRootLocation(
      'com.example.ack-tamper-new',
    );
    await File(
      '${target.path}${Platform.pathSeparator}external.txt',
    ).writeAsString('changed');

    final evidence = fixture.ackFor(newGameId: 'com.example.ack-tamper-new');
    await expectLater(
      fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: evidence,
      ),
      throwsA(isA<GDevelopProjectRekeyTargetChanged>()),
    );
    await expectLater(
      fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: evidence,
      ),
      throwsA(isA<GDevelopProjectRekeyTargetChanged>()),
    );
    final status = await fixture.rekey.status(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(status.phase, GDevelopProjectRekeyPhase.newPublished);
    expect(status.record.payload.conflict, isNull);
    await expectLater(
      fixture.rekey.abort(oldGameId: seed.gameId, txId: prepared.txId),
      throwsA(
        isA<GDevelopProjectRekeyUnavailable>().having(
          (error) => error.phase,
          'phase',
          GDevelopProjectRekeyPhase.newPublished,
        ),
      ),
    );
    expect(fixture.approvalMigrations, isEmpty);
    expect(fixture.closedAiSessions, isEmpty);
    expect(fixture.stoppedPreviews, isEmpty);

    await File('${target.path}${Platform.pathSeparator}external.txt').delete();
    final repaired = await fixture.rekey.acknowledge(
      oldGameId: seed.gameId,
      txId: prepared.txId,
      browserEvidence: evidence,
    );
    expect(repaired.phase, GDevelopProjectRekeyPhase.oldCleaned);
    expect(fixture.approvalMigrations, hasLength(1));
    expect(fixture.closedAiSessions, hasLength(1));
    expect(fixture.stoppedPreviews, hasLength(1));
  });

  test('durable BROWSER_UPDATED 后 target 篡改进入稳定 CONFLICT 且零副作用', () async {
    final fixture = await _RekeyFixture.create();
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.browser-tamper-old');
    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.browser-tamper-new',
    );
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
    var crashed = false;
    fixture.rekey = fixture.newCoordinator(
      crashHook: (point, _) {
        if (!crashed &&
            point == GDevelopProjectRekeyCrashPoint.afterBrowserUpdated) {
          crashed = true;
          throw StateError('simulated browser-updated response loss');
        }
      },
    );
    await expectLater(
      fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: fixture.ackFor(
          newGameId: 'com.example.browser-tamper-new',
        ),
      ),
      throwsStateError,
    );
    final target = await fixture.resolver.projectRootLocation(
      'com.example.browser-tamper-new',
    );
    final tamper = File('${target.path}${Platform.pathSeparator}external.txt');
    await tamper.writeAsString('changed');
    fixture.rekey = fixture.newCoordinator();

    final pending = await fixture.rekey.recover(seed.gameId);
    expect(pending.transaction?.phase, GDevelopProjectRekeyPhase.conflict);
    expect(
      pending.transaction?.record.payload.conflict?['reason'],
      'rollback_target_evidence_mismatch',
    );
    expect(fixture.approvalMigrations, isEmpty);
    expect(fixture.closedAiSessions, isEmpty);
    expect(fixture.stoppedPreviews, isEmpty);

    await tamper.delete();
    final recovered = await fixture.rekey.recover(seed.gameId);
    expect(recovered.transaction?.phase, GDevelopProjectRekeyPhase.conflict);
    expect(fixture.approvalMigrations, isEmpty);
    expect(fixture.closedAiSessions, isEmpty);
    expect(fixture.stoppedPreviews, isEmpty);
  });

  test('各副作用 durable 标记后的崩溃由 recover 幂等收敛且不重复执行', () async {
    for (final crashPoint in const [
      GDevelopProjectRekeyCrashPoint.afterGrantsMigrated,
      GDevelopProjectRekeyCrashPoint.afterServicesClosed,
      GDevelopProjectRekeyCrashPoint.afterTombstoneCleanup,
    ]) {
      final fixture = await _RekeyFixture.create();
      addTearDown(fixture.close);
      final suffix = crashPoint.name.toLowerCase();
      final seed = await fixture.seed('com.example.side-effect-$suffix-old');
      final newGameId = 'com.example.side-effect-$suffix-new';
      final prepared = await fixture.prepare(seed, newGameId: newGameId);
      await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
      var crashed = false;
      fixture.rekey = fixture.newCoordinator(
        crashHook: (point, _) {
          if (!crashed && point == crashPoint) {
            crashed = true;
            throw StateError('simulated side-effect crash');
          }
        },
      );
      await expectLater(
        fixture.rekey.acknowledge(
          oldGameId: seed.gameId,
          txId: prepared.txId,
          browserEvidence: fixture.ackFor(newGameId: newGameId),
        ),
        throwsStateError,
      );
      fixture.rekey = fixture.newCoordinator();

      final recovered = await fixture.rekey.recover(seed.gameId);
      expect(recovered.transaction, isNull);
      expect(
        (await fixture.rekey.status(
          oldGameId: seed.gameId,
          txId: prepared.txId,
        )).phase,
        GDevelopProjectRekeyPhase.oldCleaned,
      );
      expect(fixture.approvalMigrations, hasLength(1));
      expect(fixture.closedAiSessions, hasLength(1));
      expect(fixture.stoppedPreviews, hasLength(1));
      final replay = await fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: fixture.ackFor(newGameId: newGameId),
      );
      expect(replay.phase, GDevelopProjectRekeyPhase.oldCleaned);
      expect(fixture.approvalMigrations, hasLength(1));
      expect(fixture.closedAiSessions, hasLength(1));
      expect(fixture.stoppedPreviews, hasLength(1));
    }
  });

  test(
    'approval 与 preview 部分失败保留 OLD_CLEANED receipt 并由 recover 幂等重试',
    () async {
      final approvalFixture = await _RekeyFixture.create();
      addTearDown(approvalFixture.close);
      final approvalSeed = await approvalFixture.seed(
        'com.example.approval-retry-old',
      );
      final approvalPrepared = await approvalFixture.prepare(
        approvalSeed,
        newGameId: 'com.example.approval-retry-new',
      );
      await approvalFixture.rekey.commit(
        oldGameId: approvalSeed.gameId,
        txId: approvalPrepared.txId,
      );
      var approvalAttempts = 0;
      Future<void> migrateApproval(String oldGameId, String newGameId) async {
        approvalAttempts++;
        if (approvalAttempts == 1) throw StateError('approval busy');
        approvalFixture.approvalMigrations.add('$oldGameId->$newGameId');
      }

      approvalFixture.rekey = approvalFixture.newCoordinator(
        approvalMigrator: migrateApproval,
      );
      final approvalPending = await approvalFixture.rekey.acknowledge(
        oldGameId: approvalSeed.gameId,
        txId: approvalPrepared.txId,
        browserEvidence: approvalFixture.ackFor(
          newGameId: 'com.example.approval-retry-new',
        ),
      );
      expect(approvalPending.phase, GDevelopProjectRekeyPhase.oldCleaned);
      expect(approvalPending.record.payload.cleanupPending, isTrue);
      expect(
        approvalPending.record.payload.cleanupError,
        'approval_migration_pending',
      );
      expect(approvalAttempts, 1);
      expect(approvalFixture.closedAiSessions, [approvalSeed.gameId]);
      expect(approvalFixture.stoppedPreviews, isEmpty);
      approvalFixture.rekey = approvalFixture.newCoordinator(
        approvalMigrator: migrateApproval,
      );
      final approvalRecovered = await approvalFixture.rekey.recover(
        approvalSeed.gameId,
      );
      expect(approvalRecovered.transaction, isNull);
      expect(approvalAttempts, 2);
      expect(approvalFixture.approvalMigrations, hasLength(1));
      expect(approvalFixture.closedAiSessions, hasLength(1));
      expect(approvalFixture.stoppedPreviews, hasLength(1));
      await approvalFixture.rekey.recover(approvalSeed.gameId);
      expect(approvalAttempts, 2);

      final serviceFixture = await _RekeyFixture.create();
      addTearDown(serviceFixture.close);
      final serviceSeed = await serviceFixture.seed(
        'com.example.service-retry-old',
      );
      final servicePrepared = await serviceFixture.prepare(
        serviceSeed,
        newGameId: 'com.example.service-retry-new',
      );
      await serviceFixture.rekey.commit(
        oldGameId: serviceSeed.gameId,
        txId: servicePrepared.txId,
      );
      var closeAttempts = 0;
      var previewAttempts = 0;
      void closeSessions(String gameId) {
        closeAttempts++;
        serviceFixture.closedAiSessions.add(gameId);
      }

      void stopPreview(String gameId) {
        previewAttempts++;
        if (previewAttempts == 1) throw StateError('preview busy');
        serviceFixture.stoppedPreviews.add(gameId);
      }

      serviceFixture.rekey = serviceFixture.newCoordinator(
        aiSessionCloser: closeSessions,
        previewStopper: stopPreview,
      );
      final servicePending = await serviceFixture.rekey.acknowledge(
        oldGameId: serviceSeed.gameId,
        txId: servicePrepared.txId,
        browserEvidence: serviceFixture.ackFor(
          newGameId: 'com.example.service-retry-new',
        ),
      );
      expect(servicePending.phase, GDevelopProjectRekeyPhase.oldCleaned);
      expect(servicePending.record.payload.cleanupPending, isTrue);
      expect(
        servicePending.record.payload.cleanupError,
        'service_cleanup_pending',
      );
      expect(serviceFixture.approvalMigrations, hasLength(1));
      expect(closeAttempts, 1);
      expect(previewAttempts, 1);
      serviceFixture.rekey = serviceFixture.newCoordinator(
        aiSessionCloser: closeSessions,
        previewStopper: stopPreview,
      );
      final serviceRecovered = await serviceFixture.rekey.recover(
        serviceSeed.gameId,
      );
      expect(serviceRecovered.transaction, isNull);
      expect(serviceFixture.approvalMigrations, hasLength(1));
      expect(closeAttempts, 1, reason: 'durable aiSessionsClosed 后不能重复关闭');
      expect(previewAttempts, 2);
      expect(serviceFixture.stoppedPreviews, hasLength(1));
    },
  );

  test(
    '墓碑逻辑提交后的 session close 失败进入 receipt cleanup，recover 只重试旧 gameId',
    () async {
      final fixture = await _RekeyFixture.create();
      addTearDown(fixture.close);
      final seed = await fixture.seed('com.example.close-fault-old');
      const newGameId = 'com.example.close-fault-new';
      final prepared = await fixture.prepare(seed, newGameId: newGameId);
      await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
      var closeAttempts = 0;
      final closed = <String>[];
      void closeSessions(String gameId) {
        closeAttempts += 1;
        expect(
          gameId,
          seed.gameId,
          reason: '新 gameId 的 session 不能被旧身份 rekey 误伤',
        );
        if (closeAttempts == 1) throw StateError('session close busy');
        closed.add(gameId);
      }

      fixture.rekey = fixture.newCoordinator(aiSessionCloser: closeSessions);
      final pending = await fixture.rekey.acknowledge(
        oldGameId: seed.gameId,
        txId: prepared.txId,
        browserEvidence: fixture.ackFor(newGameId: newGameId),
      );
      expect(pending.phase, GDevelopProjectRekeyPhase.oldCleaned);
      expect(pending.record.payload.cleanupPending, isTrue);
      expect(pending.record.payload.cleanupError, 'service_cleanup_pending');
      expect(closeAttempts, 1);
      expect(closed, isEmpty);
      expect(
        await fixture.resolver
            .projectRootLocation(seed.gameId)
            .then((root) => root.exists()),
        isFalse,
      );
      expect(
        await fixture.resolver
            .projectRootLocation(newGameId)
            .then((root) => root.exists()),
        isTrue,
      );

      final recovered = await fixture.rekey.recover(seed.gameId);
      expect(recovered.transaction, isNull);
      expect(closeAttempts, 2);
      expect(closed, [seed.gameId]);
      await fixture.rekey.recover(seed.gameId);
      expect(closeAttempts, 2, reason: 'durable servicesClosed 后不得重复副作用');
    },
  );

  test('cleanupPending 保留 old tombstone、放行 new，并由 recover 幂等清理', () async {
    var failCleanup = true;
    late _RekeyFixture fixture;
    fixture = await _RekeyFixture.create(
      deleteDirectory: (directory) async {
        if (failCleanup &&
            _name(directory.path).startsWith('.playmesh-rekey-tombstone-')) {
          throw FileSystemException('busy', directory.path);
        }
        await directory.delete(recursive: true);
      },
    );
    addTearDown(fixture.close);
    final seed = await fixture.seed('com.example.cleanup-old');
    final prepared = await fixture.prepare(
      seed,
      newGameId: 'com.example.cleanup-new',
    );
    await fixture.rekey.commit(oldGameId: seed.gameId, txId: prepared.txId);
    final receipt = await fixture.rekey.acknowledge(
      oldGameId: seed.gameId,
      txId: prepared.txId,
      browserEvidence: fixture.ackFor(newGameId: 'com.example.cleanup-new'),
    );
    expect(receipt.record.payload.cleanupPending, isTrue);
    expect(receipt.phase, GDevelopProjectRekeyPhase.oldCleaned);
    expect(
      await Directory(receipt.record.payload.tombstonePath).exists(),
      isTrue,
    );
    await expectLater(
      fixture.rekey.ensureMutationAllowed(seed.gameId),
      throwsA(isA<GDevelopProjectRekeyMutationLocked>()),
    );
    await fixture.rekey.ensureMutationAllowed('com.example.cleanup-new');

    final stillPending = await fixture.rekey.recover(seed.gameId);
    expect(stillPending.cleanupPendingTxIds, [prepared.txId]);
    expect(stillPending.transaction, isNull);

    failCleanup = false;
    final cleaned = await fixture.rekey.recover(seed.gameId);
    expect(cleaned.cleanupPendingTxIds, isEmpty);
    final recovered = await fixture.rekey.status(
      oldGameId: seed.gameId,
      txId: prepared.txId,
    );
    expect(recovered.phase, GDevelopProjectRekeyPhase.oldCleaned);
    expect(recovered.record.payload.cleanupPending, isFalse);
    await fixture.rekey.ensureMutationAllowed(seed.gameId);
    expect(
      await (await fixture.resolver.projectRootLocation(seed.gameId)).exists(),
      isFalse,
    );
  });

  test('rekey 与 create/另一 rekey 抢同 target 时只有先持锁者成功', () async {
    final preparedEntered = Completer<void>();
    final releasePrepare = Completer<void>();
    late _RekeyFixture fixture;
    fixture = await _RekeyFixture.create(
      crashHook: (point, _) async {
        if (point == GDevelopProjectRekeyCrashPoint.afterPrepared &&
            !preparedEntered.isCompleted) {
          preparedEntered.complete();
          await releasePrepare.future;
        }
      },
    );
    addTearDown(fixture.close);
    final first = await fixture.seed('com.example.race-first');
    final second = await fixture.seed('com.example.race-second');
    final prepareFirst = fixture.prepare(
      first,
      newGameId: 'com.example.race-target',
    );
    await preparedEntered.future;

    final create = fixture.restore.runProjectAllocation(
      'com.example.race-target',
      () => fixture.history.createProjectRoot(
        gameId: 'com.example.race-target',
        origin: GDevelopProjectEnsureOrigin.create,
        name: 'must lose',
      ),
    );
    final prepareSecond = fixture.prepare(
      second,
      newGameId: 'com.example.race-target',
      idempotencyKey: 'rekey-race-second',
    );
    releasePrepare.complete();
    final winner = await prepareFirst;
    expect(winner.phase, GDevelopProjectRekeyPhase.prepared);
    await expectLater(
      create,
      throwsA(isA<GDevelopProjectRekeyMutationLocked>()),
    );
    await expectLater(
      prepareSecond,
      throwsA(isA<GDevelopProjectRekeyMutationLocked>()),
    );
  });

  test('不相交 rekey 可并行，反向 old/new 请求无死锁', () async {
    final entered = <String>{};
    final bothEntered = Completer<void>();
    final release = Completer<void>();
    late _RekeyFixture fixture;
    fixture = await _RekeyFixture.create(
      crashHook: (point, txId) async {
        if (point != GDevelopProjectRekeyCrashPoint.afterPrepared) return;
        entered.add(txId);
        if (entered.length == 2 && !bothEntered.isCompleted) {
          bothEntered.complete();
        }
        await release.future;
      },
    );
    addTearDown(fixture.close);
    final first = await fixture.seed('com.example.parallel-a');
    final second = await fixture.seed('com.example.parallel-b');
    final one = fixture.prepare(
      first,
      newGameId: 'com.example.parallel-new-a',
      idempotencyKey: 'parallel-a',
    );
    final two = fixture.prepare(
      second,
      newGameId: 'com.example.parallel-new-b',
      idempotencyKey: 'parallel-b',
    );
    await bothEntered.future.timeout(const Duration(seconds: 5));
    release.complete();
    await Future.wait([one, two]);

    final reverseA = await fixture.seed('com.example.reverse-a');
    final reverseB = await fixture.seed('com.example.reverse-b');
    final results = await Future.wait([
      fixture
          .prepare(
            reverseA,
            newGameId: reverseB.gameId,
            idempotencyKey: 'reverse-a',
          )
          .then<Object>((value) => value, onError: (Object error) => error),
      fixture
          .prepare(
            reverseB,
            newGameId: reverseA.gameId,
            idempotencyKey: 'reverse-b',
          )
          .then<Object>((value) => value, onError: (Object error) => error),
    ]).timeout(const Duration(seconds: 5));
    expect(results, everyElement(isA<ProjectProvisioningConflict>()));
  });
}

class _Seed {
  const _Seed({
    required this.gameId,
    required this.config,
    required this.expected,
  });

  final String gameId;
  final GDevelopProjectConfig config;
  final GDevelopProjectRekeyExpectedEvidence expected;
}

class _RekeyFixture {
  _RekeyFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.config,
    required this.restore,
    required this.deleteDirectory,
    required this.initialCrashHook,
  });

  final Directory root;
  final FileSystemGDevelopProjectRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController config;
  final GDevelopRestoreTransactionCoordinator restore;
  final GDevelopProjectRekeyDirectoryDelete? deleteDirectory;
  final GDevelopProjectRekeyCrashHook? initialCrashHook;
  final List<Map<String, Object?>> events = [];
  final List<String> approvalMigrations = [];
  final List<String> closedAiSessions = [];
  final List<String> stoppedPreviews = [];
  DateTime now = DateTime.utc(2026, 8, 5, 8);
  int sequence = 0;
  late GDevelopProjectRekeyCoordinator rekey;

  static Future<_RekeyFixture> create({
    GDevelopProjectRekeyDirectoryDelete? deleteDirectory,
    GDevelopProjectRekeyCrashHook? crashHook,
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-rekey-');
    late _RekeyFixture fixture;
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
    final restore = GDevelopRestoreTransactionCoordinator(
      history: history,
      projectConfig: config,
      rootResolver: resolver,
      clock: () => fixture.now,
    );
    fixture = _RekeyFixture(
      root: root,
      resolver: resolver,
      history: history,
      config: config,
      restore: restore,
      deleteDirectory: deleteDirectory,
      initialCrashHook: crashHook,
    );
    fixture.rekey = fixture.newCoordinator(crashHook: crashHook);
    restore.registerMutationGuard(fixture.rekey.ensureMutationAllowed);
    return fixture;
  }

  GDevelopProjectRekeyCoordinator newCoordinator({
    GDevelopProjectRekeyCrashHook? crashHook,
    GDevelopProjectRekeyApprovalMigrator? approvalMigrator,
    GDevelopProjectRekeyProjectCloser? aiSessionCloser,
    GDevelopProjectRekeyProjectCloser? previewStopper,
  }) => GDevelopProjectRekeyCoordinator(
    history: history,
    projectConfig: config,
    restoreTransactions: restore,
    rootResolver: resolver,
    deleteDirectory: deleteDirectory,
    clock: () => now,
    idFactory: () => 'rekey-tx-${sequence++}',
    crashHook: crashHook,
    approvalMigrator:
        approvalMigrator ??
        (oldGameId, newGameId) async {
          approvalMigrations.add('$oldGameId->$newGameId');
        },
    closeAiSessions:
        aiSessionCloser ??
        (gameId) {
          closedAiSessions.add(gameId);
        },
    stopPreview:
        previewStopper ??
        (gameId) {
          stoppedPreviews.add(gameId);
        },
    eventSink: (event) => events.add(Map.unmodifiable(event)),
  );

  Future<_Seed> seed(String gameId) async {
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: gameId,
      fileIdentifier: 'file-${gameId.split('.').last}',
    );
    expect(await config.initializeNewProject(gameId), isTrue);
    final projectConfig = (await config.read(gameId)).config!;
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: [
        GDevelopProjectFile(
          path: 'game.json',
          content: {
            'name': gameId,
            'properties': {'packageName': gameId, 'folderProject': true},
          },
        ),
      ],
      resources: const [],
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(
        projectConfig,
      ),
    );
    final projectRoot = await resolver.projectRootLocation(gameId);
    await File(
      '${projectRoot.path}${Platform.pathSeparator}main.json',
    ).writeAsString(
      jsonEncode({'id': gameId, 'name': gameId, 'app': 'index.html'}),
      flush: true,
    );
    final current = (await history.currentReferenceSnapshot(gameId))!;
    return _Seed(
      gameId: gameId,
      config: projectConfig,
      expected: GDevelopProjectRekeyExpectedEvidence(
        history: GDevelopRestoreHistoryEvidence(
          revision: current.version.revision,
          currentContentHash: current.version.contentHash,
          projectFilesHash: current.projectFiles.contentHash,
          resourceManifestHash: await _hashJson(
            current.resources.map((item) => item.toJson()).toList(),
          ),
        ),
        config: await config.inspect(gameId),
      ),
    );
  }

  Future<GDevelopProjectRekeyTransaction> prepare(
    _Seed seed, {
    required String newGameId,
    String idempotencyKey = 'rekey-click-1',
  }) => rekey.prepare(
    oldGameId: seed.gameId,
    newGameId: newGameId,
    idempotencyKey: idempotencyKey,
    expectedOldEvidence: seed.expected,
    browserSource: GDevelopProjectRekeyBrowserTarget(
      fileIdentifier: 'web-file-1',
      projectFilesHash: 'a' * 64,
    ),
    browserTarget: GDevelopProjectRekeyBrowserTarget(
      fileIdentifier: 'web-file-1',
      projectFilesHash: 'b' * 64,
    ),
    clientId: 'web-ide-1',
  );

  GDevelopProjectRekeyBrowserEvidence ackFor({required String newGameId}) =>
      GDevelopProjectRekeyBrowserEvidence(
        fileIdentifier: 'web-file-1',
        gameId: newGameId,
        packageName: newGameId,
        projectFilesHash: 'b' * 64,
      );

  GDevelopProjectRekeyBrowserEvidence rollbackAckFor({
    required String oldGameId,
  }) => GDevelopProjectRekeyBrowserEvidence(
    fileIdentifier: 'web-file-1',
    gameId: oldGameId,
    packageName: oldGameId,
    projectFilesHash: 'a' * 64,
  );

  Future<List<String>> identityBytes(Directory root) async {
    final result = <String>[];
    for (final relative in const [
      '.playmesh/project.json',
      '.playmesh/gdevelop/project-config.json',
      'main.json',
    ]) {
      final file = File(
        '${root.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      result.add(await file.exists() ? await file.readAsString() : '<missing>');
    }
    return result;
  }

  Future<void> close() => root.delete(recursive: true);
}

Future<String> _hashJson(Object? value) async {
  final digest = await Sha256().hash(utf8.encode(jsonEncode(value)));
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String _name(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
