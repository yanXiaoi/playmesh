import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../download/endpoint_document.dart';
import '../download/named_download_endpoint.dart';
import '../download/verified_resumable_download.dart';
import '../library/playmesh_library_root.dart';
import 'gdevelop_web_ide_distribution.dart';
import 'gdevelop_ai_tool_registry.dart';
import 'gdevelop_web_ide_installer.dart';
import 'gdevelop_web_ide_manager_contract.dart';
import 'gdevelop_local_package_source.dart';

typedef GDevelopRootResolver = Future<Directory> Function();

GDevelopWebIdeManager createGDevelopWebIdeManager() {
  final documentClient = createEndpointDocumentHttpClient();
  return FileGDevelopWebIdeManager(
    configSourcesLoader: const GDevelopWebIdeConfigSourcesLoader(),
    releaseManifestLoader: GDevelopWebIdeReleaseManifestLoader(
      documentLoader: EndpointDocumentLoader(httpClient: documentClient),
    ),
    downloader: createVerifiedResumableDownloader(),
    installer: createGDevelopWebIdeInstaller(),
    ownedDocumentClient: documentClient,
  );
}

class FileGDevelopWebIdeManager implements GDevelopWebIdeManager {
  FileGDevelopWebIdeManager({
    required this.configSourcesLoader,
    required this.releaseManifestLoader,
    required this.downloader,
    required this.installer,
    GDevelopRootResolver? gdevelopRootResolver,
    this._ownedDocumentClient,
  }) : _gdevelopRootResolver =
           gdevelopRootResolver ?? _resolveDefaultGDevelopRoot;

  static final Set<String> _activeRoots = {};

  final GDevelopWebIdeConfigSourcesLoader configSourcesLoader;
  final GDevelopWebIdeReleaseManifestLoader releaseManifestLoader;
  final VerifiedResumableDownloader downloader;
  final GDevelopWebIdeInstaller installer;
  final GDevelopRootResolver _gdevelopRootResolver;
  final EndpointDocumentHttpClient? _ownedDocumentClient;
  var _closed = false;

  @override
  Future<GDevelopWebIdeInstallationInspection> inspectInstallation() async {
    _ensureOpen();
    final root = (await _gdevelopRootResolver()).absolute;
    return installer.inspect(gdevelopRootPath: root.path);
  }

