import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/game_manifest.dart';
import '../../models/game_package_layout.dart';
import '../../models/game_summary.dart';
import '../game_sdk/sdk_feature_registry.dart';
import 'game_package_transfer_service.dart';
import 'safe_game_package_archive.dart';

sealed class GamePackageImportInspection {
  const GamePackageImportInspection();
}

final class StandardGamePackageInspection extends GamePackageImportInspection {
  const StandardGamePackageInspection();
}

final class UnsupportedGamePackageInspection
    extends GamePackageImportInspection {
  const UnsupportedGamePackageInspection();
}

final class OrdinaryWebPackageInspection extends GamePackageImportInspection {
  const OrdinaryWebPackageInspection({
    required this.htmlEntries,
    required this.suggestedGameEntry,
    required this.suggestedControllerEntry,
    required this.suggestedName,
    required this.strippedRootDirectory,
  });

  final List<String> htmlEntries;
  final String suggestedGameEntry;
  final String? suggestedControllerEntry;
  final String suggestedName;
  final String? strippedRootDirectory;
}

class OrdinaryWebPackageConfiguration {
  const OrdinaryWebPackageConfiguration({
    required this.name,
    required this.orientation,
    required this.mode,
    required this.displayMode,
    required this.gameEntry,
    this.controllerOrientation,
    this.controllerEntry,
  });

  final String name;
  final GameOrientation orientation;
  final GameMode mode;
  final GameDisplayMode displayMode;
  final String gameEntry;
  final GameOrientation? controllerOrientation;
  final String? controllerEntry;
}

class OrdinaryWebPackageImporter {
  const OrdinaryWebPackageImporter();

  static const _compatibilityAuthorityEntry =
      '.playmesh/compatibility-authority.js';
  static const _compatibilityAuthoritySource =
      '// 普通网页包兼容入口：导入器不修改游戏业务或自动增加联机逻辑。\n';

  Future<GamePackageImportInspection> inspect(File source) async {
    final files = await SafeGamePackageArchive.read(source);
    if (files.containsKey('main.json')) {
      return const StandardGamePackageInspection();
    }
    final archive = _normalizeOrdinaryArchive(source, files);
    if (archive.htmlEntries.isEmpty) {
      return const UnsupportedGamePackageInspection();
    }
    return OrdinaryWebPackageInspection(
      htmlEntries: archive.htmlEntries,
      suggestedGameEntry: archive.suggestedGameEntry,
      suggestedControllerEntry: archive.suggestedControllerEntry,
      suggestedName: archive.suggestedName,
      strippedRootDirectory: archive.strippedRootDirectory,
    );
  }

