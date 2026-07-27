import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/local_app_sdk_server.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';

void main() {
  test('加入方 App 只在本地回环地址提供自己的 App SDK', () async {
    final server = await startLocalAppSdkServer();
    addTearDown(server.close);

    expect(server.scriptUri.scheme, 'http');
    expect(server.scriptUri.host, '127.0.0.1');
    expect(server.scriptUri.path, '/playmesh-app.js');

    final response = await http.get(server.scriptUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, SdkFeatureRegistry.sdkFile('playmesh-app.js'));
    expect(response.headers['cache-control'], 'no-store');
    expect(
      (await http.get(server.scriptUri.resolve('/playmesh.js'))).statusCode,
      HttpStatus.notFound,
    );
  });

  test('App SDK 版本选择只通过 Dart feature 注册表', () async {
    final server = await startLocalAppSdkServer();
    addTearDown(server.close);

    final compatible = await http.get(
      server.scriptUri.replace(queryParameters: {'version': '1.0.0'}),
    );
    final future = await http.get(
      server.scriptUri.replace(queryParameters: {'version': '9.0.0'}),
    );

    expect(compatible.statusCode, HttpStatus.ok);
    expect(
      compatible.body,
      SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '1.0.0'),
    );
    expect(future.statusCode, HttpStatus.badRequest);
    expect(future.body, contains('不支持'));
  });
}
