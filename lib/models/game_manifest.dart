import 'game_summary.dart';

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
  const GameEntriesManifest({
    this.game = 'app/index.html',
    this.controller = 'app/controller/index.html',
  });

  final String game;
  final String controller;
}

class GameManifest {
  const GameManifest({
    required this.id,
    required this.name,
    required this.remarks,
    required this.version,
    required this.sdkVersion,
    required this.appSdkVersion,
    required this.orientation,
    required this.modes,
    required this.displayModes,
    required this.players,
    required this.permissions,
    required this.tags,
    required this.icon,
    required this.entries,
    this.authority,
  });

  factory GameManifest.fromJson(Map<String, Object?> json) {
    final id = _requiredString(json, 'id');
    final name = _requiredString(json, 'name');
    final version = _requiredVersion(json, 'version');
    final sdkVersion = _requiredVersion(json, 'sdkVersion');
    if (!sdkVersion.startsWith('1.') && !sdkVersion.startsWith('2.')) {
      throw const FormatException('当前 App 只支持 1.x 或 2.x Game SDK');
    }
    final appSdkVersion = json['appSdkVersion'] == null
        ? '1.0.0'
        : _requiredVersion(json, 'appSdkVersion');
    if (!appSdkVersion.startsWith('1.') && !appSdkVersion.startsWith('2.')) {
      throw const FormatException('当前 App 只支持 1.x 或 2.x App SDK');
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
    final displayModes = _enumList(
      json,
      'displayModes',
      GameDisplayMode.values,
      (value) => value.manifestValue,
    );
    if (displayModes.length != 1) {
      throw const FormatException('displayModes 必须且只能声明一个显示模式');
    }

    final playerJson = _requiredMap(json, 'players');
    final minPlayers = _requiredInt(playerJson, 'min');
    final maxPlayers = _requiredInt(playerJson, 'max');
    if (minPlayers < 1 || maxPlayers < minPlayers) {
      throw const FormatException('players 必须满足 1 <= min <= max');
    }

    final entriesJson = json['entries'];
    final entriesMap = entriesJson == null
        ? const <String, Object?>{}
        : _asMap(entriesJson, 'entries');
    final entries = GameEntriesManifest(
      game: _validateHtmlEntry(
        _optionalString(entriesMap, 'game') ?? 'app/index.html',
        field: 'entries.game',
      ),
      controller: _validateHtmlEntry(
        _optionalString(entriesMap, 'controller') ??
            'app/controller/index.html',
        field: 'entries.controller',
      ),
    );

    final authorityJson = json['authority'];
    final authority = authorityJson == null
        ? null
        : GameAuthorityManifest(
            entry: _validateJavaScriptEntry(
              _requiredString(_asMap(authorityJson, 'authority'), 'entry'),
              field: 'authority.entry',
            ),
          );
    final isMultiplayer = modes.contains(GameMode.multiplayer);
    if (isMultiplayer && authority == null) {
      throw const FormatException('多人游戏必须声明 authority.entry');
    }
    if (!isMultiplayer && maxPlayers > 1) {
      throw const FormatException('多人上限大于 1 时 modes 必须包含 multiplayer');
    }

    final iconValue = json['icon'];
    final icon = iconValue == null
        ? null
        : validateGamePackagePath(_asString(iconValue, 'icon'), field: 'icon');
    if (icon != null && !icon.startsWith('app/')) {
      throw const FormatException('icon 必须位于 app/ 公开资源目录内');
    }
    final permissions = _optionalStringList(json, 'permissions');
    final tags = _optionalStringList(json, 'tags');

    return GameManifest(
      id: id,
      name: name,
      remarks: _optionalString(json, 'remarks') ?? '',
      version: version,
      sdkVersion: sdkVersion,
      appSdkVersion: appSdkVersion,
      orientation: orientation,
      modes: Set.unmodifiable(modes),
      displayModes: Set.unmodifiable(displayModes),
      players: GamePlayerLimits(min: minPlayers, max: maxPlayers),
      permissions: List.unmodifiable(permissions),
      tags: List.unmodifiable(tags),
      icon: icon,
      entries: entries,
      authority: authority,
    );
  }

  final String id;
  final String name;
  final String remarks;
  final String version;
  final String sdkVersion;
  final String appSdkVersion;
  final GameOrientation orientation;
  final Set<GameMode> modes;
  final Set<GameDisplayMode> displayModes;
  final GamePlayerLimits players;
  final List<String> permissions;
  final List<String> tags;
  final String? icon;
  final GameEntriesManifest entries;
  final GameAuthorityManifest? authority;

  bool get supportsMultiplayer => modes.contains(GameMode.multiplayer);

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'id': id,
      'name': name,
      'remarks': remarks,
      'version': version,
      'sdkVersion': sdkVersion,
      'appSdkVersion': appSdkVersion,
      'orientation': orientation.manifestValue,
      'modes': modes.map((mode) => mode.manifestValue).toList(),
      'displayModes': displayModes.map((mode) => mode.manifestValue).toList(),
      'players': {'min': players.min, 'max': players.max},
      'entries': {'game': entries.game, 'controller': entries.controller},
      'permissions': permissions,
      'tags': tags,
    };
    if (authority case final authority?) {
      json['authority'] = {'entry': authority.entry};
    }
    if (icon case final icon?) json['icon'] = icon;
    return json;
  }
}

String validateGamePackagePath(String value, {required String field}) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      value.contains('\\') ||
      value.contains('?') ||
      value.contains('#') ||
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(value)) {
    throw FormatException('$field 必须是游戏包内的相对路径');
  }

  final segments = value.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw FormatException('$field 不能越过游戏包目录');
  }
  return value;
}

String _validateHtmlEntry(String value, {required String field}) {
  final path = validateGamePackagePath(value.trim(), field: field);
  if (!path.startsWith('app/')) {
    throw FormatException('$field 必须位于 app/ 公开资源目录内');
  }
  if (!path.toLowerCase().endsWith('.html')) {
    throw FormatException('$field 必须指向 HTML 文件');
  }
  return path;
}

String _validateJavaScriptEntry(String value, {required String field}) {
  final path = validateGamePackagePath(value.trim(), field: field);
  if (!path.startsWith('app/')) {
    throw FormatException('$field 必须位于 app/ 公开资源目录内');
  }
  final lower = path.toLowerCase();
  if (!lower.endsWith('.js') && !lower.endsWith('.mjs')) {
    throw FormatException('$field 必须指向 JavaScript 文件');
  }
  return path;
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

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  return value == null ? null : _asString(value, field);
}

String _requiredVersion(Map<String, Object?> json, String field) {
  final value = _requiredString(json, field);
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value)) {
    throw FormatException('$field 必须使用 MAJOR.MINOR.PATCH');
  }
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
