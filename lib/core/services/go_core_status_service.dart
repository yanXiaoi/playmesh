import '../network/go_core_client.dart';
import '../protocol/go_core_status.dart';

abstract interface class GoCoreStatusProvider {
  Uri get endpoint;

  Future<GoCoreStatusResult> check();

  Future<void> close();
}

class GoCoreStatusService implements GoCoreStatusProvider {
  const GoCoreStatusService(this._client);

  final GoCoreHealthClient _client;

  @override
  Uri get endpoint => _client.endpoint;

  @override
  Future<GoCoreStatusResult> check() async {
    try {
      final status = await _client.fetchHealth();
      return GoCoreStatusResult.online(status);
    } on GoCoreException catch (error) {
      if (error.isOffline) {
        return GoCoreStatusResult.offline(
          message: error.userMessage,
          requestId: error.requestId,
        );
      }
      return GoCoreStatusResult.error(
        message: error.userMessage,
        requestId: error.requestId,
      );
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}
