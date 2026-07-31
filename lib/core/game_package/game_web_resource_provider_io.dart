import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/game_package_layout.dart';
import 'game_web_resource_source.dart';

const _developmentConnectTimeout = Duration(seconds: 10);
const _developmentResponseIdleTimeout = Duration(seconds: 15);
const _developmentWebSocketCloseTimeout = Duration(seconds: 2);
const _maxDevelopmentEntryBytes = 8 * 1024 * 1024;

abstract interface class GameWebResourceProvider {
  Future<LoadedGameWebResource?> read(String relativePath, {String? query});

  Future<void> serve(HttpRequest request, String relativePath);

  Future<void> close();
}

/// 在来源边界统一解析网关请求；开发来源只移除 HTTP 根斜杠，不解释上游虚拟路径。
String? gameWebResourceRequestPath(
  Uri uri, {
  required bool validatePath,
  required String gatewayName,
}) {
  if (!validatePath) {
    final path = uri.path;
    return path == '/' ? null : path.substring(1);
  }
  try {
    final encoded = uri.toString().split('?').first;
    if (!encoded.startsWith('/') || encoded.contains('%')) {
      throw const FormatException('请求路径包含编码字符或不是绝对 Web 路径');
    }
    if (encoded == '/') return null;
    final relativePath = encoded.substring(1);
    return playmeshGamePackageLayout.validateRelativePath(
      relativePath,
      field: '游戏资源请求路径',
    );
  } on FormatException catch (error) {
    debugPrint(
      '[$gatewayName][warning] 安装态游戏资源路径被拒绝 '
      'uri=${uri.toString()} reason=${error.message}',
    );
    rethrow;
  }
}

class LoadedGameWebResource {
  const LoadedGameWebResource(this.bytes, {this.contentType});

  final List<int> bytes;
  final ContentType? contentType;
}

class GameWebResourceSessionExpired implements Exception {
  const GameWebResourceSessionExpired();
}

Future<GameWebResourceProvider> createGameWebResourceProvider(
  GameWebResourceSource source,
) async {
  return source.resolveWith(const _IoGameWebResourceSourceResolver());
}

final class _IoGameWebResourceSourceResolver
    implements GameWebResourceSourceResolver<GameWebResourceProvider> {
  const _IoGameWebResourceSourceResolver();

  @override
  GameWebResourceProvider installed({required String packageRootPath}) =>
      InstalledGameWebResourceProvider(
        Directory(
          '${Directory(packageRootPath).absolute.path}'
          '${Platform.pathSeparator}app',
        ),
      );

  @override
  GameWebResourceProvider development({
    required Uri sourceUri,
    required Map<String, String> requestHeaders,
    required DateTime expiresAt,
  }) => DevelopmentGameWebResourceProvider(
    sourceUri: sourceUri,
    requestHeaders: requestHeaders,
    expiresAt: expiresAt,
  );
}

class InstalledGameWebResourceProvider implements GameWebResourceProvider {
  InstalledGameWebResourceProvider(this.appDirectory);

  final Directory appDirectory;

  @override
  Future<LoadedGameWebResource?> read(
    String relativePath, {
    String? query,
  }) async {
    final file = await safeInstalledGameWebFile(appDirectory, relativePath);
    if (file == null) return null;
    return LoadedGameWebResource(
      await file.readAsBytes(),
      contentType: gameWebResourceContentType(file.path),
    );
  }

  @override
  Future<void> serve(HttpRequest request, String relativePath) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      await gameWebResourceText(
        request.response,
        HttpStatus.methodNotAllowed,
        '不支持的请求',
      );
      return;
    }
    final file = await safeInstalledGameWebFile(appDirectory, relativePath);
    if (file == null) {
      await gameWebResourceText(request.response, HttpStatus.notFound, '资源不存在');
      return;
    }
    request.response.headers.contentType = gameWebResourceContentType(
      file.path,
    );
    if (request.method == 'HEAD') {
      request.response.contentLength = await file.length();
      await request.response.close();
      return;
    }
    await file.openRead().pipe(request.response);
  }

  @override
  Future<void> close() async {}
}

