import 'verified_resumable_download_contract.dart';
import 'verified_resumable_download_stub.dart'
    if (dart.library.io) 'verified_resumable_download_io.dart'
    as platform;

export 'verified_resumable_download_contract.dart';

VerifiedResumableDownloader createVerifiedResumableDownloader({
  int maxDownloadBytes = 4 * 1024 * 1024 * 1024,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration idleTimeout = const Duration(seconds: 30),
}) => platform.createVerifiedResumableDownloader(
  maxDownloadBytes: maxDownloadBytes,
  connectTimeout: connectTimeout,
  idleTimeout: idleTimeout,
);
