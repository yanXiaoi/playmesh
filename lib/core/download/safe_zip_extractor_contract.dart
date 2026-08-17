import 'verified_resumable_download_contract.dart';

class SafeZipExtractionPolicy {
  const SafeZipExtractionPolicy({
    this.maxFileCount = 20000,
    this.maxSingleFileBytes = 512 * 1024 * 1024,
    this.maxExpandedBytes = 2 * 1024 * 1024 * 1024,
  }) : assert(maxFileCount > 0),
       assert(maxSingleFileBytes > 0),
       assert(maxExpandedBytes > 0);

  final int maxFileCount;
  final int maxSingleFileBytes;
  final int maxExpandedBytes;
}

class SafeZipExtractionResult {
  const SafeZipExtractionResult({
    required this.fileCount,
    required this.expandedBytes,
    required this.relativePaths,
  });

  final int fileCount;
  final int expandedBytes;
  final List<String> relativePaths;
}

class SafeZipExtractionException implements Exception {
  const SafeZipExtractionException(this.diagnostic);

  final String diagnostic;

  @override
  String toString() => 'SafeZipExtractionException($diagnostic)';
}

abstract interface class SafeZipExtractor {
  Future<SafeZipExtractionResult> extract({
    required String archivePath,
    required String destinationPath,
    DownloadCancellationToken? cancellationToken,
  });
}
