import 'endpoint_document_contract.dart';

EndpointDocumentHttpClient createEndpointDocumentHttpClient() =>
    _UnsupportedEndpointDocumentHttpClient();

class _UnsupportedEndpointDocumentHttpClient
    implements EndpointDocumentHttpClient {
  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) => throw const EndpointDocumentLoadException(
    kind: EndpointDocumentFailureKind.unsupported,
    diagnostic: 'endpoint_document_unsupported',
  );

  @override
  void close() {}
}
