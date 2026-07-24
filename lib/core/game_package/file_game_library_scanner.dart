import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../library/playmesh_library_root.dart';
import 'game_library_local_metadata.dart';
import 'game_library_repository.dart';

class FileGameLibraryScanner {
  FileGameLibraryScanner({
    Directory? libraryRoot,
    GameLibraryLocalMetadataStore? metadataStore,
  }) : _injectedRoot = libraryRoot,
       _metadataStore =
           metadataStore ??
           GameLibraryLocalMetadataStore(libraryRoot: libraryRoot);

  final Directory? _injectedRoot;
  final GameLibraryLocalMetadataStore _metadataStore;

  Future<List<GameSummary>> scan() async {
    final libraryRoot = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    final packages = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}packages',
    );
    await packages.create(recursive: true);
    final lastOpenedAt = await _metadataStore.readLastOpenedAt();
    final games = <GameSummary>[];
    await for (final entity in packages.list()) {
      if (entity is! Directory ||
          entity.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('.playmesh-')) {
        continue;
      }
      final manifestFile = File(
        '${entity.path}${Platform.pathSeparator}main.json',
      );
      if (!await manifestFile.exists()) continue;
      try {
        games.add(await loadPackage(entity, lastOpenedAt: lastOpenedAt));
      } on Object catch (error, stackTrace) {
        debugPrint('跳过无法识别 ID 的游戏包 ${entity.path}: $error\n$stackTrace');
      }
    }
    games.sort(compareGameLibraryOrder);
    return List.unmodifiable(games);
  }

  Future<GameSummary> loadPackage(
    Directory package, {
    Map<String, DateTime>? lastOpenedAt,
  }) async {
    final manifestFile = File(
      '${package.path}${Platform.pathSeparator}main.json',
    );
    if (!await manifestFile.exists()) {
      throw const FormatException('游戏包根目录缺少 main.json');
    }
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    final json = Map<String, Object?>.from(decoded);
    final rawId = json['id'];
    if (rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('main.json 缺少有效 id');
    }
    final opened =
        (lastOpenedAt ?? await _metadataStore.readLastOpenedAt())[rawId.trim()];
    try {
      return await _loadValidPackage(package, json, opened);
    } on Object catch (error) {
      debugPrint('游戏包 ${package.path} 清单待修复: $error');
      return _loadRecoverablePackage(package, json, error, opened);
    }
  }

  Future<GameSummary> _loadValidPackage(
    Directory package,
    Map<String, Object?> json,
    DateTime? lastOpenedAt,
  ) async {
    final manifest = GameManifest.fromJson(json);
    final capabilities = await _readCapabilities(package);
    if (!manifest.displayModes.contains(
          GameDisplayMode.singleScreenMultiplayer,
        ) &&
        capabilities.controllerRequired.isNotEmpty) {
      throw const FormatException('仅单屏多人游戏可以声明 controllerRequired');
    }
    final directoryId = package.path.split(Platform.pathSeparator).last;
    if (manifest.id != directoryId) {
      throw FormatException(
        '游戏包目录名 $directoryId 与 main.json id ${manifest.id} 不一致',
      );
    }
    final entry = _packageFile(package, manifest.entries.game);
    if (!await entry.exists()) {
      throw FormatException('游戏包缺少 ${manifest.entries.game}');
    }
    if (manifest.displayModes.contains(
      GameDisplayMode.singleScreenMultiplayer,
    )) {
      final controller = _packageFile(package, manifest.entries.controller);
      if (!await controller.exists()) {
        throw FormatException('游戏包缺少 ${manifest.entries.controller}');
      }
    }
    final authority = manifest.authority;
    if (authority != null &&
        !await _packageFile(package, authority.entry).exists()) {
      throw FormatException('游戏包缺少 ${authority.entry}');
    }
    final displayMode = manifest.displayModes.first;
    return GameSummary(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      author: manifest.author,
      lastModifiedAt: manifest.lastModifiedAt,
      lastOpenedAt: lastOpenedAt,
      sdkVersion: manifest.sdkVersion,
      appSdkVersion: manifest.appSdkVersion,
      description: manifest.remarks,
      minPlayers: manifest.players.min,
      maxPlayers: manifest.players.max,
      supportsMultiplayer: manifest.supportsMultiplayer,
      displayModeLabel: displayMode == GameDisplayMode.singleScreenMultiplayer
          ? '大屏模式'
          : '多人多屏',
      displayMode: displayMode.manifestValue,
      orientation: manifest.orientation,
      controllerOrientation: manifest.controllerOrientation,
      tags: manifest.tags,
      capabilities: capabilities,
      entry: LocalGameEntry(
        assetPath: manifest.entries.game,
        gameEntryPath: manifest.entries.game,
        controllerEntryPath: manifest.entries.controller,
        statusLabel: 'Game SDK ${manifest.sdkVersion}',
        packageRootFilePath: package.path,
      ),
    );
  }

  GameSummary _loadRecoverablePackage(
    Directory package,
    Map<String, Object?> json,
    Object error,
    DateTime? lastOpenedAt,
  ) {
    final id = (json['id'] as String).trim();
    final displayMode =
        _firstString(json['displayModes']) ??
        GameDisplayMode.multiScreen.manifestValue;
    final orientation =
        _safeOrientation(json['orientation']) ?? GameOrientation.landscape;
    final controllerOrientation = _safeOrientation(
      json['controllerOrientation'],
      nullable: true,
    );
    final players = json['players'];
    final playerMap = players is Map ? players : const <Object?, Object?>{};
    final minPlayers = _positiveInt(playerMap['min']) ?? 1;
    final maxPlayers = (_positiveInt(playerMap['max']) ?? minPlayers)
        .clamp(minPlayers, 999)
        .toInt();
    final entries = json['entries'];
    final entryMap = entries is Map ? entries : const <Object?, Object?>{};
    final gameEntry = _safePackageEntry(
      entryMap['game'],
      fallback: 'app/index.html',
    );
    final controllerEntry = _safePackageEntry(
      entryMap['controller'],
      fallback: 'app/controller/index.html',
    );
    final author = _nonEmptyString(json['author']) ?? '佚名';
    return GameSummary(
      id: id,
      name: _nonEmptyString(json['name']) ?? id,
      version: _nonEmptyString(json['version']) ?? '0.0.0',
      author: author,
      lastModifiedAt: _safeTimestamp(json['lastModifiedAt']),
      lastOpenedAt: lastOpenedAt,
      manifestError: error.toString(),
      sdkVersion: _nonEmptyString(json['sdkVersion']) ?? '',
      appSdkVersion: _nonEmptyString(json['appSdkVersion']) ?? '',
      description:
          _nonEmptyString(json['remarks']) ?? 'main.json 存在错误，请在开发者工作区修复。',
      minPlayers: minPlayers,
      maxPlayers: maxPlayers,
      supportsMultiplayer: _stringListContains(json['modes'], 'multiplayer'),
      displayModeLabel:
          displayMode == GameDisplayMode.singleScreenMultiplayer.manifestValue
          ? '大屏模式'
          : '多人多屏',
      displayMode: displayMode,
      orientation: orientation,
      controllerOrientation: controllerOrientation,
      entry: LocalGameEntry(
        assetPath: gameEntry,
        gameEntryPath: gameEntry,
        controllerEntryPath: controllerEntry,
        statusLabel: '清单待修复',
        packageRootFilePath: package.path,
      ),
    );
  }

  File _packageFile(Directory package, String manifestPath) => File(
    '${package.path}${Platform.pathSeparator}'
    '${manifestPath.replaceAll('/', Platform.pathSeparator)}',
  );

  Future<GameCapabilities> _readCapabilities(Directory package) async {
    final file = File(
      '${package.path}${Platform.pathSeparator}capabilities.json',
    );
    if (!await file.exists()) return const GameCapabilities();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('capabilities.json 根节点必须是对象');
    }
    return GameCapabilities.fromJson(Map<String, Object?>.from(decoded));
  }
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _firstString(Object? value) {
  if (value is! List || value.isEmpty) return null;
  return _nonEmptyString(value.first);
}

bool _stringListContains(Object? value, String expected) =>
    value is List && value.contains(expected);

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;

DateTime? _safeTimestamp(Object? value) => value is int && value >= 0
    ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
    : null;

GameOrientation? _safeOrientation(Object? value, {bool nullable = false}) {
  try {
    if (value is String) return GameOrientation.fromManifestValue(value);
  } on FormatException {
    // Use a display-only fallback so the broken project remains repairable.
  }
  return nullable ? null : GameOrientation.landscape;
}

String _safePackageEntry(Object? value, {required String fallback}) {
  final path = _nonEmptyString(value);
  if (path == null) return fallback;
  try {
    return validateGamePackagePath(path, field: 'entry');
  } on FormatException {
    return fallback;
  }
}
