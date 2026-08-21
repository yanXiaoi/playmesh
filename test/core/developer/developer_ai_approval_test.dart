import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval_store.dart';

void main() {
  test('once 只批准当前请求，reject 不写入审批缓存', () async {
    final broker = await _broker();
    addTearDown(broker.dispose);
    final subject = _subject();

    final approved = broker.request(
      requestId: 'request-once',
      subject: subject,
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.once,
    );
    expect(await approved, DeveloperAiApprovalResult.approved);

    final rejected = broker.request(
      requestId: 'request-reject',
      subject: subject,
    );
    final rejectedApprovalId = await _pendingId(broker);
    expect(broker.pending, hasLength(1), reason: 'once 不能批准后续同类请求');
    await broker.decide(rejectedApprovalId, DeveloperAiApprovalDecision.reject);
    expect(await rejected, DeveloperAiApprovalResult.rejected);

    final retried = broker.request(
      requestId: 'request-after-reject',
      subject: subject,
    );
    final retriedApprovalId = await _pendingId(broker);
    expect(broker.pending, hasLength(1), reason: 'reject 不能形成允许缓存');
    await broker.decide(retriedApprovalId, DeveloperAiApprovalDecision.reject);
    expect(await retried, DeveloperAiApprovalResult.rejected);
  });

  test('project 审批按 scopeKind、scopeId 和 operationId 隔离', () async {
    final broker = await _broker();
    addTearDown(broker.dispose);
    final approvedSubject = _subject();

    final initial = broker.request(
      requestId: 'request-project',
      subject: approvedSubject,
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.project,
    );
    expect(await initial, DeveloperAiApprovalResult.approved);
    expect(
      await broker.request(
        requestId: 'request-project-reuse',
        subject: approvedSubject,
      ),
      DeveloperAiApprovalResult.approved,
    );
    expect(broker.pending, isEmpty);

    for (final isolatedSubject in [
      _subject(scopeId: 'com.example.other'),
      _subject(operationId: 'gdevelop.tool.change_object_properties_effects'),
      _subject(scopeKind: 'source'),
    ]) {
      final isolated = broker.request(
        requestId: 'request-isolated-${isolatedSubject.projectCacheKey}',
        subject: isolatedSubject,
      );
      final isolatedApprovalId = await _pendingId(broker);
      expect(
        broker.pending,
        hasLength(1),
        reason: '${isolatedSubject.projectCacheKey} 不能继承其他项目审批',
      );
      await broker.decide(
        isolatedApprovalId,
        DeveloperAiApprovalDecision.reject,
      );
      expect(await isolated, DeveloperAiApprovalResult.rejected);
    }
  });

  test('危险操作在固定 30 秒后返回 timeout 且清理 pending', () async {
    final broker = await _broker();
    addTearDown(broker.dispose);
    Duration? requestedDuration;
    late void Function() fireTimeout;

    final result = runZoned(
      () => broker.request(requestId: 'request-timeout', subject: _subject()),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == DeveloperAiApprovalBroker.timeout) {
            requestedDuration = duration;
            fireTimeout = callback;
            return parent.createTimer(zone, const Duration(days: 1), callback);
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );

    final approvalId = await _pendingId(broker);
    fireTimeout();
    expect(requestedDuration, DeveloperAiApprovalBroker.timeout);
    expect(await result, DeveloperAiApprovalResult.timeout);
    expect(broker.pending, isEmpty);
    for (final decision in DeveloperAiApprovalDecision.values.where(
      (value) => value != DeveloperAiApprovalDecision.reject,
    )) {
      await expectLater(
        broker.decide(approvalId, decision),
        throwsA(isA<StateError>()),
      );
    }
    expect(await broker.listAlwaysGrants(), isEmpty);
  });

  test('always 按 scopeKind、gameId 和 tool 持久化且可以撤销', () async {
    final root = await Directory.systemTemp.createTemp(
      'developer-ai-approval-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}grants.json');
    final first = DeveloperAiApprovalBroker(
      persistence: FileDeveloperAiApprovalPersistence(file: file),
      idFactory: () => 'approval-persist-first',
    );
    await first.initialize();
    final subject = _subject();
    final initial = first.request(requestId: 'persist-first', subject: subject);
    await first.decide(
      await _pendingId(first),
      DeveloperAiApprovalDecision.always,
    );
    expect(await initial, DeveloperAiApprovalResult.approved);
    final persisted = await first.listAlwaysGrants();
    expect(persisted, hasLength(1));
    expect(persisted.single, containsPair('gameId', 'com.example.game'));
    expect(
      persisted.single,
      containsPair(
        'operationId',
        'gdevelop.tool.change_scene_properties_layers_effects_groups',
      ),
    );
    first.dispose();

    final restarted = DeveloperAiApprovalBroker(
      persistence: FileDeveloperAiApprovalPersistence(file: file),
    );
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(
      await restarted.request(requestId: 'persist-restart', subject: subject),
      DeveloperAiApprovalResult.approved,
    );
    expect(restarted.pending, isEmpty);

    for (final isolated in [
      _subject(scopeId: 'com.example.other'),
      _subject(operationId: 'gdevelop.tool.change_object_properties_effects'),
      _subject(scopeKind: 'source'),
    ]) {
      final result = restarted.request(
        requestId: 'persist-isolated-${isolated.projectCacheKey}',
        subject: isolated,
      );
      await restarted.decide(
        await _pendingId(restarted),
        DeveloperAiApprovalDecision.reject,
      );
      expect(await result, DeveloperAiApprovalResult.rejected);
    }

    final grantId =
        (await restarted.listAlwaysGrants()).single['grantId']! as String;
    expect(await restarted.revokeAlways(grantId), isTrue);
    expect(await restarted.revokeAlways(grantId), isFalse);
    final afterRevoke = restarted.request(
      requestId: 'persist-after-revoke',
      subject: subject,
    );
    await restarted.decide(
      await _pendingId(restarted),
      DeveloperAiApprovalDecision.reject,
    );
    expect(await afterRevoke, DeveloperAiApprovalResult.rejected);
  });

  test('损坏持久授权文件 fail-closed', () async {
    final root = await Directory.systemTemp.createTemp(
      'developer-ai-approval-corrupt-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}grants.json');
    await file.writeAsString('{not-json');
    final broker = DeveloperAiApprovalBroker(
      persistence: FileDeveloperAiApprovalPersistence(file: file),
    );
    addTearDown(broker.dispose);
    await broker.initialize();

    final result = broker.request(
      requestId: 'corrupt-file',
      subject: _subject(),
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.reject,
    );
    expect(await result, DeveloperAiApprovalResult.rejected);
    expect(await broker.listAlwaysGrants(), isEmpty);
  });

  test('项目删除只清理同 scopeKind/scopeId 的持久与本次运行授权', () async {
    final persistence = _MemoryApprovalPersistence();
    final broker = await _broker(persistence: persistence);
    addTearDown(broker.dispose);
    for (final subject in [
      _subject(),
      _subject(scopeKind: 'source'),
      _subject(scopeId: 'com.example.other'),
    ]) {
      final result = broker.request(
        requestId: 'grant-${subject.projectCacheKey}',
        subject: subject,
      );
      await broker.decide(
        await _pendingId(broker),
        DeveloperAiApprovalDecision.always,
      );
      expect(await result, DeveloperAiApprovalResult.approved);
    }

    final projectOnlySubject = _subject(
      operationId: 'gdevelop.tool.change_behavior_property',
    );
    final projectOnly = broker.request(
      requestId: 'project-only-grant',
      subject: projectOnlySubject,
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.project,
    );
    expect(await projectOnly, DeveloperAiApprovalResult.approved);
    expect(
      await broker.request(
        requestId: 'project-only-reuse',
        subject: projectOnlySubject,
      ),
      DeveloperAiApprovalResult.approved,
    );
    final pendingDuringDelete = broker.request(
      requestId: 'pending-during-delete',
      subject: _subject(
        operationId: 'gdevelop.tool.change_object_properties_effects',
      ),
    );
    await _pendingId(broker);

    await broker.clearScopeApprovals(
      scopeKind: 'gdevelop',
      scopeId: 'com.example.game',
    );
    expect(await pendingDuringDelete, DeveloperAiApprovalResult.rejected);
    final remaining = await broker.listAlwaysGrants();
    expect(remaining, hasLength(2));
    expect(
      remaining.map((grant) => '${grant['scopeKind']}::${grant['scopeId']}'),
      containsAll(['source::com.example.game', 'gdevelop::com.example.other']),
    );
    final afterDelete = broker.request(
      requestId: 'project-only-after-delete',
      subject: projectOnlySubject,
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.reject,
    );
    expect(await afterDelete, DeveloperAiApprovalResult.rejected);
  });

  test('rekey 原子迁移同 scope 的 always/project 授权并拒绝旧 pending', () async {
    final persistence = _MemoryApprovalPersistence();
    final broker = await _broker(persistence: persistence);
    addTearDown(broker.dispose);

    final always = broker.request(
      requestId: 'rekey-always',
      subject: _subject(),
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.always,
    );
    expect(await always, DeveloperAiApprovalResult.approved);
    final projectSubject = _subject(
      operationId: 'gdevelop.tool.change_behavior_property',
    );
    final project = broker.request(
      requestId: 'rekey-project',
      subject: projectSubject,
    );
    await broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.project,
    );
    expect(await project, DeveloperAiApprovalResult.approved);
    final pending = broker.request(
      requestId: 'rekey-pending',
      subject: _subject(
        operationId: 'gdevelop.tool.change_object_properties_effects',
      ),
    );
    await _pendingId(broker);

    await broker.migrateScopeApprovals(
      scopeKind: 'gdevelop',
      oldScopeId: 'com.example.game',
      newScopeId: 'com.example.renamed',
    );

    expect(await pending, DeveloperAiApprovalResult.rejected);
    final grants = await broker.listAlwaysGrants();
    expect(grants, hasLength(1));
    expect(grants.single['scopeId'], 'com.example.renamed');
    expect(
      await broker.request(
        requestId: 'rekey-always-new',
        subject: _subject(scopeId: 'com.example.renamed'),
      ),
      DeveloperAiApprovalResult.approved,
    );
    expect(
      await broker.request(
        requestId: 'rekey-project-new',
        subject: _subject(
          scopeId: 'com.example.renamed',
          operationId: 'gdevelop.tool.change_behavior_property',
        ),
      ),
      DeveloperAiApprovalResult.approved,
    );

    for (final oldSubject in [_subject(), projectSubject]) {
      final oldRequest = broker.request(
        requestId: 'rekey-old-${oldSubject.operationId}',
        subject: oldSubject,
      );
      await broker.decide(
        await _pendingId(broker),
        DeveloperAiApprovalDecision.reject,
      );
      expect(await oldRequest, DeveloperAiApprovalResult.rejected);
    }
  });

  for (final decision in DeveloperAiApprovalDecision.values.where(
    (value) => value != DeveloperAiApprovalDecision.reject,
  )) {
    test('绑定调用先取消后，later ${decision.name} 决策不能形成授权', () async {
      final broker = await _broker();
      addTearDown(broker.dispose);
      final cancellation = DeveloperAiCancellationController();
      final subject = _subject(
        operationId: 'gdevelop.tool.cancel-race-${decision.name}',
      );
      final result = broker.request(
        requestId: 'cancel-race-${decision.name}',
        subject: subject,
        cancellation: cancellation.signal,
      );
      final approvalId = await _pendingId(broker);

      expect(cancellation.cancel('call_cancelled'), isTrue);
      expect(await result, DeveloperAiApprovalResult.rejected);
      expect(broker.pending, isEmpty);
      await expectLater(
        broker.decide(approvalId, decision),
        throwsA(isA<StateError>()),
      );
      expect(await broker.listAlwaysGrants(), isEmpty);

      final retry = broker.request(
        requestId: 'cancel-race-retry-${decision.name}',
        subject: subject,
      );
      await broker.decide(
        await _pendingId(broker),
        DeveloperAiApprovalDecision.reject,
      );
      expect(
        await retry,
        DeveloperAiApprovalResult.rejected,
        reason: '取消的 ${decision.name} 决策不得留下 project/always grant',
      );
    });
  }

  test('always 持久写入中取消会串行补偿且磁盘不留下 grant', () async {
    final persistence = _BlockingApprovalPersistence();
    final broker = await _broker(persistence: persistence);
    addTearDown(broker.dispose);
    final cancellation = DeveloperAiCancellationController();
    final request = broker.request(
      requestId: 'always-persist-race',
      subject: _subject(operationId: 'gdevelop.tool.always-persist-race'),
      cancellation: cancellation.signal,
    );
    final decision = broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.always,
    );
    await persistence.nonEmptySaveStarted.future;

    cancellation.cancel('turn_cancelled');
    persistence.allowNonEmptySave.complete();

    expect(await request, DeveloperAiApprovalResult.rejected);
    await decision;
    expect(await broker.listAlwaysGrants(), isEmpty);
    expect(persistence.grants, isEmpty);
  });

  test('autoApprove 在最后一次异步初始化后复查且不创建 pending', () async {
    final persistence = _BlockingLoadApprovalPersistence();
    final broker = DeveloperAiApprovalBroker(
      persistence: persistence,
      idFactory: () => 'approval-auto-race',
    );
    addTearDown(broker.dispose);
    var autoApprove = false;

    final request = broker.request(
      requestId: 'auto-race',
      subject: _subject(editorSessionId: 'editor-auto'),
      autoApprove: () => autoApprove,
    );
    await persistence.loadStarted.future;
    autoApprove = true;
    persistence.allowLoad.complete();

    expect(await request, DeveloperAiApprovalResult.approved);
    expect(broker.pending, isEmpty);
  });

  test('会话自动允许只完成相同 editorSessionId 的 GDevelop pending', () async {
    final broker = await _broker();
    addTearDown(broker.dispose);
    final first = broker.request(
      requestId: 'editor-first',
      subject: _subject(callId: 'call-first', editorSessionId: 'editor-first'),
    );
    final second = broker.request(
      requestId: 'editor-second',
      subject: _subject(
        callId: 'call-second',
        editorSessionId: 'editor-second',
      ),
    );
    while (broker.pending.length != 2) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(broker.approvePendingForEditorSession('editor-first'), 1);
    expect(await first, DeveloperAiApprovalResult.approved);
    expect(broker.pending, hasLength(1));
    expect(broker.pending.single['editorSessionId'], 'editor-second');
    await broker.decide(
      broker.pending.single['approvalId']! as String,
      DeveloperAiApprovalDecision.reject,
    );
    expect(await second, DeveloperAiApprovalResult.rejected);
  });

  test('会话自动允许与进行中的 always grant 决策并发时不会重复完成', () async {
    final persistence = _BlockingApprovalPersistence();
    final broker = await _broker(persistence: persistence);
    addTearDown(broker.dispose);
    final request = broker.request(
      requestId: 'editor-always-race',
      subject: _subject(
        callId: 'call-always-race',
        editorSessionId: 'editor-always-race',
      ),
    );
    final decision = broker.decide(
      await _pendingId(broker),
      DeveloperAiApprovalDecision.always,
    );
    await persistence.nonEmptySaveStarted.future;

    expect(broker.approvePendingForEditorSession('editor-always-race'), 1);
    expect(await request, DeveloperAiApprovalResult.approved);
    persistence.allowNonEmptySave.complete();
    await decision;
    expect(await broker.listAlwaysGrants(), hasLength(1));
  });

  test('单个取消监听器异常不会阻断其他消费者和取消 future', () async {
    final cancellation = DeveloperAiCancellationController();
    var secondListenerCalled = false;
    cancellation.signal.addListener((_) => throw StateError('listener'));
    cancellation.signal.addListener((_) => secondListenerCalled = true);

    expect(cancellation.cancel('session_closed'), isTrue);
    expect(secondListenerCalled, isTrue);
    expect((await cancellation.signal.whenCancelled).reason, 'session_closed');
  });
}

