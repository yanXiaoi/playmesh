import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_summary.dart';
import '../library/playmesh_library_root.dart';
import 'file_game_library_scanner.dart';

class GamePackageTransferService {
  GamePackageTransferService({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  static const maxCompressedBytes = 64 * 1024 * 1024;
  static const maxExpandedBytes = 256 * 1024 * 1024;
  static const maxSingleFileBytes = 32 * 1024 * 1024;
  static const maxFileCount = 4096;

  static const _blockedExtensions = {
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.bat',
    '.cmd',
    '.com',
    '.msi',
    '.ps1',
    '.sh',
  };

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<GameSummary> importPackage(File source) async {
    if (!await source.exists()) throw StateError('找不到游戏包文件');
    final compressedSize = await source.length();
    if (compressedSize <= 0 || compressedSize > maxCompressedBytes) {
      throw const FormatException('游戏包压缩文件大小必须在 1 B 至 64 MiB 之间');
    }
    final archive = ZipDecoder().decodeBytes(
      await source.readAsBytes(),
      verify: true,
    );
    final files = <String, ArchiveFile>{};
    var expandedBytes = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw FormatException('游戏包不允许符号链接：${entry.name}');
      }
      final path = _safeArchivePath(entry.name);
      if (path == null || !entry.isFile) continue;
      if (files.containsKey(path)) throw FormatException('游戏包包含重复路径：$path');
      if (entry.size > maxSingleFileBytes) {
        throw FormatException('单个文件超过 32 MiB：$path');
      }
      expandedBytes += entry.size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('游戏包解压后不能超过 256 MiB');
      }
      if (files.length >= maxFileCount) {
        throw const FormatException('游戏包文件数量不能超过 4096');
      }
      _validatePackagePath(path);
      files[path] = entry;
    }
    final manifestEntry = files['main.json'];
    if (manifestEntry == null) {
      throw const FormatException('Playmesh 游戏包根目录必须存在 main.json');
    }
    if (!files.keys.any((path) => path.startsWith('app/'))) {
      throw const FormatException('Playmesh 游戏包根目录必须存在 app/');
    }
    final manifest = _readManifest(manifestEntry);
    if (files['capabilities.json'] case final capabilitiesEntry?) {
      _readCapabilities(capabilitiesEntry);
    }
    _validateRequiredFiles(manifest, files.keys.toSet());

