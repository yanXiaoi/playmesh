import 'dart:io';
import 'dart:math';

import '../../models/game_summary.dart';

String gamePackageFileName({required String name, required String version}) {
  final safeName = _packageFileNameComponent(
    name,
    fallback: 'game',
    maxRunes: 80,
  );
  final safeVersion = _packageFileNameComponent(
    version,
    fallback: 'unknown',
    maxRunes: 64,
  );
  return '$safeName-v$safeVersion.zip';
}

String gamePackageShareFileName(GameSummary game) =>
    gamePackageFileName(name: game.name, version: game.version);

String _packageFileNameComponent(
  String value, {
  required String fallback,
  required int maxRunes,
}) {
  var safe = value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) safe = fallback;
  if (safe.runes.length > maxRunes) {
    safe = String.fromCharCodes(safe.runes.take(maxRunes));
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
  }
  return safe.isEmpty ? fallback : safe;
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
      final normalized = _normalizedAbsolutePath(resolved);
      if (_active.contains(normalized) ||
          entity is Directory &&
              _active.any(
                (path) =>
                    path.startsWith('$normalized${Platform.pathSeparator}'),
              )) {
        continue;
      }
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
    final leaseDirectory = Directory(
      '${root.path}${Platform.pathSeparator}$nonce',
    ).absolute;
    await leaseDirectory.create();
    final file = File(
      '${leaseDirectory.path}${Platform.pathSeparator}'
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
    final parent = file.parent.absolute;
    if (_normalizedAbsolutePath(parent.parent.path) ==
            _normalizedAbsolutePath(root) &&
        await parent.exists() &&
        await parent.list(followLinks: false).isEmpty) {
      await parent.delete();
    }
  }

  /// 标记分享使用方已经结束。能保证消费完成的平台应请求立即删除；其他平台释放租约，
  /// 由下次创建或清理操作删除文件。
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
