import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_distribution.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_models.dart';

void main() {
  const sha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('one platform hash is shared by every download route', () {
    final manifest = RuntimePackageReleaseManifest.parse(
      jsonEncode({
        'version': 'v1.0.0-build1',
        'platform': {
          'android': {
            'x86': {
              'sha256': sha256,
              'downloads': [
                {'name': 'HTTPS', 'url': 'https://example.com/x86.apk'},
                {'name': 'HTTP', 'url': 'http://example.com/x86.apk'},
              ],
            },
            'arm': {
              'sha256': sha256,
              'downloads': [
                {'name': 'Placeholder', 'url': ''},
              ],
            },
          },
          'windows': {
            'sha256': sha256,
            'downloads': [
              {'name': 'Windows', 'url': 'https://example.com/win.zip'},
            ],
          },
        },
      }),
    );

    expect(manifest.version, 'v1.0.0-build1');
    expect(RuntimePackageTarget.androidX86.id, 'android-x86_64');
    expect(RuntimePackageTarget.androidArm.architecture, 'arm64-v8a');
    expect(RuntimePackageTarget.windowsX64.fileName, endsWith('.zip'));
    expect(manifest.sha256For(RuntimePackageTarget.androidX86), sha256);
    expect(
      manifest
          .downloadsFor(RuntimePackageTarget.androidX86)
          .map((endpoint) => endpoint.sha256),
      everyElement(sha256),
    );
    expect(manifest.canDownload(RuntimePackageTarget.androidX86), isTrue);
    expect(manifest.canDownload(RuntimePackageTarget.androidArm), isFalse);
    expect(
      RuntimePackageReleaseManifest.fromJson(manifest.toJson()).toJson(),
      manifest.toJson(),
    );
  });

  test(
    'repository Runtime manifest hashes match every staged base package',
    () async {
      final manifest = RuntimePackageReleaseManifest.parse(
        File('resources/runtime/update.json').readAsStringSync(),
      );
      final runtimeVersion = RegExp(
        r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(File('runtime/src/pubspec.yaml').readAsStringSync());
      expect(runtimeVersion, isNotNull);
      expect(
        manifest.version,
        'v${runtimeVersion!.group(1)}-build${runtimeVersion.group(2)}',
      );

      const files = {
        RuntimePackageTarget.androidX86:
            'resources/runtime/playmesh-runtime-x86.apk',
        RuntimePackageTarget.androidArm:
            'resources/runtime/playmesh-runtime-arm.apk',
        RuntimePackageTarget.windowsX64:
            'resources/runtime/playmesh-runtime-win.zip',
      };
      for (final entry in files.entries) {
        final digest = await crypto.sha256
            .bind(File(entry.value).openRead())
            .first;
        final expectedSha256 = digest.toString();
        expect(manifest.sha256For(entry.key), expectedSha256);
        expect(
          manifest.downloadsFor(entry.key).map((endpoint) => endpoint.sha256),
          everyElement(expectedSha256),
        );
        expect(manifest.canDownload(entry.key), isTrue);
      }
    },
  );

  test('Runtime host stays aligned with the current App SDK menu contract', () {
    final ui =
        jsonDecode(
              File(
                'runtime/src/assets/runtime/platform-ui.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final locales = (ui['locales']! as List).cast<Map>();
    for (final locale in locales) {
      final messages = locale['messages']! as Map;
      for (final key in [
        'sidebar.join',
        'join.title',
        'join.empty',
        'join.scanning',
        'join.scan',
        'join.input',
        'join.action',
        'join.failed',
      ]) {
        expect(messages[key], isNotEmpty, reason: '${locale['locale']}: $key');
      }
    }

    final platformUi = File(
      'runtime/src/lib/runtime/runtime_platform_ui.dart',
    ).readAsStringSync();
    final appBridge = File(
      'runtime/src/lib/runtime/runtime_app_bridge.dart',
    ).readAsStringSync();
    expect(platformUi, contains("'join': showShareAction"));
    expect(appBridge, isNot(contains('showJoinAction:')));
    expect(
      appBridge,
      contains("'_playmeshFullscreen': await _readFullscreen()"),
    );
  });

  test('manifest enforces structure and platform-level SHA only', () {
    Map<String, Object?> validVariant() => {
      'sha256': sha256,
      'downloads': [
        {'name': 'Route', 'url': 'http://example.com/runtime.apk'},
      ],
    };

    Map<String, Object?> manifestWith(Object? x86) => {
      'version': '1.0.0',
      'platform': {
        'android': {'x86': x86, 'arm': validVariant()},
        'windows': validVariant(),
      },
    };

    expect(
      () => RuntimePackageReleaseManifest.fromJson({
        ...manifestWith(validVariant()),
        'unknown': true,
      }),
      throwsFormatException,
    );
    expect(
      () => RuntimePackageReleaseManifest.fromJson(
        manifestWith({'sha256': 'short', 'downloads': const []}),
      ),
      throwsFormatException,
    );
    expect(
      () => RuntimePackageReleaseManifest.fromJson(
        manifestWith({
          'sha256': sha256,
          'downloads': [
            {
              'name': 'Legacy',
              'url': 'http://example.com/a.apk',
              'sha256': sha256,
            },
          ],
        }),
      ),
      throwsFormatException,
    );
  });

  test('links have no protocol, credential or fragment policy', () {
    final manifest = RuntimePackageReleaseManifest.fromJson({
      'version': '1.0.0',
      'platform': {
        'android': {
          'x86': {
            'sha256': sha256,
            'downloads': [
              {
                'name': 'Unrestricted',
                'url': 'http://user:pass@example.com/a.apk#latest',
              },
            ],
          },
          'arm': {'sha256': sha256, 'downloads': const []},
        },
        'windows': {'sha256': sha256, 'downloads': const []},
      },
    });

    expect(
      manifest.downloadsFor(RuntimePackageTarget.androidX86).single.urlValue,
      'http://user:pass@example.com/a.apk#latest',
    );
  });

  test('App.json projection uses only export and accepts HTTP', () {
    final sources = RuntimePackageConfigSources.parse(
      jsonEncode([
        {
          'name': 'HTTP mirror',
          'app': 'https://example.com/app.json',
          'export': 'http://example.com/runtime.json',
        },
        {'name': 'App only', 'app': 'https://example.com/app-2.json'},
      ]),
    );

    expect(runtimePackageResourceKey, 'export');
    expect(sources.sources, hasLength(1));
    expect(
      sources.sources.single.url.toString(),
      'http://example.com/runtime.json',
    );
    expect(
      RuntimePackageConfigSources.parse(
        '[{"name":"App","app":"https://example.com/app.json"}]',
      ).configured,
      isFalse,
    );
  });
}
