import 'runtime_package_models.dart';

final class RuntimePackageStatus {
  const RuntimePackageStatus({
    required this.target,
    required this.filePath,
    required this.installed,
    required this.sizeBytes,
  });

  final RuntimePackageTarget target;
  final String filePath;
  final bool installed;
  final int? sizeBytes;

  Map<String, Object?> toJson() => {
    'target': target.id,
    'platform': target.platform,
    'architecture': target.architecture,
    'fileName': target.fileName,
    'filePath': filePath,
    'installed': installed,
    'sizeBytes': sizeBytes,
  };
}

abstract interface class RuntimePackageStore {
  Future<RuntimePackageStatus> inspect(RuntimePackageTarget target);

  Future<List<RuntimePackageStatus>> inspectAll();

  Future<String> installedFilePath(RuntimePackageTarget target);

  Future<String> downloadDirectoryPath(RuntimePackageTarget target);

  /// Atomically makes a fully downloaded temporary file the installed package.
  ///
  /// The temporary file must be on the same storage volume as the package
  /// directory. An existing package remains recoverable until the rename commits.
  Future<RuntimePackageStatus> commitTemporaryFile({
    required RuntimePackageTarget target,
    required String temporaryFilePath,
  });
}
