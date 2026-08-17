import 'dart:async';
import 'dart:io';

import 'endpoint_probe_contract.dart';

EndpointProbeHttpClient createEndpointProbeHttpClient() =>
    IoEndpointProbeHttpClient();

class IoEndpointProbeHttpClient implements EndpointProbeHttpClient {
  IoEndpointProbeHttpClient({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;
  var _closed = false;

  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    if (_closed) throw const EndpointProbeNetworkException();
    HttpClientRequest? request;
    try {
      final operation = () async {
        request = await _client.openUrl(method, url);
        request!.followRedirects = true;
        request!.maxRedirects = 5;
        for (final entry in headers.entries) {
          request!.headers.set(entry.key, entry.value);
        }
        final response = await request!.close();
        final responseHeaders = <String, List<String>>{};
        final allow = response.headers.value(HttpHeaders.allowHeader);
        if (allow != null) responseHeaders[HttpHeaders.allowHeader] = [allow];
        var cancelled = false;
        return EndpointProbeHttpResponse(
          statusCode: response.statusCode,
          headers: responseHeaders,
          cancelBody: () async {
            if (cancelled) return;
            cancelled = true;
            final subscription = response.listen(
              (_) {},
              onError: (_) {},
              cancelOnError: true,
            );
            await subscription.cancel();
          },
        );
      }();
      return await operation.timeout(
        timeout,
        onTimeout: () {
          request?.abort(TimeoutException('endpoint probe timeout'));
          throw TimeoutException('endpoint probe timeout', timeout);
        },
      );
    } on TimeoutException {
      rethrow;
    } on HandshakeException {
      throw const EndpointProbeTlsException();
    } on TlsException {
      throw const EndpointProbeTlsException();
    } on SocketException catch (error) {
      if (_isDnsFailure(error)) throw const EndpointProbeDnsException();
      throw const EndpointProbeNetworkException();
    } on HttpException catch (error) {
      throw EndpointProbeNetworkException('http_client_${error.runtimeType}');
    } on EndpointProbeNetworkException {
      rethrow;
    } on Object catch (error) {
      throw EndpointProbeNetworkException('network_${error.runtimeType}');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  bool _isDnsFailure(SocketException error) {
    if (error.address == null) return true;
    final message = error.message.toLowerCase();
    return message.contains('host lookup') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname') ||
        error.osError?.errorCode == 11001;
  }
}
