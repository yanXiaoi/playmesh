import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_package/game_asset_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('只映射当前游戏 app 和平台公共资源', () async {
    final gateway = await startGameAssetGateway(
      gameRootAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package',
      entryAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package/app/index.html',
    );
    addTearDown(gateway.close);

    final entry = await http.get(gateway.entryUri);
    expect(gateway.entryUri.path, '/app/index.html');
    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-app.js'));
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh.js'));

    final sdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh.js'),
    );
    expect(sdk.statusCode, HttpStatus.ok);
    expect(sdk.body, isNot(contains('/playmesh/developer/log')));
    expect(sdk.body, contains('Playmesh Game SDK 注入成功'));

    final appSdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-app.js'),
    );
    expect(appSdk.statusCode, HttpStatus.ok);
    expect(appSdk.body, contains('global.playmeshApp = playmeshApp'));
    expect(appSdk.body, contains('Playmesh App SDK 注入成功'));

    final data = await http.get(gateway.entryUri.resolve('/data/save.json'));
    expect(data.statusCode, HttpStatus.notFound);

    final other = await http.get(
      gateway.entryUri.resolve('/assets/other-game/index.html'),
    );
    expect(other.statusCode, HttpStatus.notFound);

    final legacy = await http.get(gateway.entryUri.resolve('/game/index.html'));
    expect(legacy.statusCode, HttpStatus.notFound);
  });

  test('资源网关不接收客户端 console 日志', () async {
    final gateway = await startGameAssetGateway(
      gameRootAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package',
      entryAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package/app/index.html',
    );
    addTearDown(gateway.close);
    final response = await http.post(
      gateway.entryUri.resolve('/playmesh/developer/log'),
      headers: const {'Content-Type': 'application/json'},
      body: '{}',
    );

    expect(response.statusCode, HttpStatus.methodNotAllowed);
  });

  test('文件项目入口缺少 SDK 标签时由 App WebView 网关补齐双 SDK', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-file-gateway-',
    );
    final app = Directory('${root.path}${Platform.pathSeparator}app');
    await app.create(recursive: true);
    await File('${app.path}${Platform.pathSeparator}index.html').writeAsString(
      '<!doctype html><html><head></head><body>GAME</body></html>',
    );
    addTearDown(() => root.delete(recursive: true));

    final gateway = await startGameAssetGateway(
      gameRootFilePath: root.path,
      entryAssetPath: 'app/index.html',
    );
    addTearDown(gateway.close);

    final entry = await http.get(gateway.entryUri);
    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-app.js'));
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh.js'));
    expect(
      entry.body.indexOf('/playmesh/sdk/v1/playmesh-app.js'),
      lessThan(entry.body.indexOf('/playmesh/sdk/v1/playmesh.js')),
    );

    final sdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh.js'),
    );
    expect(sdk.statusCode, HttpStatus.ok);
    expect(sdk.body, contains('global.playmesh = playmesh'));
  });
}