Future<DeveloperAiApprovalBroker> _broker({
  DeveloperAiApprovalPersistence? persistence,
}) async {
  var sequence = 0;
  final broker = DeveloperAiApprovalBroker(
    idFactory: () => 'approval-${++sequence}',
    persistence: persistence ?? _MemoryApprovalPersistence(),
  );
  await broker.initialize();
  return broker;
}

Future<String> _pendingId(DeveloperAiApprovalBroker broker) async {
  while (broker.pending.isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  return broker.pending.single['approvalId']! as String;
}

class _MemoryApprovalPersistence implements DeveloperAiApprovalPersistence {
  Set<DeveloperAiApprovalGrant> grants = {};

  @override
  Future<Set<DeveloperAiApprovalGrant>> load() async => Set.of(grants);

  @override
  Future<void> save(Iterable<DeveloperAiApprovalGrant> next) async {
    grants = Set.of(next);
  }
}

class _BlockingApprovalPersistence implements DeveloperAiApprovalPersistence {
  Set<DeveloperAiApprovalGrant> grants = {};
  final Completer<void> nonEmptySaveStarted = Completer<void>();
  final Completer<void> allowNonEmptySave = Completer<void>();
  bool _blocked = false;

  @override
  Future<Set<DeveloperAiApprovalGrant>> load() async => Set.of(grants);

  @override
  Future<void> save(Iterable<DeveloperAiApprovalGrant> next) async {
    final snapshot = Set<DeveloperAiApprovalGrant>.of(next);
    if (snapshot.isNotEmpty && !_blocked) {
      _blocked = true;
      nonEmptySaveStarted.complete();
      await allowNonEmptySave.future;
    }
    grants = snapshot;
  }
}

class _BlockingLoadApprovalPersistence
    implements DeveloperAiApprovalPersistence {
  final Completer<void> loadStarted = Completer<void>();
  final Completer<void> allowLoad = Completer<void>();

  @override
  Future<Set<DeveloperAiApprovalGrant>> load() async {
    loadStarted.complete();
    await allowLoad.future;
    return {};
  }

  @override
  Future<void> save(Iterable<DeveloperAiApprovalGrant> next) async {}
}

DeveloperAiApprovalSubject _subject({
  String scopeKind = 'gdevelop',
  String scopeId = 'com.example.game',
  String operationId =
      'gdevelop.tool.change_scene_properties_layers_effects_groups',
  String? callId,
  String? editorSessionId,
}) => DeveloperAiApprovalSubject(
  scopeKind: scopeKind,
  scopeId: scopeId,
  operationId: operationId,
  summary: '删除场景',
  description:
      'GDevelop EditorFunctions: change_scene_properties_layers_effects_groups',
  risk: 'high',
  dangerous: true,
  channel: 'gdevelop-agent',
  callId: callId,
  editorSessionId: editorSessionId,
);
