import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/endpoint_document_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_distribution.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_downloader_contract.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_manager_contract.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_manager_io.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_models.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_store_io.dart';

const _testSha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test(
    'local inspection and installed reuse perform no network or download',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);
      final destination = File(
        await fixture.store.installedFilePath(RuntimePackageTarget.androidX86),
      );
      await destination.writeAsString('manually copied package');
      final release = _manifest();
      final selected = release
          .downloadsFor(RuntimePackageTarget.androidX86)
          .single;

      final statuses = await fixture.manager.inspectPackages();
      final result = await fixture.manager.downloadPackage(
        target: RuntimePackageTarget.androidX86,
        release: release,
        selectedDownload: selected,
      );

      expect(statuses, hasLength(3));
      expect(result.reused, isTrue);
      expect(result.downloaded, isFalse);
      expect(fixture.downloader.calls, isEmpty);
      expect(fixture.documentClient.urls, isEmpty);
      expect(await destination.readAsString(), 'manually copied package');
    },
  );

  test(
    'missing package downloads and commits to the fixed file name',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);
      final release = _manifest();
      final selected = release
          .downloadsFor(RuntimePackageTarget.androidArm)
          .single;

      final result = await fixture.manager.downloadPackage(
        target: RuntimePackageTarget.androidArm,
        release: release,
        selectedDownload: selected,
      );

      expect(result.downloaded, isTrue);
      expect(result.reused, isFalse);
      expect(result.sha256, _testSha256);
      expect(result.status.installed, isTrue);
      expect(result.status.filePath, endsWith('playmesh-runtime-arm.apk'));
      expect(
        await File(result.status.filePath).readAsString(),
        'downloaded package',
      );
      expect(fixture.downloader.calls, hasLength(1));
      expect(
        fixture.downloader.calls.single.downloadDirectoryPath,
        endsWith('android-arm64'),
      );
    },
  );

  test(
    'forced failure preserves old package and successful retry replaces it',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);
      final target = RuntimePackageTarget.windowsX64;
      final destination = File(await fixture.store.installedFilePath(target));
      await destination.writeAsString('old package');
      final release = _manifest();
      final selected = release.downloadsFor(target).single;
      fixture.downloader.error = const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.sha256Mismatch,
        diagnostic: 'test_hash_mismatch',
      );

      await expectLater(
        fixture.manager.downloadPackage(
          target: target,
          release: release,
          selectedDownload: selected,
          forceRedownload: true,
        ),
        throwsA(isA<RuntimePackageDownloadException>()),
      );
      expect(await destination.readAsString(), 'old package');

      fixture.downloader.error = null;
      final result = await fixture.manager.downloadPackage(
        target: target,
        release: release,
        selectedDownload: selected,
        forceRedownload: true,
      );
      expect(result.downloaded, isTrue);
      expect(await destination.readAsString(), 'downloaded package');
    },
  );

  test('empty placeholder remains visible but cannot be downloaded', () async {
    final fixture = await _ManagerFixture.create();
    addTearDown(fixture.close);
    final release = _manifest(placeholderArm: true);
    final placeholder = release
        .downloadsFor(RuntimePackageTarget.androidArm)
        .single;

    expect(release.canDownload(RuntimePackageTarget.androidArm), isFalse);
    await expectLater(
      fixture.manager.downloadPackage(
        target: RuntimePackageTarget.androidArm,
        release: release,
        selectedDownload: placeholder,
      ),
      throwsA(
        isA<RuntimePackageDownloadException>().having(
          (error) => error.kind,
          'kind',
          RuntimePackageDownloadFailureKind.unavailable,
        ),
      ),
    );
    expect(fixture.downloader.calls, isEmpty);
  });

  test(
    'App.json source declaration is rechecked before manifest network I/O',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);

      final sources = await fixture.manager.loadConfigSources();
      final manifest = await fixture.manager.loadReleaseManifest(
        sources.sources.single,
      );
      expect(manifest.version, 'v1.0.0-build1');
      expect(fixture.documentClient.urls, [fixture.configSource.url]);

      await expectLater(
        fixture.manager.loadReleaseManifest(
          NamedDownloadEndpoint(
            name: 'Undeclared',
            url: Uri.parse('https://example.com/other.json'),
          ),
        ),
        throwsA(
          isA<RuntimePackageManagerException>().having(
            (error) => error.diagnostic,
            'diagnostic',
            'runtime_package_config_source_not_declared',
          ),
        ),
      );
      expect(fixture.documentClient.urls, hasLength(1));
    },
  );
}

