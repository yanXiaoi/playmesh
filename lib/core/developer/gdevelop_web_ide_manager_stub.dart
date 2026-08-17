import '../download/named_download_endpoint.dart';
import '../download/verified_resumable_download_contract.dart';
import 'gdevelop_web_ide_distribution.dart';
import 'gdevelop_ai_tool_registry.dart';
import 'gdevelop_web_ide_installer_contract.dart';
import 'gdevelop_web_ide_manager_contract.dart';
import 'gdevelop_local_package_source.dart';

GDevelopWebIdeManager createGDevelopWebIdeManager() =>
    const _UnsupportedGDevelopWebIdeManager();

class _UnsupportedGDevelopWebIdeManager implements GDevelopWebIdeManager {
  const _UnsupportedGDevelopWebIdeManager();

  @override
  Future<GDevelopWebIdeInstallationInspection> inspectInstallation() async =>
      const GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.needsRepair,
        diagnostic: 'gdevelop_install_unsupported',
      );

  @override
  Future<GDevelopWebIdeInstalledNotices> loadInstalledNotices() =>
      throw const GDevelopWebIdeInstallException(
        'gdevelop_install_unsupported',
      );

  @override
  Future<GDevelopAiToolRegistry> loadInstalledAiToolRegistry() =>
      throw const GDevelopWebIdeInstallException(
        'gdevelop_install_unsupported',
      );

  @override
  Future<GDevelopWebIdeConfigSources> loadConfigSources() async =>
      const GDevelopWebIdeConfigSources([]);

  @override
  Future<GDevelopWebIdeReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  Future<GDevelopWebIdeInstallResult> applyRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalPackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  void close() {}
}
