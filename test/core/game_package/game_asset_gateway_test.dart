import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_package/game_asset_gateway.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';

import '../storage/standard_json_bucket_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('只映射当前游戏 app 和平台公共资源', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-bucket-gateway-',
    );
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.gateway',
      libraryRoot: root,
    );
    final packageRoot = await _createInstalledPackageRoot();
    addTearDown(() async {
      await storage.close();
      await root.delete(recursive: true);
      await packageRoot.delete(recursive: true);
    });
    final gateway = await startGameAssetGateway(
      source: InstalledGameWebResourceSource(packageRootPath: packageRoot.path),
      entryPath: 'index.html',
      gameSdkVersion: '4.1.0',
      appSdkVersion: '3.3.0',
      config: const {
        'webRuntime': {'multithreading': true},
      },
      storage: storage,
    );
    addTearDown(gateway.close);

    final entry = await http.get(gateway.entryUri);
    expect(gateway.entryUri.path, '/index.html');
    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-app.js'));
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-main.js'));
    _expectGameWebViewIsolationHeaders(entry);

    final sdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-main.js'),
    );
    expect(sdk.statusCode, HttpStatus.ok);
    _expectGameWebViewIsolationHeaders(sdk);
    expect(
      sdk.body,
      SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '4.1.0'),
    );
    expect(sdk.body, isNot(contains('/playmesh/developer/log')));
    expect(sdk.body, contains('Playmesh Game SDK 注入成功'));

    final appSdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-app.js'),
    );
    expect(appSdk.statusCode, HttpStatus.ok);
    expect(
      appSdk.body,
      SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '3.3.0'),
    );
    expect(appSdk.body, contains('Symbol.for("playmesh.app.internal.v1")'));
    expect(appSdk.body, isNot(contains('global.playmesh =')));
    expect(appSdk.body, contains('publicApi: publicAppApi'));
    expect(appSdk.body, isNot(contains('global.playmeshApp')));
    expect(appSdk.body, contains('Playmesh App SDK 注入成功'));

    final data = await http.get(gateway.entryUri.resolve('/data/save.json'));
    expect(data.statusCode, HttpStatus.notFound);
    _expectGameWebViewIsolationHeaders(data);

    await storage.setData('save', 'secret', 42);
    await storage.flushAll();
    final upload = await http.post(
      gateway.entryUri.resolve('/bucket/media?name=frame.bin'),
      body: <int>[0, 1, 255, 7],
    );
    expect(upload.statusCode, HttpStatus.created);
    final uploadedUrl =
        (jsonDecode(upload.body) as Map<String, Object?>)['url']! as String;
    final binary = await http.get(gateway.entryUri.resolve(uploadedUrl));
    expect(binary.statusCode, HttpStatus.ok);
    expect(binary.bodyBytes, <int>[0, 1, 255, 7]);

    final standardInitial = await sendStandardJsonBucketRequest(
      baseUri: gateway.entryUri,
      requestId: 'asset-authority-get-initial-0001',
      gameId: storage.gameId,
      operation: 'get',
      bucket: 'save',
      key: 'checkpoint',
    );
    expect(standardInitial.statusCode, HttpStatus.ok);
    final standardSet = await sendStandardJsonBucketRequest(
      baseUri: gateway.entryUri,
      requestId: 'asset-authority-set-0001',
      gameId: storage.gameId,
      operation: 'set',
      bucket: 'save',
      key: 'checkpoint',
      value: 7,
      expectedRevision: standardJsonBucketRevision(standardInitial),
    );
    expect(standardSet.statusCode, HttpStatus.ok);
    final standardGet = await sendStandardJsonBucketRequest(
      baseUri: gateway.entryUri,
      requestId: 'asset-authority-get-0001',
      gameId: storage.gameId,
      operation: 'get',
      bucket: 'save',
      key: 'checkpoint',
    );
    expect(standardGet.statusCode, HttpStatus.ok);
    expect(standardJsonBucketValue(standardGet), 7);

    expect(
      (await http.get(gateway.entryUri.resolve('/bucket/media'))).statusCode,
      HttpStatus.notFound,
    );
    expect(
      (await http.get(
        gateway.entryUri.resolve('/bucket/save/save.json'),
      )).statusCode,
      HttpStatus.notFound,
    );

    final other = await http.get(
      gateway.entryUri.resolve('/assets/other-game/index.html'),
    );
    expect(other.statusCode, HttpStatus.notFound);

    final userApp = await http.get(gateway.entryUri.resolve('/app/index.html'));
    expect(userApp.statusCode, HttpStatus.ok);
    expect(userApp.body, contains('USER_APP_ROUTE'));
    final nestedPlatformName = await http.get(
      gateway.entryUri.resolve('/app/playmesh/user.js'),
    );
    expect(nestedPlatformName.statusCode, HttpStatus.ok);
    expect(nestedPlatformName.body, contains('userAppRoute'));
    final reservedCaseVariant = await http.get(
      gateway.entryUri.resolve('/PLAYMESH/sdk/v1/playmesh-main.js'),
    );
    expect(reservedCaseVariant.statusCode, HttpStatus.notFound);
  });

  test('Web Runtime 多线程未启用时不添加跨源隔离头', () async {
    final packageRoot = await _createInstalledPackageRoot();
    addTearDown(() => packageRoot.delete(recursive: true));
    for (final config in <Object?>[
      null,
      const {
        'webRuntime': {'multithreading': false},
      },
      const {
        'webRuntime': {'multithreading': 'true'},
      },
      const {'futureRuntime': true},
    ]) {
      final gateway = await startGameAssetGateway(
        source: InstalledGameWebResourceSource(
          packageRootPath: packageRoot.path,
        ),
        entryPath: 'index.html',
        config: config,
      );
      final response = await http.get(gateway.entryUri);
      await gateway.close();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['cross-origin-opener-policy'], isNull);
      expect(response.headers['cross-origin-embedder-policy'], isNull);
    }
  });

  test('资源网关在启动时拒绝未注册的 SDK 版本', () async {
    final packageRoot = await _createInstalledPackageRoot();
    addTearDown(() => packageRoot.delete(recursive: true));
    expect(
      () => startGameAssetGateway(
        source: InstalledGameWebResourceSource(
          packageRootPath: packageRoot.path,
        ),
        entryPath: 'index.html',
        gameSdkVersion: '99.0.0',
      ),
      throwsUnsupportedError,
    );
  });

  test('资源网关不接收客户端 console 日志', () async {
    final packageRoot = await _createInstalledPackageRoot();
    addTearDown(() => packageRoot.delete(recursive: true));
    final gateway = await startGameAssetGateway(
      source: InstalledGameWebResourceSource(packageRootPath: packageRoot.path),
      entryPath: 'index.html',
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
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      entryPath: 'index.html',
    );
    addTearDown(gateway.close);

    final entry = await http.get(gateway.entryUri);
    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-app.js'));
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-main.js'));
    expect(
      entry.body.indexOf('/playmesh/sdk/v1/playmesh-app.js'),
      lessThan(entry.body.indexOf('/playmesh/sdk/v1/playmesh-main.js')),
    );

    final sdk = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-main.js'),
    );
    expect(sdk.statusCode, HttpStatus.ok);
    expect(sdk.body, contains('global.playmesh = Object.freeze'));
  });

  test('开发资源源只代理普通路径并为固定上游附加会话凭据', () async {
    final credential = List<String>.filled(40, 'd').join();
    final requests = <String>[];
    final controlMethods = <String>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) async {
      requests.add(request.uri.path);
      if (request.headers.value(playmeshDevelopmentCredentialHeader) !=
          credential) {
        request.response.statusCode = HttpStatus.forbidden;
      } else if (request.uri.path == '/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><head></head><body>DEV</body></html>',
        );
      } else if (request.uri.path == '/assets/main.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
        );
        request.response.write('window.devLoaded = true;');
      } else if (request.uri.path ==
          '/$playmeshDevelopmentRestartControlPath') {
        controlMethods.add(request.method);
        request.response.statusCode = HttpStatus.accepted;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      entryPath: 'index.html',
      gameSdkVersion: '4.1.0',
      appSdkVersion: '3.3.0',
    );
    addTearDown(gateway.close);

    final entry = await http.get(gateway.entryUri);
    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('DEV'));
    expect(entry.body, contains('/playmesh/sdk/v1/playmesh-app.js'));
    final script = await http.get(
      gateway.entryUri.resolve('/assets/main.js?cache=1'),
    );
    expect(script.statusCode, HttpStatus.ok);
    expect(script.body, contains('devLoaded'));
    final restart = await http.post(
      gateway.entryUri.resolve('/$playmeshDevelopmentRestartControlPath'),
    );
    expect(restart.statusCode, HttpStatus.accepted);
    final platform = await http.get(
      gateway.entryUri.resolve('/playmesh/sdk/v1/playmesh-main.js'),
    );
    expect(platform.statusCode, HttpStatus.ok);
    final bucket = await http.get(gateway.entryUri.resolve('/bucket/private'));
    expect(bucket.statusCode, HttpStatus.notFound);
    expect(requests, [
      '/index.html',
      '/assets/main.js',
      '/$playmeshDevelopmentRestartControlPath',
    ]);
    expect(controlMethods, ['POST']);
  });

  test('开发入口用纯路径读取上游并在 WebView 地址保留查询参数', () async {
    final credential = List<String>.filled(40, 'q').join();
    final requests = <String>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      requests.add(request.uri.toString());
      if (request.headers.value(playmeshDevelopmentCredentialHeader) !=
          credential) {
        request.response.statusCode = HttpStatus.forbidden;
      } else if (request.uri.path == '/web-mobile/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><head></head><body>COCOS</body></html>',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      entryPath:
          'web-mobile/index.html?scene=current_scene'
          '&mode=touch&mode=keyboard',
    );
    addTearDown(() async {
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    expect(gateway.entryUri.path, '/web-mobile/index.html');
    expect(gateway.entryUri.queryParameters['scene'], 'current_scene');
    expect(gateway.entryUri.queryParametersAll['mode'], ['touch', 'keyboard']);

    final entry = await http.get(gateway.entryUri);

    expect(entry.statusCode, HttpStatus.ok);
    expect(entry.body, contains('COCOS'));
    expect(requests, [
      '/web-mobile/index.html?scene=current_scene&mode=touch&mode=keyboard',
    ]);
  });

  test('开发资源源双向代理 WebSocket 并保留 HMR 子协议', () async {
    final credential = List<String>.filled(40, 'w').join();
    final receivedCredentials = <String?>[];
    final negotiatedProtocols = <String?>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      receivedCredentials.add(
        request.headers.value(playmeshDevelopmentCredentialHeader),
      );
      if (request.uri.path != '/hmr' ||
          request.headers.value(playmeshDevelopmentCredentialHeader) !=
              credential) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) =>
            protocols.contains('vite-hmr') ? 'vite-hmr' : null,
      );
      negotiatedProtocols.add(socket.protocol);
      socket.listen((message) => socket.add('upstream:$message'));
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      entryPath: 'index.html',
    );
    addTearDown(() async {
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    final socket = await WebSocket.connect(
      gateway.entryUri
          .replace(scheme: 'ws', path: '/hmr', queryParameters: {'v': '1'})
          .toString(),
      protocols: const ['vite-hmr'],
    );
    addTearDown(socket.close);
    socket.add('ping');

    expect(socket.protocol, 'vite-hmr');
    expect(
      await socket.first.timeout(const Duration(seconds: 3)),
      'upstream:ping',
    );
    expect(receivedCredentials, [credential]);
    expect(negotiatedProtocols, ['vite-hmr']);
  });

  test('开发资源会话到期会同时关闭代理两端 WebSocket', () async {
    final credential = List<String>.filled(40, 'e').join();
    final upstreamConnected = Completer<void>();
    final upstreamClosed = Completer<void>();
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!upstreamConnected.isCompleted) upstreamConnected.complete();
      socket.listen(
        (_) {},
        onDone: () {
          if (!upstreamClosed.isCompleted) upstreamClosed.complete();
        },
        onError: (_) {
          if (!upstreamClosed.isCompleted) upstreamClosed.complete();
        },
      );
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 2)),
      ),
      entryPath: 'index.html',
    );
    addTearDown(() async {
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    final socket = await WebSocket.connect(
      gateway.entryUri.replace(scheme: 'ws', path: '/hmr').toString(),
    );
    await upstreamConnected.future.timeout(const Duration(seconds: 3));
    await socket.drain<void>().timeout(const Duration(seconds: 5));
    await upstreamClosed.future.timeout(const Duration(seconds: 3));

    expect(socket.closeCode, WebSocketStatus.policyViolation);
  });

  test('开发资源本地 WebSocket upgrade 失败后关闭已连接的上游', () async {
    final credential = List<String>.filled(40, 'f').join();
    final upstreamRequested = Completer<void>();
    final allowUpstreamUpgrade = Completer<void>();
    final upstreamClosed = Completer<void>();
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      if (!upstreamRequested.isCompleted) upstreamRequested.complete();
      await allowUpstreamUpgrade.future;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (_) {},
        onDone: () {
          if (!upstreamClosed.isCompleted) upstreamClosed.complete();
        },
        onError: (_) {
          if (!upstreamClosed.isCompleted) upstreamClosed.complete();
        },
      );
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      entryPath: 'index.html',
    );
    addTearDown(() async {
      if (!allowUpstreamUpgrade.isCompleted) allowUpstreamUpgrade.complete();
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      gateway.entryUri.port,
    );
    socket.write(
      'GET /hmr HTTP/1.1\r\n'
      'Host: 127.0.0.1:${gateway.entryUri.port}\r\n'
      'Connection: Upgrade\r\n'
      'Upgrade: websocket\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
      '\r\n',
    );
    await socket.flush();
    await upstreamRequested.future.timeout(const Duration(seconds: 3));
    socket.destroy();
    allowUpstreamUpgrade.complete();

    await upstreamClosed.future.timeout(const Duration(seconds: 3));
  });

  test('开发资源入口拒绝超过内存保护上限的响应', () async {
    final credential = List<String>.filled(40, 'l').join();
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamSubscription = upstream.listen((request) async {
      request.response.contentLength = 9 * 1024 * 1024;
      try {
        request.response.add(const <int>[0]);
        await request.response.flush();
        await request.response.done;
      } on Object {
        // 代理读取响应头并确认超限后会主动取消该响应。
      }
    });
    final gateway = await startGameAssetGateway(
      source: DevelopmentGameWebResourceSource(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}/'),
        credential: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      entryPath: 'index.html',
    );
    addTearDown(() async {
      await gateway.close();
      await upstreamSubscription.cancel();
      await upstream.close(force: true);
    });

    final response = await http.get(gateway.entryUri);

    expect(response.statusCode, HttpStatus.internalServerError);
  });

  test('开发资源源拒绝过期会话和编码路径绕过', () async {
    final expiredCredential = List<String>.filled(40, 'x').join();
    expect(
      () => startGameAssetGateway(
        source: DevelopmentGameWebResourceSource(
          baseUri: Uri.parse('http://127.0.0.1:9999/'),
          credential: expiredCredential,
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(seconds: 1),
          ),
        ),
        entryPath: 'index.html',
      ),
      throwsFormatException,
    );

    final root = await Directory.systemTemp.createTemp(
      'playmesh-encoded-gateway-',
    );
    final app = Directory('${root.path}${Platform.pathSeparator}app');
    await app.create(recursive: true);
    await File(
      '${app.path}${Platform.pathSeparator}index.html',
    ).writeAsString('<!doctype html>');
    addTearDown(() => root.delete(recursive: true));
    final gateway = await startGameAssetGateway(
      source: InstalledGameWebResourceSource(packageRootPath: root.path),
      entryPath: 'index.html',
    );
    addTearDown(gateway.close);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      gateway.entryUri.port,
    );
    socket.write(
      'GET /assets%2Fsecret.js HTTP/1.1\r\n'
      'Host: 127.0.0.1:${gateway.entryUri.port}\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();
    final response = await utf8.decoder.bind(socket).join();
    expect(response, startsWith('HTTP/1.1 403'));
  });
}

