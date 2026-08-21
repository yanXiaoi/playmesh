import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_ai_prompt_templates.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval_store.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';
import 'package:playmesh/core/developer/gdevelop_editor_instance_lease.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';
import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'v2 global tools remain live while session tools pin their snapshot',
    () async {
      var providerCalls = 0;
      final fixture = await _AiGatewayFixture.create(
        toolsProvider: () async {
          providerCalls += 1;
          return loadGDevelopAiToolRegistryForTest();
        },
      );
      addTearDown(fixture.close);

      final global = await fixture.get('/dev/api/gdevelop/ai/tools');
      expect(global.statusCode, HttpStatus.ok, reason: global.body);
      expect(providerCalls, 1);

      final opened = await fixture.openSession(mode: 'chat');
      expect(opened['protocolVersion'], '4.0.0');
      final session = opened['session']! as Map;
      expect(session['approvalMode'], 'request_approval');
      expect(providerCalls, 2);

      final sessionTools = await fixture.get(
        '${fixture.aiBase}/editor-sessions/${session['editorSessionId']}/tools',
      );
      expect(sessionTools.statusCode, HttpStatus.ok, reason: sessionTools.body);
      expect(providerCalls, 2, reason: 'session tools use the pinned registry');
      final sessionToolsJson = _json(sessionTools);
      expect(sessionToolsJson['contractHash'], session['toolContractHash']);
      expect(sessionToolsJson['toolCount'], fixture.toolContract['toolCount']);

      final refreshed = await fixture.get('/dev/api/gdevelop/ai/tools');
      expect(refreshed.statusCode, HttpStatus.ok, reason: refreshed.body);
      expect(
        providerCalls,
        3,
        reason: 'global tools load the installed contract',
      );
    },
  );

  test('审批模式接口按会话自动放行并保留 Agent 编辑器租约边界', () async {
    final fixture = await _AiGatewayFixture.create();
    addTearDown(fixture.close);
    final opened = await fixture.openSession(mode: 'chat');
    final session = opened['session']! as Map;
    final sessionId = session['editorSessionId']! as String;
    final settingsPath =
        '${fixture.aiBase}/editor-settings/$sessionId/approval-mode';
    final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';

    final firstTurn = await fixture.createTurn(
      sessionId,
      'approval-mode-first',
      echo: 1,
    );
    final awaiting = await fixture.json('POST', callBase, {
      'turnId': firstTurn,
      'callId': 'approval-mode-awaiting',
      'idempotencyKey': 'approval-mode-awaiting',
      'toolName': 'change_scene_properties_layers_effects_groups',
      'arguments': {'scene_name': 'Current Scene'},
    });
    expect(awaiting.statusCode, HttpStatus.accepted, reason: awaiting.body);
    expect((_json(awaiting)['call']! as Map)['state'], 'awaiting_approval');
    for (var attempt = 0; attempt < 20; attempt += 1) {
      final pending = await fixture.get('/dev/api/ai-approvals');
      if ((_json(pending)['approvals']! as List).isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final alwaysAllowed = await fixture.json('PUT', settingsPath, {
      'approvalMode': 'always_allow',
    });
    expect(alwaysAllowed.statusCode, HttpStatus.ok, reason: alwaysAllowed.body);
    final authoritative = _json(alwaysAllowed)['session']! as Map;
    expect(authoritative['approvalMode'], 'always_allow');
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-awaiting').state,
      GDevelopAiCallState.queued,
    );
    final readSettings = await fixture.get(settingsPath);
    expect(readSettings.statusCode, HttpStatus.ok, reason: readSettings.body);
    expect(
      (_json(readSettings)['session']! as Map)['approvalMode'],
      'always_allow',
    );
    final pendingAfterEnable = await fixture.get('/dev/api/ai-approvals');
    expect(
      _json(pendingAfterEnable)['approvals'],
      isEmpty,
      reason: '已登记的同会话审批必须与调用状态一同完成',
    );

    final automaticTurn = await fixture.createTurn(
      sessionId,
      'approval-mode-automatic',
      echo: 2,
    );
    final automatic = await fixture.json('POST', callBase, {
      'turnId': automaticTurn,
      'callId': 'approval-mode-automatic',
      'idempotencyKey': 'approval-mode-automatic',
      'toolName': 'change_scene_properties_layers_effects_groups',
      'arguments': {'scene_name': 'Other Scene'},
    });
    expect((_json(automatic)['call']! as Map)['state'], 'queued');

    final requestApproval = await fixture.json('PUT', settingsPath, {
      'approvalMode': 'request_approval',
    });
    expect(requestApproval.statusCode, HttpStatus.ok);
    expect(
      (_json(requestApproval)['session']! as Map)['approvalMode'],
      'request_approval',
    );
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-automatic').state,
      GDevelopAiCallState.queued,
      reason: '切回请求审批不能回滚已排队调用',
    );

    final invalid = await fixture.json('PUT', settingsPath, {
      'approvalMode': 'always_allow',
      'unexpected': true,
    });
    expect(invalid.statusCode, HttpStatus.badRequest);

    final unboundAgent = await http.get(
      fixture.uri(settingsPath),
      headers: {
        'Authorization': 'Bearer ${fixture.token}',
        'X-Playmesh-AI-Channel': 'agent',
      },
    );
    expect(unboundAgent.statusCode, HttpStatus.conflict);
    expect(
      (_json(unboundAgent)['error']! as Map)['code'],
      'gdevelop_editor_lease_required',
    );

    final futureTurn = await fixture.createTurn(
      sessionId,
      'approval-mode-future',
      echo: 3,
    );
    final future = await fixture.json('POST', callBase, {
      'turnId': futureTurn,
      'callId': 'approval-mode-future',
      'idempotencyKey': 'approval-mode-future',
      'toolName': 'change_scene_properties_layers_effects_groups',
      'arguments': {'scene_name': 'Future Scene'},
    });
    expect((_json(future)['call']! as Map)['state'], 'awaiting_approval');
    await fixture.approveSinglePending(decision: 'project');
    for (var attempt = 0; attempt < 20; attempt += 1) {
      if (fixture.sessions.call(sessionId, 'approval-mode-future').state ==
          GDevelopAiCallState.queued) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-future').state,
      GDevelopAiCallState.queued,
    );

    await fixture.json('PUT', settingsPath, {'approvalMode': 'always_allow'});
    await fixture.json('PUT', settingsPath, {
      'approvalMode': 'request_approval',
    });
    final grantedTurn = await fixture.createTurn(
      sessionId,
      'approval-mode-existing-grant',
      echo: 4,
    );
    final granted = await fixture.json('POST', callBase, {
      'turnId': grantedTurn,
      'callId': 'approval-mode-existing-grant',
      'idempotencyKey': 'approval-mode-existing-grant',
      'toolName': 'change_scene_properties_layers_effects_groups',
      'arguments': {'scene_name': 'Granted Scene'},
    });
    expect(granted.statusCode, HttpStatus.accepted, reason: granted.body);
    for (var attempt = 0; attempt < 20; attempt += 1) {
      if (fixture.sessions
              .call(sessionId, 'approval-mode-existing-grant')
              .state ==
          GDevelopAiCallState.queued) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-existing-grant').state,
      GDevelopAiCallState.queued,
      reason: '切换会话审批模式不能清除或忽略已有逐工具 grant',
    );
  });

  test('审批模式往返不会让持久屏障后的审批请求迟到登记', () async {
    final persistence = _BlockingApprovalBarrierPersistence();
    final approvalBroker = DeveloperAiApprovalBroker(persistence: persistence);
    final fixture = await _AiGatewayFixture.create(
      approvalBroker: approvalBroker,
    );
    addTearDown(fixture.close);
    final session =
        (await fixture.openSession(mode: 'chat'))['session']! as Map;
    final sessionId = session['editorSessionId']! as String;
    final settingsPath =
        '${fixture.aiBase}/editor-settings/$sessionId/approval-mode';

    final barrierRequest = approvalBroker.request(
      requestId: 'approval-barrier',
      subject: const DeveloperAiApprovalSubject(
        scopeKind: 'source',
        scopeId: 'approval-barrier-source',
        operationId: 'approval.barrier.operation',
        summary: 'Approval barrier',
        description: 'Approval barrier',
        risk: 'high',
        dangerous: true,
        channel: 'source-agent',
      ),
    );
    while (approvalBroker.pending.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final barrierDecision = approvalBroker.decide(
      approvalBroker.pending.single['approvalId']! as String,
      DeveloperAiApprovalDecision.always,
    );
    await persistence.nonEmptySaveStarted.future;

    final turnId = await fixture.createTurn(
      sessionId,
      'approval-mode-barrier-turn',
      echo: 1,
    );
    final enqueued = await fixture.json(
      'POST',
      '${fixture.aiBase}/editor-sessions/$sessionId/calls',
      {
        'turnId': turnId,
        'callId': 'approval-mode-barrier-call',
        'idempotencyKey': 'approval-mode-barrier-call',
        'toolName': 'change_scene_properties_layers_effects_groups',
        'arguments': {'scene_name': 'Barrier Scene'},
      },
    );
    expect((_json(enqueued)['call']! as Map)['state'], 'awaiting_approval');
    expect(
      approvalBroker.pending,
      hasLength(1),
      reason: 'GDevelop 审批请求此时仍阻塞在持久化 barrier 之前',
    );

    final always = await fixture.json('PUT', settingsPath, {
      'approvalMode': 'always_allow',
    });
    expect(always.statusCode, HttpStatus.ok, reason: always.body);
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-barrier-call').state,
      GDevelopAiCallState.queued,
    );
    final requestApproval = await fixture.json('PUT', settingsPath, {
      'approvalMode': 'request_approval',
    });
    expect(requestApproval.statusCode, HttpStatus.ok);

    persistence.allowNonEmptySave.complete();
    await barrierDecision;
    expect(await barrierRequest, DeveloperAiApprovalResult.approved);
    await Future<void>.delayed(Duration.zero);
    expect(
      fixture.sessions.call(sessionId, 'approval-mode-barrier-call').state,
      GDevelopAiCallState.queued,
    );
    expect(
      approvalBroker.pending,
      isEmpty,
      reason: '已不再 awaiting_approval 的调用不能迟到创建 pending',
    );
  });

  test(
    'installed tool contract failures keep bounded Gateway diagnostics',
    () async {
      for (final failure in <({String code, int status})>[
        (code: 'gdevelop_ai_tools_missing', status: HttpStatus.conflict),
        (
          code: 'gdevelop_ai_tools_identity_mismatch',
          status: HttpStatus.conflict,
        ),
        (
          code: 'gdevelop_install_io_unavailable',
          status: HttpStatus.serviceUnavailable,
        ),
      ]) {
        final fixture = await _AiGatewayFixture.create(
          toolsProvider: () async =>
              throw GDevelopWebIdeInstallException(failure.code),
        );
        try {
          final response = await fixture.get('/dev/api/gdevelop/ai/tools');
          expect(response.statusCode, failure.status, reason: response.body);
          final error = _json(response)['error']! as Map;
          expect(error['code'], failure.code);
          expect(response.body, isNot(contains(fixture.root.path)));
          expect(response.body, isNot(contains(fixture.token)));
        } finally {
          await fixture.close();
        }
      }
    },
  );

  test(
    'AI Gateway failure logs contain request identity but no credential',
    () async {
      final fixture = await _AiGatewayFixture.create();
      addTearDown(fixture.close);
      final messages = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);

      final response = await fixture.get(
        '${fixture.aiBase}/editor-sessions/missing-session/prompt.txt',
      );
      expect(response.statusCode, HttpStatus.notFound);
      final envelope = _json(response);
      final requestId = envelope['requestId']! as String;
      final error = envelope['error']! as Map;
      expect(error['operation'], 'gdevelop.ai.session.prompt');
      expect(error['code'], 'gdevelop_ai_session_not_found');
      expect(error['requestId'], requestId);
      expect(
        messages,
        contains(
          '[DeveloperGateway][AI] requestId=$requestId '
          'operation=gdevelop.ai.session.prompt status=404 '
          'code=gdevelop_ai_session_not_found',
        ),
      );
      expect(messages.join('\n'), isNot(contains(fixture.token)));
      expect(messages.join('\n'), isNot(contains('Bearer')));
    },
  );

  test('project context is required only for prompt generation', () async {
    final fixture = await _AiGatewayFixture.create();
    addTearDown(fixture.close);
    final opened = await fixture.openSession(mode: 'chat');
    final session = opened['session']! as Map;
    final sessionId = session['editorSessionId']! as String;

    final missingContext = await fixture.get(
      '${fixture.aiBase}/editor-sessions/$sessionId/prompt.txt',
    );
    expect(missingContext.statusCode, HttpStatus.conflict);
    expect(
      (_json(missingContext)['error']! as Map)['code'],
      'project_context_missing',
    );

    final patched = await fixture.json(
      'PATCH',
      '${fixture.aiBase}/editor-sessions/$sessionId',
      {'context': await fixture.projectContext()},
    );
    expect(patched.statusCode, HttpStatus.ok, reason: patched.body);
    final prompt = await fixture.get(
      '${fixture.aiBase}/editor-sessions/$sessionId/prompt.txt',
    );
    expect(prompt.statusCode, HttpStatus.ok, reason: prompt.body);
    expect(prompt.body, contains('PLAYMESH GDEVELOP'));
    expect(prompt.body, contains('"list_scenes"'));
    expect(prompt.body, contains('"selectedSceneName": "Current Scene"'));
    expect(prompt.body, contains('{"echo":1,"calls":['));
    expect(prompt.body, isNot(contains('{"calls":[{"echo":')));
    expect(prompt.body, contains('正安全整数'));
    expect(prompt.body, contains('echo 缺失、不匹配或重复'));
    expect(prompt.body, isNot(contains(fixture.token)));

    final selectedAgentBaseUrl = 'http://127.0.0.1:${fixture.port}';
    final agentPrompt = await fixture.get(
      '${fixture.aiBase}/editor-sessions/$sessionId/prompt.txt'
      '?mode=agent&baseUrl=${Uri.encodeQueryComponent(selectedAgentBaseUrl)}',
    );
    expect(agentPrompt.statusCode, HttpStatus.ok, reason: agentPrompt.body);
    expect(
      agentPrompt.body,
      contains('Authorization: Bearer ${fixture.token}'),
    );
    expect(agentPrompt.body, contains('"turnId": "<turn.turnId>"'));
    expect(agentPrompt.body, contains('"arguments":'));
    expect(agentPrompt.body, isNot(contains('{"echo":1,"calls":[')));
    expect(agentPrompt.body, contains('仅事件载荷工具还必须同时提交 input'));
    expect(agentPrompt.body, contains('精确工具详情中明确声明的工具专用接口'));
    expect(
      agentPrompt.body,
      contains('PUT .../resource-staging/{contentHash}'),
    );
    expect(agentPrompt.body, isNot(contains('仅可调用本合同明确列出的接口')));
    expect(agentPrompt.body, isNot(contains('/event-payload')));
  });

  test(
    'event payload is bound inline and execution returns only business output',
    () async {
      final fixture = await _AiGatewayFixture.create();
      addTearDown(fixture.close);
      final session =
          (await fixture.openSession(mode: 'chat'))['session']! as Map;
      final sessionId = session['editorSessionId']! as String;
      final turnId = await fixture.createTurn(
        sessionId,
        'inline-event-turn',
        echo: 61,
      );
      final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';
      final payload = _eventPayload();

      final legacyCallEcho = await fixture.json('POST', callBase, {
        'turnId': turnId,
        'callId': 'legacy-call-echo',
        'idempotencyKey': 'legacy-call-echo',
        'echo': 62,
        'toolName': 'read_scene_events',
        'arguments': {'scene_name': 'Current Scene'},
      });
      expect(legacyCallEcho.statusCode, HttpStatus.badRequest);

      final missingInput = await fixture.json('POST', callBase, {
        'turnId': turnId,
        'callId': 'missing-event-input',
        'idempotencyKey': 'missing-event-input',
        'toolName': 'add_scene_events',
        'arguments': {
          'scene_name': 'Current Scene',
          'events_description': 'Add one empty event',
          'extension_names_list': '',
        },
      });
      expect(missingInput.statusCode, HttpStatus.badRequest);

      final unexpectedInput = await fixture.json('POST', callBase, {
        'turnId': turnId,
        'callId': 'unexpected-read-input',
        'idempotencyKey': 'unexpected-read-input',
        'toolName': 'read_scene_events',
        'arguments': {'scene_name': 'Current Scene'},
        'input': {'eventPayload': payload},
      });
      expect(unexpectedInput.statusCode, HttpStatus.badRequest);

      final enqueued = await fixture.json('POST', callBase, {
        'turnId': turnId,
        'callId': 'inline-event-call',
        'idempotencyKey': 'inline-event-key',
        'toolName': 'add_scene_events',
        'arguments': {
          'scene_name': 'Current Scene',
          'events_description': 'Add one empty event',
          'extension_names_list': '',
        },
        'input': {'eventPayload': payload},
      });
      expect(enqueued.statusCode, HttpStatus.accepted, reason: enqueued.body);
      final pendingCall = _json(enqueued)['call']! as Map;
      expect(pendingCall, isNot(contains('echo')));
      expect(pendingCall['state'], 'awaiting_approval');
      expect((pendingCall['input']! as Map)['eventPayload'], payload);
      expect(pendingCall, isNot(contains('output')));
      final duplicateEcho = await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$sessionId/turns',
        {'clientMessageId': 'duplicate-echo-message', 'echo': 61},
      );
      expect(duplicateEcho.statusCode, HttpStatus.conflict);
      await fixture.approveSinglePending();

      final leased = await fixture.json('POST', '$callBase/next');
      final runningCall = _json(leased)['call']! as Map;
      expect(runningCall, isNot(contains('echo')));
      expect(runningCall['state'], 'running');
      expect((runningCall['input']! as Map)['eventPayload'], payload);
      expect(runningCall, isNot(contains('output')));

      final executed = await fixture.json(
        'POST',
        '$callBase/inline-event-call/execution',
        {
          'success': true,
          'output': {'applied': 1, 'errors': <Object?>[]},
        },
      );
      final terminal = _json(executed)['call']! as Map;
      expect(terminal, isNot(contains('echo')));
      expect(terminal['state'], 'finished');
      expect(terminal, isNot(contains('input')));
      expect(terminal['output'], {'applied': 1, 'errors': <Object?>[]});

      final removedPayloadEndpoint = await fixture.json(
        'POST',
        '$callBase/inline-event-call/event-payload',
        {'payload': payload},
      );
      expect(removedPayloadEndpoint.statusCode, HttpStatus.notFound);
      final removedCorrectionEndpoint = await fixture.json(
        'POST',
        '$callBase/inline-event-call/correction',
        {'message': 'retry'},
      );
      expect(removedCorrectionEndpoint.statusCode, HttpStatus.notFound);
    },
  );

  test(
    'Agent resource staging is address-agnostic session-memory consumed once',
    () async {
      final fixture = await _AiGatewayFixture.create();
      addTearDown(fixture.close);
      final session =
          (await fixture.openSession(mode: 'agent'))['session']! as Map;
      final sessionId = session['editorSessionId']! as String;
      final bytes = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
      final hash = await _hash(bytes);
      final stagingPath =
          '${fixture.aiBase}/editor-sessions/$sessionId/resource-staging/$hash';

      final turnId = await fixture.createTurn(sessionId, 'resource-turn');
      final enqueued = await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$sessionId/calls',
        {
          'turnId': turnId,
          'callId': 'resource-call',
          'idempotencyKey': 'resource-key',
          'toolName': 'import_project_resource',
          'arguments': {
            'resource_name': 'player.png',
            'resource_kind': 'image',
            'content_hash': hash,
            'mime': 'image/png',
            'size': bytes.length,
          },
        },
        'agent',
      );
      expect(enqueued.statusCode, HttpStatus.accepted, reason: enqueued.body);

      // Enqueue only records the business call. The upload remains a separate
      // session-scoped transport and is checked when WebIDE consumes it.
      final nonLoopbackAddresses = (await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      )).expand((interface) => interface.addresses).toList();
      final stagingUri = nonLoopbackAddresses.isEmpty
          ? fixture.uri(stagingPath)
          : fixture
                .uri(stagingPath)
                .replace(host: nonLoopbackAddresses.first.address);
      final agentUploadHeaders = {
        HttpHeaders.authorizationHeader: 'Bearer ${fixture.token}',
        'X-Playmesh-AI-Channel': 'agent',
        HttpHeaders.contentTypeHeader: 'image/png',
      };

      final wrongChannel = await http.put(
        stagingUri,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${fixture.token}',
          'X-Playmesh-AI-Channel': 'chat',
          HttpHeaders.contentTypeHeader: 'image/png',
        },
        body: bytes,
      );
      expect(wrongChannel.statusCode, HttpStatus.conflict);
      expect(
        (_json(wrongChannel)['error']! as Map)['code'],
        'gdevelop_editor_lease_required',
      );

      final mismatchedGame = await http.put(
        stagingUri.replace(
          path:
              '/dev/api/gdevelop/projects/com.example.other-game/ai/'
              'editor-sessions/$sessionId/resource-staging/$hash',
        ),
        headers: agentUploadHeaders,
        body: bytes,
      );
      expect(mismatchedGame.statusCode, HttpStatus.notFound);
      expect(
        (_json(mismatchedGame)['error']! as Map)['code'],
        'gdevelop_ai_session_not_found',
      );

      final unboundSession = fixture.sessions.open(
        gameId: fixture.gameId,
        mode: GDevelopAiMode.agent,
        locale: 'zh-CN',
        registry: loadGDevelopAiToolRegistryForTest(),
      );
      final unboundSessionId = unboundSession.id;
      fixture.editorInstances.unbindAiSession(unboundSessionId);
      final unboundSessionUpload = await http.put(
        stagingUri.replace(
          path:
              '/dev/api/gdevelop/projects/${fixture.gameId}/ai/'
              'editor-sessions/$unboundSessionId/resource-staging/$hash',
        ),
        headers: agentUploadHeaders,
        body: bytes,
      );
      expect(unboundSessionUpload.statusCode, HttpStatus.conflict);
      expect(
        (_json(unboundSessionUpload)['error']! as Map)['code'],
        'gdevelop_editor_lease_required',
      );

      // Deliberately omit all WebIDE editor lease headers. A current Agent
      // session binding plus the shared Developer bearer is the authorization
      // boundary for this transport, including over a LAN address.
      final staged = await http.put(
        stagingUri,
        headers: agentUploadHeaders,
        body: bytes,
      );
      expect(staged.statusCode, HttpStatus.ok, reason: staged.body);
      await fixture.approveSinglePending();
      final leased = await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$sessionId/calls/next',
      );
      expect((_json(leased)['call']! as Map)['state'], 'running');

      final consumed = await fixture.get('$stagingPath?size=${bytes.length}');
      expect(consumed.statusCode, HttpStatus.ok, reason: consumed.body);
      expect(consumed.bodyBytes, bytes);
      final consumedAgain = await fixture.get(
        '$stagingPath?size=${bytes.length}',
      );
      expect(consumedAgain.statusCode, HttpStatus.conflict);
      expect(
        (_json(consumedAgain)['error']! as Map)['code'],
        'gdevelop_ai_resource_missing',
      );
    },
  );

  test(
    'write execution leaves saved history unchanged and next read can run',
    () async {
      final fixture = await _AiGatewayFixture.create();
      addTearDown(fixture.close);
      final before = await fixture.history.currentReferenceSnapshot(
        fixture.gameId,
      );
      final session =
          (await fixture.openSession(mode: 'chat'))['session']! as Map;
      final sessionId = session['editorSessionId']! as String;
      final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';

      final writeTurn = await fixture.createTurn(
        sessionId,
        'write-turn',
        echo: 1,
      );
      await fixture.json('POST', callBase, {
        'turnId': writeTurn,
        'callId': 'write-call',
        'idempotencyKey': 'write-key',
        'toolName': 'create_scene',
        'arguments': {'scene_name': 'Game'},
      });
      final leasedWrite = await fixture.json('POST', '$callBase/next');
      expect((_json(leasedWrite)['call']! as Map)['state'], 'running');
      final writeResult = await fixture.json(
        'POST',
        '$callBase/write-call/execution',
        {
          'success': true,
          'output': {'created': true, 'sceneName': 'Game'},
        },
      );
      expect((_json(writeResult)['call']! as Map)['output'], {
        'created': true,
        'sceneName': 'Game',
      });
      final after = await fixture.history.currentReferenceSnapshot(
        fixture.gameId,
      );
      expect(after?.toJson(), before?.toJson());
      expect(await fixture.history.list(fixture.gameId), hasLength(1));

      final readTurn = await fixture.createTurn(
        sessionId,
        'read-turn',
        echo: 2,
      );
      final readEnqueued = await fixture.json('POST', callBase, {
        'turnId': readTurn,
        'callId': 'read-call',
        'idempotencyKey': 'read-key',
        'toolName': 'read_scene_events',
        'arguments': {'scene_name': 'Game'},
      });
      expect(
        readEnqueued.statusCode,
        HttpStatus.accepted,
        reason: readEnqueued.body,
      );
      final leasedRead = await fixture.json('POST', '$callBase/next');
      expect((_json(leasedRead)['call']! as Map)['callId'], 'read-call');
      final readResult = await fixture.json(
        'POST',
        '$callBase/read-call/execution',
        {
          'success': true,
          'output': {'eventsAsText': 'SceneJustBegins'},
        },
      );
      expect((_json(readResult)['call']! as Map)['state'], 'finished');
    },
  );

  test('reload or close never leases an old running writer again', () async {
    final fixture = await _AiGatewayFixture.create();
    addTearDown(fixture.close);
    final session =
        (await fixture.openSession(mode: 'chat'))['session']! as Map;
    final sessionId = session['editorSessionId']! as String;
    final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';
    final turnId = await fixture.createTurn(sessionId, 'reload-turn', echo: 1);
    await fixture.json('POST', callBase, {
      'turnId': turnId,
      'callId': 'reload-write',
      'idempotencyKey': 'reload-key',
      'toolName': 'create_scene',
      'arguments': {'scene_name': 'Reloaded'},
    });
    final leased = await fixture.json('POST', '$callBase/next');
    expect((_json(leased)['call']! as Map)['state'], 'running');

    final reopened = await fixture.openSession(
      mode: 'chat',
      resumeEditorSessionId: sessionId,
    );
    expect((reopened['session']! as Map)['editorSessionId'], sessionId);
    final calls = await fixture.get('$callBase?afterSequence=0');
    final failed = (_json(calls)['calls']! as List).single as Map;
    expect(failed['state'], 'failed');
    expect((failed['error']! as Map)['code'], 'worker_reloaded');
    final noReplay = await fixture.json('POST', '$callBase/next');
    expect(_json(noReplay)['call'], isNull);

    final closeTurn = await fixture.createTurn(
      sessionId,
      'close-turn',
      echo: 2,
    );
    await fixture.json('POST', callBase, {
      'turnId': closeTurn,
      'callId': 'close-write',
      'idempotencyKey': 'close-key',
      'toolName': 'create_scene',
      'arguments': {'scene_name': 'Closed'},
    });
    final leasedBeforeClose = await fixture.json('POST', '$callBase/next');
    expect((_json(leasedBeforeClose)['call']! as Map)['state'], 'running');
    final closed = await fixture.json(
      'DELETE',
      '${fixture.aiBase}/editor-sessions/$sessionId',
    );
    expect(_json(closed)['closed'], isTrue);
    final afterClose = await fixture.json('POST', '$callBase/next');
    expect(afterClose.statusCode, HttpStatus.notFound);
  });

  test('Gateway 原子拒绝取消运行中的写调用且不改变调用状态', () async {
    final fixture = await _AiGatewayFixture.create();
    addTearDown(fixture.close);
    final session =
        (await fixture.openSession(mode: 'chat'))['session']! as Map;
    final sessionId = session['editorSessionId']! as String;
    final sessionBase = '${fixture.aiBase}/editor-sessions/$sessionId';
    final callBase = '$sessionBase/calls';
    final turnId = await fixture.createTurn(
      sessionId,
      'cancel-write-turn',
      echo: 1,
    );
    for (final request in <Map<String, Object?>>[
      {
        'turnId': turnId,
        'callId': 'protected-write',
        'idempotencyKey': 'protected-write-key',
        'toolName': 'create_scene',
        'arguments': {'scene_name': 'Game'},
      },
      {
        'turnId': turnId,
        'callId': 'queued-read',
        'idempotencyKey': 'queued-read-key',
        'toolName': 'read_scene_events',
        'arguments': {'scene_name': 'Game'},
      },
    ]) {
      final enqueued = await fixture.json('POST', callBase, request);
      expect(enqueued.statusCode, HttpStatus.accepted, reason: enqueued.body);
    }
    final leased = await fixture.json('POST', '$callBase/next');
    expect((_json(leased)['call']! as Map)['callId'], 'protected-write');
    final before = await fixture.get('$callBase?afterSequence=0');
    final beforeCalls = _callStateSnapshot(before);
    final sessionBefore = await fixture.get(sessionBase);
    final sequenceBefore =
        ((_json(sessionBefore)['session']! as Map)['sequence']! as int);

    final cancelCall = await fixture.json(
      'POST',
      '$callBase/protected-write/cancel',
    );
    expect(cancelCall.statusCode, HttpStatus.conflict);
    expect(
      (_json(cancelCall)['error']! as Map)['code'],
      'write_execution_non_cancellable',
    );
    final cancelTurn = await fixture.json(
      'POST',
      '$sessionBase/turns/$turnId/cancel',
    );
    expect(cancelTurn.statusCode, HttpStatus.conflict);
    expect(
      (_json(cancelTurn)['error']! as Map)['code'],
      'write_execution_non_cancellable',
    );

    final after = await fixture.get('$callBase?afterSequence=0');
    expect(_callStateSnapshot(after), beforeCalls);
    final sessionAfter = await fixture.get(sessionBase);
    expect(
      ((_json(sessionAfter)['session']! as Map)['sequence']),
      sequenceBefore,
    );

    final finished = await fixture.json(
      'POST',
      '$callBase/protected-write/execution',
      {
        'success': true,
        'output': {'created': true},
      },
    );
    expect((_json(finished)['call']! as Map)['state'], 'finished');
  });

  test(
    'one project writer is leased at a time across sibling sessions',
    () async {
      final fixture = await _AiGatewayFixture.create();
      addTearDown(fixture.close);
      final sessions = <Map>[
        (await fixture.openSession(mode: 'chat'))['session']! as Map,
        (await fixture.openSession(mode: 'agent'))['session']! as Map,
      ];
      for (var index = 0; index < sessions.length; index += 1) {
        final sessionId = sessions[index]['editorSessionId']! as String;
        final turnId = await fixture.createTurn(
          sessionId,
          'writer-$index',
          echo: index == 0 ? 1 : null,
        );
        final queued = await fixture.json(
          'POST',
          '${fixture.aiBase}/editor-sessions/$sessionId/calls',
          {
            'turnId': turnId,
            'callId': 'writer-call-$index',
            'idempotencyKey': 'writer-key-$index',
            'toolName': 'create_scene',
            'arguments': {'scene_name': 'Scene$index'},
          },
          index == 0 ? 'chat' : 'agent',
        );
        expect(queued.statusCode, HttpStatus.accepted, reason: queued.body);
      }

      final nextResponses = await Future.wait([
        for (final session in sessions)
          fixture.json(
            'POST',
            '${fixture.aiBase}/editor-sessions/'
                '${session['editorSessionId']}/calls/next',
          ),
      ]);
      final leased = nextResponses
          .map((response) => _json(response)['call'])
          .whereType<Map>()
          .toList();
      expect(leased, hasLength(1));
      final winner = leased.single;
      expect(winner['state'], 'running');
      final winnerSessionId = winner['editorSessionId']! as String;
      final loserSessionId =
          sessions.singleWhere(
                (session) => session['editorSessionId'] != winnerSessionId,
              )['editorSessionId']!
              as String;
      final blocked = await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$loserSessionId/calls/next',
      );
      expect(_json(blocked)['call'], isNull);

      await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$winnerSessionId/calls/'
            '${winner['callId']}/execution',
        {
          'success': true,
          'output': {'done': true},
        },
      );
      final unblocked = await fixture.json(
        'POST',
        '${fixture.aiBase}/editor-sessions/$loserSessionId/calls/next',
      );
      expect((_json(unblocked)['call']! as Map)['state'], 'running');
    },
  );

  test('Gateway 在状态变更前以 400 拒绝含冒号的客户端 ID', () async {
    final fixture = await _AiGatewayFixture.create();
    addTearDown(fixture.close);
    final opened = await fixture.openSession(mode: 'chat');
    final session = opened['session']! as Map;
    final sessionId = session['editorSessionId']! as String;
    final initialSequence = session['sequence'];

    final invalidResume = await fixture.json(
      'POST',
      '${fixture.aiBase}/editor-sessions',
      {
        'mode': 'chat',
        'locale': 'zh-CN',
        'resumeEditorSessionId': 'session:invalid',
      },
    );
    expect(invalidResume.statusCode, HttpStatus.badRequest);
    final unchangedSession = await fixture.get(
      '${fixture.aiBase}/editor-sessions/$sessionId',
    );
    expect(
      ((_json(unchangedSession)['session']! as Map)['sequence']),
      initialSequence,
    );

    final invalidMessage = await fixture.json(
      'POST',
      '${fixture.aiBase}/editor-sessions/$sessionId/turns',
      {'clientMessageId': 'message:invalid'},
    );
    expect(invalidMessage.statusCode, HttpStatus.badRequest);
    final validTurn = await fixture.createTurn(
      sessionId,
      'valid-message',
      echo: 1,
    );
    final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';
    for (final rejected in <({String turnId, String callId, String key})>[
      (turnId: 'turn:invalid', callId: 'valid-call', key: 'valid-key'),
      (turnId: validTurn, callId: 'call:invalid', key: 'valid-key'),
      (turnId: validTurn, callId: 'valid-call', key: 'key:invalid'),
    ]) {
      final response = await fixture.json('POST', callBase, {
        'turnId': rejected.turnId,
        'callId': rejected.callId,
        'idempotencyKey': rejected.key,
        'toolName': 'read_scene_events',
        'arguments': {'scene_name': 'Game'},
      });
      expect(response.statusCode, HttpStatus.badRequest, reason: response.body);
    }
    final calls = await fixture.get('$callBase?afterSequence=0');
    expect((_json(calls)['calls']! as List), isEmpty);

    final invalidTurnPath = await fixture.json(
      'POST',
      '${fixture.aiBase}/editor-sessions/$sessionId/turns/turn:invalid/cancel',
    );
    expect(invalidTurnPath.statusCode, HttpStatus.badRequest);
    final invalidSessionPath = await fixture.get(
      '${fixture.aiBase}/editor-sessions/session:invalid',
    );
    expect(invalidSessionPath.statusCode, HttpStatus.badRequest);
  });
}

