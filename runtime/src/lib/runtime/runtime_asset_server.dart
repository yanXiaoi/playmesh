import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../core/game_web/game_web_gateway_contract.dart';
import '../core/game_web/local_tunnel_gateway_contract.dart';
import '../core/network/lan_endpoint_resolver.dart';
import 'runtime_package.dart';
import 'runtime_platform_ui.dart';
import 'runtime_storage.dart';

final class RuntimeShareAccess {
  const RuntimeShareAccess.multiplayer({
    required this.corePort,
    required this.joinCode,
    required this.shareToken,
  }) : multiplayer = true;

  RuntimeShareAccess.standalone()
    : multiplayer = false,
      corePort = null,
      joinCode = null,
      shareToken = _randomToken();

  final bool multiplayer;
  final int? corePort;
  final String? joinCode;
  final String shareToken;
}

final class RuntimeAssetServer {
  RuntimeAssetServer({
    required this.game,
    required this.storage,
    required this.shareAccess,
    required this.browserCapabilityRegistry,
    required this.platformUi,
  });

  static const _browserSessionCookie = 'playmesh_runtime_session';

  final RuntimeGamePackage game;
  final RuntimeStorage storage;
  final RuntimeShareAccess? shareAccess;
  final List<Map<String, Object?>> browserCapabilityRegistry;
  final RuntimePlatformUiCatalog platformUi;
  final String invitationToken = _randomToken();
  final String _browserSessionToken = _randomToken();
  HttpServer? _server;
  bool _sharingEnabled = true;

  int get port => _server?.port ?? (throw StateError('Runtime 资源网关尚未启动'));

