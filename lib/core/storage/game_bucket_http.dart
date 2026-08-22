import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'game_storage_service.dart';

const _standardJsonDigestHeader = 'x-playmesh-content-sha256';
const _synchronousStorageHeader = 'x-playmesh-storage-sync';
const playmeshStandardJsonBucketPath = '/bucket/_playmesh-json/v1';
const playmeshStandardJsonProtocolVersion = '1.0.0';
const playmeshEndpointBoundStorageGameId = '@playmesh-current-game';
const _standardJsonEnvelopeBytes = 128 * 1024;
const _maxSynchronousGetPayloadBytes = 12 * 1024;
const _maxSynchronousGetQueryBytes = 16 * 1024;
const _maxStandardJsonRequestBytes =
    GameStorageService.maxStandardJsonBytes + _standardJsonEnvelopeBytes;
final _requestIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{15,127}$');
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

typedef StandardJsonBucketAuthorizer =
    StandardJsonBucketAuthorization? Function(HttpRequest request);

class StandardJsonBucketAuthorization {
  const StandardJsonBucketAuthorization(this.scope, {this.isAuthority = true});

  final String scope;
  final bool isAuthority;
}

class StandardJsonBucketRequestLedger {
  static const _maxEntries = 64;
  static const _maxResultBytes = 16 * 1024 * 1024;

  final Map<String, _StandardJsonLedgerEntry> _entries = {};
  int _resultBytes = 0;

  Future<Object?> run({
    required String requestId,
    required String digest,
    required String scope,
    required String gameId,
    required String operation,
    required String bucket,
    required Future<Object?> Function() action,
  }) {
    final identity = '$scope\u0000$gameId\u0000$operation\u0000$bucket';
    final existing = _entries[requestId];
    if (existing != null) {
      if (existing.digest != digest || existing.identity != identity) {
        throw const _StandardJsonIdempotencyConflict();
      }
      return existing.result;
    }

    final completer = Completer<Object?>();
    final entry = _StandardJsonLedgerEntry(
      digest: digest,
      identity: identity,
      result: completer.future,
    );
    _entries[requestId] = entry;
    () async {
      try {
        final result = await action();
        entry
          ..completed = true
          ..resultBytes = utf8.encode(jsonEncode(result)).length;
        _resultBytes += entry.resultBytes;
        completer.complete(result);
        _trim();
      } on Object catch (error, stackTrace) {
        _entries.remove(requestId);
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  void _trim() {
    while (_entries.length > _maxEntries || _resultBytes > _maxResultBytes) {
      String? oldestCompleted;
      for (final entry in _entries.entries) {
        if (entry.value.completed) {
          oldestCompleted = entry.key;
          break;
        }
      }
      if (oldestCompleted == null) return;
      final removed = _entries.remove(oldestCompleted)!;
      _resultBytes -= removed.resultBytes;
    }
  }
}

/// 处理同源 `/bucket` 文件上传与读取。返回 false 表示请求不属于该路由。
Future<bool> handleGameBucketRequest(
  HttpRequest request, {
  required GameStorageService storage,
  StandardJsonBucketAuthorizer? authorizeUpload,
  StandardJsonBucketAuthorizer? authorizeStandardJson,
  StandardJsonBucketRequestLedger? standardJsonLedger,
}) async {
  final segments = request.uri.pathSegments;
  if (segments.isEmpty || segments.first != 'bucket') return false;

  if (request.uri.path == playmeshStandardJsonBucketPath) {
    await _handleStandardJson(
      request,
      storage: storage,
      authorize: authorizeStandardJson,
      ledger: standardJsonLedger,
    );
    return true;
  }

  if (request.method == 'POST' && segments.length == 2) {
    final authorization = authorizeUpload?.call(request);
    if (authorization == null || authorization.scope.isEmpty) {
      await _jsonError(
        request.response,
        HttpStatus.forbidden,
        'storage_session_invalid',
        '存储会话无效',
      );
      return true;
    }
    if (!authorization.isAuthority) {
      await _jsonError(
        request.response,
        HttpStatus.forbidden,
        'not_authority',
        '只有 Authority 主机可以写入 Main Bucket',
      );
      return true;
    }
    final originalName = request.uri.queryParameters['name'];
    if (originalName == null || originalName.isEmpty) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': '缺少上传文件名',
      });
      return true;
    }
    try {
      final url = await storage.upload(
        bucket: segments[1],
        originalName: originalName,
        data: request,
        contentLength: request.contentLength,
      );
      await _json(request.response, HttpStatus.created, {'url': url});
    } on FormatException catch (error) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    }
    return true;
  }

  if (request.method == 'GET' && segments.length == 3) {
    try {
      final file = storage.dataFile(segments[1], segments[2]);
      if (!await file.exists()) {
        await _text(request.response, HttpStatus.notFound, '文件不存在');
        return true;
      }
      request.response.headers
        ..contentType = bucketContentType(file.path)
        ..set('x-content-type-options', 'nosniff');
      if (segments[1] == GameStorageService.systemAvatarBucket) {
        final playerId = segments[2].substring(0, segments[2].length - 4);
        final etag = await storage.avatarEtag(playerId);
        request.response.headers
          ..set(HttpHeaders.cacheControlHeader, 'private, no-cache')
          ..set(HttpHeaders.etagHeader, etag);
        if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
          request.response.statusCode = HttpStatus.notModified;
          await request.response.close();
          return true;
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
      await _text(request.response, HttpStatus.notFound, '文件不存在');
    }
    return true;
  }

  if (request.method != 'GET' && request.method != 'POST') {
    await _text(request.response, HttpStatus.methodNotAllowed, '不支持的请求');
  } else {
    // 不提供 Bucket 目录枚举，也不暴露 data/json。
    await _text(request.response, HttpStatus.notFound, '文件不存在');
  }
  return true;
}

