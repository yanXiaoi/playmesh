import '../../models/game_summary.dart';

const developerInstallationPackageTargetAndroidArm64 = 'android-arm64';
const developerInstallationPackageTargetAndroidX86_64 = 'android-x86_64';
const developerInstallationPackageTargetWindowsX64 = 'windows-x64';
const developerInstallationPackageProgressRequestIdHeader =
    'X-Playmesh-Package-Export-Request-ID';

const developerInstallationPackageTargetIds = <String>{
  developerInstallationPackageTargetAndroidArm64,
  developerInstallationPackageTargetAndroidX86_64,
  developerInstallationPackageTargetWindowsX64,
};

enum DeveloperInstallationPackageProgressStage {
  preparing('preparing'),
  runtimeCheck('runtime_check'),
  runtimeDownload('runtime_download'),
  runtimeVerified('runtime_verified'),
  packageBuild('package_build'),
  nativeExport('native_export'),
  completed('completed'),
  failed('failed');

  const DeveloperInstallationPackageProgressStage(this.wireName);

  final String wireName;
}

final class DeveloperInstallationPackageProgress {
  const DeveloperInstallationPackageProgress({
    required this.stage,
    this.receivedBytes,
    this.totalBytes,
  });

  final DeveloperInstallationPackageProgressStage stage;
  final int? receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final received = receivedBytes;
    final total = totalBytes;
    if (received == null || total == null || total <= 0) return null;
    return (received / total).clamp(0, 1).toDouble();
  }

  double? get percent => fraction == null ? null : fraction! * 100;

  Map<String, Object?> toJson() => {
    'stage': stage.wireName,
    if (stage == DeveloperInstallationPackageProgressStage.runtimeDownload ||
        stage == DeveloperInstallationPackageProgressStage.runtimeVerified) ...{
      'receivedBytes': receivedBytes,
      'totalBytes': totalBytes,
      'fraction': fraction,
      'percent': percent,
    },
  };
}

typedef DeveloperInstallationPackageProgressCallback =
    void Function(DeveloperInstallationPackageProgress progress);

final class DeveloperInstallationPackageTargetStatus {
  const DeveloperInstallationPackageTargetStatus({
    required this.id,
    required this.platform,
    required this.architecture,
    required this.runtimeFilename,
    required this.installed,
    required this.downloadAvailable,
    this.runtimeVersion,
    this.sizeBytes,
  });

  final String id;
  final String platform;
  final String architecture;
  final String runtimeFilename;
  final bool installed;
  final bool downloadAvailable;
  final String? runtimeVersion;
  final int? sizeBytes;

  Map<String, Object?> toJson() => {
    'id': id,
    'platform': platform,
    'architecture': architecture,
    'runtimeFilename': runtimeFilename,
    'installed': installed,
    'downloadAvailable': downloadAvailable,
    if (runtimeVersion != null) 'runtimeVersion': runtimeVersion,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
  };
}

final class DeveloperInstallationPackageRelayServer {
  const DeveloperInstallationPackageRelayServer({
    required this.id,
    required this.name,
    required this.address,
    required this.token,
    this.latencyMs,
  });

  final String id;
  final String name;
  final Uri address;
  final String token;
  final int? latencyMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'address': address.toString(),
    'token': token,
    if (latencyMs != null) 'latencyMs': latencyMs,
  };
}

abstract interface class DeveloperInstallationPackageRelayServerCatalog {
  Future<List<DeveloperInstallationPackageRelayServer>> inspect();
}

final class EmptyDeveloperInstallationPackageRelayServerCatalog
    implements DeveloperInstallationPackageRelayServerCatalog {
  const EmptyDeveloperInstallationPackageRelayServerCatalog();

  @override
  Future<List<DeveloperInstallationPackageRelayServer>> inspect() async =>
      const [];
}

final class DeveloperInstallationPackageArtifact {
  const DeveloperInstallationPackageArtifact({
    required this.id,
    required this.projectId,
    required this.filePath,
    required this.filename,
    required this.mimeType,
    required this.size,
  });

  final String id;
  final String projectId;
  final String filePath;
  final String filename;
  final String mimeType;
  final int size;

  Map<String, Object?> toJson() => {
    'exportId': id,
    'filename': filename,
    'mimeType': mimeType,
    'size': size,
  };
}

abstract interface class DeveloperInstallationPackageService {
  Future<List<DeveloperInstallationPackageTargetStatus>> inspectTargets();

  Future<List<DeveloperInstallationPackageRelayServer>> inspectRelayServers();

  Future<DeveloperInstallationPackageArtifact> create({
    required GameSummary game,
    required String targetId,
    required bool refreshRuntime,
    Uri? relayServer,
    DeveloperInstallationPackageProgressCallback? onProgress,
  });

  DeveloperInstallationPackageArtifact? find(String exportId);

  Future<void> release(String exportId);

  Future<void> close();
}

enum DeveloperInstallationPackageFailureKind {
  targetUnavailable,
  runtimeDownloadUnavailable,
  runtimeDownloadFailed,
  invalidRuntimePackage,
  exportFailed,
}

final class DeveloperInstallationPackageException implements Exception {
  const DeveloperInstallationPackageException({
    required this.kind,
    required this.code,
    required this.message,
    this.diagnostic,
  });

  final DeveloperInstallationPackageFailureKind kind;
  final String code;
  final String message;
  final String? diagnostic;

  @override
  String toString() => 'DeveloperInstallationPackageException($code)';
}

Uri parseDeveloperRuntimeRelayServer(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.queryParametersAll.keys.any((key) => key != 'token') ||
      (uri.queryParametersAll['token']?.length ?? 0) > 1) {
    throw const FormatException('Runtime 中转地址必须是有效的 HTTP/HTTPS publicURL');
  }
  return uri;
}
