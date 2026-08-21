import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_distribution.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_local_package_source.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_manager_io.dart';
import 'package:playmesh/core/developer/gdevelop_ai_tool_registry.dart';
import 'package:playmesh/core/download/endpoint_document_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

void main() {
  test(
    'manager composes the selected manifest and ZIP into one transaction',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);
      final progress = <VerifiedDownloadProgress>[];

      final sources = await fixture.manager.loadConfigSources();
      final release = await fixture.manager.loadReleaseManifest(
        sources.sources.single,
      );
      final result = await fixture.manager.applyRelease(
        release: release,
        selectedDownload: release.downloads.single,
        forceRedownload: true,
        onProgress: progress.add,
      );

      expect(result.marker.sha256, release.sha256);
      expect(fixture.manifestLoader.calls, [fixture.configSource]);
      expect(fixture.downloader.calls, hasLength(1));
      expect(fixture.downloader.calls.single.reuseCompleted, isFalse);
      expect(
        fixture.downloader.calls.single.downloadRootPath,
        '${fixture.root.path}${Platform.pathSeparator}downloads',
      );
      expect(fixture.installer.specs.single.version, release.version);
      expect(fixture.installer.specs.single.size, release.size);
      expect(progress.single.receivedBytes, release.size);
    },
  );

  test(
    'manager rejects endpoints not present in the exact selected level',
    () async {
      final fixture = await _ManagerFixture.create();
      addTearDown(fixture.close);
      final undeclared = NamedDownloadEndpoint(
        name: 'Undeclared',
        url: Uri.parse('https://other.example/update.json'),
      );

      await expectLater(
        fixture.manager.loadReleaseManifest(undeclared),
        throwsA(isA<FormatException>()),
      );
      expect(fixture.manifestLoader.calls, isEmpty);

      await expectLater(
        fixture.manager.applyRelease(
          release: fixture.release,
          selectedDownload: undeclared,
          forceRedownload: false,
        ),
        throwsA(
          isA<GDevelopWebIdeInstallException>().having(
            (error) => error.diagnostic,
            'diagnostic',
            'gdevelop_download_source_not_declared',
          ),
        ),
      );
      expect(fixture.downloader.calls, isEmpty);
    },
  );

  test(
    'same-root operation guard covers download and install together',
    () async {
      final fixture = await _ManagerFixture.create(blockDownload: true);
      addTearDown(fixture.close);
      final first = fixture.manager.applyRelease(
        release: fixture.release,
        selectedDownload: fixture.downloadSource,
        forceRedownload: false,
      );
      await fixture.downloader.entered.future;

      await expectLater(
        fixture.manager.applyRelease(
          release: fixture.release,
          selectedDownload: fixture.downloadSource,
          forceRedownload: false,
        ),
        throwsA(isA<GDevelopWebIdeInstallBusyException>()),
      );
      expect(fixture.downloader.calls, hasLength(1));

      fixture.downloader.release.complete();
      await first;
    },
  );

  test('local content stream installs without path or network', () async {
    final fixture = await _ManagerFixture.create();
    addTearDown(fixture.close);
    final bytes = List<int>.generate(4096, (index) => index % 251);
    var memoryReads = 0;

    final result = await fixture.manager.applyLocalPackage(
      source: GDevelopLocalPackageSource(
        displayName: 'content://documents/webide.zip',
        openRead: () =>
            Stream.fromIterable([bytes.sublist(0, 1024), bytes.sublist(1024)]),
        readAsBytes: () async {
          memoryReads += 1;
          return Uint8List.fromList(bytes);
        },
      ),
      allowMemoryFallback: false,
    );

    expect(fixture.downloader.calls, isEmpty);
    expect(memoryReads, 0);
    expect(fixture.installer.localSpecs, hasLength(1));
    expect(fixture.installer.localSpecs.single.size, bytes.length);
    expect(result.marker.sha256, fixture.installer.localSpecs.single.sha256);
  });

  test('memory fallback requires explicit retry', () async {
    final fixture = await _ManagerFixture.create();
    addTearDown(fixture.close);
    final bytes = Uint8List.fromList(List.filled(128, 7));
    var memoryReads = 0;
    final source = GDevelopLocalPackageSource(
      displayName: 'webide.zip',
      openRead: () =>
          Stream.error(const GDevelopLocalPackageStreamingUnavailable()),
      readAsBytes: () async {
        memoryReads += 1;
        return bytes;
      },
    );

    await expectLater(
      fixture.manager.applyLocalPackage(
        source: source,
        allowMemoryFallback: false,
      ),
      throwsA(isA<GDevelopLocalPackageStreamingUnavailable>()),
    );
    expect(memoryReads, 0);
    expect(fixture.installer.localSpecs, isEmpty);

    await fixture.manager.applyLocalPackage(
      source: source,
      allowMemoryFallback: true,
    );
    expect(memoryReads, 1);
    expect(fixture.installer.localSpecs, hasLength(1));
  });

  test('cancelled or denied local reads never reach installer', () async {
    final fixture = await _ManagerFixture.create();
    addTearDown(fixture.close);
    final cancellation = DownloadCancellationToken()..cancel();
    final source = GDevelopLocalPackageSource(
      displayName: 'webide.zip',
      openRead: () => Stream.value(const [1, 2, 3]),
      readAsBytes: () async => Uint8List.fromList(const [1, 2, 3]),
    );

    await expectLater(
      fixture.manager.applyLocalPackage(
        source: source,
        allowMemoryFallback: false,
        cancellationToken: cancellation,
      ),
      throwsA(
        isA<VerifiedDownloadException>().having(
          (error) => error.kind,
          'kind',
          VerifiedDownloadFailureKind.cancelled,
        ),
      ),
    );
    await expectLater(
      fixture.manager.applyLocalPackage(
        source: GDevelopLocalPackageSource(
          displayName: 'denied.zip',
          openRead: () => Stream.error(StateError('permission denied')),
          readAsBytes: () async => Uint8List(0),
        ),
        allowMemoryFallback: false,
      ),
      throwsA(
        isA<GDevelopWebIdeInstallException>().having(
          (error) => error.diagnostic,
          'diagnostic',
          contains('gdevelop_local_package_read_failed'),
        ),
      ),
    );
    expect(fixture.installer.localSpecs, isEmpty);
  });
}

