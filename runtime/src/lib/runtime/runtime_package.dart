import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'runtime_config.dart';

final class RuntimeGameManifest {
  const RuntimeGameManifest({
    required this.id,
    required this.name,
    required this.gameSdkVersion,
    required this.appSdkVersion,
    required this.orientation,
    required this.multiplayer,
    required this.displayMode,
    required this.minPlayers,
    required this.maxPlayers,
    required this.gameEntry,
    required this.requiredCapabilities,
    required this.tags,
    this.gameEntryQuery,
    this.controllerEntry,
    this.controllerEntryQuery,
    this.controllerOrientation,
    this.controllerRequiredCapabilities = const [],
    this.authorityEntry,
  });

  factory RuntimeGameManifest.fromPackage(Map<String, Uint8List> files) {
    final manifest = _jsonObject(files, 'main.json');
    final entries = _object(manifest, 'entries');
    final players = _object(manifest, 'players');
    final modes = _enumValues(manifest, 'modes', const {'solo', 'multiplayer'});
    if (modes.length != 1) {
      throw const FormatException('modes 必须且只能声明一个游戏模式');
    }
    final multiplayer = modes.single == 'multiplayer';
    final displayModes = _enumValues(manifest, 'displayModes', const {
      'multi_screen',
      'single_screen_multiplayer',
    });
    if (displayModes.length != 1) {
      throw const FormatException('displayModes 必须且只能声明一个显示模式');
    }
    final capabilities = files.containsKey('capabilities.json')
        ? _parseCapabilities(_jsonObject(files, 'capabilities.json'))
        : (required: const <String>[], controller: const <String>[]);
    final gameEntry = _parseEntry(
      _requiredUntrimmedString(entries, 'game'),
      field: 'entries.game',
      html: true,
    );
    final rawController = entries['controller'];
    final displayMode = displayModes.single;
    final singleScreen =
        multiplayer && displayMode == 'single_screen_multiplayer';
    final controllerEntry = singleScreen && rawController is String
        ? _parseEntry(rawController, field: 'entries.controller', html: true)
        : null;
    if (singleScreen && controllerEntry == null) {
      throw const FormatException(
        'single_screen_multiplayer 缺少 entries.controller',
      );
    }
    final orientation = _orientation(manifest, 'orientation');
    final rawControllerOrientation = manifest['controllerOrientation'];
    final controllerOrientation = rawControllerOrientation == null
        ? null
        : _orientation(manifest, 'controllerOrientation');
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
    final minPlayers = _requiredInt(players, 'min');
    final maxPlayers = _requiredInt(players, 'max');
    if (minPlayers < 1 || maxPlayers < minPlayers) {
      throw const FormatException('players 必须满足 1 <= min <= max');
    }
    if (!multiplayer && maxPlayers > 1) {
      throw const FormatException('多人上限大于 1 时 modes 必须包含 multiplayer');
    }
    final authorityValue = manifest['authority'];
    final authority = authorityValue == null
        ? null
        : _parseEntry(
            _requiredUntrimmedString(
              _map(authorityValue, 'authority'),
              'entry',
            ),
            field: 'authority.entry',
            html: false,
          ).path;
    if (multiplayer && authority == null) {
      throw const FormatException('多人游戏必须声明 authority.entry');
    }
    final id = _requiredString(manifest, 'id');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(id)) {
      throw const FormatException('游戏 id 格式无效');
    }
    _semanticVersion(_requiredString(manifest, 'version'), 'version');
    final gameSdkVersion = _semanticVersion(
      _requiredString(manifest, 'sdkVersion'),
      'sdkVersion',
    );
    if (gameSdkVersion != '4.1.0') {
      throw FormatException('Runtime 不支持 Game SDK $gameSdkVersion');
    }
    final appSdkVersion = _semanticVersion(
      _requiredString(manifest, 'appSdkVersion'),
      'appSdkVersion',
    );
    if (appSdkVersion != '3.2.0' && appSdkVersion != '3.3.0') {
      throw FormatException('Runtime 不支持 App SDK $appSdkVersion');
    }
    final tags = _optionalStrings(manifest['tags'], 'tags');
    if (tags.length > 5) throw const FormatException('tags 最多只能包含 5 个标签');
    return RuntimeGameManifest(
      id: id,
      name: _requiredString(manifest, 'name'),
      gameSdkVersion: gameSdkVersion,
      appSdkVersion: appSdkVersion,
      orientation: orientation,
      multiplayer: multiplayer,
      displayMode: displayMode,
      minPlayers: minPlayers,
      maxPlayers: maxPlayers,
      gameEntry: gameEntry.path,
      gameEntryQuery: gameEntry.query,
      controllerEntry: controllerEntry?.path,
      controllerEntryQuery: controllerEntry?.query,
      controllerOrientation: controllerOrientation,
      requiredCapabilities: capabilities.required,
      controllerRequiredCapabilities: capabilities.controller,
      tags: tags,
      authorityEntry: authority,
    );
  }

  final String id;
  final String name;
  final String gameSdkVersion;
  final String appSdkVersion;
  final String orientation;
  final bool multiplayer;
  final String displayMode;
  final int minPlayers;
  final int maxPlayers;
  final String gameEntry;
  final String? gameEntryQuery;
  final String? controllerEntry;
  final String? controllerEntryQuery;
  final String? controllerOrientation;
  final List<String> requiredCapabilities;
  final List<String> controllerRequiredCapabilities;
  final List<String> tags;
  final String? authorityEntry;

  bool get usesControllerEntry =>
      multiplayer && displayMode == 'single_screen_multiplayer';

  String get sharedEntry => usesControllerEntry ? controllerEntry! : gameEntry;

  String? get sharedEntryQuery =>
      usesControllerEntry ? controllerEntryQuery : gameEntryQuery;

  String get sharedOrientation =>
      usesControllerEntry ? controllerOrientation ?? orientation : orientation;

  List<String> get sharedRequiredCapabilities => usesControllerEntry
      ? controllerRequiredCapabilities
      : requiredCapabilities;
}

