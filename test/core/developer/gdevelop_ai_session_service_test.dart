import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

final _registry = loadGDevelopAiToolRegistryForTest();

void main() {
  test('写工具只终结业务结果，随后同会话可执行只读工具', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);

    final write = _enqueue(
      service,
      session,
      suffix: 'write',
      toolName: 'create_scene',
      arguments: const {'scene_name': 'Game'},
    );
    expect(service.leaseNext(session.id)?.id, write.id);
    final finished = service.finishCall(
      editorSessionId: session.id,
      callId: write.id,
      success: true,
      output: const {'created': true, 'sceneName': 'Game'},
    );

    expect(finished.state, GDevelopAiCallState.finished);
    expect(finished.output, const {'created': true, 'sceneName': 'Game'});
    final wire = finished.toJson();
    expect(wire, isNot(contains('commitEvidence')));
    expect(wire, isNot(contains('baseRevision')));
    expect(wire, isNot(contains('baseProjectContentHash')));

    final read = _enqueue(
      service,
      session,
      suffix: 'read',
      toolName: 'read_scene_events',
      arguments: const {'scene_name': 'Game'},
    );
    expect(service.leaseNext(session.id)?.id, read.id);
    final readFinished = service.finishCall(
      editorSessionId: session.id,
      callId: read.id,
      success: true,
      output: const {'eventsAsText': 'SceneJustBegins'},
    );
    expect(readFinished.state, GDevelopAiCallState.finished);
  });

  test('写工具执行不修改 history current 或 revision', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-ai-result-');
    addTearDown(() => root.delete(recursive: true));
    final history = GDevelopProjectHistoryAdapter(
      rootResolver: FileSystemGDevelopProjectRootResolver(
        projectsRoot: root,
        cleanupJournal: File(
          '${root.path}${Platform.pathSeparator}cleanup.json',
        ),
      ),
    );
    const gameId = 'com.example.ai-result-only';
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: 'AI result only',
    );
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: const [
        GDevelopProjectFile(
          path: 'game.json',
          content: {'name': 'saved-by-user'},
        ),
      ],
      resources: const [],
    );
    final before = await history.currentReferenceSnapshot(gameId);

    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = service.open(
      gameId: gameId,
      mode: GDevelopAiMode.chat,
      locale: 'zh-CN',
      registry: _registry,
    );
    final write = _enqueue(
      service,
      session,
      suffix: 'history-neutral',
      toolName: 'create_scene',
      arguments: const {'scene_name': 'Game'},
    );
    service.leaseNext(session.id);
    service.finishCall(
      editorSessionId: session.id,
      callId: write.id,
      success: true,
      output: const {'created': true},
    );

    final after = await history.currentReferenceSnapshot(gameId);
    expect(after?.toJson(), before?.toJson());
    expect((await history.list(gameId)), hasLength(1));
  });

  test('页面重载终止已运行写工具，且旧调用不能再次 lease', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final write = _enqueue(
      service,
      session,
      suffix: 'stale-write',
      toolName: 'create_scene',
      arguments: const {'scene_name': 'Game'},
    );
    expect(service.leaseNext(session.id)?.id, write.id);

    final reattached = service.reattachOrOpen(
      gameId: session.gameId,
      mode: session.mode,
      locale: session.locale,
      resumeEditorSessionId: session.id,
      registry: _registry,
    );

    expect(reattached.id, session.id);
    final stale = service.call(session.id, write.id);
    expect(stale.state, GDevelopAiCallState.failed);
    expect(stale.errorCode, 'worker_reloaded');
    expect(service.leaseNext(session.id), isNull);
    expect(service.writerLease(session.gameId), isNull);
  });

  test('关闭会话取消未完成写工具，新会话不会得到旧调用', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final first = _open(service);
    final write = _enqueue(
      service,
      first,
      suffix: 'close-write',
      toolName: 'create_scene',
      arguments: const {'scene_name': 'Game'},
    );
    expect(service.leaseNext(first.id)?.id, write.id);
    expect(service.close(first.id), isTrue);
    expect(service.writerLease(first.gameId), isNull);

    final second = _open(service);
    expect(service.leaseNext(second.id), isNull);
  });

  test('审批模式只属于当前会话，重连保留而关闭后重置', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    expect(session.approvalMode, GDevelopAiApprovalMode.requestApproval);
    expect(session.toJson()['approvalMode'], 'request_approval');

    final pending = _enqueue(
      service,
      session,
      suffix: 'approval-pending',
      toolName: 'change_scene_properties_layers_effects_groups',
      arguments: const {'scene_name': 'Game'},
    );
    expect(pending.state, GDevelopAiCallState.awaitingApproval);

    final alwaysAllowed = service.updateSession(
      session.id,
      approvalMode: GDevelopAiApprovalMode.alwaysAllow,
    );
    expect(alwaysAllowed.approvalMode, GDevelopAiApprovalMode.alwaysAllow);
    expect(
      service.call(session.id, pending.id).state,
      GDevelopAiCallState.queued,
    );

    final reattached = service.reattachOrOpen(
      gameId: session.gameId,
      mode: session.mode,
      locale: session.locale,
      resumeEditorSessionId: session.id,
      registry: _registry,
    );
    expect(reattached.id, session.id);
    expect(reattached.approvalMode, GDevelopAiApprovalMode.alwaysAllow);
    final automaticallyQueued = _enqueue(
      service,
      reattached,
      suffix: 'approval-automatic',
      toolName: 'change_scene_properties_layers_effects_groups',
      arguments: const {'scene_name': 'Other'},
    );
    expect(automaticallyQueued.state, GDevelopAiCallState.queued);

    final requestsApproval = service.updateSession(
      session.id,
      approvalMode: GDevelopAiApprovalMode.requestApproval,
    );
    expect(
      requestsApproval.approvalMode,
      GDevelopAiApprovalMode.requestApproval,
    );
    expect(
      service.call(session.id, automaticallyQueued.id).state,
      GDevelopAiCallState.queued,
      reason: '切回请求审批不能回滚已经排队的调用',
    );
    final futurePending = _enqueue(
      service,
      requestsApproval,
      suffix: 'approval-future',
      toolName: 'change_scene_properties_layers_effects_groups',
      arguments: const {'scene_name': 'Future'},
    );
    expect(futurePending.state, GDevelopAiCallState.awaitingApproval);

    service.close(session.id);
    final reopened = _open(service);
    expect(reopened.approvalMode, GDevelopAiApprovalMode.requestApproval);
  });

  test('运行中的写调用不可取消，整轮取消原子拒绝且不改状态', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final turn = service.createTurn(session.id, echo: 1);
    final write = service.enqueueCall(
      editorSessionId: session.id,
      turnId: turn.id,
      callId: 'protected-write',
      idempotencyKey: 'protected-write-key',
      toolName: 'create_scene',
      arguments: const {'scene_name': 'Game'},
    );
    final queuedRead = service.enqueueCall(
      editorSessionId: session.id,
      turnId: turn.id,
      callId: 'queued-read',
      idempotencyKey: 'queued-read-key',
      toolName: 'read_scene_events',
      arguments: const {'scene_name': 'Game'},
    );
    expect(service.leaseNext(session.id)?.id, write.id);
    final sequenceBeforeCancel = service.session(session.id).sequence;

    Matcher nonCancellableConflict() => isA<GDevelopAiCallConflict>().having(
      (error) => error.code,
      'code',
      'write_execution_non_cancellable',
    );
    expect(
      () => service.cancelCall(session.id, write.id),
      throwsA(nonCancellableConflict()),
    );
    expect(
      () => service.cancelTurn(session.id, turn.id),
      throwsA(nonCancellableConflict()),
    );

    expect(service.session(session.id).sequence, sequenceBeforeCancel);
    expect(
      service.call(session.id, write.id).state,
      GDevelopAiCallState.running,
    );
    expect(
      service.call(session.id, queuedRead.id).state,
      GDevelopAiCallState.queued,
      reason: 'turn cancellation must not partially cancel sibling calls',
    );
    expect(service.writerLease(session.gameId)?.callId, write.id);

    service.finishCall(
      editorSessionId: session.id,
      callId: write.id,
      success: true,
      output: const {'created': true},
    );
    final cancelled = service.cancelTurn(session.id, turn.id);
    expect(cancelled.map((call) => call.id), [queuedRead.id]);
  });

  test('写工具越过 30 秒仍等待精确结果，并持续阻塞第二个 writer', () {
    fakeAsync((async) {
      final service = GDevelopAiSessionService();
      final session = _open(service);
      final first = _enqueue(
        service,
        session,
        suffix: 'long-write-first',
        toolName: 'create_scene',
        arguments: const {'scene_name': 'First'},
      );
      final second = _enqueue(
        service,
        session,
        suffix: 'long-write-second',
        toolName: 'create_scene',
        arguments: const {'scene_name': 'Second'},
      );

      expect(service.leaseNext(session.id)?.id, first.id);
      async.elapse(const Duration(seconds: 31));

      expect(
        service.call(session.id, first.id).state,
        GDevelopAiCallState.running,
      );
      expect(service.writerLease(session.gameId)?.callId, first.id);
      expect(service.leaseNext(session.id), isNull);

      final finished = service.finishCall(
        editorSessionId: session.id,
        callId: first.id,
        success: true,
        output: const {'created': true},
      );
      expect(finished.state, GDevelopAiCallState.finished);
      expect(service.leaseNext(session.id)?.id, second.id);
      service.dispose();
    });
  });

  test('只读工具保留 30 秒执行超时', () {
    fakeAsync((async) {
      final service = GDevelopAiSessionService();
      final session = _open(service);
      final read = _enqueue(
        service,
        session,
        suffix: 'timed-read',
        toolName: 'read_scene_events',
        arguments: const {'scene_name': 'Game'},
      );

      expect(service.leaseNext(session.id)?.id, read.id);
      async.elapse(const Duration(seconds: 31));

      final timedOut = service.call(session.id, read.id);
      expect(timedOut.state, GDevelopAiCallState.timedOut);
      expect(timedOut.errorCode, 'tool_timeout');
      service.dispose();
    });
  });

  test('所有客户端 ID 禁止冒号，并在任何状态写入前拒绝', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    expect(
      () => service.open(
        gameId: 'com.example.ai',
        mode: GDevelopAiMode.chat,
        locale: 'zh-CN',
        resumeEditorSessionId: 'session:invalid',
        registry: _registry,
      ),
      throwsFormatException,
    );

    final session = _open(service);
    final initialSequence = service.session(session.id).sequence;
    expect(
      () => service.createTurn(session.id, clientMessageId: 'message:invalid'),
      throwsFormatException,
    );
    expect(
      () => service.createTurn(session.id, clientMessageId: 'message\n'),
      throwsFormatException,
    );
    expect(service.session(session.id).sequence, initialSequence);

    final turn = service.createTurn(session.id, echo: 1);
    final beforeRejectedCalls = service.session(session.id).sequence;
    for (final rejected in <({String turnId, String callId, String key})>[
      (turnId: 'turn:invalid', callId: 'valid-call', key: 'valid-key'),
      (turnId: turn.id, callId: 'call:invalid', key: 'valid-key'),
      (turnId: turn.id, callId: 'valid-call', key: 'key:invalid'),
    ]) {
      expect(
        () => service.enqueueCall(
          editorSessionId: session.id,
          turnId: rejected.turnId,
          callId: rejected.callId,
          idempotencyKey: rejected.key,
          toolName: 'read_scene_events',
          arguments: const {'scene_name': 'Game'},
        ),
        throwsFormatException,
      );
      expect(service.calls(session.id), isEmpty);
      expect(service.session(session.id).sequence, beforeRejectedCalls);
    }
    expect(
      () => service.cancelTurn(session.id, 'turn:invalid'),
      throwsFormatException,
    );
    expect(() => service.session('session:invalid'), throwsFormatException);
  });

  test('幂等键只重放完全相同的业务调用', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final turn = service.createTurn(session.id, echo: 1);
    GDevelopAiCall enqueue(String sceneName) => service.enqueueCall(
      editorSessionId: session.id,
      turnId: turn.id,
      callId: 'stable-call',
      idempotencyKey: 'stable-key',
      toolName: 'create_scene',
      arguments: {'scene_name': sceneName},
    );

    final first = enqueue('Game');
    expect(enqueue('Game').id, first.id);
    expect(
      () => enqueue('Other'),
      throwsA(
        isA<GDevelopAiCallConflict>().having(
          (error) => error.code,
          'code',
          'idempotency_conflict',
        ),
      ),
    );
  });

  test('Chat echo 是 turn 根字段并在会话内保持正安全整数单调递增', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final turn = service.createTurn(
      session.id,
      clientMessageId: 'echo-message',
      echo: 7,
    );
    expect(turn.echo, 7);
    expect(turn.toJson()['echo'], 7);
    expect(
      service
          .createTurn(session.id, clientMessageId: 'echo-message', echo: 7)
          .id,
      turn.id,
      reason: 'same clientMessageId and echo replay the same turn',
    );
    expect(
      () => service.createTurn(
        session.id,
        clientMessageId: 'echo-message',
        echo: 8,
      ),
      throwsA(
        isA<GDevelopAiCallConflict>().having(
          (error) => error.code,
          'code',
          'idempotency_conflict',
        ),
      ),
    );
    for (final invalidEcho in [0, 9007199254740992]) {
      expect(
        () => service.createTurn(
          session.id,
          clientMessageId: 'invalid-echo-$invalidEcho',
          echo: invalidEcho,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => service.createTurn(
        session.id,
        clientMessageId: 'duplicate-echo-message',
        echo: 7,
      ),
      throwsA(
        isA<GDevelopAiCallConflict>().having(
          (error) => error.code,
          'code',
          'echo_conflict',
        ),
      ),
    );
    final nextTurn = service.createTurn(
      session.id,
      clientMessageId: 'next-echo-message',
      echo: 9,
    );
    expect(nextTurn.echo, 9);

    final queued = service.enqueueCall(
      editorSessionId: session.id,
      turnId: turn.id,
      callId: 'echo-call',
      idempotencyKey: 'echo-key',
      toolName: 'read_scene_events',
      arguments: const {'scene_name': 'Game'},
    );
    expect(queued.toJson(), isNot(contains('echo')));

    final running = service.leaseNext(session.id)!;
    expect(running.toJson(), isNot(contains('echo')));
    final finished = service.finishCall(
      editorSessionId: session.id,
      callId: running.id,
      success: false,
      output: const {'reason': 'tool failed'},
      errorCode: 'tool_failed',
      errorMessage: 'tool failed',
    );
    expect(finished.toJson(), isNot(contains('echo')));
  });

  test('Agent transport 可省略 Chat echo', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = service.open(
      gameId: 'com.example.ai-agent',
      mode: GDevelopAiMode.agent,
      locale: 'zh-CN',
      registry: _registry,
    );
    final turn = service.createTurn(
      session.id,
      clientMessageId: 'agent-message',
    );
    expect(turn.toJson(), isNot(contains('echo')));
  });

  test('事件 payload 在 enqueue 时锁定为 input，终态 output 只是业务结果', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final payload = <String, Object?>{
      'schemaVersion': '1.0.0',
      'sceneName': 'Game',
      'changes': <Object?>[],
    };
    final call = _enqueue(
      service,
      session,
      suffix: 'event-payload',
      toolName: 'add_scene_events',
      arguments: const {
        'scene_name': 'Game',
        'events_description': '增加场景开始事件',
        'extension_names_list': '',
      },
      input: {'eventPayload': payload},
    );
    expect(call.input?['eventPayload'], payload);
    expect(call.output, isNull);
    payload['sceneName'] = 'Mutated after enqueue';
    expect(
      (call.input?['eventPayload']! as Map)['sceneName'],
      'Game',
      reason: 'enqueue must detach the immutable input from caller-owned maps',
    );
    service.approvalDecision(
      editorSessionId: session.id,
      callId: call.id,
      approved: true,
    );
    final running = service.leaseNext(session.id)!;
    expect(running.state, GDevelopAiCallState.running);
    expect((running.input?['eventPayload']! as Map)['sceneName'], 'Game');
    expect(running.output, isNull);

    final finished = service.finishCall(
      editorSessionId: session.id,
      callId: call.id,
      success: true,
      output: const {'applied': 1},
    );
    expect(finished.input, isNull);
    expect(finished.output, const {'applied': 1});
  });

  test('事件 payload 参与幂等指纹，非事件工具拒绝该输入', () {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    final turn = service.createTurn(session.id, echo: 1);
    GDevelopAiCall enqueueEvent(String sceneName) => service.enqueueCall(
      editorSessionId: session.id,
      turnId: turn.id,
      callId: 'stable-event-call',
      idempotencyKey: 'stable-event-key',
      toolName: 'add_scene_events',
      arguments: const {
        'scene_name': 'Game',
        'events_description': '增加事件',
        'extension_names_list': '',
      },
      input: {
        'eventPayload': {'sceneName': sceneName},
      },
    );

    expect(enqueueEvent('Game').input, isNotNull);
    expect(
      () => enqueueEvent('Other'),
      throwsA(
        isA<GDevelopAiCallConflict>().having(
          (error) => error.code,
          'code',
          'idempotency_conflict',
        ),
      ),
    );
    expect(
      () => service.enqueueCall(
        editorSessionId: session.id,
        turnId: turn.id,
        callId: 'read-with-payload',
        idempotencyKey: 'read-with-payload',
        toolName: 'read_scene_events',
        arguments: const {'scene_name': 'Game'},
        input: const {
          'eventPayload': {'unexpected': true},
        },
      ),
      throwsFormatException,
    );
  });

  test('Agent resource 只在会话内存暂存并一次性消费', () async {
    final service = GDevelopAiSessionService();
    addTearDown(service.dispose);
    final session = _open(service);
    const hash =
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';
    await service.stageResource(
      editorSessionId: session.id,
      expectedHash: hash,
      bytes: const [1, 2, 3],
    );
    expect(
      service.takeStagedResource(
        editorSessionId: session.id,
        contentHash: hash,
        size: 3,
      ),
      const [1, 2, 3],
    );
    expect(
      () => service.takeStagedResource(
        editorSessionId: session.id,
        contentHash: hash,
        size: 3,
      ),
      throwsA(isA<GDevelopAiCallConflict>()),
    );
  });
}

GDevelopAiEditorSession _open(GDevelopAiSessionService service) => service.open(
  gameId: 'com.example.ai',
  mode: GDevelopAiMode.chat,
  locale: 'zh-CN',
  registry: _registry,
);

GDevelopAiCall _enqueue(
  GDevelopAiSessionService service,
  GDevelopAiEditorSession session, {
  required String suffix,
  required String toolName,
  required Map<String, Object?> arguments,
  Map<String, Object?>? input,
}) {
  final turn = service.createTurn(
    session.id,
    echo: service.session(session.id).sequence + 1,
  );
  return service.enqueueCall(
    editorSessionId: session.id,
    turnId: turn.id,
    callId: 'call-$suffix',
    idempotencyKey: 'idem-$suffix',
    toolName: toolName,
    arguments: arguments,
    input: input,
  );
}
