import '../download/named_download_endpoint.dart';
import 'runtime_package_distribution.dart';
import 'runtime_package_downloader_contract.dart';
import 'runtime_package_models.dart';
import 'runtime_package_store_contract.dart';

class RuntimePackageManagerException implements Exception {
  const RuntimePackageManagerException(this.diagnostic);

  final String diagnostic;

  @override
  String toString() => 'RuntimePackageManagerException($diagnostic)';
}

final class RuntimePackageManagerBusyException
    extends RuntimePackageManagerException {
  const RuntimePackageManagerBusyException()
    : super('runtime_package_operation_busy');
}

final class RuntimePackageInstallResult {
  const RuntimePackageInstallResult({
    required this.status,
    required this.version,
    required this.downloaded,
    required this.reused,
    required this.sha256,
  });

  final RuntimePackageStatus status;
  final String version;
  final bool downloaded;
  final bool reused;
  final String? sha256;

  Map<String, Object?> toJson() => {
    'status': status.toJson(),
    'version': version,
    'downloaded': downloaded,
    'reused': reused,
    'sha256': sha256,
  };
}

abstract interface class RuntimePackageManager {
  /// Local-only inspection. This never reads App.json or performs network I/O.
  Future<RuntimePackageStatus> inspectPackage(RuntimePackageTarget target);

  /// Local-only inspection of every supported export target.
  Future<List<RuntimePackageStatus>> inspectPackages();

  /// Reads the bundled App.json and projects only its `export` entries.
  Future<RuntimePackageConfigSources> loadConfigSources();

  /// Downloads and parses the selected source's Runtime update.json.
  Future<RuntimePackageReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  );

  /// Reuses an installed file unless [forceRedownload] is true. A missing file
  /// always downloads the explicitly selected endpoint.
  Future<RuntimePackageInstallResult> downloadPackage({
    required RuntimePackageTarget target,
    required RuntimePackageReleaseManifest release,
    required RuntimePackageDownloadEndpoint selectedDownload,
    bool forceRedownload = false,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  });

  void close();
}