Map<String, Object?> _eventPayload() => {
  'schemaVersion': '1.0.0',
  'sceneName': 'Current Scene',
  'changes': <Object?>[
    {
      'operationName': 'insert_at_end',
      'operationTargetEvent': null,
      'isEventsJsonValid': true,
      'generatedEvents': jsonEncode([
        {
          'type': 'BuiltinCommonInstructions::Standard',
          'conditions': <Object?>[],
          'actions': <Object?>[],
        },
      ]),
      'areEventsValid': true,
      'extensionNames': <String>[],
      'diagnosticLines': <String>[],
      'undeclaredVariables': <Object?>[],
      'undeclaredObjectVariables': <String, Object?>{},
      'missingObjectBehaviors': <String, Object?>{},
      'missingResources': <Object?>[],
    },
  ],
};

Map<String, Object?> _json(http.Response response) =>
    Map<String, Object?>.from(jsonDecode(response.body) as Map);

Map<String, ({String state, int sequence})> _callStateSnapshot(
  http.Response response,
) => {
  for (final call in (_json(response)['calls']! as List).cast<Map>())
    call['callId']! as String: (
      state: call['state']! as String,
      sequence: call['sequence']! as int,
    ),
};

class _AiGatewayFixture {
  _AiGatewayFixture({
    required this.gateway,
    required this.history,
    required this.sessions,
    required this.root,
    required this.port,
    required this.editorLease,
    required this.editorInstances,
    required this.toolContract,
  });