    final root = await _root();
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    await packages.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final staging = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-import-$nonce',
    );
    final target = Directory(
      '${packages.path}${Platform.pathSeparator}${manifest.id}',
    );
    final backup = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-backup-$nonce',
    );
    await staging.create(recursive: true);
    try {
      for (final item in files.entries) {
        final output = File(
          '${staging.path}${Platform.pathSeparator}'
          '${item.key.replaceAll('/', Platform.pathSeparator)}',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(item.value.content as List<int>, flush: true);
      }
      final replacing = await target.exists();
      if (replacing) {
        await _replacePublishedFiles(
          staging: staging,
          target: target,
          backup: backup,
        );
      } else {
        await staging.rename(target.path);
      }
      return FileGameLibraryScanner(libraryRoot: root).loadPackage(target);
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _replacePublishedFiles({
    required Directory staging,
    required Directory target,
    required Directory backup,
  }) async {
    await backup.create(recursive: true);
    const names = ['main.json', 'capabilities.json', 'app'];
    try {
      for (final name in names) {
        await _moveIfPresent(target, backup, name);
      }
      for (final name in names) {
        await _moveIfPresent(staging, target, name);
      }
      await staging.delete(recursive: true);
      await backup.delete(recursive: true);
    } on Object {
      // 发布文件作为一个事务回滚；data、cache 和其他运行目录始终留在原目标中。
      for (final name in names) {
        await _deleteIfPresent(target, name);
      }
      for (final name in names) {
        await _moveIfPresent(backup, target, name);
      }
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await backup.exists()) await backup.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _moveIfPresent(
    Directory sourceRoot,
    Directory destinationRoot,
    String name,
  ) async {
    final sourceFile = File('${sourceRoot.path}${Platform.pathSeparator}$name');
    final sourceDirectory = Directory(sourceFile.path);
    final destination = '${destinationRoot.path}${Platform.pathSeparator}$name';
    if (await sourceFile.exists()) {
      await destinationRoot.create(recursive: true);
      await sourceFile.rename(destination);
    } else if (await sourceDirectory.exists()) {
      await destinationRoot.create(recursive: true);
      await sourceDirectory.rename(destination);
    }
  }

  Future<void> _deleteIfPresent(Directory root, String name) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final directory = Directory(file.path);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<File> exportPackage(GameSummary game, File destination) async {
    final packagePath = game.entry.packageRootFilePath;
    if (packagePath == null) throw StateError('内置游戏不能导出为本地游戏包');
    final root = await _root();
    final expected = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}${game.id}',
    ).absolute.path.toLowerCase();
    final package = Directory(packagePath);
    if (package.absolute.path.toLowerCase() != expected) {
      throw StateError('游戏包目录不在 Playmesh 游戏库中');
    }
    final manifest = File('${package.path}${Platform.pathSeparator}main.json');
    final app = Directory('${package.path}${Platform.pathSeparator}app');
    if (!await manifest.exists() || !await app.exists()) {
      throw const FormatException('游戏包根目录必须包含 main.json 和 app/');
    }
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'main.json',
          await manifest.length(),
          await manifest.readAsBytes(),
        ),
      );
    var expandedBytes = await manifest.length();
    var fileCount = 1;
    final capabilities = File(
      '${package.path}${Platform.pathSeparator}capabilities.json',
    );
    if (await capabilities.exists()) {
      final bytes = await capabilities.readAsBytes();
      GameCapabilities.fromJson(
        Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map),
      );
      archive.addFile(ArchiveFile('capabilities.json', bytes.length, bytes));
      expandedBytes += bytes.length;
      fileCount += 1;
    }
    await for (final entity in app.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw const FormatException('游戏包不允许符号链接');
      if (entity is! File) continue;
      final size = await entity.length();
      if (size > maxSingleFileBytes) {
        throw FormatException('单个文件超过 32 MiB：${entity.path}');
      }
      expandedBytes += size;
      fileCount += 1;
      if (expandedBytes > maxExpandedBytes || fileCount > maxFileCount) {
        throw const FormatException('游戏包超过导出限制');
      }
      final relative = entity.path
          .substring(package.path.length + 1)
          .replaceAll('\\', '/');
      _validatePackagePath(relative);
      archive.addFile(ArchiveFile(relative, size, await entity.readAsBytes()));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw StateError('游戏包压缩失败');
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(encoded, flush: true);
    return destination;
  }

  GameManifest _readManifest(ArchiveFile file) {
    final decoded = jsonDecode(utf8.decode(file.content as List<int>));
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    return GameManifest.fromJson(Map<String, Object?>.from(decoded));
  }

  GameCapabilities _readCapabilities(ArchiveFile file) {
    final decoded = jsonDecode(utf8.decode(file.content as List<int>));
    if (decoded is! Map) {
      throw const FormatException('capabilities.json 根节点必须是对象');
    }
    return GameCapabilities.fromJson(Map<String, Object?>.from(decoded));
  }

  void _validateRequiredFiles(GameManifest manifest, Set<String> paths) {
    final required = <String>{'main.json', manifest.entries.game};
    if (manifest.displayModes.contains(
      GameDisplayMode.singleScreenMultiplayer,
    )) {
      required.add(manifest.entries.controller);
    }
    if (manifest.authority case final authority?) required.add(authority.entry);
    for (final path in required) {
      if (!paths.contains(path)) throw FormatException('游戏包缺少 $path');
    }
  }

  String? _safeArchivePath(String raw) {
    final normalized = raw.replaceAll('\\', '/');
    if (normalized.endsWith('/')) return null;
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('游戏包包含非法路径：$raw');
    }
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('游戏包包含目录穿越路径：$raw');
    }
    return parts.join('/');
  }

  void _validatePackagePath(String path) {
    if (path != 'main.json' &&
        path != 'capabilities.json' &&
        !path.startsWith('app/')) {
      throw FormatException(
        '游戏包只允许包含根 main.json、capabilities.json 和 app/：$path',
      );
    }
    final lower = path.toLowerCase();
    if (_blockedExtensions.any(lower.endsWith)) {
      throw FormatException('游戏包包含禁止文件类型：$path');
    }
  }

  Future<Directory> _root() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    await root.create(recursive: true);
    return _resolvedRoot = root;
  }
}
