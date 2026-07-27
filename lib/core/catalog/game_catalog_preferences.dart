import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';
import 'game_catalog_models.dart';

class GameCatalogPreferencesValue {
  const GameCatalogPreferencesValue({
    this.share = const GameCatalogShareConfig(),
    this.defaultPageSize = defaultOnlineGamePageSize,
    this.sources = const [],
  });

  final GameCatalogShareConfig share;
  final int defaultPageSize;
  final List<OnlineGameSource> sources;
}

class GameCatalogPreferences {
  GameCatalogPreferences({Directory? libraryRoot, DateTime Function()? now})
    : _injectedRoot = libraryRoot,
      _now = now ?? DateTime.now;

  final Directory? _injectedRoot;
  final DateTime Function() _now;
  Directory? _resolvedRoot;

  Future<GameCatalogPreferencesValue> load() async {
    final file = await _file();
    if (!await file.exists()) return const GameCatalogPreferencesValue();
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      await _isolateUnsupported(file);
      await save(const GameCatalogPreferencesValue());
      return const GameCatalogPreferencesValue();
    }
    if (decoded is! Map || decoded['formatVersion'] != 2) {
      await _isolateUnsupported(file);
      await save(const GameCatalogPreferencesValue());
      return const GameCatalogPreferencesValue();
    }
    final json = Map<String, Object?>.from(decoded);
    final shareRaw = json['share'];
    final sizeRaw = json['defaultPageSize'];
    final sourcesRaw = json['sources'];
    final sources = <OnlineGameSource>[];
    if (sourcesRaw is List) {
      for (final item in sourcesRaw) {
        if (item is Map) {
          try {
            sources.add(
              OnlineGameSource.fromJson(Map<String, Object?>.from(item)),
            );
          } on Object {
            await _isolateUnsupported(file);
            await save(const GameCatalogPreferencesValue());
            return const GameCatalogPreferencesValue();
          }
        }
      }
    }
    return GameCatalogPreferencesValue(
      share: shareRaw is Map
          ? GameCatalogShareConfig.fromJson(Map<String, Object?>.from(shareRaw))
          : const GameCatalogShareConfig(),
      defaultPageSize: sizeRaw is int && sizeRaw >= 1 && sizeRaw <= 100
          ? sizeRaw
          : defaultOnlineGamePageSize,
      sources: List.unmodifiable(sources),
    );
  }

  Future<void> save(GameCatalogPreferencesValue value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'formatVersion': 2,
        'share': value.share.toJson(),
        'defaultPageSize': value.defaultPageSize,
        'sources': value.sources.map((source) => source.toJson()).toList(),
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<File> _file() async {
    final root = _resolvedRoot ??=
        _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    return File(
      '${root.path}${Platform.pathSeparator}catalog'
      '${Platform.pathSeparator}settings.json',
    );
  }

  Future<void> _isolateUnsupported(File file) async {
    final stamp = _now().toUtc().millisecondsSinceEpoch;
    var backup = File('${file.path}.$stamp.unsupported');
    var suffix = 0;
    while (await backup.exists()) {
      suffix += 1;
      backup = File('${file.path}.$stamp.$suffix.unsupported');
    }
    await file.rename(backup.path);
  }
}
