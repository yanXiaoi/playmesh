import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_ai_prompt_templates.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';
import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  test('HTTP 写工具只透传结果，不写历史，下一轮读取可继续执行', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final before = await fixture.history.currentReferenceSnapshot(
      _Fixture.gameId,
    );

    final opened = await fixture.post('${fixture.aiBase}/editor-sessions', {
      'mode': 'chat',
      'locale': 'zh-CN',
    });
    expect(opened.statusCode, HttpStatus.created, reason: opened.body);
    final openedJson = _json(opened);
    expect(openedJson['protocolVersion'], '4.0.0');
    final session = openedJson['session']! as Map;
    expect(session['approvalMode'], 'request_approval');
    expect(session, isNot(contains('projectRevision')));
    expect(session, isNot(contains('projectContentHash')));
    final sessionId = session['editorSessionId']! as String;
    final callBase = '${fixture.aiBase}/editor-sessions/$sessionId/calls';

    final writeTurn = await fixture.post(
      '${fixture.aiBase}/editor-sessions/$sessionId/turns',
      {'clientMessageId': 'write-turn'},
    );
    final writeTurnId = (_json(writeTurn)['turn']! as Map)['turnId']! as String;
    final writeEnqueue = await fixture.post(callBase, {
      'turnId': writeTurnId,
      'callId': 'write-call',
      'idempotencyKey': 'write-key',
      'toolName': 'create_scene',
      'arguments': {'scene_name': 'Game'},
    });
    expect(
      writeEnqueue.statusCode,
      HttpStatus.accepted,
      reason: writeEnqueue.body,
    );
    expect((_json(writeEnqueue)['call']! as Map)['state'], 'queued');

    final leasedWrite = await fixture.post('$callBase/next', const {});
    expect((_json(leasedWrite)['call']! as Map)['state'], 'running');
    final writeResult = await fixture.post('$callBase/write-call/execution', {
      'success': true,
      'output': {'created': true, 'sceneName': 'Game'},
    });
    final terminalWrite = _json(writeResult)['call']! as Map;
    expect(terminalWrite['state'], 'finished');
    expect(terminalWrite, isNot(contains('commitEvidence')));
    expect(terminalWrite, isNot(contains('baseRevision')));
    expect(terminalWrite, isNot(contains('baseProjectContentHash')));

    final after = await fixture.history.currentReferenceSnapshot(
      _Fixture.gameId,
    );
    expect(after?.toJson(), before?.toJson());
    expect(await fixture.history.list(_Fixture.gameId), hasLength(1));

    final readTurn = await fixture.post(
      '${fixture.aiBase}/editor-sessions/$sessionId/turns',
      {'clientMessageId': 'read-turn'},
    );
    final readTurnId = (_json(readTurn)['turn']! as Map)['turnId']! as String;
    final readEnqueue = await fixture.post(callBase, {
      'turnId': readTurnId,
      'callId': 'read-call',
      'idempotencyKey': 'read-key',
      'toolName': 'read_scene_events',
      'arguments': {'scene_name': 'Game'},
    });
    expect(
      readEnqueue.statusCode,
      HttpStatus.accepted,
      reason: readEnqueue.body,
    );
    final leasedRead = await fixture.post('$callBase/next', const {});
    expect((_json(leasedRead)['call']! as Map)['callId'], 'read-call');
    final readResult = await fixture.post('$callBase/read-call/execution', {
      'success': true,
      'output': {'eventsAsText': 'SceneJustBegins'},
    });
    expect((_json(readResult)['call']! as Map)['state'], 'finished');
  });

  test('旧 revision/hash 与 execution 提交字段被严格拒绝', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);

    final oldOpen = await fixture.post('${fixture.aiBase}/editor-sessions', {
      'mode': 'chat',
      'locale': 'zh-CN',
      'baseRevision': 1,
    });
    expect(oldOpen.statusCode, HttpStatus.badRequest);

    final opened = await fixture.post('${fixture.aiBase}/editor-sessions', {
      'mode': 'chat',
      'locale': 'zh-CN',
    });
    final sessionId =
        (_json(opened)['session']! as Map)['editorSessionId']! as String;
    final sessionBase = '${fixture.aiBase}/editor-sessions/$sessionId';
    final turn = await fixture.post('$sessionBase/turns', const {});
    final turnId = (_json(turn)['turn']! as Map)['turnId']! as String;
    final oldCall = await fixture.post('$sessionBase/calls', {
      'turnId': turnId,
      'callId': 'old-call',
      'idempotencyKey': 'old-key',
      'toolName': 'create_scene',
      'arguments': {'scene_name': 'Game'},
      'baseRevision': 1,
      'baseProjectContentHash': 'a' * 64,
    });
    expect(oldCall.statusCode, HttpStatus.badRequest);
  });

  test('无效 execution 请求只失败本次 HTTP，调用仍可提交正确结果', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);

    final opened = await fixture.post('${fixture.aiBase}/editor-sessions', {
      'mode': 'chat',
      'locale': 'zh-CN',
    });
    final sessionId =
        (_json(opened)['session']! as Map)['editorSessionId']! as String;
    final sessionBase = '${fixture.aiBase}/editor-sessions/$sessionId';
    final turn = await fixture.post('$sessionBase/turns', const {});
    final turnId = (_json(turn)['turn']! as Map)['turnId']! as String;
    await fixture.post('$sessionBase/calls', {
      'turnId': turnId,
      'callId': 'retry-execution-call',
      'idempotencyKey': 'retry-execution-key',
      'toolName': 'read_scene_events',
      'arguments': {'scene_name': 'Game'},
    });
    await fixture.post('$sessionBase/calls/next', const {});

    final invalid = await fixture.postRaw(
      '$sessionBase/calls/retry-execution-call/execution',
      '{"success":true,"output":',
    );
    expect(invalid.statusCode, HttpStatus.badRequest, reason: invalid.body);

    final listed = await fixture.get('$sessionBase/calls?afterSequence=0');
    final call = (_json(listed)['calls']! as List).cast<Map>().singleWhere(
      (item) => item['callId'] == 'retry-execution-call',
    );
    expect(call['state'], 'running');
    expect(call, isNot(contains('output')));

    final valid = await fixture.post(
      '$sessionBase/calls/retry-execution-call/execution',
      {
        'success': true,
        'output': {'eventsAsText': 'SceneJustBegins'},
      },
    );
    expect(valid.statusCode, HttpStatus.ok, reason: valid.body);
    expect((_json(valid)['call']! as Map)['state'], 'finished');
  });
}