  Uri get loopbackInvitationUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: playmeshGameInvitationPath,
    fragment: Uri(
      queryParameters: {playmeshGameInvitationTokenParameter: invitationToken},
    ).query,
  );

  Uri get entryUri {
    final server = _server;
    if (server == null) throw StateError('Runtime 资源网关尚未启动');
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/${game.manifest.gameEntry}',
      query: game.manifest.gameEntryQuery,
    );
  }

  Future<void> start() async {
    if (_server != null) return;
    await storage.load();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        await _handle(request);
      } on RuntimeStorageConflict {
        await _jsonError(
          request.response,
          HttpStatus.conflict,
          'storage_revision_conflict',
          '存储修订已发生变化',
        );
      } on FormatException catch (error) {
        await _jsonError(
          request.response,
          HttpStatus.badRequest,
          'runtime_request_invalid',
          error.message.toString(),
        );
      } on Object catch (error) {
        await _jsonError(
          request.response,
          HttpStatus.internalServerError,
          'runtime_gateway_failed',
          error.toString(),
        );
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == playmeshGameInvitationPath) {
      await _invitation(request);
      return;
    }
    if (request.uri.path == playmeshCoreTunnelPath) {
      await _coreTunnel(request);
      return;
    }
    if (request.uri.path.startsWith('/bucket/')) {
      final authorityRequest = _isLocalRequest(request);
      final requiresAuthority =
          request.uri.path == '/bucket/_playmesh-json/v1' ||
          request.method == 'POST';
      if (requiresAuthority && !authorityRequest) {
        await _jsonError(
          request.response,
          HttpStatus.forbidden,
          'not_authority',
          '只有 Authority 主机可以读写 Main Bucket',
        );
        return;
      }
      if (!authorityRequest && !_isAuthorizedBrowser(request)) {
        await _jsonError(
          request.response,
          HttpStatus.forbidden,
          'runtime_share_invalid',
          '分享链接已失效',
        );
        return;
      }
      if (request.uri.path == '/bucket/_playmesh-json/v1') {
        await _storage(request);
      } else {
        await _binaryBucket(request);
      }
      return;
    }
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (request.uri.path.startsWith('/playmesh/sdk/v1/')) {
      await _sdk(request);
      return;
    }
    await _webAsset(request);
  }

  Future<void> _webAsset(HttpRequest request) async {
    final local = _isLocalRequest(request);
    if (!local && (!_sharingEnabled || !_hasBrowserSession(request))) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('分享链接已失效');
      await request.response.close();
      return;
    }
    final relative = request.uri.path == '/'
        ? game.manifest.gameEntry
        : request.uri.path.substring(1);
    if (!_safePath(relative)) {
      throw const FormatException('资源路径不安全');
    }
    var bytes = game.readWebFile(relative);
    if (bytes == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final requestQuery = request.uri.hasQuery ? request.uri.query : null;
    final isKnownEntry =
        relative == game.manifest.gameEntry ||
        relative == game.manifest.controllerEntry;
    final isLocalEntry =
        local &&
        relative == game.manifest.gameEntry &&
        requestQuery == _normalizedQuery(game.manifest.gameEntryQuery);
    final isBrowserEntry =
        !local &&
        relative == game.manifest.sharedEntry &&
        requestQuery == _normalizedQuery(game.manifest.sharedEntryQuery);
    if (isKnownEntry) {
      if (!isLocalEntry && !isBrowserEntry) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('分享链接已失效');
        await request.response.close();
        return;
      }
      final html = utf8.decode(bytes);
      bytes = Uint8List.fromList(
        utf8.encode(
          isLocalEntry
              ? _injectNativeSdk(html)
              : _injectBrowserSdk(html, request),
        ),
      );
    }
    request.response.headers
      ..contentType = _contentType(relative)
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    request.response.add(bytes);
    await request.response.close();
  }

  String _injectNativeSdk(String html) {
    const app = '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>';
    const main = '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>';
    var output = html;
    if (output.contains(main)) {
      if (!output.contains(app)) {
        output = output.replaceFirst(main, '$app$main');
      }
      return output;
    }
    final scripts = '$app$main';
    if (output.contains('</head>')) {
      return output.replaceFirst('</head>', '$scripts</head>');
    }
    return '$scripts$output';
  }

  String _injectBrowserSdk(String html, HttpRequest request) {
    final access = shareAccess;
    if (access == null) throw StateError('当前游戏不支持分享');
    final host = request.requestedUri.host;
    if (host.isEmpty) throw const FormatException('分享请求 Host 无效');
    final availableCapabilities = <String>[
      for (final descriptor in browserCapabilityRegistry)
        if ((descriptor['supportedPlatforms'] as List<Object?>? ?? const [])
            .contains('HTML'))
          descriptor['code']! as String,
    ];
    final config = jsonEncode({
      '_playmeshPlatformUi': platformUi.browserConfiguration(),
      'mode': access.multiplayer ? 'multiplayer' : 'solo',
      if (access.multiplayer)
        'coreBase': Uri(
          scheme: 'http',
          host: host,
          port: access.corePort!,
          path: '/',
        ).toString(),
      if (access.multiplayer) 'joinCode': access.joinCode,
      'shareToken': access.shareToken,
      'gameId': game.manifest.id,
      'gameName': game.manifest.name,
      'tags': game.manifest.tags,
      'orientation': game.manifest.sharedOrientation,
      'displayMode': game.manifest.displayMode,
      'requiredCapabilities': game.manifest.sharedRequiredCapabilities,
      'availableCapabilities': availableCapabilities,
      'capabilityRegistry': browserCapabilityRegistry,
      'bucketEndpoint': '/bucket',
      'playerSource': 'lan_html',
    }).replaceAll('<', r'\u003c');
    final bootstrap = '<script>window.__PLAYMESH_BROWSER__=$config;</script>';
    const app = '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>';
    const main = '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>';
    var output = html;
    if (output.contains(main)) {
      if (!output.contains(app)) {
        output = output.replaceFirst(main, '$app$main');
      }
      return output.replaceFirst(app, '$bootstrap$app');
    }
    final scripts = '$bootstrap$app$main';
    if (output.contains('</head>')) {
      return output.replaceFirst('</head>', '$scripts</head>');
    }
    return '$scripts$output';
  }

  Future<void> _invitation(HttpRequest request) async {
    if (request.uri.hasQuery || shareAccess == null || !_sharingEnabled) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    switch (request.method) {
      case 'GET':
        await _invitationPage(request.response);
      case 'POST':
        await _acceptInvitation(request);
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
    }
  }

  Future<void> _coreTunnel(HttpRequest request) async {
    final access = shareAccess;
    if (access == null || !access.multiplayer || !_sharingEnabled) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final tunnelToken = request.headers.value(playmeshShareTokenHeader);
    if (tunnelToken == null ||
        !_constantTimeEqual(tunnelToken, invitationToken)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
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
      core = await Socket.connect(
        InternetAddress.loopbackIPv4,
        access.corePort!,
      );
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
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      }
    }
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
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Playmesh</title><style>html,body{height:100%;margin:0;background:#111827;color:#f8fafc;font:15px system-ui}body{display:grid;place-items:center}p{max-width:32rem;padding:1.5rem;text-align:center}</style></head>
<body><p id="status">正在进入游戏…</p><script>
(async()=>{const status=document.getElementById("status");try{const fragment=new URLSearchParams(location.hash.slice(1));const inviteToken=fragment.get("$playmeshGameInvitationTokenParameter");history.replaceState(null,"",location.pathname);if(!inviteToken)throw new Error("邀请凭据缺失");const response=await fetch(location.pathname,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({"$playmeshGameInvitationTokenParameter":inviteToken}),credentials:"same-origin"});const result=await response.json();if(!response.ok||typeof result.entry!=="string")throw new Error(result.error||"邀请已失效");location.replace(result.entry)}catch(error){status.textContent=error instanceof Error?error.message:"邀请已失效"}})();
</script></body></html>
''');
    await response.close();
  }

  Future<void> _acceptInvitation(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json' ||
        request.contentLength < 0 ||
        request.contentLength > 4096) {
      await _jsonError(
        request.response,
        HttpStatus.badRequest,
        'runtime_invitation_invalid',
        '邀请请求无效',
      );
      return;
    }
    try {
      final decoded = jsonDecode(await utf8.decoder.bind(request).join());
      final supplied = decoded is Map
          ? decoded[playmeshGameInvitationTokenParameter]
          : null;
      if (supplied is! String ||
          !_constantTimeEqual(supplied, invitationToken)) {
        await _jsonError(
          request.response,
          HttpStatus.forbidden,
          'runtime_invitation_expired',
          '邀请已失效',
        );
        return;
      }
    } on Object {
      await _jsonError(
        request.response,
        HttpStatus.badRequest,
        'runtime_invitation_invalid',
        '邀请请求无效',
      );
      return;
    }
    request.response.cookies.add(
      Cookie(_browserSessionCookie, _browserSessionToken)
        ..httpOnly = true
        ..sameSite = SameSite.strict
        ..path = '/',
    );
    request.response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(
      jsonEncode({
        'entry': Uri(
          path: '/${game.manifest.sharedEntry}',
          query: game.manifest.sharedEntryQuery,
        ).toString(),
        'gameId': game.manifest.id,
        'gameName': game.manifest.name,
      }),
    );
    await request.response.close();
  }

  bool _isLocalRequest(HttpRequest request) =>
      (request.connectionInfo?.remoteAddress.isLoopback ?? false) &&
      !_hasBrowserSession(request);

  bool _hasBrowserSession(HttpRequest request) => request.cookies.any(
    (cookie) =>
        cookie.name == _browserSessionCookie &&
        _constantTimeEqual(cookie.value, _browserSessionToken),
  );

  bool _isAuthorizedBrowser(HttpRequest request) {
    if (!_sharingEnabled) return false;
    if (_hasBrowserSession(request)) return true;
    final access = shareAccess;
    final supplied = request.headers.value('X-Playmesh-Share-Token');
    return access != null &&
        supplied != null &&
        _constantTimeEqual(supplied, access.shareToken);
  }

  Future<List<Uri>> shareLinks() async {
    if (shareAccess == null || !_sharingEnabled) return const [];
    final endpoints = await resolveLanEndpoints(port, includeLinkLocal: true);
    return endpoints
        .map(
          (base) => base.replace(
            path: playmeshGameInvitationPath,
            query: null,
            fragment: Uri(
              queryParameters: {
                playmeshGameInvitationTokenParameter: invitationToken,
              },
            ).query,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _sdk(HttpRequest request) async {
    final filename = request.uri.pathSegments.last;
    if (!const {
      'playmesh-app.js',
      'playmesh-main.js',
      'playmesh-app.d.ts',
      'playmesh-main.d.ts',
    }.contains(filename)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final data = await rootBundle.load(
      'assets/playmesh-library/public/sdk/v1/$filename',
    );
    request.response.headers
      ..contentType = _contentType(filename)
      ..set(
        HttpHeaders.cacheControlHeader,
        'public, max-age=31536000, immutable',
      );
    request.response.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await request.response.close();
  }

  Future<void> _storage(HttpRequest request) async {
    final body = switch (request.method) {
      'GET' ||
      'DELETE' => _decodePayload(request.uri.queryParameters['payload']),
      'PUT' => await utf8.decoder.bind(request).join(),
      _ => throw const FormatException('存储 HTTP 方法不受支持'),
    };
    final expectedDigest = request.headers.value('x-playmesh-content-sha256');
    if (expectedDigest == null ||
        sha256.convert(utf8.encode(body)).toString() != expectedDigest) {
      throw const FormatException('存储请求摘要不匹配');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('存储请求必须是对象');
    final envelope = Map<String, Object?>.from(decoded);
    if (envelope['protocolVersion'] != '1.0.0') {
      throw const FormatException('存储协议版本不受支持');
    }
    final requestGameId = envelope['gameId'];
    if (requestGameId != game.manifest.id &&
        requestGameId != '@playmesh-current-game') {
      throw const FormatException('存储请求不属于当前游戏');
    }
    final result = await storage.execute(envelope);
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'protocolVersion': '1.0.0',
        'requestId': envelope['requestId'],
        'result': result,
      }),
    );
    await request.response.close();
  }

  Future<void> _binaryBucket(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (request.method == 'POST' && segments.length == 2) {
      final originalName = request.uri.queryParameters['name'];
      if (originalName == null || originalName.isEmpty) {
        await _jsonError(
          request.response,
          HttpStatus.badRequest,
          'runtime_upload_name_missing',
          '缺少上传文件名',
        );
        return;
      }
      try {
        final url = await storage.upload(
          bucket: segments[1],
          originalName: originalName,
          data: request,
          contentLength: request.contentLength < 0
              ? null
              : request.contentLength,
        );
        request.response.statusCode = HttpStatus.created;
        request.response.headers
          ..contentType = ContentType.json
          ..set(HttpHeaders.cacheControlHeader, 'no-store')
          ..set('X-Content-Type-Options', 'nosniff');
        request.response.write(jsonEncode({'url': url}));
        await request.response.close();
      } on FormatException catch (error) {
        await _jsonError(
          request.response,
          error.message.toString().contains('256 MiB')
              ? HttpStatus.requestEntityTooLarge
              : HttpStatus.badRequest,
          'runtime_upload_invalid',
          error.message.toString(),
        );
      }
      return;
    }

    if (request.method == 'GET' && segments.length == 3) {
      try {
        final file = storage.dataFile(segments[1], segments[2]);
        if (!await file.exists()) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        request.response.headers
          ..contentType = _contentType(file.path)
          ..set('X-Content-Type-Options', 'nosniff');
        if (segments[1] == RuntimeStorage.systemAvatarBucket) {
          final playerId = segments[2].substring(0, segments[2].length - 4);
          final etag = await storage.avatarEtag(playerId);
          request.response.headers
            ..set(HttpHeaders.cacheControlHeader, 'private, no-cache')
            ..set(HttpHeaders.etagHeader, etag);
          if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
            request.response.statusCode = HttpStatus.notModified;
            await request.response.close();
            return;
          }
        } else {
          request.response.headers.set(
            HttpHeaders.cacheControlHeader,
            'public, max-age=31536000, immutable',
          );
        }
        request.response.contentLength = await file.length();
        await file.openRead().pipe(request.response);
      } on FormatException {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
      return;
    }

    request.response.statusCode =
        request.method == 'GET' || request.method == 'POST'
        ? HttpStatus.notFound
        : HttpStatus.methodNotAllowed;
    await request.response.close();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void revokeSharing() {
    _sharingEnabled = false;
  }
}

String _randomToken() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(24, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

bool _constantTimeEqual(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = max(leftBytes.length, rightBytes.length);
  for (var index = 0; index < length; index += 1) {
    final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

String _decodePayload(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    throw const FormatException('存储请求缺少 payload');
  }
  final normalized = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
  return utf8.decode(base64Url.decode(normalized));
}

bool _safePath(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..');

String? _normalizedQuery(String? value) =>
    value == null ? null : Uri(query: value).query;

ContentType _contentType(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'html' => ContentType.html,
    'js' || 'mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
    'css' => ContentType('text', 'css', charset: 'utf-8'),
    'json' || 'map' => ContentType.json,
    'svg' => ContentType('image', 'svg+xml'),
    'png' => ContentType('image', 'png'),
    'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
    'webp' => ContentType('image', 'webp'),
    'wasm' => ContentType('application', 'wasm'),
    'mp3' => ContentType('audio', 'mpeg'),
    'ogg' => ContentType('audio', 'ogg'),
    'wav' => ContentType('audio', 'wav'),
    'mp4' => ContentType('video', 'mp4'),
    _ => ContentType.binary,
  };
}

Future<void> _jsonError(
  HttpResponse response,
  int status,
  String code,
  String message,
) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(
    jsonEncode({
      'error': {'code': code, 'message': message},
    }),
  );
  await response.close();
}

Future<void> _bridgeSockets(Socket left, Socket right) async {
  final completed = Completer<void>();
  late final StreamSubscription<List<int>> leftSubscription;
  late final StreamSubscription<List<int>> rightSubscription;

  void finish() {
    if (!completed.isCompleted) completed.complete();
  }

  StreamSubscription<List<int>> pipe(Socket source, Socket destination) {
    late final StreamSubscription<List<int>> subscription;
    subscription = source.listen(
      (bytes) {
        subscription.pause();
        destination.add(bytes);
        destination.flush().then<void>(
          (_) => subscription.resume(),
          onError: (_) => finish(),
        );
      },
      onError: (_) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
    return subscription;
  }

  leftSubscription = pipe(left, right);
  rightSubscription = pipe(right, left);
  await completed.future;
  await leftSubscription.cancel();
  await rightSubscription.cancel();
  left.destroy();
  right.destroy();
}
