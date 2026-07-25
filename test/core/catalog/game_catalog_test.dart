import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/game_catalog_preferences.dart';
import 'package:playmesh/core/catalog/game_catalog_server.dart';
import 'package:playmesh/core/catalog/online_game_catalog.dart';
import 'package:playmesh/core/game_package/file_game_library_scanner.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_manifest.dart';

void main() {
  test('本地游戏源支持鉴权、分页搜索和安全包下载', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-catalog-');
    final importRoot = await Directory.systemTemp.createTemp(
      'playmesh-catalog-import-',
    );
    addTearDown(() async {
      await root.delete(recursive: true);
      await importRoot.delete(recursive: true);
    });
    await _writeInstalledGame(
      root,
      id: 'com.example.catalog',
      name: '星海竞速',
      description: '支持局域网竞速',
      tags: ['race', 'party'],
    );
    await _writeInstalledGame(
      root,
      id: 'com.example.other',
      name: '另一款游戏',
      description: '其他描述',
      tags: ['casual'],
    );
    final scanner = FileGameLibraryScanner(libraryRoot: root);
    final library = GameLibraryRepository(scanner.scan);
    final transfer = GamePackageTransferService(libraryRoot: root);
    final server = GameCatalogServer(
      library,
      transfer,
      nicknameProvider: () => '测试玩家',
    );
    addTearDown(server.stop);
    final port = await _freePort();
    await server.start(port: port, token: 'catalog-token');
    final base = Uri.parse('http://127.0.0.1:$port');

    final unauthorized = await http.get(base.resolve('/apps/list'));
    expect(unauthorized.statusCode, HttpStatus.unauthorized);

    final list = await http.get(
      base.replace(
        path: '/apps/list',
        queryParameters: {
          'page': '1',
          'size': '5',
          's_name': '星海',
          's_tag': 'race',
          's_desc': '局域网',
        },
      ),
      headers: const {HttpHeaders.authorizationHeader: 'Bearer catalog-token'},
    );
    expect(list.statusCode, HttpStatus.ok);
    expect(list.headers['x-playmesh-catalog-version'], '1.4.0');
    final listJson = jsonDecode(list.body) as Map<String, Object?>;
    expect(listJson['total'], 1);
    expect(listJson['current'], 1);
    final manifest = (listJson['data']! as List).single as Map;
    expect(manifest['id'], 'com.example.catalog');
    expect(manifest['sdkVersion'], '1.3.0');
    expect(manifest['entries'], isA<Map>());

    final info = await http.get(
      base.resolve('/apps/info'),
      headers: const {HttpHeaders.authorizationHeader: 'Bearer catalog-token'},
    );
    expect(info.statusCode, HttpStatus.ok);
    expect(jsonDecode(info.body), {
      'catalogApiVersion': '1.4.0',
      'name': '测试玩家的游戏库',
      'supportsGameRelay': false,
    });

    final secondPage = await http.get(
      base.replace(
        path: '/apps/list',
        queryParameters: {'page': '2', 'size': '1'},
      ),
      headers: const {HttpHeaders.authorizationHeader: 'Bearer catalog-token'},
    );
    final secondPageJson = jsonDecode(secondPage.body) as Map<String, Object?>;
    expect(secondPageJson['total'], 2);
    expect(secondPageJson['current'], 2);
    expect(secondPageJson['size'], 1);
    expect(secondPageJson['data'], hasLength(1));

    final download = await http.get(
      base.replace(
        path: '/apps/download',
        queryParameters: {'id': 'com.example.catalog'},
      ),
      headers: const {HttpHeaders.authorizationHeader: 'Bearer catalog-token'},
    );
    expect(download.statusCode, HttpStatus.ok);
    final file = File('${importRoot.path}${Platform.pathSeparator}remote.zip');
    await file.writeAsBytes(download.bodyBytes);
    final imported = await GamePackageTransferService(
      libraryRoot: importRoot,
    ).importPackage(file);
    expect(imported.id, 'com.example.catalog');

    final queueImported = Completer<void>();
    final queue = GameDownloadQueue(
      GamePackageTransferService(libraryRoot: importRoot),
      (_) async => queueImported.complete(),
    );
    addTearDown(queue.close);
    queue.enqueue([
      OnlineCatalogGame(
        manifest: GameManifest.fromJson(Map<String, Object?>.from(manifest)),
        source: OnlineGameSource(
          id: 'local',
          name: '本机源',
          host: base,
          token: 'catalog-token',
        ),
      ),
    ]);
    await queueImported.future.timeout(const Duration(seconds: 5));
    await _waitUntil(
      () => queue.tasks.single.status == GameDownloadStatus.completed,
    );
    expect(queue.tasks.single.status, GameDownloadStatus.completed);

    await server.start(port: port, token: '');
    final publicList = await http.get(base.resolve('/apps/list?size=1'));
    expect(publicList.statusCode, HttpStatus.ok);
  });

  test('多个在线源并发获取并按 ID 去重，下载队列可停止和删除', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-sources-');
    final installRoot = await Directory.systemTemp.createTemp(
      'playmesh-source-install-',
    );
    addTearDown(() async {
      await root.delete(recursive: true);
      await installRoot.delete(recursive: true);
    });
    final barrier = Completer<void>();
    var requests = 0;
    final first = await _sourceServer(
      barrier: barrier,
      onList: () {
        requests += 1;
        if (requests == 2) barrier.complete();
      },
      manifests: [
        _manifest('com.example.same', '相同游戏'),
        _manifest('com.example.first', '第一个源'),
      ],
    );
    final second = await _sourceServer(
      barrier: barrier,
      onList: () {
        requests += 1;
        if (requests == 2) barrier.complete();
      },
      manifests: [
        _manifest('com.example.same', '重复游戏'),
        _manifest('com.example.second', '第二个源'),
      ],
    );
    addTearDown(() => first.close(force: true));
    addTearDown(() => second.close(force: true));
    final preferences = GameCatalogPreferences(libraryRoot: root);
    await preferences.save(
      GameCatalogPreferencesValue(
        sources: [
          OnlineGameSource(
            id: 'first',
            name: '第一源',
            host: Uri.parse('http://127.0.0.1:${first.port}'),
          ),
          OnlineGameSource(
            id: 'second',
            name: '第二源',
            host: Uri.parse('http://127.0.0.1:${second.port}'),
          ),
        ],
      ),
    );
    final controller = GameCatalogController(
      library: GameLibraryRepository(() async => const []),
      transfer: GamePackageTransferService(libraryRoot: installRoot),
      onImported: (_) async {},
      nicknameProvider: () => '测试玩家',
      preferences: preferences,
    );
    addTearDown(controller.close);

    final result = await controller.search().timeout(
      const Duration(seconds: 5),
    );

    expect(requests, 2);
    expect(result.errors, isEmpty);
    expect(result.games.map((game) => game.manifest.id).toSet(), {
      'com.example.same',
      'com.example.first',
      'com.example.second',
    });

    controller.downloads.enqueue(result.games.take(2));
    final queued = controller.downloads.tasks.last;
    controller.downloads.stop(queued.id);
    expect(queued.status, GameDownloadStatus.stopped);
    controller.downloads.delete(queued.id);
    expect(controller.downloads.tasks, isNot(contains(queued)));
  });

  test('游戏源设置和扫码配置可以持久化恢复', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-source-settings-',
    );
    addTearDown(() => root.delete(recursive: true));
    final preferences = GameCatalogPreferences(libraryRoot: root);
    final source = OnlineGameSource.fromConfigurationUri(
      'playmesh://catalog-source?host=http%3A%2F%2F192.168.1.8%3A16668'
      '&token=abc&name=LivingRoom',
    );
    await preferences.save(
      GameCatalogPreferencesValue(
        share: const GameCatalogShareConfig(
          enabled: true,
          port: 17777,
          token: 'share-token',
        ),
        defaultPageSize: 20,
        sources: [source],
      ),
    );

    final loaded = await preferences.load();

    expect(loaded.share.port, 17777);
    expect(loaded.share.token, 'share-token');
    expect(loaded.defaultPageSize, 20);
    expect(loaded.sources.single.host.port, 16668);
    expect(loaded.sources.single.token, 'abc');
  });

  test('游戏源声明校验中转字段并格式化默认端口', () {
    final declaration = GameCatalogDeclaration.fromJson({
      'catalogApiVersion': '1.4.0',
      'supportsGameRelay': true,
      'relay': {
        'protocolVersion': '2.0.0',
        'transport': 'playmesh-tcp-upgrade',
        'publicBaseUrl': 'https://relay.example.com:8443',
        'hostPath': '/relay/v1/host',
        'clientPath': '/relay/v1/client',
        'maxConnectionsPerTunnel': 64,
      },
    });

    expect(
      declaration.displayNameFor(Uri.parse('https://example.com:443')),
      'example.com',
    );
    expect(declaration.supportsGameRelay, isTrue);
    expect(
      declaration.relay!.publicBaseUrl,
      Uri.parse('https://relay.example.com:8443'),
    );
    expect(declaration.relay!.maxConnectionsPerTunnel, 64);
    expect(
      () => GameCatalogDeclaration.fromJson({
        'catalogApiVersion': '1.4.0',
        'supportsGameRelay': true,
      }),
      throwsFormatException,
    );
    expect(
      () => GameCatalogDeclaration.fromJson({
        'catalogApiVersion': '1.4.0',
        'supportsGameRelay': true,
        'relay': {
          'protocolVersion': '2.0.0',
          'transport': 'playmesh-tcp-upgrade',
          'hostPath': '/relay/v1/host',
          'clientPath': '/relay/v1/client',
          'maxConnectionsPerTunnel': 64,
        },
      }),
      throwsFormatException,
    );
    final httpDeclaration = GameCatalogDeclaration.fromJson({
      'catalogApiVersion': '1.4.0',
      'supportsGameRelay': true,
      'relay': {
        'protocolVersion': '2.0.0',
        'transport': 'playmesh-tcp-upgrade',
        'publicBaseUrl': 'http://relay.example.com',
        'hostPath': '/relay/v1/host',
        'clientPath': '/relay/v1/client',
        'maxConnectionsPerTunnel': 64,
      },
    });
    expect(httpDeclaration.relay!.publicBaseUrl.scheme, 'http');
    expect(
      () => GameCatalogDeclaration.fromJson({
        'catalogApiVersion': '1.4.0',
        'supportsGameRelay': true,
        'relay': {
          'protocolVersion': '2.0.0',
          'transport': 'playmesh-tcp-upgrade',
          'publicBaseUrl': 'https://relay.example.com',
          'hostPath': '/relay/v1/host',
          'clientPath': '/relay/v1/client',
        },
      }),
      throwsFormatException,
    );
  });
}

