import 'dart:io';

import 'package:archive/archive.dart';

import '../../models/game_package_layout.dart';

class SafeGamePackageArchive {
  const SafeGamePackageArchive._();

  static const maxCompressedBytes = 100 * 1024 * 1024;
  static const maxExpandedBytes = 512 * 1024 * 1024;
  static const maxSingleFileBytes = 128 * 1024 * 1024;
  static const maxFileCount = 8000;

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

  static Future<Map<String, List<int>>> read(File source) async {
    if (!await source.exists()) throw StateError('找不到游戏包文件');
    final compressedSize = await source.length();
    if (compressedSize <= 0 || compressedSize > maxCompressedBytes) {
      throw const FormatException('游戏包压缩文件大小必须在 1 B 至 100 MiB 之间');
    }
    final archive = ZipDecoder().decodeBytes(
      await source.readAsBytes(),
      verify: true,
    );
    final files = <String, List<int>>{};
    var expandedBytes = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw FormatException('游戏包不允许符号链接：${entry.name}');
      }
      final path = normalizePath(entry.name);
      if (path == null || !entry.isFile) continue;
      if (files.containsKey(path)) throw FormatException('游戏包包含重复路径：$path');
      if (entry.size > maxSingleFileBytes) {
        throw FormatException('单个文件超过 128 MiB：$path');
      }
      expandedBytes += entry.size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('游戏包解压后不能超过 512 MiB');
      }
      if (files.length >= maxFileCount) {
        throw const FormatException('游戏包文件数量不能超过 8000');
      }
      validateAllowedExtension(path);
      files[path] = List<int>.from(entry.content as List<int>);
    }
    return Map.unmodifiable(files);
  }

  static String? normalizePath(String raw) {
    final normalized = raw.replaceAll('\\', '/');
    final isDirectory = normalized.endsWith('/');
    final path = isDirectory
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (path.isEmpty ||
        path.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw FormatException('游戏包包含非法路径：$raw');
    }
    final parts = path.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('游戏包包含目录穿越路径：$raw');
    }
    final validated = playmeshGamePackageLayout.validateRelativePath(
      parts.join('/'),
      field: '游戏包路径',
    );
    return isDirectory ? null : validated;
  }

  static void validateAllowedExtension(String path) {
    final lower = path.toLowerCase();
    if (_blockedExtensions.any(lower.endsWith)) {
      throw FormatException('游戏包包含禁止文件类型：$path');
    }
  }
}
