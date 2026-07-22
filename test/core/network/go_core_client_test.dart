import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:playmesh/core/network/go_core_client.dart';

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:43210/');

  test('fetchHealth sends and traces the same request ID', () async {
    final logs = <Map<String, Object?>>[];
    final httpClient = MockClient((request) async {
      expect(request.url.toString(), 'http://127.0.0.1:43210/health');
      expect(request.headers['X-Request-ID'], 'req-client-1');

      return http.Response(
        jsonEncode({
          'type': 'core.health',
          'protocolVersion': '1.0.0',
          'timestamp': 1760000000100,
          'requestId': 'req-client-1',
          'data': {
            'status': 'online',
            'coreVersion': '0.1.0',
            'startedAt': 1760000000000,
          },
        }),
        200,
        headers: {'x-request-id': 'req-client-1'},
      );
    });
    final client = GoCoreClient(
      baseUri: baseUri,
      httpClient: httpClient,
      requestIdFactory: () => 'req-client-1',
      logSink: logs.add,
    );

    final status = await client.fetchHealth();

    expect(status.coreVersion, '0.1.0');
    expect(logs.map((record) => record['event']), [
      'core.health.requested',
      'core.health.succeeded',
    ]);
    expect(
      logs.every((record) => record['requestId'] == 'req-client-1'),
      isTrue,
    );
  });

  test('fetchHealth exposes a structured server error', () async {
    final client = GoCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'type': 'core.error',
              'protocolVersion': '1.0.0',
              'timestamp': 1760000000100,
              'requestId': 'req-client-error',
              'error': {
                'code': 'health_unavailable',
                'message': 'Go Core 暂时不可用',
              },
            }),
          ),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      requestIdFactory: () => 'req-client-error',
      logSink: (_) {},
    );

    await expectLater(
      client.fetchHealth(),
      throwsA(
        isA<GoCoreException>()
            .having((error) => error.code, 'code', 'health_unavailable')
            .having(
              (error) => error.requestId,
              'requestId',
              'req-client-error',
            ),
      ),
    );
  });

  test('fetchHealth rejects invalid JSON', () async {
    final client = GoCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((_) async => http.Response('not-json', 200)),
      requestIdFactory: () => 'req-invalid-json',
      logSink: (_) {},
    );

    await expectLater(
      client.fetchHealth(),
      throwsA(
        isA<GoCoreException>().having(
          (error) => error.code,
          'code',
          'invalid_json',
        ),
      ),
    );
  });

  test('fetchHealth maps an unreachable server to an offline error', () async {
    final client = GoCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (request) async => throw http.ClientException('refused', request.url),
      ),
      requestIdFactory: () => 'req-unreachable',
      logSink: (_) {},
    );

    await expectLater(
      client.fetchHealth(),
      throwsA(
        isA<GoCoreException>()
            .having((error) => error.code, 'code', 'core_unreachable')
            .having((error) => error.isOffline, 'isOffline', isTrue),
      ),
    );
  });

  test('fetchHealth maps a timeout to an offline error', () async {
    final client = GoCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response('{}', 200);
      }),
      timeout: const Duration(milliseconds: 1),
      requestIdFactory: () => 'req-timeout',
      logSink: (_) {},
    );

    await expectLater(
      client.fetchHealth(),
      throwsA(
        isA<GoCoreException>().having(
          (error) => error.code,
          'code',
          'core_timeout',
        ),
      ),
    );
  });
}
