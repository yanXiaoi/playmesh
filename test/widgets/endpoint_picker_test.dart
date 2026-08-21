import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/endpoint_picker_controller.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/widgets/endpoint_picker.dart';

void main() {
  testWidgets('one picker widget is reused for both distribution levels', (
    tester,
  ) async {
    final service = EndpointProbeService(httpClient: _ReachableHttpClient());
    addTearDown(service.close);
    final configEndpoint = NamedDownloadEndpoint(
      name: 'Gitee config',
      url: Uri.parse('https://gitee.com/example/update.json'),
    );
    final zipEndpoint = NamedDownloadEndpoint(
      name: 'GitHub ZIP',
      url: Uri.parse('https://github.com/example/GDevelop-webide.zip'),
    );
    final configController = EndpointPickerController(
      endpoints: [configEndpoint],
      probeService: service,
    );
    final zipController = EndpointPickerController(
      endpoints: [zipEndpoint],
      probeService: service,
    );
    addTearDown(configController.dispose);
    addTearDown(zipController.dispose);
    await configController.probeAll();
    await zipController.probeAll();
    NamedDownloadEndpoint? selectedConfig;
    NamedDownloadEndpoint? selectedZip;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  EndpointPicker(
                    controller: configController,
                    title: 'Choose config source',
                    description: 'Select where to read update.json.',
                    refreshLabel: 'Refresh sources',
                    emptyLabel: 'No config sources.',
                    probingLabel: 'Checking source',
                    timeoutLabel: 'Source timed out',
                    unreachableLabel: 'Source unavailable',
                    unsupportedLabel: 'Cannot measure source',
                    latencyLabelBuilder: (ms) => 'Source latency $ms ms',
                    onSelected: (endpoint) => selectedConfig = endpoint,
                    autoProbe: false,
                  ),
                  const SizedBox(height: 24),
                  EndpointPicker(
                    controller: zipController,
                    title: 'Choose ZIP mirror',
                    description: 'Select one exact release download.',
                    refreshLabel: 'Refresh mirrors',
                    emptyLabel: 'No ZIP mirrors.',
                    probingLabel: 'Checking mirror',
                    timeoutLabel: 'Mirror timed out',
                    unreachableLabel: 'Mirror unavailable',
                    unsupportedLabel: 'Cannot measure mirror',
                    latencyLabelBuilder: (ms) => 'Mirror latency $ms ms',
                    onSelected: (endpoint) => selectedZip = endpoint,
                    autoProbe: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Choose config source'), findsOneWidget);
    expect(find.text('Choose ZIP mirror'), findsOneWidget);
    expect(find.text('gitee.com'), findsOneWidget);
    expect(find.text('github.com'), findsOneWidget);
    expect(find.textContaining('Source latency'), findsOneWidget);
    expect(find.textContaining('Mirror latency'), findsOneWidget);

    await tester.tap(find.text('Gitee config'));
    await tester.pump();
    expect(selectedConfig, same(configEndpoint));
    expect(selectedZip, isNull);

    await tester.tap(find.text('GitHub ZIP'));
    await tester.pump();
    expect(selectedZip, same(zipEndpoint));
    expect(configController.selected, same(configEndpoint));
  });

  testWidgets('unreachable endpoint is visibly disabled and cannot select', (
    tester,
  ) async {
    final service = EndpointProbeService(httpClient: _UnreachableHttpClient());
    addTearDown(service.close);
    final endpoint = NamedDownloadEndpoint(
      name: 'Unavailable',
      url: Uri.parse('https://example.com/update.json'),
    );
    final controller = EndpointPickerController(
      endpoints: [endpoint],
      probeService: service,
    );
    addTearDown(controller.dispose);
    await controller.probeAll();
    var selections = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EndpointPicker(
            controller: controller,
            title: 'Source',
            description: 'Pick a source.',
            refreshLabel: 'Refresh',
            emptyLabel: 'Empty',
            probingLabel: 'Checking',
            timeoutLabel: 'Timed out',
            unreachableLabel: 'Unavailable now',
            unsupportedLabel: 'Cannot measure',
            latencyLabelBuilder: (ms) => '$ms ms',
            onSelected: (_) => selections += 1,
            autoProbe: false,
          ),
        ),
      ),
    );

    expect(find.text('Unavailable now'), findsOneWidget);
    await tester.tap(find.text('Unavailable'), warnIfMissed: false);
    await tester.pump();
    expect(selections, 0);
    expect(controller.selected, isNull);
  });
}

class _ReachableHttpClient implements EndpointProbeHttpClient {
  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async => EndpointProbeHttpResponse(statusCode: 204);

  @override
  void close() {}
}

class _UnreachableHttpClient implements EndpointProbeHttpClient {
  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async => EndpointProbeHttpResponse(statusCode: 404);

  @override
  void close() {}
}
