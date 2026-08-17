import 'verified_resumable_download_contract.dart';
import 'safe_zip_extractor_contract.dart';

SafeZipExtractor createSafeZipExtractor({
  required SafeZipExtractionPolicy policy,
}) => _UnsupportedSafeZipExtractor();

class _UnsupportedSafeZipExtractor implements SafeZipExtractor {
  @override
  Future<SafeZipExtractionResult> extract({
    required String archivePath,
    required String destinationPath,
    DownloadCancellationToken? cancellationToken,
  }) => throw const SafeZipExtractionException('zip_extraction_unsupported');
}
