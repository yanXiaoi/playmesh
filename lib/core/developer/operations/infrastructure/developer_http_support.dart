part of '../../developer_web_gateway_io.dart';

Future<Map<String, Object?>> _jsonBody(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.length > 3 * 1024 * 1024) {
    throw const FormatException('请求内容超过 3 MiB');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('请求体必须是 JSON 对象');
  return Map<String, Object?>.from(decoded);
}

Future<Map<String, Object?>> _optionalJsonBody(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.trim().isEmpty) return <String, Object?>{};
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('请求体必须是 JSON 对象');
  return Map<String, Object?>.from(decoded);
}

Future<void> _html(HttpResponse response, String body) =>
    _text(response, body, 'text/html; charset=utf-8');

Future<void> _text(
  HttpResponse response,
  String body,
  String contentType,
) async {
  response.headers.contentType = ContentType.parse(contentType);
  response.write(body);
  await response.close();
}

Future<void> _json(HttpResponse response, int status, Object body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> _error(
  HttpResponse response,
  int status,
  String requestId,
  String code,
  String message,
) => _json(response, status, {
  'requestId': requestId,
  'error': {'code': code, 'message': message},
});

Future<List<Uri>> _availableDeveloperBaseUrls(
  _IoDeveloperWebGateway gateway,
  HttpRequest request,
) async {
  final urls = <String, Uri>{};
  void add(Uri uri) {
    final normalized = Uri(
      scheme: 'http',
      host: uri.host,
      port: gateway.server.port,
    );
    urls[normalized.toString()] = normalized;
  }

  add(request.requestedUri);
  for (final endpoint in await resolveLanEndpoints(gateway.server.port)) {
    add(endpoint);
  }
  add(Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address));
  return urls.values.toList(growable: false);
}

Future<Uri> _resolvePromptBaseUrl(
  _IoDeveloperWebGateway gateway,
  HttpRequest request,
) async {
  final selected = request.uri.queryParameters['baseUrl']?.trim() ?? '';
  if (selected.isEmpty) {
    return Uri(
      scheme: request.requestedUri.scheme,
      host: request.requestedUri.host,
      port: request.requestedUri.port,
    );
  }
  final parsed = Uri.tryParse(selected);
  if (parsed == null ||
      parsed.scheme != 'http' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.port != gateway.server.port ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      parsed.hasQuery ||
      parsed.hasFragment) {
    throw const FormatException('Agent Base URL 必须是当前开发者网关的本机 HTTP 地址');
  }
  final normalized = Uri(
    scheme: 'http',
    host: parsed.host,
    port: gateway.server.port,
  );
  final available = await _availableDeveloperBaseUrls(gateway, request);
  if (!available.contains(normalized)) {
    throw const FormatException('Agent Base URL 不属于当前设备的可用地址');
  }
  return normalized;
}

Future<void> _servePublicAsset(HttpRequest request, String route) async {
  final relativePath = route.substring('/playmesh/'.length);
  if (relativePath.isEmpty || relativePath.split('/').contains('..')) {
    throw const FormatException('平台资源路径无效');
  }
  final data = await rootBundle.load(
    'assets/playmesh-library/public/$relativePath',
  );
  request.response.headers.contentType = ContentType.parse(
    _publicContentType(relativePath),
  );
  request.response.add(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  await request.response.close();
}

Future<void> _serveDeveloperAsset(
  HttpRequest request,
  String relativePath,
) async {
  if (relativePath.isEmpty || relativePath.split('/').contains('..')) {
    throw const FormatException('开发者文档资源路径无效');
  }
  final data = await rootBundle.load(
    'assets/playmesh-library/public/developer/$relativePath',
  );
  request.response.headers.contentType = ContentType.parse(
    _publicContentType(relativePath),
  );
  request.response.add(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  await request.response.close();
}

String _publicContentType(String path) {
  if (path.endsWith('.d.ts')) return 'text/plain; charset=utf-8';
  if (path.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.json')) return 'application/json; charset=utf-8';
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.md') || path.endsWith('.txt')) {
    return 'text/plain; charset=utf-8';
  }
  return 'application/octet-stream';
}

String _createToken(String? customToken) {
  final value = customToken?.trim() ?? '';
  if (value.isNotEmpty) {
    if (value.length < 8 || value.length > 128) {
      throw const FormatException('开发者 Token 长度必须为 8 到 128 个字符');
    }
    return value;
  }
  return base64Url.encode(_randomBytes(32)).replaceAll('=', '');
}

String _createPath(String? persistedPath) {
  final value = persistedPath?.trim() ?? '';
  if (value.isEmpty) return _randomHex(16);
  if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value)) {
    throw const FormatException('开发者工作区路径无效');
  }
  return value;
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int length) => _randomBytes(
  length,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = max(a.length, b.length);
  for (var index = 0; index < length; index += 1) {
    difference |=
        (index < a.length ? a[index] : 0) ^ (index < b.length ? b[index] : 0);
  }
  return difference == 0;
}
