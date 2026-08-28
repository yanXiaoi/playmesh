import 'game_summary.dart';
import 'game_id.dart';
import 'game_package_layout.dart';
import '../core/game_sdk/sdk_feature_registry.dart';
import '../core/version/semantic_version.dart';

export 'game_manifest_config.dart';

const maxGameTagCount = 5;

enum GameMode {
  solo('solo'),
  multiplayer('multiplayer');

  const GameMode(this.manifestValue);

  final String manifestValue;
}

enum GameDisplayMode {
  multiScreen('multi_screen'),
  singleScreenMultiplayer('single_screen_multiplayer');

  const GameDisplayMode(this.manifestValue);

  final String manifestValue;
}

class GamePlayerLimits {
  const GamePlayerLimits({required this.min, required this.max});

  final int min;
  final int max;
}

class GameAuthorityManifest {
  const GameAuthorityManifest({required this.entry});

  final String entry;
}

class GameEntriesManifest {
  const GameEntriesManifest({required this.game, this.controller});

  final String game;
  final String? controller;
}

class GameManifest {
  const GameManifest({
    required this.id,
    required this.name,
    required this.author,
    required this.lastModifiedAt,
    required this.remarks,
    required this.version,
    required this.sdkVersion,
    required this.appSdkVersion,
    required this.orientation,
    this.controllerOrientation,
    required this.modes,
    required this.displayModes,
    required this.players,
    required this.tags,
    required this.entries,
    this.authority,
    this.config,
    bool? hasConfig,
  }) : hasConfig = hasConfig ?? config != null;

  factory GameManifest.fromJson(
    Map<String, Object?> json, {
    bool validateSdkCompatibility = true,
  }) {
    final id = _requiredString(json, 'id');
    if (!isValidPlaymeshGameId(id)) {
      throw const FormatException(
        'id 必须为 1 到 64 个 ASCII 字母、数字、点、下划线或连字符，且以字母或数字开头',
      );
    }
    final name = _requiredString(json, 'name');
    final author = (_optionalString(json, 'author')?.trim() ?? '').isEmpty
        ? ''
        : _optionalString(json, 'author')!.trim();
    if (author.length > 80) {
      throw const FormatException('author 不能超过 80 个字符');
    }
    final lastModifiedAtValue = json['lastModifiedAt'];
    final lastModifiedAt = lastModifiedAtValue == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            _asNonNegativeInt(lastModifiedAtValue, 'lastModifiedAt'),
            isUtc: true,
          );
    final version = _requiredVersion(json, 'version');
    final sdkVersion = _requiredVersion(json, 'sdkVersion');
    final appSdkVersion = _requiredVersion(json, 'appSdkVersion');
    if (validateSdkCompatibility) {
      try {
        SdkFeatureRegistry.resolveGameSdkVersion(sdkVersion);
        SdkFeatureRegistry.resolveAppSdkVersion(appSdkVersion);
      } on UnsupportedError catch (error) {
        throw FormatException(error.message ?? error.toString());
      }
    }

    final orientation = GameOrientation.fromManifestValue(
      _requiredString(json, 'orientation'),
    );
    final modes = _enumList(
      json,
      'modes',
      GameMode.values,
      (value) => value.manifestValue,
    );
    if (modes.length != 1) {
      throw const FormatException('modes 必须且只能声明一个游戏模式');
    }
    final isMultiplayer = modes.single == GameMode.multiplayer;
    final displayModes = _enumList(
      json,
      'displayModes',
      GameDisplayMode.values,
      (value) => value.manifestValue,
    );
    if (displayModes.length != 1) {
      throw const FormatException('displayModes 必须且只能声明一个显示模式');
    }
    final singleScreen =
        isMultiplayer &&
        displayModes.single == GameDisplayMode.singleScreenMultiplayer;
    final controllerOrientationValue = json['controllerOrientation'];
    final controllerOrientation = controllerOrientationValue == null
        ? null
        : GameOrientation.fromManifestValue(
            _asString(controllerOrientationValue, 'controllerOrientation'),
          );
    if (singleScreen && controllerOrientation == null) {
      throw const FormatException(
        'single_screen_multiplayer 必须声明 controllerOrientation',
      );
    }
    if (!singleScreen && controllerOrientation != null) {
      throw const FormatException(
        '仅 single_screen_multiplayer 可以声明 controllerOrientation',
      );
    }

