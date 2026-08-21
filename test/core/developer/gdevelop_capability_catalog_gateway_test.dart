import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_catalog_artifact_service.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('Gateway exposes bounded capability search and detail routes', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-capability-gateway-',
    );
    addTearDown(() => root.delete(recursive: true));
    final commit = List.filled(40, 'a').join();
    final tree = List.filled(40, 'b').join();
    final exampleCommit = List.filled(40, 'c').join();
    final exampleTree = List.filled(40, 'd').join();
    final body = utf8.encode(
      jsonEncode({
        'name': 'MotionKit',
        'requiredExtensions': <Object?>[],
        'eventsFunctions': <Object?>[],
        'eventsBasedBehaviors': [
          {
            'name': 'MotionBehavior',
            'objectType': 'Sprite',
            'eventsFunctions': [
              {
                'name': 'Move',
                'fullName': 'Move',
                'description': 'Moves the object.',
                'functionType': 'Action',
              },
            ],
          },
        ],
      }),
    );
    final digest = sha256.convert(body).toString();
    final artifact = {
      'id': 'extension:MotionKit',
      'kind': 'extension',
      'repository': 'GDevelopApp/GDevelop-extensions',
      'commit': commit,
      'rootTreeSha': tree,
      'path': 'extensions/reviewed/MotionKit.json',
      'declaredBytes': body.length,
      'sha256': digest,
      'mediaType': 'application/json',
    };
    final index = jsonEncode({
      'schemaVersion': 1,
      'catalogRevision': 'fixture-1',
      'engine': {'version': '5.6.276'},
      'headers': [
        {
          'tier': 'reviewed',
          'name': 'MotionKit',
          'fullName': 'Motion kit',
          'shortDescription': 'Adds reusable movement.',
          'category': 'Movement',
          'tags': ['motion'],
        },
      ],
      'behavior': {
        'headers': [
          {
            'tier': 'reviewed',
            'extensionName': 'MotionKit',
            'name': 'MotionBehavior',
            'fullName': 'Motion behavior',
            'description': 'Moves sprite objects.',
            'category': 'Movement',
            'objectType': 'Sprite',
            'allRequiredBehaviorTypes': <Object?>[],
          },
        ],
      },
      'artifacts': {'extension:MotionKit': artifact},
    });
    final examplesIndex = jsonEncode({
      'source': {
        'repository': 'GDevelopApp/GDevelop-examples',
        'commit': exampleCommit,
        'rootTreeSha': exampleTree,
      },
      'headers': <Object?>[],
    });
    final lock = jsonEncode({
      'sources': {
        'extensions': {
          'repository': 'GDevelopApp/GDevelop-extensions',
          'commit': commit,
          'rootTreeSha': tree,
        },
        'examples': {
          'repository': 'GDevelopApp/GDevelop-examples',
          'commit': exampleCommit,
          'rootTreeSha': exampleTree,
        },
      },
      'limits': {
        'extensionBytes': 1024 * 1024,
        'exampleProjectBytes': 1024,
        'exampleResourceBytes': 1024,
        'licenseFileBytes': 1024,
      },
    });
    var fetchCount = 0;
    final artifactService = GDevelopCatalogArtifactService(
      rootResolver: () async => root,
      lockLoader: () async => lock,
      catalogIndexLoader: (name) async =>
          name == 'extensions-index.json' ? index : examplesIndex,
      fetcher: (_, target, _, _) async {
        fetchCount += 1;
        await target.writeAsBytes(body, flush: true);
      },
    );
    final port = await _availablePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'capability-gateway-token',
      gdevelopWebIdeSource: _MapGDevelopWebIdeSource({
        'index.html': '<!doctype html><p>test</p>',
        'playmesh/catalog/extensions-index.json': index,
        'playmesh/catalog/examples-index.json': examplesIndex,
      }),
      gdevelopCatalogArtifacts: artifactService,
    );
    addTearDown(gateway.close);
    final client = http.Client();
    addTearDown(client.close);
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: base,
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: 'capability-gateway-token',
    );
    addTearDown(lease.release);
    final headers = lease.authHeaders;

    final search = await client.get(
      base.resolve(
        '/dev/api/gdevelop/catalog/capabilities?query=sprite&kind=behavior&page=1&pageSize=5',
      ),
      headers: headers,
    );
    expect(search.statusCode, HttpStatus.ok, reason: search.body);
    final searchJson = jsonDecode(search.body) as Map<String, Object?>;
    expect(searchJson['page'], 1);
    expect(searchJson['pageSize'], 5);
    expect(searchJson['total'], 1);
    expect(
      (searchJson['items'] as List).single,
      containsPair('stableId', 'MotionKit::MotionBehavior'),
    );
    expect(fetchCount, 0, reason: 'search must never download artifacts');

    final detail = await client.get(
      base.resolve(
        '/dev/api/gdevelop/catalog/capabilities/behavior/${Uri.encodeComponent('MotionKit::MotionBehavior')}',
      ),
      headers: headers,
    );
    expect(detail.statusCode, HttpStatus.ok, reason: detail.body);
    final detailJson = jsonDecode(detail.body) as Map<String, Object?>;
    final capability = detailJson['capability'] as Map<String, dynamic>;
    expect(capability['stableId'], 'MotionKit::MotionBehavior');
    expect(
      (capability['actions'] as List).single,
      containsPair('name', 'Move'),
    );
    expect((capability['artifact'] as Map), isNot(contains('url')));
    expect(fetchCount, 1);

    final openApi = await client.get(
      base.resolve('/dev/openapi.json'),
      headers: headers,
    );
    expect(openApi.statusCode, HttpStatus.ok, reason: openApi.body);
    expect(openApi.body, contains('/dev/api/gdevelop/catalog/capabilities'));
    expect(
      openApi.body,
      contains('/dev/api/gdevelop/catalog/capabilities/{kind}/{stableId}'),
    );

    final tooLarge = await client.get(
      base.resolve('/dev/api/gdevelop/catalog/capabilities?pageSize=51'),
      headers: headers,
    );
    expect(tooLarge.statusCode, HttpStatus.badRequest);
    final error = jsonDecode(tooLarge.body) as Map<String, Object?>;
    expect((error['error'] as Map)['code'], 'invalid_request');
  });
}

class _MapGDevelopWebIdeSource implements GDevelopWebIdeSource {
  const _MapGDevelopWebIdeSource(this.files);

  final Map<String, String> files;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Uint8List?> read(String relativePath) async {
    final value = files[relativePath];
    return value == null ? null : Uint8List.fromList(utf8.encode(value));
  }
}

Future<int> _availablePort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
}
