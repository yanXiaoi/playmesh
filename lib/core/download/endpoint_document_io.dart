import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'endpoint_document_contract.dart';

EndpointDocumentHttpClient createEndpointDocumentHttpClient() =>
    IoEndpointDocumentHttpClient();

class IoEndpointDocumentHttpClient implements EndpointDocumentHttpClient {
  IoEndpointDocumentHttpClient({HttpClient? client})
    : _client = client ?? HttpClient(),
      _allowHttpForTesting = false;

  @visibleForTesting
  IoEndpointDocumentHttpClient.allowHttpForTesting({HttpClient? client})
    : _client = client ?? HttpClient(),
      _allowHttpForTesting = true;

  final HttpClient _client;
  final bool _allowHttpForTesting;
  var _closed = false;

  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) async {
    if (_closed) {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.network,
        diagnostic: 'client_closed',
      );
    }
    if (!_isAllowedUri(url)) {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.invalidUrl,
        diagnostic: 'document_url_must_be_https',
      );
    }

    HttpClientRequest? request;
    try {
      final operation = () async {
        request = await _client.getUrl(url);
        request!.followRedirects = true;
        request!.maxRedirects = 5;
        request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request!.close();
        var redirectBase = url;
        for (final redirect in response.redirects) {
          final destination = redirectBase.resolveUri(redirect.location);
          if (!_isAllowedUri(destination)) {
            throw const EndpointDocumentLoadException(
              kind: EndpointDocumentFailureKind.invalidUrl,
              diagnostic: 'document_redirect_must_be_https',
            );
          }
          redirectBase = destination;
        }
        if (response.statusCode != HttpStatus.ok) {
          await _cancelResponse(response);
          throw EndpointDocumentLoadException(
            kind: EndpointDocumentFailureKind.http,
            diagnostic: 'document_http_${response.statusCode}',
            httpStatus: response.statusCode,
          );
        }
        final declaredLength = response.contentLength;
        if (declaredLength > maxBytes) {
          await _cancelResponse(response);
          throw const EndpointDocumentLoadException(
            kind: EndpointDocumentFailureKind.tooLarge,
            diagnostic: 'document_content_length_exceeded',
          );
        }

        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const EndpointDocumentLoadException(
              kind: EndpointDocumentFailureKind.tooLarge,
              diagnostic: 'document_stream_limit_exceeded',
            );
          }
          bytes.add(chunk);
        }
        try {
          return utf8.decode(bytes.takeBytes(), allowMalformed: false);
        } on FormatException {
          throw const EndpointDocumentLoadException(
            kind: EndpointDocumentFailureKind.invalidUtf8,
            diagnostic: 'document_invalid_utf8',
          );
        }
      }();
      return await operation.timeout(
        timeout,
        onTimeout: () {
          request?.abort(TimeoutException('endpoint document timeout'));
          throw EndpointDocumentLoadException(
            kind: EndpointDocumentFailureKind.timeout,
            diagnostic: 'document_timeout',
          );
        },
      );
    } on EndpointDocumentLoadException {
      rethrow;
    } on HandshakeException {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.tls,
        diagnostic: 'document_tls_handshake_failed',
      );
    } on TlsException {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.tls,
        diagnostic: 'document_tls_handshake_failed',
      );
    } on SocketException catch (error) {
      final dns = _isDnsFailure(error);
      throw EndpointDocumentLoadException(
        kind: dns
            ? EndpointDocumentFailureKind.dns
            : EndpointDocumentFailureKind.network,
        diagnostic: dns
            ? 'document_dns_lookup_failed'
            : 'document_network_error',
      );
    } on HttpException {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.network,
        diagnostic: 'document_http_client_error',
      );
    } on Object {
      throw const EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.network,
        diagnostic: 'document_network_error',
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  bool _isAllowedUri(Uri uri) =>
      uri.host.isNotEmpty &&
      (uri.scheme == 'https' || (_allowHttpForTesting && uri.scheme == 'http'));

  bool _isDnsFailure(SocketException error) {
    if (error.address == null) return true;
    final message = error.message.toLowerCase();
    return message.contains('host lookup') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname') ||
        error.osError?.errorCode == 11001;
  }

  Future<void> _cancelResponse(HttpClientResponse response) async {
    try {
      final subscription = response.listen((_) {}, onError: (_) {});
      await subscription.cancel();
    } on Object {
      // 响应体取消失败时，仍应保留已经分类的响应错误。
    }
  }
}