class _ManagerFixture {
  _ManagerFixture({
    required this.base,
    required this.root,
    required this.configSource,
    required this.downloadSource,
    required this.release,
    required this.manifestLoader,
    required this.downloader,
    required this.installer,
    required this.manager,
  });

  final Directory base;
  final Directory root;
  final NamedDownloadEndpoint configSource;
  final NamedDownloadEndpoint downloadSource;
  final GDevelopWebIdeReleaseManifest release;
  final _FakeManifestLoader manifestLoader;
  final _FakeDownloader downloader;
  final _FakeInstaller installer;
  final FileGDevelopWebIdeManager manager;

  static Future<_ManagerFixture> create({bool blockDownload = false}) async {
    final base = await Directory.systemTemp.createTemp('gdevelop-manager-');
    final root = Directory('${base.path}${Platform.pathSeparator}GDevelop');
    final configSource = NamedDownloadEndpoint(
      name: 'Config',
      url: Uri.parse('https://config.example/update.json'),
    );
    final downloadSource = NamedDownloadEndpoint(
      name: 'ZIP',
      url: Uri.parse('https://download.example/GDevelop-webide-v5.6.269.zip'),
    );
    final release = GDevelopWebIdeReleaseManifest(
      version: '5.6.269',
      sha256: List.filled(64, 'c').join(),
      size: 8192,
      downloads: [downloadSource],
    );
    final configLoader = _FakeConfigSourcesLoader(
      GDevelopWebIdeConfigSources([configSource]),
    );
    final manifestLoader = _FakeManifestLoader(release);
    final downloader = _FakeDownloader(block: blockDownload);
    final installer = _FakeInstaller();
    final manager = FileGDevelopWebIdeManager(
      configSourcesLoader: configLoader,
      releaseManifestLoader: manifestLoader,
      downloader: downloader,
      installer: installer,
      gdevelopRootResolver: () async => root,
    );
    return _ManagerFixture(
      base: base,
      root: root,
      configSource: configSource,
      downloadSource: downloadSource,
      release: release,
      manifestLoader: manifestLoader,
      downloader: downloader,
      installer: installer,
      manager: manager,
    );
  }

  Future<void> close() async {
    manager.close();
    if (await base.exists()) await base.delete(recursive: true);
  }
}

class _FakeConfigSourcesLoader extends GDevelopWebIdeConfigSourcesLoader {
  _FakeConfigSourcesLoader(this.value);

  final GDevelopWebIdeConfigSources value;

