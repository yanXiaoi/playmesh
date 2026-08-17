import 'dart:io';
import 'dart:typed_data';

import '../library/playmesh_library_root.dart';
import 'gdevelop_web_ide_installer.dart';
import 'gdevelop_web_ide_source_contract.dart';

GDevelopWebIdeSource createGDevelopWebIdeSource() => FileGDevelopWebIdeSource();

class FileGDevelopWebIdeSource implements GDevelopWebIdeSource {
  FileGDevelopWebIdeSource({
    Directory? root,
    GDevelopWebIdeInstaller? installer,
  }) : _injectedRoot = root,
       _installer = installer ?? createGDevelopWebIdeInstaller();

  final Directory? _injectedRoot;
  final GDevelopWebIdeInstaller _installer;
  bool? _available;

  Future<Directory> _root() async {
    final injected = _injectedRoot;
    if (injected != null) return injected;
    final libraryRoot = await PlaymeshLibraryRoot.resolve();
    return Directory(
      '${libraryRoot.path}${Platform.pathSeparator}GDevelop'
      '${Platform.pathSeparator}official',
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final root = await _root();
      final inspection = await _installer.inspect(
        gdevelopRootPath: root.parent.path,
      );
      return _available =
          inspection.state == GDevelopWebIdeInstallationState.ready;
    } on Object {
      // WebIDE 是开发者入口的软依赖；恢复或身份检查失败不能阻断开发者模式。
      return _available = false;
    }
  }

  @override
  Future<Uint8List?> read(String relativePath) async {
    final segments = Uri(path: relativePath).pathSegments;
    if (segments.isEmpty ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      return null;
    }
    // 每次页面导航重新验证 marker；其余静态资源复用本次页面已确认的身份。
    if ((relativePath == 'index.html' || _available != true) &&
        !await isAvailable()) {
      return null;
    }
    final root = await _root();
    if (!await root.exists()) return null;
    final file = File([root.path, ...segments].join(Platform.pathSeparator));
    if (!await file.exists()) return null;

    // 下载的 Web IDE 允许包含普通目录，但不能借符号链接读出安装根。
    final canonicalRoot = await root.resolveSymbolicLinks();
    final canonicalFile = await file.resolveSymbolicLinks();
    final comparisonRoot = Platform.isWindows
        ? canonicalRoot.toLowerCase()
        : canonicalRoot;
    final comparisonFile = Platform.isWindows
        ? canonicalFile.toLowerCase()
        : canonicalFile;
    final rootPrefix = comparisonRoot.endsWith(Platform.pathSeparator)
        ? comparisonRoot
        : '$comparisonRoot${Platform.pathSeparator}';
    if (!comparisonFile.startsWith(rootPrefix)) return null;
    return file.readAsBytes();
  }
}
