import 'dart:convert';
import 'dart:io';

import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../game_package/game_library_repository.dart';
import '../game_package/game_package_transfer_service.dart';
import 'game_catalog_models.dart';

class GameCatalogServer {
  GameCatalogServer(this._library, this._transfer);

  final GameLibraryRepository _library;
  final GamePackageTransferService _transfer;
  HttpServer? _server;
  String _token = '';

  bool get running => _server != null;
  int? get port => _server?.port;

  Future<void> start({required int port, required String token}) async {
    if (port < 1 || port > 65535) {
      throw const FormatException('游戏源端口必须在 1 到 65535 之间');
    }
    await stop();
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
        case '/apps/list':
          await _list(request);
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
      final manifest = await _manifest(game);
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
      matches.add(_CatalogEntry(game: game, manifest: manifest));
    }
    matches.sort((left, right) {
      final byName = left.manifest.name.compareTo(right.manifest.name);
      return byName != 0
          ? byName
          : left.manifest.id.compareTo(right.manifest.id);
    });
    final start = ((page - 1) * size).clamp(0, matches.length);
    final end = (start + size).clamp(start, matches.length);
    await _json(request.response, HttpStatus.ok, {
      'total': matches.length,
      'current': page,
      'size': size,
      'data': matches
          .sublist(start, end)
          .map((entry) => entry.manifest.toJson())
          .toList(),
    });
  }

  Future<void> _download(HttpRequest request) async {
    final id = request.uri.queryParameters['id']?.trim() ?? '';
    if (id.isEmpty) throw const FormatException('缺少游戏 id');
    final games = await _library.refresh();
    GameSummary? selected;
    for (final game in games) {
      if (game.id == id) {
        selected = game;
        break;
      }
    }
    if (selected == null) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'game_not_found',
        'message': '找不到游戏 $id',
      });
      return;
    }
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-catalog-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    try {
      await _transfer.exportPackage(selected, temporary);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.headers.set(
        'Content-Disposition',
        'attachment; filename="${_downloadFilename(selected)}"',
      );
      request.response.contentLength = await temporary.length();
      await request.response.addStream(temporary.openRead());
      await request.response.close();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<GameManifest> _manifest(GameSummary game) async {
    final root = game.entry.packageRootFilePath;
    if (root == null) throw StateError('在线游戏源不能分享内置资源游戏');
    final file = File('$root${Platform.pathSeparator}main.json');
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('main.json 根节点必须是对象');
    return GameManifest.fromJson(Map<String, Object?>.from(decoded));
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
    final safeId = game.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safeVersion = game.version.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    return '$safeId-$safeVersion.playmesh.zip';
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
