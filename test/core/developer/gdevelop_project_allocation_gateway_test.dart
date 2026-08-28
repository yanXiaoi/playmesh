import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/foundation/pending_project_commit_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_allocation.dart';
import 'package:playmesh/core/developer/gdevelop_project_allocation_controller.dart';
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
  test('HTTP workspace allocation exact wire、chunked PUT 与全链路幂等', () async {
    final fixture = await _AllocationGatewayFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.workspace('com.example.allocation_gateway');

    final unknown = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      {...workspace.prepareBody, 'unexpected': true},
    );
    expect(unknown.statusCode, HttpStatus.badRequest);
    expect(fixture.errorCode(unknown), 'invalid_request');
    final nestedUnknown = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      {
        ...workspace.prepareBody,
        'workspaceTarget': {
          ...Map<String, Object?>.from(
            workspace.prepareBody['workspaceTarget']! as Map,
          ),
          'unexpected': true,
        },
      },
    );
    expect(nestedUnknown.statusCode, HttpStatus.badRequest);

    final prepared = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      workspace.prepareBody,
    );
    expect(prepared.statusCode, HttpStatus.created);
    final transaction = fixture.transaction(prepared);
    final txId = transaction['txId']! as String;
    expect(transaction['phase'], 'PREPARED');
    expect(
      transaction['workspaceTarget'],
      workspace.prepareBody['workspaceTarget'],
    );
    expect(transaction['resourcePlan'], isEmpty);
    expect(transaction['workspaceProject'], isNull);
    expect(transaction['workspaceFinalization'], isNull);
    expect(transaction.containsKey('browserTarget'), isFalse);
    expect(transaction.containsKey('browserEvidence'), isFalse);
    expect(
      fixture.transaction(
        await fixture.jsonRequest(
          'POST',
          _AllocationGatewayFixture.basePath,
          workspace.prepareBody,
        ),
      )['txId'],
      txId,
    );

    final prematureCommit = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/commit',
    );
    expect(prematureCommit.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(prematureCommit),
      'gdevelop_allocation_unavailable',
    );

    final presence = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/resources/presence',
      {'resources': workspace.resources.reversed.toList()},
    );
    expect(presence.statusCode, HttpStatus.ok);
    expect((fixture.decode(presence)['missing']! as List), hasLength(2));
    expect((fixture.decode(presence)['available']! as List), isEmpty);
    expect(
      (fixture.transaction(presence)['resourcePlan']! as List),
      hasLength(2),
    );

    for (final resource in workspace.resources) {
      final response = await fixture.rawPut(
        '${_AllocationGatewayFixture.basePath}/$txId/resources/'
        '${resource['contentHash']}',
        workspace.resourceBytes[resource['logicalId']]!,
        chunked: true,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(
        Map<String, Object?>.from(
          fixture.decode(response)['resource']! as Map,
        )['hash'],
        resource['contentHash'],
      );
    }
    final available = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/resources/presence',
      {'resources': workspace.resources},
    );
    expect((fixture.decode(available)['missing']! as List), isEmpty);
    expect((fixture.decode(available)['available']! as List), hasLength(2));

    final projectPut = await fixture.rawPut(
      '${_AllocationGatewayFixture.basePath}/$txId/workspace/project-files',
      workspace.projectBytes,
      chunked: true,
    );
    expect(projectPut.statusCode, HttpStatus.ok);
    expect(
      Map<String, Object?>.from(
        fixture.decode(projectPut)['project']! as Map,
      )['contentHash'],
      workspace.finalization['projectFilesHash'],
    );

    final wrongFinalization = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/workspace/finalize',
      {
        ...workspace.finalization,
        'resourceManifestHash': await _sha(Uint8List.fromList([9])),
      },
    );
    expect(wrongFinalization.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(wrongFinalization),
      'gdevelop_allocation_evidence_mismatch',
    );
    expect(
      Map<String, Object?>.from(
        fixture.decode(wrongFinalization)['error']! as Map,
      )['reason'],
      'workspace_finalization_mismatch',
    );
    final finalized = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/workspace/finalize',
      workspace.finalization,
    );
    expect(finalized.statusCode, HttpStatus.ok);
    expect(fixture.transaction(finalized)['phase'], 'WORKSPACE_FINALIZED');
    final finalizedReplay = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/workspace/finalize',
      workspace.finalization,
    );
    expect(
      fixture.transaction(finalizedReplay)['phase'],
      'WORKSPACE_FINALIZED',
    );
    final finalizedReplacement = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      {...workspace.prepareBody, 'idempotencyKey': 'allocation-click-2'},
    );
    expect(finalizedReplacement.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(finalizedReplacement),
      'gdevelop_project_allocation_locked',
    );
    expect(fixture.error(finalizedReplacement)['activeTxId'], txId);
    expect(fixture.error(finalizedReplacement)['phase'], 'WORKSPACE_FINALIZED');

    final committed = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/commit',
    );
    expect(committed.statusCode, HttpStatus.ok);
    expect(fixture.transaction(committed)['phase'], 'COMMITTED');
    expect(await fixture.rootFor(workspace.gameId).exists(), isTrue);
    expect(
      fixture.transaction(
        await fixture.get('${_AllocationGatewayFixture.basePath}/$txId'),
      )['phase'],
      'COMMITTED',
    );
    final removedBrowserRoute = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/browser-prepared',
      const {},
    );
    expect(removedBrowserRoute.statusCode, HttpStatus.notFound);
  });

  test('HTTP prepare 丢 201 后同键找回，不同键替换 PREPARED', () async {
    final fixture = await _AllocationGatewayFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.workspace(
      'com.example.allocation_gateway_lost_prepare',
    );

    final first = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      workspace.prepareBody,
    );
    expect(first.statusCode, HttpStatus.created);
    final firstTxId = fixture.transaction(first)['txId']! as String;

    final replay = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      workspace.prepareBody,
    );
    expect(replay.statusCode, HttpStatus.created);
    expect(fixture.transaction(replay)['txId'], firstTxId);

    final changedTarget = Map<String, Object?>.from(
      workspace.prepareBody['workspaceTarget']! as Map,
    )..['fileIdentifier'] = 'changed-file-identifier';
    final changedSameKey = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      {...workspace.prepareBody, 'workspaceTarget': changedTarget},
    );
    expect(changedSameKey.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(changedSameKey),
      'gdevelop_allocation_idempotency_conflict',
    );

    final replacement = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      {...workspace.prepareBody, 'idempotencyKey': 'allocation-click-new'},
    );
    expect(replacement.statusCode, HttpStatus.created);
    final replacementTxId = fixture.transaction(replacement)['txId']! as String;
    expect(replacementTxId, isNot(firstTxId));
    expect(fixture.transaction(replacement)['phase'], 'PREPARED');

    final oldStatus = await fixture.get(
      '${_AllocationGatewayFixture.basePath}/$firstTxId',
    );
    expect(oldStatus.statusCode, HttpStatus.ok);
    expect(fixture.transaction(oldStatus)['phase'], 'ABORTED');
    expect(await fixture.rootFor(workspace.gameId).exists(), isFalse);
  });

  test('HTTP resource/project/finalize 严格失败不发布半成品', () async {
    final fixture = await _AllocationGatewayFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.workspace(
      'com.example.allocation_gateway_strict',
    );
    final prepared = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      workspace.prepareBody,
    );
    final txId = fixture.transaction(prepared)['txId']! as String;
    final first = workspace.resources.first;

    final duplicate = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/resources/presence',
      {
        'resources': [first, first],
      },
    );
    expect(duplicate.statusCode, HttpStatus.badRequest);
    final unexpected = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/resources/presence',
      {
        'resources': [
          {...first, 'unexpected': true},
        ],
      },
    );
    expect(unexpected.statusCode, HttpStatus.badRequest);

    await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/resources/presence',
      {'resources': workspace.resources},
    );
    final unplannedHash = await _sha(Uint8List.fromList([8, 8]));
    final unplanned = await fixture.rawPut(
      '${_AllocationGatewayFixture.basePath}/$txId/resources/$unplannedHash',
      const [8, 8],
    );
    expect(unplanned.statusCode, HttpStatus.conflict);
    expect(
      fixture.errorCode(unplanned),
      'gdevelop_allocation_resource_not_planned',
    );
    final wrongResource = await fixture.rawPut(
      '${_AllocationGatewayFixture.basePath}/$txId/resources/'
      '${first['contentHash']}',
      List<int>.filled(first['size']! as int, 9),
    );
    expect(wrongResource.statusCode, HttpStatus.conflict);

    final finalizeWithoutProject = await fixture.jsonRequest(
      'POST',
      '${_AllocationGatewayFixture.basePath}/$txId/workspace/finalize',
      workspace.finalization,
    );
    expect(finalizeWithoutProject.statusCode, HttpStatus.conflict);
    expect(await fixture.rootFor(workspace.gameId).exists(), isFalse);
    expect(
      fixture.transaction(
        await fixture.get('${_AllocationGatewayFixture.basePath}/$txId'),
      )['phase'],
      'PREPARED',
    );

    final missing = await fixture.get(
      '${_AllocationGatewayFixture.basePath}/allocation-does-not-exist',
    );
    expect(missing.statusCode, HttpStatus.notFound);
    expect(fixture.errorCode(missing), 'gdevelop_allocation_not_found');
  });

  test('allocation 与统一 create/rekey/restore 项目级锁双向互斥', () async {
    final fixture = await _AllocationGatewayFixture.create();
    addTearDown(fixture.close);
    final workspace = await fixture.workspace(
      'com.example.allocation_reserved',
    );
    final prepared = await fixture.jsonRequest(
      'POST',
      _AllocationGatewayFixture.basePath,
      workspace.prepareBody,
    );
    expect(prepared.statusCode, HttpStatus.created);
    final create = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects',
      {
        'gameId': workspace.gameId,
        'origin': 'create',
        'name': workspace.gameId,
      },
    );
    expect(create.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(create), 'gdevelop_project_allocation_locked');

    const source = 'com.example.allocation-rekey-source';
    final expected = await fixture.seed(source);
    final rekey = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$source/rekey-transactions',
      fixture.rekeyBody(
        newGameId: workspace.gameId,
        expected: expected,
        idempotencyKey: 'rekey-against-allocation',
      ),
    );
    expect(rekey.statusCode, HttpStatus.conflict);
    expect(fixture.errorCode(rekey), 'gdevelop_project_allocation_locked');
  });
}

