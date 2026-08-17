import 'dart:async';

enum EndpointProbeState {
  probing,
  reachable,
  timeout,
  unreachable,
  unsupported,
}

enum EndpointProbeFailureKind { http, dns, tls, timeout, network, unsupported }

class EndpointProbeResult {
  const EndpointProbeResult({
    required this.url,
    required this.state,
    this.latency,
    this.failureKind,
    this.httpStatus,
    this.diagnostic,
  });

  const EndpointProbeResult.probing(Uri url)
    : this(url: url, state: EndpointProbeState.probing);

  final Uri url;
  final EndpointProbeState state;
  final Duration? latency;
  final EndpointProbeFailureKind? failureKind;
  final int? httpStatus;
  final String? diagnostic;

  int? get latencyMs => latency?.inMilliseconds;
}

abstract interface class EndpointProbeHttpClient {
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  });

  void close();
}

class EndpointProbeHttpResponse {
  EndpointProbeHttpResponse({
    required this.statusCode,
    Map<String, List<String>> headers = const {},
    Future<void> Function()? cancelBody,
  }) : headers = Map.unmodifiable({
         for (final entry in headers.entries)
           entry.key.toLowerCase(): List.unmodifiable(entry.value),
       }),
       _cancelBody = cancelBody ?? _noop;

  final int statusCode;
  final Map<String, List<String>> headers;
  final Future<void> Function() _cancelBody;

  List<String> headerValues(String name) =>
      headers[name.toLowerCase()] ?? const [];

  Future<void> cancelBody() => _cancelBody();

  static Future<void> _noop() async {}
}

class EndpointProbeDnsException implements Exception {
  const EndpointProbeDnsException();
}

class EndpointProbeTlsException implements Exception {
  const EndpointProbeTlsException();
}

class EndpointProbeNetworkException implements Exception {
  const EndpointProbeNetworkException([this.diagnostic = 'network_error']);

  final String diagnostic;
}

class EndpointProbeUnsupportedException implements Exception {
  const EndpointProbeUnsupportedException();
}

typedef EndpointProbeUpdate = void Function(EndpointProbeResult result);

