import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/endpoint_picker_controller.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';

void main() {
  test(
    'independent pickers share URL cache without sharing selection or errors',
    () async {
      var statusCode = 204;
      var calls = 0;
      final httpClient = _PickerProbeHttpClient((request) async {
        calls += 1;
        return EndpointProbeHttpResponse(statusCode: statusCode);
      });
      final probeService = EndpointProbeService(httpClient: httpClient);
      addTearDown(probeService.close);
      final firstEndpoint = NamedDownloadEndpoint(
        name: 'Config source',
        url: Uri.parse('https://example.com/shared.json'),
      );
      final secondEndpoint = NamedDownloadEndpoint(
        name: 'ZIP mirror',
        url: Uri.parse('https://example.com/shared.json'),
      );
      final first = EndpointPickerController(
        endpoints: [firstEndpoint],
        probeService: probeService,
      );
      final second = EndpointPickerController(
        endpoints: [secondEndpoint],
        probeService: probeService,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.probeAll();
      await second.probeAll();
      expect(calls, 1, reason: '两个 picker 实例复用按 URL 的会话缓存');
      expect(first.select(firstEndpoint), isTrue);
      expect(first.selected, same(firstEndpoint));
      expect(second.selected, isNull);
      expect(second.select(secondEndpoint), isTrue);

      statusCode = 404;
      await first.refresh();
      expect(calls, 2);
      expect(
        first.resultFor(firstEndpoint)?.state,
        EndpointProbeState.unreachable,
      );
      expect(first.selected, isNull, reason: '只清理失效的本地选择');
      expect(
        second.resultFor(secondEndpoint)?.state,
        EndpointProbeState.reachable,
        reason: '共享 cache 不会回写其他 controller 的已显示状态',
      );
      expect(second.selected, same(secondEndpoint));
    },
  );

  test(
    'refresh probing state stays inside the initiating controller',
    () async {
      Completer<EndpointProbeHttpResponse>? pending;
      final client = _PickerProbeHttpClient((request) {
        final current = pending;
        if (current != null) return current.future;
        return Future.value(EndpointProbeHttpResponse(statusCode: 204));
      });
      final service = EndpointProbeService(httpClient: client);
      addTearDown(service.close);
      final endpoint = NamedDownloadEndpoint(
        name: 'Shared',
        url: Uri.parse('https://example.com/shared.json'),
      );
      final first = EndpointPickerController(
        endpoints: [endpoint],
        probeService: service,
      );
      final second = EndpointPickerController(
        endpoints: [endpoint],
        probeService: service,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.probeAll();
      await second.probeAll();

      pending = Completer<EndpointProbeHttpResponse>();
      final refresh = first.refresh();
      expect(first.resultFor(endpoint)?.state, EndpointProbeState.probing);
      expect(second.resultFor(endpoint)?.state, EndpointProbeState.reachable);

      pending.complete(EndpointProbeHttpResponse(statusCode: 204));
      await refresh;
      expect(first.resultFor(endpoint)?.state, EndpointProbeState.reachable);
    },
  );

  test(
    'unsupported remains selectable while unreachable is disabled by default',
    () async {
      var call = 0;
      final service = EndpointProbeService(
        httpClient: _PickerProbeHttpClient((request) async {
          call += 1;
          return EndpointProbeHttpResponse(statusCode: call == 1 ? 405 : 501);
        }),
      );
      addTearDown(service.close);
      final endpoint = NamedDownloadEndpoint(
        name: 'Cannot measure',
        url: Uri.parse('https://example.com/file.zip'),
      );
      final controller = EndpointPickerController(
        endpoints: [endpoint],
        probeService: service,
      );
      addTearDown(controller.dispose);

      await controller.probeAll();

      expect(
        controller.resultFor(endpoint)?.state,
        EndpointProbeState.unsupported,
      );
      expect(controller.canSelect(endpoint), isTrue);
      expect(controller.select(endpoint), isTrue);
    },
  );
}

class _ProbeRequest {
  const _ProbeRequest(this.method, this.url, this.headers, this.timeout);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Duration timeout;
}

class _PickerProbeHttpClient implements EndpointProbeHttpClient {
  _PickerProbeHttpClient(this.handler);

  final Future<EndpointProbeHttpResponse> Function(_ProbeRequest request)
  handler;

  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) => handler(_ProbeRequest(method, url, headers, timeout));

  @override
  void close() {}
}
