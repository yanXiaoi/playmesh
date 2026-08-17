import 'gdevelop_web_ide_manager_contract.dart';
import 'gdevelop_web_ide_manager_stub.dart'
    if (dart.library.io) 'gdevelop_web_ide_manager_io.dart'
    as platform;

export 'gdevelop_web_ide_manager_contract.dart';

GDevelopWebIdeManager createGDevelopWebIdeManager() =>
    platform.createGDevelopWebIdeManager();
