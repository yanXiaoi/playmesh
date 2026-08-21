import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_capability_catalog_service.dart';
import 'package:playmesh/core/developer/gdevelop_catalog_artifact_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String index;
  late String lock;
  late List<int> artifactBody;
  late String artifactSha256;
  final commit = List.filled(40, 'a').join();
  final tree = List.filled(40, 'b').join();
  final exampleCommit = List.filled(40, 'c').join();
  final exampleTree = List.filled(40, 'd').join();

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'playmesh-capability-catalog-',
    );
    artifactBody = utf8.encode(
      jsonEncode({
        'name': 'MotionKit',
        'fullName': 'Motion kit',
        'requiredExtensions': [
          {'extensionName': 'Tween', 'extensionVersion': '1.2.0'},
        ],
        'eventsFunctions': [
          {
            'name': 'Start',
            'fullName': 'Start motion',
            'description': 'Starts motion.',
            'functionType': 'Action',
          },
          {
            'name': 'IsMoving',
            'fullName': 'Is moving',
            'description': 'Checks motion.',
            'functionType': 'Condition',
          },
          {
            'name': 'Speed',
            'fullName': 'Speed',
            'description': 'Returns speed.',
            'functionType': 'Expression',
          },
        ],
        'eventsBasedBehaviors': [
          {
            'name': 'MotionBehavior',
            'fullName': 'Motion behavior',
            'description': 'Moves sprite objects.',
            'objectType': 'Sprite',
            'eventsFunctions': [
              {
                'name': 'Enabled',
                'fullName': 'Enabled',
                'description': 'Checks and returns enabled state.',
                'functionType': 'ExpressionAndCondition',
              },
            ],
          },
        ],
      }),
    );
    artifactSha256 = sha256.convert(artifactBody).toString();
    final artifact = {
      'id': 'extension:MotionKit',
      'kind': 'extension',
      'repository': 'GDevelopApp/GDevelop-extensions',
      'commit': commit,
      'rootTreeSha': tree,
      'path': 'extensions/reviewed/MotionKit.json',
      'declaredBytes': artifactBody.length,
      'sha256': artifactSha256,
      'mediaType': 'application/json',
    };
    index = jsonEncode({
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
          'tags': ['motion', 'sprite'],
          'artifactId': 'extension:MotionKit',
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
            'tags': ['motion'],
            'objectType': 'Sprite',
            'allRequiredBehaviorTypes': ['Tween::TweenBehavior'],
          },
        ],
      },
      'artifacts': {'extension:MotionKit': artifact},
    });
    lock = jsonEncode({
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
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  GDevelopCatalogArtifactService artifacts({
    required GDevelopCatalogArtifactFetcher fetcher,
  }) => GDevelopCatalogArtifactService(
    rootResolver: () async => root,
    lockLoader: () async => lock,
    catalogIndexLoader: (name) async => name == 'extensions-index.json'
        ? index
        : jsonEncode({
            'source': {
              'repository': 'GDevelopApp/GDevelop-examples',
              'commit': exampleCommit,
              'rootTreeSha': exampleTree,
            },
            'headers': <Object?>[],
          }),
    fetcher: fetcher,
  );

  test('search is local, bounded, stable and paginated', () async {
    var fetchCount = 0;
    final service = GDevelopCapabilityCatalogService(
      artifacts: artifacts(fetcher: (_, _, _, _) async => fetchCount += 1),
      indexLoader: () async => index,
    );

    final result = await service.search(
      const GDevelopCapabilitySearchRequest(
        query: 'sprite',
        category: 'movement',
        page: 1,
        pageSize: 10,
      ),
    );

    expect(fetchCount, 0);
    expect(result.total, 2);
    expect(
      result.items.map((item) => item['stableId']),
      containsAll(['MotionKit', 'MotionKit::MotionBehavior']),
    );
    expect(result.items.first.keys, {
      'stableId',
      'type',
      'canonicalName',
      'localizedName',
      'canonicalSummary',
      'localizedSummary',
      'ownerExtension',
      'category',
    });
    expect(
      result.items.first['localizedName'],
      result.items.first['canonicalName'],
    );

    final longSearch = await service.search(
      GDevelopCapabilitySearchRequest(
        query: List<String>.filled(512, 'q').join(),
        category: List<String>.filled(512, 'c').join(),
        pageSize: 10,
      ),
    );
    expect(longSearch.total, 0);

    await expectLater(
      service.search(const GDevelopCapabilitySearchRequest(pageSize: 51)),
      throwsFormatException,
    );
  });

  test('packaged 5.6.276 index is accepted without network access', () async {
    final packagedIndex = await File(
      'assets/playmesh-library/public/GDevelop/playmesh/catalog/generated/extensions-index.json',
    ).readAsString();
    var fetchCount = 0;
    final service = GDevelopCapabilityCatalogService(
      artifacts: artifacts(fetcher: (_, _, _, _) async => fetchCount += 1),
      indexLoader: () async => packagedIndex,
    );

    final result = await service.search(
      const GDevelopCapabilitySearchRequest(
        query: 'platformer',
        kind: 'behavior',
        pageSize: 5,
      ),
    );

    expect(result.total, greaterThan(0));
    expect(result.items, isNotEmpty);
    expect(result.items.every((item) => item['type'] == 'behavior'), isTrue);
    expect(fetchCount, 0);
  });

  test('catalog indexes larger than 8 MiB remain locally searchable', () async {
    final oversizedIndex = Map<String, Object?>.from(jsonDecode(index) as Map);
    final oneKiB = List.filled(1024, 'x').join();
    oversizedIndex['forwardCompatibleMetadata'] = List.filled(
      8193,
      oneKiB,
    ).join();
    final service = GDevelopCapabilityCatalogService(
      artifacts: artifacts(fetcher: (_, _, _, _) async {}),
      indexLoader: () async => jsonEncode(oversizedIndex),
    );

    final result = await service.search(
      const GDevelopCapabilitySearchRequest(
        query: 'MotionKit',
        kind: 'extension',
      ),
    );

    expect(result.total, 1);
    expect(result.items.single['stableId'], 'MotionKit');
  });

  test(
    'detail preserves more than 128 dependencies and functions plus long text',
    () async {
      final longDescription = List.filled(900, '长').join();
      final requiredExtensions = List.generate(
        130,
        (index) => {
          'extensionName': 'Dependency$index',
          'extensionVersion': '1.0.$index',
        },
      );
      List<Map<String, Object?>> functions(String type) => List.generate(
        130,
        (index) => {
          'name': '${type}Function$index',
          'fullName': '$type function $index',
          'description': index == 129
              ? longDescription
              : '$type description $index',
          'functionType': type,
        },
      );
      artifactBody = utf8.encode(
        jsonEncode({
          'name': 'MotionKit',
          'fullName': 'Motion kit',
          'requiredExtensions': requiredExtensions,
          'eventsFunctions': [
            ...functions('Action'),
            ...functions('Condition'),
            ...functions('Expression'),
          ],
        }),
      );
      artifactSha256 = sha256.convert(artifactBody).toString();
      final decodedIndex = Map<String, Object?>.from(jsonDecode(index) as Map);
      final headers = (decodedIndex['headers'] as List).cast<Map>();
      headers.single['shortDescription'] = longDescription;
      final artifact = Map<String, Object?>.from(
        (decodedIndex['artifacts'] as Map)['extension:MotionKit'] as Map,
      );
      artifact['declaredBytes'] = artifactBody.length;
      artifact['sha256'] = artifactSha256;
      decodedIndex['artifacts'] = {'extension:MotionKit': artifact};
      index = jsonEncode(decodedIndex);

      final service = GDevelopCapabilityCatalogService(
        artifacts: artifacts(
          fetcher: (_, target, _, _) async {
            await target.writeAsBytes(artifactBody, flush: true);
          },
        ),
        indexLoader: () async => index,
      );

      final searchResult = await service.search(
        const GDevelopCapabilitySearchRequest(
          kind: 'extension',
          query: 'MotionKit',
        ),
      );
      final detail = await service.detail(
        kind: 'extension',
        stableId: 'MotionKit',
      );

      expect(searchResult.items.single['canonicalSummary'], longDescription);
      expect(detail, isNotNull);
      final capability = detail!.capability;
      expect(capability['dependencies'], hasLength(130));
      expect(
        ((capability['dependencies'] as List).last as Map)['stableId'],
        'Dependency129',
      );
      for (final key in ['actions', 'conditions', 'expressions']) {
        final summaries = capability[key] as List;
        expect(summaries, hasLength(130), reason: key);
        expect(
          (summaries.last as Map)['summary'],
          longDescription,
          reason: key,
        );
      }
    },
  );

  test(
    'detail reuses owner extension CAS and returns complete summaries',
    () async {
      var fetchCount = 0;
      final service = GDevelopCapabilityCatalogService(
        artifacts: artifacts(
          fetcher: (_, target, _, _) async {
            fetchCount += 1;
            await target.writeAsBytes(artifactBody, flush: true);
          },
        ),
        indexLoader: () async => index,
      );

      final first = await service.detail(
        kind: 'behavior',
        stableId: 'MotionKit::MotionBehavior',
      );
      final second = await service.detail(
        kind: 'behavior',
        stableId: 'MotionKit::MotionBehavior',
      );

      expect(fetchCount, 1);
      expect(first, isNotNull);
      final capability = first!.capability;
      expect(capability['ownerExtension'], 'MotionKit');
      expect(capability['applicableObjectTypes'], ['Sprite']);
      expect((capability['conditions'] as List), hasLength(1));
      expect((capability['expressions'] as List), hasLength(1));
      expect((capability['actions'] as List), isEmpty);
      expect(
        (capability['dependencies'] as List).cast<Map>().map(
          (item) => item['stableId'],
        ),
        containsAll(['Tween', 'Tween::TweenBehavior']),
      );
      expect(
        (capability['artifact'] as Map).keys,
        containsAll({
          'id',
          'kind',
          'repository',
          'commit',
          'rootTreeSha',
          'path',
          'declaredBytes',
          'sha256',
          'mediaType',
        }),
      );
      expect((capability['artifact'] as Map), isNot(contains('url')));
      expect((capability['source'] as Map)['cache'], 'miss');
      expect((second!.capability['source'] as Map)['cache'], 'hit');
      expect(utf8.encode(jsonEncode(capability)).length, lessThan(256 * 1024));
    },
  );

  test('network failure is structured and never exposes a URL', () async {
    final service = GDevelopCapabilityCatalogService(
      artifacts: artifacts(
        fetcher: (uri, _, _, _) => throw SocketException(uri.toString()),
      ),
      indexLoader: () async => index,
    );

    await expectLater(
      service.detail(kind: 'extension', stableId: 'MotionKit'),
      throwsA(
        isA<GDevelopCapabilityCatalogException>()
            .having(
              (error) => error.code,
              'code',
              'capability_artifact_unavailable',
            )
            .having((error) => error.retryable, 'retryable', isTrue)
            .having(
              (error) => error.message,
              'message',
              isNot(contains('github.com')),
            ),
      ),
    );
  });
}