Future<void> _handleStandardJson(
  HttpRequest request, {
  required GameStorageService storage,
  required StandardJsonBucketAuthorizer? authorize,
  required StandardJsonBucketRequestLedger? ledger,
}) async {
  final synchronous = request.headers.value(_synchronousStorageHeader) == '1';
  final allowed = synchronous
      ? const {'GET', 'PUT'}
      : const {'GET', 'PUT', 'DELETE'};
  if (!allowed.contains(request.method)) {
    request.response.headers.set(HttpHeaders.allowHeader, allowed.join(', '));
    await _jsonError(
      request.response,
      HttpStatus.methodNotAllowed,
      synchronous
          ? 'storage_sync_method_required'
          : 'storage_json_method_required',
      synchronous ? '同步存储只接受 GET/PUT' : '标准 JSON 存储只接受 GET/PUT/DELETE',
    );
    return;
  }
  await _handleVersionedStandardJson(
    request,
    storage: storage,
    authorize: authorize,
    ledger: ledger,
    synchronous: synchronous,
  );
}

Future<Uint8List> _readAndVerifyStandardJsonBody(
  HttpRequest request, {
  required String expectedDigest,
}) async {
  final builder = BytesBuilder(copy: false);
  final hashSink = Sha256().toSync().newHashSink();
  var received = 0;
  try {
    await for (final chunk in request) {
      received += chunk.length;
      if (received > _maxStandardJsonRequestBytes) {
        throw const _StandardJsonBodyTooLarge();
      }
      hashSink.add(chunk);
      builder.add(chunk);
    }
    if (request.contentLength >= 0 && received != request.contentLength) {
      throw const FormatException('存储请求长度不匹配');
    }
    hashSink.close();
    final hash = await hashSink.hash();
    final digest = hash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    if (digest != expectedDigest) {
      throw const _StandardJsonDigestMismatch();
    }
    return builder.takeBytes();
  } finally {
    try {
      hashSink.close();
    } on StateError {
      // 正常路径已关闭；断流或超额路径在这里释放 sink。
    }
  }
}

