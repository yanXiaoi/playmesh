import 'gdevelop_web_ide_source_contract.dart';
import 'gdevelop_web_ide_source_stub.dart'
    if (dart.library.io) 'gdevelop_web_ide_source_io.dart'
    as implementation;

export 'gdevelop_web_ide_source_contract.dart';

GDevelopWebIdeSource createGDevelopWebIdeSource() =>
    implementation.createGDevelopWebIdeSource();
