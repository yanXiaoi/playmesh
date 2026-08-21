import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval.dart';
import 'package:playmesh/core/developer/foundation/developer_ai_approval_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/models/game_summary.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('HTTP 可列出和撤销授权，source/GDevelop 删除分别清理自身 scope', () async {
    final root = await Directory.systemTemp.createTemp(
      'developer-ai-approval-gateway-',
    );
    addTearDown(() => root.delete(recursive: true));
    final projectsRoot = Directory(
      '${root.path}${Platform.pathSeparator}packages',
    );
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const <GameSummary>[]),
      workspaceRoot: projectsRoot,
    );
    const sourceId = 'com.example.approval-source';
    const gameId = 'com.example.approval-gdevelop';
    await catalog.createProject(
      DeveloperProjectDraft(
        id: sourceId,
        name: 'Approval Source',
        author: 'Test Author',
        lastModifiedAt: DateTime.utc(2026, 8, 5),
        mode: 'solo',
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 1,
        maxPlayers: 1,
      ),
    );
    final history = GDevelopProjectHistoryAdapter(
      rootResolver: FileSystemGDevelopProjectRootResolver(
        projectsRoot: projectsRoot,
        cleanupJournal: File(
          '${root.path}${Platform.pathSeparator}cleanup.json',
        ),
      ),
    );
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      fileIdentifier: 'approval-gdevelop-file',
      name: 'Approval GDevelop',
    );
    final approvalBroker = DeveloperAiApprovalBroker(
      persistence: FileDeveloperAiApprovalPersistence(
        file: File('${root.path}${Platform.pathSeparator}approval-grants.json'),
      ),
    );
    await approvalBroker.initialize();
    await _grantAlways(
      approvalBroker,
      scopeKind: 'source',
      scopeId: sourceId,
      operationId: 'projects.delete',
    );
    await _grantAlways(
      approvalBroker,
      scopeKind: 'gdevelop',
      scopeId: gameId,
      operationId:
          'gdevelop.tool.change_scene_properties_layers_effects_groups',
    );
    await _grantAlways(
      approvalBroker,
      scopeKind: 'gdevelop',
      scopeId: gameId,
      operationId: 'gdevelop.tool.change_behavior_property',
    );

    final port = await _availablePort();
    const token = 'approval-gateway-token';
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      catalog: catalog,
      gdevelopHistory: history,
      approvalBroker: approvalBroker,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    addTearDown(gateway.close);
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: base,
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    addTearDown(lease.release);
    final headers = {
      ...lease.authHeaders,
      HttpHeaders.contentTypeHeader: 'application/json',
    };
    final unboundAgentHeaders = {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.contentTypeHeader: 'application/json',
      'X-Playmesh-AI-Channel': 'agent',
    };

    Future<List<Map<String, Object?>>> grants() async {
      final response = await http.get(
        base.resolve('/dev/api/ai-approval-grants'),
        headers: headers,
      );
      expect(response.statusCode, HttpStatus.ok, reason: response.body);
      return ((jsonDecode(response.body) as Map)['grants'] as List)
          .map((item) => Map<String, Object?>.from(item as Map))
          .toList();
    }

    final unboundGrants = await http.get(
      base.resolve('/dev/api/ai-approval-grants'),
      headers: unboundAgentHeaders,
    );
    expect(unboundGrants.statusCode, HttpStatus.ok, reason: unboundGrants.body);
    final unboundGrantItems =
        ((jsonDecode(unboundGrants.body) as Map)['grants'] as List).cast<Map>();
    expect(unboundGrantItems, hasLength(1));
    expect(unboundGrantItems.single['scopeKind'], 'source');

    final initial = await grants();
    expect(initial, hasLength(3));
    final revokedGrant = initial.singleWhere(
      (grant) =>
          grant['operationId'] == 'gdevelop.tool.change_behavior_property',
    );
    final unboundRevoke = await http.delete(
      base.resolve(
        '/dev/api/ai-approval-grants/${Uri.encodeComponent(revokedGrant['grantId']! as String)}',
      ),
      headers: unboundAgentHeaders,
    );
    expect(unboundRevoke.statusCode, HttpStatus.conflict);
    expect(
      ((jsonDecode(unboundRevoke.body) as Map)['error'] as Map)['code'],
      'gdevelop_editor_lease_required',
    );
    expect(await grants(), hasLength(3));
    final revoke = await http.delete(
      base.resolve(
        '/dev/api/ai-approval-grants/${Uri.encodeComponent(revokedGrant['grantId']! as String)}',
      ),
      headers: headers,
    );
    expect(revoke.statusCode, HttpStatus.ok, reason: revoke.body);
    expect(await grants(), hasLength(2));
    final missingRevoke = await http.delete(
      base.resolve(
        '/dev/api/ai-approval-grants/${Uri.encodeComponent(revokedGrant['grantId']! as String)}',
      ),
      headers: headers,
    );
    expect(missingRevoke.statusCode, HttpStatus.notFound);

    final sourcePending = approvalBroker.request(
      requestId: 'source-pending',
      subject: const DeveloperAiApprovalSubject(
        scopeKind: 'source',
        scopeId: sourceId,
        operationId: 'source.pending.operation',
        summary: 'Source pending',
        description: 'Source pending',
        risk: 'high',
        dangerous: true,
        channel: 'source-agent',
      ),
    );
    final gdevelopPending = approvalBroker.request(
      requestId: 'gdevelop-pending',
      subject: const DeveloperAiApprovalSubject(
        scopeKind: 'gdevelop',
        scopeId: gameId,
        operationId: 'gdevelop.tool.pending_operation',
        summary: 'GDevelop pending',
        description: 'GDevelop pending',
        risk: 'high',
        dangerous: true,
        channel: 'gdevelop-agent',
        callId: 'pending-call',
        editorSessionId: 'pending-editor-session',
      ),
    );
    while (approvalBroker.pending.length != 2) {
      await Future<void>.delayed(Duration.zero);
    }
    final sourceApprovalId =
        approvalBroker.pending.singleWhere(
              (approval) => approval['scopeKind'] == 'source',
            )['approvalId']!
            as String;
    final gdevelopApprovalId =
        approvalBroker.pending.singleWhere(
              (approval) => approval['scopeKind'] == 'gdevelop',
            )['approvalId']!
            as String;

    final unboundApprovals = await http.get(
      base.resolve('/dev/api/ai-approvals'),
      headers: unboundAgentHeaders,
    );
    expect(unboundApprovals.statusCode, HttpStatus.ok);
    final unboundApprovalItems =
        ((jsonDecode(unboundApprovals.body) as Map)['approvals'] as List)
            .cast<Map>();
    expect(unboundApprovalItems, hasLength(1));
    expect(unboundApprovalItems.single['scopeKind'], 'source');

    final unboundGDevelopDecision = await http.post(
      base.resolve('/dev/api/ai-approvals/$gdevelopApprovalId'),
      headers: unboundAgentHeaders,
      body: jsonEncode({'decision': 'once'}),
    );
    expect(unboundGDevelopDecision.statusCode, HttpStatus.conflict);
    expect(
      ((jsonDecode(unboundGDevelopDecision.body) as Map)['error']
          as Map)['code'],
      'gdevelop_editor_lease_required',
    );
    expect(
      approvalBroker.pending.any(
        (approval) => approval['approvalId'] == gdevelopApprovalId,
      ),
      isTrue,
    );

    final sourceDecision = await http.post(
      base.resolve('/dev/api/ai-approvals/$sourceApprovalId'),
      headers: unboundAgentHeaders,
      body: jsonEncode({'decision': 'reject'}),
    );
    expect(
      sourceDecision.statusCode,
      HttpStatus.ok,
      reason: sourceDecision.body,
    );
    expect(await sourcePending, DeveloperAiApprovalResult.rejected);

    final boundApprovals = await http.get(
      base.resolve('/dev/api/ai-approvals'),
      headers: headers,
    );
    final boundApprovalItems =
        ((jsonDecode(boundApprovals.body) as Map)['approvals'] as List)
            .cast<Map>();
    expect(boundApprovalItems, hasLength(1));
    expect(boundApprovalItems.single['scopeKind'], 'gdevelop');
    final gdevelopDecision = await http.post(
      base.resolve('/dev/api/ai-approvals/$gdevelopApprovalId'),
      headers: headers,
      body: jsonEncode({'decision': 'reject'}),
    );
    expect(
      gdevelopDecision.statusCode,
      HttpStatus.ok,
      reason: gdevelopDecision.body,
    );
    expect(await gdevelopPending, DeveloperAiApprovalResult.rejected);

    final sourceDelete = await http.delete(
      base.resolve('/dev/api/projects/$sourceId'),
      headers: headers,
    );
    expect(sourceDelete.statusCode, HttpStatus.ok, reason: sourceDelete.body);
    expect((await grants()).single['scopeKind'], 'gdevelop');

    final gdevelopDelete = await http.delete(
      base.resolve('/dev/api/gdevelop/projects/$gameId'),
      headers: headers,
    );
    expect(
      gdevelopDelete.statusCode,
      anyOf(HttpStatus.ok, HttpStatus.accepted),
      reason: gdevelopDelete.body,
    );
    expect(await grants(), isEmpty);
  });
}

Future<void> _grantAlways(
  DeveloperAiApprovalBroker broker, {
  required String scopeKind,
  required String scopeId,
  required String operationId,
}) async {
  final result = broker.request(
    requestId: 'grant-$scopeKind-$scopeId-$operationId',
    subject: DeveloperAiApprovalSubject(
      scopeKind: scopeKind,
      scopeId: scopeId,
      operationId: operationId,
      summary: operationId,
      description: operationId,
      risk: 'high',
      dangerous: true,
      channel: '$scopeKind-agent',
    ),
  );
  while (broker.pending.isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  await broker.decide(
    broker.pending.single['approvalId']! as String,
    DeveloperAiApprovalDecision.always,
  );
  expect(await result, DeveloperAiApprovalResult.approved);
}

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