class EndpointProbeService {
  EndpointProbeService({
    required this.httpClient,
    this.maxConcurrency = 4,
    this.timeout = const Duration(seconds: 4),
    this.cacheDuration = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : assert(maxConcurrency > 0),
       assert(timeout > Duration.zero),
       assert(!cacheDuration.isNegative),
       _clock = clock ?? DateTime.now;

  final int maxConcurrency;
  final Duration timeout;
  final Duration cacheDuration;
  final EndpointProbeHttpClient httpClient;
  final DateTime Function() _clock;
  final Map<String, _EndpointProbeCacheEntry> _cache = {};

  Future<EndpointProbeResult> probe(
    Uri url, {
    bool refresh = false,
    EndpointProbeUpdate? onUpdate,
  }) async {
    final cacheKey = normalizedEndpointProbeCacheKey(url);
    final now = _clock();
    final cached = _cache[cacheKey];
    final cacheAge = cached == null ? null : now.difference(cached.recordedAt);
    if (!refresh &&
        cached != null &&
        !cacheAge!.isNegative &&
        cacheAge < cacheDuration) {
      onUpdate?.call(cached.result);
      return cached.result;
    }

    onUpdate?.call(EndpointProbeResult.probing(url));
    final result = await _probeUncached(url);
    _cache[cacheKey] = _EndpointProbeCacheEntry(
      result: result,
      recordedAt: _clock(),
    );
    onUpdate?.call(result);
    return result;
  }

  Future<EndpointProbeResult> refresh(
    Uri url, {
    EndpointProbeUpdate? onUpdate,
  }) => probe(url, refresh: true, onUpdate: onUpdate);

  Future<List<EndpointProbeResult>> probeAll(
    Iterable<Uri> urls, {
    bool refresh = false,
    EndpointProbeUpdate? onUpdate,
  }) async {
    final targets = urls.toList(growable: false);
    final results = List<EndpointProbeResult?>.filled(targets.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < targets.length) {
        final index = nextIndex;
        nextIndex += 1;
        results[index] = await probe(
          targets[index],
          refresh: refresh,
          onUpdate: onUpdate,
        );
      }
    }

    final workerCount = targets.length < maxConcurrency
        ? targets.length
        : maxConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<EndpointProbeResult>();
  }

  Future<List<EndpointProbeResult>> refreshAll(
    Iterable<Uri> urls, {
    EndpointProbeUpdate? onUpdate,
  }) => probeAll(urls, refresh: true, onUpdate: onUpdate);

  void clearCache() => _cache.clear();

  void close() => httpClient.close();

  Future<EndpointProbeResult> _probeUncached(Uri url) async {
    final stopwatch = Stopwatch()..start();
    try {
      final head = await _send(
        method: 'HEAD',
        url: url,
        headers: const {},
        remaining: () => _remaining(stopwatch),
      );
      final headStatus = head.statusCode;
      final fallback = _shouldFallbackToRange(head);
      await _cancelResponseBody(head);

      if (headStatus == 404 || headStatus == 410) {
        return _httpFailure(url, headStatus);
      }
      if (!fallback) {
        if (headStatus >= 200 && headStatus < 400) {
          stopwatch.stop();
          return EndpointProbeResult(
            url: url,
            state: EndpointProbeState.reachable,
            latency: stopwatch.elapsed,
          );
        }
        return _httpFailure(url, headStatus);
      }

      final range = await _send(
        method: 'GET',
        url: url,
        headers: const {'Range': 'bytes=0-0'},
        remaining: () => _remaining(stopwatch),
      );
      final rangeStatus = range.statusCode;
      await _cancelResponseBody(range);
      if (rangeStatus == 200 || rangeStatus == 206) {
        stopwatch.stop();
        return EndpointProbeResult(
          url: url,
          state: EndpointProbeState.reachable,
          latency: stopwatch.elapsed,
        );
      }
      if (rangeStatus == 405 || rangeStatus == 501) {
        return EndpointProbeResult(
          url: url,
          state: EndpointProbeState.unsupported,
          failureKind: EndpointProbeFailureKind.unsupported,
          httpStatus: rangeStatus,
          diagnostic: 'probe_method_unsupported',
        );
      }
      return _httpFailure(url, rangeStatus);
    } on TimeoutException {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.timeout,
        failureKind: EndpointProbeFailureKind.timeout,
        diagnostic: 'probe_timeout',
      );
    } on EndpointProbeDnsException {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unreachable,
        failureKind: EndpointProbeFailureKind.dns,
        diagnostic: 'dns_lookup_failed',
      );
    } on EndpointProbeTlsException {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unreachable,
        failureKind: EndpointProbeFailureKind.tls,
        diagnostic: 'tls_handshake_failed',
      );
    } on EndpointProbeUnsupportedException {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unsupported,
        failureKind: EndpointProbeFailureKind.unsupported,
        diagnostic: 'probe_unsupported',
      );
    } on EndpointProbeNetworkException catch (error) {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unreachable,
        failureKind: EndpointProbeFailureKind.network,
        diagnostic: error.diagnostic,
      );
    } on Object {
      return EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unreachable,
        failureKind: EndpointProbeFailureKind.network,
        diagnostic: 'network_error',
      );
    }
  }

  Future<EndpointProbeHttpResponse> _send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration Function() remaining,
  }) {
    final limit = remaining();
    return httpClient
        .send(method: method, url: url, headers: headers, timeout: limit)
        .timeout(limit);
  }

  Duration _remaining(Stopwatch stopwatch) {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('probe timeout');
    return remaining;
  }

  bool _shouldFallbackToRange(EndpointProbeHttpResponse response) {
    if (response.statusCode == 403 ||
        response.statusCode == 405 ||
        response.statusCode == 501) {
      return true;
    }
    final allowed = response
        .headerValues('allow')
        .expand((value) => value.split(','))
        .map((value) => value.trim().toUpperCase())
        .toSet();
    return allowed.contains('GET') && !allowed.contains('HEAD');
  }

  Future<void> _cancelResponseBody(EndpointProbeHttpResponse response) async {
    try {
      await response.cancelBody();
    } on Object {
      // 此时响应头与首字节耗时已经可用；取消响应体仅作尽力处理，
      // 不能把可达端点误判为网络失败。
    }
  }

  EndpointProbeResult _httpFailure(Uri url, int statusCode) =>
      EndpointProbeResult(
        url: url,
        state: EndpointProbeState.unreachable,
        failureKind: EndpointProbeFailureKind.http,
        httpStatus: statusCode,
        diagnostic: 'http_status_$statusCode',
      );
}

String normalizedEndpointProbeCacheKey(Uri url) =>
    url.normalizePath().toString();

class _EndpointProbeCacheEntry {
  const _EndpointProbeCacheEntry({
    required this.result,
    required this.recordedAt,
  });

  final EndpointProbeResult result;
  final DateTime recordedAt;
}
