import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/lifecycle/go_core_host.dart';
import 'package:playmesh/core/network/go_core_client.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_runtime.dart';

void main() {
  test('starts the bundled host before checking and stops on close', () async {
    final host = _StubHost();
    final client = _RuntimeClient();
    final runtime = GoCoreRuntime(host: host, client: client);

    final result = await runtime.check();

    expect(host.startCalls, 1);
    expect(client.fetchCalls, 1);
    expect(result.availability, GoCoreAvailability.online);

    await runtime.close();
    expect(host.stopCalls, 1);
    expect(client.closed, isTrue);
  });

  test('maps a bundled host startup failure to error', () async {
    final host = _StubHost(
      startError: const GoCoreHostException(
        code: 'bundled_core_missing',
        userMessage: '应用缺少内置 Go Core，请重新安装。',
        diagnostic: 'missing executable',
      ),
    );
    final client = _RuntimeClient();
    final runtime = GoCoreRuntime(host: host, client: client);

    final result = await runtime.check();

    expect(result.availability, GoCoreAvailability.error);
    expect(result.message, contains('缺少内置 Go Core'));
    expect(client.fetchCalls, 0);
  });

  test(
    'creates the health client from the address reported by the host',
    () async {
      final host = _StubHost(
        initialEndpoint: Uri.parse('http://127.0.0.1:0/health'),
        boundEndpoint: Uri.parse('http://127.0.0.1:43210/health'),
      );
      Uri? clientEndpoint;
      final runtime = GoCoreRuntime(
        host: host,
        clientFactory: (endpoint) {
          clientEndpoint = endpoint;
          return _RuntimeClient(endpoint: endpoint);
        },
      );

      expect(runtime.endpoint.port, 0);

      final result = await runtime.check();

      expect(result.availability, GoCoreAvailability.online);
      expect(clientEndpoint, Uri.parse('http://127.0.0.1:43210/health'));
      expect(runtime.endpoint.port, 43210);
    },
  );
}

class _StubHost implements GoCoreHost {
  _StubHost({this.startError, Uri? initialEndpoint, this.boundEndpoint})
    : _endpoint = initialEndpoint ?? Uri.parse('http://127.0.0.1:43210/health');

  final GoCoreHostException? startError;
  final Uri? boundEndpoint;
  Uri _endpoint;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Uri get endpoint => _endpoint;

  @override
  Future<void> start() async {
    startCalls += 1;
    if (startError case final error?) {
      throw error;
    }
    if (boundEndpoint case final endpoint?) {
      _endpoint = endpoint;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}

class _RuntimeClient implements GoCoreHealthClient {
  _RuntimeClient({Uri? endpoint})
    : _endpoint = endpoint ?? Uri.parse('http://127.0.0.1:43210/health');

  final Uri _endpoint;
  int fetchCalls = 0;
  bool closed = false;

  @override
  Uri get endpoint => _endpoint;

  @override
  Future<GoCoreStatus> fetchHealth({String? requestId}) async {
    fetchCalls += 1;
    return GoCoreStatus(
      requestId: 'req-runtime',
      status: 'online',
      coreVersion: '0.1.0',
      timestamp: DateTime.utc(2026, 7, 15, 8, 30),
      startedAt: DateTime.utc(2026, 7, 15, 8),
    );
  }

  @override
  void close() {
    closed = true;
  }
}
