import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/core/game_web/local_tunnel_gateway.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';
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
    final packageRoot = await _createInstalledPackageRoot();
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: packageRoot.path),
      gameId: 'com.playmesh.test-game',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      gameEntryPath: 'index.html',
      controllerEntryPath: 'controller/index.html',
      coreEndpoint: Uri.parse('http://127.0.0.1:39001/'),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      gameName: '测试游戏',
      tags: const ['派对', '本地多人'],
      gameSdkVersion: '4.0.0',
      appSdkVersion: '3.2.0',
      requiredCapabilities: const ['media.camera'],
      controllerRequiredCapabilities: const ['media.microphone'],
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
      await packageRoot.delete(recursive: true);
    });
    final base = Uri.parse('http://127.0.0.1:${gateway.port}');
    final shareLinks = await gateway.shareLinks();
    expect(shareLinks, isNotEmpty);
    expect(
      shareLinks.every(
        (link) =>
            link.path == playmeshGameInvitationPath &&
            !link.hasQuery &&
            RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(
              Uri.splitQueryString(
                    link.fragment,
                  )[playmeshGameInvitationTokenParameter] ??
                  '',
            ),
      ),
      isTrue,
    );

    final opened = await _openInvitation(shareLinks.first);
    final controller = opened.entry;
    expect(opened.landing.body, contains('正在进入游戏'));
    expect(opened.entryUri.path, '/controller/index.html');
    expect(opened.entryUri.hasQuery, isFalse);
    expect(controller.statusCode, HttpStatus.ok);
    expect(controller.body, contains('window.__PLAYMESH_BROWSER__'));
    expect(
      controller.body.indexOf(
        '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>',
      ),
      lessThan(
        controller.body.indexOf(
          '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>',
        ),
      ),
    );
    expect(controller.body, contains('"gameId":"com.playmesh.test-game"'));
    expect(controller.body, contains('"gameName"'));
    expect(controller.body, contains('"_playmeshPlatformUi"'));
    expect(controller.body, contains('"fallbackLocale":"zh-CN"'));
    expect(controller.body, contains('"locale":"zh-CN"'));
    expect(controller.body, contains('"locale":"en-US"'));
    expect(controller.body, contains('"sidebar.title":"游戏菜单"'));
    expect(controller.body, contains('"sidebar.title":"Game menu"'));
    expect(controller.body, isNot(contains('"home.title"')));
    expect(
      controller.body,
      contains('"requiredCapabilities":["media.microphone"]'),
    );
    expect(controller.body, contains('"tags":["派对","本地多人"]'));
    expect(controller.body, contains('"availableCapabilities":[]'));
    expect(controller.body, contains('/playmesh/sdk/v1/playmesh-main.js'));
    expect(
      controller.body.indexOf('/playmesh/sdk/v1/playmesh-app.js'),
      lessThan(controller.body.indexOf('/playmesh/sdk/v1/playmesh-main.js')),
    );
    expect(controller.body, isNot(contains('joinEndpoint')));
    expect(controller.body, isNot(contains('storageEndpoint')));
    expect(controller.body, isNot(contains('nicknameEndpoint')));
    expect(controller.body, isNot(contains('"nickname":')));

    final spoofedAppController = await http.get(
      opened.entryUri.replace(
        query:
            'playmeshNickname=App'
            '&playmeshApp=1'
            '&playmeshAppSdkUrl=http%3A%2F%2F127.0.0.1%3A45678'
            '%2Fplaymesh-app.js',
      ),
      headers: {'Cookie': opened.cookie},
    );
    expect(spoofedAppController.statusCode, HttpStatus.forbidden);

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

    final sdk = await http.get(
      base.resolve('/playmesh/sdk/v1/playmesh-main.js'),
    );
    expect(sdk.statusCode, HttpStatus.ok);
    expect(
      sdk.body,
      SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '4.0.0'),
    );
    expect(sdk.body, contains('global.playmesh = Object.freeze'));
    expect(sdk.body, isNot(contains('/playmesh/developer/log')));

    final rejectedRemoteLog = await http.post(
      base.resolve('/playmesh/developer/log'),
      headers: const {'Content-Type': 'application/json'},
      body: '{}',
    );
    expect(rejectedRemoteLog.statusCode, HttpStatus.notFound);

    final appAsset = await http.get(base.resolve('/static/css/game.css'));
    expect(appAsset.statusCode, HttpStatus.ok);
    final noImplicitAppAlias = await http.get(
      base.resolve('/app/static/css/game.css'),
    );
    expect(noImplicitAppAlias.statusCode, HttpStatus.notFound);
    final reservedCaseVariant = await http.get(
      base.resolve('/PLAYMESH/sdk/v1/playmesh-main.js'),
    );
    expect(reservedCaseVariant.statusCode, HttpStatus.notFound);

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
    final packageRoot = await _createInstalledPackageRoot();
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: packageRoot.path),
      gameId: 'com.playmesh.core-tunnel',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      gameEntryPath: 'index.html',
      controllerEntryPath: 'controller/index.html',
      coreEndpoint: Uri(scheme: 'http', host: '127.0.0.1', port: core.port),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      storage: storage,
    );
    final coreGateway = await startLocalUpgradeTunnelGateway(
      targetBaseUri: Uri(scheme: 'http', host: '127.0.0.1', port: gateway.port),
      path: playmeshCoreTunnelPath,
      headers: {
        playmeshShareTokenHeader: parsePlaymeshInvitationFragment(
          (await gateway.shareLinks()).first.fragment,
        )[playmeshGameInvitationTokenParameter]!,
      },
    );
    addTearDown(() async {
      await coreGateway.close();
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
      await packageRoot.delete(recursive: true);
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
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script></body></html>',
    );
    await File(
      '${controller.path}${Platform.pathSeparator}index.html',
    ).writeAsString(
      '<!doctype html><html><head></head><body>CONTROLLER_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.multi-screen',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      gameId: 'com.example.multi-screen',
      multiplayer: true,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      gameEntryPath: 'index.html',
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

    final response = (await _openInvitation(
      (await gateway.shareLinks()).first,
    )).entry;

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('MAIN_ENTRY'));
    expect(response.body, isNot(contains('CONTROLLER_ENTRY')));
    expect(response.body, contains('<base href="/">'));
    expect(response.body, contains('window.__PLAYMESH_BROWSER__'));
    expect(
      response.body,
      contains('<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'),
    );
  });

  test('单机分享加载主 index 且不注入会话和 WebSocket 配置', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-web-solo-');
    final app = Directory('${root.path}${Platform.pathSeparator}app');
    await app.create(recursive: true);
    await File('${app.path}${Platform.pathSeparator}index.html').writeAsString(
      '<!doctype html><html><head></head><body>SOLO_ENTRY'
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.solo',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      gameId: 'com.example.solo',
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      gameEntryPath: 'index.html',
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
    expect(links.first.path, playmeshGameInvitationPath);
    expect(links.first.hasQuery, isFalse);
    final response = (await _openInvitation(links.first)).entry;

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('SOLO_ENTRY'));
    expect(response.body, contains('<base href="/">'));
    expect(response.body, contains('"mode":"solo"'));
    expect(
      response.body,
      contains('<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'),
    );
    expect(response.body, isNot(contains('joinEndpoint')));
    expect(response.body, isNot(contains('coreBase')));
    expect(response.body, isNot(contains('storageEndpoint')));
    expect(response.body, isNot(contains('nicknameEndpoint')));
  });

  test('缺失浏览器会话或错误邀请凭据会被拒绝', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-web-storage-');
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.test-game',
      libraryRoot: root,
    );
    final packageRoot = await _createInstalledPackageRoot();
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: packageRoot.path),
      gameId: 'com.playmesh.test-game',
      multiplayer: true,
      displayMode: 'single_screen_multiplayer',
      orientation: GameOrientation.landscape,
      controllerOrientation: GameOrientation.portrait,
      gameEntryPath: 'index.html',
      controllerEntryPath: 'controller/index.html',
      coreEndpoint: Uri.parse('http://127.0.0.1:39001/'),
      joinCode: 'ABC123',
      shareToken: 'share-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
      await packageRoot.delete(recursive: true);
    });

    final invitation = (await gateway.shareLinks()).first;
    final response = await http.get(
      Uri(
        scheme: invitation.scheme,
        host: invitation.host,
        port: invitation.port,
        path: '/controller/index.html',
      ),
    );
    expect(response.statusCode, HttpStatus.forbidden);

    final rejectedExchange = await http.post(
      invitation.replace(fragment: null),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({playmeshGameInvitationTokenParameter: 'wrong-token'}),
    );
    expect(rejectedExchange.statusCode, HttpStatus.forbidden);

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

  test('自定义嵌套首页保留重复查询参数并按入口目录注入 base 路径', () async {
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
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script></body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.custom-entry',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      gameId: 'com.example.custom-entry',
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      // 分享握手独立于入口查询串，所有 manifest 参数都按原语义保留。
      gameEntryPath:
          'play/main.html?scene=current_scene&mode=touch&other=1'
          '&mode=keyboard&raw=%2f&blob=%FF'
          '&channelId=manifest-channel&token=manifest-token',
      shareToken: 'custom-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
    });

    final invitation = (await gateway.shareLinks()).first;
    expect(invitation.path, playmeshGameInvitationPath);
    expect(invitation.hasQuery, isFalse);
    final opened = await _openInvitation(invitation);
    expect(opened.entryUri.path, '/play/main.html');
    expect(_rawQueryValues(opened.entryUri, 'scene'), ['current_scene']);
    expect(_rawQueryValues(opened.entryUri, 'mode'), ['touch', 'keyboard']);
    expect(_rawQueryValues(opened.entryUri, 'token'), ['manifest-token']);
    expect(_rawQueryValues(opened.entryUri, 'channelId'), ['manifest-channel']);
    expect(
      opened.entryUri.query,
      'scene=current_scene&mode=touch&other=1&mode=keyboard'
      '&raw=%2F&blob=%FF'
      '&channelId=manifest-channel&token=manifest-token',
    );
    final response = opened.entry;

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('CUSTOM_ENTRY'));
    expect(response.body, contains('<base href="/play/">'));
  });

  test('开发态浏览器分享复用实时资源源且不向上游转发平台目录', () async {
    final credential = List<String>.filled(40, 's').join();
    final forwardedRequests = <String>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      forwardedRequests.add(request.uri.toString());
      if (request.headers.value(playmeshDevelopmentCredentialHeader) !=
          credential) {
        request.response.statusCode = HttpStatus.forbidden;
      } else if (request.uri.path == '/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><head></head><body>LIVE_SHARE'
          '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>'
          '</body></html>',
        );
      } else if (request.uri.path == '/assets/hot.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('hot-resource-ok');
      } else if (request.uri.toString() ==
          '/scripting/engine/external/%2540cocos/box2d.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('cocos-virtual-resource-ok');
      } else if (request.uri.path == '/app/secret.js' ||
          request.uri.path == '/app/playmesh/user.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('window.userAppRoute = true;');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final root = await Directory.systemTemp.createTemp(
      'playmesh-web-development-share-',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.development-share',
      libraryRoot: root,
    );
    final gateway = await startGameWebGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      gameId: 'com.example.development-share',
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      gameEntryPath: 'index.html',
      shareToken: 'development-share-token',
      storage: storage,
    );
    addTearDown(() async {
      await gateway.close();
      await storage.close();
      await root.delete(recursive: true);
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    final invitation = (await gateway.shareLinks()).first;
    final opened = await _openInvitation(invitation);
    final entry = opened.entry;
    final script = await http.get(invitation.resolve('/assets/hot.js?v=1'));
    final cocosVirtualResource = await http.get(
      Uri.parse(
        '${invitation.origin}'
        '/scripting/engine/external/%2540cocos/box2d.js',
      ),
    );
    final platform = await http.get(
      invitation.resolve('/playmesh/unavailable.js'),
    );
    final bucket = await http.get(invitation.resolve('/bucket/private'));
    final userApp = await http.get(invitation.resolve('/app/secret.js'));
    final nestedPlatformName = await http.get(
      invitation.resolve('/app/playmesh/user.js'),
    );

    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('LIVE_SHARE'));
    expect(entry.body, contains('window.__PLAYMESH_BROWSER__'));
    expect(script.statusCode, HttpStatus.ok);
    expect(script.body, 'hot-resource-ok');
    expect(cocosVirtualResource.statusCode, HttpStatus.ok);
    expect(cocosVirtualResource.body, 'cocos-virtual-resource-ok');
    expect(platform.statusCode, HttpStatus.notFound);
    expect(bucket.statusCode, HttpStatus.notFound);
    expect(userApp.statusCode, HttpStatus.ok);
    expect(nestedPlatformName.statusCode, HttpStatus.ok);
    expect(forwardedRequests, [
      '/index.html',
      '/assets/hot.js?v=1',
      '/scripting/engine/external/%2540cocos/box2d.js',
      '/app/secret.js',
      '/app/playmesh/user.js',
    ]);
  });

  test('分享网关允许用户 app 目录入口声明', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-web-user-app-entry-',
    );
    final userApp = Directory(
      '${root.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}app',
    );
    await userApp.create(recursive: true);
    await File(
      '${userApp.path}${Platform.pathSeparator}index.html',
    ).writeAsString(
      '<!doctype html><html><head></head><body>USER_APP_ENTRY</body></html>',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.example.user-app-entry',
      libraryRoot: root,
    );
    addTearDown(() async {
      await storage.close();
      await root.delete(recursive: true);
    });

    final gateway = await startGameWebGateway(
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      gameId: 'com.example.user-app-entry',
      multiplayer: false,
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      gameEntryPath: 'app/index.html',
      shareToken: 'user-app-token',
      storage: storage,
    );
    addTearDown(gateway.close);

    final invitation = (await gateway.shareLinks()).first;
    expect(invitation.path, playmeshGameInvitationPath);
    final opened = await _openInvitation(invitation);
    expect(opened.entryUri.path, '/app/index.html');
    final response = opened.entry;
    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, contains('USER_APP_ENTRY'));
  });
}

