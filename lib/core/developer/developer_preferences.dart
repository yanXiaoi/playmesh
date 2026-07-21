import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../library/playmesh_library_root.dart';
import 'developer_channel.dart';

class DeveloperPreferences {
  DeveloperPreferences({Directory? libraryRoot}) : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<DeveloperWorkspacePreference> load() async {
    final file = await _settingsFile();
    if (!await file.exists()) return _createDefault();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('开发者设置根节点必须是对象');
    final port = decoded['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('开发者端口必须在 1 到 65535 之间');
    }
    final token = decoded['token'];
    if (token is! String || token.length < 8 || token.length > 128) {
      throw const FormatException('开发者 token 必须在 8 到 128 个字符之间');
    }
    final path = decoded['path'];
    if (path is! String || !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(path)) {
      throw const FormatException('开发者工作区路径无效');
    }
    return DeveloperWorkspacePreference(port: port, token: token, path: path);
  }

  Future<void> save(DeveloperWorkspacePreference preference) async {
    if (preference.port < 1 || preference.port > 65535) {
      throw const FormatException('开发者端口必须在 1 到 65535 之间');
    }
    if (preference.token.length < 8 || preference.token.length > 128) {
      throw const FormatException('开发者 token 必须在 8 到 128 个字符之间');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(preference.path)) {
      throw const FormatException('开发者工作区路径无效');
    }
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'port': preference.port,
        'token': preference.token,
        'path': preference.path,
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  DeveloperWorkspacePreference _createDefault() {
    return DeveloperWorkspacePreference(
      port: defaultDeveloperPort,
      token: _randomHex(32),
      path: _randomHex(16),
    );
  }

  Future<File> _settingsFile() async {
    final cached = _resolvedRoot;
    final root = cached ?? _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    _resolvedRoot = root;
    return File(
      '${root.path}${Platform.pathSeparator}developer'
      '${Platform.pathSeparator}settings.json',
    );
  }
}

String _randomHex(int byteCount) {
  final random = Random.secure();
  return List.generate(
    byteCount,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
