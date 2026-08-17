part of '../../developer_web_gateway_io.dart';

class _DeveloperRequestTooLarge implements Exception {
  const _DeveloperRequestTooLarge(this.limit);

  final int limit;
}

Future<List<int>> _bytesBodyWithLimit(HttpRequest request, int maxBytes) async {
  if (request.contentLength > maxBytes) {
    throw _DeveloperRequestTooLarge(maxBytes);
  }
  final builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in request) {
    length += chunk.length;
    if (length > maxBytes) throw _DeveloperRequestTooLarge(maxBytes);
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<Map<String, Object?>> _jsonBody(HttpRequest request) =>
    _jsonBodyWithLimit(request, 3 * 1024 * 1024);

Future<Map<String, Object?>> _jsonBodyWithLimit(
  HttpRequest request,
  int maxBytes,
) async {
  if (request.contentLength > maxBytes) {
    throw _DeveloperRequestTooLarge(maxBytes);
  }
  final text = await utf8.decoder.bind(request).join();
  if (utf8.encode(text).length > maxBytes) {
    throw _DeveloperRequestTooLarge(maxBytes);
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

String _boundedDeveloperDiagnosticField(Object? value, String fallback) {
  final text = value?.toString() ?? '';
  if (text.isEmpty ||
      text.length > 256 ||
      !RegExp(r'^[A-Za-z0-9._:/?=& -]+$').hasMatch(text)) {
    return fallback;
  }
  return text;
}

String? _developerGatewayFailureLogLine(
  HttpResponse response,
  int status,
  Object body,
) {
  if (status < HttpStatus.badRequest || body is! Map) return null;
  final operation = response.headers.value('X-Playmesh-Operation-ID');
  if (operation == null) {
    return null;
  }
  final area =
      operation.startsWith('gdevelop.ai.') ||
          operation.startsWith('ai_approvals.') ||
          operation.startsWith('ai_approval_grants.')
      ? 'AI'
      : operation.startsWith('gdevelop.catalog.') ||
            operation.startsWith('gdevelop.history.') ||
            operation.startsWith('gdevelop.project.allocation.')
      ? 'GDevelop'
      : null;
  if (area == null) return null;
  final error = body['error'];
  final code = error is Map ? error['code'] : null;
  final requestId = response.headers.value('X-Request-ID') ?? body['requestId'];
  return '[DeveloperGateway][$area] '
      'requestId=${_boundedDeveloperDiagnosticField(requestId, 'unavailable')} '
      'operation=${_boundedDeveloperDiagnosticField(operation, 'gdevelop.unknown')} '
      'status=$status '
      'code=${_boundedDeveloperDiagnosticField(code, 'unknown_error')}';
}

Future<void> _json(HttpResponse response, int status, Object body) async {
  final responseBody = _withDeveloperFailureEnvelope(response, status, body);
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  final diagnostic = _developerGatewayFailureLogLine(
    response,
    status,
    responseBody,
  );
  if (diagnostic != null) debugPrint(diagnostic);
  response.write(jsonEncode(responseBody));
  await response.close();
}

Object _withDeveloperFailureEnvelope(
  HttpResponse response,
  int status,
  Object body,
) {
  if (status < HttpStatus.badRequest || body is! Map) return body;
  final routedOperation = response.headers.value('X-Playmesh-Operation-ID');
  if (routedOperation == null ||
      (!routedOperation.startsWith('gdevelop.ai.') &&
          !routedOperation.startsWith('gdevelop.history.') &&
          !routedOperation.startsWith('ai_approvals.') &&
          !routedOperation.startsWith('ai_approval_grants.'))) {
    return body;
  }
  final result = Map<String, Object?>.from(body);
  final rawError = result['error'];
  if (rawError is! Map) return result;
  final error = Map<String, Object?>.from(rawError);
  final requestId =
      response.headers.value('X-Request-ID') ??
      result['requestId']?.toString() ??
      error['requestId']?.toString() ??
      'unavailable';
  final operation = error['operation']?.toString() ?? routedOperation;
  final code = error['code']?.toString() ?? 'unknown_error';
  final message = error['message']?.toString().trim() ?? '';
  error.putIfAbsent('stage', () => 'gateway_response');
  error.putIfAbsent('operation', () => operation);
  error.putIfAbsent('status', () => status);
  error.putIfAbsent('code', () => code);
  error.putIfAbsent('reason', () => message.isEmpty ? code : message);
  error.putIfAbsent('requestId', () => requestId);
  error.putIfAbsent('type', () => 'DeveloperGatewayError');
  result['requestId'] = requestId;
  result['error'] = error;
  return result;
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
) => _resolveDeveloperBaseUrl(
  gateway,
  request,
  selected: request.uri.queryParameters['baseUrl'],
  label: 'Agent Base URL',
);

Future<Uri> _resolveDeveloperBaseUrl(
  _IoDeveloperWebGateway gateway,
  HttpRequest request, {
  String? selected,
  required String label,
}) async {
  final normalizedSelected = selected?.trim() ?? '';
  if (normalizedSelected.isEmpty) {
    return Uri(
      scheme: request.requestedUri.scheme,
      host: request.requestedUri.host,
      port: request.requestedUri.port,
    );
  }
  final parsed = Uri.tryParse(normalizedSelected);
  if (parsed == null ||
      parsed.scheme != 'http' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.port != gateway.server.port ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      parsed.hasQuery ||
      parsed.hasFragment) {
    throw FormatException('$label 必须是当前开发者网关的本机 HTTP 地址');
  }
  final normalized = Uri(
    scheme: 'http',
    host: parsed.host,
    port: gateway.server.port,
  );
  final available = await _availableDeveloperBaseUrls(gateway, request);
  if (!available.contains(normalized)) {
    throw FormatException('$label 不属于当前设备的可用地址');
  }
  return normalized;
}

Future<void> _servePublicAsset(HttpRequest request, String route) async {
  final relativePath = route.substring('/playmesh/'.length);
  if (relativePath.isEmpty || relativePath.split('/').contains('..')) {
    throw const FormatException('平台资源路径无效');
  }
  if (relativePath.startsWith('localization/')) {
    final localizationPath = relativePath.substring('localization/'.length);
    if (localizationPath.isEmpty ||
        localizationPath.split('/').contains('..')) {
      throw const FormatException('本地化资源路径无效');
    }
    final data = await rootBundle.load(
      'assets/playmesh-localization/$localizationPath',
    );
    request.response.headers.contentType = ContentType.parse(
      _publicContentType(localizationPath),
    );
    request.response.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await request.response.close();
    return;
  }
  final liveSdk = SdkFeatureRegistry.sdkFileForPublicPath(relativePath);
  if (liveSdk != null) {
    request.response.headers.contentType = ContentType.parse(
      _publicContentType(relativePath),
    );
    request.response.write(liveSdk);
    await request.response.close();
    return;
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
  if (path.endsWith('.wasm')) return 'application/wasm';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
  if (path.endsWith('.gif')) return 'image/gif';
  if (path.endsWith('.ico')) return 'image/x-icon';
  if (path.endsWith('.woff')) return 'font/woff';
  if (path.endsWith('.woff2')) return 'font/woff2';
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
