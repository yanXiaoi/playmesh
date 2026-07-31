import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_package/game_asset_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('统一开发资源源转发 CLI 代理、保留平台路由并随网关停止', () async {
    final credential = List<String>.filled(40, 'd').join();
    final forwardedPaths = <String>[];
    final forwardedCredentials = <String?>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      forwardedPaths.add(request.uri.toString());
      forwardedCredentials.add(
        request.headers.value(playmeshDevelopmentCredentialHeader),
      );
      if (request.headers.value(playmeshDevelopmentCredentialHeader) !=
          credential) {
        request.response.statusCode = HttpStatus.forbidden;
      } else if (request.uri.path == '/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><head></head><body>DEVELOPMENT</body></html>',
        );
      } else if (request.uri.path == '/assets/runtime.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('development-resource-ok');
      } else if (request.uri.toString() ==
          '/scripting/engine/external/%2540cocos/box2d.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('cocos-virtual-resource-ok');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final source = DevelopmentGameWebResourceSource(
      baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
      credential: credential,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    final gateway = await startGameAssetGateway(
      source: source,
      entryPath: 'index.html',
      gameSdkVersion: '4.0.0',
      appSdkVersion: '3.2.0',
    );

    try {
      final entry = await http.get(gateway.entryUri);
      final script = await http.get(
        gateway.entryUri.resolve('/assets/runtime.js?v=1'),
      );
      final cocosVirtualResource = await http.get(
        Uri.parse(
          '${gateway.entryUri.origin}'
          '/scripting/engine/external/%2540cocos/box2d.js',
        ),
      );
      final platform = await http.get(
        gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-main.js'),
      );
      final bucket = await http.get(
        gateway.entryUri.resolve('/bucket/private'),
      );

      expect(entry.statusCode, HttpStatus.ok);
      expect(entry.body, contains('DEVELOPMENT'));
      expect(script.statusCode, HttpStatus.ok);
      expect(script.body, 'development-resource-ok');
      expect(cocosVirtualResource.statusCode, HttpStatus.ok);
      expect(cocosVirtualResource.body, 'cocos-virtual-resource-ok');
      expect(platform.statusCode, HttpStatus.ok);
      expect(bucket.statusCode, HttpStatus.notFound);
      expect(forwardedPaths, [
        '/index.html',
        '/assets/runtime.js?v=1',
        '/scripting/engine/external/%2540cocos/box2d.js',
      ]);
      expect(forwardedCredentials, everyElement(credential));

      final closedEntryUri = gateway.entryUri;
      await gateway.close();
      await expectLater(http.get(closedEntryUri), throwsA(anything));
    } finally {
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    }
  });
}
