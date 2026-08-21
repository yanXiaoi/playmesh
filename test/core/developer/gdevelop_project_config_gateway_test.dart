import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  test('GET/PUT config 提供 missing/ready 与稳定 CAS 409', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.config-api-a';

    final missing = await fixture.get(
      '/dev/api/gdevelop/projects/$gameId/config',
    );
    expect(missing.statusCode, HttpStatus.ok);
    expect(jsonDecode(missing.body)['status'], 'missing');
    expect(
      await fixture.configFile(gameId).exists(),
      isFalse,
      reason: '旧项目 GET missing 不得自动写 sidecar',
    );

    final updated = await fixture.jsonRequest(
      'PUT',
      '/dev/api/gdevelop/projects/$gameId/config',
      const {
        'schemaVersion': 2,
        'gameType': 'online',
        'minPlayers': 3,
        'maxPlayers': 9,
        'tags': ['party', 'co-op'],
        'expectedRevision': 0,
      },
    );
    expect(updated.statusCode, HttpStatus.ok);
    final updatedEnvelope = jsonDecode(updated.body);
    expect(updatedEnvelope['status'], 'ready');
    expect(updatedEnvelope['requestId'], startsWith('dev-'));
    expect(
      updated.headers['x-playmesh-operation-id'],
      'gdevelop.project.config.put',
    );
    expect(updatedEnvelope['config']['revision'], 1);
    expect(updatedEnvelope['config']['gameType'], 'online');
    expect(updatedEnvelope['config']['minPlayers'], 3);
    expect(updatedEnvelope['config']['maxPlayers'], 9);
    expect(updatedEnvelope['config']['tags'], ['party', 'co-op']);
    expect(
      updatedEnvelope['config']['updatedAt'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T.*Z$')),
      reason: 'WebIDE 必须收到可严格解析的 UTC 时间及同一响应 requestId',
    );

    final stale = await fixture
        .jsonRequest('PUT', '/dev/api/gdevelop/projects/$gameId/config', const {
          'schemaVersion': 2,
          'gameType': 'single',
          'minPlayers': 1,
          'maxPlayers': 1,
          'tags': <String>[],
          'expectedRevision': 0,
        });
    expect(stale.statusCode, HttpStatus.conflict);
    final error = jsonDecode(stale.body)['error'];
    expect(error['code'], GDevelopProjectConfigRevisionConflict.code);
    expect(error['currentRevision'], 1);

    final ready = await fixture.get(
      '/dev/api/gdevelop/projects/$gameId/config',
    );
    final readyEnvelope = jsonDecode(ready.body);
    expect(readyEnvelope['config']['gameType'], 'online');
    expect(readyEnvelope['config']['revision'], 1);
    expect(readyEnvelope['requestId'], startsWith('dev-'));
    expect(
      ready.headers['x-playmesh-operation-id'],
      'gdevelop.project.config.get',
    );

    final extraField = await fixture.jsonRequest(
      'PUT',
      '/dev/api/gdevelop/projects/$gameId/config',
      const {
        'schemaVersion': 1,
        'gameType': 'single',
        'expectedRevision': 1,
        'unexpected': true,
      },
    );
    expect(extraField.statusCode, HttpStatus.badRequest);

    await fixture.configFile(gameId).writeAsString('{broken');
    final invalid = await fixture.get(
      '/dev/api/gdevelop/projects/$gameId/config',
    );
    expect(jsonDecode(invalid.body)['status'], 'invalid');
    final rejectedOverwrite = await fixture
        .jsonRequest('PUT', '/dev/api/gdevelop/projects/$gameId/config', const {
          'schemaVersion': 2,
          'gameType': 'single',
          'minPlayers': 1,
          'maxPlayers': 1,
          'tags': <String>[],
          'expectedRevision': 1,
        });
    expect(rejectedOverwrite.statusCode, HttpStatus.conflict);
    expect(
      jsonDecode(rejectedOverwrite.body)['error']['code'],
      GDevelopProjectConfigInvalidState.code,
    );
  });

  test('config 权限独立注册且 gameId 项目隔离', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    await fixture.jsonRequest(
      'PUT',
      '/dev/api/gdevelop/projects/com.example.config-api-a/config',
      const {
        'schemaVersion': 2,
        'gameType': 'online',
        'minPlayers': 2,
        'maxPlayers': 5,
        'tags': <String>[],
        'expectedRevision': 0,
      },
    );

    final other = await fixture.get(
      '/dev/api/gdevelop/projects/com.example.config-api-b/config',
    );
    expect(jsonDecode(other.body)['status'], 'missing');
    final absent = await fixture.get(
      '/dev/api/gdevelop/projects/com.example.config-api-absent/config',
    );
    expect(absent.statusCode, HttpStatus.notFound);

    final openApi = jsonDecode((await fixture.get('/dev/openapi.json')).body);
    final path = openApi['paths']['/dev/api/gdevelop/projects/{gameId}/config'];
    expect(path['get']['x-permission'], 'gdevelop.config.read');
    expect(path['put']['x-permission'], 'gdevelop.config.write');
    expect(path['get']['operationId'], 'gdevelop.project.config.get');
    expect(path['put']['operationId'], 'gdevelop.project.config.put');
  });

  test('项目创建成功后 best-effort 初始化 single，初始化失败仍返回 201', () async {
    final fixture = await _GatewayFixture.create(
      repository: _FailingPutRepository(),
    );
    addTearDown(fixture.close);
    const gameId = 'com.example.config-create-fallback';

    final created = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects',
      const {'gameId': gameId, 'origin': 'create', 'name': 'Create Fallback'},
    );

    expect(created.statusCode, HttpStatus.created);
    expect(jsonDecode(created.body)['configInitialized'], isFalse);
    expect(
      await Directory(
        '${fixture.root.path}${Platform.pathSeparator}$gameId',
      ).exists(),
      isTrue,
    );
    expect(await fixture.configFile(gameId).exists(), isFalse);
  });

  test('DELETE 原子摘除完整源工程；tombstone 清理失败返回 pending', () async {
    const successId = 'com.example.config-delete-success';
    const pendingId = 'com.example.config-delete-pending';
    const failedId = 'com.example.config-delete-failed';
    var failDelete = false;
    var failRename = false;
    final fixture = await _GatewayFixture.create(
      deleteDirectory: (directory) async {
        if (failDelete && directory.path.endsWith(pendingId)) {
          throw FileSystemException('injected cleanup failure', directory.path);
        }
        await directory.delete(recursive: true);
      },
      renameDirectory: (directory, targetPath) async {
        if (failRename && directory.path.endsWith(failedId)) {
          throw FileSystemException('injected rename failure', directory.path);
        }
        return directory.rename(targetPath);
      },
    );
    addTearDown(fixture.close);
    for (final gameId in [successId, pendingId, failedId]) {
      final created = await fixture.jsonRequest(
        'POST',
        '/dev/api/gdevelop/projects',
        {'gameId': gameId, 'origin': 'create', 'name': gameId},
      );
      expect(created.statusCode, HttpStatus.created);
      expect(jsonDecode(created.body)['configInitialized'], isTrue);
      final file = fixture.configFile(gameId);
      final config = jsonDecode(await file.readAsString());
      expect(config['gameType'], 'single');
      expect(config['revision'], 1);
      await File('${file.path}.tmp').writeAsString('stale');
      await File('${file.path}.backup').writeAsString('stale');
    }

    final deleted = await fixture.jsonRequest(
      'DELETE',
      '/dev/api/gdevelop/projects/$successId',
    );
    expect(deleted.statusCode, HttpStatus.ok, reason: deleted.body);
    expect(jsonDecode(deleted.body)['configDeleted'], isTrue);
    for (final suffix in ['', '.tmp', '.backup']) {
      expect(
        await File('${fixture.configFile(successId).path}$suffix').exists(),
        isFalse,
      );
    }

    failDelete = true;
    final pending = await fixture.jsonRequest(
      'DELETE',
      '/dev/api/gdevelop/projects/$pendingId',
    );
    expect(pending.statusCode, HttpStatus.accepted);
    expect(jsonDecode(pending.body)['cleanupPending'], isTrue);
    expect(jsonDecode(pending.body)['projectDeleted'], isTrue);
    expect(jsonDecode(pending.body)['configDeleted'], isTrue);
    expect(await fixture.configFile(pendingId).exists(), isFalse);
    final tombstoneConfig = File(
      '${fixture.root.path}.deletions${Platform.pathSeparator}$pendingId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}'
      'gdevelop${Platform.pathSeparator}project-config.json',
    );
    expect(
      await tombstoneConfig.exists(),
      isTrue,
      reason: 'cleanup pending 时完整源工程应保留在不可见 tombstone 中',
    );

    failRename = true;
    final failed = await fixture.jsonRequest(
      'DELETE',
      '/dev/api/gdevelop/projects/$failedId',
    );
    expect(failed.statusCode, HttpStatus.internalServerError);
    expect(
      await fixture.configFile(failedId).exists(),
      isTrue,
      reason: '原子 rename 未提交时必须完整保留源工程',
    );
  });
}