  Future<ValidatedGamePackage> convert(
    File source, {
    required OrdinaryWebPackageConfiguration configuration,
    required String author,
    required DateTime lastModifiedAt,
  }) async {
    final sourceFiles = await SafeGamePackageArchive.read(source);
    if (sourceFiles.containsKey('main.json')) {
      throw const FormatException('标准 Playmesh 游戏包不能作为普通网页包转换');
    }
    final archive = _normalizeOrdinaryArchive(source, sourceFiles);
    if (archive.htmlEntries.isEmpty) {
      throw const FormatException('压缩包中没有 main.json 或 HTML 文件');
    }

    final name = configuration.name.trim();
    if (name.isEmpty) throw const FormatException('游戏名称不能为空');
    final normalizedAuthor = author.trim();
    if (normalizedAuthor.isEmpty) throw const FormatException('发布者不能为空');
    final gameEntry = playmeshGamePackageLayout.parseWebEntry(
      configuration.gameEntry,
      field: 'entries.game',
      kind: GameWebEntryKind.html,
    );
    if (!archive.htmlEntries.contains(gameEntry.path)) {
      throw const FormatException('游戏主入口必须是压缩包内的 HTML 文件');
    }

    final singleScreen =
        configuration.displayMode == GameDisplayMode.singleScreenMultiplayer;
    if (configuration.mode == GameMode.solo &&
        configuration.displayMode != GameDisplayMode.multiScreen) {
      throw const FormatException('单机游戏必须使用多屏显示模式');
    }
    final controllerEntry = configuration.controllerEntry == null
        ? null
        : playmeshGamePackageLayout.parseWebEntry(
            configuration.controllerEntry!,
            field: 'entries.controller',
            kind: GameWebEntryKind.html,
          );
    if (singleScreen &&
        (controllerEntry == null ||
            !archive.htmlEntries.contains(controllerEntry.path))) {
      throw const FormatException('单屏多人游戏必须选择控制器入口 HTML');
    }
    if (singleScreen && configuration.controllerOrientation == null) {
      throw const FormatException('单屏多人游戏必须选择控制器方向');
    }

    final outputFiles = <String, List<int>>{};
    for (final item in archive.files.entries) {
      final packagePath = playmeshGamePackageLayout.packagePathForWebPath(
        item.key,
      );
      outputFiles[packagePath] = item.value;
    }

    final multiplayer = configuration.mode == GameMode.multiplayer;
    if (multiplayer) {
      outputFiles[playmeshGamePackageLayout.packagePathForWebPath(
        _compatibilityAuthorityEntry,
      )] = utf8.encode(
        _compatibilityAuthoritySource,
      );
    }
    final manifest = GameManifest(
      id: _newGameId(),
      name: name,
      author: normalizedAuthor,
      lastModifiedAt: lastModifiedAt.toUtc(),
      remarks: '',
      version: '1.0.0',
      sdkVersion: SdkFeatureRegistry.gameSdkVersion,
      appSdkVersion: SdkFeatureRegistry.appSdkVersion,
      orientation: configuration.orientation,
      controllerOrientation: singleScreen
          ? configuration.controllerOrientation
          : null,
      modes: {configuration.mode},
      displayModes: {configuration.displayMode},
      players: multiplayer
          ? const GamePlayerLimits(min: 2, max: 5)
          : const GamePlayerLimits(min: 1, max: 1),
      tags: const [],
      entries: GameEntriesManifest(
        game: gameEntry.value,
        controller: controllerEntry?.value,
      ),
      authority: multiplayer
          ? const GameAuthorityManifest(entry: _compatibilityAuthorityEntry)
          : null,
    );
    outputFiles['main.json'] = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
    );
    if (outputFiles.length > SafeGamePackageArchive.maxFileCount ||
        outputFiles.values.fold<int>(
              0,
              (total, bytes) => total + bytes.length,
            ) >
            SafeGamePackageArchive.maxExpandedBytes) {
      throw const FormatException('转换后的游戏包超过安装限制');
    }
    return GamePackageTransferService().validatePackageFiles(outputFiles);
  }

  _OrdinaryArchive _normalizeOrdinaryArchive(
    File source,
    Map<String, List<int>> sourceFiles,
  ) {
    final strippedRootDirectory = _commonRootDirectory(sourceFiles.keys);
    final files = <String, List<int>>{};
    for (final item in sourceFiles.entries) {
      final path = strippedRootDirectory == null
          ? item.key
          : item.key.substring(strippedRootDirectory.length + 1);
      if (path.isEmpty || files.containsKey(path)) {
        throw FormatException('网页包规范化后包含重复路径：$path');
      }
      files[path] = item.value;
    }

    final htmlEntries = files.keys.where(_isHtmlPath).toList()
      ..sort(_compareHtmlEntries);
    final indexEntries = htmlEntries.where(_isIndexHtmlPath).toList();
    final suggestedGameEntry = indexEntries.isNotEmpty
        ? indexEntries.first
        : htmlEntries.firstOrNull ?? '';
    final suggestedControllerEntry = htmlEntries
        .where(
          (path) =>
              path != suggestedGameEntry &&
              RegExp(
                r'(^|/)(controller|control|remote|pad)(/|\.html?$)',
                caseSensitive: false,
              ).hasMatch(path),
        )
        .firstOrNull;
    final suggestedName = indexEntries.isEmpty
        ? _archiveFileName(source)
        : _readHtmlTitle(files[suggestedGameEntry]!) ??
              _archiveFileName(source);
    return _OrdinaryArchive(
      files: Map.unmodifiable(files),
      htmlEntries: List.unmodifiable(htmlEntries),
      suggestedGameEntry: suggestedGameEntry,
      suggestedControllerEntry: suggestedControllerEntry,
      suggestedName: suggestedName,
      strippedRootDirectory: strippedRootDirectory,
    );
  }

  String? _commonRootDirectory(Iterable<String> paths) {
    String? common;
    var found = false;
    for (final path in paths) {
      found = true;
      final separator = path.indexOf('/');
      if (separator <= 0) return null;
      final first = path.substring(0, separator);
      common ??= first;
      if (common != first) return null;
    }
    return found ? common : null;
  }

  static bool _isHtmlPath(String path) =>
      path.toLowerCase().endsWith('.html') ||
      path.toLowerCase().endsWith('.htm');

  static bool _isIndexHtmlPath(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1).toLowerCase();
    return name == 'index.html' || name == 'index.htm';
  }

  static int _compareHtmlEntries(String left, String right) {
    final leftIndex = _isIndexHtmlPath(left);
    final rightIndex = _isIndexHtmlPath(right);
    if (leftIndex != rightIndex) return leftIndex ? -1 : 1;
    final depth = left.split('/').length.compareTo(right.split('/').length);
    if (depth != 0) return depth;
    return left.toLowerCase().compareTo(right.toLowerCase());
  }

  String _archiveFileName(File source) {
    final fileName = source.path.split(RegExp(r'[/\\]')).last;
    return fileName.replaceFirst(
      RegExp(r'(?:\.playmesh)?\.zip$|\.playmesh$', caseSensitive: false),
      '',
    );
  }

  String? _readHtmlTitle(List<int> bytes) {
    try {
      final html = utf8.decode(bytes);
      final match = RegExp(
        r'<title\b[^>]*>([\s\S]*?)</title\s*>',
        caseSensitive: false,
      ).firstMatch(html);
      if (match == null) return null;
      final title = _decodeHtmlEntities(
        match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim(),
      ).trim();
      return title.isEmpty ? null : title;
    } on FormatException {
      return null;
    }
  }

  String _decodeHtmlEntities(String source) {
    return source.replaceAllMapped(
      RegExp(r'&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);', caseSensitive: false),
      (match) {
        final value = match.group(1)!.toLowerCase();
        return switch (value) {
          'amp' => '&',
          'lt' => '<',
          'gt' => '>',
          'quot' => '"',
          'apos' => "'",
          _ when value.startsWith('#x') => String.fromCharCode(
            int.parse(value.substring(2), radix: 16),
          ),
          _ when value.startsWith('#') => String.fromCharCode(
            int.parse(value.substring(1)),
          ),
          _ => match.group(0)!,
        };
      },
    );
  }

  String _newGameId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final source = Random.secure();
    final random =
        '${source.nextInt(1 << 24).toRadixString(36)}'
        '${source.nextInt(1 << 24).toRadixString(36)}';
    return 'local.web.$timestamp.$random';
  }
}

class _OrdinaryArchive {
  const _OrdinaryArchive({
    required this.files,
    required this.htmlEntries,
    required this.suggestedGameEntry,
    required this.suggestedControllerEntry,
    required this.suggestedName,
    required this.strippedRootDirectory,
  });

  final Map<String, List<int>> files;
  final List<String> htmlEntries;
  final String suggestedGameEntry;
  final String? suggestedControllerEntry;
  final String suggestedName;
  final String? strippedRootDirectory;
}
