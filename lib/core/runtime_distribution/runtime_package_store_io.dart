import 'dart:io';

import '../library/playmesh_library_root.dart';
import 'runtime_package_models.dart';
import 'runtime_package_store_contract.dart';

typedef RuntimePackageLibraryRootResolver = Future<Directory> Function();

final class FileRuntimePackageStore implements RuntimePackageStore {
  FileRuntimePackageStore({
    RuntimePackageLibraryRootResolver? libraryRootResolver,
  }) : _libraryRootResolver =
           libraryRootResolver ?? (() => PlaymeshLibraryRoot.resolve());

  final RuntimePackageLibraryRootResolver _libraryRootResolver;
  Directory? _runtimeRoot;

  @override
  Future<RuntimePackageStatus> inspect(RuntimePackageTarget target) async {
    final file = await _installedFile(target);
    await _recoverInterruptedCommit(file);
    final installed = await file.exists();
    return RuntimePackageStatus(
      target: target,
      filePath: file.path,
      installed: installed,
      sizeBytes: installed ? await file.length() : null,
    );
  }

  @override
  Future<List<RuntimePackageStatus>> inspectAll() async => [
    for (final target in RuntimePackageTarget.values) await inspect(target),
  ];

  @override
  Future<String> installedFilePath(RuntimePackageTarget target) async =>
      (await _installedFile(target)).path;

  @override
  Future<String> downloadDirectoryPath(RuntimePackageTarget target) async {
    final root = await _root();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}downloads'
      '${Platform.pathSeparator}${target.id}',
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<RuntimePackageStatus> commitTemporaryFile({
    required RuntimePackageTarget target,
    required String temporaryFilePath,
  }) async {
    final temporary = File(temporaryFilePath).absolute;
    if (!await temporary.exists()) {
      throw const FileSystemException(
        'Runtime package temporary file does not exist',
      );
    }
    final destination = await _installedFile(target);
    if (_samePath(temporary.path, destination.absolute.path)) {
      throw const FileSystemException(
        'Runtime package temporary and destination paths must differ',
      );
    }
    final expectedDownloadDirectory = Directory(
      await downloadDirectoryPath(target),
    ).absolute;
    if (!_samePath(
      temporary.parent.absolute.path,
      expectedDownloadDirectory.path,
    )) {
      throw const FileSystemException(
        'Runtime package temporary file is outside its target download directory',
      );
    }
    await _recoverInterruptedCommit(destination);
    final backup = File('${destination.path}.backup');
    var oldMoved = false;
    var newMoved = false;
    try {
      if (await destination.exists()) {
        if (await backup.exists()) await backup.delete();
        await destination.rename(backup.path);
        oldMoved = true;
      }
      await temporary.rename(destination.path);
      newMoved = true;
    } on Object {
      if (!newMoved && oldMoved && await backup.exists()) {
        if (await destination.exists()) await destination.delete();
        await backup.rename(destination.path);
      }
      rethrow;
    }
    if (newMoved && await backup.exists()) {
      try {
        await backup.delete();
      } on Object {
        // The installed file is already committed. The next inspection removes
        // the stale backup without changing the installed-state definition.
      }
    }
    return inspect(target);
  }

  Future<Directory> _root() async {
    final cached = _runtimeRoot;
    if (cached != null) return cached;
    final library = (await _libraryRootResolver()).absolute;
    final root = Directory('${library.path}${Platform.pathSeparator}runtime');
    await Directory(
      '${root.path}${Platform.pathSeparator}packages',
    ).create(recursive: true);
    _runtimeRoot = root;
    return root;
  }

  Future<File> _installedFile(RuntimePackageTarget target) async {
    final root = await _root();
    return File(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}${target.fileName}',
    );
  }

  Future<void> _recoverInterruptedCommit(File destination) async {
    final backup = File('${destination.path}.backup');
    if (!await backup.exists()) return;
    if (await destination.exists()) {
      await backup.delete();
      return;
    }
    await backup.rename(destination.path);
  }

  static bool _samePath(String left, String right) => Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}
