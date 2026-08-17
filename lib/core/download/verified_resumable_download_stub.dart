import 'verified_resumable_download_contract.dart';

VerifiedResumableDownloader createVerifiedResumableDownloader({
  required int maxDownloadBytes,
  required Duration connectTimeout,
  required Duration idleTimeout,
}) => _UnsupportedVerifiedResumableDownloader();

class _UnsupportedVerifiedResumableDownloader
    implements VerifiedResumableDownloader {
  @override
  Future<VerifiedDownloadResult> download({
    required String downloadRootPath,
    required VerifiedDownloadSpec spec,
    bool reuseCompleted = true,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) => throw const VerifiedDownloadException(
    kind: VerifiedDownloadFailureKind.unsupported,
    diagnostic: 'verified_download_unsupported',
  );

  @override
  void close() {}
}
