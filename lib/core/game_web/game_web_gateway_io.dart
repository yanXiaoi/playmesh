import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../network/lan_endpoint_resolver.dart';
import '../storage/game_bucket_http.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_package_layout.dart';
import '../../models/game_summary.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/capability_plugin.dart';
import '../game_package/game_web_resource_provider_io.dart';
import '../game_package/game_web_resource_source.dart';
import '../game_sdk/sdk_feature_registry.dart';
import '../localization/platform_game_ui_assets.dart';
import 'game_web_gateway_contract.dart';
import 'local_tunnel_gateway_contract.dart';

Future<GameWebGateway> startGameWebGateway({
  required GameWebResourceSource source,
  required bool multiplayer,
  required String displayMode,
  required GameOrientation orientation,
  GameOrientation? controllerOrientation,
  required String gameEntryPath,
  String? controllerEntryPath,
  required String gameId,
  String gameName = 'Playmesh 游戏',
  List<String> tags = const [],
  String? gameSdkVersion,
  String? appSdkVersion,
  List<String> requiredCapabilities = const [],
  List<String> controllerRequiredCapabilities = const [],
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
  if (displayMode == 'single_screen_multiplayer' &&
      controllerOrientation == null) {
    throw const FormatException('单屏多人分享缺少控制器方向');
  }
  if (multiplayer && (coreEndpoint == null || joinCode?.isNotEmpty != true)) {
    throw const FormatException('联机分享缺少 Core 地址或联机码');
  }
  final resolvedGameSdkVersion = SdkFeatureRegistry.resolveGameSdkVersion(
    gameSdkVersion,
  );
  final resolvedAppSdkVersion = SdkFeatureRegistry.resolveAppSdkVersion(
    appSdkVersion,
  );
  final platformUiAssets = await PlatformGameUiAssets.load();
  final normalizedGameEntry = _parseHtmlEntry(
    gameEntryPath,
    field: 'entries.game',
  );
  final controllerPageRequired =
      multiplayer && displayMode == 'single_screen_multiplayer';
  final normalizedControllerEntry = controllerEntryPath == null
      ? controllerPageRequired
            ? throw const FormatException(
                'single_screen_multiplayer 必须声明 entries.controller',
              )
            : null
      : _parseHtmlEntry(controllerEntryPath, field: 'entries.controller');
  final resourceProvider = await createGameWebResourceProvider(source);
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final gateway = _IoGameWebGateway(
      server: server,
      resourceProvider: resourceProvider,
      validateRequestPaths: source.validateRequestPaths,
      multiplayer: multiplayer,
      displayMode: displayMode,
      orientation: orientation,
      controllerOrientation: controllerOrientation,
      gameEntryPath: normalizedGameEntry.path,
      gameEntryQuery: normalizedGameEntry.query,
      controllerEntryPath: normalizedControllerEntry?.path,
      controllerEntryQuery: normalizedControllerEntry?.query,
      gameId: gameId,
      gameName: gameName,
      tags: List.unmodifiable(tags),
      gameSdkVersion: resolvedGameSdkVersion,
      appSdkVersion: resolvedAppSdkVersion,
      platformUiAssets: platformUiAssets,
      requiredCapabilities: List.unmodifiable(requiredCapabilities),
      controllerRequiredCapabilities: List.unmodifiable(
        controllerRequiredCapabilities,
      ),
      coreEndpoint: coreEndpoint?.replace(
        path: '/',
        query: null,
        fragment: null,
      ),
      joinCode: joinCode,
      shareToken: shareToken,
      storage: storage,
    );
    gateway.listen();
    return gateway;
  } on Object {
    await resourceProvider.close();
    rethrow;
  }
}

