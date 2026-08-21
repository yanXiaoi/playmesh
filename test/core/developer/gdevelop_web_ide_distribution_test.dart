import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_distribution.dart';
import 'package:playmesh/core/download/app_resource_source_catalog.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';

const _testSha256 =
    '1111111111111111111111111111111111111111111111111111111111111111';

void main() {
  test('shared endpoint parser matches every Dart/Node fixture', () async {
    final fixture = await _fixture();
    for (final rawCase in fixture['endpointCases']! as List<Object?>) {
      final testCase = rawCase! as Map<String, Object?>;
      final source = testCase.containsKey('source')
          ? testCase['source']! as String
          : jsonEncode(testCase['value']);
      if (testCase['valid']! as bool) {
        NamedDownloadEndpointList.parse(source);
      } else {
        expect(
          () => NamedDownloadEndpointList.parse(source),
          throwsFormatException,
          reason: testCase['name']! as String,
        );
      }
    }
  });

  test('release manifest parser matches every Dart/Node fixture', () async {
    final fixture = await _fixture();
    for (final rawCase in fixture['manifestCases']! as List<Object?>) {
      final testCase = rawCase! as Map<String, Object?>;
      final source = testCase.containsKey('source')
          ? testCase['source']! as String
          : jsonEncode(testCase['value']);
      if (testCase['valid']! as bool) {
        GDevelopWebIdeReleaseManifest.parse(source);
      } else {
        expect(
          () => GDevelopWebIdeReleaseManifest.parse(source),
          throwsFormatException,
          reason: testCase['name']! as String,
        );
      }
    }
  });

  test('the two levels reuse one exact name/url model without merging', () {
    final sources = GDevelopWebIdeConfigSources.parse(
      jsonEncode([
        {
          'name': 'Gitee config',
          'app': 'https://gitee.com/example/app.json',
          'gdevelop': 'https://gitee.com/example/webide.json',
        },
        {'name': 'App only', 'app': 'https://example.com/app.json'},
        {
          'name': 'GitHub config',
          'gdevelop': 'https://github.com/example/webide.json',
          'futureResource': {'version': 1},
        },
      ]),
    );
    final selectedSource = sources.sources.singleWhere(
      (source) => source.name == 'GitHub config',
    );
    final manifest = GDevelopWebIdeReleaseManifest.fromJson({
      'version': 'release-1',
      'sha256': _testSha256,
      'size': 123,
      'downloads': [
        {
          'name': 'GitHub ZIP',
          'url': 'https://github.com/example/webide.zip?token=exact',
        },
      ],
    });

    expect(
      selectedSource.url.toString(),
      'https://github.com/example/webide.json',
    );
    expect(manifest.downloads, hasLength(1));
    expect(manifest.size, 123);
    expect(manifest.downloads.single, isA<NamedDownloadEndpoint>());
    expect(
      manifest.downloads.single.url.toString(),
      'https://github.com/example/webide.zip?token=exact',
    );
    expect(sources.sources, hasLength(2), reason: '选源不会合并不同源的 manifest');
  });

  test(
    'selected source list and manifest downloads enforce the shared cap',
    () {
      final tooMany = List<Object?>.generate(
        NamedDownloadEndpointList.maxEndpoints + 1,
        (index) => {
          'name': 'Endpoint $index',
          'url': 'https://example.com/file-$index.json',
        },
      );
      final tooManyConfigSources = List<Object?>.generate(
        NamedDownloadEndpointList.maxEndpoints + 1,
        (index) => {
          'name': 'Endpoint $index',
          'gdevelop': 'https://example.com/file-$index.json',
        },
      );
      expect(
        () =>
            GDevelopWebIdeConfigSources.parse(jsonEncode(tooManyConfigSources)),
        throwsFormatException,
      );
      expect(
        () => GDevelopWebIdeReleaseManifest.fromJson({
          'version': 'release-1',
          'sha256': _testSha256,
          'size': 123,
          'downloads': tooMany,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'resource projection may be empty and loader uses the unified asset path',
    () async {
      final bundle = _RecordingAssetBundle(
        '[{"name":"App only","app":"https://example.com/app.json"}]',
      );

      final sources = await GDevelopWebIdeConfigSourcesLoader(
        bundle: bundle,
      ).load();

      expect(sources.configured, isFalse);
      expect(sources.sources, isEmpty);
      expect(bundle.keys, [appResourceSourceCatalogAssetPath]);
      expect(appResourceSourceCatalogAssetPath, 'assets/app/App.json');
    },
  );
}

Future<Map<String, Object?>> _fixture() async =>
    jsonDecode(
          await File(
            'test/fixtures/gdevelop_web_ide_distribution_cases.json',
          ).readAsString(),
        )
        as Map<String, Object?>;

class _RecordingAssetBundle extends CachingAssetBundle {
  _RecordingAssetBundle(this.source);

  final String source;
  final List<String> keys = [];

  @override
  Future<ByteData> load(String key) async {
    keys.add(key);
    final bytes = Uint8List.fromList(utf8.encode(source));
    return ByteData.sublistView(bytes);
  }
}
