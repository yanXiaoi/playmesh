import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_package_layout.dart';
import '../../models/game_summary.dart';
import '../library/playmesh_library_root.dart';
import 'file_game_library_scanner.dart';
import 'game_package_icon.dart';
import 'safe_game_package_archive.dart';

class ValidatedGamePackage {
  const ValidatedGamePackage({required this.manifest, required this.files});

  final GameManifest manifest;
  final Map<String, List<int>> files;
}

class GamePackageTransferService {
  GamePackageTransferService({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  static const maxCompressedBytes = SafeGamePackageArchive.maxCompressedBytes;
  static const maxExpandedBytes = SafeGamePackageArchive.maxExpandedBytes;
  static const maxSingleFileBytes = SafeGamePackageArchive.maxSingleFileBytes;
  static const maxFileCount = SafeGamePackageArchive.maxFileCount;

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<GameSummary> importPackage(
    File source, {
    String? author,
    DateTime? lastModifiedAt,
    String? expectedGameId,
    String? expectedVersion,
    String? expectedPublisher,
  }) async {
    final package = await readPackage(
      source,
      author: author,
      lastModifiedAt: lastModifiedAt,
    );
    if (expectedGameId != null && package.manifest.id != expectedGameId) {
      throw const FormatException('下载包 gameId 与 Catalog offer 不一致');
    }
    if (expectedVersion != null &&
        package.manifest.version != expectedVersion) {
      throw const FormatException('下载包版本与 Catalog offer 不一致');
    }
    if (expectedPublisher != null &&
        package.manifest.author.trim() != expectedPublisher.trim()) {
      throw const FormatException('下载包发布者与 Catalog offer 不一致');
    }
    final root = await _root();
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    await packages.create(recursive: true);
    await _recoverInterruptedImports(packages);
    final target = Directory(
      '${packages.path}${Platform.pathSeparator}${package.manifest.id}',
    );
    await commitPackage(package, target);
    return FileGameLibraryScanner(libraryRoot: root).loadPackage(target);
  }

  Future<ValidatedGamePackage> readPackage(
    File source, {
    String? author,
    DateTime? lastModifiedAt,
  }) async {
    return validatePackageFiles(
      await SafeGamePackageArchive.read(source),
      author: author,
      lastModifiedAt: lastModifiedAt,
    );
  }

  ValidatedGamePackage validatePackageFiles(
    Map<String, List<int>> sourceFiles, {
    String? author,
    DateTime? lastModifiedAt,
  }) {
    final files = <String, List<int>>{};
    for (final item in sourceFiles.entries) {
      final path = SafeGamePackageArchive.normalizePath(item.key);
      if (path == null) {
        throw FormatException('游戏包文件路径不能以目录分隔符结尾：${item.key}');
      }
      _validatePackagePath(path);
      if (files.containsKey(path)) {
        throw FormatException('游戏包包含重复路径：$path');
      }
      files[path] = item.value;
    }
    final manifestEntry = files['main.json'];
    if (manifestEntry == null) {
      throw const FormatException('Playmesh 游戏包根目录必须存在 main.json');
    }
    if (!files.keys.any((path) => path.startsWith('app/'))) {
      throw const FormatException('Playmesh 游戏包根目录必须存在 app/');
    }
    final manifestJson = _readManifestJson(manifestEntry);
    if (author != null || lastModifiedAt != null) {
      final normalizedAuthor = author?.trim() ?? '';
      if (normalizedAuthor.isEmpty || lastModifiedAt == null) {
        throw const FormatException('发布项目必须同时提供发布者和最后修改时间');
      }
      manifestJson
        ..['author'] = normalizedAuthor
        ..['lastModifiedAt'] = lastModifiedAt.toUtc().millisecondsSinceEpoch;
    }
    final manifest = GameManifest.fromJson(manifestJson);
    if (files['capabilities.json'] case final capabilitiesEntry?) {
      final capabilities = _readCapabilities(capabilitiesEntry);
      if (!manifest.displayModes.contains(
            GameDisplayMode.singleScreenMultiplayer,
          ) &&
          capabilities.controllerRequired.isNotEmpty) {
        throw const FormatException('仅单屏多人游戏可以声明 controllerRequired');
      }
    }
    _validateRequiredFiles(manifest, files.keys.toSet());
    if (files[gamePackageIconName] case final iconEntry?) {
      if (!isSafeGamePackageIconBytes(
        iconEntry,
        totalLength: iconEntry.length,
      )) {
        files.remove(gamePackageIconName);
      }
    }
    final normalizedFiles = <String, List<int>>{
      for (final item in files.entries)
        item.key: item.key == 'main.json'
            ? utf8.encode(
                '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
              )
            : item.value,
    };
    return ValidatedGamePackage(
      manifest: manifest,
      files: Map.unmodifiable(normalizedFiles),
    );
  }

  Future<void> commitPackage(
    ValidatedGamePackage package,
    Directory target,
  ) async {
    final packages = target.parent;
    await packages.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final staging = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-import-$nonce',
    );
    final backup = Directory(
      '${packages.path}${Platform.pathSeparator}.playmesh-backup-$nonce',
    );
    await staging.create(recursive: true);
    try {
      for (final item in package.files.entries) {
        final output = File(
          '${staging.path}${Platform.pathSeparator}'
          '${item.key.replaceAll('/', Platform.pathSeparator)}',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(item.value, flush: true);
      }
      final replacing = await target.exists();
      if (replacing) {
        await _replacePackageDirectory(
          staging: staging,
          target: target,
          backup: backup,
        );
      } else {
        await staging.rename(target.path);
      }
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  /// 若上次进程停在 [commitPackage] 的两次同卷目录重命名之间，则恢复最后一个完整包。
  Future<void> recoverInterruptedImports() async {
    final root = await _root();
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    if (!await packages.exists()) return;
    await _recoverInterruptedImports(packages);
  }

  Future<void> _replacePackageDirectory({
    required Directory staging,
    required Directory target,
    required Directory backup,
  }) async {
    await _copyPreservedEntries(target, staging);
    await target.rename(backup.path);
    try {
      await staging.rename(target.path);
    } on Object {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    try {
      await backup.delete(recursive: true);
    } on FileSystemException {
      // 完整的新目标已可见；启动恢复只删除陈旧备份，不能冒险回滚已提交包。
    }
  }

  Future<void> _copyPreservedEntries(
    Directory target,
    Directory staging,
  ) async {
    for (final name in const ['data', 'cache']) {
      final source = Directory('${target.path}${Platform.pathSeparator}$name');
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await _copyPreservedDirectory(
        source,
        Directory('${staging.path}${Platform.pathSeparator}$name'),
      );
    }
  }

  Future<void> _copyPreservedDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final child in source.list(followLinks: false)) {
      final name = child.path.substring(source.path.length + 1);
      final targetPath = '${destination.path}${Platform.pathSeparator}$name';
      if (child is File) {
        await File(targetPath).parent.create(recursive: true);
        await child.copy(targetPath);
      } else if (child is Directory) {
        await _copyPreservedDirectory(child, Directory(targetPath));
      }
    }
  }

  Future<void> _recoverInterruptedImports(Directory packages) async {
    final backups = <Directory>[];
    final staging = <Directory>[];
    await for (final entity in packages.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.substring(packages.path.length + 1);
      if (name.startsWith('.playmesh-backup-')) {
        backups.add(entity);
      } else if (name.startsWith('.playmesh-import-')) {
        staging.add(entity);
      }
    }
    backups.sort((left, right) => right.path.compareTo(left.path));
    for (final backup in backups) {
      try {
        final manifestFile = File(
          '${backup.path}${Platform.pathSeparator}main.json',
        );
        final decoded = jsonDecode(await manifestFile.readAsString());
        if (decoded is! Map) continue;
        final manifest = GameManifest.fromJson(
          Map<String, Object?>.from(decoded),
        );
        final target = Directory(
          '${packages.path}${Platform.pathSeparator}${manifest.id}',
        );
        if (await target.exists()) {
          await backup.delete(recursive: true);
        } else {
          await backup.rename(target.path);
        }
      } on Object {
        // 无法识别的备份保持原样，供人工恢复。
      }
    }
    for (final directory in staging) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  Future<File> exportPackage(
    GameSummary game,
    File destination, {
    bool validate = true,
  }) async {
    final packagePath = game.entry.packageRootFilePath;
    if (packagePath == null) throw StateError('游戏缺少已安装包目录，无法导出');
    final root = await _root();
    final packagesDirectory = Directory(
      '${root.path}${Platform.pathSeparator}packages',
    );
    final packagesRoot = packagesDirectory.absolute.path.toLowerCase();
    final expected = Directory(
      '${packagesDirectory.path}${Platform.pathSeparator}${game.id}',
    ).absolute.path.toLowerCase();
    final package = Directory(packagePath);
    final actual = package.absolute.path.toLowerCase();
    final insidePackages =
        actual.startsWith('$packagesRoot${Platform.pathSeparator}') &&
        !actual
            .substring(packagesRoot.length + 1)
            .contains(Platform.pathSeparator);
    if ((validate && actual != expected) || (!validate && !insidePackages)) {
      throw StateError('游戏包目录不在 Playmesh 游戏库中');
    }
    final manifest = File('${package.path}${Platform.pathSeparator}main.json');
    final app = Directory('${package.path}${Platform.pathSeparator}app');
    if (!await manifest.exists() || (validate && !await app.exists())) {
      throw const FormatException('游戏包根目录必须包含 main.json 和 app/');
    }
    final manifestSize = await manifest.length();
    if (manifestSize > maxSingleFileBytes) {
      throw const FormatException('main.json 超过单文件限制');
    }
    List<int>? normalizedManifestBytes;
    var archiveManifestSize = manifestSize;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map) {
        if (validate) {
          throw const FormatException('main.json 根节点必须是对象');
        }
      } else {
        final input = decoded.map<String, Object?>(
          (key, value) => MapEntry(key.toString(), value),
        );
        final normalized = validate
            ? GameManifest.fromJson(input).toJson()
            : projectGameManifestJson(input);
        normalizedManifestBytes = utf8.encode(
          '${const JsonEncoder.withIndent('  ').convert(normalized)}\n',
        );
        archiveManifestSize = normalizedManifestBytes.length;
      }
    } on FormatException {
      if (validate) rethrow;
    }
    if (archiveManifestSize > maxSingleFileBytes) {
      throw const FormatException('main.json 超过单文件限制');
    }
    final files = <(File, String)>[];
    var expandedBytes = archiveManifestSize;
    var fileCount = 1;
    final capabilities = File(
      '${package.path}${Platform.pathSeparator}capabilities.json',
    );
    if (await capabilities.exists()) {
      final capabilitySize = await capabilities.length();
      if (capabilitySize > maxSingleFileBytes) {
        throw const FormatException('capabilities.json 超过单文件限制');
      }
      final bytes = await capabilities.readAsBytes();
      if (validate) {
        GameCapabilities.fromJson(
          Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map),
        );
      }
      files.add((capabilities, 'capabilities.json'));
      expandedBytes += bytes.length;
      fileCount += 1;
    }
    final icon = File(
      '${package.path}${Platform.pathSeparator}$gamePackageIconName',
    );
    if (await isSafeGamePackageIcon(icon)) {
      files.add((icon, gamePackageIconName));
      expandedBytes += await icon.length();
      fileCount += 1;
    }
    if (expandedBytes > maxExpandedBytes || fileCount > maxFileCount) {
      throw const FormatException('游戏包超过导出限制');
    }
    if (await app.exists()) {
      await for (final entity in app.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) {
          throw const FormatException('游戏包不允许符号链接');
        }
        if (entity is! File) continue;
        final size = await entity.length();
        if (size > maxSingleFileBytes) {
          throw FormatException('单个文件超过 128 MiB：${entity.path}');
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
        files.add((entity, relative));
      }
    }
    await destination.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      encoder.create(destination.path);
      opened = true;
      if (normalizedManifestBytes case final normalized?) {
        encoder.addArchiveFile(
          ArchiveFile('main.json', normalized.length, normalized),
        );
      } else {
        await encoder.addFile(manifest, 'main.json');
      }
      for (final item in files) {
        await encoder.addFile(item.$1, item.$2);
      }
      await encoder.close();
      opened = false;
    } on Object {
      if (opened) {
        try {
          await encoder.close();
        } on Object {
          // 保留原始导出错误。
        }
      }
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
    return destination;
  }

  Map<String, Object?> _readManifestJson(List<int> file) {
    final decoded = jsonDecode(utf8.decode(file));
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    return Map<String, Object?>.from(decoded);
  }

  GameCapabilities _readCapabilities(List<int> file) {
    final decoded = jsonDecode(utf8.decode(file));
    if (decoded is! Map) {
      throw const FormatException('capabilities.json 根节点必须是对象');
    }
    return GameCapabilities.fromJson(Map<String, Object?>.from(decoded));
  }

  void _validateRequiredFiles(GameManifest manifest, Set<String> paths) {
    final gameEntry = playmeshGamePackageLayout.parseWebEntry(
      manifest.entries.game,
      field: 'entries.game',
      kind: GameWebEntryKind.html,
    );
    final required = <String>{
      'main.json',
      playmeshGamePackageLayout.packagePathForWebPath(gameEntry.path),
    };
    if (manifest.displayModes.contains(
      GameDisplayMode.singleScreenMultiplayer,
    )) {
      final controllerEntry = playmeshGamePackageLayout.parseWebEntry(
        manifest.entries.controller!,
        field: 'entries.controller',
        kind: GameWebEntryKind.html,
      );
      required.add(
        playmeshGamePackageLayout.packagePathForWebPath(controllerEntry.path),
      );
    }
    if (manifest.authority case final authority?) {
      final authorityEntry = playmeshGamePackageLayout.parseWebEntry(
        authority.entry,
        field: 'authority.entry',
        kind: GameWebEntryKind.javaScript,
      );
      required.add(
        playmeshGamePackageLayout.packagePathForWebPath(authorityEntry.path),
      );
    }
    for (final path in required) {
      if (!paths.contains(path)) throw FormatException('游戏包缺少 $path');
    }
  }

  void _validatePackagePath(String path) {
    playmeshGamePackageLayout.validatePackagePath(path, field: '游戏包路径');
    if (path != 'main.json' &&
        path != 'capabilities.json' &&
        path != gamePackageIconName &&
        !path.startsWith('app/')) {
      throw FormatException(
        '游戏包只允许包含根 main.json、icon.png、capabilities.json 和 app/：$path',
      );
    }
    SafeGamePackageArchive.validateAllowedExtension(path);
  }

  Future<Directory> _root() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    await root.create(recursive: true);
    return _resolvedRoot = root;
  }
}