class _GatewayWorkspace {
  const _GatewayWorkspace({
    required this.gameId,
    required this.prepareBody,
    required this.projectBytes,
    required this.resources,
    required this.resourceBytes,
    required this.finalization,
  });

  final String gameId;
  final Map<String, Object?> prepareBody;
  final Uint8List projectBytes;
  final List<Map<String, Object?>> resources;
  final Map<String, Uint8List> resourceBytes;
  final Map<String, Object?> finalization;
}

class _AllocationGatewayFixture {
  _AllocationGatewayFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.config,
    required this.gateway,
    required this.lease,
    required this.port,
  });

  static const token = 'gdevelop-allocation-gateway-token';
  static const basePath = '/dev/api/gdevelop/project-allocation-transactions';

  final Directory root;
  final FileSystemGDevelopProjectRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopProjectConfigController config;
  final DeveloperWebGateway gateway;
  final GDevelopEditorLeaseTestClient lease;
  final int port;

  static Future<_AllocationGatewayFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-allocation-gateway-',
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
      ),
    );
    var sequence = 0;
    final allocation = GDevelopProjectAllocationController(
      GDevelopProjectAllocationCoordinator(
        rootResolver: resolver,
        history: history,
        mutationLock: restore.mutationLock,
        idFactory: () => 'allocation-http-tx-${sequence++}',
      ),
    );
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'gdevelopallocationgatewaytest',
      gdevelopHistory: history,
      gdevelopProjectConfig: config,
      gdevelopRestoreTransactions: restore,
      gdevelopProjectRekey: rekey,
      gdevelopProjectAllocation: allocation,
      currentAuthor: () => 'Allocation Gateway Test',
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    return _AllocationGatewayFixture(
      root: root,
      resolver: resolver,
      history: history,
      config: config,
      gateway: gateway,
      lease: lease,
      port: port,
    );
  }

  Future<_GatewayWorkspace> workspace(String gameId) async {
    final projectUuid = 'project-$gameId';
    final firstLogical = 'playmesh-local-resource://file-$gameId/first';
    final secondLogical = 'playmesh-local-resource://file-$gameId/second';
    final firstBytes = Uint8List.fromList([1, 2, 3, 4]);
    final secondBytes = Uint8List.fromList([5, 6, 7]);
    final first = <String, Object?>{
      'logicalId': firstLogical,
      'name': 'First',
      'contentHash': await _sha(firstBytes),
      'mime': 'image/png',
      'size': firstBytes.length,
    };
    final second = <String, Object?>{
      'logicalId': secondLogical,
      'name': 'Second',
      'contentHash': await _sha(secondBytes),
      'mime': 'audio/ogg',
      'size': secondBytes.length,
    };
    final officialOrder = [second, first];
    final rootProject = {
      'gdVersion': {'major': 5, 'minor': 6},
      'properties': {
        'name': gameId,
        'packageName': gameId,
        'projectUuid': projectUuid,
        'folderProject': true,
      },
      'resources': {
        'resources': [
          for (final resource in officialOrder)
            {
              'name': resource['name'],
              'file': resource['logicalId'],
              'kind': resource['mime'] == 'image/png' ? 'image' : 'audio',
            },
        ],
      },
      'layouts': [
        {
          '__REFERENCE_TO_SPLIT_OBJECT': true,
          'referenceTo': '/layouts/Main-scene',
        },
      ],
    };
    final projectBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          {'path': 'game.json', 'content': rootProject},
          {
            'path': 'layouts/Main-scene.json',
            'content': {
              'name': 'Main scene',
              'mangledName': 'Main-scene',
              'objects': const [],
              'instances': const [],
            },
          },
        ]),
      ),
    );
    final projectHash = await _sha(projectBytes);
    final manifestHash = await PendingProjectCommitComparator.hashJson(
      officialOrder,
    );
    final finalization = <String, Object?>{
      'packageName': gameId,
      'projectUuid': projectUuid,
      'projectFilesHash': projectHash,
      'projectFilesSize': projectBytes.length,
      'resourceManifestHash': manifestHash,
    };
    return _GatewayWorkspace(
      gameId: gameId,
      prepareBody: {
        'idempotencyKey': 'allocation-click-1',
        'gameId': gameId,
        'origin': 'create',
        'name': gameId,
        'clientId': 'web-ide-1',
        'workspaceTarget': {
          'fileIdentifier': 'file-$gameId',
          'gameId': gameId,
          'packageName': gameId,
          'projectUuid': projectUuid,
          'projectFilesHash': projectHash,
          'resourceManifestHash': manifestHash,
        },
      },
      projectBytes: projectBytes,
      resources: officialOrder,
      resourceBytes: {firstLogical: firstBytes, secondLogical: secondBytes},
      finalization: finalization,
    );
  }

  Map<String, Object?> rekeyBody({
    required String newGameId,
    required Map<String, Object?> expected,
    required String idempotencyKey,
  }) => {
    'idempotencyKey': idempotencyKey,
    'newGameId': newGameId,
    'expectedOldEvidence': expected,
    'browserSource': {
      'fileIdentifier': 'rekey-file-1',
      'projectFilesHash':
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    },
    'browserTarget': {
      'fileIdentifier': 'rekey-file-1',
      'projectFilesHash':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    },
    'clientId': 'web-ide-1',
  };

  Future<Map<String, Object?>> seed(String gameId) async {
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: gameId,
      fileIdentifier: 'seed-${gameId.split('.').last}',
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
    final current = (await history.currentReferenceSnapshot(gameId))!;
    return {
      'history': {
        'revision': current.version.revision,
        'currentContentHash': current.version.contentHash,
        'projectFilesHash': current.projectFiles.contentHash,
        'resourceManifestHash': await PendingProjectCommitComparator.hashJson(
          const [],
        ),
      },
      'config': (await config.inspect(gameId)).toJson(),
    };
  }

  Map<String, Object?> decode(http.Response response) =>
      Map<String, Object?>.from(jsonDecode(response.body) as Map);

  Map<String, Object?> transaction(http.Response response) =>
      Map<String, Object?>.from(decode(response)['transaction']! as Map);

  Map<String, Object?> error(http.Response response) =>
      Map<String, Object?>.from(decode(response)['error']! as Map);

  String? errorCode(http.Response response) =>
      error(response)['code'] as String?;

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

  Future<http.Response> rawPut(
    String path,
    List<int> bytes, {
    bool chunked = false,
  }) async {
    if (!chunked) {
      return http.put(
        uri(path),
        headers: {
          ...lease.authHeaders,
          'Content-Type': 'application/octet-stream',
        },
        body: bytes,
      );
    }
    final client = http.Client();
    try {
      final request = http.StreamedRequest('PUT', uri(path));
      request.headers.addAll({
        ...lease.authHeaders,
        'Content-Type': 'application/octet-stream',
      });
      final responseFuture = client.send(request);
      request.sink.add(bytes.sublist(0, bytes.length ~/ 2));
      request.sink.add(bytes.sublist(bytes.length ~/ 2));
      await request.sink.close();
      return await http.Response.fromStream(await responseFuture);
    } finally {
      client.close();
    }
  }

  Future<void> close() async {
    await lease.release();
    await gateway.close();
    await root.delete(recursive: true);
  }
}

Future<String> _sha(List<int> bytes) async {
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