final class RuntimeGamePackage {
  const RuntimeGamePackage({
    required this.files,
    required this.manifest,
    required this.config,
    this.relayServer,
    this.autoApproveCapabilities = false,
  });

  static const maxFiles = 20000;
  static const maxUncompressedBytes = 512 * 1024 * 1024;

  static Future<RuntimeGamePackage> load({
    RuntimePackageDecoder decoder = const RuntimePackageDecoder(),
  }) async {
    final config = await RuntimeConfig.load();
    Uint8List? encoded;
    if (config.packageCodec == 'plain-zip') {
      final data = await rootBundle.load(config.gameAsset);
      encoded = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final clear = await decoder.decode(config, encoded);
    final archive = ZipDecoder().decodeBytes(clear, verify: true);
    if (archive.length > maxFiles) {
      throw const FormatException('游戏包文件数量超过 Runtime 限制');
    }
    var totalBytes = 0;
    final files = <String, Uint8List>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final path = _safeArchivePath(entry.name);
      totalBytes += entry.size;
      if (totalBytes > maxUncompressedBytes) {
        throw const FormatException('游戏包解压体积超过 Runtime 限制');
      }
      if (files.containsKey(path)) {
        throw FormatException('游戏包包含重复文件路径: $path');
      }
      final content = entry.content;
      files[path] = content is Uint8List
          ? content
          : Uint8List.fromList(List<int>.from(content as List));
    }
    if (!files.containsKey('main.json')) {
      throw const FormatException('游戏包缺少 main.json');
    }
    final manifest = RuntimeGameManifest.fromPackage(files);
    final packageRuntime = files.containsKey('playmesh-runtime.json')
        ? _jsonObject(files, 'playmesh-runtime.json')
        : const <String, Object?>{};
    if (packageRuntime.isNotEmpty && packageRuntime['schemaVersion'] != 1) {
      throw const FormatException('playmesh-runtime.json 版本不受支持');
    }
    final rawRelayServer = packageRuntime['relayServer'];
    if (rawRelayServer != null && rawRelayServer is! String) {
      throw const FormatException('Runtime 中转地址必须是字符串');
    }
    final relayServer = rawRelayServer == null
        ? null
        : parseRuntimeRelayServer(rawRelayServer as String);
    final rawAutoApproveCapabilities =
        packageRuntime['autoApproveCapabilities'] ?? false;
    if (rawAutoApproveCapabilities is! bool) {
      throw const FormatException('Runtime 自动同意能力授权配置必须是布尔值');
    }
    if (!files.containsKey(manifest.gameEntry)) {
      throw FormatException('游戏入口不存在: ${manifest.gameEntry}');
    }
    final controllerEntry = manifest.controllerEntry;
    if (controllerEntry != null && !files.containsKey(controllerEntry)) {
      throw FormatException('控制器入口不存在: $controllerEntry');
    }
    final authorityEntry = manifest.authorityEntry;
    if (authorityEntry != null && !files.containsKey(authorityEntry)) {
      throw FormatException('Authority 入口不存在: $authorityEntry');
    }
    return RuntimeGamePackage(
      files: Map.unmodifiable(files),
      manifest: manifest,
      config: config,
      relayServer: relayServer,
      autoApproveCapabilities: rawAutoApproveCapabilities,
    );
  }

  final Map<String, Uint8List> files;
  final RuntimeGameManifest manifest;
  final RuntimeConfig config;
  final Uri? relayServer;
  final bool autoApproveCapabilities;

  Uint8List? readWebFile(String relativePath) => files[relativePath];
}

Map<String, Object?> _jsonObject(Map<String, Uint8List> files, String path) {
  final bytes = files[path];
  if (bytes == null) throw FormatException('游戏包缺少 $path');
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) throw FormatException('$path 根节点必须是对象');
  return Map<String, Object?>.from(decoded);
}

Map<String, Object?> _object(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! Map) throw FormatException('main.json.$key 必须是对象');
  return Map<String, Object?>.from(value);
}

