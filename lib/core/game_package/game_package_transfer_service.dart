import 'dart:async';
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

class _ReplacementTransaction {
  const _ReplacementTransaction({
    required this.schemaVersion,
    required this.targetName,
    required this.oldEntries,
    required this.newEntries,
  });

  final int schemaVersion;
  final String targetName;
  final Set<String> oldEntries;
  final Set<String> newEntries;
}

class GamePackageTransferService {
  GamePackageTransferService({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  static const _packageOwnedRootEntries = [
    'app',
    'main.json',
    'capabilities.json',
    gamePackageIconName,
  ];
  static const _packageOwnedRootEntriesManifestLast = [
    'app',
    'capabilities.json',
    gamePackageIconName,
    'main.json',
  ];
  static const _importDirectoryPrefix = '.playmesh-import-';
  static const _backupDirectoryPrefix = '.playmesh-backup-';
  static const _retiredDirectoryPrefix = '.playmesh-retired-';
  static const _replacementTransactionName = 'transaction.json';
  static const _replacementPreparedName = 'prepared';
  static const _replacementCommittedName = 'committed';
  static const _replacementTransactionSchemaVersion = 2;
  static const _conflictDirectoryPrefix = '.playmesh-conflict-';
  static const _preservedDirectoryPrefix = '.playmesh-preserved-';

  static const maxCompressedBytes = SafeGamePackageArchive.maxCompressedBytes;
  static const maxExpandedBytes = SafeGamePackageArchive.maxExpandedBytes;
  static const maxSingleFileBytes = SafeGamePackageArchive.maxSingleFileBytes;
  static const maxFileCount = SafeGamePackageArchive.maxFileCount;

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;
  Future<void> _commitTail = Future<void>.value();

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
    final previous = _commitTail;
    final release = Completer<void>();
    _commitTail = release.future;
    await previous;
    try {
      await _commitPackage(package, target);
    } finally {
      release.complete();
    }
  }

  Future<void> _commitPackage(
    ValidatedGamePackage package,
    Directory target,
  ) async {
    final packages = target.parent;
    await packages.create(recursive: true);
    await _recoverInterruptedImports(packages);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final staging = Directory(
      '${packages.path}${Platform.pathSeparator}$_importDirectoryPrefix$nonce',
    );
    await staging.create(recursive: true);
    var replacing = false;
    try {
      for (final item in package.files.entries) {
        final output = File(
          '${staging.path}${Platform.pathSeparator}'
          '${item.key.replaceAll('/', Platform.pathSeparator)}',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(item.value, flush: true);
      }
      replacing = await target.exists();
      if (replacing) {
        await _replacePackageEntries(
          staging: staging,
          target: target,
          nonce: nonce,
        );
      } else {
        await staging.rename(target.path);
      }
    } on Object {
      // A replacement owns its transaction cleanup and may need the staged
      // package for recovery. A failed new install is always safe to discard.
      if (!replacing && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// 恢复未完成的发布条目事务和旧版整目录交换事务。
  Future<void> recoverInterruptedImports() async {
    final root = await _root();
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    if (!await packages.exists()) return;
    await _recoverInterruptedImports(packages);
  }

  Future<void> _replacePackageEntries({
    required Directory staging,
    required Directory target,
    required String nonce,
  }) async {
    final retired = Directory(
      '${target.parent.path}${Platform.pathSeparator}'
      '$_retiredDirectoryPrefix$nonce',
    );
    var transactionWritten = false;
    try {
      await retired.create();
      final oldEntries = await _existingPackageOwnedEntries(target);
      final newEntries = await _existingPackageOwnedEntries(staging);
      final targetName = target.path.substring(target.parent.path.length + 1);
      await File(
        '${retired.path}${Platform.pathSeparator}$_replacementTransactionName',
      ).writeAsString(
        jsonEncode({
          'schemaVersion': _replacementTransactionSchemaVersion,
          'targetName': targetName,
          'oldEntries': oldEntries.toList(),
          'newEntries': newEntries.toList(),
        }),
        flush: true,
      );
      transactionWritten = true;
      // The project root never moves or disappears. Runtime storage can keep
      // writing data while only package-owned entries are retired and installed.
      await _movePackageOwnedEntries(target, retired, manifestLast: true);
      await File(
        '${retired.path}${Platform.pathSeparator}$_replacementPreparedName',
      ).writeAsString('prepared', flush: true);
      // main.json is the visibility marker and is installed last.
      await _movePackageOwnedEntries(staging, target, manifestLast: true);
      await File(
        '${retired.path}${Platform.pathSeparator}$_replacementCommittedName',
      ).writeAsString('committed', flush: true);
    } on Object catch (error, stackTrace) {
      var restored = !transactionWritten;
      if (transactionWritten) {
        try {
          final transaction = await _readReplacementTransaction(retired);
          if (transaction == null ||
              transaction.schemaVersion !=
                  _replacementTransactionSchemaVersion) {
            throw const FormatException('应用包更新事务记录无效');
          }
          await _rollbackPackageEntryTransaction(
            staging: staging,
            target: target,
            retired: retired,
            transaction: transaction,
          );
          restored = true;
        } on Object {
          // Leave the journal, staged package and retired entries intact. A
          // later recovery pass can continue without touching non-package data.
        }
      }
      if (restored) {
        await _deleteDirectoryBestEffort(staging);
        await _deleteDirectoryBestEffort(retired);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _deleteDirectoryBestEffort(staging);
    await _deleteDirectoryBestEffort(retired);
  }

  Future<void> _movePackageOwnedEntries(
    Directory source,
    Directory destination, {
    bool manifestLast = false,
  }) async {
    await destination.create(recursive: true);
    final names = manifestLast
        ? _packageOwnedRootEntriesManifestLast
        : _packageOwnedRootEntries;
    for (final name in names) {
      await _movePackageOwnedEntry(source, destination, name);
    }
  }

  Future<bool> _movePackageOwnedEntry(
    Directory source,
    Directory destination,
    String name,
  ) async {
    await destination.create(recursive: true);
    final sourcePath = '${source.path}${Platform.pathSeparator}$name';
    final sourceType = await FileSystemEntity.type(
      sourcePath,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) return false;
    final destinationPath = '${destination.path}${Platform.pathSeparator}$name';
    if (await FileSystemEntity.type(destinationPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('更新应用包时发布文件发生冲突', destinationPath);
    }
    if (sourceType == FileSystemEntityType.file) {
      await File(sourcePath).rename(destinationPath);
    } else if (sourceType == FileSystemEntityType.directory) {
      await Directory(sourcePath).rename(destinationPath);
    } else if (sourceType == FileSystemEntityType.link) {
      await Link(sourcePath).rename(destinationPath);
    } else {
      throw FileSystemException('更新应用包时发布文件类型无效', sourcePath);
    }
    return true;
  }

  Future<void> _rollbackPackageEntryTransaction({
    required Directory staging,
    required Directory target,
    required Directory retired,
    required _ReplacementTransaction transaction,
  }) async {
    final prepared = await File(
      '${retired.path}${Platform.pathSeparator}$_replacementPreparedName',
    ).exists();
    await target.create(recursive: true);
    for (final name in _packageOwnedRootEntriesManifestLast.reversed) {
      final oldRetired =
          transaction.oldEntries.contains(name) &&
          await _entryExists(retired, name);
      final installedByTransaction =
          oldRetired ||
          (prepared &&
              !transaction.oldEntries.contains(name) &&
              transaction.newEntries.contains(name));
      if (installedByTransaction && await _entryExists(target, name)) {
        await _discardOrRestagePackageOwnedEntry(target, staging, name);
      }
    }
    for (final name in _packageOwnedRootEntriesManifestLast) {
      final oldRetired =
          transaction.oldEntries.contains(name) &&
          await _entryExists(retired, name);
      if (oldRetired) {
        await _movePackageOwnedEntry(retired, target, name);
      }
    }
  }

  Future<void> _discardOrRestagePackageOwnedEntry(
    Directory source,
    Directory staging,
    String name,
  ) async {
    if (!await _entryExists(staging, name)) {
      await _movePackageOwnedEntry(source, staging, name);
      return;
    }
    await _deleteEntry('${source.path}${Platform.pathSeparator}$name');
  }

  Future<void> _restoreLegacyBackupPackageEntries({
    required Directory staging,
    required Directory backup,
    required Directory retired,
  }) async {
    if (!await retired.exists()) return;
    final prepared = await File(
      '${retired.path}${Platform.pathSeparator}$_replacementPreparedName',
    ).exists();
    if (!prepared) {
      await _movePackageOwnedEntries(retired, backup);
      return;
    }
    final transaction = await _readReplacementTransaction(retired);
    if (transaction == null) {
      throw const FormatException('应用包更新事务记录无效');
    }
    for (final name in _packageOwnedRootEntries) {
      final oldEntryRetired = await _entryExists(retired, name);
      if (transaction.oldEntries.contains(name)) {
        if (!oldEntryRetired) continue;
        if (await _entryExists(backup, name)) {
          await _discardOrRestagePackageOwnedEntry(backup, staging, name);
        }
        await _movePackageOwnedEntry(retired, backup, name);
      } else if (await _entryExists(backup, name)) {
        await _discardOrRestagePackageOwnedEntry(backup, staging, name);
      }
    }
  }

  Future<bool> _entryExists(Directory directory, String name) async =>
      await FileSystemEntity.type(
        '${directory.path}${Platform.pathSeparator}$name',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;

  Future<void> _deleteEntry(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    }
  }

  Future<Set<String>> _existingPackageOwnedEntries(Directory directory) async {
    final result = <String>{};
    for (final name in _packageOwnedRootEntries) {
      if (await FileSystemEntity.type(
            '${directory.path}${Platform.pathSeparator}$name',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        result.add(name);
      }
    }
    return result;
  }

  Future<GameManifest> _readInstalledManifest(Directory directory) async {
    final decoded = jsonDecode(
      await File(
        '${directory.path}${Platform.pathSeparator}main.json',
      ).readAsString(),
    );
    if (decoded is! Map) {
      throw const FormatException('main.json 根节点必须是对象');
    }
    return GameManifest.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<_ReplacementTransaction?> _readReplacementTransaction(
    Directory retired,
  ) async {
    final file = File(
      '${retired.path}${Platform.pathSeparator}$_replacementTransactionName',
    );
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['targetName'] is! String) {
      return null;
    }
    final schemaVersion = decoded['schemaVersion'] is int
        ? decoded['schemaVersion'] as int
        : 1;
    final targetName = decoded['targetName'] as String;
    final rawOldEntries = decoded['oldEntries'];
    final rawNewEntries = decoded['newEntries'];
    if (targetName.isEmpty ||
        targetName == '.' ||
        targetName == '..' ||
        targetName.contains('/') ||
        targetName.contains('\\') ||
        rawOldEntries is! List ||
        rawOldEntries.any(
          (entry) =>
              entry is! String || !_packageOwnedRootEntries.contains(entry),
        ) ||
        (schemaVersion == _replacementTransactionSchemaVersion &&
            (rawNewEntries is! List ||
                rawNewEntries.any(
                  (entry) =>
                      entry is! String ||
                      !_packageOwnedRootEntries.contains(entry),
                ) ||
                !rawNewEntries.contains('app') ||
                !rawNewEntries.contains('main.json'))) ||
        (schemaVersion != 1 &&
            schemaVersion != _replacementTransactionSchemaVersion)) {
      return null;
    }
    return _ReplacementTransaction(
      schemaVersion: schemaVersion,
      targetName: targetName,
      oldEntries: rawOldEntries.cast<String>().toSet(),
      newEntries: schemaVersion == _replacementTransactionSchemaVersion
          ? (rawNewEntries as List).cast<String>().toSet()
          : const <String>{},
    );
  }

  Future<bool> _isCommittedPackageValid(
    Directory target,
    _ReplacementTransaction transaction,
  ) async {
    if (!await target.exists()) return false;
    final entries = await _existingPackageOwnedEntries(target);
    if (entries.length != transaction.newEntries.length ||
        !entries.containsAll(transaction.newEntries)) {
      return false;
    }
    try {
      return (await _readInstalledManifest(target)).id ==
          transaction.targetName;
    } on Object {
      return false;
    }
  }

  Future<void> _deleteDirectoryBestEffort(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // A visible complete package is already available. Startup recovery can
      // retry cleanup without rolling it back.
    }
  }

  Future<void> _recoverInterruptedImports(Directory packages) async {
    final backups = <Directory>[];
    final staging = <Directory>[];
    final retired = <Directory>[];
    final stagingByNonce = <String, Directory>{};
    final retiredByNonce = <String, Directory>{};
    await for (final entity in packages.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.substring(packages.path.length + 1);
      if (name.startsWith(_backupDirectoryPrefix)) {
        backups.add(entity);
      } else if (name.startsWith(_importDirectoryPrefix)) {
        staging.add(entity);
        stagingByNonce[name.substring(_importDirectoryPrefix.length)] = entity;
      } else if (name.startsWith(_retiredDirectoryPrefix)) {
        retired.add(entity);
        retiredByNonce[name.substring(_retiredDirectoryPrefix.length)] = entity;
      }
    }
    final handledRetired = <String>{};
    for (final directory in retired) {
      final name = directory.path.substring(packages.path.length + 1);
      final nonce = name.substring(_retiredDirectoryPrefix.length);
      try {
        final transaction = await _readReplacementTransaction(directory);
        if (transaction == null ||
            transaction.schemaVersion != _replacementTransactionSchemaVersion) {
          continue;
        }
        final target = Directory(
          '${packages.path}${Platform.pathSeparator}${transaction.targetName}',
        );
        final transactionStaging =
            stagingByNonce[nonce] ??
            Directory(
              '${packages.path}${Platform.pathSeparator}'
              '$_importDirectoryPrefix$nonce',
            );
        final committed = await File(
          '${directory.path}${Platform.pathSeparator}'
          '$_replacementCommittedName',
        ).exists();
        if (!committed ||
            !await _isCommittedPackageValid(target, transaction)) {
          await _rollbackPackageEntryTransaction(
            staging: transactionStaging,
            target: target,
            retired: directory,
            transaction: transaction,
          );
        }
        await _deleteDirectoryBestEffort(transactionStaging);
        await _deleteDirectoryBestEffort(directory);
        handledRetired.add(nonce);
      } on Object {
        // Keep every transaction entry for a later recovery or manual repair.
      }
    }

    backups.sort((left, right) => right.path.compareTo(left.path));
    final restoredTargets = <String>{};
    for (final backup in backups) {
      try {
        final backupName = backup.path.substring(packages.path.length + 1);
        final nonce = backupName.substring(_backupDirectoryPrefix.length);
        final matchingStaging = stagingByNonce[nonce];
        final matchingRetired = retiredByNonce[nonce];
        final transactionStaging =
            matchingStaging ??
            Directory(
              '${packages.path}${Platform.pathSeparator}'
              '$_importDirectoryPrefix$nonce',
            );
        final transaction = matchingRetired == null
            ? null
            : await _readReplacementTransaction(matchingRetired);
        late final String targetName;
        if (transaction != null) {
          targetName = transaction.targetName;
        } else {
          final oldManifestRoot =
              matchingRetired != null &&
                  await File(
                    '${matchingRetired.path}${Platform.pathSeparator}main.json',
                  ).exists()
              ? matchingRetired
              : backup;
          targetName = (await _readInstalledManifest(oldManifestRoot)).id;
        }
        if (!restoredTargets.add(targetName)) {
          await _preserveTransactionDirectory(backup, 'backup-$nonce');
          if (matchingStaging != null) {
            await _preserveTransactionDirectory(
              matchingStaging,
              'import-$nonce',
            );
          }
          if (matchingRetired != null) {
            await _preserveTransactionDirectory(
              matchingRetired,
              'retired-$nonce',
            );
          }
          continue;
        }
        if (matchingRetired != null) {
          await _restoreLegacyBackupPackageEntries(
            staging: transactionStaging,
            backup: backup,
            retired: matchingRetired,
          );
        }
        final target = Directory(
          '${packages.path}${Platform.pathSeparator}$targetName',
        );
        if (await target.exists()) {
          final conflict = await _uniqueSiblingDirectory(
            packages,
            '$_conflictDirectoryPrefix$nonce',
          );
          await target.rename(conflict.path);
        }
        await backup.rename(target.path);
        await _deleteDirectoryBestEffort(transactionStaging);
        if (matchingRetired != null) {
          await _deleteDirectoryBestEffort(matchingRetired);
        }
      } on Object {
        // 无法识别的备份保持原样，供人工恢复。
      }
    }
    for (final directory in retired) {
      if (!await directory.exists()) continue;
      final name = directory.path.substring(packages.path.length + 1);
      final nonce = name.substring(_retiredDirectoryPrefix.length);
      if (handledRetired.contains(nonce)) continue;
      try {
        final transaction = await _readReplacementTransaction(directory);
        if (transaction?.schemaVersion ==
            _replacementTransactionSchemaVersion) {
          continue;
        }
        final matchingBackup = Directory(
          '${packages.path}${Platform.pathSeparator}'
          '$_backupDirectoryPrefix$nonce',
        );
        if (await matchingBackup.exists()) continue;
        await _preserveTransactionDirectory(directory, 'retired-$nonce');
      } on Object {
        // Unrecognized retired entries stay untouched for manual recovery.
      }
    }
    for (final directory in staging) {
      if (!await directory.exists()) continue;
      final name = directory.path.substring(packages.path.length + 1);
      final nonce = name.substring(_importDirectoryPrefix.length);
      final matchingBackup = Directory(
        '${packages.path}${Platform.pathSeparator}'
        '$_backupDirectoryPrefix$nonce',
      );
      final matchingRetired = Directory(
        '${packages.path}${Platform.pathSeparator}'
        '$_retiredDirectoryPrefix$nonce',
      );
      if (await matchingBackup.exists() || await matchingRetired.exists()) {
        continue;
      }
      await _deleteDirectoryBestEffort(directory);
    }
  }

  Future<Directory> _uniqueSiblingDirectory(
    Directory parent,
    String preferredName,
  ) async {
    var candidate = Directory(
      '${parent.path}${Platform.pathSeparator}$preferredName',
    );
    var suffix = 0;
    while (await candidate.exists()) {
      suffix += 1;
      candidate = Directory(
        '${parent.path}${Platform.pathSeparator}$preferredName-$suffix',
      );
    }
    return candidate;
  }

  Future<void> _preserveTransactionDirectory(
    Directory directory,
    String label,
  ) async {
    if (!await directory.exists()) return;
    final destination = await _uniqueSiblingDirectory(
      directory.parent,
      '$_preservedDirectoryPrefix$label',
    );
    await directory.rename(destination.path);
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