class _IoGameWebGateway implements GameWebGateway {
  _IoGameWebGateway({
    required this.server,
    required this.resourceProvider,
    required this.validateRequestPaths,
    required this.multiplayer,
    required this.displayMode,
    required this.orientation,
    required this.controllerOrientation,
    required this.gameEntryPath,
    required this.gameEntryQuery,
    required this.controllerEntryPath,
    required this.controllerEntryQuery,
    required this.gameId,
    required this.gameName,
    required this.tags,
    required this.gameSdkVersion,
    required this.appSdkVersion,
    required this.platformUiAssets,
    required this.requiredCapabilities,
    required this.controllerRequiredCapabilities,
    required this.coreEndpoint,
    required this.joinCode,
    required this.shareToken,
    required this.storage,
  });

  final HttpServer server;
  final GameWebResourceProvider resourceProvider;
  final bool validateRequestPaths;
  final bool multiplayer;
  final String displayMode;
  final GameOrientation orientation;
  final GameOrientation? controllerOrientation;
  final String gameEntryPath;
  final String? gameEntryQuery;
  final String? controllerEntryPath;
  final String? controllerEntryQuery;
  final String gameId;
  final String gameName;
  final List<String> tags;
  final String gameSdkVersion;
  final String appSdkVersion;
  final PlatformGameUiAssets platformUiAssets;
  final List<String> requiredCapabilities;
  final List<String> controllerRequiredCapabilities;
  final Uri? coreEndpoint;
  final String? joinCode;
  final String shareToken;
  final GameStorageService storage;
  final StandardJsonBucketRequestLedger _standardJsonLedger =
      StandardJsonBucketRequestLedger();
  final GameBucketChunkUploadRegistry _chunkUploads =
      GameBucketChunkUploadRegistry();
  @override
  final String invitationToken = _randomSessionToken();
  final String browserSessionToken = _randomSessionToken();
  bool _closed = false;

  @override
  int get port => server.port;

  String get _browserSessionCookieName =>
      'playmesh-game-session-${server.port}';

