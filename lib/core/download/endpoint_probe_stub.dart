import 'endpoint_probe_contract.dart';

EndpointProbeHttpClient createEndpointProbeHttpClient() =>
    _UnsupportedEndpointProbeHttpClient();

class _UnsupportedEndpointProbeHttpClient implements EndpointProbeHttpClient {
  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) => throw const EndpointProbeUnsupportedException();

  @override
  void close() {}
}
