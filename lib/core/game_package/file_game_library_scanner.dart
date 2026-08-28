import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_package_layout.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../library/playmesh_library_root.dart';
import 'game_library_local_metadata.dart';
import 'game_library_repository.dart';
import 'game_package_icon.dart';

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
    final usage = await _metadataStore.readUsageStats();
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
        games.add(await loadPackage(entity, usage: usage));
      } on Object catch (error, stackTrace) {
        debugPrint('跳过无法识别 ID 的游戏包 ${entity.path}: $error\n$stackTrace');
      }
    }
    await _metadataStore.retainGameIds(games.map((game) => game.id));
    games.sort(compareGameLibraryOrder);
    return List.unmodifiable(games);
  }

  Future<GameSummary> loadPackage(
    Directory package, {
    Map<String, DateTime>? lastOpenedAt,
    Map<String, GameLibraryUsageStats>? usage,
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
    final id = rawId.trim();
    final stats =
        usage?[id] ??
        (lastOpenedAt == null
            ? (await _metadataStore.readUsageStats())[id]
            : GameLibraryUsageStats(lastOpenedAt: lastOpenedAt[id]));
    try {
      return await _loadValidPackage(package, json, stats);
    } on Object catch (error) {
      debugPrint('游戏包 ${package.path} 清单待修复: $error');
      return await _loadRepairOnlyPackage(package, json, error, stats);
    }
  }

  Future<GameSummary> _loadValidPackage(
    Directory package,
    Map<String, Object?> json,
    GameLibraryUsageStats? usage,
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
    final entry = _packageWebEntryFile(
      package,
      manifest.entries.game,
      field: 'entries.game',
      kind: GameWebEntryKind.html,
    );
    if (!await entry.exists()) {
      throw FormatException('游戏包缺少 ${manifest.entries.game}');
    }
    if (manifest.displayModes.contains(
      GameDisplayMode.singleScreenMultiplayer,
    )) {
      final controller = _packageWebEntryFile(
        package,
        manifest.entries.controller!,
        field: 'entries.controller',
        kind: GameWebEntryKind.html,
      );
      if (!await controller.exists()) {
        throw FormatException('游戏包缺少 ${manifest.entries.controller}');
      }
    }
    final authority = manifest.authority;
    if (authority != null &&
        !await _packageWebEntryFile(
          package,
          authority.entry,
          field: 'authority.entry',
          kind: GameWebEntryKind.javaScript,
        ).exists()) {
      throw FormatException('游戏包缺少 ${authority.entry}');
    }
    final displayMode = manifest.displayModes.first;
    final icon = File(
      '${package.path}${Platform.pathSeparator}$gamePackageIconName',
    );
    final iconPath = await isSafeGamePackageIcon(icon) ? icon.path : null;
    return GameSummary(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      author: manifest.author,
      lastModifiedAt: manifest.lastModifiedAt,
      lastOpenedAt: usage?.lastOpenedAt,
      launchCount: usage?.launchCount ?? 0,
      localIconPath: iconPath,
      sdkVersion: manifest.sdkVersion,
      appSdkVersion: manifest.appSdkVersion,
      description: manifest.remarks,
      minPlayers: manifest.players.min,
      maxPlayers: manifest.players.max,
      supportsMultiplayer: manifest.supportsMultiplayer,
      displayModeLabel: displayMode.manifestValue,
      displayMode: displayMode.manifestValue,
      orientation: manifest.orientation,
      controllerOrientation: manifest.controllerOrientation,
      tags: manifest.tags,
      capabilities: capabilities,
      config: manifest.config,
      entry: LocalGameEntry(
        gameEntryPath: manifest.entries.game,
        controllerEntryPath: manifest.entries.controller,
        statusLabel: 'Game SDK ${manifest.sdkVersion}',
        packageRootFilePath: package.path,
      ),
    );
  }

  Future<GameSummary> _loadRepairOnlyPackage(
    Directory package,
    Map<String, Object?> json,
    Object error,
    GameLibraryUsageStats? usage,
  ) async {
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
    // 这些路径只用于让损坏包可在修复界面中检查。
    // `manifestError` keeps this summary out of every runnable/public path.
    final repairDisplayGameEntry = _repairDisplayWebEntry(
      entryMap['game'],
      fallback: 'index.html',
      kind: GameWebEntryKind.html,
    );
    final repairDisplayControllerEntry =
        displayMode == GameDisplayMode.singleScreenMultiplayer.manifestValue
        ? _repairDisplayWebEntry(
            entryMap['controller'],
            fallback: 'controller/index.html',
            kind: GameWebEntryKind.html,
          )
        : _optionalRepairDisplayWebEntry(
            entryMap['controller'],
            kind: GameWebEntryKind.html,
          );
    final author = _nonEmptyString(json['author']) ?? '';
    final icon = File(
      '${package.path}${Platform.pathSeparator}$gamePackageIconName',
    );
    final iconPath = await isSafeGamePackageIcon(icon) ? icon.path : null;
    return GameSummary(
      id: id,
      name: _nonEmptyString(json['name']) ?? id,
      version: _nonEmptyString(json['version']) ?? '0.0.0',
      author: author,
      lastModifiedAt: _safeTimestamp(json['lastModifiedAt']),
      lastOpenedAt: usage?.lastOpenedAt,
      launchCount: usage?.launchCount ?? 0,
      localIconPath: iconPath,
      manifestError: error.toString(),
      sdkVersion: _nonEmptyString(json['sdkVersion']) ?? '',
      appSdkVersion: _nonEmptyString(json['appSdkVersion']) ?? '',
      description: _nonEmptyString(json['remarks']) ?? '',
      minPlayers: minPlayers,
      maxPlayers: maxPlayers,
      supportsMultiplayer: _stringListContains(json['modes'], 'multiplayer'),
      displayModeLabel: displayMode,
      displayMode: displayMode,
      orientation: orientation,
      controllerOrientation: controllerOrientation,
      tags: _stringList(json['tags']),
      entry: LocalGameEntry(
        gameEntryPath: repairDisplayGameEntry,
        controllerEntryPath: repairDisplayControllerEntry,
        statusLabel: 'manifest_repair_required',
        packageRootFilePath: package.path,
      ),
    );
  }

  File _packageWebFile(Directory package, String webPath) => File(
    '${package.path}${Platform.pathSeparator}'
    '${playmeshGamePackageLayout.packagePathForWebPath(webPath).replaceAll('/', Platform.pathSeparator)}',
  );

  File _packageWebEntryFile(
    Directory package,
    String entry, {
    required String field,
    required GameWebEntryKind kind,
  }) {
    final location = playmeshGamePackageLayout.parseWebEntry(
      entry,
      field: field,
      kind: kind,
    );
    return _packageWebFile(package, location.path);
  }

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

List<String> _stringList(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList()
    : const [];

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;

DateTime? _safeTimestamp(Object? value) => value is int && value >= 0
    ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
    : null;

GameOrientation? _safeOrientation(Object? value, {bool nullable = false}) {
  try {
    if (value is String) return GameOrientation.fromManifestValue(value);
  } on FormatException {
    // 使用仅供显示的回退值，使损坏项目仍可修复。
  }
  return nullable ? null : GameOrientation.landscape;
}

String _repairDisplayWebEntry(
  Object? value, {
  required String fallback,
  required GameWebEntryKind kind,
}) {
  final path = _nonEmptyString(value);
  if (path == null) return fallback;
  try {
    return playmeshGamePackageLayout.validateWebEntry(
      path,
      field: 'entry',
      kind: kind,
    );
  } on FormatException {
    return fallback;
  }
}

String? _optionalRepairDisplayWebEntry(
  Object? value, {
  required GameWebEntryKind kind,
}) {
  final path = _nonEmptyString(value);
  if (path == null) return null;
  try {
    return playmeshGamePackageLayout.validateWebEntry(
      path,
      field: 'entry',
      kind: kind,
    );
  } on FormatException {
    return null;
  }
}