  @override
  Uri get loopbackInvitationUri =>
      _invitationUri(Uri(scheme: 'http', host: '127.0.0.1', port: port));

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
    if (request.uri.path == playmeshGameInvitationPath) {
      if (request.uri.hasQuery) {
        await _text(request.response, HttpStatus.notFound, '页面不存在');
        return;
      }
      if (request.method == 'GET') {
        await _invitationPage(request.response);
      } else if (request.method == 'POST') {
        await _acceptInvitation(request);
      } else {
        await _text(request.response, HttpStatus.methodNotAllowed, '不支持的请求');
      }
      return;
    }
    if (await handleGameBucketRequest(
      request,
      storage: storage,
      chunkUploads: _chunkUploads,
      authorizeUpload: (request) =>
          request.headers.value(playmeshShareTokenHeader) == shareToken
          ? StandardJsonBucketAuthorization(
              'browser:$browserSessionToken',
              isAuthority: false,
            )
          : null,
      authorizeStandardJson: (request) => _hasBrowserSession(request)
          ? StandardJsonBucketAuthorization(
              'browser:$browserSessionToken',
              isAuthority: false,
            )
          : null,
      standardJsonLedger: _standardJsonLedger,
    )) {
      return;
    }
    final expectedEntryPath = playmeshGamePackageLayout.webRequestPath(
      _pageEntryPath,
    );
    if (request.method == 'GET' && request.uri.path == expectedEntryPath) {
      if (!_hasBrowserSession(request) ||
          (request.uri.hasQuery ? request.uri.query : null) !=
              _normalizedPageEntryQuery) {
        await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
        return;
      }
      await _browserPage(request);
      return;
    }
    if (request.method == 'GET' && request.uri.path == playmeshCoreTunnelPath) {
      await _coreTunnel(request);
      return;
    }
    if (request.method == 'GET' &&
        request.uri.path != '/' &&
        !_isBucketRequestPath(request.uri.path)) {
      await _asset(request);
      return;
    }
    await _text(request.response, HttpStatus.notFound, '页面不存在');
  }

  Future<void> _invitationPage(HttpResponse response) async {
    response.headers
      ..contentType = ContentType.html
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('Referrer-Policy', 'no-referrer')
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; script-src 'unsafe-inline'; "
            "connect-src 'self'; style-src 'unsafe-inline'",
      );
    response.write('''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Playmesh</title>
  <style>html,body{height:100%;margin:0;background:#111827;color:#f8fafc;font:15px system-ui}body{display:grid;place-items:center}p{max-width:32rem;padding:1.5rem;text-align:center}</style>
</head>
<body>
  <p id="status">正在进入游戏…</p>
  <script>
  (async () => {
    const status = document.getElementById("status");
    try {
      const fragment = new URLSearchParams(location.hash.slice(1));
      const inviteToken = fragment.get("$playmeshGameInvitationTokenParameter");
      history.replaceState(null, "", location.pathname);
      if (!inviteToken) throw new Error("邀请凭据缺失");
      const response = await fetch(location.pathname, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({"$playmeshGameInvitationTokenParameter": inviteToken}),
        credentials: "same-origin"
      });
      const result = await response.json();
      if (!response.ok || typeof result.entry !== "string") {
        throw new Error(result.error || "邀请已失效");
      }
      location.replace(result.entry);
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : "邀请已失效";
    }
  })();
  </script>
</body>
</html>
''');
    await response.close();
  }

  Future<void> _acceptInvitation(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json' ||
        request.contentLength < 0 ||
        request.contentLength > 4096) {
      await _jsonError(request.response, HttpStatus.badRequest, '邀请请求无效');
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map ||
          decoded[playmeshGameInvitationTokenParameter] != invitationToken) {
        await _jsonError(request.response, HttpStatus.forbidden, '邀请已失效');
        return;
      }
    } on Object {
      await _jsonError(request.response, HttpStatus.badRequest, '邀请请求无效');
      return;
    }
    request.response.cookies.add(
      Cookie(_browserSessionCookieName, browserSessionToken)
        ..httpOnly = true
        ..sameSite = SameSite.strict
        ..path = '/',
    );
    request.response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(
      jsonEncode({
        'entry': _pageEntryTarget,
        'gameId': gameId,
        'gameName': gameName,
      }),
    );
    await request.response.close();
  }

  bool _hasBrowserSession(HttpRequest request) => request.cookies.any(
    (cookie) =>
        cookie.name == _browserSessionCookieName &&
        cookie.value == browserSessionToken,
  );

  Future<void> _coreTunnel(HttpRequest request) async {
    if (!multiplayer || coreEndpoint == null) {
      await _text(request.response, HttpStatus.notFound, '连接入口不存在');
      return;
    }
    if (request.headers.value(playmeshShareTokenHeader) != invitationToken) {
      await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
      return;
    }
    final connectionTokens =
        request.headers
            .value(HttpHeaders.connectionHeader)
            ?.split(',')
            .map((value) => value.trim().toLowerCase())
            .toSet() ??
        const <String>{};
    if (!connectionTokens.contains('upgrade') ||
        request.headers.value(HttpHeaders.upgradeHeader) !=
            playmeshCoreTunnelProtocol) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    Socket? core;
    var detached = false;
    try {
      core = await Socket.connect(coreEndpoint!.host, coreEndpoint!.port);
      request.response.statusCode = HttpStatus.switchingProtocols;
      request.response.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, playmeshCoreTunnelProtocol);
      final joiningApp = await request.response.detachSocket(
        writeHeaders: true,
      );
      detached = true;
      await _bridgeSockets(joiningApp, core);
    } on Object {
      core?.destroy();
      if (!detached) {
        await _text(
          request.response,
          HttpStatus.serviceUnavailable,
          'Core 连接不可用',
        );
      }
    }
  }

  Future<void> _browserPage(HttpRequest request) async {
    final entryPath = multiplayer && displayMode == 'single_screen_multiplayer'
        ? controllerEntryPath!
        : gameEntryPath;
    final entryQuery = multiplayer && displayMode == 'single_screen_multiplayer'
        ? controllerEntryQuery
        : gameEntryQuery;
    late final LoadedGameWebResource? entry;
    try {
      entry = await resourceProvider.read(entryPath, query: entryQuery);
    } on GameWebResourceSessionExpired {
      await _text(request.response, HttpStatus.gone, '开发资源会话已过期');
      return;
    }
    if (entry == null) {
      await _text(request.response, HttpStatus.notFound, '游戏入口不存在');
      return;
    }
    late final String htmlSource;
    try {
      htmlSource = utf8.decode(entry.bytes);
    } on FormatException {
      await _text(
        request.response,
        HttpStatus.unprocessableEntity,
        '游戏入口不是 UTF-8 HTML',
      );
      return;
    }
    var html = htmlSource;
    final lastSeparator = entryPath.lastIndexOf('/');
    final basePath = lastSeparator < 0
        ? '/'
        : '/${entryPath.substring(0, lastSeparator + 1)}';
    html = html.replaceFirst('<head>', '<head><base href="$basePath">');
    final browserConfig = jsonEncode({
      '_playmeshPlatformUi': {
        ...platformUiAssets.browserCatalog.toJson(),
        'actions': {
          'share': false,
          'restart': true,
          'logs': true,
          'fullscreen': true,
          'info': true,
          'performance': true,
          'exit': true,
        },
      },
      'mode': multiplayer ? 'multiplayer' : 'solo',
      if (multiplayer)
        'coreBase': Uri(
          scheme: 'http',
          host: request.requestedUri.host,
          port: coreEndpoint!.port,
          path: '/',
        ).toString(),
      if (multiplayer) 'joinCode': joinCode,
      'shareToken': shareToken,
      'gameId': gameId,
      'gameName': gameName,
      'tags': tags,
      'orientation': _pageOrientation.manifestValue,
      'requiredCapabilities': _pageRequiredCapabilities,
      'availableCapabilities': defaultCapabilityDescriptors
          .where(
            (definition) =>
                definition.supportsPlatform(CapabilityPlatform.HTML),
          )
          .map((definition) => definition.code)
          .toList(),
      'capabilityRegistry': defaultCapabilityDescriptors
          .map((definition) => definition.toJson())
          .toList(),
      'bucketEndpoint': '/bucket',
    });
    html = html.replaceFirst(
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>',
      '<script>window.__PLAYMESH_BROWSER__=$browserConfig;</script>'
          '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'
          '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>',
    );
    await _html(request.response, html);
  }

  GameOrientation get _pageOrientation =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerOrientation!
      : orientation;

  List<String> get _pageRequiredCapabilities =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerRequiredCapabilities
      : requiredCapabilities;

  String get _pageEntryPath =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerEntryPath!
      : gameEntryPath;

  String? get _pageEntryQuery =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerEntryQuery
      : gameEntryQuery;

  String? get _normalizedPageEntryQuery =>
      _pageEntryQuery == null ? null : Uri(query: _pageEntryQuery).query;

  String get _pageEntryTarget => Uri(
    path: playmeshGamePackageLayout.webRequestPath(_pageEntryPath),
    query: _pageEntryQuery,
  ).toString();

  Future<void> _asset(HttpRequest request) async {
    final path = request.uri.path;
    if (_isPlaymeshRequestPath(path)) {
      if (!path.startsWith('/playmesh/')) {
        await _text(request.response, HttpStatus.notFound, '资源不存在');
        return;
      }
      final liveSdk = SdkFeatureRegistry.sdkFileForPublicPath(
        path.substring('/playmesh/'.length),
        gameVersion: gameSdkVersion,
        appVersion: appSdkVersion,
      );
      if (liveSdk != null) {
        request.response.headers.contentType = gameWebResourceContentType(path);
        request.response.write(liveSdk);
        await request.response.close();
        return;
      }
      final assetPath =
          'assets/playmesh-library/public/'
          '${path.substring('/playmesh/'.length)}';
      try {
        final data = await rootBundle.load(assetPath);
        request.response.headers.contentType = gameWebResourceContentType(
          assetPath,
        );
        request.response.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        await request.response.close();
      } on Object {
        await _text(request.response, HttpStatus.notFound, '资源不存在');
      }
      return;
    }

    late final String? relativePath;
    try {
      relativePath = gameWebResourceRequestPath(
        request.uri,
        validatePath: validateRequestPaths,
        gatewayName: 'GameWebGateway',
      );
    } on FormatException {
      await _text(request.response, HttpStatus.forbidden, '资源访问被拒绝');
      return;
    }
    if (relativePath == null) {
      await _text(request.response, HttpStatus.notFound, '资源不存在');
      return;
    }
    await resourceProvider.serve(request, relativePath);
  }

  @override
  Future<List<Uri>> shareLinks() async {
    final endpoints = await resolveLanEndpoints(port, includeLinkLocal: true);
    return endpoints.map(_invitationUri).toList(growable: false);
  }

  Uri _invitationUri(Uri base) => base.replace(
    path: playmeshGameInvitationPath,
    query: null,
    fragment: Uri(
      queryParameters: {playmeshGameInvitationTokenParameter: invitationToken},
    ).query,
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _chunkUploads.close();
      await server.close(force: true);
    } finally {
      await resourceProvider.close();
    }
  }
}

