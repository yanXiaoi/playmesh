import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/network/go_core_client.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_status_service.dart';

void main() {
  test('maps a health response to online', () async {
    final service = GoCoreStatusService(
      _StubHealthClient(status: _onlineStatus('req-service-online')),
    );

    final result = await service.check();

    expect(result.availability, GoCoreAvailability.online);
    expect(result.requestId, 'req-service-online');
  });

  test('maps a connection exception to offline', () async {
    final service = GoCoreStatusService(
      _StubHealthClient(
        error: const GoCoreException(
          code: 'core_unreachable',
          userMessage: '无法连接 Go Core',
          requestId: 'req-service-offline',
          diagnostic: 'refused',
        ),
      ),
    );

    final result = await service.check();

    expect(result.availability, GoCoreAvailability.offline);
    expect(result.requestId, 'req-service-offline');
  });

  test('maps a protocol exception to error', () async {
    final service = GoCoreStatusService(
      _StubHealthClient(
        error: const GoCoreException(
          code: 'invalid_response',
          userMessage: '响应无效',
          requestId: 'req-service-error',
          diagnostic: 'bad schema',
        ),
      ),
    );

    final result = await service.check();

    expect(result.availability, GoCoreAvailability.error);
    expect(result.requestId, 'req-service-error');
  });
}

class _StubHealthClient implements GoCoreHealthClient {
  _StubHealthClient({this.status, this.error});

  final GoCoreStatus? status;
  final GoCoreException? error;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatus> fetchHealth({String? requestId}) async {
    if (error case final exception?) {
      throw exception;
    }
    return status!;
  }

  @override
  void close() {}
}

GoCoreStatus _onlineStatus(String requestId) {
  return GoCoreStatus(
    requestId: requestId,
    status: 'online',
    coreVersion: '0.1.0',
    timestamp: DateTime.utc(2026, 7, 15, 8, 30),
    startedAt: DateTime.utc(2026, 7, 15, 8),
  );
}
