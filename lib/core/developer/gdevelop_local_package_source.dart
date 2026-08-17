import 'dart:typed_data';

typedef GDevelopLocalPackageStreamOpener = Stream<List<int>> Function();
typedef GDevelopLocalPackageBytesReader = Future<Uint8List> Function();

/// Platform-neutral input selected by the system file picker.
///
/// The installer never receives an Android content URI or an arbitrary source
/// path. The manager first consumes this source into its own downloads area,
/// computing the immutable SHA-256 identity while streaming.
class GDevelopLocalPackageSource {
  const GDevelopLocalPackageSource({
    required this.displayName,
    required this.openRead,
    required this.readAsBytes,
  });

  final String displayName;
  final GDevelopLocalPackageStreamOpener openRead;
  final GDevelopLocalPackageBytesReader readAsBytes;
}

class GDevelopLocalPackageStreamingUnavailable implements Exception {
  const GDevelopLocalPackageStreamingUnavailable([this.diagnostic]);

  final Object? diagnostic;
}