RuntimePackageReleaseManifest _manifest({bool placeholderArm = false}) =>
    RuntimePackageReleaseManifest.fromJson({
      'version': 'v1.0.0-build1',
      'platform': {
        'android': {
          'x86': {
            'sha256': _testSha256,
            'downloads': [
              {'name': 'X86', 'url': 'https://example.com/x86.apk'},
            ],
          },
          'arm': {
            'sha256': _testSha256,
            'downloads': [
              {
                'name': 'ARM',
                'url': placeholderArm ? '' : 'https://example.com/arm.apk',
              },
            ],
          },
        },
        'windows': {
          'sha256': _testSha256,
          'downloads': [
            {'name': 'Windows', 'url': 'https://example.com/win.zip'},
          ],
        },
      },
    });

final class _ManagerFixture {
  _ManagerFixture({
    required this.root,
    required this.configSource,
    required this.documentClient,
    required this.downloader,
    required this.store,
    required this.manager,
  });

  final Directory root;
  final NamedDownloadEndpoint configSource;
  final _FakeDocumentClient documentClient;
  final _FakeDownloader downloader;
  final FileRuntimePackageStore store;
  final FileRuntimePackageManager manager;

  static Future<_ManagerFixture> create() async {
    final root = await Directory.systemTemp.createTemp('runtime-manager-');
    final configSource = NamedDownloadEndpoint(
      name: 'Config',
      url: Uri.parse('https://example.com/runtime.json'),
    );
    final documentClient = _FakeDocumentClient(
      jsonEncode(_manifest().toJson()),
    );
    final downloader = _FakeDownloader();
    final store = FileRuntimePackageStore(
      libraryRootResolver: () async => root,
    );
    final manager = FileRuntimePackageManager(
      configSourcesLoader: RuntimePackageConfigSourcesLoader(
        assetLoader: (_) async => jsonEncode([
          {'name': configSource.name, 'export': configSource.url.toString()},
          {'name': 'App only', 'app': 'https://example.com/app.json'},
        ]),
      ),
      releaseManifestLoader: RuntimePackageReleaseManifestLoader(
        documentLoader: EndpointDocumentLoader(httpClient: documentClient),
      ),
      downloader: downloader,
      store: store,
    );
    return _ManagerFixture(
      root: root,
      configSource: configSource,
      documentClient: documentClient,
      downloader: downloader,
      store: store,
      manager: manager,
    );
  }

  Future<void> close() async {
    manager.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _FakeDocumentClient implements EndpointDocumentHttpClient {
  _FakeDocumentClient(this.body);

  final String body;
  final List<Uri> urls = [];

  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) async {
    urls.add(url);
    return body;
  }

  @override
  void close() {}
}

final class _DownloadCall {
  const _DownloadCall({required this.downloadDirectoryPath});

  final String downloadDirectoryPath;
}

final class _FakeDownloader implements RuntimePackageDownloader {
  final List<_DownloadCall> calls = [];
  Object? error;

  @override
  Future<RuntimePackageDownloadResult> download({
    required RuntimePackageDownloadEndpoint endpoint,
    required String downloadDirectoryPath,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  }) async {
    calls.add(_DownloadCall(downloadDirectoryPath: downloadDirectoryPath));
    if (error case final failure?) throw failure;
    cancellationToken?.throwIfCancellationRequested();
    final temporary = File(
      '$downloadDirectoryPath${Platform.pathSeparator}.fake.download',
    );
    await temporary.writeAsString('downloaded package');
    onProgress?.call(
      const RuntimePackageDownloadProgress(receivedBytes: 18, totalBytes: null),
    );
    return RuntimePackageDownloadResult(
      temporaryFilePath: temporary.path,
      bytes: 18,
      sha256: endpoint.sha256,
    );
  }

  @override
  void close() {}
}
