import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval_store.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';
import '../../support/gdevelop_ai_tool_contract_test_support.dart';

final _webIdeToolRegistry = loadGDevelopAiToolRegistryForTest();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'unavailable GDevelop workspace disables backend, catalog, and IDE UI',
    () async {
      final sessions = GDevelopAiSessionService();
      final session = sessions.open(
        gameId: 'game-off',
        mode: GDevelopAiMode.chat,
        locale: 'en-US',
        registry: _webIdeToolRegistry,
      );
      final port = await _freePort();
      final webIdeSource = _MemoryGDevelopSource(available: false);
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: _developerToken,
        path: 'featureofftest',
        gdevelopAiSessions: sessions,
        gdevelopWebIdeSource: webIdeSource,
      );
      addTearDown(gateway.close);
      final base = Uri.parse('http://127.0.0.1:$port');
      webIdeSource.available = true;
      final workspaceUri = (await gateway.gdevelopWorkspaceLinks()).first;
      webIdeSource.available = false;
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: base,
        workspaceUri: workspaceUri,
        developerToken: _developerToken,
      );
      addTearDown(lease.release);

      Future<http.Response> developerGet(String path) {
        final relative = Uri.parse(path);
        return http.get(
          base.replace(
            path: relative.path,
            query: relative.hasQuery ? relative.query : null,
          ),
          headers: lease.authHeaders,
        );
      }

      for (final path in [
        '/dev/api/gdevelop/ai/tools',
        '/dev/api/gdevelop/projects/game-off/ai/editor-sessions/'
            '${session.id}',
        '/dev/api/gdevelop/projects/game-off/ai/editor-sessions/'
            '${session.id}/prompt.txt',
      ]) {
        final response = await developerGet(path);
        expect(response.statusCode, HttpStatus.notFound, reason: path);
      }

      final scopedEvents = await http.get(
        base.replace(
          path:
              '/dev/api/gdevelop/projects/game-off/ai/editor-sessions/'
              '${session.id}/events',
        ),
        headers: lease.authHeaders,
      );
      expect(scopedEvents.statusCode, HttpStatus.notFound);

      final gdevelopPrompts = await developerGet(
        '/dev/api/ai-prompt-templates?surface=gdevelop',
      );
      expect(gdevelopPrompts.statusCode, HttpStatus.notFound);

      final openApi = await developerGet('/dev/openapi.json');
      expect(openApi.statusCode, HttpStatus.ok);
      final paths = (jsonDecode(openApi.body)['paths'] as Map).keys
          .cast<String>();
      expect(
        paths.where(
          (path) => path.contains('/gdevelop/') && path.contains('/ai'),
        ),
        isEmpty,
      );
      final operationCatalog = await developerGet(
        '/dev/api/operations?target=all',
      );
      expect(operationCatalog.statusCode, HttpStatus.ok);
      expect(operationCatalog.body, isNot(contains('gdevelop.ai.')));

      final workspace = await developerGet('/dev/featureofftest/workspace');
      expect(workspace.statusCode, HttpStatus.ok);
      expect(workspace.body, contains(r'"gdevelopAi"'));
      expect(workspace.body, contains(r'"enabled":false'));

      final globalClient = http.Client();
      addTearDown(globalClient.close);
      final globalRequest = http.Request(
        'GET',
        base.replace(path: '/dev/api/events'),
      )..headers[HttpHeaders.authorizationHeader] = 'Bearer $_developerToken';
      final globalEvents = await globalClient.send(globalRequest);
      expect(globalEvents.statusCode, HttpStatus.ok);
      final globalAiEvents = <Map<String, Object?>>[];
      final globalSubscription = globalEvents.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data: '))
          .map(
            (line) =>
                Map<String, Object?>.from(jsonDecode(line.substring(6)) as Map),
          )
          .where(
            (event) =>
                (event['type'] as String?)?.startsWith('gdevelop.ai.') ?? false,
          )
          .listen(globalAiEvents.add);
      final offTurn = sessions.createTurn(
        session.id,
        clientMessageId: 'feature-off-diagnostics',
      );
      sessions.enqueueCall(
        editorSessionId: session.id,
        turnId: offTurn.id,
        callId: 'feature-off-call',
        idempotencyKey: 'feature-off-call-idempotency',
        toolName: 'inspect_object_properties_effects',
        arguments: {'scene_name': 'Scene', 'object_name': 'Player'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(globalAiEvents, isEmpty);
      await globalSubscription.cancel();
      globalClient.close();
    },
  );

  test(
    'trusted global diagnostics keep full GDevelop AI events when enabled',
    () async {
      const gameId = 'com.example.globaldiagnostics';
      final projectsRoot = await Directory.systemTemp.createTemp(
        'gdevelop-ai-global-diagnostics-',
      );
      addTearDown(() async {
        if (await projectsRoot.exists()) {
          await projectsRoot.delete(recursive: true);
        }
      });
      final history = GDevelopProjectHistoryAdapter(
        rootResolver: FileSystemGDevelopProjectRootResolver(
          projectsRoot: projectsRoot,
        ),
      );
      await history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        name: 'Global diagnostics fixture',
      );
      final sessions = GDevelopAiSessionService();
      final session = sessions.open(
        gameId: gameId,
        mode: GDevelopAiMode.agent,
        locale: 'en-US',
        registry: _webIdeToolRegistry,
      );
      final port = await _freePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: _developerToken,
        path: 'globaldiagnosticstest',
        gdevelopAiSessions: sessions,
        gdevelopHistory: history,
        gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
          enabled: true,
        ),
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(gateway.close);
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: _developerToken,
      );
      addTearDown(lease.release);
      final client = http.Client();
      addTearDown(client.close);
      final request = http.Request(
        'GET',
        Uri.parse('http://127.0.0.1:$port/dev/api/events'),
      )..headers[HttpHeaders.authorizationHeader] = 'Bearer $_developerToken';
      final response = await client.send(request);
      expect(response.statusCode, HttpStatus.ok);
      final diagnosticFuture = _readGlobalSseEvent(
        response.stream,
        type: 'gdevelop.ai.call.updated',
      );

      final turn = sessions.createTurn(
        session.id,
        clientMessageId: 'global-diagnostics-turn',
      );
      final call = sessions.enqueueCall(
        editorSessionId: session.id,
        turnId: turn.id,
        callId: 'global-diagnostics-call',
        idempotencyKey: 'global-diagnostics-idempotency',
        toolName: 'inspect_object_properties_effects',
        arguments: {'scene_name': 'Scene', 'object_name': 'Player'},
      );
      final diagnostic = await diagnosticFuture.timeout(
        const Duration(seconds: 3),
      );
      expect(diagnostic['gameId'], gameId);
      expect(diagnostic['editorSessionId'], session.id);
      expect(diagnostic['turnId'], turn.id);
      expect(diagnostic['callId'], call.id);
      expect(diagnostic['toolName'], 'inspect_object_properties_effects');
      expect(diagnostic['arguments'], {
        'scene_name': 'Scene',
        'object_name': 'Player',
      });
      expect(diagnostic['idempotencyKey'], 'global-diagnostics-idempotency');
      expect(diagnostic['eventId'], isNotEmpty);
      expect(diagnostic['timestamp'], isA<int>());
      client.close();

      final closeClient = http.Client();
      addTearDown(closeClient.close);
      final closeStream = await closeClient.send(
        http.Request(
          'GET',
          Uri.parse('http://127.0.0.1:$port/dev/api/events'),
        )..headers[HttpHeaders.authorizationHeader] = 'Bearer $_developerToken',
      );
      expect(closeStream.statusCode, HttpStatus.ok);
      final closedDiagnosticFuture = _readGlobalSseEvent(
        closeStream.stream,
        type: 'gdevelop.ai.session.updated',
      );
      final closedResponse = await http.delete(
        Uri.parse(
          'http://127.0.0.1:$port/dev/api/gdevelop/projects/'
          '$gameId/ai/editor-sessions/${session.id}',
        ),
        headers: lease.authHeaders,
      );
      expect(
        closedResponse.statusCode,
        HttpStatus.ok,
        reason: closedResponse.body,
      );
      final closedDiagnostic = await closedDiagnosticFuture.timeout(
        const Duration(seconds: 3),
      );
      expect(closedDiagnostic['action'], 'closed');
      expect(closedDiagnostic['gameId'], gameId);
      expect(closedDiagnostic['editorSessionId'], session.id);
      expect(closedDiagnostic['closed'], isTrue);
      // Closing first terminalizes the pending call, then advances once more
      // for the session-closed transition itself.
      expect(closedDiagnostic['sequence'], call.sequence + 2);
    },
  );

  test(
    'scoped named SSE isolates games and replays after exact sequence',
    () async {
      final sessions = GDevelopAiSessionService();
      final first = sessions.open(
        gameId: 'game-one',
        mode: GDevelopAiMode.agent,
        locale: 'en-US',
        registry: _webIdeToolRegistry,
      );
      final second = sessions.open(
        gameId: 'game-two',
        mode: GDevelopAiMode.agent,
        locale: 'en-US',
        registry: _webIdeToolRegistry,
      );
      final port = await _freePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: _developerToken,
        path: 'scopedeventtest',
        gdevelopAiSessions: sessions,
        gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
          enabled: true,
        ),
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(gateway.close);
      final base = Uri.parse('http://127.0.0.1:$port');
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: base,
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: _developerToken,
      );
      addTearDown(lease.release);
      Uri eventsUri(String gameId, String sessionId, {int after = 0}) =>
          base.replace(
            path:
                '/dev/api/gdevelop/projects/$gameId/ai/editor-sessions/'
                '$sessionId/events',
            queryParameters: {'afterSequence': '$after'},
          );

      final firstClient = http.Client();
      final request = http.Request('GET', eventsUri('game-one', first.id))
        ..headers.addAll(lease.authHeaders);
      final response = await firstClient.send(request);
      expect(response.statusCode, HttpStatus.ok);
      var delivered = false;
      final firstEventFuture = _readSseEvent(response.stream).then((event) {
        delivered = true;
        return event;
      });

      sessions.createTurn(second.id, clientMessageId: 'other-game');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(delivered, isFalse);
      final firstTurn = sessions.createTurn(
        first.id,
        clientMessageId: 'first-game',
      );
      final firstEvent = await firstEventFuture.timeout(
        const Duration(seconds: 3),
      );
      expect(firstEvent.name, 'gdevelop.ai.turn.created');
      expect(firstEvent.id, '${firstTurn.sequence}');
      expect(firstEvent.data, {
        'type': 'gdevelop.ai.turn.created',
        'gameId': 'game-one',
        'editorSessionId': first.id,
        'sequence': firstTurn.sequence,
        'turnId': firstTurn.id,
      });
      expect(
        firstEvent.data.keys.toSet().difference({
          'type',
          'gameId',
          'editorSessionId',
          'sequence',
          'turnId',
          'callId',
          'state',
        }),
        isEmpty,
      );
      firstClient.close();

      final replayTurn = sessions.createTurn(
        first.id,
        clientMessageId: 'reconnect',
      );
      final replayClient = http.Client();
      addTearDown(replayClient.close);
      final replayRequest = http.Request('GET', eventsUri('game-one', first.id))
        ..headers.addAll(lease.authHeaders)
        ..headers['Last-Event-ID'] = '${firstTurn.sequence}';
      final replayResponse = await replayClient.send(replayRequest);
      expect(replayResponse.statusCode, HttpStatus.ok);
      final replayEvent = await _readSseEvent(
        replayResponse.stream,
      ).timeout(const Duration(seconds: 3));
      expect(replayEvent.name, 'gdevelop.ai.turn.created');
      expect(replayEvent.id, '${replayTurn.sequence}');
      expect(replayEvent.data['turnId'], replayTurn.id);
      expect(replayEvent.data['gameId'], 'game-one');
      expect(replayEvent.data['editorSessionId'], first.id);
    },
  );

  test(
    'Developer Mode close cancels calls, approval, lease, SSE, and stale prompt',
    () async {
      const gameId = 'lifecycle-game';
      final sessions = GDevelopAiSessionService();
      final approvals = DeveloperAiApprovalBroker(
        persistence: _MemoryApprovalPersistence(),
        idFactory: () => 'lifecycle-approval',
      );
      final session = sessions.open(
        gameId: gameId,
        mode: GDevelopAiMode.agent,
        locale: 'en-US',
        registry: _webIdeToolRegistry,
      );
      final turn = sessions.createTurn(session.id);
      final leasedCall = sessions.enqueueCall(
        editorSessionId: session.id,
        turnId: turn.id,
        callId: 'lifecycle-writer',
        idempotencyKey: 'lifecycle-writer-idempotency',
        toolName: 'create_scene',
        arguments: const {'scene_name': 'Lifecycle'},
      );
      expect(
        sessions.leaseNext(session.id)?.state,
        GDevelopAiCallState.running,
      );
      expect(sessions.writerLease(gameId)?.callId, leasedCall.id);

      final pendingCall = sessions.enqueueCall(
        editorSessionId: session.id,
        turnId: turn.id,
        callId: 'lifecycle-pending',
        idempotencyKey: 'lifecycle-pending-idempotency',
        toolName: 'change_scene_properties_layers_effects_groups',
        arguments: const {'scene_name': 'Lifecycle'},
      );
      final pendingDecision = approvals.request(
        requestId: 'lifecycle-request',
        cancellation: sessions.cancellationSignal(session.id, pendingCall.id),
        subject: const DeveloperAiApprovalSubject(
          scopeKind: 'gdevelop',
          scopeId: gameId,
          operationId:
              'gdevelop.tool.change_scene_properties_layers_effects_groups',
          summary: '删除场景',
          description: 'Developer Mode lifecycle test',
          risk: 'high',
          dangerous: true,
          channel: 'agent',
        ),
      );

      final port = await _freePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: _developerToken,
        path: 'lifecycle',
        gdevelopAiSessions: sessions,
        approvalBroker: approvals,
        gdevelopWebIdeSource: _MemoryGDevelopSource(),
      );
      final base = Uri.parse('http://127.0.0.1:$port');
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: base,
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: _developerToken,
      );
      final sseClient = http.Client();
      final sse = await sseClient.send(
        http.Request(
          'GET',
          base.replace(
            path:
                '/dev/api/gdevelop/projects/$gameId/ai/editor-sessions/'
                '${session.id}/events',
          ),
        )..headers.addAll(lease.authHeaders),
      );
      expect(sse.statusCode, HttpStatus.ok);
      final sseClosed = sse.stream.drain<void>().then(
        (_) => true,
        onError: (Object error) {
          expect(error, isA<http.ClientException>());
          return true;
        },
      );

      await gateway.close();
      await expectLater(
        pendingDecision,
        completion(DeveloperAiApprovalResult.rejected),
      );
      expect(approvals.pending, isEmpty);
      expect(sessions.writerLease(gameId), isNull);
      expect(await sseClosed.timeout(const Duration(seconds: 3)), isTrue);
      sseClient.close();

      final restartedSessions = GDevelopAiSessionService();
      final restarted = await startDeveloperWebGateway(
        port: port,
        token: _developerToken,
        path: 'lifecycle',
        gdevelopAiSessions: restartedSessions,
        gdevelopWebIdeSource: _MemoryGDevelopSource(),
      );
      addTearDown(restarted.close);
      final restartedLease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: base,
        workspaceUri: (await restarted.gdevelopWorkspaceLinks()).first,
        developerToken: _developerToken,
      );
      addTearDown(restartedLease.release);
      final stalePrompt = await http.get(
        base.replace(
          path:
              '/dev/api/gdevelop/projects/$gameId/ai/editor-sessions/'
              '${session.id}/prompt.txt',
        ),
        headers: restartedLease.authHeaders,
      );
      expect(stalePrompt.statusCode, HttpStatus.notFound);
      final catalog = await http.get(
        base.replace(
          path: '/dev/api/operations',
          queryParameters: {'target': 'all'},
        ),
        headers: _developerHeaders,
      );
      expect(catalog.statusCode, HttpStatus.ok);
      expect(catalog.body, contains('gdevelop.ai.session.open'));
      await lease.release();
    },
  );

  test('pending GDevelop approvals require the active editor lease', () async {
    final sessions = GDevelopAiSessionService();
    final first = sessions.open(
      gameId: 'approval-one',
      mode: GDevelopAiMode.agent,
      locale: 'en-US',
      registry: _webIdeToolRegistry,
    );
    final second = sessions.open(
      gameId: 'approval-two',
      mode: GDevelopAiMode.agent,
      locale: 'en-US',
      registry: _webIdeToolRegistry,
    );
    final approvals = DeveloperAiApprovalBroker(
      persistence: _MemoryApprovalPersistence(),
      idFactory: () => 'approval-${_approvalSequence++}',
    );
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: _developerToken,
      path: 'scopedapprovaltest',
      gdevelopAiSessions: sessions,
      approvalBroker: approvals,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
        enabled: true,
      ),
    );
    addTearDown(gateway.close);
    final base = Uri.parse('http://127.0.0.1:$port');
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: base,
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: _developerToken,
    );
    addTearDown(lease.release);
    final firstDecision = approvals.request(
      requestId: 'request-one',
      subject: DeveloperAiApprovalSubject(
        scopeKind: 'gdevelop',
        scopeId: 'approval-one',
        operationId: 'gdevelop.ai.call.enqueue',
        summary: 'first',
        description: 'first',
        risk: 'high',
        dangerous: true,
        channel: 'gdevelop-agent',
        editorSessionId: first.id,
        callId: 'call-one',
      ),
    );
    final secondDecision = approvals.request(
      requestId: 'request-two',
      subject: DeveloperAiApprovalSubject(
        scopeKind: 'gdevelop',
        scopeId: 'approval-two',
        operationId: 'gdevelop.ai.call.enqueue',
        summary: 'second',
        description: 'second',
        risk: 'high',
        dangerous: true,
        channel: 'gdevelop-agent',
        editorSessionId: second.id,
        callId: 'call-two',
      ),
    );
    await _waitFor(() => approvals.pending.length == 2);
    final firstApprovalId =
        approvals.pending.singleWhere(
              (approval) => approval['gameId'] == 'approval-one',
            )['approvalId']!
            as String;
    final secondApprovalId =
        approvals.pending.singleWhere(
              (approval) => approval['gameId'] == 'approval-two',
            )['approvalId']!
            as String;

    final unauthenticated = await http.get(
      base.replace(path: '/dev/api/ai-approvals'),
    );
    expect(unauthenticated.statusCode, HttpStatus.unauthorized);

    final listResponse = await http.get(
      base.replace(path: '/dev/api/ai-approvals'),
      headers: lease.authHeaders,
    );
    expect(listResponse.statusCode, HttpStatus.ok);
    final listed = jsonDecode(listResponse.body)['approvals'] as List;
    expect(listed, hasLength(2));
    expect(listResponse.body, contains(firstApprovalId));
    expect(listResponse.body, contains(secondApprovalId));

    final accepted = await http.post(
      base.replace(path: '/dev/api/ai-approvals/$firstApprovalId'),
      headers: {
        ...lease.authHeaders,
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
      },
      body: jsonEncode({'decision': 'once'}),
    );
    expect(accepted.statusCode, HttpStatus.ok, reason: accepted.body);
    expect(await firstDecision, DeveloperAiApprovalResult.approved);
    final rejected = await http.post(
      base.replace(path: '/dev/api/ai-approvals/$secondApprovalId'),
      headers: {
        ...lease.authHeaders,
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
      },
      body: jsonEncode({'decision': 'reject'}),
    );
    expect(rejected.statusCode, HttpStatus.ok, reason: rejected.body);
    expect(await secondDecision, DeveloperAiApprovalResult.rejected);
  });
}