Future<void> _writeInstalledGame(
  Directory root, {
  required String id,
  required String name,
  required String description,
  required List<String> tags,
}) async {
  final package = Directory(
    '${root.path}${Platform.pathSeparator}packages'
    '${Platform.pathSeparator}$id',
  );
  await Directory(
    '${package.path}${Platform.pathSeparator}app',
  ).create(recursive: true);
  await File('${package.path}${Platform.pathSeparator}main.json').writeAsString(
    jsonEncode(_manifest(id, name, description: description, tags: tags)),
  );
  await File(
    '${package.path}${Platform.pathSeparator}app'
    '${Platform.pathSeparator}index.html',
  ).writeAsString('<!doctype html><title>$name</title>');
}

Map<String, Object?> _manifest(
  String id,
  String name, {
  String description = '在线游戏',
  List<String> tags = const ['party'],
}) => {
  'id': id,
  'name': name,
  'author': 'Test Author',
  'lastModifiedAt': 1784851200000,
  'remarks': description,
  'version': '1.0.0',
  'sdkVersion': '1.3.0',
  'orientation': 'portrait',
  'modes': ['solo'],
  'displayModes': ['multi_screen'],
  'players': {'min': 1, 'max': 1},
  'entries': {'game': 'app/index.html'},
  'permissions': <String>[],
  'tags': tags,
};

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<HttpServer> _sourceServer({
  required Completer<void> barrier,
  required void Function() onList,
  required List<Map<String, Object?>> manifests,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path == '/apps/list') {
      onList();
      await barrier.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'total': manifests.length,
          'current': 1,
          'size': 5,
          'data': manifests,
        }),
      );
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  });
  return server;
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
