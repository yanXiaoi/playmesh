import 'gdevelop_web_ide_installer_contract.dart';
import 'gdevelop_web_ide_installer_stub.dart'
    if (dart.library.io) 'gdevelop_web_ide_installer_io.dart'
    as platform;

export 'gdevelop_web_ide_installer_contract.dart';

GDevelopWebIdeInstaller createGDevelopWebIdeInstaller() =>
    platform.createGDevelopWebIdeInstaller();