    final playerJson = _requiredMap(json, 'players');
    final minPlayers = _requiredInt(playerJson, 'min');
    final maxPlayers = _requiredInt(playerJson, 'max');
    if (minPlayers < 1 || maxPlayers < minPlayers) {
      throw const FormatException('players 必须满足 1 <= min <= max');
    }

    final entriesMap = _requiredMap(json, 'entries');
    final controllerEntry = !singleScreen || entriesMap['controller'] == null
        ? null
        : _validateHtmlEntry(
            _requiredUntrimmedString(entriesMap, 'controller'),
            field: 'entries.controller',
          );
    if (singleScreen && controllerEntry == null) {
      throw const FormatException(
        'single_screen_multiplayer 必须声明 entries.controller',
      );
    }
    final entries = GameEntriesManifest(
      game: _validateHtmlEntry(
        _requiredUntrimmedString(entriesMap, 'game'),
        field: 'entries.game',
      ),
      controller: controllerEntry,
    );

    final authorityJson = json['authority'];
    final authority = authorityJson == null
        ? null
        : GameAuthorityManifest(
            entry: _validateJavaScriptEntry(
              _requiredUntrimmedString(
                _asMap(authorityJson, 'authority'),
                'entry',
              ),
              field: 'authority.entry',
            ),
          );
    if (isMultiplayer && authority == null) {
      throw const FormatException('多人游戏必须声明 authority.entry');
    }
    if (!isMultiplayer && maxPlayers > 1) {
      throw const FormatException('多人上限大于 1 时 modes 必须包含 multiplayer');
    }

    final tags = _optionalStringList(json, 'tags');
    if (tags.length > maxGameTagCount) {
      throw const FormatException('tags 最多只能包含 5 个标签');
    }

    return GameManifest(
      id: id,
      name: name,
      author: author,
      lastModifiedAt: lastModifiedAt,
      remarks: _optionalString(json, 'remarks') ?? '',
      version: version,
      sdkVersion: sdkVersion,
      appSdkVersion: appSdkVersion,
      orientation: orientation,
      controllerOrientation: controllerOrientation,
      modes: Set.unmodifiable(modes),
      displayModes: Set.unmodifiable(displayModes),
      players: GamePlayerLimits(min: minPlayers, max: maxPlayers),
      tags: List.unmodifiable(tags),
      entries: entries,
      authority: authority,
      config: json['config'],
      hasConfig: json.containsKey('config'),
    );
  }

  final String id;
  final String name;
  final String author;
  final DateTime? lastModifiedAt;
  final String remarks;
  final String version;
  final String sdkVersion;
  final String appSdkVersion;
  final GameOrientation orientation;
  final GameOrientation? controllerOrientation;
  final Set<GameMode> modes;
  final Set<GameDisplayMode> displayModes;
  final GamePlayerLimits players;
  final List<String> tags;
  final GameEntriesManifest entries;
  final GameAuthorityManifest? authority;
  final Object? config;
  final bool hasConfig;

  bool get supportsMultiplayer => modes.contains(GameMode.multiplayer);

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'id': id,
      'name': name,
      'author': author,
      'remarks': remarks,
      'version': version,
      'sdkVersion': sdkVersion,
      'appSdkVersion': appSdkVersion,
      'orientation': orientation.manifestValue,
      'modes': modes.map((mode) => mode.manifestValue).toList(),
      'displayModes': displayModes.map((mode) => mode.manifestValue).toList(),
      'players': {'min': players.min, 'max': players.max},
      'entries': {'game': entries.game, 'controller': ?entries.controller},
      'tags': tags,
    };
    if (lastModifiedAt case final lastModifiedAt?) {
      json['lastModifiedAt'] = lastModifiedAt.millisecondsSinceEpoch;
    }
    if (controllerOrientation case final controllerOrientation?) {
      json['controllerOrientation'] = controllerOrientation.manifestValue;
    }
    if (authority case final authority?) {
      json['authority'] = {'entry': authority.entry};
    }
    if (hasConfig) json['config'] = config;
    return json;
  }
}