final class _OpenedInvitation {
  const _OpenedInvitation({
    required this.landing,
    required this.entryUri,
    required this.entry,
    required this.cookie,
  });

  final http.Response landing;
  final Uri entryUri;
  final http.Response entry;
  final String cookie;
}

Future<_OpenedInvitation> _openInvitation(Uri invitation) async {
  final fragment = Uri.splitQueryString(invitation.fragment);
  final inviteToken = fragment[playmeshGameInvitationTokenParameter];
  if (fragment.length != 1 || inviteToken == null || inviteToken.isEmpty) {
    throw StateError('测试邀请缺少 inviteToken');
  }
  final endpoint = invitation.replace(fragment: null);
  final landing = await http.get(endpoint);
  final exchange = await http.post(
    endpoint,
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({playmeshGameInvitationTokenParameter: inviteToken}),
  );
  if (exchange.statusCode != HttpStatus.ok) {
    throw StateError('邀请交换失败: ${exchange.statusCode} ${exchange.body}');
  }
  final cookieHeader = exchange.headers['set-cookie'];
  if (cookieHeader == null || cookieHeader.isEmpty) {
    throw StateError('邀请交换没有设置 Cookie');
  }
  final cookie = cookieHeader.split(';').first;
  final payload = jsonDecode(exchange.body) as Map<String, Object?>;
  final entryUri = endpoint.resolve(payload['entry']! as String);
  final entry = await http.get(entryUri, headers: {'Cookie': cookie});
  return _OpenedInvitation(
    landing: landing,
    entryUri: entryUri,
    entry: entry,
    cookie: cookie,
  );
}

