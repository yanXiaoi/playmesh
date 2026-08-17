import 'named_download_endpoint.dart';

enum VerifiedDownloadFailureKind {
  invalidUrl,
  http,
  timeout,
  network,
  quota,
  cancelled,
  invalidResponse,
  sizeMismatch,
  sha256Mismatch,
  unsupported,
}

class VerifiedDownloadException implements Exception {
  const VerifiedDownloadException({
    required this.kind,
    required this.diagnostic,
    this.httpStatus,
  });

  final VerifiedDownloadFailureKind kind;
  final String diagnostic;
  final int? httpStatus;

  @override
  String toString() => 'VerifiedDownloadException($diagnostic)';
}

class VerifiedDownloadSpec {
  const VerifiedDownloadSpec({
    required this.endpoint,
    required this.size,
    required this.sha256,
  });

  final NamedDownloadEndpoint endpoint;
  final int size;
  final String sha256;
}

class VerifiedDownloadProgress {
  const VerifiedDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 0 : receivedBytes / totalBytes;
}

class VerifiedDownloadResult {
  const VerifiedDownloadResult({
    required this.filePath,
    required this.bytes,
    required this.sha256,
    required this.resumed,
  });

  final String filePath;
  final int bytes;
  final String sha256;
  final bool resumed;
}

class DownloadCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancellationRequested() {
    if (_cancelled) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.cancelled,
        diagnostic: 'download_cancelled',
      );
    }
  }
}

typedef VerifiedDownloadProgressCallback =
    void Function(VerifiedDownloadProgress progress);

abstract interface class VerifiedResumableDownloader {
  Future<VerifiedDownloadResult> download({
    required String downloadRootPath,
    required VerifiedDownloadSpec spec,
    bool reuseCompleted = true,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  });

  void close();
}
