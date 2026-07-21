import 'dart:convert';
import 'dart:io';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../library/playmesh_library_root.dart';

class FileGameLibraryScanner {
  FileGameLibraryScanner({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;

  Future<List<GameSummary>> scan() async {
    final libraryRoot = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    final packages = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}packages',
    );
    await packages.create(recursive: true);
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
      games.add(await loadPackage(entity));
    }
    games.sort((left, right) => left.name.compareTo(right.name));
    return List.unmodifiable(games);
  }

  Future<GameSummary> loadPackage(Directory package) async {
    final manifestFile = File(
      '${package.path}${Platform.pathSeparator}main.json',
    );
    if (!await manifestFile.exists()) {
      throw const FormatException('游戏包根目录缺少 main.json');
    }
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    final manifest = GameManifest.fromJson(Map<String, Object?>.from(decoded));
    final capabilities = await _readCapabilities(package);
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
      description: manifest.remarks,
      minPlayers: manifest.players.min,
      maxPlayers: manifest.players.max,
      supportsMultiplayer: manifest.supportsMultiplayer,
      displayModeLabel: displayMode == GameDisplayMode.singleScreenMultiplayer
          ? '大屏模式'
          : '多人多屏',
      displayMode: displayMode.manifestValue,
      orientation: manifest.orientation,
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