const _developerToken = 'gdevelop-scoped-events-test-token';
var _approvalSequence = 0;
const _developerHeaders = <String, String>{
  HttpHeaders.authorizationHeader: 'Bearer $_developerToken',
};

class _MemoryGDevelopSource implements GDevelopWebIdeSource {
  _MemoryGDevelopSource({this.available = true});

  bool available;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Uint8List?> read(String relativePath) async =>
      available && relativePath == 'index.html'
      ? Uint8List.fromList(
          utf8.encode('<!doctype html><html><head></head><body></body></html>'),
        )
      : null;
}

class _MemoryApprovalPersistence implements DeveloperAiApprovalPersistence {
  Set<DeveloperAiApprovalGrant> grants = {};

  @override
  Future<Set<DeveloperAiApprovalGrant>> load() async => Set.of(grants);

  @override
  Future<void> save(Iterable<DeveloperAiApprovalGrant> grants) async {
    this.grants = grants.toSet();
  }
}

class _SseEvent {
  const _SseEvent({required this.name, required this.id, required this.data});

  final String name;
  final String id;
  final Map<String, Object?> data;
}

Future<_SseEvent> _readSseEvent(Stream<List<int>> bytes) async {
  String? name;
  String? id;
  String? data;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.startsWith('event: ')) name = line.substring(7);
    if (line.startsWith('id: ')) id = line.substring(4);
    if (line.startsWith('data: ')) data = line.substring(6);
    if (line.isEmpty && name != null && id != null && data != null) {
      return _SseEvent(
        name: name,
        id: id,
        data: Map<String, Object?>.from(jsonDecode(data) as Map),
      );
    }
  }
  throw StateError('SSE stream ended before a named event');
}

Future<Map<String, Object?>> _readGlobalSseEvent(
  Stream<List<int>> bytes, {
  required String type,
}) async {
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data: ')) continue;
    final event = Map<String, Object?>.from(
      jsonDecode(line.substring(6)) as Map,
    );
    if (event['type'] == type) return event;
  }
  throw StateError('SSE stream ended before global event $type');
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
