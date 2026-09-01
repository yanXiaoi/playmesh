import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'runtime_app_local_bucket_store.dart';

const runtimeAppLocalBucketSyncProtocolVersion = '1.0.0';

/// 为当前 Runtime WebView 提供阻塞 XHR 可用的回环 JSON 通道。
///
/// Gateway 绑定随机 loopback 端口和 256-bit capability path。它只访问注入的
/// [RuntimeAppLocalBucketStore]，不会代理到 Authority、Core 或对局网络。
final class RuntimeAppLocalBucketSyncGateway {
  RuntimeAppLocalBucketSyncGateway._(
    this._server,
    this._store,
    this._capability,
  );

  static const _maxRequestBytes =
      RuntimeAppLocalBucketStore.maxBucketJsonBytes + 128 * 1024;
  static final _requestIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{15,127}$',
  );

  final HttpServer _server;
  final RuntimeAppLocalBucketStore _store;
  final String _capability;
  final Map<String, _RuntimeAppLocalBucketSyncLedgerEntry> _ledger = {};
  bool _closed = false;

  static Future<RuntimeAppLocalBucketSyncGateway> start(
    RuntimeAppLocalBucketStore store,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final capability = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final gateway = RuntimeAppLocalBucketSyncGateway._(
      server,
      store,
      capability,
    );
    gateway._listen();
    return gateway;
  }

  Uri get endpoint => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: '/playmesh/app-storage-sync/v1/$_capability',
  );

  void _listen() {
    _server.listen((request) async {
      try {
        await _handle(request);
      } on Object catch (error) {
        await _json(request, HttpStatus.badRequest, {
          'protocolVersion': runtimeAppLocalBucketSyncProtocolVersion,
          'error': {
            'code': 'app_storage_sync_failed',
            'message': error is FormatException
                ? error.message
                : 'App Bucket 同步操作失败',
          },
        });
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.connectionInfo?.remoteAddress.isLoopback != true ||
        request.uri.path != endpoint.path) {
      await _json(request, HttpStatus.notFound, {
        'error': {'code': 'not_found', 'message': '资源不存在'},
      });
      return;
    }
    if (!_allowOrigin(request)) {
      await _json(request, HttpStatus.forbidden, {
        'error': {'code': 'origin_forbidden', 'message': '请求来源无效'},
      });
      return;
    }
    if (request.method != 'GET' && request.method != 'POST') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, POST');
      await _json(request, HttpStatus.methodNotAllowed, {
        'error': {'code': 'method_invalid', 'message': '只接受 GET/POST'},
      });
      return;
    }

    final body = request.method == 'GET'
        ? _decodeGetPayload(request.uri)
        : await _readBody(request);
    final digest = sha256.convert(body).toString();
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) throw const FormatException('同步存储请求必须是对象');
    final envelope = Map<String, Object?>.from(decoded);
    if (envelope['protocolVersion'] !=
        runtimeAppLocalBucketSyncProtocolVersion) {
      throw const FormatException('同步存储协议版本不受支持');
    }
    final requestId = envelope['requestId'];
    final operation = envelope['operation'];
    final bucket = envelope['bucket'];
    final key = envelope['key'];
    if (requestId is! String || !_requestIdPattern.hasMatch(requestId)) {
      throw const FormatException('同步存储 requestId 无效');
    }
    if (bucket is! String || key is! String) {
      throw const FormatException('同步存储 bucket/key 无效');
    }
    final expectedKeys = operation == 'sync.get'
        ? const {'protocolVersion', 'requestId', 'operation', 'bucket', 'key'}
        : operation == 'sync.set'
        ? const {
            'protocolVersion',
            'requestId',
            'operation',
            'bucket',
            'key',
            'value',
          }
        : throw const FormatException('同步存储 operation 无效');
    if (envelope.length != expectedKeys.length ||
        !envelope.keys.every(expectedKeys.contains)) {
      throw const FormatException('同步存储请求字段无效');
    }
    if ((request.method == 'GET') != (operation == 'sync.get')) {
      throw const FormatException('同步存储 HTTP method 与 operation 不匹配');
    }

    final result = await _runOnce(
      requestId: requestId,
      digest: digest,
      action: () => operation == 'sync.get'
          ? _store.getSynchronousData(bucket, key)
          : _store
                .setSynchronousData(bucket, key, envelope['value'])
                .then<Object?>((_) => null),
    );
    await _json(request, HttpStatus.ok, {
      'protocolVersion': runtimeAppLocalBucketSyncProtocolVersion,
      'requestId': requestId,
      'result': result,
    });
  }

  bool _allowOrigin(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null) return true;
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.scheme != 'http' || !uri.hasPort) return false;
    final address = InternetAddress.tryParse(uri.host);
    if (address?.isLoopback != true && uri.host.toLowerCase() != 'localhost') {
      return false;
    }
    request.response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, origin)
      ..set(HttpHeaders.varyHeader, 'origin');
    return true;
  }

  List<int> _decodeGetPayload(Uri uri) {
    final parameters = uri.queryParametersAll;
    if (parameters.length != 1 || parameters['payload']?.length != 1) {
      throw const FormatException('同步读取只接受单一 payload 参数');
    }
    final encoded = parameters['payload']!.single;
    if (encoded.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const FormatException('同步读取 payload 编码无效');
    }
    final List<int> bytes;
    try {
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      bytes = base64Url.decode('$encoded$padding');
    } on FormatException {
      throw const FormatException('同步读取 payload 编码无效');
    }
    if (bytes.length > 16 * 1024) {
      throw const FormatException('同步读取请求过大');
    }
    return bytes;
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxRequestBytes) {
        throw const FormatException('同步写入请求过大');
      }
    }
    return bytes;
  }

  Future<Object?> _runOnce({
    required String requestId,
    required String digest,
    required Future<Object?> Function() action,
  }) {
    final existing = _ledger[requestId];
    if (existing != null) {
      if (existing.digest != digest) {
        throw const FormatException('同步存储 requestId 已用于其他请求');
      }
      return existing.result;
    }
    final result = action();
    _ledger[requestId] = _RuntimeAppLocalBucketSyncLedgerEntry(digest, result);
    result.catchError((Object _) {
      _ledger.remove(requestId);
      return null;
    });
    while (_ledger.length > 64) {
      _ledger.remove(_ledger.keys.first);
    }
    return result;
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    _ledger.clear();
  }
}

final class _RuntimeAppLocalBucketSyncLedgerEntry {
  const _RuntimeAppLocalBucketSyncLedgerEntry(this.digest, this.result);

  final String digest;
  final Future<Object?> result;
}