Map<String, Object?> _json(http.Response response) =>
    Map<String, Object?>.from(jsonDecode(response.body) as Map);

class _Fixture {
  _Fixture({
    required this.gateway,
    required this.history,
    required this.sessions,
    required this.editorLease,
    required this.projectsRoot,
    required this.port,
  });

  static const gameId = 'com.example.gdevelop-ai-result-only';
  static const token =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  final DeveloperWebGateway gateway;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopAiSessionService sessions;
  final GDevelopEditorLeaseTestClient editorLease;
  final Directory projectsRoot;
  final int port;

  String get aiBase => '/dev/api/gdevelop/projects/$gameId/ai';

  Future<http.Response> post(String path, Map<String, Object?> body) =>
      http.post(
        Uri.parse('http://127.0.0.1:$port$path'),
        headers: {
          ...editorLease.authHeaders,
          'X-Playmesh-AI-Channel': 'chat',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

  Future<http.Response> get(String path) => http.get(
    Uri.parse('http://127.0.0.1:$port$path'),
    headers: {...editorLease.authHeaders, 'X-Playmesh-AI-Channel': 'chat'},
  );

  Future<http.Response> postRaw(String path, String body) => http.post(
    Uri.parse('http://127.0.0.1:$port$path'),
    headers: {
      ...editorLease.authHeaders,
      'X-Playmesh-AI-Channel': 'chat',
      'Content-Type': 'application/json',
    },
    body: body,
  );

  Future<void> close() async {
    await editorLease.release();
    await gateway.close();
    sessions.dispose();
    if (await projectsRoot.exists()) await projectsRoot.delete(recursive: true);
  }

  static Future<_Fixture> create() async {
    final projectsRoot = await Directory.systemTemp.createTemp(
      'gdevelop-ai-result-only-',
    );
    final promptRoot = Directory(
      'assets/playmesh-library/public/developer/prompts',
    );
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: projectsRoot,
      cleanupJournal: File(
        '${projectsRoot.path}${Platform.pathSeparator}cleanup.json',
      ),
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: 'AI result-only workflow',
    );
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: const [
        GDevelopProjectFile(path: 'game.json', content: {'name': 'saved'}),
      ],
      resources: const [],
    );
    final sessions = GDevelopAiSessionService();
    final promptTemplates = DeveloperAiPromptTemplateStore(
      bundle: _FileAssetBundle(),
      root: promptRoot,
    );
    await promptTemplates.resolveSessionLocale('zh-CN');
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'gdevelopairesulttest',
      gdevelopHistory: history,
      gdevelopAiSessions: sessions,
      gdevelopAiToolsProvider: () async => loadGDevelopAiToolRegistryForTest(),
      promptTemplates: promptTemplates,
      gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
        enabled: true,
      ),
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    final editorLease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    return _Fixture(
      gateway: gateway,
      history: history,
      sessions: sessions,
      editorLease: editorLease,
      projectsRoot: projectsRoot,
      port: port,
    );
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _FileAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
