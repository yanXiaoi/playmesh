import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/foundation/local_version_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  test('history invalid_request 返回完整结构化诊断且不吞掉校验原因', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.project-a';
    final response = await fixture.jsonRequest(
      'PUT',
      '/dev/api/gdevelop/projects/$gameId/history/current',
      {
        'baseRevision': 0,
        'source': 'user',
        'projectFiles': _projectFiles({
          'properties': {'packageName': gameId},
        }),
        'resources': [
          {
            'logicalId': 'playmesh-local-resource://fixture/shared.png',
            'name': 'primary.png',
            'contentHash': 'a' * 64,
            'mime': 'image/png',
            'size': 1,
          },
          {
            'logicalId': 'playmesh-local-resource://fixture/shared.png',
            'name': 'alias.png',
            'contentHash': 'b' * 64,
            'mime': 'image/png',
            'size': 1,
          },
        ],
      },
    );
    expect(response.statusCode, HttpStatus.badRequest);
    final envelope = jsonDecode(response.body) as Map;
    final requestId = envelope['requestId'] as String;
    final error = envelope['error'] as Map;
    expect(error['stage'], 'gateway_response');
    expect(error['operation'], 'gdevelop.history.current.put');
    expect(error['status'], HttpStatus.badRequest);
    expect(error['code'], 'invalid_request');
    expect(
      error['reason'],
      'GDevelop resources[1].logicalId 与 resources[0].logicalId 重复',
    );
    expect(error['requestId'], requestId);
    expect(error['type'], 'DeveloperGatewayError');
  });

  test('history current PUT 在 JSON 解析和资源字段早期失败时仍返回脱敏诊断', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const path =
        '/dev/api/gdevelop/projects/com.example.project-a/history/current';

    final invalidMime = await fixture.jsonRequest('PUT', path, {
      'baseRevision': 0,
      'source': 'user',
      'projectFiles': _projectFiles(const <String, Object?>{}),
      'resources': [
        {
          'logicalId': 'playmesh-local-resource://fixture/unsafe.bin',
          'contentHash': 'a' * 64,
          'mime': 'application/x-not-allowed',
          'size': 1,
        },
      ],
    });
    expect(invalidMime.statusCode, HttpStatus.badRequest);
    final mimeEnvelope = jsonDecode(invalidMime.body) as Map;
    final mimeError = mimeEnvelope['error'] as Map;
    expect(mimeError['operation'], 'gdevelop.history.current.put');
    expect(mimeError['stage'], 'gateway_response');
    expect(mimeError['reason'], 'GDevelop resources[0]: GDevelop 资源 mime 无效');
    expect(mimeError['requestId'], mimeEnvelope['requestId']);
    expect(mimeError['type'], 'DeveloperGatewayError');

    final invalidJson = await http.put(
      fixture.uri(path),
      headers: {...fixture.authHeaders, 'Content-Type': 'application/json'},
      body: '{"baseRevision":',
    );
    expect(invalidJson.statusCode, HttpStatus.badRequest);
    final jsonEnvelope = jsonDecode(invalidJson.body) as Map;
    final jsonError = jsonEnvelope['error'] as Map;
    expect(jsonError['operation'], 'gdevelop.history.current.put');
    expect(jsonError['stage'], 'gateway_response');
    expect(jsonError['status'], HttpStatus.badRequest);
    expect(jsonError['code'], 'invalid_request');
    expect(jsonError['reason'], isNot('invalid_request'));
    expect(jsonError['requestId'], jsonEnvelope['requestId']);
    expect(jsonError['type'], 'DeveloperGatewayError');
  });

  test('历史 HTTP 合同拒绝已删除的 AI source 与 ai_turn reason', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.project-a';
    const snapshotPath = '/dev/api/gdevelop/projects/$gameId/history/snapshots';
    const restorePath =
        '/dev/api/gdevelop/projects/$gameId/history/restore-transactions';

    void expectInvalidRequest(
      http.Response response, {
      required String operation,
      required String field,
    }) {
      expect(response.statusCode, HttpStatus.badRequest);
      final envelope = jsonDecode(response.body) as Map;
      final error = envelope['error'] as Map;
      expect(error['operation'], operation);
      expect(error['code'], 'invalid_request');
      expect(error['reason'], contains(field));
    }

    final legacySnapshotSource = await fixture
        .jsonRequest('POST', snapshotPath, {
          'baseRevision': 0,
          'reason': 'explicit_save',
          'source': 'ai',
          'projectFiles': _projectFiles(<String, Object?>{}),
          'resources': <Object?>[],
        });
    expectInvalidRequest(
      legacySnapshotSource,
      operation: 'gdevelop.history.snapshot',
      field: 'source',
    );

    final legacySnapshotReason = await fixture
        .jsonRequest('POST', snapshotPath, {
          'baseRevision': 0,
          'reason': 'ai_turn',
          'source': 'user',
          'projectFiles': _projectFiles(<String, Object?>{}),
          'resources': <Object?>[],
        });
    expectInvalidRequest(
      legacySnapshotReason,
      operation: 'gdevelop.history.snapshot',
      field: 'reason',
    );

    final legacyRestoreSource = await fixture.jsonRequest('POST', restorePath, {
      'idempotencyKey': 'legacy-ai-restore',
      'baseRevision': 1,
      'targetRevision': 1,
      'source': 'ai',
      'currentProjectFiles': _projectFiles(<String, Object?>{}),
      'currentResources': <Object?>[],
    });
    expectInvalidRequest(
      legacyRestoreSource,
      operation: 'gdevelop.history.restore.prepare',
      field: 'source',
    );

    final history = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history'),
      headers: fixture.authHeaders,
    );
    expect(history.statusCode, HttpStatus.ok);
    expect(jsonDecode(history.body)['versions'], isEmpty);
  });

  test('GET 项目列表返回 App 托管 identity 与轻量 current evidence', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const currentGameId = 'com.example.project-a';
    final snapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$currentGameId/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'authoritative current'}),
        'resources': [],
      },
    );
    expect(snapshot.statusCode, HttpStatus.ok);

    final response = await http.get(
      fixture.uri('/dev/api/gdevelop/projects'),
      headers: fixture.authHeaders,
    );
    expect(response.statusCode, HttpStatus.ok);
    final envelope = Map<String, Object?>.from(
      jsonDecode(response.body) as Map,
    );
    expect(envelope['requestId'], isA<String>());
    expect(envelope['activeGameId'], currentGameId);
    expect(envelope['diagnostics'], isEmpty);
    final projects = (envelope['projects']! as List)
        .map((raw) => Map<String, Object?>.from(raw as Map))
        .toList();
    expect(projects.map((project) => (project['identity'] as Map)['gameId']), [
      'com.example.presence-project',
      'com.example.conflict-project',
      'com.example.project-b',
      'com.example.project-a',
    ]);
    final current = projects.singleWhere(
      (project) => (project['identity'] as Map)['gameId'] == currentGameId,
    );
    final identity = Map<String, Object?>.from(current['identity']! as Map);
    expect(identity['schemaVersion'], 1);
    expect(identity['kind'], 'gdevelop');
    expect(identity['name'], currentGameId);
    expect(identity['fileIdentifiers'], ['fixture-project-a']);
    expect(identity, isNot(contains('root')));
    final evidence = Map<String, Object?>.from(
      current['currentEvidence']! as Map,
    );
    expect(evidence['revision'], 1);
    expect(
      (evidence['projectFiles'] as Map)['contentHash'],
      matches(r'^[a-f0-9]{64}$'),
    );
    expect(evidence['resources'], isEmpty);
    final withoutCurrent = projects.singleWhere(
      (project) =>
          (project['identity'] as Map)['gameId'] == 'com.example.project-b',
    );
    expect(withoutCurrent['currentEvidence'], isNull);
  });

  test('项目列表按复用的 updatedAt 倒序且仅打开或元数据更新改变顺序', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);

    Future<List<Map<String, Object?>>> listProjects() async {
      final response = await http.get(
        fixture.uri('/dev/api/gdevelop/projects'),
        headers: fixture.authHeaders,
      );
      expect(response.statusCode, HttpStatus.ok);
      final envelope = Map<String, Object?>.from(
        jsonDecode(response.body) as Map,
      );
      return (envelope['projects']! as List)
          .map((raw) => Map<String, Object?>.from(raw as Map))
          .toList(growable: false);
    }

    List<String> gameIds(List<Map<String, Object?>> projects) => projects
        .map((project) => (project['identity'] as Map)['gameId']! as String)
        .toList(growable: false);

    final initial = await listProjects();
    expect(gameIds(initial), [
      'com.example.presence-project',
      'com.example.conflict-project',
      'com.example.project-b',
      'com.example.project-a',
    ]);

    final opened = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.project-a/open',
      const {'fileIdentifier': 'fixture-project-a'},
    );
    expect(opened.statusCode, HttpStatus.ok);
    final afterOpen = await listProjects();
    expect(gameIds(afterOpen).first, 'com.example.project-a');
    final openedAt =
        ((afterOpen.first['identity'] as Map)['updatedAt']! as String);

    final afterRefresh = await listProjects();
    expect(gameIds(afterRefresh), gameIds(afterOpen));
    expect(
      (afterRefresh.first['identity'] as Map)['updatedAt'],
      openedAt,
      reason: '仅刷新列表不得改变排序时间',
    );

    final renamed = await fixture.jsonRequest(
      'PATCH',
      '/dev/api/gdevelop/projects/com.example.project-b',
      const {'name': 'Recently changed'},
    );
    expect(renamed.statusCode, HttpStatus.ok);
    final afterRename = await listProjects();
    expect(gameIds(afterRename).first, 'com.example.project-b');
  });

  test('GET 项目列表隔离坏根和坏 current，并返回稳定且不泄露路径的诊断', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const damagedCurrentGameId = 'com.example.project-b';
    final snapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$damagedCurrentGameId/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'will be damaged'}),
        'resources': [],
      },
    );
    expect(snapshot.statusCode, HttpStatus.ok);

    final damagedState = File(
      '${fixture.root.path}${Platform.pathSeparator}$damagedCurrentGameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}source${Platform.pathSeparator}current'
      '${Platform.pathSeparator}manifest.json',
    );
    await damagedState.writeAsString('{invalid current');

    final invalidRoot = Directory(
      '${fixture.root.path}${Platform.pathSeparator}zzz-invalid-metadata',
    );
    final invalidMetadata = File(
      '${invalidRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    await invalidMetadata.parent.create(recursive: true);
    await invalidMetadata.writeAsString('{invalid metadata');

    final mismatchedRoot = Directory(
      '${fixture.root.path}${Platform.pathSeparator}zzz-root-mismatch',
    );
    final mismatchedMetadata = File(
      '${mismatchedRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );
    await mismatchedMetadata.parent.create(recursive: true);
    await File(
      '${fixture.root.path}${Platform.pathSeparator}com.example.project-a'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}project.json',
    ).copy(mismatchedMetadata.path);

    final response = await http.get(
      fixture.uri('/dev/api/gdevelop/projects'),
      headers: fixture.authHeaders,
    );
    expect(response.statusCode, HttpStatus.ok);
    final envelope = Map<String, Object?>.from(
      jsonDecode(response.body) as Map,
    );
    final projects = (envelope['projects']! as List)
        .map((raw) => Map<String, Object?>.from(raw as Map))
        .toList();
    expect(projects.map((project) => (project['identity'] as Map)['gameId']), [
      'com.example.presence-project',
      'com.example.conflict-project',
      damagedCurrentGameId,
      'com.example.project-a',
    ]);
    final damagedProject = projects.singleWhere(
      (project) =>
          (project['identity'] as Map)['gameId'] == damagedCurrentGameId,
    );
    expect(damagedProject['currentEvidence'], isNull);

    final diagnostics = (envelope['diagnostics']! as List)
        .map((raw) => Map<String, Object?>.from(raw as Map))
        .toList();
    expect(
      diagnostics.map(
        (diagnostic) => '${diagnostic['entry']}:${diagnostic['code']}',
      ),
      [
        '$damagedCurrentGameId:gdevelop_current_evidence_unavailable',
        'zzz-invalid-metadata:project_metadata_invalid',
        'zzz-root-mismatch:project_root_identity_mismatch',
      ],
    );
    expect(
      diagnostics.every(
        (diagnostic) => diagnostic.keys.toSet().difference({
          'code',
          'entry',
          'gameId',
          'messageKey',
        }).isEmpty,
      ),
      isTrue,
    );
    expect(response.body, isNot(contains(fixture.root.path)));
  });

  test('项目生命周期按 gameId 绑定根、文件标识和独立历史', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.playmesh.game.gfixtureone';
    const copiedGameId = 'com.playmesh.game.gfixturetwo';

    final created = await fixture
        .jsonRequest('POST', '/dev/api/gdevelop/projects', const {
          'gameId': gameId,
          'origin': 'create',
          'fileIdentifier': 'visual-file-a',
          'name': 'Visual Fixture',
        });
    expect(created.statusCode, HttpStatus.created);
    final createdProject = jsonDecode(created.body)['project'] as Map;
    expect(createdProject['gameId'], gameId);
    expect(createdProject['created'], isTrue);
    expect(createdProject, isNot(contains('root')));
    final projectRoot = Directory(
      '${fixture.root.path}${Platform.pathSeparator}$gameId',
    );
    await File(
      '${projectRoot.path}${Platform.pathSeparator}source-cache.bin',
    ).writeAsBytes([1, 2, 3]);
    final publishedRoot = Directory(
      '${fixture.root.path}.published${Platform.pathSeparator}$gameId',
    );
    await publishedRoot.create(recursive: true);
    final publishedSentinel = File(
      '${publishedRoot.path}${Platform.pathSeparator}game.json',
    );
    await publishedSentinel.writeAsString('{"published":true}');
    addTearDown(() async {
      final root = Directory('${fixture.root.path}.published');
      if (await root.exists()) await root.delete(recursive: true);
    });
    expect(
      await File(
        '${projectRoot.path}${Platform.pathSeparator}.playmesh'
        '${Platform.pathSeparator}project.json',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${projectRoot.path}${Platform.pathSeparator}main.json',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${projectRoot.path}${Platform.pathSeparator}game.json',
      ).exists(),
      isFalse,
    );

    final duplicateConflict = await fixture
        .jsonRequest('POST', '/dev/api/gdevelop/projects', const {
          'gameId': gameId,
          'origin': 'duplicate',
          'fileIdentifier': 'visual-copy-conflict',
          'name': 'Must Not Overwrite',
        });
    expect(duplicateConflict.statusCode, HttpStatus.conflict);
    expect(
      jsonDecode(duplicateConflict.body)['error']['code'],
      'project_id_conflict',
    );

    final opened = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$gameId/open',
      const {'fileIdentifier': 'visual-file-b'},
    );
    expect(opened.statusCode, HttpStatus.ok);
    expect(jsonDecode(opened.body)['project']['fileIdentifiers'], [
      'visual-file-a',
      'visual-file-b',
    ]);
    final renamed = await fixture.jsonRequest(
      'PATCH',
      '/dev/api/gdevelop/projects/$gameId',
      const {'name': 'Visual Renamed'},
    );
    expect(renamed.statusCode, HttpStatus.ok);
    expect(jsonDecode(renamed.body)['project']['name'], 'Visual Renamed');

    final snapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$gameId/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({
          'name': 'same game across file identifiers',
        }),
        'resources': [],
      },
    );
    expect(snapshot.statusCode, HttpStatus.ok);
    final snapshotJson = jsonDecode(snapshot.body) as Map<String, Object?>;
    expect(snapshotJson['gameId'], gameId);
    expect(snapshotJson, isNot(contains('projectId')));
    final history = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history'),
      headers: fixture.authHeaders,
    );
    final historyJson = jsonDecode(history.body) as Map<String, Object?>;
    expect(historyJson['gameId'], gameId);
    expect(historyJson, isNot(contains('projectId')));
    expect(historyJson['versions'], hasLength(1));
    expect((historyJson['versions'] as List).single['gameId'], gameId);
    expect((historyJson['versions'] as List).single['changeSummary'], {
      'added': 1,
      'modified': 0,
      'deleted': 0,
    });
    expect(snapshotJson['version'], isNot(contains('changeSummary')));
    expect(
      historyJson['versions'] as List,
      everyElement(isNot(contains('projectId'))),
    );

    final copied = await fixture
        .jsonRequest('POST', '/dev/api/gdevelop/projects', const {
          'gameId': copiedGameId,
          'origin': 'duplicate',
          'fileIdentifier': 'visual-copy-a',
          'name': 'Visual Copy',
        });
    expect(copied.statusCode, HttpStatus.created);
    final copiedHistory = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$copiedGameId/history'),
      headers: fixture.authHeaders,
    );
    expect(jsonDecode(copiedHistory.body)['versions'], isEmpty);

    final deleted = await fixture.jsonRequest(
      'DELETE',
      '/dev/api/gdevelop/projects/$gameId',
    );
    expect(deleted.statusCode, HttpStatus.ok, reason: deleted.body);
    expect(jsonDecode(deleted.body)['gameId'], gameId);
    expect(jsonDecode(deleted.body)['projectDeleted'], isTrue);
    expect(jsonDecode(deleted.body)['historyDeleted'], isTrue);
    expect(await projectRoot.exists(), isFalse);
    expect(
      await publishedSentinel.exists(),
      isTrue,
      reason: '删除 GDevelop 源工程绝不能删除已发布 Playmesh 游戏包',
    );
    expect(
      await Directory(
        '${fixture.root.path}${Platform.pathSeparator}$copiedGameId',
      ).exists(),
      isTrue,
      reason: '删除一个可视化项目不能影响另一个项目',
    );
  });

  test('DELETE history 只清版本，current 与项目打开能力保持', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.project-a';
    final saved = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$gameId/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'independent current'}),
        'resources': [],
      },
    );
    expect(saved.statusCode, HttpStatus.ok, reason: saved.body);

    final cleared = await fixture.jsonRequest(
      'DELETE',
      '/dev/api/gdevelop/projects/$gameId/history',
    );
    expect(cleared.statusCode, HttpStatus.ok, reason: cleared.body);
    expect(jsonDecode(cleared.body)['historyDeleted'], isTrue);
    expect(jsonDecode(cleared.body)['currentPreserved'], isTrue);

    final history = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history'),
      headers: fixture.authHeaders,
    );
    expect(jsonDecode(history.body)['versions'], isEmpty);
    final current = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history/current'),
      headers: fixture.authHeaders,
    );
    expect(_rootContent(jsonDecode(current.body)['current']['projectFiles']), {
      'name': 'independent current',
    });

    final projects = await http.get(
      fixture.uri('/dev/api/gdevelop/projects'),
      headers: fixture.authHeaders,
    );
    final project = (jsonDecode(projects.body)['projects'] as List)
        .cast<Map>()
        .singleWhere((item) => item['identity']['gameId'] == gameId);
    expect(project['currentEvidence'], isNotNull);
  });

  test('normal open HTTP 只校验资源 URL 路径并原样中转 current', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.project-a';
    final bytes = Uint8List.fromList([7, 6, 5, 4]);
    final hash = await _hash(bytes);
    final upload = await http.put(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history/resources/$hash'),
      headers: fixture.binaryHeaders,
      body: bytes,
    );
    expect(upload.statusCode, HttpStatus.ok, reason: upload.body);
    final snapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$gameId/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles(const {'name': 'before raw relay'}),
        'resources': [_resourceJson(hash, bytes.length)],
      },
    );
    expect(snapshot.statusCode, HttpStatus.ok, reason: snapshot.body);

    final currentRoot = Directory(
      '${fixture.root.path}${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}source${Platform.pathSeparator}current',
    );
    final manifestFile = File(
      '${currentRoot.path}${Platform.pathSeparator}manifest.json',
    );
    final manifest =
        Map<String, Object?>.from(
            jsonDecode(await manifestFile.readAsString()) as Map,
          )
          ..['schemaVersion'] = 'stored-schema'
          ..['gameId'] = '../stored-game-id'
          ..['revision'] = {'stored': 'revision'}
          ..['reason'] = ['stored-reason']
          ..['source'] = false
          ..['contentHash'] = {'stored': 'content-hash'}
          ..['contentBytes'] = 'stored-content-bytes'
          ..['projectFilesHash'] = 'not-a-hash'
          ..['projectFilesSize'] = 'stored-project-bytes'
          ..['playmeshProjectConfig'] = 'stored-config'
          ..['resources'] = [
            {
              'logicalId': '../stored-logical-id',
              'contentHash': 'not-a-hash',
              'mime': 'not a mime',
              'size': 'stored-size',
            },
          ];
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
    await File(
      '${currentRoot.path}${Platform.pathSeparator}project'
      '${Platform.pathSeparator}game.json',
    ).writeAsString('["stored","project"]', flush: true);

    final currentResponse = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/$gameId/history/current'),
      headers: fixture.authHeaders,
    );
    expect(
      currentResponse.statusCode,
      HttpStatus.ok,
      reason: currentResponse.body,
    );
    final currentEnvelope = jsonDecode(currentResponse.body) as Map;
    final current = currentEnvelope['current'] as Map;
    final version = current['version'] as Map;
    expect(version['gameId'], '../stored-game-id');
    expect(version['revision'], {'stored': 'revision'});
    expect(version['reason'], ['stored-reason']);
    expect(version['source'], isFalse);
    expect(version['contentHash'], {'stored': 'content-hash'});
    expect(version['contentBytes'], 'stored-content-bytes');
    expect(_rootContent(current['projectFiles']), ['stored', 'project']);
    expect(current['playmeshProjectConfig'], 'stored-config');
    expect((current['resources'] as List).single, {
      'logicalId': '../stored-logical-id',
      'contentHash': 'not-a-hash',
      'mime': 'not a mime',
      'size': 'stored-size',
    });

    final unpinnedHash = '0' * 64;
    const unpinnedBytes = [31, 32, 33];
    await File(
      '${currentRoot.path}${Platform.pathSeparator}resources'
      '${Platform.pathSeparator}$unpinnedHash.blob',
    ).writeAsBytes(unpinnedBytes, flush: true);
    final resourceResponse = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/$gameId/history/resources/$unpinnedHash',
      ),
      headers: fixture.authHeaders,
    );
    expect(resourceResponse.statusCode, HttpStatus.ok);
    expect(resourceResponse.bodyBytes, unpinnedBytes);
    expect(
      resourceResponse.headers[HttpHeaders.contentTypeHeader],
      'application/octet-stream',
    );
    expect(
      resourceResponse.headers[HttpHeaders.cacheControlHeader],
      'no-store',
    );
    expect(resourceResponse.headers[HttpHeaders.etagHeader], isNull);

    final unsafe = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/$gameId/history/resources/not-a-hash',
      ),
      headers: fixture.authHeaders,
    );
    expect(unsafe.statusCode, HttpStatus.badRequest);
  });

  test('真实 HTTP 完成资源暂存、快照、读取与授权隔离', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    final bytes = Uint8List.fromList([9, 8, 7, 6]);
    final hash = await _hash(bytes);

    final upload = await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/resources/$hash',
      ),
      headers: fixture.binaryHeaders,
      body: bytes,
    );
    expect(upload.statusCode, HttpStatus.ok);

    final snapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.project-a/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'HTTP project'}),
        'resources': [_resourceJson(hash, bytes.length)],
      },
    );
    expect(snapshot.statusCode, HttpStatus.ok);
    expect(jsonDecode(snapshot.body)['version']['revision'], 1);

    final resource = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/resources/$hash',
      ),
      headers: fixture.authHeaders,
    );
    expect(resource.statusCode, HttpStatus.ok);
    expect(resource.bodyBytes, bytes);

    final nextBytes = Uint8List.fromList([1, 3, 5, 7, 9]);
    final nextHash = await _hash(nextBytes);
    final nextUpload = await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/resources/$nextHash',
      ),
      headers: fixture.binaryHeaders,
      body: nextBytes,
    );
    expect(nextUpload.statusCode, HttpStatus.ok);
    final nextSnapshot = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.project-a/history/snapshots',
      {
        'baseRevision': 1,
        'reason': 'autosave',
        'source': 'system',
        'projectFiles': _projectFiles({'name': 'HTTP project changed'}),
        'resources': [
          {
            ..._resourceJson(nextHash, nextBytes.length),
            'mime': 'application/json',
          },
        ],
      },
    );
    expect(nextSnapshot.statusCode, HttpStatus.ok);
    final nextSnapshotBody = jsonDecode(nextSnapshot.body) as Map;
    expect(nextSnapshotBody['version']['revision'], 2);
    expect((nextSnapshotBody['version'] as Map)['reason'], 'autosave');
    expect((nextSnapshotBody['version'] as Map)['source'], 'system');

    final diff = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/diff?fromRevision=1&toRevision=2',
      ),
      headers: fixture.authHeaders,
    );
    expect(diff.statusCode, HttpStatus.ok, reason: diff.body);
    final diffBody = Map<String, Object?>.from(jsonDecode(diff.body) as Map);
    final evidence = Map<String, Object?>.from(
      diffBody['resourceEvidence'] as Map,
    );
    expect(((evidence['before'] as List).single as Map)['contentHash'], hash);
    expect(
      ((evidence['after'] as List).single as Map)['contentHash'],
      nextHash,
    );

    final logicalId = Uri.encodeQueryComponent(
      'playmesh-local-resource://project/resource/image.png',
    );
    final oldRevisionResource = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/revisions/1/resources/$hash?logicalId=$logicalId',
      ),
      headers: fixture.authHeaders,
    );
    expect(oldRevisionResource.statusCode, HttpStatus.ok);
    expect(oldRevisionResource.bodyBytes, bytes);
    expect(
      oldRevisionResource.headers['content-type'],
      startsWith('image/png'),
    );
    expect(oldRevisionResource.headers['content-disposition'], 'inline');
    expect(oldRevisionResource.headers['x-content-type-options'], 'nosniff');

    final newRevisionResource = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/revisions/2/resources/$nextHash?logicalId=$logicalId',
      ),
      headers: fixture.authHeaders,
    );
    expect(newRevisionResource.statusCode, HttpStatus.ok);
    expect(newRevisionResource.bodyBytes, nextBytes);
    expect(newRevisionResource.headers['content-disposition'], 'attachment');

    final crossRevisionFallback = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/revisions/1/resources/$nextHash?logicalId=$logicalId',
      ),
      headers: fixture.authHeaders,
    );
    expect(crossRevisionFallback.statusCode, HttpStatus.notFound);

    final wrongProject = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-b/history/resources/$hash',
      ),
      headers: fixture.authHeaders,
    );
    expect(wrongProject.statusCode, HttpStatus.notFound);
  });

  test('缺失资源返回409，恢复修订冲突返回409且携带当前修订', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    final missingHash = 'a' * 64;
    final missing = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.conflict-project/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'missing'}),
        'resources': [_resourceJson(missingHash, 3)],
      },
    );
    expect(missing.statusCode, HttpStatus.conflict);
    expect(
      jsonDecode(missing.body)['error']['code'],
      'gdevelop_resource_missing',
    );

    final initial = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.conflict-project/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'initial'}),
        'resources': const [],
      },
    );
    expect(initial.statusCode, HttpStatus.ok);
    final conflict = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.conflict-project/history/restore-transactions',
      {
        'idempotencyKey': 'restore-conflict-1',
        'baseRevision': 2,
        'targetRevision': 1,
        'source': 'user',
        'currentProjectFiles': _projectFiles({'name': 'changed'}),
        'currentResources': const [],
      },
    );
    expect(conflict.statusCode, HttpStatus.conflict);
    final error = jsonDecode(conflict.body)['error'];
    expect(error['code'], 'gdevelop_revision_conflict');
    expect(error['currentRevision'], 1);

    final targetMissing = await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.conflict-project/history/restore-transactions',
      {
        'idempotencyKey': 'restore-target-missing-1',
        'baseRevision': 1,
        'targetRevision': 99,
        'source': 'user',
        'currentProjectFiles': _projectFiles({'name': 'initial'}),
        'currentResources': const [],
      },
    );
    expect(targetMissing.statusCode, HttpStatus.notFound);
    expect(
      jsonDecode(targetMissing.body)['error']['code'],
      'gdevelop_history_revision_not_found',
    );
    expect(jsonDecode(targetMissing.body)['error']['revision'], 99);
  });

  test('恢复事务 HTTP 协议覆盖 prepare、锁、commit、status、ack、recover 与 abort', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.conflict-project';
    const basePath = '/dev/api/gdevelop/projects/$gameId/history';

    for (final entry in const [
      (baseRevision: 0, name: 'target'),
      (baseRevision: 1, name: 'current'),
    ]) {
      final response = await fixture.jsonRequest(
        'POST',
        '$basePath/snapshots',
        {
          'baseRevision': entry.baseRevision,
          'reason': 'explicit_save',
          'source': 'user',
          'projectFiles': _projectFiles({'name': entry.name}),
          'resources': const [],
        },
      );
      expect(response.statusCode, HttpStatus.ok);
    }

    final prepareBody = <String, Object?>{
      'idempotencyKey': 'restore-http-1',
      'baseRevision': 2,
      'targetRevision': 1,
      'source': 'user',
      'currentProjectFiles': _projectFiles({'name': 'current'}),
      'currentResources': const [],
      'clientId': 'web-ide-test',
    };
    final prepared = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions',
      prepareBody,
    );
    expect(prepared.statusCode, HttpStatus.created);
    final preparedEnvelope = Map<String, Object?>.from(
      jsonDecode(prepared.body) as Map,
    );
    final preparedTransaction = Map<String, Object?>.from(
      preparedEnvelope['transaction']! as Map,
    );
    final txId = preparedTransaction['txId']! as String;
    expect(preparedEnvelope['requestId'], isA<String>());
    expect(preparedTransaction['phase'], 'PREPARED');
    expect(preparedTransaction['gameId'], gameId);
    expect(preparedTransaction['clientId'], 'web-ide-test');
    final preparedTargetSnapshot = Map<String, Object?>.from(
      preparedTransaction['targetSnapshot']! as Map,
    );
    expect((preparedTargetSnapshot['sourceVersion'] as Map)['revision'], 1);
    expect(_rootContent(preparedTargetSnapshot['projectFiles']), {
      'name': 'target',
    });
    expect(preparedTargetSnapshot['resources'], isEmpty);
    expect(preparedTargetSnapshot, containsPair('playmeshProjectConfig', null));
    expect(
      (preparedTransaction['targetEvidence'] as Map)['history']['revision'],
      3,
      reason: '计划 revision 必须与 sourceVersion 分离',
    );
    expect(preparedTransaction, isNot(contains('restored')));

    final repeatedPrepare = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions',
      prepareBody,
    );
    expect(repeatedPrepare.statusCode, HttpStatus.created);
    expect(jsonDecode(repeatedPrepare.body)['transaction']['txId'], txId);
    expect(
      jsonDecode(repeatedPrepare.body)['transaction']['targetSnapshot'],
      preparedTargetSnapshot,
    );

    final lockedMutation = await fixture.jsonRequest(
      'POST',
      '$basePath/snapshots',
      {
        'baseRevision': 2,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'must-not-write'}),
        'resources': const [],
      },
    );
    expect(lockedMutation.statusCode, HttpStatus.conflict);
    expect(
      jsonDecode(lockedMutation.body)['error']['code'],
      'gdevelop_project_mutation_locked',
    );

    final statusBeforeCommit = await http.get(
      fixture.uri('$basePath/restore-transactions/$txId'),
      headers: fixture.authHeaders,
    );
    expect(statusBeforeCommit.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(statusBeforeCommit.body)['transaction']['phase'],
      'PREPARED',
    );
    expect(
      jsonDecode(statusBeforeCommit.body)['transaction']['targetSnapshot'],
      preparedTargetSnapshot,
    );

    final wrongProjectStatus = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-b/history/'
        'restore-transactions/$txId',
      ),
      headers: fixture.authHeaders,
    );
    expect(wrongProjectStatus.statusCode, HttpStatus.notFound);

    final committed = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/$txId/commit',
    );
    expect(committed.statusCode, HttpStatus.ok);
    final committedTransaction = Map<String, Object?>.from(
      jsonDecode(committed.body)['transaction'] as Map,
    );
    expect(committedTransaction['phase'], 'BACKEND_COMMITTED');
    expect((committedTransaction['restored'] as Map)['version']['revision'], 3);
    final targetEvidence = Map<String, Object?>.from(
      committedTransaction['targetEvidence']! as Map,
    );
    final historyEvidence = Map<String, Object?>.from(
      targetEvidence['history']! as Map,
    );
    final ackBody = <String, Object?>{
      'projectFilesHash': historyEvidence['projectFilesHash'],
      'resourceManifestHash': historyEvidence['resourceManifestHash'],
    };

    final acknowledged = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/$txId/ack',
      ackBody,
    );
    expect(acknowledged.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(acknowledged.body)['transaction']['phase'],
      'BROWSER_PERSISTED',
    );
    final repeatedAck = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/$txId/ack',
      ackBody,
    );
    expect(repeatedAck.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(repeatedAck.body)['transaction']['phase'],
      'BROWSER_PERSISTED',
    );

    final recovered = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/recover',
    );
    expect(recovered.statusCode, HttpStatus.ok);
    expect(jsonDecode(recovered.body)['transaction'], isNull);
    expect(jsonDecode(recovered.body)['replayedEventTxIds'], isA<List>());

    final abortPrepared = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions',
      {
        ...prepareBody,
        'idempotencyKey': 'restore-http-abort-1',
        'baseRevision': 3,
        'currentProjectFiles': _projectFiles({'name': 'target'}),
      },
    );
    expect(abortPrepared.statusCode, HttpStatus.created);
    final abortTxId =
        jsonDecode(abortPrepared.body)['transaction']['txId'] as String;
    final aborted = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/$abortTxId/abort',
    );
    expect(aborted.statusCode, HttpStatus.ok);
    expect(jsonDecode(aborted.body)['transaction']['phase'], 'ABORTED');
    final repeatedAbort = await fixture.jsonRequest(
      'POST',
      '$basePath/restore-transactions/$abortTxId/abort',
    );
    expect(repeatedAbort.statusCode, HttpStatus.ok);
    expect(jsonDecode(repeatedAbort.body)['transaction']['phase'], 'ABORTED');
  });

  test('presence 只返回新增资源并复用历史 pin 的旧 hash', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    final firstBytes = Uint8List.fromList([1, 1, 1]);
    final secondBytes = Uint8List.fromList([2, 2, 2]);
    final firstHash = await _hash(firstBytes);
    final secondHash = await _hash(secondBytes);
    final firstResource = _resourceJson(firstHash, firstBytes.length);
    final secondResource = {
      ..._resourceJson(secondHash, secondBytes.length),
      'logicalId': 'playmesh-local-resource://project/resource/second.png',
    };
    await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.presence-project/history/resources/$firstHash',
      ),
      headers: fixture.binaryHeaders,
      body: firstBytes,
    );
    await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.presence-project/history/snapshots',
      {
        'baseRevision': 0,
        'reason': 'explicit_save',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'first'}),
        'resources': [firstResource],
      },
    );

    final unchanged = await fixture.presence('com.example.presence-project', [
      firstResource,
    ]);
    expect(unchanged['missing'], isEmpty, reason: '连续相同快照应为 0 次 PUT');
    final oneChanged = await fixture.presence('com.example.presence-project', [
      firstResource,
      secondResource,
    ]);
    expect(oneChanged['missing'], [
      {'contentHash': secondHash, 'size': secondBytes.length},
    ]);

    await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.presence-project/history/resources/$secondHash',
      ),
      headers: fixture.binaryHeaders,
      body: secondBytes,
    );
    await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.presence-project/history/snapshots',
      {
        'baseRevision': 1,
        'reason': 'important_change',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'second'}),
        'resources': [firstResource, secondResource],
      },
    );
    final deleted = await fixture.presence('com.example.presence-project', [
      firstResource,
    ]);
    expect(deleted['missing'], isEmpty, reason: '删除资源不需要 PUT');
    await fixture.jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/com.example.presence-project/history/snapshots',
      {
        'baseRevision': 2,
        'reason': 'important_change',
        'source': 'user',
        'projectFiles': _projectFiles({'name': 'deleted'}),
        'resources': [firstResource],
      },
    );
    final oldResource = await http.get(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.presence-project/history/resources/$secondHash',
      ),
      headers: fixture.authHeaders,
    );
    expect(
      oldResource.statusCode,
      HttpStatus.ok,
      reason: '历史 revision 仍应 pin 旧资源',
    );
    final reverted = await fixture.presence('com.example.presence-project', [
      secondResource,
    ]);
    expect(reverted['missing'], isEmpty, reason: '改回旧 hash 应为 0 次 PUT');
  });

  test('拒绝路径穿越和错误上传 hash', () async {
    final fixture = await _GatewayFixture.create();
    addTearDown(fixture.close);
    final traversal = await http.get(
      fixture.uri('/dev/api/gdevelop/projects/%2E%2E/history'),
      headers: fixture.authHeaders,
    );
    expect(traversal.statusCode, isNot(HttpStatus.ok));

    final wrongHash = await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/resources/${'0' * 64}',
      ),
      headers: fixture.binaryHeaders,
      body: [1, 2, 3],
    );
    expect(wrongHash.statusCode, HttpStatus.badRequest);
  });

  test('资源对象上限提前返回413，工程 JSON 上限为 1 GiB', () async {
    final fixture = await _GatewayFixture.create(
      policy: const LocalVersionRetentionPolicy(
        maxVersionsPerNamespace: 2,
        maxUniqueBytesPerNamespace: 1024,
        maxObjectBytes: 4,
      ),
    );
    addTearDown(fixture.close);
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final hash = await _hash(bytes);
    final resource = await http.put(
      fixture.uri(
        '/dev/api/gdevelop/projects/com.example.project-a/history/resources/$hash',
      ),
      headers: fixture.binaryHeaders,
      body: bytes,
    );
    expect(resource.statusCode, 413);
    expect(
      jsonDecode(resource.body)['error']['code'],
      'history_quota_exceeded',
    );
    expect(
      GDevelopProjectHistoryAdapter.maxProjectFilesBytes,
      1024 * 1024 * 1024,
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
  Map<String, String> get binaryHeaders => {
    ...authHeaders,
    'Content-Type': 'application/octet-stream',
  };

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

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
    'PATCH' => http.patch(
      uri(path),
      headers: {...authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
    'DELETE' => http.delete(uri(path), headers: authHeaders),
    _ => throw ArgumentError.value(method, 'method'),
  };

  Future<Map<String, Object?>> presence(
    String gameId,
    List<Map<String, Object?>> resources,
  ) async {
    final response = await jsonRequest(
      'POST',
      '/dev/api/gdevelop/projects/$gameId/history/resources/presence',
      {
        'resources': resources
            .map(
              (resource) => {
                'contentHash': resource['contentHash'],
                'size': resource['size'],
              },
            )
            .toList(),
      },
    );
    expect(response.statusCode, HttpStatus.ok);
    return Map<String, Object?>.from(jsonDecode(response.body) as Map);
  }

  Future<void> close() async {
    await lease.release();
    await gateway.close();
    await root.delete(recursive: true);
  }

  static Future<_GatewayFixture> create({
    LocalVersionRetentionPolicy policy = const LocalVersionRetentionPolicy(),
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-gateway-');
    final port = await _freePort();
    const token = 'gdevelop-history-test-token';
    var clockTick = 0;
    final clockOrigin = DateTime.utc(2026, 8, 10, 12);
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
      clock: () => clockOrigin.add(Duration(seconds: clockTick++)),
    );
    final history = GDevelopProjectHistoryAdapter(
      rootResolver: resolver,
      retentionPolicy: policy,
    );
    for (final gameId in const [
      'com.example.project-a',
      'com.example.project-b',
      'com.example.conflict-project',
      'com.example.presence-project',
    ]) {
      await history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        fileIdentifier: 'fixture-${gameId.split('.').last}',
        name: gameId,
      );
    }
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'gdevelophistorytest',
      gdevelopHistory: history,
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

Map<String, Object?> _resourceJson(String hash, int size) => {
  'logicalId': 'playmesh-local-resource://project/resource/image.png',
  'name': 'image.png',
  'contentHash': hash,
  'mime': 'image/png',
  'size': size,
};

List<Map<String, Object?>> _projectFiles(Map<String, Object?> content) => [
  {'path': 'game.json', 'content': content},
];

Object? _rootContent(Object? projectFiles) {
  final files = projectFiles! as List;
  final root = files.cast<Map>().singleWhere(
    (file) => file['path'] == 'game.json',
  );
  return root['content'];
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
