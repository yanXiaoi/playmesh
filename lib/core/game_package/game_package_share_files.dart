import 'dart:io';
import 'dart:math';

import '../../models/game_summary.dart';

String gamePackageShareFileName(GameSummary game) {
  var name = game.name
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'game';
  if (name.runes.length > 80) {
    name = String.fromCharCodes(name.runes.take(80));
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
  }
  if (name.isEmpty) name = 'game';
  return '$name-v${game.version}.zip';
}

final class GamePackageShareFiles {
  GamePackageShareFiles({Directory? temporaryRoot, Random? random})
    : _temporaryRoot = temporaryRoot ?? Directory.systemTemp,
      _random = random ?? Random.secure();

  final Directory _temporaryRoot;
  final Random _random;
  final Set<String> _active = {};

  Directory get directory => Directory(
    '${_temporaryRoot.path}${Platform.pathSeparator}playmesh-game-shares',
  );

  Future<void> cleanup() async {
    final root = directory.absolute;
    if (!await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      final resolved = entity.absolute.path;
      if (!_isInside(root.path, resolved)) {
        throw StateError('拒绝清理分享目录外路径：$resolved');
      }
      if (_active.contains(_normalizedAbsolutePath(resolved))) continue;
      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      } else if (entity is Link) {
        await entity.delete();
      }
    }
  }

  Future<File> create(GameSummary game) async {
    await cleanup();
    final root = directory.absolute;
    await root.create(recursive: true);
    final nonce =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '${_random.nextInt(1 << 32)}';
    final file = File(
      '${root.path}${Platform.pathSeparator}$nonce-'
      '${gamePackageShareFileName(game)}',
    ).absolute;
    if (!_isInside(root.path, file.path)) {
      throw StateError('分享文件路径逃逸临时目录');
    }
    _active.add(_normalizedAbsolutePath(file.path));
    return file;
  }

  Future<void> delete(File file) async {
    final root = directory.absolute.path;
    final target = file.absolute.path;
    if (!_isInside(root, target)) {
      throw StateError('拒绝删除分享目录外文件');
    }
    _active.remove(_normalizedAbsolutePath(target));
    if (await file.exists()) await file.delete();
  }

  /// Marks a share consumer as finished. Platforms that can guarantee
  /// consumption should request immediate deletion; other platforms release
  /// the lease so the next create/cleanup removes it.
  Future<void> complete(File file, {required bool deleteNow}) async {
    final target = file.absolute.path;
    _active.remove(_normalizedAbsolutePath(target));
    if (deleteNow) await delete(file);
  }

  bool _isInside(String root, String target) {
    final normalizedRoot = _normalizedAbsolutePath(root);
    final normalizedTarget = _normalizedAbsolutePath(target);
    return normalizedTarget.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  }

  String _normalizedAbsolutePath(String value) {
    final normalized = Uri.file(
      File(value).absolute.path,
      windows: Platform.isWindows,
    ).normalizePath().toFilePath(windows: Platform.isWindows);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
