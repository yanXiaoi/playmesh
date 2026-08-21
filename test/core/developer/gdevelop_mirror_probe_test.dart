import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/endpoint_probe.dart';

typedef GDevelopMirrorProbe = EndpointProbeService;
typedef GDevelopMirrorProbeState = EndpointProbeState;
typedef GDevelopMirrorProbeFailureKind = EndpointProbeFailureKind;
typedef GDevelopMirrorProbeHttpClient = EndpointProbeHttpClient;
typedef GDevelopMirrorProbeHttpResponse = EndpointProbeHttpResponse;
typedef GDevelopMirrorDnsException = EndpointProbeDnsException;
typedef GDevelopMirrorTlsException = EndpointProbeTlsException;
typedef GDevelopMirrorNetworkException = EndpointProbeNetworkException;

void main() {
  test('successful HEAD reports reachable connection latency', () async {
    var cancelled = 0;
    final client = _ScriptedProbeClient((request) async {
      expect(request.method, 'HEAD');
      expect(request.headers, isEmpty);
      return GDevelopMirrorProbeHttpResponse(
        statusCode: 204,
        cancelBody: () async => cancelled += 1,
      );
    });
    final probe = _probe(client);
    addTearDown(probe.close);
    final updates = <GDevelopMirrorProbeState>[];

    final result = await probe.probe(
      Uri.parse('https://example.com/webide.zip'),
      onUpdate: (result) => updates.add(result.state),
    );

    expect(
      result.state,
      GDevelopMirrorProbeState.reachable,
      reason: '${result.failureKind}/${result.httpStatus}/${result.diagnostic}',
    );
    expect(result.latencyMs, isNotNull);
    expect(updates, [
      GDevelopMirrorProbeState.probing,
      GDevelopMirrorProbeState.reachable,
    ]);
    expect(cancelled, 1);
  });

  test('405 HEAD falls back to a one-byte Range GET', () async {
    var calls = 0;
    var cancelled = 0;
    final client = _ScriptedProbeClient((request) async {
      calls += 1;
      if (calls == 1) {
        expect(request.method, 'HEAD');
        return GDevelopMirrorProbeHttpResponse(
          statusCode: 405,
          cancelBody: () async => cancelled += 1,
        );
      }
      expect(request.method, 'GET');
      expect(request.headers, {'Range': 'bytes=0-0'});
      return GDevelopMirrorProbeHttpResponse(
        statusCode: 206,
        cancelBody: () async => cancelled += 1,
      );
    });
    final probe = _probe(client);
    addTearDown(probe.close);

    final result = await probe.probe(Uri.parse('https://example.com/a.zip'));

    expect(result.state, GDevelopMirrorProbeState.reachable);
    expect(calls, 2);
    expect(cancelled, 2);
  });

  test(
    '403 HEAD may probe GET and cancels a 200 body that ignored Range',
    () async {
      var calls = 0;
      var cancelled = 0;
      final client = _ScriptedProbeClient((request) async {
        calls += 1;
        return GDevelopMirrorProbeHttpResponse(
          statusCode: calls == 1 ? 403 : 200,
          cancelBody: () async => cancelled += 1,
        );
      });
      final probe = _probe(client);
      addTearDown(probe.close);

      final result = await probe.probe(Uri.parse('https://example.com/a.zip'));

      expect(result.state, GDevelopMirrorProbeState.reachable);
      expect(client.requests.last.method, 'GET');
      expect(client.requests.last.headers['Range'], 'bytes=0-0');
      expect(cancelled, 2, reason: '不读取被忽略 Range 的完整响应体');
    },
  );

  test('404 and 410 are directly unreachable without fallback', () async {
    for (final statusCode in const [404, 410]) {
      final client = _ScriptedProbeClient(
        (request) async =>
            GDevelopMirrorProbeHttpResponse(statusCode: statusCode),
      );
      final probe = _probe(client);

      final result = await probe.probe(
        Uri.parse('https://example.com/$statusCode.zip'),
      );

      expect(result.state, GDevelopMirrorProbeState.unreachable);
      expect(result.failureKind, GDevelopMirrorProbeFailureKind.http);
      expect(result.httpStatus, statusCode);
      expect(client.requests, hasLength(1));
      probe.close();
    }
  });

  test('method rejection by both probes reports unsupported', () async {
    var call = 0;
    final client = _ScriptedProbeClient(
      (request) async =>
          GDevelopMirrorProbeHttpResponse(statusCode: call++ == 0 ? 405 : 501),
    );
    final probe = _probe(client);
    addTearDown(probe.close);

    final result = await probe.probe(Uri.parse('https://example.com/a.zip'));

    expect(result.state, GDevelopMirrorProbeState.unsupported);
    expect(result.failureKind, GDevelopMirrorProbeFailureKind.unsupported);
    expect(result.diagnostic, 'probe_method_unsupported');
  });

  test(
    'timeout, DNS, TLS and network failures remain distinguishable',
    () async {
      final scenarios = <Object, GDevelopMirrorProbeFailureKind>{
        const GDevelopMirrorDnsException(): GDevelopMirrorProbeFailureKind.dns,
        const GDevelopMirrorTlsException(): GDevelopMirrorProbeFailureKind.tls,
        const GDevelopMirrorNetworkException():
            GDevelopMirrorProbeFailureKind.network,
      };
      for (final scenario in scenarios.entries) {
        final client = _ScriptedProbeClient((request) async {
          throw scenario.key;
        });
        final probe = _probe(client);
        final result = await probe.probe(
          Uri.parse('https://example.com/${scenario.value.name}.zip'),
        );
        expect(result.state, GDevelopMirrorProbeState.unreachable);
        expect(result.failureKind, scenario.value);
        probe.close();
      }

      final timeoutClient = _ScriptedProbeClient(
        (request) => Completer<GDevelopMirrorProbeHttpResponse>().future,
      );
      final timeoutProbe = _probe(
        timeoutClient,
        timeout: const Duration(milliseconds: 10),
      );
      addTearDown(timeoutProbe.close);
      final timeoutResult = await timeoutProbe.probe(
        Uri.parse('https://example.com/timeout.zip'),
      );
      expect(timeoutResult.state, GDevelopMirrorProbeState.timeout);
      expect(timeoutResult.failureKind, GDevelopMirrorProbeFailureKind.timeout);
    },
  );

  test('HTTP client follows redirects before reporting reachable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/final');
      } else {
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
    });
    final probe = createEndpointProbeService(
      timeout: const Duration(seconds: 2),
    );
    addTearDown(probe.close);

    final result = await probe.probe(
      Uri.parse('http://127.0.0.1:${server.port}/start'),
      refresh: true,
    );

    expect(
      result.state,
      GDevelopMirrorProbeState.reachable,
      reason:
          '${result.failureKind}/${result.httpStatus}/${result.diagnostic}; '
          'paths=$paths',
    );
    expect(paths, ['/start', '/final']);
  });

  test(
    'probeAll enforces max concurrency while preserving input order',
    () async {
      var active = 0;
      var peak = 0;
      final client = _ScriptedProbeClient((request) async {
        active += 1;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        active -= 1;
        return GDevelopMirrorProbeHttpResponse(statusCode: 204);
      });
      final probe = _probe(client, maxConcurrency: 4);
      addTearDown(probe.close);
      final urls = List.generate(
        9,
        (index) => Uri.parse('https://example.com/$index.zip'),
      );

      final results = await probe.probeAll(urls);

      expect(peak, 4);
      expect(peak, lessThanOrEqualTo(4));
      expect(results.map((result) => result.url), urls);
    },
  );

  test(
    'short session cache is reused and manual refresh bypasses it',
    () async {
      var now = DateTime.utc(2026, 8, 5);
      var calls = 0;
      final client = _ScriptedProbeClient((request) async {
        calls += 1;
        return GDevelopMirrorProbeHttpResponse(statusCode: 204);
      });
      final probe = GDevelopMirrorProbe(
        httpClient: client,
        clock: () => now,
        cacheDuration: const Duration(seconds: 30),
      );
      addTearDown(probe.close);
      final url = Uri.parse('https://example.com/a.zip');

      await probe.probe(url);
      final cachedUpdates = <GDevelopMirrorProbeState>[];
      await probe.probe(
        url,
        onUpdate: (result) => cachedUpdates.add(result.state),
      );
      expect(calls, 1);
      expect(cachedUpdates, [GDevelopMirrorProbeState.reachable]);

      await probe.refresh(url);
      expect(calls, 2);

      now = now.add(const Duration(seconds: 31));
      await probe.probe(url);
      expect(calls, 3);
    },
  );

  test('config source and ZIP URL have independent cache keys', () async {
    var calls = 0;
    final client = _ScriptedProbeClient((request) async {
      calls += 1;
      return GDevelopMirrorProbeHttpResponse(statusCode: 204);
    });
    final probe = _probe(client);
    addTearDown(probe.close);
    final configUrl = Uri.parse('https://example.com/update.json');
    final zipUrl = Uri.parse('https://example.com/GDevelop-webide.zip');

    await probe.probe(configUrl);
    await probe.probe(zipUrl);
    await probe.probe(configUrl);
    await probe.probe(zipUrl);

    expect(calls, 2, reason: '两级 URL 各自命中自己的缓存键');
  });
}

GDevelopMirrorProbe _probe(
  GDevelopMirrorProbeHttpClient client, {
  int maxConcurrency = 4,
  Duration timeout = const Duration(seconds: 1),
}) => GDevelopMirrorProbe(
  httpClient: client,
  maxConcurrency: maxConcurrency,
  timeout: timeout,
  cacheDuration: const Duration(seconds: 30),
);

class _ProbeRequest {
  const _ProbeRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.timeout,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Duration timeout;
}

class _ScriptedProbeClient implements GDevelopMirrorProbeHttpClient {
  _ScriptedProbeClient(this.handler);

  final Future<GDevelopMirrorProbeHttpResponse> Function(_ProbeRequest request)
  handler;
  final List<_ProbeRequest> requests = [];
  var closed = false;

  @override
  Future<GDevelopMirrorProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) {
    final request = _ProbeRequest(
      method: method,
      url: url,
      headers: Map.unmodifiable(headers),
      timeout: timeout,
    );
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}
