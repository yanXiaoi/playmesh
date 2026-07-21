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
  GameCatalogPreferences({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<GameCatalogPreferencesValue> load() async {
    final file = await _file();
    if (!await file.exists()) return const GameCatalogPreferencesValue();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('游戏源设置根节点必须是对象');
    final json = Map<String, Object?>.from(decoded);
    final shareRaw = json['share'];
    final sizeRaw = json['defaultPageSize'];
    final sourcesRaw = json['sources'];
    final sources = <OnlineGameSource>[];
    if (sourcesRaw is List) {
      for (final item in sourcesRaw) {
        if (item is Map) {
          sources.add(
            OnlineGameSource.fromJson(Map<String, Object?>.from(item)),
          );
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
        'formatVersion': 1,
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
}