  @override
  Future<GDevelopWebIdeConfigSources> load() async => value;
}

class _FakeManifestLoader extends GDevelopWebIdeReleaseManifestLoader {
  _FakeManifestLoader(this.value)
    : super(
        documentLoader: EndpointDocumentLoader(
          httpClient: _UnusedDocumentClient(),
        ),
      );

  final GDevelopWebIdeReleaseManifest value;
  final List<NamedDownloadEndpoint> calls = [];

  @override
  Future<GDevelopWebIdeReleaseManifest> load(
    NamedDownloadEndpoint selectedSource,
  ) async {
    calls.add(selectedSource);
    return value;
  }
}

class _UnusedDocumentClient implements EndpointDocumentHttpClient {
  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) => throw StateError('unexpected document request');

  @override
  void close() {}
}

class _DownloadCall {
  const _DownloadCall({
    required this.downloadRootPath,
    required this.spec,
    required this.reuseCompleted,
  });

  final String downloadRootPath;
  final VerifiedDownloadSpec spec;
  final bool reuseCompleted;
}

class _FakeDownloader implements VerifiedResumableDownloader {
  _FakeDownloader({required this.block});

  final bool block;
  final entered = Completer<void>();
  final release = Completer<void>();
  final List<_DownloadCall> calls = [];

  @override
  Future<VerifiedDownloadResult> download({
    required String downloadRootPath,
    required VerifiedDownloadSpec spec,
    bool reuseCompleted = true,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    calls.add(
      _DownloadCall(
        downloadRootPath: downloadRootPath,
        spec: spec,
        reuseCompleted: reuseCompleted,
      ),
    );
    if (block) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    cancellationToken?.throwIfCancellationRequested();
    onProgress?.call(
      VerifiedDownloadProgress(receivedBytes: spec.size, totalBytes: spec.size),
    );
    return VerifiedDownloadResult(
      filePath: '$downloadRootPath${Platform.pathSeparator}${spec.sha256}.zip',
      bytes: spec.size,
      sha256: spec.sha256,
      resumed: false,
    );
  }

  @override
  void close() {}
}

class _FakeInstaller implements GDevelopWebIdeInstaller {
  final List<GDevelopWebIdeInstallSpec> specs = [];
  final List<GDevelopWebIdeLocalInstallSpec> localSpecs = [];

  @override
  Future<GDevelopWebIdeInstalledAiTools> loadInstalledAiTools({
    required String gdevelopRootPath,
  }) async {
    final registry = loadGDevelopAiToolRegistryForTest();
    return GDevelopWebIdeInstalledAiTools(
      marker: _marker(
        version: '5.6.269',
        sha256: List.filled(64, 'c').join(),
        size: 8192,
        registry: registry,
      ),
      registry: registry,
    );
  }

  @override
  Future<GDevelopWebIdeInstallationInspection> inspect({
    required String gdevelopRootPath,
  }) async => const GDevelopWebIdeInstallationInspection(
    state: GDevelopWebIdeInstallationState.absent,
  );

  @override
  Future<GDevelopWebIdeInstallResult> install({
    required GDevelopWebIdeInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) async {
    specs.add(spec);
    return GDevelopWebIdeInstallResult(
      marker: _marker(
        version: spec.version,
        sha256: spec.sha256,
        size: spec.size,
      ),
    );
  }

  @override
  Future<GDevelopWebIdeInstallResult> installLocalArchive({
    required GDevelopWebIdeLocalInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) async {
    localSpecs.add(spec);
    return GDevelopWebIdeInstallResult(
      marker: _marker(version: '5.6.269', sha256: spec.sha256, size: spec.size),
    );
  }

  @override
  Future<void> recover({required String gdevelopRootPath}) async {}

  GDevelopWebIdeInstalledMarker _marker({
    required String version,
    required String sha256,
    required int size,
    GDevelopAiToolRegistry? registry,
  }) => GDevelopWebIdeInstalledMarker(
    version: version,
    sha256: sha256,
    noticesSha256: List.filled(64, 'd').join(),
    aiToolsPath: 'playmesh/ai/tools.json',
    aiToolsSha256: List.filled(64, 'e').join(),
    aiToolsContractHash:
        registry?.contractHash ??
        loadGDevelopAiToolRegistryForTest().contractHash,
    size: size,
    installedAt: DateTime.utc(2026, 8, 5),
    installationKind: GDevelopWebIdeInstallationKind.release,
  );
}
