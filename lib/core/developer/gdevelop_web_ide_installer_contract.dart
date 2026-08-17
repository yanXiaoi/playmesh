import '../download/verified_resumable_download_contract.dart';
import 'gdevelop_ai_tool_registry.dart';

enum GDevelopWebIdeInstallationState { absent, ready, needsRepair }

enum GDevelopWebIdeInstallationKind { release, userProvided }

class GDevelopWebIdeInstalledMarker {
  const GDevelopWebIdeInstalledMarker({
    required this.version,
    required this.sha256,
    required this.noticesSha256,
    required this.aiToolsPath,
    required this.aiToolsSha256,
    required this.aiToolsContractHash,
    required this.size,
    required this.installedAt,
    required this.installationKind,
  });

  final String version;
  final String sha256;

  /// Identity of the notice bytes inside this exact installed WebIDE tree.
  final String noticesSha256;

  /// Package-relative location of the WebIDE-owned AI tool contract.
  final String aiToolsPath;

  /// SHA-256 of the exact contract bytes installed at [aiToolsPath].
  final String aiToolsSha256;

  /// Canonical semantic contract hash used to pin editor sessions.
  final String aiToolsContractHash;
  final int size;
  final DateTime installedAt;
  final GDevelopWebIdeInstallationKind installationKind;
}

class GDevelopWebIdeInstalledAiTools {
  const GDevelopWebIdeInstalledAiTools({
    required this.marker,
    required this.registry,
  });

  final GDevelopWebIdeInstalledMarker marker;
  final GDevelopAiToolRegistry registry;
}

class GDevelopWebIdeInstalledNotices {
  const GDevelopWebIdeInstalledNotices({
    required this.version,
    required this.archiveSha256,
    required this.noticesSha256,
    required this.contents,
  });

  final String version;
  final String archiveSha256;
  final String noticesSha256;
  final String contents;
}

class GDevelopWebIdeInstallationInspection {
  const GDevelopWebIdeInstallationInspection({
    required this.state,
    this.marker,
    this.diagnostic,
  });

  final GDevelopWebIdeInstallationState state;
  final GDevelopWebIdeInstalledMarker? marker;
  final String? diagnostic;

  /// Release bytes are the sole update decision; display version is metadata.
  bool matchesSha256(String sha256) =>
      state == GDevelopWebIdeInstallationState.ready &&
      marker?.sha256 == sha256;

  bool matches({
    required String version,
    required String sha256,
    required int size,
  }) =>
      state == GDevelopWebIdeInstallationState.ready &&
      marker?.version == version &&
      marker?.sha256 == sha256 &&
      marker?.size == size;
}

class GDevelopWebIdeInstallSpec {
  const GDevelopWebIdeInstallSpec({
    required this.gdevelopRootPath,
    required this.archivePath,
    required this.version,
    required this.sha256,
    required this.size,
  });

  final String gdevelopRootPath;
  final String archivePath;
  final String version;
  final String sha256;
  final int size;
}

/// A locally selected archive whose immutable identity is computed by the
/// manager before it reaches the installer. The version is read from the
/// schema-3 Playmesh provenance inside the archive, never from the filename.
class GDevelopWebIdeLocalInstallSpec {
  const GDevelopWebIdeLocalInstallSpec({
    required this.gdevelopRootPath,
    required this.archivePath,
    required this.sha256,
    required this.size,
  });

  final String gdevelopRootPath;
  final String archivePath;
  final String sha256;
  final int size;
}

class GDevelopWebIdeInstallResult {
  const GDevelopWebIdeInstallResult({required this.marker});

  final GDevelopWebIdeInstalledMarker marker;
}

class GDevelopWebIdeInstallException implements Exception {
  const GDevelopWebIdeInstallException(this.diagnostic);

  final String diagnostic;

  @override
  String toString() => 'GDevelopWebIdeInstallException($diagnostic)';
}

class GDevelopWebIdeInstallBusyException implements Exception {
  const GDevelopWebIdeInstallBusyException();
}

abstract interface class GDevelopWebIdeInstaller {
  Future<GDevelopWebIdeInstallationInspection> inspect({
    required String gdevelopRootPath,
  });

  Future<void> recover({required String gdevelopRootPath});

  /// Loads the immutable AI tool contract recorded by the installed WebIDE.
  /// This never consults an open editor page.
  Future<GDevelopWebIdeInstalledAiTools> loadInstalledAiTools({
    required String gdevelopRootPath,
  });

  Future<GDevelopWebIdeInstallResult> install({
    required GDevelopWebIdeInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  });

  Future<GDevelopWebIdeInstallResult> installLocalArchive({
    required GDevelopWebIdeLocalInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  });
}