Future<void> _handleVersionedStandardJson(
  HttpRequest request, {
  required GameStorageService storage,
  required StandardJsonBucketAuthorizer? authorize,
  required StandardJsonBucketRequestLedger? ledger,
  required bool synchronous,
}) async {
  String? requestId;
  final authorization = authorize?.call(request);
  if (authorization == null || authorization.scope.isEmpty) {
    await _jsonError(
      request.response,
      HttpStatus.forbidden,
      'storage_session_invalid',
      '存储会话无效',
    );
    return;
  }
  if (!authorization.isAuthority) {
    await _jsonError(
      request.response,
      HttpStatus.forbidden,
      'not_authority',
      '只有 Authority 主机可以读写 Main Bucket',
    );
    return;
  }
  if (ledger == null) {
    await _jsonError(
      request.response,
      HttpStatus.internalServerError,
      'storage_ledger_unavailable',
      '存储幂等队列不可用',
    );
    return;
  }
  final expectedDigest = request.headers.value(_standardJsonDigestHeader);
  if (expectedDigest == null || !_sha256Pattern.hasMatch(expectedDigest)) {
    await _jsonError(
      request.response,
      HttpStatus.badRequest,
      'storage_digest_invalid',
      '存储请求缺少有效 SHA-256',
    );
    return;
  }

  try {
    late final Uint8List body;
    if (request.method == 'GET' || request.method == 'DELETE') {
      final parameters = request.uri.queryParametersAll;
      if (parameters.length != 1 ||
          !parameters.containsKey('payload') ||
          parameters['payload']!.length != 1) {
        throw FormatException('${request.method} JSON 存储只接受单一 payload 参数');
      }
      final encoded = parameters['payload']!.single;
      if (encoded.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
        throw FormatException('${request.method} JSON 存储 payload 编码无效');
      }
      if (utf8.encode(encoded).length > _maxSynchronousGetQueryBytes) {
        throw const _StandardJsonBodyTooLarge();
      }
      try {
        final padding = '=' * ((4 - encoded.length % 4) % 4);
        body = Uint8List.fromList(base64Url.decode('$encoded$padding'));
      } on FormatException {
        throw FormatException('${request.method} JSON 存储 payload 编码无效');
      }
      if (body.length > _maxSynchronousGetPayloadBytes) {
        throw const _StandardJsonBodyTooLarge();
      }
      await _verifyStandardJsonBytes(body, expectedDigest: expectedDigest);
    } else if (request.method == 'PUT') {
      if (request.uri.hasQuery) {
        throw const FormatException('PUT JSON 存储不接受查询参数');
      }
      if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
        await _jsonError(
          request.response,
          HttpStatus.unsupportedMediaType,
          'content_type_invalid',
          '存储请求必须使用 application/json',
        );
        return;
      }
      if (request.contentLength > _maxStandardJsonRequestBytes) {
        throw const _StandardJsonBodyTooLarge();
      }
      body = await _readAndVerifyStandardJsonBody(
        request,
        expectedDigest: expectedDigest,
      );
    } else {
      request.response.headers.set(
        HttpHeaders.allowHeader,
        synchronous ? 'GET, PUT' : 'GET, PUT, DELETE',
      );
      await _jsonError(
        request.response,
        HttpStatus.methodNotAllowed,
        synchronous
            ? 'storage_sync_method_required'
            : 'storage_json_method_required',
        synchronous ? '同步存储只接受 GET/PUT' : '标准 JSON 存储只接受 GET/PUT/DELETE',
      );
      return;
    }

    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) throw const FormatException('存储请求必须是对象');
    final envelope = Map<String, Object?>.from(decoded);
    requestId = _requiredString(envelope, 'requestId');
    if (!_requestIdPattern.hasMatch(requestId)) {
      throw const FormatException('存储 requestId 无效');
    }
    if (_requiredString(envelope, 'protocolVersion') !=
        playmeshStandardJsonProtocolVersion) {
      throw const FormatException('存储协议版本不受支持');
    }
    final operation = _requiredString(envelope, 'operation');
    final operationMatchesMethod = synchronous
        ? (request.method == 'GET'
              ? operation == 'sync.get'
              : operation == 'sync.set')
        : switch (request.method) {
            'GET' => operation == 'get',
            'PUT' => operation == 'set',
            'DELETE' => operation == 'remove' || operation == 'clear',
            _ => false,
          };
    if (!operationMatchesMethod) {
      await _jsonError(
        request.response,
        HttpStatus.methodNotAllowed,
        'storage_method_mismatch',
        'HTTP method 与 JSON 存储操作不匹配',
        requestId: requestId,
      );
      return;
    }
    final requestGameId = _requiredString(envelope, 'gameId');
    if (requestGameId != storage.gameId &&
        (!synchronous || requestGameId != playmeshEndpointBoundStorageGameId)) {
      await _jsonError(
        request.response,
        HttpStatus.forbidden,
        'storage_game_mismatch',
        '存储请求不属于当前游戏',
        requestId: requestId,
      );
      return;
    }
    final bucket = _requiredString(envelope, 'bucket');
    final result = await ledger.run(
      requestId: requestId,
      digest: expectedDigest,
      scope: authorization.scope,
      gameId: storage.gameId,
      operation: operation,
      bucket: bucket,
      action: () => _executeVersionedJsonOperation(
        storage,
        operation,
        envelope,
        synchronous: synchronous,
      ),
    );
    await _json(request.response, HttpStatus.ok, {
      'protocolVersion': playmeshStandardJsonProtocolVersion,
      'requestId': requestId,
      'result': result,
    });
  } on _StandardJsonBodyTooLarge {
    await _jsonError(
      request.response,
      HttpStatus.requestEntityTooLarge,
      'storage_request_too_large',
      synchronous ? '存储请求超过同步 JSON 限制' : '存储请求超过标准 JSON 限制',
      requestId: requestId,
    );
  } on _StandardJsonDigestMismatch {
    await _jsonError(
      request.response,
      HttpStatus.badRequest,
      'storage_digest_mismatch',
      '存储请求 SHA-256 不匹配',
      requestId: requestId,
    );
  } on _StandardJsonIdempotencyConflict {
    await _jsonError(
      request.response,
      HttpStatus.conflict,
      'storage_idempotency_conflict',
      '同一 requestId 不能用于不同存储请求',
      requestId: requestId,
    );
  } on GameStorageRevisionConflictException {
    await _jsonError(
      request.response,
      HttpStatus.conflict,
      'storage_revision_conflict',
      '存储修订已发生变化，已拒绝覆盖',
      requestId: requestId,
    );
  } on FormatException catch (error) {
    final quota = error.message.toString().contains('10 MiB');
    await _jsonError(
      request.response,
      quota ? HttpStatus.requestEntityTooLarge : HttpStatus.badRequest,
      quota ? 'standard_bucket_too_large' : 'storage_request_invalid',
      error.message.toString(),
      requestId: requestId,
    );
  }
}