  static const _token =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  static const _gameId = 'com.example.gdevelop-ai-v2';

  final DeveloperWebGateway gateway;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopAiSessionService sessions;
  final Directory root;
  final int port;
  final GDevelopEditorLeaseTestClient editorLease;
  final GDevelopEditorInstanceLeaseManager editorInstances;
  final Map<String, Object?> toolContract;

  String get token => _token;
  String get gameId => _gameId;
  String get aiBase => '/dev/api/gdevelop/projects/$gameId/ai';
  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');
  Map<String, String> get auth => editorLease.authHeaders;

  Future<http.Response> get(String path) => http.get(uri(path), headers: auth);

  Future<http.Response> json(
    String method,
    String path, [
    Map<String, Object?> body = const {},
    String channel = 'chat',
  ]) => switch (method) {
    'POST' => http.post(
      uri(path),
      headers: {
        ...auth,
        'X-Playmesh-AI-Channel': channel,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    ),
    'PATCH' => http.patch(
      uri(path),
      headers: {
        ...auth,
        'X-Playmesh-AI-Channel': channel,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    ),
    'PUT' => http.put(
      uri(path),
      headers: {
        ...auth,
        'X-Playmesh-AI-Channel': channel,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    ),
    'DELETE' => http.delete(
      uri(path),
      headers: {...auth, 'X-Playmesh-AI-Channel': channel},
    ),
    _ => throw ArgumentError.value(method),
  };

  Future<Map<String, Object?>> openSession({
    required String mode,
    bool includeContext = false,
    String? resumeEditorSessionId,
  }) async {
    final response = await json('POST', '$aiBase/editor-sessions', {
      'mode': mode,
      'locale': 'zh-CN',
      if (includeContext) 'context': await projectContext(),
      'resumeEditorSessionId': ?resumeEditorSessionId,
    }, mode);
    expect(response.statusCode, HttpStatus.created, reason: response.body);
    return _json(response);
  }

  Future<String> createTurn(
    String sessionId,
    String clientMessageId, {
    int? echo,
  }) async {
    final response = await json(
      'POST',
      '$aiBase/editor-sessions/$sessionId/turns',
      {'clientMessageId': clientMessageId, 'echo': ?echo},
    );
    expect(response.statusCode, HttpStatus.created, reason: response.body);
    final turn = _json(response)['turn']! as Map;
    expect(turn['echo'], echo);
    return turn['turnId']! as String;
  }

  Future<void> approveSinglePending({String decision = 'once'}) async {
    Map? pending;
    for (var attempt = 0; attempt < 20 && pending == null; attempt += 1) {
      final approvals = await get('/dev/api/ai-approvals');
      expect(approvals.statusCode, HttpStatus.ok, reason: approvals.body);
      final items = _json(approvals)['approvals']! as List;
      if (items.isNotEmpty) pending = items.single as Map;
      if (pending == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    expect(pending, isNotNull);
    final response = await json(
      'POST',
      '/dev/api/ai-approvals/${pending!['approvalId']}',
      {'decision': decision},
    );
    expect(response.statusCode, HttpStatus.ok, reason: response.body);
  }

  Future<Map<String, Object?>> projectContext({
    String sceneName = 'Current Scene',
  }) async {
    final tools = await get('/dev/api/gdevelop/ai/tools');
    expect(tools.statusCode, HttpStatus.ok, reason: tools.body);
    final capabilities = Map<String, Object?>.from(
      _json(tools)['capabilitiesReference']! as Map,
    );
    return <String, Object?>{
      'schemaVersion': '1.0.0',
      'selectedScene': {
        'name': sceneName,
        'eventsText': '$sceneName event text',
      },
      'projectSummary': {
        'simplifiedProject': {
          'properties': {
            'gameResolutionWidth': 800,
            'gameResolutionHeight': 600,
          },
          'globalObjects': <Object?>[],
          'globalObjectGroups': <Object?>[],
          'scenes': [
            {
              'sceneName': sceneName,
              'objects': <Object?>[],
              'objectGroups': <Object?>[],
              'sceneVariables': <Object?>[],
              'layers': <Object?>[],
              'instancesOnSceneDescription': '',
            },
          ],
          'globalVariables': <Object?>[],
          'resources': <Object?>[],
        },
        'projectSpecificExtensionsSummary': {'extensionSummaries': <Object?>[]},
      },
      'capabilities': capabilities,
    };
  }

  Future<void> close() async {
    await editorLease.release();
    await gateway.close();
    sessions.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }

  static Future<_AiGatewayFixture> create({
    GDevelopAiToolRegistryProvider? toolsProvider,
    DeveloperAiApprovalBroker? approvalBroker,
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-ai-v2-');
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    await history.createProjectRoot(
      gameId: _gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: 'GDevelop AI v2 fixture',
    );
    await history.snapshot(
      projectId: _gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: const [
        GDevelopProjectFile(path: 'game.json', content: {'name': 'saved'}),
      ],
      resources: const [],
    );
    final sessions = GDevelopAiSessionService();
    final editorInstances = GDevelopEditorInstanceLeaseManager();
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: _token,
      path: 'gdevelopaiv2test',
      gdevelopHistory: history,
      gdevelopAiSessions: sessions,
      gdevelopAiToolsProvider:
          toolsProvider ?? () async => loadGDevelopAiToolRegistryForTest(),
      promptTemplates: DeveloperAiPromptTemplateStore(
        bundle: _FileAssetBundle(),
        root: Directory('assets/playmesh-library/public/developer/prompts'),
      ),
      gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
        enabled: true,
      ),
      approvalBroker: approvalBroker,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      gdevelopEditorInstances: editorInstances,
    );
    final editorLease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: _token,
    );
    return _AiGatewayFixture(
      gateway: gateway,
      history: history,
      sessions: sessions,
      root: root,
      port: port,
      editorLease: editorLease,
      editorInstances: editorInstances,
      toolContract: loadGDevelopAiToolContractForTest(),
    );
  }
}

class _BlockingApprovalBarrierPersistence
    implements DeveloperAiApprovalPersistence {
  final Completer<void> nonEmptySaveStarted = Completer<void>();
  final Completer<void> allowNonEmptySave = Completer<void>();
  bool _blocked = false;
  Set<DeveloperAiApprovalGrant> grants = {};

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

class _FileAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

Future<String> _hash(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
