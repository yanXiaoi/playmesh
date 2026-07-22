import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../network/lan_endpoint_resolver.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_manifest.dart';
import '../capabilities/default_capability_plugins.dart';
import 'game_web_gateway_contract.dart';

Future<GameWebGateway> startGameWebGateway({
  required String gameRootAssetPath,
  String? gameRootFilePath,
  required bool multiplayer,
  required String displayMode,
  String gameEntryPath = 'app/index.html',
  String controllerEntryPath = 'app/controller/index.html',
  String gameId = 'com.playmesh.unknown',
  String gameName = 'Playmesh 游戏',
  List<String> requiredCapabilities = const [],
  Uri? coreEndpoint,
  String? joinCode,
  required String shareToken,
  required GameStorageService storage,
}) async {
  if (displayMode != 'multi_screen' &&
      displayMode != 'single_screen_multiplayer') {
    throw FormatException('不支持的浏览器分享显示模式: $displayMode');
  }
  if (!multiplayer && displayMode != 'multi_screen') {
    throw const FormatException('单机分享必须使用 multi_screen');
  }
  if (multiplayer && (coreEndpoint == null || joinCode?.isNotEmpty != true)) {
    throw const FormatException('联机分享缺少 Core 地址或联机码');
  }
  _appRelativeHtmlEntry(gameEntryPath, field: 'entries.game');
  _appRelativeHtmlEntry(controllerEntryPath, field: 'entries.controller');
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  final gateway = _IoGameWebGateway(
    server: server,
    gameRootAssetPath: gameRootAssetPath,
    gameRootFilePath: gameRootFilePath,
    multiplayer: multiplayer,
    displayMode: displayMode,
    gameEntryPath: gameEntryPath,
    controllerEntryPath: controllerEntryPath,
    gameId: gameId,
    gameName: gameName,
    requiredCapabilities: List.unmodifiable(requiredCapabilities),
    coreEndpoint: coreEndpoint?.replace(path: '/', query: null, fragment: null),
    joinCode: joinCode,
    shareToken: shareToken,
    storage: storage,
  );
  gateway.listen();
  return gateway;
}

class _IoGameWebGateway implements GameWebGateway {
  _IoGameWebGateway({
    required this.server,
    required this.gameRootAssetPath,
    this.gameRootFilePath,
    required this.multiplayer,
    required this.displayMode,
    required this.gameEntryPath,
    required this.controllerEntryPath,
    required this.gameId,
    required this.gameName,
    required this.requiredCapabilities,
    required this.coreEndpoint,
    required this.joinCode,
    required this.shareToken,
    required this.storage,
  });

  final HttpServer server;
  final String gameRootAssetPath;
  final String? gameRootFilePath;
  final bool multiplayer;
  final String displayMode;
  final String gameEntryPath;
  final String controllerEntryPath;
  final String gameId;
  final String gameName;
  final List<String> requiredCapabilities;
  final Uri? coreEndpoint;
  final String? joinCode;
  final String shareToken;
  final GameStorageService storage;

  @override
  int get port => server.port;

