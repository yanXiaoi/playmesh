import 'named_download_endpoint.dart';

enum EndpointDocumentFailureKind {
  invalidUrl,
  http,
  timeout,
  dns,
  tls,
  tooLarge,
  invalidUtf8,
  invalidDocument,
  network,
  unsupported,
}

class EndpointDocumentLoadException implements Exception {
  const EndpointDocumentLoadException({
    required this.kind,
    required this.diagnostic,
    this.httpStatus,
  });

  final EndpointDocumentFailureKind kind;
  final String diagnostic;
  final int? httpStatus;

  @override
  String toString() => 'EndpointDocumentLoadException($diagnostic)';
}

abstract interface class EndpointDocumentHttpClient {
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  });

  void close();
}

typedef EndpointDocumentParser<T> = T Function(String source);

class EndpointDocumentLoader {
  const EndpointDocumentLoader({
    required this.httpClient,
    this.maxBytes = 512 * 1024,
    this.timeout = const Duration(seconds: 8),
  }) : assert(maxBytes > 0),
       assert(timeout > Duration.zero);

  final EndpointDocumentHttpClient httpClient;
  final int maxBytes;
  final Duration timeout;

  Future<T> load<T>({
    required NamedDownloadEndpoint endpoint,
    required EndpointDocumentParser<T> parse,
  }) async {
    final source = await httpClient.get(
      url: endpoint.url,
      maxBytes: maxBytes,
      timeout: timeout,
    );
    try {
      return parse(source);
    } on FormatException catch (error) {
      throw EndpointDocumentLoadException(
        kind: EndpointDocumentFailureKind.invalidDocument,
        diagnostic: 'invalid_document:${error.message}',
      );
    }
  }
}