/// 返回清单的可写投影，不为未知 JSON 成员赋予语义。读取端可以接受任意额外成员，
/// 但 App 管理的所有写入路径只输出当前协议中的字段。
Map<String, Object?> projectGameManifestJson(Map<String, Object?> source) {
  final projected = _projectJsonObject(source, const [
    'id',
    'name',
    'author',
    'lastModifiedAt',
    'remarks',
    'version',
    'sdkVersion',
    'appSdkVersion',
    'orientation',
    'controllerOrientation',
    'modes',
    'displayModes',
    'players',
    'entries',
    'tags',
    'authority',
    'config',
  ]);
  _projectNestedJsonObject(projected, 'players', const ['min', 'max']);
  _projectNestedJsonObject(projected, 'entries', const ['game', 'controller']);
  _projectNestedJsonObject(projected, 'authority', const ['entry']);
  return projected;
}

void _projectNestedJsonObject(
  Map<String, Object?> parent,
  String field,
  List<String> fields,
) {
  final value = parent[field];
  if (value is! Map) return;
  parent[field] = _projectJsonObject(
    value.map((key, value) => MapEntry(key.toString(), value)),
    fields,
  );
}

Map<String, Object?> _projectJsonObject(
  Map<String, Object?> source,
  List<String> fields,
) => {
  for (final field in fields)
    if (source.containsKey(field)) field: source[field],
};

String validateGamePackagePath(String value, {required String field}) {
  return playmeshGamePackageLayout.validatePackagePath(value, field: field);
}

String _validateHtmlEntry(String value, {required String field}) {
  return playmeshGamePackageLayout
      .parseWebEntry(value, field: field, kind: GameWebEntryKind.html)
      .value;
}

String _validateJavaScriptEntry(String value, {required String field}) {
  return playmeshGamePackageLayout
      .parseWebEntry(value, field: field, kind: GameWebEntryKind.javaScript)
      .value;
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    throw FormatException('缺少必填字段: $field');
  }
  final result = _asString(value, field).trim();
  if (result.isEmpty) {
    throw FormatException('$field 不能为空');
  }
  return result;
}

String _requiredUntrimmedString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    throw FormatException('缺少必填字段: $field');
  }
  return _asString(value, field);
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  return value == null ? null : _asString(value, field);
}

String _requiredVersion(Map<String, Object?> json, String field) {
  final value = _requiredString(json, field);
  SemanticVersion.parse(value);
  return value;
}

String _asString(Object value, String field) {
  if (value is! String) {
    throw FormatException('$field 必须是字符串');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) {
    throw FormatException('$field 必须是整数');
  }
  return value;
}

int _asNonNegativeInt(Object value, String field) {
  if (value is! int || value < 0) {
    throw FormatException('$field 必须是非负 Unix 毫秒时间戳');
  }
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    throw FormatException('缺少必填字段: $field');
  }
  return _asMap(value, field);
}

Map<String, Object?> _asMap(Object value, String field) {
  if (value is! Map) {
    throw FormatException('$field 必须是对象');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<T> _enumList<T>(
  Map<String, Object?> json,
  String field,
  List<T> values,
  String Function(T value) manifestValue,
) {
  final rawValues = json[field];
  if (rawValues is! List || rawValues.isEmpty) {
    throw FormatException('$field 必须是非空数组');
  }

  return rawValues
      .map((rawValue) {
        if (rawValue is! String) {
          throw FormatException('$field 只能包含字符串');
        }
        return values.firstWhere(
          (value) => manifestValue(value) == rawValue,
          orElse: () => throw FormatException('$field 包含未知值: $rawValue'),
        );
      })
      .toList(growable: false);
}

List<String> _optionalStringList(Map<String, Object?> json, String field) {
  final rawValues = json[field];
  if (rawValues == null) {
    return const [];
  }
  if (rawValues is! List) {
    throw FormatException('$field 必须是数组');
  }
  return rawValues.map((value) => _asString(value, field)).toList();
}
