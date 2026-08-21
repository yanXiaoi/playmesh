import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_external_navigation.dart';

void main() {
  group('Playmesh developer external navigation host', () {
    test('parses the native-host envelope for an HTTPS URL', () {
      final uri = parsePlaymeshExternalNavigationMessage(
        jsonEncode({
          '__playmeshExternalNavigation': {
            'href': 'https://wiki.gdevelop.io/gdevelop5/',
          },
        }),
      );

      expect(uri, Uri.parse('https://wiki.gdevelop.io/gdevelop5/'));
    });

    test('rejects malformed, relative, and active-content URLs', () {
      expect(parsePlaymeshExternalNavigationMessage('not json'), isNull);
      expect(
        parsePlaymeshExternalNavigationMessage(
          jsonEncode({
            '__playmeshExternalNavigation': {'href': '/relative'},
          }),
        ),
        isNull,
      );
      expect(
        parsePlaymeshExternalNavigationMessage(
          jsonEncode({
            '__playmeshExternalNavigation': {'href': 'javascript:alert(1)'},
          }),
        ),
        isNull,
      );
    });

    test('keeps same-origin workspace routing in the embedded WebView', () {
      final workspace = Uri.parse('http://127.0.0.1:16666/dev/token/gdevelop/');

      expect(
        shouldOpenDeveloperNavigationExternally(
          workspaceUri: workspace,
          requestedUri: workspace.resolve('static/js/main.js'),
        ),
        isFalse,
      );
      expect(
        shouldOpenDeveloperNavigationExternally(
          workspaceUri: workspace,
          requestedUri: Uri.parse('https://gdevelop.io/docs'),
        ),
        isTrue,
      );
    });

    test('opens safe links through the supplied system launcher', () async {
      Uri? opened;
      final result = await openDeveloperExternalUri(
        Uri.parse('https://gdevelop.io/'),
        launcher: (uri) async {
          opened = uri;
          return true;
        },
      );

      expect(result, isTrue);
      expect(opened, Uri.parse('https://gdevelop.io/'));
    });

    test('host script supports both native WebView bridge families', () {
      expect(
        playmeshExternalNavigationScript,
        contains('global.PlaymeshExternalNavigation'),
      );
      expect(
        playmeshExternalNavigationScript,
        contains('global.chrome.webview'),
      );
      expect(
        playmeshExternalNavigationScript,
        contains('__playmeshExternalNavigationInstalled'),
      );
    });
  });
}
