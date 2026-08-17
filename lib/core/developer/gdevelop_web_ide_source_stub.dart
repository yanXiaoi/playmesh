import 'gdevelop_web_ide_source_contract.dart';

GDevelopWebIdeSource createGDevelopWebIdeSource() =>
    const _UnavailableGDevelopWebIdeSource();

class _UnavailableGDevelopWebIdeSource implements GDevelopWebIdeSource {
  const _UnavailableGDevelopWebIdeSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<Never?> read(String relativePath) async => null;
}
