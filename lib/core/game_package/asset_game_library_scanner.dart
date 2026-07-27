import 'package:flutter/services.dart';

import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import 'asset_game_package_loader.dart';

const gameLibraryAssetRoot = 'assets/playmesh-library/packages';

class AssetGameLibraryScanner {
  AssetGameLibraryScanner({AssetBundle? bundle})
    : bundle = bundle ?? rootBundle;

  final AssetBundle bundle;

  Future<List<GameSummary>> scan({List<String>? assetKeys}) async {
    if (assetKeys == null) {
      bundle.evict('AssetManifest.bin');
      bundle.evict('AssetManifest.json');
    }
    final keys =
        assetKeys ??
        (await AssetManifest.loadFromAssetBundle(bundle)).listAssets();
    final manifestPattern = RegExp(
      '^${RegExp.escape(gameLibraryAssetRoot)}/([^/]+)/main\\.json\$',
    );
    final roots = <String>{};
    for (final key in keys) {
      final match = manifestPattern.firstMatch(key);
      if (match != null) {
        roots.add('$gameLibraryAssetRoot/${match.group(1)}');
      }
    }

    final sortedRoots = roots.toList()..sort();
    final loader = AssetGamePackageLoader(bundle: bundle);
    final packages = await Future.wait(sortedRoots.map(loader.load));
    final games = packages.map(_toSummary).toList(growable: false);
    games.sort((left, right) => left.name.compareTo(right.name));
    return List.unmodifiable(games);
  }

  GameSummary _toSummary(LoadedGamePackage package) {
    final directoryGameId = package.rootAssetPath.split('/').last;
    final manifest = package.manifest;
    if (manifest.id != directoryGameId) {
      throw FormatException(
        '游戏包目录名 $directoryGameId 与 main.json id ${manifest.id} 不一致',
      );
    }
    final displayMode = manifest.displayModes.first;
    return GameSummary(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      author: manifest.author,
      lastModifiedAt: manifest.lastModifiedAt,
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
      capabilities: package.capabilities,
      entry: LocalGameEntry(
        assetPath: package.appEntryAssetPath,
        gameEntryPath: manifest.entries.game,
        controllerEntryPath: manifest.entries.controller,
        packageRootAssetPath: package.rootAssetPath,
        statusLabel: 'Game SDK ${manifest.sdkVersion}',
      ),
    );
  }
}