String _randomSessionToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Future<void> _bridgeSockets(Socket left, Socket right) async {
  final completed = Completer<void>();
  var leftWriting = Future<void>.value();
  var rightWriting = Future<void>.value();
  late final StreamSubscription<Uint8List> leftSubscription;
  late final StreamSubscription<Uint8List> rightSubscription;

  void complete() {
    if (!completed.isCompleted) completed.complete();
  }

  StreamSubscription<Uint8List> pipe(
    Socket source,
    Socket destination,
    void Function(Future<void>) updateWriting,
  ) {
    late final StreamSubscription<Uint8List> subscription;
    subscription = source.listen(
      (chunk) {
        subscription.pause();
        destination.add(chunk);
        final writing = destination.flush();
        updateWriting(writing);
        unawaited(
          writing
              .then((_) {
                if (!completed.isCompleted) subscription.resume();
              })
              .catchError((Object _) {
                complete();
              }),
        );
      },
      onError: (_) => complete(),
      onDone: complete,
      cancelOnError: true,
    );
    return subscription;
  }

  leftSubscription = pipe(left, right, (value) => rightWriting = value);
  rightSubscription = pipe(right, left, (value) => leftWriting = value);
  await completed.future;
  await leftSubscription.cancel();
  await rightSubscription.cancel();
  try {
    await Future.wait([leftWriting, rightWriting]);
  } on Object {
    // 任一方向关闭后只需等待已提交写入结束，失败不覆盖原始断开原因。
  }
  left.destroy();
  right.destroy();
}

GameWebEntryLocation _parseHtmlEntry(String path, {required String field}) =>
    playmeshGamePackageLayout.parseWebEntry(
      path,
      field: field,
      kind: GameWebEntryKind.html,
    );

bool _isPlaymeshRequestPath(String path) =>
    _isRuntimeRequestPath(path, 'playmesh');

bool _isBucketRequestPath(String path) => _isRuntimeRequestPath(path, 'bucket');

bool _isRuntimeRequestPath(String path, String namespace) {
  if (!path.startsWith('/')) return false;
  final relative = path.substring(1);
  if (relative.isEmpty) return false;
  return relative.split('/').first.toLowerCase() == namespace;
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

Future<void> _jsonError(
  HttpResponse response,
  int status,
  String message,
) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode({'error': message}));
  await response.close();
}
