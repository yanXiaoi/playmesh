import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_catalog_artifact_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late List<int> body;
  late String bodySha256;
  late String lock;
  late String extensionsIndex;
  late String examplesIndex;
  final extensionCommit = List.filled(40, 'a').join();
  final extensionTree = List.filled(40, 'b').join();
  final exampleCommit = List.filled(40, 'c').join();
  final exampleTree = List.filled(40, 'd').join();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playmesh-catalog-artifact-');
    body = utf8.encode('{"name":"Fixture"}');
    bodySha256 = sha256.convert(body).toString();
    lock = jsonEncode({
      'sources': {
        'extensions': {
          'repository': 'GDevelopApp/GDevelop-extensions',
          'commit': extensionCommit,
          'rootTreeSha': extensionTree,
        },
        'examples': {
          'repository': 'GDevelopApp/GDevelop-examples',
          'commit': exampleCommit,
          'rootTreeSha': exampleTree,
        },
      },
      'limits': {
        'extensionBytes': 1024,
        'exampleProjectBytes': 2048,
        'exampleResourceBytes': 4096,
        'licenseFileBytes': 1024,
      },
    });
    extensionsIndex = jsonEncode({
      'artifacts': {
        'extension:Fixture': {
          'repository': 'GDevelopApp/GDevelop-extensions',
          'commit': extensionCommit,
          'rootTreeSha': extensionTree,
          'path': 'extensions/reviewed/Fixture.json',
          'declaredBytes': body.length,
          'gitBlobOid': List.filled(40, 'e').join(),
          'sha256': bodySha256,
          'mediaType': 'application/json',
        },
      },
    });
    examplesIndex = jsonEncode({
      'source': {
        'repository': 'GDevelopApp/GDevelop-examples',
        'commit': exampleCommit,
        'rootTreeSha': exampleTree,
      },
      'headers': <Object?>[],
    });
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  GDevelopCatalogArtifactRequest request({
    String? commit,
    String? expectedSha256,
  }) => GDevelopCatalogArtifactRequest(
    id: 'extension:Fixture',
    kind: 'extension',
    repository: 'GDevelopApp/GDevelop-extensions',
    commit: commit ?? extensionCommit,
    rootTreeSha: extensionTree,
    path: 'extensions/reviewed/Fixture.json',
    declaredBytes: body.length,
    gitBlobOid: List.filled(40, 'e').join(),
    sha256: expectedSha256 ?? bodySha256,
    mediaType: 'application/json',
  );

  Future<String> loadIndex(String name) async =>
      name == 'extensions-index.json' ? extensionsIndex : examplesIndex;

  test('fixed catalog lock is packaged in the App asset bundle', () async {
    final source = await rootBundle.loadString(
      'assets/playmesh-library/public/GDevelop/playmesh/catalog-lock.json',
    );
    final decoded = jsonDecode(source) as Map<String, Object?>;
    expect(decoded['schemaVersion'], 1);
    expect(decoded['catalogRevision'], isNotEmpty);
    expect(decoded['sources'], isA<Map>());
  });

  test('packaged policy accepts the generated RegEx behavior artifact', () async {
    final realExtensionsIndex = await File(
      'assets/playmesh-library/public/GDevelop/playmesh/catalog/generated/extensions-index.json',
    ).readAsString();
    final realExamplesIndex = await File(
      'assets/playmesh-library/public/GDevelop/playmesh/catalog/generated/examples-index.json',
    ).readAsString();
    final decoded = jsonDecode(realExtensionsIndex) as Map<String, Object?>;
    final artifacts = Map<String, Object?>.from(decoded['artifacts'] as Map);
    final artifact = Map<String, Object?>.from(
      artifacts['extension:RegEx'] as Map,
    );
    final service = GDevelopCatalogArtifactService(
      rootResolver: () async => root,
      catalogIndexLoader: (name) async => name == 'extensions-index.json'
          ? realExtensionsIndex
          : realExamplesIndex,
      fetcher: (_, _, _, _) => throw const GDevelopCatalogArtifactException(
        'policy_probe_reached_fetcher',
        'probe',
      ),
    );
    final request = GDevelopCatalogArtifactRequest(
      id: artifact['id'] as String,
      kind: artifact['kind'] as String,
      repository: artifact['repository'] as String,
      commit: artifact['commit'] as String,
      rootTreeSha: artifact['rootTreeSha'] as String,
      path: artifact['path'] as String,
      declaredBytes: artifact['declaredBytes'] as int,
      gitBlobOid: artifact['gitBlobOid'] as String?,
      sha256: artifact['sha256'] as String,
      mediaType: artifact['mediaType'] as String,
    );

    await expectLater(
      service.acquire(request),
      throwsA(
        isA<GDevelopCatalogArtifactException>().having(
          (error) => error.code,
          'code',
          'policy_probe_reached_fetcher',
        ),
      ),
    );
  });

  test('downloads only on acquire then reuses App CAS/LKG offline', () async {
    var fetchCount = 0;
    Uri? usedProxy;
    final service = GDevelopCatalogArtifactService(
      rootResolver: () async => root,
      lockLoader: () async => lock,
      catalogIndexLoader: loadIndex,
      proxy: Uri.parse('http://127.0.0.1:1080'),
      fetcher: (uri, target, maximumBytes, proxy) async {
        fetchCount++;
        usedProxy = proxy;
        expect(uri.host, 'raw.githubusercontent.com');
        expect(
          uri.path,
          contains('/$extensionCommit/extensions/reviewed/Fixture.json'),
        );
        expect(maximumBytes, 1024);
        await target.writeAsBytes(body, flush: true);
      },
    );

    final downloaded = await service.acquire(request());
    expect(downloaded.cacheHit, isFalse);
    expect(downloaded.sha256, bodySha256);
    expect(fetchCount, 1);
    expect(usedProxy, Uri.parse('http://127.0.0.1:1080'));

    final cached = await service.acquire(request());
    expect(cached.cacheHit, isTrue);
    expect(fetchCount, 1);
    expect(await cached.file.readAsBytes(), body);
    expect(
      await Directory(
        '${root.path}${Platform.pathSeparator}lkg',
      ).list().where((entry) => entry is File).length,
      1,
    );
  });

  test(
    'downstream import failure keeps the verified App CAS artifact',
    () async {
      var fetchCount = 0;
      final service = GDevelopCatalogArtifactService(
        rootResolver: () async => root,
        lockLoader: () async => lock,
        catalogIndexLoader: loadIndex,
        fetcher: (_, target, _, _) async {
          fetchCount++;
          await target.writeAsBytes(body, flush: true);
        },
      );

      final downloaded = await service.acquire(request());
      expect(downloaded.cacheHit, isFalse);
      expect(fetchCount, 1);

      // Allocation/import owns its rollback independently. A failure after the
      // catalog acquisition must not evict immutable verified download bytes.
      expect(
        () => throw StateError('downstream allocation failed'),
        throwsStateError,
      );

      final reused = await service.acquire(request());
      expect(reused.cacheHit, isTrue);
      expect(await reused.file.readAsBytes(), body);
      expect(fetchCount, 1);
    },
  );

  test(
    'unreachable source never replaces a corrupt or missing CAS entry',
    () async {
      final cas = Directory('${root.path}${Platform.pathSeparator}cas');
      await cas.create(recursive: true);
      final corrupt = File('${cas.path}${Platform.pathSeparator}$bodySha256');
      await corrupt.writeAsString('corrupt');
      final service = GDevelopCatalogArtifactService(
        rootResolver: () async => root,
        lockLoader: () async => lock,
        catalogIndexLoader: loadIndex,
        fetcher: (_, _, _, _) => throw const SocketException('offline'),
      );

      await expectLater(
        service.acquire(request()),
        throwsA(
          isA<GDevelopCatalogArtifactException>()
              .having((error) => error.code, 'code', 'artifact_download_failed')
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
      expect(await corrupt.exists(), isFalse);
    },
  );

  test('unlisted SHA and changed commit fail before network or LKG', () async {
    var fetchCount = 0;
    final service = GDevelopCatalogArtifactService(
      rootResolver: () async => root,
      lockLoader: () async => lock,
      catalogIndexLoader: loadIndex,
      fetcher: (_, target, _, _) async {
        fetchCount++;
        await target.writeAsBytes(body, flush: true);
      },
    );
    await expectLater(
      service.acquire(request(expectedSha256: List.filled(64, 'f').join())),
      throwsA(isA<FormatException>()),
    );
    expect(fetchCount, 0);

    await expectLater(
      service.acquire(request(commit: List.filled(40, '9').join())),
      throwsA(isA<FormatException>()),
    );
    expect(fetchCount, 0);
  });
}
