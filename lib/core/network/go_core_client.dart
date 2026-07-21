import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../protocol/go_core_status.dart';

typedef GoCoreLogSink = void Function(Map<String, Object?> record);
typedef RequestIdFactory = String Function();

abstract interface class GoCoreHealthClient {
  Uri get endpoint;

  Future<GoCoreStatus> fetchHealth({String? requestId});

  void close();
}

class GoCoreClient implements GoCoreHealthClient {
  GoCoreClient({
    http.Client? httpClient,
    required this.baseUri,
    this.timeout = const Duration(seconds: 3),
    GoCoreLogSink? logSink,
    RequestIdFactory? requestIdFactory,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _logSink = logSink ?? _defaultLogSink,
       _requestIdFactory = requestIdFactory ?? _defaultRequestId;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Uri baseUri;
  final Duration timeout;
  final GoCoreLogSink _logSink;
  final RequestIdFactory _requestIdFactory;

  @override
  Uri get endpoint => baseUri.resolve('health');

  @override
  Future<GoCoreStatus> fetchHealth({String? requestId}) async {
    final correlationId = requestId ?? _requestIdFactory();
    _log('info', 'core.health.requested', correlationId);

    late final http.Response response;
    try {
      response = await _httpClient
          .get(
            endpoint,
            headers: {
              'Accept': 'application/json',
              'X-Request-ID': correlationId,
            },
          )
          .timeout(timeout);
    } on TimeoutException catch (error) {
      throw _networkException(
        code: 'core_timeout',
        message: '连接 Go Core 超时，请确认服务已启动。',
        requestId: correlationId,
        event: 'core.health.timeout',
        error: error,
      );
    } on http.ClientException catch (error) {
      throw _networkException(
        code: 'core_unreachable',
        message: '无法连接 Go Core，请确认服务已启动。',
        requestId: correlationId,
        event: 'core.health.unreachable',
        error: error,
      );
    } on Object catch (error) {
      throw _networkException(
        code: 'core_unreachable',
        message: '无法连接 Go Core，请检查本机服务。',
        requestId: correlationId,
        event: 'core.health.unreachable',
        error: error,
      );
    }

    final payload = _decodePayload(response, correlationId);
    if (response.statusCode != 200) {
      throw _serverException(response, payload, correlationId);
    }

    late final GoCoreStatus status;
    try {
      status = GoCoreStatus.fromJson(payload);
    } on FormatException catch (error) {
      _log(
        'error',
        'core.health.invalid_response',
        correlationId,
        errorCode: 'invalid_response',
        statusCode: response.statusCode,
      );
      throw GoCoreException(
        code: 'invalid_response',
        userMessage: 'Go Core 返回了无法识别的状态。',
        requestId: correlationId,
        diagnostic: error.message,
        cause: error,
      );
    }

    final headerRequestId = response.headers['x-request-id'];
    if (status.requestId != correlationId ||
        (headerRequestId != null && headerRequestId != correlationId)) {
      _log(
        'error',
        'core.health.request_id_mismatch',
        correlationId,
        errorCode: 'request_id_mismatch',
        statusCode: response.statusCode,
      );
      throw GoCoreException(
        code: 'request_id_mismatch',
        userMessage: 'Go Core 响应无法与本次请求对应。',
        requestId: correlationId,
        diagnostic:
            'bodyRequestId=${status.requestId} headerRequestId=$headerRequestId',
      );
    }

    _log(
      'info',
      'core.health.succeeded',
      correlationId,
      statusCode: response.statusCode,
    );
    return status;
  }

  @override
  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Map<String, Object?> _decodePayload(
    http.Response response,
    String requestId,
  ) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
      throw const FormatException('响应根节点不是对象');
    } on FormatException catch (error) {
      _log(
        'error',
        'core.health.invalid_json',
        requestId,
        errorCode: 'invalid_json',
        statusCode: response.statusCode,
      );
      throw GoCoreException(
        code: 'invalid_json',
        userMessage: 'Go Core 返回了无效数据。',
        requestId: requestId,
        diagnostic: error.message,
        cause: error,
      );
    }
  }

  GoCoreException _serverException(
    http.Response response,
    Map<String, Object?> payload,
    String requestId,
  ) {
    final errorPayload = payload['error'];
    final errorMap = errorPayload is Map
        ? Map<String, Object?>.from(errorPayload)
        : const <String, Object?>{};
    final code = errorMap['code'] is String
        ? errorMap['code']! as String
        : 'http_${response.statusCode}';
    final message = errorMap['message'] is String
        ? errorMap['message']! as String
        : 'Go Core 返回错误，请稍后重试。';

    _log(
      'error',
      'core.health.failed',
      requestId,
      errorCode: code,
      statusCode: response.statusCode,
    );
    return GoCoreException(
      code: code,
      userMessage: message,
      requestId: requestId,
      diagnostic: 'statusCode=${response.statusCode}',
    );
  }

  GoCoreException _networkException({
    required String code,
    required String message,
    required String requestId,
    required String event,
    required Object error,
  }) {
    _log('error', event, requestId, errorCode: code);
    return GoCoreException(
      code: code,
      userMessage: message,
      requestId: requestId,
      diagnostic: error.toString(),
      cause: error,
    );
  }

  void _log(
    String level,
    String event,
    String requestId, {
    String? errorCode,
    int? statusCode,
  }) {
    _logSink({
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      'level': level,
      'component': 'go-core-client',
      'event': event,
      'requestId': requestId,
      'errorCode': ?errorCode,
      'statusCode': ?statusCode,
    });
  }
}

class GoCoreException implements Exception {
  const GoCoreException({
    required this.code,
    required this.userMessage,
    required this.requestId,
    required this.diagnostic,
    this.cause,
  });

  final String code;
  final String userMessage;
  final String requestId;
  final String diagnostic;
  final Object? cause;

  bool get isOffline => code == 'core_unreachable' || code == 'core_timeout';

  @override
  String toString() {
    return 'GoCoreException(code=$code, requestId=$requestId, diagnostic=$diagnostic)';
  }
}

final Random _requestIdRandom = Random.secure();

String _defaultRequestId() {
  final bytes = List<int>.generate(12, (_) => _requestIdRandom.nextInt(256));
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'req-$hex';
}

void _defaultLogSink(Map<String, Object?> record) {
  debugPrint(jsonEncode(record));
}
