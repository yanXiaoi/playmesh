import 'dart:io';

import 'package:flutter/services.dart';

import '../download/endpoint_document.dart';
import '../download/named_download_endpoint.dart';
import 'runtime_package_distribution.dart';
import 'runtime_package_downloader_contract.dart';
import 'runtime_package_downloader_io.dart';
import 'runtime_package_manager_contract.dart';
import 'runtime_package_models.dart';
import 'runtime_package_store_contract.dart';
import 'runtime_package_store_io.dart';

RuntimePackageManager createRuntimePackageManager() {
  final documentClient = createEndpointDocumentHttpClient();
  return FileRuntimePackageManager(
    configSourcesLoader: RuntimePackageConfigSourcesLoader(
      assetLoader: rootBundle.loadString,
    ),
    releaseManifestLoader: RuntimePackageReleaseManifestLoader(
      documentLoader: EndpointDocumentLoader(httpClient: documentClient),
    ),
    downloader: IoRuntimePackageDownloader(),
    store: FileRuntimePackageStore(),
    ownedDocumentClient: documentClient,
  );
}

final class FileRuntimePackageManager implements RuntimePackageManager {
  FileRuntimePackageManager({
    required this.configSourcesLoader,
    required this.releaseManifestLoader,
    required this.downloader,
    required this.store,
    this.ownedDocumentClient,
  });

  final RuntimePackageConfigSourcesLoader configSourcesLoader;
  final RuntimePackageReleaseManifestLoader releaseManifestLoader;
  final RuntimePackageDownloader downloader;
  final RuntimePackageStore store;
  final EndpointDocumentHttpClient? ownedDocumentClient;
  final Set<RuntimePackageTarget> _activeTargets = {};
  var _closed = false;

  @override
  Future<RuntimePackageStatus> inspectPackage(RuntimePackageTarget target) {
    _ensureOpen();
    return store.inspect(target);
  }

  @override
  Future<List<RuntimePackageStatus>> inspectPackages() {
    _ensureOpen();
    return store.inspectAll();
  }

  @override
  Future<RuntimePackageConfigSources> loadConfigSources() {
    _ensureOpen();
    return configSourcesLoader.load();
  }

  @override
  Future<RuntimePackageReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) async {
    _ensureOpen();
    final configured = await configSourcesLoader.load();
    if (!_containsConfigSource(configured.sources, selectedSource)) {
      throw const RuntimePackageManagerException(
        'runtime_package_config_source_not_declared',
      );
    }
    return releaseManifestLoader.load(selectedSource);
  }

  @override
  Future<RuntimePackageInstallResult> downloadPackage({
    required RuntimePackageTarget target,
    required RuntimePackageReleaseManifest release,
    required RuntimePackageDownloadEndpoint selectedDownload,
    bool forceRedownload = false,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  }) async {
    _ensureOpen();
    final current = await store.inspect(target);
    if (current.installed && !forceRedownload) {
      return RuntimePackageInstallResult(
        status: current,
        version: release.version,
        downloaded: false,
        reused: true,
        sha256: null,
      );
    }
    if (!release.downloadsFor(target).contains(selectedDownload)) {
      throw const RuntimePackageManagerException(
        'runtime_package_download_source_not_declared',
      );
    }
    if (!selectedDownload.downloadable) {
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.unavailable,
        diagnostic: 'runtime_package_download_unavailable',
      );
    }
    if (!_activeTargets.add(target)) {
      throw const RuntimePackageManagerBusyException();
    }

    String? temporaryFilePath;
    try {
      final downloaded = await downloader.download(
        endpoint: selectedDownload,
        downloadDirectoryPath: await store.downloadDirectoryPath(target),
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      temporaryFilePath = downloaded.temporaryFilePath;
      final installed = await store.commitTemporaryFile(
        target: target,
        temporaryFilePath: temporaryFilePath,
      );
      temporaryFilePath = null;
      return RuntimePackageInstallResult(
        status: installed,
        version: release.version,
        downloaded: true,
        reused: false,
        sha256: downloaded.sha256,
      );
    } finally {
      _activeTargets.remove(target);
      if (temporaryFilePath case final path?) {
        final temporary = File(path);
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on Object {
            // The next explicit download replaces this private temporary file.
          }
        }
      }
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    downloader.close();
    ownedDocumentClient?.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw const RuntimePackageManagerException(
        'runtime_package_manager_closed',
      );
    }
  }

  static bool _containsConfigSource(
    Iterable<NamedDownloadEndpoint> sources,
    NamedDownloadEndpoint candidate,
  ) => sources.any(
    (source) => source.name == candidate.name && source.url == candidate.url,
  );
}
