import 'safe_zip_extractor_contract.dart';
import 'safe_zip_extractor_stub.dart'
    if (dart.library.io) 'safe_zip_extractor_io.dart'
    as platform;

export 'safe_zip_extractor_contract.dart';

SafeZipExtractor createSafeZipExtractor({
  SafeZipExtractionPolicy policy = const SafeZipExtractionPolicy(),
}) => platform.createSafeZipExtractor(policy: policy);
