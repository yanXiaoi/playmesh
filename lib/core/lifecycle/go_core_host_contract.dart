abstract interface class GoCoreHost {
  Uri get endpoint;

  Future<void> start();

  Future<void> stop();
}

class GoCoreHostException implements Exception {
  const GoCoreHostException({
    required this.code,
    required this.userMessage,
    required this.diagnostic,
    this.cause,
  });

  final String code;
  final String userMessage;
  final String diagnostic;
  final Object? cause;

  @override
  String toString() {
    return 'GoCoreHostException(code=$code, diagnostic=$diagnostic)';
  }
}