class DevelopmentGameWebResourceProvider implements GameWebResourceProvider {
  DevelopmentGameWebResourceProvider({
    required this.sourceUri,
    required Map<String, String> requestHeaders,
    required this.expiresAt,
  }) : sourceRequestHeaders = Map.unmodifiable(requestHeaders),
       _client = _newDevelopmentHttpClient() {
    final now = DateTime.now().toUtc();
    if (sourceUri.scheme != 'http' ||
        sourceUri.host.isEmpty ||
        !sourceUri.hasPort ||
        sourceUri.userInfo.isNotEmpty ||
        (sourceUri.path.isNotEmpty && sourceUri.path != '/') ||
        sourceUri.hasQuery ||
        sourceUri.hasFragment) {
      throw const FormatException('开发资源地址必须是带端口的 HTTP 根地址');
    }
    final credential =
        requestHeaders[playmeshDevelopmentCredentialHeader] ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(credential) ||
        !expiresAt.isAfter(now)) {
      throw const FormatException('开发资源会话凭据无效或已经过期');
    }
    _expiryTimer = Timer(expiresAt.difference(now), () {
      unawaited(_expire());
    });
  }

  final Uri sourceUri;
  final Map<String, String> sourceRequestHeaders;
  final DateTime expiresAt;
  final HttpClient _client;
  final Set<WebSocket> _webSockets = <WebSocket>{};
  Timer? _expiryTimer;
  bool _closed = false;

  @override
  Future<LoadedGameWebResource?> read(
    String relativePath, {
    String? query,
  }) async {
    final response = await _request('GET', relativePath, query);
    if (response.statusCode == HttpStatus.notFound) {
      await _drain(response);
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _drain(response);
      throw HttpException('开发服务器返回 HTTP ${response.statusCode}');
    }
    final bytes = await _readEntry(response);
    return LoadedGameWebResource(
      bytes,
      contentType: response.headers.contentType,
    );
  }

  @override
  Future<void> serve(HttpRequest request, String relativePath) async {
    if (_isExpired) {
      await gameWebResourceText(request.response, HttpStatus.gone, '开发资源会话已过期');
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      await _serveWebSocket(request, relativePath);
      return;
    }
    final isRestartControl =
        relativePath == playmeshDevelopmentRestartControlPath &&
        request.method == 'POST';
    if (request.method != 'GET' &&
        request.method != 'HEAD' &&
        !isRestartControl) {
      await gameWebResourceText(
        request.response,
        HttpStatus.methodNotAllowed,
        '不支持的请求',
      );
      return;
    }
    final upstream = await _request(
      request.method,
      relativePath,
      request.uri.hasQuery ? request.uri.query : null,
      requestHeaders: request.headers,
    );
    request.response.statusCode = upstream.statusCode;
    _copyResponseHeaders(upstream.headers, request.response.headers);
    if (request.method == 'HEAD') {
      await _drain(upstream);
      await request.response.close();
      return;
    }
    await upstream
        .timeout(_developmentResponseIdleTimeout)
        .pipe(request.response);
  }

  Future<HttpClientResponse> _request(
    String method,
    String relativePath,
    String? query, {
    HttpHeaders? requestHeaders,
  }) async {
    if (_isExpired) {
      throw const GameWebResourceSessionExpired();
    }
    if (_closed) {
      throw const HttpException('开发资源会话已经关闭');
    }
    final uri = sourceUri.replace(path: '/$relativePath', query: query);
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false;
    for (final MapEntry(:key, :value) in sourceRequestHeaders.entries) {
      request.headers.set(key, value);
    }
    for (final name in const [
      HttpHeaders.acceptHeader,
      HttpHeaders.acceptEncodingHeader,
      HttpHeaders.ifModifiedSinceHeader,
      HttpHeaders.ifNoneMatchHeader,
      HttpHeaders.rangeHeader,
    ]) {
      final values = requestHeaders?[name];
      if (values != null) request.headers.set(name, values);
    }
    try {
      return await request.close().timeout(_developmentConnectTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
  }

  Future<void> _serveWebSocket(HttpRequest request, String relativePath) async {
    final upstreamUri = sourceUri.replace(
      scheme: 'ws',
      path: '/$relativePath',
      query: request.uri.hasQuery ? request.uri.query : null,
    );
    final requestedProtocols =
        request.headers['sec-websocket-protocol']
            ?.expand((value) => value.split(','))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    WebSocket? upstream;
    WebSocket? local;
    StreamSubscription<dynamic>? localSubscription;
    StreamSubscription<dynamic>? upstreamSubscription;
    try {
      upstream = await WebSocket.connect(
        upstreamUri.toString(),
        headers: sourceRequestHeaders,
        protocols: requestedProtocols.isEmpty ? null : requestedProtocols,
        customClient: _client,
      );
      _webSockets.add(upstream);
      if (_closed || _isExpired) {
        if (_isExpired) {
          await gameWebResourceText(
            request.response,
            HttpStatus.gone,
            '开发资源会话已过期',
          );
          return;
        }
        throw const HttpException('开发资源会话已经关闭');
      }
      final negotiatedProtocol = upstream.protocol;
      local = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: requestedProtocols.isEmpty
            ? null
            : (protocols) {
                if (negotiatedProtocol != null &&
                    protocols.contains(negotiatedProtocol)) {
                  return negotiatedProtocol;
                }
                return null;
              },
      );
      _webSockets.add(local);
      if (_closed || _isExpired) return;

      final done = Completer<void>();
      void complete() {
        if (!done.isCompleted) done.complete();
      }

      localSubscription = local.listen(
        upstream.add,
        onDone: complete,
        onError: (_) => complete(),
        cancelOnError: true,
      );
      upstreamSubscription = upstream.listen(
        local.add,
        onDone: complete,
        onError: (_) => complete(),
        cancelOnError: true,
      );
      await done.future;
    } finally {
      await localSubscription?.cancel();
      await upstreamSubscription?.cancel();
      await _releaseWebSocket(
        local,
        WebSocketStatus.goingAway,
        'Playmesh development proxy closed',
      );
      await _releaseWebSocket(
        upstream,
        WebSocketStatus.goingAway,
        'Playmesh development proxy closed',
      );
    }
  }

  bool get _isExpired => !DateTime.now().toUtc().isBefore(expiresAt);

  Future<List<int>> _readEntry(HttpClientResponse response) async {
    if (response.contentLength > _maxDevelopmentEntryBytes) {
      final socket = await response.detachSocket();
      socket.destroy();
      throw const HttpException('开发资源入口超过大小限制');
    }
    final bytes = BytesBuilder(copy: false);
    await response.timeout(_developmentResponseIdleTimeout).forEach((chunk) {
      if (bytes.length + chunk.length > _maxDevelopmentEntryBytes) {
        throw const HttpException('开发资源入口超过大小限制');
      }
      bytes.add(chunk);
    });
    return bytes.takeBytes();
  }

  Future<void> _drain(HttpClientResponse response) =>
      response.timeout(_developmentResponseIdleTimeout).drain<void>();

  Future<void> _expire() async {
    _client.close(force: true);
    await _closeTrackedWebSockets(
      WebSocketStatus.policyViolation,
      'Playmesh development session expired',
    );
  }

  Future<void> _closeTrackedWebSockets(int code, String reason) async {
    final sockets = _webSockets.toList(growable: false);
    _webSockets.clear();
    await Future.wait(
      sockets.map((socket) => _closeWebSocket(socket, code, reason)),
    );
  }

  Future<void> _releaseWebSocket(
    WebSocket? socket,
    int code,
    String reason,
  ) async {
    if (socket == null) return;
    _webSockets.remove(socket);
    await _closeWebSocket(socket, code, reason);
  }

  Future<void> _closeWebSocket(
    WebSocket socket,
    int code,
    String reason,
  ) async {
    try {
      await socket
          .close(code, reason)
          .timeout(_developmentWebSocketCloseTimeout);
    } on Object {
      // Provider 已撤销会话，底层连接关闭只能尽力完成。
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _client.close(force: true);
    await _closeTrackedWebSockets(
      WebSocketStatus.goingAway,
      'Playmesh development provider closed',
    );
  }
}

HttpClient _newDevelopmentHttpClient() => HttpClient()
  ..autoUncompress = false
  ..connectionTimeout = _developmentConnectTimeout
  ..idleTimeout = _developmentResponseIdleTimeout;

Future<File?> safeInstalledGameWebFile(
  Directory appDirectory,
  String relativePath,
) async {
  playmeshGamePackageLayout.validateWebPath(relativePath, field: '游戏资源路径');
  if (!await appDirectory.exists()) return null;
  final packageRoot = await appDirectory.parent.resolveSymbolicLinks();
  final root = await appDirectory.resolveSymbolicLinks();
  final normalizedPackageRoot = _normalizedFileSystemPath(packageRoot);
  final normalizedRoot = _normalizedFileSystemPath(root);
  final packagePrefix = normalizedPackageRoot.endsWith(Platform.pathSeparator)
      ? normalizedPackageRoot
      : '$normalizedPackageRoot${Platform.pathSeparator}';
  if (!normalizedRoot.startsWith(packagePrefix)) {
    throw const FormatException('游戏物理 app/ 目录越过了当前游戏包');
  }
  final candidate = File(
    '${appDirectory.path}${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  if (!await candidate.exists()) return null;
  final resolved = await candidate.resolveSymbolicLinks();
  final normalizedResolved = _normalizedFileSystemPath(resolved);
  final rootPrefix = normalizedRoot.endsWith(Platform.pathSeparator)
      ? normalizedRoot
      : '$normalizedRoot${Platform.pathSeparator}';
  if (!normalizedResolved.startsWith(rootPrefix) ||
      await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException('游戏资源路径越过物理 app/ 目录');
  }
  return File(resolved);
}

String _normalizedFileSystemPath(String path) =>
    Platform.isWindows ? path.toLowerCase() : path;

void _copyResponseHeaders(HttpHeaders source, HttpHeaders target) {
  for (final name in const [
    HttpHeaders.cacheControlHeader,
    HttpHeaders.contentEncodingHeader,
    HttpHeaders.contentLanguageHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.contentTypeHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.expiresHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.acceptRangesHeader,
  ]) {
    final values = source[name];
    if (values != null) target.set(name, values);
  }
}

ContentType gameWebResourceContentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.d.ts') ||
      lower.endsWith('.txt') ||
      lower.endsWith('.md')) {
    return ContentType.text;
  }
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return ContentType('text', 'javascript', charset: 'utf-8');
  }
  if (lower.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (lower.endsWith('.json') || lower.endsWith('.map')) {
    return ContentType.json;
  }
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  if (lower.endsWith('.gif')) return ContentType('image', 'gif');
  if (lower.endsWith('.webp')) return ContentType('image', 'webp');
  if (lower.endsWith('.svg')) {
    return ContentType('image', 'svg+xml', charset: 'utf-8');
  }
  if (lower.endsWith('.ico')) return ContentType('image', 'x-icon');
  if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
  if (lower.endsWith('.ogg')) return ContentType('audio', 'ogg');
  if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
  if (lower.endsWith('.m4a')) return ContentType('audio', 'mp4');
  if (lower.endsWith('.aac')) return ContentType('audio', 'aac');
  if (lower.endsWith('.mp4')) return ContentType('video', 'mp4');
  if (lower.endsWith('.webm')) return ContentType('video', 'webm');
  if (lower.endsWith('.woff')) return ContentType('font', 'woff');
  if (lower.endsWith('.woff2')) return ContentType('font', 'woff2');
  if (lower.endsWith('.ttf')) return ContentType('font', 'ttf');
  if (lower.endsWith('.otf')) return ContentType('font', 'otf');
  if (lower.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
}

Future<void> gameWebResourceText(
  HttpResponse response,
  int status,
  String body,
) async {
  try {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
  } on StateError {
    await response.close();
    return;
  }
  await response.close();
}
