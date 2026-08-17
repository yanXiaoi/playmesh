import '../download/verified_resumable_download_contract.dart';
import 'gdevelop_web_ide_installer_contract.dart';

GDevelopWebIdeInstaller createGDevelopWebIdeInstaller() =>
    _UnsupportedGDevelopWebIdeInstaller();

class _UnsupportedGDevelopWebIdeInstaller implements GDevelopWebIdeInstaller {
  @override
  Future<GDevelopWebIdeInstallationInspection> inspect({
    required String gdevelopRootPath,
  }) async => const GDevelopWebIdeInstallationInspection(
    state: GDevelopWebIdeInstallationState.needsRepair,
    diagnostic: 'gdevelop_install_unsupported',
  );

  @override
  Future<GDevelopWebIdeInstallResult> install({
    required GDevelopWebIdeInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  Future<GDevelopWebIdeInstalledAiTools> loadInstalledAiTools({
    required String gdevelopRootPath,
  }) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  Future<GDevelopWebIdeInstallResult> installLocalArchive({
    required GDevelopWebIdeLocalInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) => throw const GDevelopWebIdeInstallException(
    'gdevelop_install_unsupported',
  );

  @override
  Future<void> recover({required String gdevelopRootPath}) async {}
}
