import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/core/game_web/local_tunnel_gateway.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('分享网关只公开 App、Bucket、SDK 与受控入口资源', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-web-storage-');
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.test-game',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      coreEndpoint: Uri.parse('http://127.0.0.1:39001/'),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      gameName: '测试游戏',
      requiredCapabilities: const ['sensor.accelerometer'],
      controllerRequiredCapabilities: const ['sensor.gyroscope'],
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });
    final base = Uri.parse('http://127.0.0.1:${gateway.port}');
    final shareLinks = await gateway.shareLinks();
    expect(shareLinks, isNotEmpty);
    expect(
      shareLinks.every(
        (link) =>
            link.queryParameters['token'] == 'share-token' &&
            RegExp(
              r'^[A-Za-z0-9_-]{12}$',
            ).hasMatch(link.queryParameters['channelId'] ?? '') &&
            link.path == '/app/controller/index.html' &&
            link.queryParameters.length == 2 &&
            !link.hasFragment,
      ),
      isTrue,
    );

    final controller = await http.get(shareLinks.first);
    expect(controller.statusCode, HttpStatus.ok);
    expect(controller.body, contains('window.__PLAYMESH_BROWSER__'));
    expect(controller.body, contains('"gameName"'));
    expect(
      controller.body,
      contains('"requiredCapabilities":["sensor.gyroscope"]'),
    );
    expect(controller.body, contains('"availableCapabilities":[]'));
    expect(controller.body, contains('/playmesh/sdk/v1/playmesh.js'));
    expect(
      controller.body,
      isNot(contains('/playmesh/sdk/v1/playmesh-app.js')),
    );
    expect(controller.body, isNot(contains('joinEndpoint')));
    expect(controller.body, isNot(contains('storageEndpoint')));
    expect(controller.body, isNot(contains('nicknameEndpoint')));
    expect(controller.body, isNot(contains('"nickname":')));

    final appController = await http.get(
      shareLinks.first.replace(
        queryParameters: {
          ...shareLinks.first.queryParameters,
          'playmeshNickname': 'App 玩家',
          'playmeshApp': '1',
          'playmeshAppSdkUrl': 'http://127.0.0.1:45678/playmesh-app.js',
        },
      ),
    );
    expect(appController.statusCode, HttpStatus.ok);
    expect(appController.body, contains('"nickname":"App 玩家"'));
    expect(
      appController.body,
      contains('http://127.0.0.1:45678/playmesh-app.js'),
    );
    expect(
      appController.body,
      isNot(contains('/playmesh/sdk/v1/playmesh-app.js')),
    );
    expect(
      appController.body.indexOf('http://127.0.0.1:45678/playmesh-app.js'),
      lessThan(appController.body.indexOf('/playmesh/sdk/v1/playmesh.js')),
    );

    final relayEntry = await http.get(
      base.replace(
        path: '/playmesh/join',
        queryParameters: {'token': 'share-token'},
      ),
    );
    expect(relayEntry.statusCode, HttpStatus.notFound);

    for (final path in const [
      '/api/app-capabilities',
      '/api/join',
      '/api/storage',
      '/api/player/nickname',
    ]) {
      final response = await http.post(base.resolve(path), body: '{}');
      expect(response.statusCode, HttpStatus.notFound, reason: path);
    }

    final sdk = await http.get(base.resolve('/playmesh/sdk/v1/playmesh.js'));
    expect(sdk.statusCode, HttpStatus.ok);
    expect(sdk.body, contains('global.playmesh = playmesh'));
    expect(sdk.body, isNot(contains('/playmesh/developer/log')));

    final rejectedRemoteLog = await http.post(
      base.resolve('/playmesh/developer/log'),
      headers: const {'Content-Type': 'application/json'},
      body: '{}',
    );
    expect(rejectedRemoteLog.statusCode, HttpStatus.notFound);

    final appAsset = await http.get(base.resolve('/app/static/css/game.css'));
    expect(appAsset.statusCode, HttpStatus.ok);
    final legacyAsset = await http.get(
      base.resolve('/game/static/css/game.css'),
    );
    expect(legacyAsset.statusCode, HttpStatus.notFound);

    final rejectedUpload = await http.post(
      base.resolve('/bucket/replays?name=round.bin'),
      headers: const {'X-Playmesh-Share-Token': 'wrong-token'},
      body: <int>[1, 2, 3],
    );
    expect(rejectedUpload.statusCode, HttpStatus.forbidden);
    final upload = await http.post(
      base.resolve('/bucket/replays?name=round.bin'),
      headers: const {'X-Playmesh-Share-Token': 'share-token'},
      body: <int>[1, 2, 255, 4],
    );
    expect(upload.statusCode, HttpStatus.created);
    final uploadBody = jsonDecode(upload.body) as Map<String, Object?>;
    final uploadedUrl = uploadBody['url']! as String;
    expect(uploadedUrl, matches(RegExp(r'^/bucket/replays/[0-9]{13,}\.bin$')));
    final download = await http.get(base.resolve(uploadedUrl));
    expect(download.statusCode, HttpStatus.ok);
    expect(download.bodyBytes, <int>[1, 2, 255, 4]);
    expect(
      (await http.get(base.resolve('/bucket/replays'))).statusCode,
      HttpStatus.notFound,
    );

    final missing = await http.get(base.resolve('/not-found'));
    expect(missing.statusCode, HttpStatus.notFound);
  });

  test('局域网 App 通过受控 Upgrade 透明访问当前 Core', () async {
    final core = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final coreSubscription = core.listen((request) async {
      request.response.write('CORE_OK:${request.uri.path}');
      await request.response.close();
    });
    final root = await Directory.systemTemp.createTemp(
      'playmesh-web-core-tunnel-',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.core-tunnel',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      coreEndpoint: Uri(scheme: 'http', host: '127.0.0.1', port: core.port),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      storage: storage,
    );
    final coreGateway = await startLocalUpgradeTunnelGateway(
      targetBaseUri: Uri(scheme: 'http', host: '127.0.0.1', port: gateway.port),
      path: playmeshCoreTunnelPath,
      headers: const {playmeshShareTokenHeader: 'share-token'},
    );
    addTearDown(() async {
      await coreGateway.close();
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
      await coreSubscription.cancel();
      await core.close(force: true);
    });

    final response = await http
        .get(coreGateway.localBaseUri.resolve('/health'))
        .timeout(const Duration(seconds: 5));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, 'CORE_OK:/health');
  });

  test('普通多人多屏分享地址加载主 index 页面', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-web-multi-screen-',
    );
    final app = Directory('${root.path}${Platform.pathSeparator}app');
    final controller = Directory(
      '${app.path}${Platform.pathSeparator}controller',
    );
    await controller.create(recursive: true);
    await File('${app.path}${Platform.pathSeparator}index.html').writeAsString(
      '<!doctype html><html><head></head><body>MAIN_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh.js"></script></body></html>',
    );
    await File(
      '${controller.path}${Platform.pathSeparator}index.html',
    ).writeAsString(
      '<!doctype html><html><head></head><body>CONTROLLER_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.multi-screen',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath: 'unused-for-file-package',
      gameRootFilePath: root.path,
      multiplayer: true,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      coreEndpoint: Uri.parse('http://127.0.0.1:39001/'),
      joinCode: 'MULTI1',
      shareToken: 'share-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    final response = await http.get((await gateway.shareLinks()).first);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('MAIN_ENTRY'));
    expect(response.body, isNot(contains('CONTROLLER_ENTRY')));
    expect(response.body, contains('<base href="/app/">'));
    expect(response.body, contains('window.__PLAYMESH_BROWSER__'));
  });

  test('单机分享加载主 index 且不注入会话和 WebSocket 配置', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-web-solo-');
    final app = Directory('${root.path}${Platform.pathSeparator}app');
    await app.create(recursive: true);
    await File('${app.path}${Platform.pathSeparator}index.html').writeAsString(
      '<!doctype html><html><head></head><body>SOLO_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.solo',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath: 'unused-for-file-package',
      gameRootFilePath: root.path,
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      shareToken: 'solo-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    final links = await gateway.shareLinks();
    expect(links, isNotEmpty);
    expect(links.first.path, '/app/index.html');
    expect(
      links.first.queryParameters['channelId'],
      matches(RegExp(r'^[A-Za-z0-9_-]{12}$')),
    );
    final response = await http.get(links.first);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('SOLO_ENTRY'));
    expect(response.body, contains('<base href="/app/">'));
    expect(response.body, contains('"mode":"solo"'));
    expect(response.body, isNot(contains('joinEndpoint')));
    expect(response.body, isNot(contains('coreBase')));
    expect(response.body, isNot(contains('storageEndpoint')));
    expect(response.body, isNot(contains('nicknameEndpoint')));
  });

  test('错误或缺失的分享 token 会被拒绝', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-web-storage-');
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.test-game',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath:
          'assets/playmesh-library/public/developer/templates/default-game/package',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      coreEndpoint: Uri.parse('http://127.0.0.1:39001/'),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    final invitation = (await gateway.shareLinks()).first;
    final response = await http.get(
      Uri(
        scheme: invitation.scheme,
        host: invitation.host,
        port: invitation.port,
        path: invitation.path,
      ),
    );
    expect(response.statusCode, HttpStatus.forbidden);

    final storageResponse = await http.post(
      Uri.parse('http://127.0.0.1:${gateway.port}/api/storage'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'command': 'storage.get',
        'bucket': 'save',
        'key': 'score',
        'shareToken': 'wrong-token',
      }),
    );
    expect(storageResponse.statusCode, HttpStatus.notFound);
  });

  test('自定义嵌套首页按入口目录注入 base 路径', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-web-custom-entry-',
    );
    final entry = File(
      '${root.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}play${Platform.pathSeparator}main.html',
    );
    await entry.parent.create(recursive: true);
    await entry.writeAsString(
      '<!doctype html><html><head></head><body>CUSTOM_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.custom-entry',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      gameRootAssetPath: 'unused-for-file-package',
      gameRootFilePath: root.path,
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      gameEntryPath: 'app/play/main.html',
      shareToken: 'custom-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    final invitation = (await gateway.shareLinks()).first;
    expect(invitation.path, '/app/play/main.html');
    final response = await http.get(invitation);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('CUSTOM_ENTRY'));
    expect(response.body, contains('<base href="/app/play/">'));
  });
}
