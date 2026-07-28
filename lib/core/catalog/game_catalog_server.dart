import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../game_package/game_library_repository.dart';
import '../game_package/game_package_transfer_service.dart';
import '../game_package/game_package_icon.dart';
import '../game_package/game_package_share_files.dart';
import '../version/semantic_version.dart';
import 'game_catalog_models.dart';

class GameCatalogServer {
  GameCatalogServer(
    this._library,
    this._transfer, {
    required this._nicknameProvider,
    GamePackageShareFiles? shareFiles,
  }) : _shareFiles = shareFiles ?? GamePackageShareFiles();

  final GameLibraryRepository _library;
  final GamePackageTransferService _transfer;
  final String Function() _nicknameProvider;
  final GamePackageShareFiles _shareFiles;
  HttpServer? _server;
  String _token = '';
  Future<void> _downloadTail = Future<void>.value();

  bool get running => _server != null;
  int? get port => _server?.port;

  Future<void> start({required int port, required String token}) async {
    if (port < 1 || port > 65535) {
      throw const FormatException('游戏源端口必须在 1 到 65535 之间');
    }
    await stop();
    await _shareFiles.cleanup();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    _token = token.trim();
    server.listen(_handle, onError: (_) => stop());
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    _cors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    try {
      if (!_authorized(request)) {
        await _json(request.response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
          'message': '需要有效的 Bearer Token',
        });
        return;
      }
      if (request.method != 'GET') {
        await _json(request.response, HttpStatus.methodNotAllowed, {
          'error': 'method_not_allowed',
        });
        return;
      }
      switch (request.uri.path) {
        case '/apps/info':
          await _info(request);
        case '/apps/list':
          await _list(request);
        case '/apps/icon':
          await _icon(request);
        case '/apps/download':
          await _download(request);
        default:
          await _json(request.response, HttpStatus.notFound, {
            'error': 'not_found',
          });
      }
    } on FormatException catch (error) {
      try {
        await _json(request.response, HttpStatus.badRequest, {
          'error': 'invalid_request',
          'message': error.message,
        });
      } on Object {
        await request.response.close();
      }
    } on Object catch (error) {
      try {
        await _json(request.response, HttpStatus.internalServerError, {
          'error': 'internal_error',
          'message': error.toString(),
        });
      } on Object {
        await request.response.close();
      }
    }
  }

  Future<void> _info(HttpRequest request) async {
    final nickname = _nicknameProvider().trim();
    await _json(request.response, HttpStatus.ok, {
      'catalogApiVersion': gameCatalogApiVersion,
      'name': '${nickname.isEmpty ? 'Playmesh 用户' : nickname}的游戏库',
      'author': 'Playmesh App',
      'supportsGameRelay': false,
      'userUpload': {'supported': false},
    });
  }

  bool _authorized(HttpRequest request) {
    if (_token.isEmpty) return true;
    return request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $_token';
  }

  Future<void> _list(HttpRequest request) async {
    final page = _positiveInt(request.uri.queryParameters['page'], 1, 'page');
    final size = _positiveInt(request.uri.queryParameters['size'], 10, 'size');
    if (size > 100) throw const FormatException('size 不能超过 100');
    final name = (request.uri.queryParameters['s_name'] ?? '').toLowerCase();
    final tag = (request.uri.queryParameters['s_tag'] ?? '').toLowerCase();
    final description = (request.uri.queryParameters['s_desc'] ?? '')
        .toLowerCase();
    final games = await _library.refresh();
    final matches = <_CatalogEntry>[];
    for (final game in games) {
      final entry = await _publicEntry(game);
      if (entry == null) continue;
      final manifest = entry.manifest;
      if (name.isNotEmpty && !manifest.name.toLowerCase().contains(name)) {
        continue;
      }
      if (tag.isNotEmpty &&
          !manifest.tags.any((value) => value.toLowerCase().contains(tag))) {
        continue;
      }
      if (description.isNotEmpty &&
          !manifest.remarks.toLowerCase().contains(description)) {
        continue;
      }
      matches.add(entry);
    }
    matches.sort(
      (left, right) =>
          compareGameManifestsNewestFirst(left.manifest, right.manifest),
    );
    final start = ((page - 1) * size).clamp(0, matches.length);
    final end = (start + size).clamp(start, matches.length);
    await _json(request.response, HttpStatus.ok, {
      'total': matches.length,
      'current': page,
      'size': size,
      'data': matches.sublist(start, end).map((entry) {
        final json = entry.manifest.toJson();
        final icon = File(
          '${entry.game.entry.packageRootFilePath}'
          '${Platform.pathSeparator}$gamePackageIconName',
        );
        if (icon.existsSync() && isSafeGamePackageIconSync(icon)) {
          json['icon'] = request.requestedUri
              .replace(
                path: '/apps/icon',
                queryParameters: {
                  'id': entry.manifest.id,
                  'version': entry.manifest.version,
                },
              )
              .toString();
        }
        return json;
      }).toList(),
    });
  }

  Future<void> _download(HttpRequest request) =>
      _serializeDownload(() => _downloadNow(request));

  Future<void> _downloadNow(HttpRequest request) async {
    final id = request.uri.queryParameters['id']?.trim() ?? '';
    final version = request.uri.queryParameters['version']?.trim() ?? '';
    if (id.isEmpty) throw const FormatException('缺少游戏 id');
    if (version.isEmpty) throw const FormatException('缺少游戏 version');
    SemanticVersion.parse(version);
    final games = await _library.refresh();
    final selected = await _findPublicEntry(games, id: id, version: version);
    if (selected == null) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'version_not_available',
        'message': '指定版本不是当前可用版本',
      });
      return;
    }
    final temporary = await _shareFiles.create(selected.game);
    try {
      await _transfer.exportPackage(selected.game, temporary);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.headers.set(
        'Content-Disposition',
        'attachment; filename="${_downloadFilename(selected.game)}"',
      );
      request.response.contentLength = await temporary.length();
      await request.response.addStream(temporary.openRead());
      await request.response.close();
    } finally {
      await _shareFiles.complete(temporary, deleteNow: true);
    }
  }

  Future<void> _icon(HttpRequest request) async {
    final id = request.uri.queryParameters['id']?.trim() ?? '';
    final version = request.uri.queryParameters['version']?.trim() ?? '';
    if (id.isEmpty || version.isEmpty) {
      throw const FormatException('图标请求必须指定 id 和 version');
    }
    SemanticVersion.parse(version);
    final games = await _library.refresh();
    final selected = await _findPublicEntry(games, id: id, version: version);
    if (selected == null || selected.game.entry.packageRootFilePath == null) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'version_not_available',
      });
      return;
    }
    final icon = File(
      '${selected.game.entry.packageRootFilePath}'
      '${Platform.pathSeparator}$gamePackageIconName',
    );
    if (!await isSafeGamePackageIcon(icon)) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'icon_not_found',
      });
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.contentLength = await icon.length();
    await request.response.addStream(icon.openRead());
    await request.response.close();
  }

  Future<T> _serializeDownload<T>(Future<T> Function() action) {
    final operation = _downloadTail.then((_) => action());
    _downloadTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<GameManifest> _manifest(GameSummary game) async {
    final root = game.entry.packageRootFilePath;
    if (root == null) throw StateError('在线游戏源不能分享内置资源游戏');
    final file = File('$root${Platform.pathSeparator}main.json');
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    return GameManifest.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<_CatalogEntry?> _publicEntry(GameSummary game) async {
    if (game.manifestError != null) return null;
    try {
      final manifest = await _manifest(game);
      if (manifest.id != game.id || manifest.version != game.version) {
        return null;
      }
      return _CatalogEntry(game: game, manifest: manifest);
    } on Object {
      // A repair item or a concurrently edited package must not make the
      // entire App-owned source unavailable.
      return null;
    }
  }

  Future<_CatalogEntry?> _findPublicEntry(
    Iterable<GameSummary> games, {
    required String id,
    required String version,
  }) async {
    for (final game in games) {
      if (game.id != id || game.version != version) continue;
      final entry = await _publicEntry(game);
      if (entry != null) return entry;
    }
    return null;
  }

  int _positiveInt(String? raw, int fallback, String field) {
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value < 1) {
      throw FormatException('$field 必须是正整数');
    }
    return value;
  }

  String _downloadFilename(GameSummary game) {
    return gamePackageShareFileName(game);
  }

  void _cors(HttpResponse response) {
    response.headers
      ..set('X-Playmesh-Catalog-Version', gameCatalogApiVersion)
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
      ..set('Access-Control-Allow-Methods', 'GET, OPTIONS');
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

class _CatalogEntry {
  const _CatalogEntry({required this.game, required this.manifest});

  final GameSummary game;
  final GameManifest manifest;
}
