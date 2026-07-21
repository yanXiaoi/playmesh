import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';

class LoadedGamePackage {
  const LoadedGamePackage({
    required this.rootAssetPath,
    required this.manifest,
    required this.capabilities,
    required this.appEntryAssetPath,
    this.controllerEntryAssetPath,
  });

  final String rootAssetPath;
  final GameManifest manifest;
  final GameCapabilities capabilities;
  final String appEntryAssetPath;
  final String? controllerEntryAssetPath;
}

class AssetGamePackageLoader {
  AssetGamePackageLoader({AssetBundle? bundle}) : bundle = bundle ?? rootBundle;

  final AssetBundle bundle;

  Future<LoadedGamePackage> load(String rootAssetPath) async {
    final root = rootAssetPath.endsWith('/')
        ? rootAssetPath.substring(0, rootAssetPath.length - 1)
        : rootAssetPath;
    final manifestPath = '$root/main.json';
    bundle.evict(manifestPath);
    final manifestText = await bundle.loadString(manifestPath);
    final decoded = jsonDecode(manifestText);
    if (decoded is! Map) {
      throw const FormatException('main.json 根节点必须是对象');
    }
    final manifest = GameManifest.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
    var capabilities = const GameCapabilities();
    final capabilitiesPath = '$root/capabilities.json';
    try {
      bundle.evict(capabilitiesPath);
      final decodedCapabilities = jsonDecode(
        await bundle.loadString(capabilitiesPath),
      );
      if (decodedCapabilities is! Map) {
        throw const FormatException('capabilities.json 根节点必须是对象');
      }
      capabilities = GameCapabilities.fromJson(
        Map<String, Object?>.from(decodedCapabilities),
      );
    } on FlutterError {
      // capabilities.json is optional. No file means no protected capability.
    }

    final appEntry = '$root/${manifest.entries.game}';
    bundle.evict(appEntry);
    await bundle.loadString(appEntry);

    String? controllerEntry;
    if (manifest.displayModes.contains(
      GameDisplayMode.singleScreenMultiplayer,
    )) {
      controllerEntry = '$root/${manifest.entries.controller}';
      bundle.evict(controllerEntry);
      await bundle.loadString(controllerEntry);
    }
    if (manifest.authority != null) {
      final authorityEntry = '$root/${manifest.authority!.entry}';
      bundle.evict(authorityEntry);
      await bundle.loadString(authorityEntry);
    }

    return LoadedGamePackage(
      rootAssetPath: root,
      manifest: manifest,
      capabilities: capabilities,
      appEntryAssetPath: appEntry,
      controllerEntryAssetPath: controllerEntry,
    );
  }
}