  @override
  Future<GDevelopWebIdeInstalledNotices> loadInstalledNotices() async {
    _ensureOpen();
    final root = (await _gdevelopRootResolver()).absolute;
    final inspection = await installer.inspect(gdevelopRootPath: root.path);
    final marker = inspection.marker;
    if (inspection.state != GDevelopWebIdeInstallationState.ready ||
        marker == null) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_unavailable',
      );
    }
    final notices = File(
      '${root.path}${Platform.pathSeparator}official'
      '${Platform.pathSeparator}THIRD_PARTY_NOTICES.md',
    );
    if (!await notices.exists() ||
        await notices.length() <= 0 ||
        await notices.length() > 4 * 1024 * 1024) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_unavailable',
      );
    }
    final bytes = await notices.readAsBytes();
    final digest = await Sha256().hash(bytes);
    final sha256 = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (sha256 != marker.noticesSha256) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_identity_mismatch',
      );
    }
    return GDevelopWebIdeInstalledNotices(
      version: marker.version,
      archiveSha256: marker.sha256,
      noticesSha256: marker.noticesSha256,
      contents: utf8.decode(bytes, allowMalformed: false),
    );
  }

  @override
  Future<GDevelopAiToolRegistry> loadInstalledAiToolRegistry() async {
    _ensureOpen();
    final root = (await _gdevelopRootResolver()).absolute;
    final installed = await installer.loadInstalledAiTools(
      gdevelopRootPath: root.path,
    );
    return installed.registry;
  }

  @override
  Future<GDevelopWebIdeConfigSources> loadConfigSources() {
    _ensureOpen();
    return configSourcesLoader.load();
  }

  @override
  Future<GDevelopWebIdeReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) async {
    _ensureOpen();
    final configured = await configSourcesLoader.load();
    if (!_containsEndpoint(configured.sources, selectedSource)) {
      throw const FormatException('gdevelop_config_source_not_declared');
    }
    return releaseManifestLoader.load(selectedSource);
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    _ensureOpen();
    if (!_containsEndpoint(release.downloads, selectedDownload)) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_download_source_not_declared',
      );
    }
    final root = (await _gdevelopRootResolver()).absolute;
    final rootKey = Platform.isWindows ? root.path.toLowerCase() : root.path;
    if (!_activeRoots.add(rootKey)) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    try {
      final downloads = Directory(
        '${root.path}${Platform.pathSeparator}downloads',
      );
      final downloaded = await downloader.download(
        downloadRootPath: downloads.path,
        spec: VerifiedDownloadSpec(
          endpoint: selectedDownload,
          size: release.size,
          sha256: release.sha256,
        ),
        // 修复必须重新向所选线路取回字节，不能复用已完成缓存。
        reuseCompleted: !forceRedownload,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      return installer.install(
        spec: GDevelopWebIdeInstallSpec(
          gdevelopRootPath: root.path,
          archivePath: downloaded.filePath,
          version: release.version,
          sha256: release.sha256,
          size: release.size,
        ),
        cancellationToken: cancellationToken,
      );
    } finally {
      _activeRoots.remove(rootKey);
    }
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalPackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) async {
    _ensureOpen();
    final root = (await _gdevelopRootResolver()).absolute;
    final rootKey = Platform.isWindows ? root.path.toLowerCase() : root.path;
    if (!_activeRoots.add(rootKey)) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    final downloads = Directory(
      '${root.path}${Platform.pathSeparator}downloads',
    );
    await downloads.create(recursive: true);
    final temporary = File(
      '${downloads.path}${Platform.pathSeparator}.local-import-'
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-$pid.zip',
    );
    try {
      final identity = await _copyLocalPackage(
        source: source,
        destination: temporary,
        allowMemoryFallback: allowMemoryFallback,
        cancellationToken: cancellationToken,
      );
      final archive = File(
        '${downloads.path}${Platform.pathSeparator}${identity.sha256}.zip',
      );
      if (await archive.exists()) {
        if (await archive.length() == identity.size) {
          await temporary.delete();
        } else {
          await archive.delete();
          await temporary.rename(archive.path);
        }
      } else {
        await temporary.rename(archive.path);
      }
      return await installer.installLocalArchive(
        spec: GDevelopWebIdeLocalInstallSpec(
          gdevelopRootPath: root.path,
          archivePath: archive.path,
          sha256: identity.sha256,
          size: identity.size,
        ),
        cancellationToken: cancellationToken,
      );
    } on GDevelopLocalPackageStreamingUnavailable {
      rethrow;
    } on VerifiedDownloadException {
      rethrow;
    } on GDevelopWebIdeInstallException {
      rethrow;
    } on FileSystemException catch (error) {
      if (const {28, 112}.contains(error.osError?.errorCode)) {
        throw const VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.quota,
          diagnostic: 'gdevelop_local_package_no_space',
        );
      }
      throw GDevelopWebIdeInstallException(
        'gdevelop_local_package_read_failed:$error',
      );
    } on Object catch (error) {
      throw GDevelopWebIdeInstallException(
        'gdevelop_local_package_read_failed:$error',
      );
    } finally {
      _activeRoots.remove(rootKey);
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on Object {
          // The next import may safely replace this private temporary file.
        }
      }
    }
  }

  Future<_LocalPackageIdentity> _copyLocalPackage({
    required GDevelopLocalPackageSource source,
    required File destination,
    required bool allowMemoryFallback,
    required DownloadCancellationToken? cancellationToken,
  }) async {
    try {
      return await _writeLocalPackageStream(
        bytes: source.openRead(),
        destination: destination,
        cancellationToken: cancellationToken,
      );
    } on Object catch (error) {
      final streamingUnavailable =
          error is UnsupportedError ||
          error is GDevelopLocalPackageStreamingUnavailable;
      if (!streamingUnavailable) rethrow;
      if (!allowMemoryFallback) {
        throw GDevelopLocalPackageStreamingUnavailable(error);
      }
      if (await destination.exists()) await destination.delete();
      return _writeLocalPackageStream(
        bytes: Stream.value(await source.readAsBytes()),
        destination: destination,
        cancellationToken: cancellationToken,
      );
    }
  }

  Future<_LocalPackageIdentity> _writeLocalPackageStream({
    required Stream<List<int>> bytes,
    required File destination,
    required DownloadCancellationToken? cancellationToken,
  }) async {
    final output = destination.openWrite();
    final hashSink = Sha256().toSync().newHashSink();
    var size = 0;
    try {
      await for (final chunk in bytes) {
        cancellationToken?.throwIfCancellationRequested();
        hashSink.add(chunk);
        output.add(chunk);
        size += chunk.length;
      }
      cancellationToken?.throwIfCancellationRequested();
      await output.flush();
    } on Object {
      hashSink.close();
      rethrow;
    } finally {
      await output.close();
    }
    if (size <= 0) {
      hashSink.close();
      throw const GDevelopWebIdeInstallException(
        'gdevelop_local_package_empty',
      );
    }
    hashSink.close();
    final hash = await hashSink.hash();
    return _LocalPackageIdentity(
      sha256: hash.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      size: size,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    downloader.close();
    _ownedDocumentClient?.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw const GDevelopWebIdeInstallException('gdevelop_manager_closed');
    }
  }

  static bool _containsEndpoint(
    Iterable<NamedDownloadEndpoint> endpoints,
    NamedDownloadEndpoint candidate,
  ) => endpoints.any(
    (endpoint) =>
        endpoint.name == candidate.name && endpoint.url == candidate.url,
  );

  static Future<Directory> _resolveDefaultGDevelopRoot() async {
    final library = await PlaymeshLibraryRoot.resolve();
    return Directory('${library.path}${Platform.pathSeparator}GDevelop');
  }
}

class _LocalPackageIdentity {
  const _LocalPackageIdentity({required this.sha256, required this.size});

  final String sha256;
  final int size;
}