String _requiredString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value.trim();
}

String _requiredUntrimmedString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}

int _requiredInt(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! int) throw FormatException('$key 必须是整数');
  return value;
}

Map<String, Object?> _map(Object value, String field) {
  if (value is! Map) throw FormatException('$field 必须是对象');
  return Map<String, Object?>.from(value);
}

List<String> _optionalStrings(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$field 必须是字符串数组');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

List<String> _requiredStrings(Object? value, String field) {
  final result = _optionalStrings(value, field);
  if (value == null) throw FormatException('$field 必须是非空数组');
  final unique = result.toSet();
  if (result.isEmpty || unique.length != result.length) {
    throw FormatException('$field 不能为空或包含重复值');
  }
  return result;
}

List<String> _uniqueStrings(Object? value, String field) {
  final result = _optionalStrings(value, field);
  final unique = result.toSet();
  if (unique.length != result.length || result.any((item) => item.isEmpty)) {
    throw FormatException('$field 不能包含空值或重复值');
  }
  return result;
}

List<String> _enumValues(
  Map<String, Object?> source,
  String field,
  Set<String> allowed,
) {
  final values = _requiredStrings(source[field], field);
  final unknown = values.where((value) => !allowed.contains(value));
  if (unknown.isNotEmpty) {
    throw FormatException('$field 包含未知值: ${unknown.first}');
  }
  return values;
}

String _orientation(Map<String, Object?> source, String field) {
  final value = _requiredString(source, field);
  if (value != 'portrait' && value != 'landscape') {
    throw FormatException('$field 必须是 portrait 或 landscape');
  }
  return value;
}

String _semanticVersion(String value, String field) {
  if (!RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(value)) {
    throw FormatException('$field 必须是严格的 MAJOR.MINOR.PATCH');
  }
  return value;
}

({List<String> required, List<String> controller}) _parseCapabilities(
  Map<String, Object?> source,
) {
  final unknown = source.keys.where(
    (field) => field != 'required' && field != 'controllerRequired',
  );
  if (unknown.isNotEmpty) {
    throw FormatException('capabilities.json 包含未知字段: ${unknown.join(', ')}');
  }
  return (
    required: source['required'] == null
        ? const []
        : _uniqueStrings(source['required'], 'capabilities.json.required'),
    controller: source['controllerRequired'] == null
        ? const []
        : _uniqueStrings(
            source['controllerRequired'],
            'capabilities.json.controllerRequired',
          ),
  );
}

({String path, String? query}) _parseEntry(
  String value, {
  required String field,
  required bool html,
}) {
  if (value.trim() != value || value.contains('#') || value.contains('\\')) {
    throw FormatException('$field 路径无效');
  }
  final separator = value.indexOf('?');
  final path = separator < 0 ? value : value.substring(0, separator);
  final query = separator < 0 ? null : value.substring(separator + 1);
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('%') ||
      path.runes.any((value) => value < 0x20 || value == 0x7f) ||
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(path) ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..') ||
      (query != null && query.isEmpty)) {
    throw FormatException('$field 路径无效');
  }
  final first = path.split('/').first.toLowerCase();
  if (first == 'playmesh' || first == 'bucket') {
    throw FormatException('$field 不得占用平台运行时目录 $first/');
  }
  final lowerPath = path.toLowerCase();
  if (html
      ? !lowerPath.endsWith('.html')
      : (!lowerPath.endsWith('.js') && !lowerPath.endsWith('.mjs'))) {
    throw FormatException(
      html ? '$field 必须指向 HTML 文件' : '$field 必须指向 JavaScript 文件',
    );
  }
  if (query != null) {
    if (!html ||
        query.contains('\\') ||
        query.runes.any((value) => value <= 0x20 || value == 0x7f)) {
      throw FormatException('$field 查询参数无效');
    }
    for (var index = 0; index < query.length; index += 1) {
      if (query.codeUnitAt(index) != 0x25) continue;
      if (index + 2 >= query.length ||
          !_isHexDigit(query.codeUnitAt(index + 1)) ||
          !_isHexDigit(query.codeUnitAt(index + 2))) {
        throw FormatException('$field 查询参数包含无效百分号编码');
      }
      index += 2;
    }
  }
  return (path: path, query: query);
}

bool _isHexDigit(int value) =>
    (value >= 0x30 && value <= 0x39) ||
    (value >= 0x41 && value <= 0x46) ||
    (value >= 0x61 && value <= 0x66);

String _safeArchivePath(String value) {
  final path = value.replaceAll('\\', '/');
  if (path.isEmpty ||
      path.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path) ||
      path.contains('%') ||
      path.contains('?') ||
      path.contains('#') ||
      path.runes.any((value) => value < 0x20 || value == 0x7f) ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('游戏包包含不安全路径: $value');
  }
  final first = path.split('/').first.toLowerCase();
  if (first == 'playmesh' || first == 'bucket') {
    throw FormatException('游戏包占用平台运行时目录: $value');
  }
  return path;
}
