final class RuntimeAndroidNativeExportRequest {
  const RuntimeAndroidNativeExportRequest({
    required this.templateApkPath,
    required this.clearGamePackagePath,
    required this.outputApkPath,
    required this.keystorePath,
    required this.storePassword,
    required this.keyPassword,
    required this.keyAlias,
    required this.gameId,
    required this.applicationId,
    required this.label,
    required this.versionName,
    required this.versionCode,
    this.iconPath,
  });

  final String templateApkPath;
  final String clearGamePackagePath;
  final String outputApkPath;
  final String keystorePath;
  final String storePassword;
  final String keyPassword;
  final String keyAlias;
  final String gameId;
  final String applicationId;
  final String label;
  final String versionName;
  final int versionCode;
  final String? iconPath;

  Map<String, Object?> toJson() => {
    'templateApkPath': templateApkPath,
    'clearGamePackagePath': clearGamePackagePath,
    'outputApkPath': outputApkPath,
    'keystorePath': keystorePath,
    'storePassword': storePassword,
    'keyPassword': keyPassword,
    'keyAlias': keyAlias,
    'gameId': gameId,
    'applicationId': applicationId,
    'label': label,
    'versionName': versionName,
    'versionCode': versionCode,
    if (iconPath != null) 'iconPath': iconPath,
  };
}

final class RuntimeWindowsNativeExportRequest {
  const RuntimeWindowsNativeExportRequest({
    required this.templateZipPath,
    required this.clearGamePackagePath,
    required this.outputZipPath,
    required this.executableName,
    required this.label,
    required this.versionName,
    this.iconPath,
  });

  final String templateZipPath;
  final String clearGamePackagePath;
  final String outputZipPath;
  final String executableName;
  final String label;
  final String versionName;
  final String? iconPath;

  Map<String, Object?> toJson() => {
    'templateZipPath': templateZipPath,
    'clearGamePackagePath': clearGamePackagePath,
    'outputZipPath': outputZipPath,
    'executableName': executableName,
    'label': label,
    'versionName': versionName,
    if (iconPath != null) 'iconPath': iconPath,
  };
}

final class RuntimeNativeExportReport {
  const RuntimeNativeExportReport({
    required this.outputPath,
    required this.sizeBytes,
    this.sha256,
    this.applicationId,
    this.certificateSha256,
  });

  final String outputPath;
  final int sizeBytes;
  final String? sha256;
  final String? applicationId;
  final String? certificateSha256;
}

abstract interface class RuntimeNativeExporter {
  Future<RuntimeNativeExportReport> exportAndroid(
    RuntimeAndroidNativeExportRequest request,
  );

  Future<RuntimeNativeExportReport> exportWindows(
    RuntimeWindowsNativeExportRequest request,
  );
}
