import '../download/named_download_endpoint.dart';
import '../download/verified_resumable_download_contract.dart';
import '../network/lan_endpoint.dart';
import 'gdevelop_web_ide_distribution.dart';
import 'gdevelop_web_ide_installer_contract.dart';
import 'gdevelop_local_package_source.dart';

class DeveloperSession {
  const DeveloperSession({
    required this.enabled,
    this.port,
    this.path,
    this.token,
    this.tokenHint,
    this.workspacePath,
    this.gdevelopWorkspacePath,
    this.docsPath,
    this.openApiPath,
    this.sdkManifestPath,
    this.createdAt,
  });

  final bool enabled;
  final int? port;
  final String? path;
  final String? token;
  final String? tokenHint;
  final String? workspacePath;
  final String? gdevelopWorkspacePath;
  final String? docsPath;
  final String? openApiPath;
  final String? sdkManifestPath;
  final DateTime? createdAt;

  factory DeveloperSession.fromJson(Map<String, Object?> json) {
    final createdAtMs = json['createdAt'];
    return DeveloperSession(
      enabled: json['enabled'] == true,
      port: json['port'] as int?,
      path: json['path'] as String?,
      token: json['token'] as String?,
      tokenHint: json['tokenHint'] as String?,
      workspacePath: json['workspacePath'] as String?,
      gdevelopWorkspacePath: json['gdevelopWorkspacePath'] as String?,
      docsPath: json['docsPath'] as String?,
      openApiPath: json['openApiPath'] as String?,
      sdkManifestPath: json['sdkManifestPath'] as String?,
      createdAt: createdAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
          : null,
    );
  }
}

abstract interface class DeveloperSessionProvider {
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  });

  Future<DeveloperSession> developerModeStatus();

  Future<void> disableDeveloperMode();
}

abstract interface class SourceDevelopmentProvider {
  Future<List<LanEndpointCandidate>> sourceWorkspaceLinks(
    DeveloperSession session,
  );
}

abstract interface class VisualGDevelopProvider {
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  );

  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation();

  Future<GDevelopWebIdeInstalledNotices> loadInstalledGDevelopWebIdeNotices();

  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources();

  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  );

  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  });

  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  });
}

/// App 运行时对“制作游戏”页面暴露的组合能力。
///
/// 组合接口只用于依赖注入；源代码与可视化控制器各自只消费自己的窄接口，
/// 避免把入口差异收敛成 `workspaceKind` 条件分支。
abstract interface class DeveloperModeProvider
    implements
        DeveloperSessionProvider,
        SourceDevelopmentProvider,
        VisualGDevelopProvider {
  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  });

  @override
  Future<DeveloperSession> developerModeStatus();

  @override
  Future<void> disableDeveloperMode();

  @override
  Future<List<LanEndpointCandidate>> sourceWorkspaceLinks(
    DeveloperSession session,
  );

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  );

  @override
  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation();

  @override
  Future<GDevelopWebIdeInstalledNotices> loadInstalledGDevelopWebIdeNotices();

  @override
  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources();

  @override
  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  );

  @override
  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  });

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  });
}

class DeveloperWorkspacePreference {
  const DeveloperWorkspacePreference({
    required this.port,
    required this.token,
    required this.path,
  });

  final int port;
  final String token;
  final String path;
}

abstract interface class DeveloperWorkspacePreferenceProvider {
  Future<DeveloperWorkspacePreference> loadDeveloperWorkspacePreference();
}

const defaultDeveloperPort = 16666;
