import '../download/named_download_endpoint.dart';
import '../download/verified_resumable_download_contract.dart';
import 'gdevelop_web_ide_distribution.dart';
import 'gdevelop_web_ide_installer_contract.dart';
import 'gdevelop_local_package_source.dart';
import 'gdevelop_ai_tool_registry.dart';

/// 编排 WebIDE 的配置读取、下载校验与固定目录事务安装。
abstract interface class GDevelopWebIdeManager {
  Future<GDevelopWebIdeInstallationInspection> inspectInstallation();

  /// Reads notices from the currently installed and identity-verified WebIDE.
  Future<GDevelopWebIdeInstalledNotices> loadInstalledNotices();

  /// Loads the contract persisted by the successful WebIDE install/update.
  Future<GDevelopAiToolRegistry> loadInstalledAiToolRegistry();

  Future<GDevelopWebIdeConfigSources> loadConfigSources();

  Future<GDevelopWebIdeReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  );

  Future<GDevelopWebIdeInstallResult> applyRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  });

  Future<GDevelopWebIdeInstallResult> applyLocalPackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  });

  void close();
}