void _expectGameWebViewIsolationHeaders(http.Response response) {
  expect(
    response.headers['cross-origin-opener-policy'],
    'same-origin',
    reason: response.request?.url.toString(),
  );
  expect(
    response.headers['cross-origin-embedder-policy'],
    'require-corp',
    reason: response.request?.url.toString(),
  );
}

Future<Directory> _createInstalledPackageRoot() async {
  final root = await Directory.systemTemp.createTemp(
    'playmesh-installed-package-',
  );
  final app = Directory('${root.path}${Platform.pathSeparator}app');
  await app.create(recursive: true);
  await File(
    '${app.path}${Platform.pathSeparator}index.html',
  ).writeAsString('<!doctype html><html><head></head><body>GAME</body></html>');
  final userApp = Directory('${app.path}${Platform.pathSeparator}app');
  await userApp.create(recursive: true);
  await File(
    '${userApp.path}${Platform.pathSeparator}index.html',
  ).writeAsString(
    '<!doctype html><html><head></head><body>USER_APP_ROUTE</body></html>',
  );
  final nestedPlatformName = Directory(
    '${userApp.path}${Platform.pathSeparator}playmesh',
  );
  await nestedPlatformName.create(recursive: true);
  await File(
    '${nestedPlatformName.path}${Platform.pathSeparator}user.js',
  ).writeAsString('window.userAppRoute = true;');
  return root;
}
