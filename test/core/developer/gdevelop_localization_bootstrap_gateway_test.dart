import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'GDevelop index localization bootstrap fails open and is never cached',
    () async {
      final port = await _freePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'bootstrap-fail-open-token-012345',
        path: 'bootstrapfailopen',
        gdevelopWebIdeSource: const _IndexSource(),
        localizationBridge: DeveloperWorkspaceLocalizationBridge(
          current: () => throw StateError('app_localization_not_ready'),
          resolve: (_) => throw StateError('not used'),
          useLocale: (_) async {},
          useTheme: (_) async {},
        ),
      );
      addTearDown(gateway.close);

      final response = await http.get(
        Uri.parse('http://127.0.0.1:$port/dev/bootstrapfailopen/gdevelop/'),
        headers: const {
          HttpHeaders.authorizationHeader:
              'Bearer bootstrap-fail-open-token-012345',
        },
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('<script src="bundle.js"></script>'));
      expect(
        response.body,
        contains('__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__'),
      );
      expect(response.body, contains(r'"enabled":true'));
      expect(
        response.body,
        isNot(contains('__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__')),
      );
      expect(
        response.headers['cache-control'],
        'no-store, no-cache, must-revalidate',
      );
    },
  );

  test(
    'GDevelop localization bootstrap filters and escapes inline JSON',
    () async {
      final port = await _freePort();
      final snapshot = DeveloperWorkspaceLocalization(
        localeId: 'zh-CN',
        localeMode: 'fixed',
        defaultLocale: 'zh-CN',
        allowLocaleSwitch: true,
        themeMode: 'dark',
        effectiveTheme: 'dark',
        allowThemeSwitch: true,
        locales: const [DeveloperWorkspaceLocale(id: 'zh-CN', label: '简体中文')],
        messages: const {
          'workspace.gdevelop_ai.escape':
              '</script><script>alert(1)</script>&\u2028\u2029',
          'workspace.not_gdevelop': 'must not enter bootstrap',
        },
      );
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'bootstrap-safe-json-token-012345',
        path: 'bootstrapsafejson',
        gdevelopWebIdeSource: const _IndexSource(
          '<!doctype html><html><head><script src="bundle.js"></script>'
          '</head><body></body></html>',
        ),
        localizationBridge: DeveloperWorkspaceLocalizationBridge(
          current: () => snapshot,
          resolve: (_) => snapshot,
          useLocale: (_) async {},
          useTheme: (_) async {},
        ),
      );
      addTearDown(gateway.close);

      final response = await http.get(
        Uri.parse('http://127.0.0.1:$port/dev/bootstrapsafejson/gdevelop/'),
        headers: const {
          HttpHeaders.authorizationHeader:
              'Bearer bootstrap-safe-json-token-012345',
        },
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.body.indexOf('__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__'),
        lessThan(response.body.indexOf('bundle.js')),
      );
      expect(response.body, contains(r'\u003c/script\u003e'));
      expect(response.body, contains(r'\u0026'));
      expect(response.body, contains(r'\u2028\u2029'));
      expect(response.body, isNot(contains('</script><script>alert(1)')));
      expect(response.body, isNot(contains('workspace.not_gdevelop')));
      expect(
        response.body,
        contains('__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__'),
      );
      expect(
        response.headers['cache-control'],
        'no-store, no-cache, must-revalidate',
      );
    },
  );
}

class _IndexSource implements GDevelopWebIdeSource {
  const _IndexSource([
    this.html = '<!doctype html><script src="bundle.js"></script>',
  ]);

  final String html;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Uint8List?> read(String relativePath) async =>
      relativePath == 'index.html'
      ? Uint8List.fromList(utf8.encode(html))
      : null;
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