  void listen() {
    server.listen((request) async {
      try {
        await _handle(request);
      } on Object catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('浏览器游戏加载失败: $error');
        await request.response.close();
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final expectedJoinPath = multiplayer ? '/join/$joinCode' : '/play';
    if (request.uri.path == expectedJoinPath) {
      if (request.uri.queryParameters['token'] != shareToken) {
        await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
        return;
      }
      await _browserPage(request);
      return;
    }
    if (request.uri.path == '/api/join' && request.method == 'POST') {
      await _proxyJoin(request);
      return;
    }
    if (request.uri.path == '/api/storage' && request.method == 'POST') {
      await _storage(request);
      return;
    }
    if (request.uri.path == '/api/player/nickname' &&
        request.method == 'POST') {
      await _proxyNickname(request);
      return;
    }
    if (request.uri.path == '/api/app-capabilities' &&
        request.method == 'GET') {
      if (request.uri.queryParameters['token'] != shareToken) {
        await _json(request.response, HttpStatus.forbidden, {
          'error': '分享链接已失效',
        });
        return;
      }
      await _json(request.response, HttpStatus.ok, {
        'gameId': gameId,
        'gameName': gameName,
        'required': requiredCapabilities,
        'capabilityRegistry': defaultCapabilityDescriptors
            .map((definition) => definition.toJson())
            .toList(),
      });
      return;
    }
    if (request.method == 'GET' &&
        (request.uri.path.startsWith('/app/') ||
            request.uri.path.startsWith('/playmesh/'))) {
      await _asset(request);
      return;
    }
    await _text(request.response, HttpStatus.notFound, '页面不存在');
  }

  Future<void> _proxyJoin(HttpRequest request) async {
    if (!multiplayer) {
      await _text(request.response, HttpStatus.notFound, '单机分享不提供会话加入');
      return;
    }
    final rawBody = await utf8.decoder.bind(request).join();
    final body = jsonDecode(rawBody);
    if (body is! Map || body['shareToken'] != shareToken) {
      await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
      return;
    }
    final client = HttpClient();
    try {
      final proxy = await client.postUrl(
        coreEndpoint!.resolve('v1/sessions/join'),
      );
      proxy.headers.contentType = ContentType.json;
      proxy.write(
        jsonEncode({
          'joinCode': joinCode,
          'nickname': body['nickname'],
          'shareToken': shareToken,
          if (body['playerId'] case final String playerId) 'playerId': playerId,
        }),
      );
      final response = await proxy.close();
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType = ContentType.json;
      await response.pipe(request.response);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _proxyNickname(HttpRequest request) async {
    if (!multiplayer) {
      await _text(request.response, HttpStatus.notFound, '单机分享不提供玩家昵称');
      return;
    }
    final rawBody = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map || decoded['shareToken'] != shareToken) {
      await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
      return;
    }
    final body = Map<String, Object?>.from(decoded);
    final sessionID = _requiredString(body, 'sessionId');
    final playerToken = _requiredString(body, 'playerToken');
    final nickname = _requiredString(body, 'nickname');
    final client = HttpClient();
    try {
      final proxy = await client.patchUrl(
        coreEndpoint!.resolve(
          'v1/sessions/${Uri.encodeComponent(sessionID)}/players/me',
        ),
      );
      proxy.headers.contentType = ContentType.json;
      proxy.headers.set(HttpHeaders.authorizationHeader, 'Bearer $playerToken');
      proxy.write(jsonEncode({'nickname': nickname}));
      final response = await proxy.close();
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType = ContentType.json;
      await response.pipe(request.response);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _storage(HttpRequest request) async {
    final rawBody = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map || decoded['shareToken'] != shareToken) {
      await _json(request.response, HttpStatus.forbidden, {'error': '分享链接已失效'});
      return;
    }
    final body = Map<String, Object?>.from(decoded);
    try {
      final command = body['command'];
      final bucket = _requiredString(body, 'bucket');
      Object? result;
      switch (command) {
        case 'storage.get':
          result = await storage.getData(bucket, _requiredString(body, 'key'));
          break;
        case 'storage.set':
          await storage.setData(
            bucket,
            _requiredString(body, 'key'),
            body['value'],
          );
          break;
        case 'storage.remove':
          await storage.removeData(bucket, _requiredString(body, 'key'));
          break;
        case 'storage.clear':
          await storage.clearData(bucket);
          break;
        default:
          throw const FormatException('未知存储命令');
      }
      await _json(request.response, HttpStatus.ok, {'result': result});
    } on Object catch (error) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': error.toString(),
      });
    }
  }

  Future<void> _browserPage(HttpRequest request) async {
    final entryPath = multiplayer && displayMode == 'single_screen_multiplayer'
        ? controllerEntryPath
        : gameEntryPath;
    final relativePath = _appRelativeHtmlEntry(
      entryPath,
      field: entryPath == controllerEntryPath
          ? 'entries.controller'
          : 'entries.game',
    );
    var html = gameRootFilePath == null
        ? await rootBundle.loadString('$gameRootAssetPath/$entryPath')
        : await File(
            '${gameRootFilePath!}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
          ).readAsString();
    final lastSeparator = relativePath.lastIndexOf('/');
    final basePath = lastSeparator < 0
        ? '/app/'
        : '/app/${relativePath.substring(0, lastSeparator + 1)}';
    html = html.replaceFirst('<head>', '<head><base href="$basePath">');
    final browserConfig = jsonEncode({
      'mode': multiplayer ? 'multiplayer' : 'solo',
      if (multiplayer) 'joinEndpoint': '/api/join',
      if (multiplayer)
        'coreBase': Uri(
          scheme: 'http',
          host: request.requestedUri.host,
          port: coreEndpoint!.port,
          path: '/',
        ).toString(),
      if (multiplayer) 'joinCode': joinCode,
      'shareToken': shareToken,
      'gameName': gameName,
      'requiredCapabilities': requiredCapabilities,
      'availableCapabilities': defaultCapabilityDescriptors
          .where((definition) => definition.htmlSupported)
          .map((definition) => definition.code)
          .toList(),
      'capabilityRegistry': defaultCapabilityDescriptors
          .map((definition) => definition.toJson())
          .toList(),
      'storageEndpoint': '/api/storage',
      if (multiplayer) 'nicknameEndpoint': '/api/player/nickname',
      'nickname': ?request.uri.queryParameters['playmeshNickname'],
    });
    html = html.replaceFirst(
      '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
      '<script>window.__PLAYMESH_BROWSER__=$browserConfig;</script>'
          '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
    );
    if (request.uri.queryParameters['playmeshApp'] == '1') {
      html = html.replaceFirst(
        '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
        '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'
            '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
      );
    }
    await _html(request.response, html);
  }

  Future<void> _asset(HttpRequest request) async {
    final path = request.uri.path;
    if (path.contains('..')) {
      await _text(request.response, HttpStatus.forbidden, '资源访问被拒绝');
      return;
    }
    if (path.startsWith('/app/') && gameRootFilePath != null) {
      final relative = path.substring('/app/'.length);
      final file = File(
        '${gameRootFilePath!}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await file.exists()) {
        await _text(request.response, HttpStatus.notFound, '资源不存在');
        return;
      }
      request.response.headers.contentType = _contentType(file.path);
      await file.openRead().pipe(request.response);
      return;
    }
    final assetPath = path.startsWith('/app/')
        ? '$gameRootAssetPath/app/${path.substring('/app/'.length)}'
        : 'assets/playmesh-library/public/'
              '${path.substring('/playmesh/'.length)}';
    try {
      final data = await rootBundle.load(assetPath);
      request.response.headers.contentType = _contentType(assetPath);
      request.response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await request.response.close();
    } on Object {
      await _text(request.response, HttpStatus.notFound, '资源不存在');
    }
  }

  @override
  Future<List<Uri>> shareLinks() async {
    final endpoints = await resolveLanEndpoints(port);
    final bases = endpoints.isEmpty
        ? [Uri(scheme: 'http', host: '127.0.0.1', port: port)]
        : endpoints;
    return bases
        .map(
          (base) => base.replace(
            path: multiplayer ? '/join/$joinCode' : '/play',
            queryParameters: {'token': shareToken},
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() => server.close(force: true);
}

String _appRelativeHtmlEntry(String path, {required String field}) {
  final normalized = validateGamePackagePath(path, field: field);
  if (!normalized.startsWith('app/') ||
      !normalized.toLowerCase().endsWith('.html')) {
    throw FormatException('$field 必须指向 app/ 内的 HTML 文件');
  }
  return normalized.substring('app/'.length);
}

Future<void> _html(HttpResponse response, String body) async {
  response.headers.contentType = ContentType.html;
  response.write(body);
  await response.close();
}

Future<void> _text(HttpResponse response, int status, String body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
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

String _requiredString(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}

ContentType _contentType(String path) {
  if (path.endsWith('.html')) {
    return ContentType.html;
  }
  if (path.endsWith('.js')) {
    return ContentType('text', 'javascript', charset: 'utf-8');
  }
  if (path.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (path.endsWith('.json')) {
    return ContentType.json;
  }
  if (path.endsWith('.png')) {
    return ContentType('image', 'png');
  }
  return ContentType.binary;
}
