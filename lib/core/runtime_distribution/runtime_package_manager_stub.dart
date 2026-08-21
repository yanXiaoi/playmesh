import '../download/named_download_endpoint.dart';
import 'runtime_package_distribution.dart';
import 'runtime_package_downloader_contract.dart';
import 'runtime_package_manager_contract.dart';
import 'runtime_package_models.dart';
import 'runtime_package_store_contract.dart';

RuntimePackageManager createRuntimePackageManager() =>
    const _UnsupportedRuntimePackageManager();

final class _UnsupportedRuntimePackageManager implements RuntimePackageManager {
  const _UnsupportedRuntimePackageManager();

  Never _unsupported() => throw const RuntimePackageManagerException(
    'runtime_package_distribution_unsupported',
  );

  @override
  Future<RuntimePackageStatus> inspectPackage(RuntimePackageTarget target) =>
      _unsupported();

  @override
  Future<List<RuntimePackageStatus>> inspectPackages() => _unsupported();

  @override
  Future<RuntimePackageConfigSources> loadConfigSources() => _unsupported();

  @override
  Future<RuntimePackageReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) => _unsupported();

  @override
  Future<RuntimePackageInstallResult> downloadPackage({
    required RuntimePackageTarget target,
    required RuntimePackageReleaseManifest release,
    required RuntimePackageDownloadEndpoint selectedDownload,
    bool forceRedownload = false,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  }) => _unsupported();

  @override
  void close() {}
}