Future<void> _verifyStandardJsonBytes(
  Uint8List body, {
  required String expectedDigest,
}) async {
  final hash = await Sha256().hash(body);
  final digest = hash.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  if (digest != expectedDigest) throw const _StandardJsonDigestMismatch();
}

Future<Object?> _executeVersionedJsonOperation(
  GameStorageService storage,
  String operation,
  Map<String, Object?> envelope, {
  required bool synchronous,
}) async {
  final bucket = _requiredString(envelope, 'bucket');
  switch (operation) {
    case 'sync.get':
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'key',
        'revision',
      });
      _optionalRevision(envelope['revision']);
      final current = await storage.getLogicalDataVersioned(
        bucket,
        _requiredString(envelope, 'key'),
      );
      return {'value': current.value, 'revision': current.revision};
    case 'sync.set':
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'key',
        'value',
        'expectedRevision',
      });
      if (!envelope.containsKey('value')) {
        throw const FormatException('存储 sync.set 缺少 value');
      }
      final revision = await storage.setLogicalDataIfRevision(
        bucket,
        _requiredString(envelope, 'key'),
        envelope['value'],
        expectedRevision: _requiredRevision(envelope, 'expectedRevision'),
      );
      return {'revision': revision};
    case 'get':
      if (synchronous) throw const FormatException('同步存储操作无效');
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'key',
        'revision',
      });
      _optionalRevision(envelope['revision']);
      final current = await storage.getDataVersioned(
        bucket,
        _requiredString(envelope, 'key'),
      );
      return {'value': current.value, 'revision': current.revision};
    case 'set':
      if (synchronous) throw const FormatException('同步存储操作无效');
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'key',
        'value',
        'expectedRevision',
      });
      if (!envelope.containsKey('value')) {
        throw const FormatException('存储 set 缺少 value');
      }
      final revision = await storage.setDataIfRevision(
        bucket,
        _requiredString(envelope, 'key'),
        envelope['value'],
        expectedRevision: _requiredRevision(envelope, 'expectedRevision'),
      );
      return {'revision': revision};
    case 'remove':
      if (synchronous) throw const FormatException('同步存储操作无效');
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'key',
        'expectedRevision',
      });
      final revision = await storage.removeDataIfRevision(
        bucket,
        _requiredString(envelope, 'key'),
        expectedRevision: _requiredRevision(envelope, 'expectedRevision'),
      );
      return {'revision': revision};
    case 'clear':
      if (synchronous) throw const FormatException('同步存储操作无效');
      _expectKeys(envelope, const {
        'protocolVersion',
        'requestId',
        'gameId',
        'operation',
        'bucket',
        'expectedRevision',
      });
      final revision = await storage.clearDataIfRevision(
        bucket,
        expectedRevision: _requiredRevision(envelope, 'expectedRevision'),
      );
      return {'revision': revision};
    default:
      throw const FormatException('未知的版本化 JSON Bucket 操作');
  }
}

