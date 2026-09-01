import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_rekey.dart';
import 'package:playmesh/core/developer/gdevelop_project_rekey_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_restore_transaction.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  test('OpenAPI 固定 rekey 七条路由、请求 schema 与分支响应', () async {
    final fixture = await _RekeyGatewayFixture.create();
    addTearDown(fixture.close);

    final openApi = fixture.decode(await fixture.get('/dev/openapi.json'));
    final paths = Map<String, Object?>.from(openApi['paths']! as Map);
    final prepare = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions',
      'post',
    );
    final commit = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/commit',
      'post',
    );
    final status = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}',
      'get',
    );
    final ack = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/ack',
      'post',
    );
    final rollback = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/rollback',
      'post',
    );
    final recover = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/recover',
      'post',
    );
    final abort = _openApiOperation(
      paths,
      '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/abort',
      'post',
    );

    expect(prepare['operationId'], 'gdevelop.project.rekey.prepare');
    expect(commit['operationId'], 'gdevelop.project.rekey.commit');
    expect(status['operationId'], 'gdevelop.project.rekey.status');
    expect(ack['operationId'], 'gdevelop.project.rekey.ack');
    expect(rollback['operationId'], 'gdevelop.project.rekey.rollback');
    expect(recover['operationId'], 'gdevelop.project.rekey.recover');
    expect(abort['operationId'], 'gdevelop.project.rekey.abort');
    for (final operation in [
      prepare,
      commit,
      status,
      ack,
      rollback,
      recover,
      abort,
    ]) {
      expect(operation['x-permission'], 'gdevelop.project.rekey');
    }

    final prepareSchema = _openApiRequestSchema(prepare);
    expect(prepareSchema['additionalProperties'], isFalse);
    expect(
      prepareSchema['required'],
      unorderedEquals([
        'idempotencyKey',
        'newGameId',
        'expectedOldEvidence',
        'browserSource',
        'browserTarget',
      ]),
    );
    final ackSchema = _openApiRequestSchema(ack);
    expect(ackSchema['additionalProperties'], isFalse);
    expect(
      ackSchema['required'],
      unorderedEquals(['fileMetadata', 'packageName', 'projectFilesHash']),
    );
    for (final operation in [commit, recover, abort]) {
      expect(_openApiRequestSchema(operation), {
        'type': 'object',
        'additionalProperties': false,
      });
    }

    expect(_openApiResponses(prepare), contains('409'));
    expect(_openApiResponses(commit), contains('409'));
    expect(_openApiResponses(status), contains('404'));
    expect(_openApiResponses(ack), containsAll(['202', '409']));
    expect(_openApiResponses(rollback), containsAll(['202', '409']));
    expect(_openApiResponses(recover), contains('202'));
    expect(_openApiResponses(recover), isNot(contains('409')));
    expect(_openApiResponses(abort), contains('409'));
    expect(_openApiResponses(abort), isNot(contains('202')));
  });

  test('HTTP rekey 覆盖 prepare 幂等、双 ID 锁、commit、ACK 与 recover', () async {
    final fixture = await _RekeyGatewayFixture.create();
    addTearDown(fixture.close);
    const oldGameId = 'com.example.rekey-gateway-old';
    const newGameId = 'com.example.rekey_gateway_new';
    final expected = await fixture.seed(oldGameId);
    final prepareBody = fixture.prepareBody(
      newGameId: newGameId,
      expected: expected,
    );

    final prepared = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      prepareBody,
    );
    expect(prepared.statusCode, HttpStatus.created);
    final preparedTransaction = fixture.transaction(prepared);
    expect(preparedTransaction['phase'], 'PREPARED');
    final txId = preparedTransaction['txId']! as String;

    final repeated = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      prepareBody,
    );
    expect(repeated.statusCode, HttpStatus.created);
    expect(fixture.transaction(repeated)['txId'], txId);

    final lockedOld = await fixture
        .jsonRequest('PUT', '/dev/api/gdevelop/projects/$oldGameId/config', {
          'schemaVersion': 2,
          'gameType': 'online',
          'minPlayers': 2,
          'maxPlayers': 8,
          'tags': <String>[],
          'expectedRevision': 1,
        });
    expect(lockedOld.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(lockedOld), 'gdevelop_project_mutation_locked');
    final lockedNew = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects',
      {'gameId': newGameId, 'origin': 'create', 'name': 'must stay locked'},
    );
    expect(lockedNew.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(lockedNew), 'gdevelop_project_mutation_locked');
    expect(await fixture.rootFor(newGameId).exists(), isFalse);

    final lockedPreview = await http.post(
      fixture.uri('/dev/api/gdevelop/projects/$oldGameId/preview'),
      headers: {...fixture.headers, 'Content-Type': 'application/octet-stream'},
      body: const [1],
    );
    expect(lockedPreview.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(lockedPreview),
      'gdevelop_project_mutation_locked',
    );
    expect(await fixture.rootFor(newGameId).exists(), isFalse);

    final lockedPublish = await http.post(
      fixture.uri('/dev/api/packages/import'),
      headers: {
        'Authorization': 'Bearer ${_RekeyGatewayFixture.token}',
        'Content-Type': 'application/zip',
      },
      body: _packageZip(newGameId),
    );
    expect(lockedPublish.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(lockedPublish),
      'gdevelop_project_mutation_locked',
    );
    expect(await fixture.rootFor(newGameId).exists(), isFalse);

    final committed = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/commit',
    );
    expect(committed.statusCode, HttpStatus.ok, reason: committed.body);
    expect(fixture.transaction(committed)['phase'], 'NEW_PUBLISHED');
    expect(await fixture.rootFor(oldGameId).exists(), isTrue);
    expect(await fixture.rootFor(newGameId).exists(), isTrue);

    final targetTamper = File(
      '${fixture.rootFor(newGameId).path}${Platform.pathSeparator}external.txt',
    );
    await targetTamper.writeAsString('changed');
    for (var attempt = 0; attempt < 2; attempt++) {
      final targetChanged = await fixture.jsonRequest(
        'POST',
        '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/ack',
        fixture.ackBody(newGameId: newGameId),
      );
      expect(targetChanged.statusCode, HttpStatus.conflict);
      expect(fixture.errorCode(targetChanged), 'gdevelop_rekey_target_changed');
    }
    final stillPublished = await fixture.get(
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId',
    );
    expect(fixture.transaction(stillPublished)['phase'], 'NEW_PUBLISHED');
    final abortPublished = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/abort',
    );
    expect(abortPublished.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(abortPublished),
      'gdevelop_rekey_transaction_unavailable',
    );
    expect(fixture.error(abortPublished)['phase'], 'NEW_PUBLISHED');
    await targetTamper.delete();

    final badAck = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/ack',
      fixture.ackBody(newGameId: newGameId, projectFilesHash: 'c' * 64),
    );
    expect(badAck.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(badAck), 'gdevelop_rekey_ack_mismatch');
    expect(await fixture.rootFor(oldGameId).exists(), isTrue);

    final acknowledged = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/ack',
      fixture.ackBody(newGameId: newGameId),
    );
    expect(acknowledged.statusCode, HttpStatus.ok);
    expect(fixture.transaction(acknowledged)['phase'], 'OLD_CLEANED');
    expect(await fixture.rootFor(oldGameId).exists(), isFalse);
    expect(await fixture.rootFor(newGameId).exists(), isTrue);

    final status = await fixture.get(
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId',
    );
    expect(status.statusCode, HttpStatus.ok);
    expect(fixture.transaction(status)['phase'], 'OLD_CLEANED');
    final recovery = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/recover',
    );
    expect(recovery.statusCode, HttpStatus.ok);
    expect(
      (jsonDecode(recovery.body) as Map<String, Object?>)['transaction'],
      isNull,
    );
  });

  test('HTTP rekey target 冲突稳定返回 project_id_conflict 且可安全 abort', () async {
    final fixture = await _RekeyGatewayFixture.create();
    addTearDown(fixture.close);
    const oldGameId = 'com.example.rekey-gateway-conflict-old';
    const targetGameId = 'com.example.rekey-gateway-conflict-target';
    final expected = await fixture.seed(oldGameId);
    await fixture.seed(targetGameId);

    final conflict = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      fixture.prepareBody(newGameId: targetGameId, expected: expected),
    );
    expect(conflict.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(conflict), 'project_id_conflict');

    const abortTarget = 'com.example.rekey-gateway-abort-target';
    final prepared = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      fixture.prepareBody(
        newGameId: abortTarget,
        expected: expected,
        idempotencyKey: 'abort-click-1',
      ),
    );
    expect(prepared.statusCode, HttpStatus.created);
    final txId = fixture.transaction(prepared)['txId']! as String;
    final aborted = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/abort',
    );
    expect(aborted.statusCode, HttpStatus.ok);
    expect(fixture.transaction(aborted)['phase'], 'ABORTED');

    final unlocked = await fixture
        .jsonRequest('PUT', '/dev/api/gdevelop/projects/$oldGameId/config', {
          'schemaVersion': 2,
          'gameType': 'online',
          'minPlayers': 2,
          'maxPlayers': 8,
          'tags': <String>[],
          'expectedRevision': 1,
        });
    expect(unlocked.statusCode, HttpStatus.ok);
  });

  test('HTTP rollback 两阶段等待浏览器反向 evidence，并可幂等重放 receipt', () async {
    final fixture = await _RekeyGatewayFixture.create();
    addTearDown(fixture.close);
    const oldGameId = 'com.example.rekey-http-rollback-old';
    const newGameId = 'com.example.rekey-http-rollback-new';
    final expected = await fixture.seed(oldGameId);
    final preparedResponse = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      fixture.prepareBody(newGameId: newGameId, expected: expected),
    );
    final txId = fixture.transaction(preparedResponse)['txId']! as String;
    await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/commit',
    );

    final requested = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/rollback',
    );
    expect(requested.statusCode, HttpStatus.accepted);
    expect(fixture.transaction(requested)['phase'], 'ROLLBACK_REQUESTED');
    final requestedAt = fixture.transaction(requested)['updatedAt'];
    final repeatedRequest = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/rollback',
    );
    expect(repeatedRequest.statusCode, HttpStatus.accepted);
    expect(fixture.transaction(repeatedRequest)['updatedAt'], requestedAt);
    expect(await fixture.rootFor(oldGameId).exists(), isTrue);
    expect(await fixture.rootFor(newGameId).exists(), isTrue);

    final invalidEvidence = fixture.rollbackBody(oldGameId: oldGameId)
      ..['projectFilesHash'] = 'c' * 64;
    final rejected = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/rollback',
      invalidEvidence,
    );
    expect(rejected.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(rejected), 'gdevelop_rekey_ack_mismatch');

    final rolledBack = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/rollback',
      fixture.rollbackBody(oldGameId: oldGameId),
    );
    expect(rolledBack.statusCode, HttpStatus.ok);
    expect(fixture.transaction(rolledBack)['phase'], 'ROLLED_BACK');
    expect(await fixture.rootFor(oldGameId).exists(), isTrue);
    expect(await fixture.rootFor(newGameId).exists(), isFalse);

    final replayed = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/rollback',
      fixture.rollbackBody(oldGameId: oldGameId),
    );
    expect(replayed.statusCode, HttpStatus.ok);
    expect(
      fixture.transaction(replayed)['updatedAt'],
      fixture.transaction(rolledBack)['updatedAt'],
    );
  });

  test('HTTP ACK 越过墓碑提交点即返回 OLD_CLEANED，后置清理由 recover 收敛', () async {
    var failOldCleanup = true;
    final fixture = await _RekeyGatewayFixture.create(
      deleteDirectory: (directory) async {
        if (failOldCleanup &&
            _name(directory.path).startsWith('.playmesh-rekey-tombstone-')) {
          throw FileSystemException('busy', directory.path);
        }
        await directory.delete(recursive: true);
      },
    );
    addTearDown(fixture.close);
    const oldGameId = 'com.example.rekey-pending-old';
    const newGameId = 'com.example.rekey-pending-new';
    final expected = await fixture.seed(oldGameId);
    final prepared = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions',
      fixture.prepareBody(newGameId: newGameId, expected: expected),
    );
    final txId = fixture.transaction(prepared)['txId']! as String;
    await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/commit',
    );

    final pendingAck = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/ack',
      fixture.ackBody(newGameId: newGameId),
    );
    expect(pendingAck.statusCode, HttpStatus.accepted);
    expect(fixture.transaction(pendingAck)['phase'], 'OLD_CLEANED');
    expect(fixture.transaction(pendingAck)['cleanupPending'], isTrue);
    expect(
      fixture.transaction(pendingAck)['cleanupError'],
      'tombstone_cleanup_pending',
    );
    expect(await fixture.rootFor(oldGameId).exists(), isFalse);
    expect(await fixture.rootFor(newGameId).exists(), isTrue);

    final status = await fixture.get(
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId',
    );
    expect(status.statusCode, HttpStatus.ok);
    expect(fixture.transaction(status)['phase'], 'OLD_CLEANED');
    final pendingRecovery = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/recover',
    );
    expect(pendingRecovery.statusCode, HttpStatus.accepted);
    expect(fixture.decode(pendingRecovery)['transaction'], isNull);
    expect((fixture.decode(pendingRecovery)['cleanupPendingTxIds']! as List), [
      txId,
    ]);

    failOldCleanup = false;
    final recovered = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/recover',
    );
    expect(recovered.statusCode, HttpStatus.ok);
    expect(fixture.decode(recovered)['transaction'], isNull);
    expect(fixture.decode(recovered)['cleanupPendingTxIds'], isEmpty);
    expect(await fixture.rootFor(oldGameId).exists(), isFalse);
    final ackReplay = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$oldGameId/rekey-transactions/$txId/ack',
      fixture.ackBody(newGameId: newGameId),
    );
    expect(ackReplay.statusCode, HttpStatus.ok);
    expect(fixture.transaction(ackReplay)['phase'], 'OLD_CLEANED');
  });
}