List<String> _rawQueryValues(Uri uri, String expectedName) {
  final values = <String>[];
  for (final segment in uri.query.split('&')) {
    final separator = segment.indexOf('=');
    final encodedName = separator < 0
        ? segment
        : segment.substring(0, separator);
    final encodedValue = separator < 0 ? '' : segment.substring(separator + 1);
    try {
      if (Uri.decodeQueryComponent(encodedName) == expectedName) {
        values.add(Uri.decodeQueryComponent(encodedValue));
      }
    } on FormatException {
      // 非目标参数允许保留不透明的百分号字节。
    }
  }
  return values;
}

Future<Directory> _createInstalledPackageRoot() async {
  final root = await Directory.systemTemp.createTemp(
    'playmesh-installed-share-package-',
  );
  final app = Directory('${root.path}${Platform.pathSeparator}app');
  final controller = Directory(
    '${app.path}${Platform.pathSeparator}controller',
  );
  final styles = Directory(
    '${app.path}${Platform.pathSeparator}static'
    '${Platform.pathSeparator}css',
  );
  await controller.create(recursive: true);
  await styles.create(recursive: true);
  await File('${app.path}${Platform.pathSeparator}index.html').writeAsString(
    '<!doctype html><html><head></head><body>GAME'
    '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>'
    '</body></html>',
  );
  await File(
    '${controller.path}${Platform.pathSeparator}index.html',
  ).writeAsString(
    '<!doctype html><html><head></head><body>CONTROLLER'
    '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>'
    '</body></html>',
  );
  await File(
    '${styles.path}${Platform.pathSeparator}game.css',
  ).writeAsString('body { color: white; }');
  return root;
}
