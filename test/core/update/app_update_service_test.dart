import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/download/app_resource_source_catalog.dart';
import 'package:playmesh/core/download/endpoint_document_contract.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/update/app_update_models.dart';
import 'package:playmesh/core/update/app_update_service.dart';
import 'package:playmesh/core/version/semantic_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('packages App.json but not the dynamic update example', () async {
    final source = await rootBundle.loadString(
      appResourceSourceCatalogAssetPath,
    );
    final catalog = AppResourceSourceCatalog.parse(source);
    expect(
      catalog.endpointsFor('app', allowEmpty: false).endpoints,
      isNotEmpty,
    );
    expect(catalog.endpointsFor('gdevelop').endpoints, isNotEmpty);
    await expectLater(
      rootBundle.loadString('assets/app/app_update.json'),
      throwsA(anything),
    );
    await expectLater(
      rootBundle.loadString('assets/app/GdevelopWebIDE.json'),
      throwsA(anything),
    );
  });

  test(
    'loads every source concurrently and selects the greatest version',
    () async {
      final documentClient = _BarrierDocumentClient(
        expectedRequests: 3,
        documents: {
          'https://updates.example.com/a.json': _manifest(
            version: '4.4.0',
            platform: 'windows',
            name: '线路 A',
            url: 'https://download.example.com/a.exe',
          ),
          'https://updates.example.com/b.json': '{invalid',
          'https://updates.example.com/c.json': _manifest(
            version: '5.0.0',
            platform: 'windows',
            name: '线路 C',
            url: 'http://download.example.com/c.exe#latest',
          ),
        },
      );
      final probeClient = _ReachableProbeClient();
      Uri? openedUrl;
      final service = AppUpdateService(
        assetLoader: (_) async => _sources,
        documentLoader: EndpointDocumentLoader(httpClient: documentClient),
        probeService: EndpointProbeService(httpClient: probeClient),
        platform: 'Windows',
        currentVersion: SemanticVersion.parse('4.2.0'),
        urlLauncher: (url) async {
          openedUrl = url;
          return true;
        },
        clock: () => DateTime.utc(2026, 8, 10),
      );

      final result = await service.checkForUpdates();

      expect(documentClient.maxInFlight, 3);
      expect(result.sourceCount, 3);
      expect(result.successfulSourceCount, 2);
      expect(result.source.name, 'C');
      expect(result.latestVersion.toString(), '5.0.0');
      expect(result.versionState, AppUpdateVersionState.available);
      expect(result.platform, 'windows');
      expect(result.downloads.single.endpoint.name, '线路 C');
      expect(result.downloads.single.probe.state, EndpointProbeState.reachable);

      expect(await service.openDownload(result.downloads.single), isTrue);
      expect(openedUrl, Uri.parse('http://download.example.com/c.exe#latest'));
    },
  );

  test('selects the greatest version before looking up the platform', () async {
    final documentClient = _BarrierDocumentClient(
      expectedRequests: 3,
      documents: {
        'https://updates.example.com/a.json': _manifest(
          version: '4.4.0',
          platform: 'windows',
          name: 'Windows',
          url: 'https://download.example.com/windows.exe',
        ),
        'https://updates.example.com/b.json': _manifest(
          version: '6.0.0',
          platform: 'android',
          name: 'Android',
          url: 'https://download.example.com/android.apk',
        ),
        'https://updates.example.com/c.json': '{invalid',
      },
    );
    final service = AppUpdateService(
      assetLoader: (_) async => _sources,
      documentLoader: EndpointDocumentLoader(httpClient: documentClient),
      probeService: EndpointProbeService(httpClient: _ReachableProbeClient()),
      platform: 'windows',
      currentVersion: SemanticVersion.parse('4.2.0'),
      urlLauncher: (_) async => true,
    );

    final result = await service.checkForUpdates();

    expect(result.latestVersion.toString(), '6.0.0');
    expect(result.source.name, 'B');
    expect(result.platformAvailable, isFalse);
    expect(result.downloads, isEmpty);
  });

  test(
    'reports invalid bundled sources separately from remote failures',
    () async {
      final service = AppUpdateService(
        assetLoader: (_) async => '[{"name":"Bad","app":42}]',
        documentLoader: EndpointDocumentLoader(
          httpClient: _BarrierDocumentClient(
            expectedRequests: 0,
            documents: const {},
          ),
        ),
        probeService: EndpointProbeService(httpClient: _ReachableProbeClient()),
        platform: 'windows',
        currentVersion: SemanticVersion.parse('4.2.0'),
        urlLauncher: (_) async => true,
      );

      await expectLater(
        service.checkForUpdates(),
        throwsA(
          isA<AppUpdateCheckException>().having(
            (error) => error.kind,
            'kind',
            AppUpdateCheckFailureKind.invalidConfiguration,
          ),
        ),
      );
    },
  );
}

const String _sources = '''
[
  {"name":"A","app":"https://updates.example.com/a.json"},
  {"name":"GDevelop only","gdevelop":"https://updates.example.com/gdevelop.json"},
  {"name":"B","app":"https://updates.example.com/b.json","future":"ignored"},
  {"name":"C","app":"https://updates.example.com/c.json"}
]
''';

String _manifest({
  required String version,
  required String platform,
  required String name,
  required String url,
}) =>
    '''
{
  "version":"$version",
  "releaseNotes":"版本 $version 说明",
  "$platform":{"downloads":[{"name":"$name","url":"$url"}]}
}
''';

final class _BarrierDocumentClient implements EndpointDocumentHttpClient {
  _BarrierDocumentClient({
    required this.expectedRequests,
    required this.documents,
  });

  final int expectedRequests;
  final Map<String, String> documents;
  final Completer<void> _barrier = Completer<void>();
  var _inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) async {
    _inFlight += 1;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    if (_inFlight == expectedRequests && !_barrier.isCompleted) {
      _barrier.complete();
    }
    if (expectedRequests > 0) await _barrier.future.timeout(timeout);
    _inFlight -= 1;
    return documents[url.toString()]!;
  }

  @override
  void close() {}
}

final class _ReachableProbeClient implements EndpointProbeHttpClient {
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