Map<String, Object?> _openApiOperation(
  Map<String, Object?> paths,
  String path,
  String method,
) => Map<String, Object?>.from(
  (Map<String, Object?>.from(paths[path]! as Map))[method]! as Map,
);

Map<String, Object?> _openApiRequestSchema(Map<String, Object?> operation) {
  final requestBody = Map<String, Object?>.from(
    operation['requestBody']! as Map,
  );
  final content = Map<String, Object?>.from(requestBody['content']! as Map);
  final json = Map<String, Object?>.from(content['application/json']! as Map);
  return Map<String, Object?>.from(json['schema']! as Map);
}

Set<String> _openApiResponses(Map<String, Object?> operation) =>
    Map<String, Object?>.from(operation['responses']! as Map).keys.toSet();

class _RekeyGatewayFixture {
  _RekeyGatewayFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.config,
    required this.gateway,
    required this.lease,
    required this.port,
  });

  static const token = 'gdevelop-rekey-gateway-token';
  static const browserHash =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  static const browserSourceHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  final Directory root;
  final FileSystemGDevelopProjectRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController config;
  final DeveloperWebGateway gateway;
  final GDevelopEditorLeaseTestClient lease;
  final int port;

  static Future<_RekeyGatewayFixture> create({
    GDevelopProjectRekeyDirectoryDelete? deleteDirectory,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-rekey-gateway-',
    );
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    final config = GDevelopProjectConfigController(
      GDevelopProjectConfigStore(rootResolver: resolver),
    );
    final restore = GDevelopRestoreTransactionCoordinator(
      history: history,
      projectConfig: config,
      rootResolver: resolver,
    );
    final rekey = GDevelopProjectRekeyController(
      GDevelopProjectRekeyCoordinator(
        history: history,
        projectConfig: config,
        restoreTransactions: restore,
        rootResolver: resolver,
        deleteDirectory: deleteDirectory,
      ),
    );
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'gdeveloprekeygatewaytest',
      gdevelopHistory: history,
      gdevelopProjectConfig: config,
      gdevelopRestoreTransactions: restore,
      gdevelopProjectRekey: rekey,
      gdevelopAiFeaturePolicy: const GDevelopAiFeaturePolicy.testOverride(
        enabled: true,
      ),
      currentAuthor: () => 'Rekey Gateway Test',
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    return _RekeyGatewayFixture(
      root: root,
      resolver: resolver,
      history: history,
      config: config,
      gateway: gateway,
      lease: lease,
      port: port,
    );
  }

  Future<Map<String, Object?>> seed(String gameId) async {
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: gameId,
      fileIdentifier: 'fixture-${gameId.split('.').last}',
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
            'layouts': [
              {
                '__REFERENCE_TO_SPLIT_OBJECT': true,
                'referenceTo': '/layouts/Main-scene',
              },
            ],
          },
        ),
        const GDevelopProjectFile(
          path: 'layouts/Main-scene.json',
          content: {
            'name': 'Main scene',
            'mangledName': 'Main-scene',
            'objects': [],
            'instances': [],
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
    return {
      'history': {
        'revision': current.version.revision,
        'currentContentHash': current.version.contentHash,
        'projectFilesHash': current.projectFiles.contentHash,
        'resourceManifestHash': await _hashJson(
          current.resources.map((resource) => resource.toJson()).toList(),
        ),
      },
      'config': (await config.inspect(gameId)).toJson(),
    };
  }

  Map<String, Object?> prepareBody({
    required String newGameId,
    required Map<String, Object?> expected,
    String idempotencyKey = 'rekey-gateway-click-1',
  }) => {
    'idempotencyKey': idempotencyKey,
    'newGameId': newGameId,
    'expectedOldEvidence': expected,
    'browserSource': {
      'fileIdentifier': 'web-file-1',
      'projectFilesHash': browserSourceHash,
    },
    'browserTarget': {
      'fileIdentifier': 'web-file-1',
      'projectFilesHash': browserHash,
    },
    'clientId': 'web-ide-1',
  };

  Map<String, Object?> ackBody({
    required String newGameId,
    String projectFilesHash = browserHash,
  }) => {
    'fileMetadata': {'fileIdentifier': 'web-file-1', 'gameId': newGameId},
    'packageName': newGameId,
    'projectFilesHash': projectFilesHash,
  };

  Map<String, Object?> rollbackBody({required String oldGameId}) => {
    'fileMetadata': {'fileIdentifier': 'web-file-1', 'gameId': oldGameId},
    'packageName': oldGameId,
    'projectFilesHash': browserSourceHash,
  };

  Map<String, Object?> transaction(http.Response response) =>
      Map<String, Object?>.from(
        (jsonDecode(response.body) as Map)['transaction']! as Map,
      );

  Map<String, Object?> decode(http.Response response) =>
      Map<String, Object?>.from(jsonDecode(response.body) as Map);

  String? errorCode(http.Response response) =>
      ((jsonDecode(response.body) as Map)['error'] as Map?)?['code'] as String?;

  Map<String, Object?> error(http.Response response) =>
      Map<String, Object?>.from(decode(response)['error']! as Map);

  Directory rootFor(String gameId) =>
      Directory('${root.path}${Platform.pathSeparator}$gameId');

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Map<String, String> get headers => {
    ...lease.authHeaders,
    'Content-Type': 'application/json',
  };

  Future<http.Response> get(String path) =>
      http.get(uri(path), headers: headers);

  Future<http.Response> jsonRequest(
    String method,
    String path, [
    Map<String, Object?> body = const {},
  ]) => switch (method) {
    'POST' => http.post(uri(path), headers: headers, body: jsonEncode(body)),
    'PUT' => http.put(uri(path), headers: headers, body: jsonEncode(body)),
    _ => throw ArgumentError.value(method, 'method'),
  };

  Future<void> close() async {
    await lease.release();
    await gateway.close();
    await root.delete(recursive: true);
  }
}

Future<String> _hashJson(Object? value) async {
  return _hashBytes(utf8.encode(jsonEncode(value)));
}

Future<String> _hashBytes(List<int> value) async {
  final digest = await Sha256().hash(value);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

List<int> _packageZip(String gameId) {
  final archive = Archive();
  final manifest = utf8.encode(
    jsonEncode({
      'id': gameId,
      'name': 'Rekey Publish Lock Fixture',
      'author': 'Browser Placeholder',
      'lastModifiedAt': 0,
      'remarks': '',
      'version': '1.0.0',
      'sdkVersion': '4.1.0',
      'appSdkVersion': '3.3.0',
      'orientation': 'landscape',
      'modes': ['solo'],
      'displayModes': ['multi_screen'],
      'players': {'min': 1, 'max': 1},
      'entries': {'game': 'index.html'},
      'tags': <String>[],
    }),
  );
  final index = utf8.encode('<!doctype html><title>Must not publish</title>');
  archive
    ..addFile(ArchiveFile('main.json', manifest.length, manifest))
    ..addFile(ArchiveFile('app/index.html', index.length, index));
  return ZipEncoder().encode(archive)!;
}

String _name(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