String _requiredRevision(Map<String, Object?> value, String key) {
  final revision = _requiredString(value, key);
  if (!_sha256Pattern.hasMatch(revision)) {
    throw FormatException('存储请求的 $key 无效');
  }
  return revision;
}

void _optionalRevision(Object? revision) {
  if (revision == null) return;
  if (revision is! String || !_sha256Pattern.hasMatch(revision)) {
    throw const FormatException('存储请求的 revision 无效');
  }
}

String _requiredString(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! String) throw FormatException('存储请求缺少 $key');
  return result;
}

void _expectKeys(Map<String, Object?> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('存储请求包含未允许字段');
  }
}

class _StandardJsonBodyTooLarge implements Exception {
  const _StandardJsonBodyTooLarge();
}

class _StandardJsonDigestMismatch implements Exception {
  const _StandardJsonDigestMismatch();
}

class _StandardJsonIdempotencyConflict implements Exception {
  const _StandardJsonIdempotencyConflict();
}

class _StandardJsonLedgerEntry {
  _StandardJsonLedgerEntry({
    required this.digest,
    required this.identity,
    required this.result,
  });

  final String digest;
  final String identity;
  final Future<Object?> result;
  bool completed = false;
  int resultBytes = 0;
}

ContentType bucketContentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  if (lower.endsWith('.gif')) return ContentType('image', 'gif');
  if (lower.endsWith('.webp')) return ContentType('image', 'webp');
  if (lower.endsWith('.svg')) {
    return ContentType('image', 'svg+xml', charset: 'utf-8');
  }
  if (lower.endsWith('.json')) return ContentType.json;
  if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
  if (lower.endsWith('.ogg')) return ContentType('audio', 'ogg');
  if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
  if (lower.endsWith('.mp4')) return ContentType('video', 'mp4');
  if (lower.endsWith('.webm')) return ContentType('video', 'webm');
  if (lower.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
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
  response.headers
    ..contentType = ContentType.json
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('x-content-type-options', 'nosniff');
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> _jsonError(
  HttpResponse response,
  int status,
  String code,
  String message, {
  String? requestId,
}) => _json(response, status, {
  'protocolVersion': playmeshStandardJsonProtocolVersion,
  'requestId': ?requestId,
  'error': {'code': code, 'message': message},
});
