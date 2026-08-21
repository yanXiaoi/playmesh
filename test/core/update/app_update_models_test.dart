import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/update/app_update_models.dart';

void main() {
  test('parses release identity and platform download endpoints strictly', () {
    final manifest = AppUpdateManifest.parse('''
      {
        "version": "4.3.0",
        "releaseNotes": "新增检查更新功能",
        "windows": {
          "downloads": [
            {"name": "GitHub", "url": "https://example.com/playmesh.exe"}
          ]
        },
        "android": {"downloads": []}
      }
    ''');

    expect(manifest.version.toString(), '4.3.0');
    expect(manifest.releaseNotes, '新增检查更新功能');
    expect(manifest.platforms['windows']!.endpoints.single.name, 'GitHub');
    expect(manifest.platforms['android']!.endpoints, isEmpty);
  });

  test('rejects unknown fields but accepts HTTP download URLs', () {
    expect(
      () => AppUpdateManifest.parse('''
          {
            "version": "4.3.0",
            "releaseNotes": "说明",
            "windows": {"downloads": []},
            "install": true
          }
        '''),
      throwsFormatException,
    );
    final httpManifest = AppUpdateManifest.parse('''
        {
          "version": "4.3.0",
          "releaseNotes": "说明",
          "windows": {
            "downloads": [
              {"name": "HTTP", "url": "http://example.com/playmesh.exe"}
            ]
          }
        }
      ''');
    expect(
      httpManifest.platforms['windows']!.endpoints.single.url.toString(),
      'http://example.com/playmesh.exe',
    );
  });
}
