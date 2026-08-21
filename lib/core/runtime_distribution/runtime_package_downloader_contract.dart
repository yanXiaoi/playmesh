import 'runtime_package_models.dart';

enum RuntimePackageDownloadFailureKind {
  unavailable,
  invalidUrl,
  http,
  timeout,
  network,
  cancelled,
  tooLarge,
  empty,
  sha256Mismatch,
  fileSystem,
  unsupported,
}

final class RuntimePackageDownloadException implements Exception {
  const RuntimePackageDownloadException({
    required this.kind,
    required this.diagnostic,
    this.httpStatus,
  });

  final RuntimePackageDownloadFailureKind kind;
  final String diagnostic;
  final int? httpStatus;

  @override
  String toString() => 'RuntimePackageDownloadException($diagnostic)';
}

final class RuntimePackageDownloadProgress {
  const RuntimePackageDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    return total == null || total <= 0 ? null : receivedBytes / total;
  }

  Map<String, Object?> toJson() => {
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'fraction': fraction,
  };
}

typedef RuntimePackageDownloadProgressCallback =
    void Function(RuntimePackageDownloadProgress progress);

final class RuntimePackageDownloadCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancellationRequested() {
    if (_cancelled) {
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.cancelled,
        diagnostic: 'runtime_package_download_cancelled',
      );
    }
  }

  void Function() addCancellationListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

final class RuntimePackageDownloadResult {
  const RuntimePackageDownloadResult({
    required this.temporaryFilePath,
    required this.bytes,
    required this.sha256,
  });

  final String temporaryFilePath;
  final int bytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'temporaryFilePath': temporaryFilePath,
    'bytes': bytes,
    'sha256': sha256,
  };
}

abstract interface class RuntimePackageDownloader {
  Future<RuntimePackageDownloadResult> download({
    required RuntimePackageDownloadEndpoint endpoint,
    required String downloadDirectoryPath,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  });

  void close();
}