class _GatewayFixture {
  _GatewayFixture({
    required this.gateway,
    required this.lease,
    required this.root,
    required this.port,
    required this.token,
  });

  final DeveloperWebGateway gateway;
  final GDevelopEditorLeaseTestClient lease;
  final Directory root;
  final int port;
  final String token;

  Map<String, String> get authHeaders => lease.authHeaders;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  File configFile(String gameId) => File(
    '${root.path}${Platform.pathSeparator}$gameId'
    '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
    '${Platform.pathSeparator}project-config.json',
  );

  Future<http.Response> get(String path) =>
      http.get(uri(path), headers: authHeaders);

  Future<http.Response> jsonRequest(
    String method,
    String path, [
    Map<String, Object?> body = const {},
  ]) => switch (method) {
    'POST' => http.post(
      uri(path),
      headers: {...authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
    'PUT' => http.put(
      uri(path),
      headers: {...authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
    'DELETE' => http.delete(uri(path), headers: authHeaders),
    _ => throw ArgumentError.value(method, 'method'),
  };

  Future<void> close() async {
    await lease.release();
    await gateway.close();
    await root.delete(recursive: true);
    final deletions = Directory('${root.path}.deletions');
    if (await deletions.exists()) await deletions.delete(recursive: true);
  }

  static Future<_GatewayFixture> create({
    GDevelopProjectConfigRepository? repository,
    Future<void> Function(Directory directory)? deleteDirectory,
    Future<Directory> Function(Directory directory, String targetPath)?
    renameDirectory,
  }) async {
    final root = await Directory.systemTemp.createTemp('config-gateway-');
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
      deleteDirectory: deleteDirectory,
      renameDirectory: renameDirectory,
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    for (final gameId in const [
      'com.example.config-api-a',
      'com.example.config-api-b',
    ]) {
      await history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        name: gameId,
      );
    }
    final controller = GDevelopProjectConfigController(
      repository ?? GDevelopProjectConfigStore(rootResolver: resolver),
    );
    final port = await _freePort();
    const token = 'gdevelop-config-test-token';
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'gdevelopconfigtest',
      gdevelopHistory: history,
      gdevelopProjectConfig: controller,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    return _GatewayFixture(
      gateway: gateway,
      lease: lease,
      root: root,
      port: port,
      token: token,
    );
  }
}

class _FailingPutRepository implements GDevelopProjectConfigRepository {
  @override
  Future<void> deleteArtifacts(String gameId) async {}

  @override
  Future<GDevelopProjectConfig> put({
    required String gameId,
    required GDevelopProjectGameType gameType,
    int? minPlayers,
    int? maxPlayers,
    List<String>? tags,
    required int expectedRevision,
  }) => throw StateError('Gateway config unavailable');

  @override
  Future<GDevelopProjectConfigReadResult> read(String gameId) async =>
      const GDevelopProjectConfigReadResult.missing();

  @override
  Future<GDevelopProjectConfigEvidence> inspect(String gameId) async =>
      const GDevelopProjectConfigEvidence.missing();

  @override
  Future<GDevelopProjectConfigEvidence> applyPreparedTarget({
    required String gameId,
    required GDevelopProjectConfigEvidence oldEvidence,
    required GDevelopProjectConfigEvidence targetEvidence,
  }) async => targetEvidence;
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
