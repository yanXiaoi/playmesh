import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/game_catalog_preferences.dart';
import 'package:playmesh/core/catalog/game_catalog_server.dart';
import 'package:playmesh/core/catalog/online_game_catalog.dart';
import 'package:playmesh/core/game_package/game_library_local_metadata.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('publicURL 接受 HTTP/HTTPS origin、token 和 uploadKey', () {
    final parsed = parseCatalogPublicUrl(
      'https://games.example.com?token=read-token&uploadKey=upload-secret',
    );
    expect(parsed.host.toString(), 'https://games.example.com');
    expect(parsed.token, 'read-token');
    expect(parsed.uploadKey, 'upload-secret');
    expect(
      () => parseCatalogPublicUrl(
        'playmesh://catalog-source?host=https://games.example.com',
      ),
      throwsFormatException,
    );
    expect(
      () => parseCatalogPublicUrl('https://games.example.com?token=a&x=b'),
      throwsFormatException,
    );
  });

  test(
    'publicURL probe sends token only as Bearer and failure never overwrites config',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playmesh-public-url-probe-',
      );
      addTearDown(() => root.delete(recursive: true));
      final requests = <({Uri uri, String? authorization})>[];
      var sourceAvailable = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add((
          uri: request.uri,
          authorization: request.headers.value(HttpHeaders.authorizationHeader),
        ));
        if (request.uri.path != '/apps/info') {
          request.response.statusCode = HttpStatus.notFound;
        } else if (!sourceAvailable) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'catalogApiVersion': '2.0.0',
              'name': 'Remote Dynamic Source / 原样',
              'author': 'Remote Publisher / 原样',
              'supportsGameRelay': false,
              'userUpload': {'supported': false},
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final controller = await _catalogController(root, const []);
      addTearDown(controller.close);
      final publicUrl =
          'http://127.0.0.1:${server.port}'
          '?token=stable-read-token&uploadKey=stable-upload-key';

      final imported = await controller.verifyAndUpsertSource(publicUrl);

      expect(imported.name, 'Remote Dynamic Source / 原样');
      expect(imported.declaration?.author, 'Remote Publisher / 原样');
      expect(imported.uploadKey, 'stable-upload-key');
      expect(requests.single.uri.path, '/apps/info');
      expect(requests.single.uri.queryParameters, isEmpty);
      expect(requests.single.authorization, 'Bearer stable-read-token');

      sourceAvailable = false;
      await expectLater(
        controller.verifyAndUpsertSource(
          'http://127.0.0.1:${server.port}'
          '?token=replacement-token&uploadKey=replacement-upload-key',
        ),
        throwsFormatException,
      );

      expect(requests.last.uri.path, '/apps/info');
      expect(requests.last.uri.queryParameters, isEmpty);
      expect(requests.last.authorization, 'Bearer replacement-token');
      expect(controller.sources, hasLength(1));
      expect(controller.sources.single.id, imported.id);
      expect(controller.sources.single.name, imported.name);
      expect(controller.sources.single.token, 'stable-read-token');
      expect(controller.sources.single.uploadKey, 'stable-upload-key');
      expect(
        controller.sources.single.declaration?.name,
        'Remote Dynamic Source / 原样',
      );

      final persisted = await GameCatalogPreferences(libraryRoot: root).load();
      expect(persisted.sources, hasLength(1));
      expect(persisted.sources.single.id, imported.id);
      expect(persisted.sources.single.token, 'stable-read-token');
      expect(persisted.sources.single.uploadKey, 'stable-upload-key');
      expect(
        persisted.sources.single.declaration?.name,
        'Remote Dynamic Source / 原样',
      );
    },
  );

  test(
    'source declaration refresh uses apps info and replaces persisted cache',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playmesh-source-refresh-',
      );
      addTearDown(() => root.delete(recursive: true));
      final paths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path != '/apps/info') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'catalogApiVersion': '2.0.0',
              'name': 'Fresh API Source / 原样',
              'author': 'Fresh API Publisher / 原样',
              'supportsGameRelay': false,
              'userUpload': {'supported': false},
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final cached = OnlineGameSource(
        id: 'cached',
        name: 'User Source Name / 原样',
        host: Uri.parse('http://127.0.0.1:${server.port}'),
        declaration: const GameCatalogDeclaration(
          catalogApiVersion: gameCatalogApiVersion,
          name: 'Cached API Source / 原样',
          author: 'Cached API Publisher / 原样',
          supportsGameRelay: false,
        ),
        lastValidatedAt: DateTime.utc(2026, 7, 25),
      );
      final controller = await _catalogController(root, [cached]);
      addTearDown(controller.close);

      expect(
        controller.sources.single.declaration?.name,
        'Cached API Source / 原样',
      );

      final probe = await controller.refreshSourceDeclaration(cached.id);

      expect(paths, ['/apps/info']);
      expect(probe.error, isNull);
      expect(controller.sources.single.name, 'User Source Name / 原样');
      expect(
        controller.sources.single.declaration?.name,
        'Fresh API Source / 原样',
      );
      expect(
        controller.sources.single.declaration?.author,
        'Fresh API Publisher / 原样',
      );
      final persisted = await GameCatalogPreferences(libraryRoot: root).load();
      expect(
        persisted.sources.single.declaration?.name,
        'Fresh API Source / 原样',
      );
    },
  );

  test('Catalog 2.0 声明严格校验 userUpload 能力', () {
    final declaration = GameCatalogDeclaration.fromJson({
      'catalogApiVersion': '2.0.0',
      'name': 'Source',
      'supportsGameRelay': false,
      'userUpload': {'supported': false},
    });
    expect(declaration.userUpload.supported, isFalse);
    expect(
      () => GameCatalogDeclaration.fromJson({
        'catalogApiVersion': '1.4.0',
        'supportsGameRelay': false,
        'userUpload': {'supported': false},
      }),
      throwsFormatException,
    );
  });

  test('旧 source config 被隔离且不会兼容读取', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-source-v1-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(
      '${root.path}${Platform.pathSeparator}catalog'
      '${Platform.pathSeparator}settings.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'formatVersion': 1, 'sources': <Object?>[]}),
    );
    final preferences = GameCatalogPreferences(
      libraryRoot: root,
      now: () => DateTime.utc(2026, 7, 26),
    );
    expect((await preferences.load()).sources, isEmpty);
    expect(await file.exists(), isTrue);
    expect(
      await file.parent
          .list()
          .where((entry) => entry.path.endsWith('.unsupported'))
          .length,
      1,
    );
  });

  test('聚合保留同 gameId 的不同发布者并按本机热度排序', () {
    final first = OnlineGameSource(
      id: 'first',
      name: 'First',
      host: Uri.parse('https://first.example'),
    );
    final second = OnlineGameSource(
      id: 'second',
      name: 'Second',
      host: Uri.parse('https://second.example'),
    );
    final results = aggregateCatalogOffers(
      [
        OnlineCatalogGame(
          manifest: _manifest(id: 'shared', author: 'A', version: '1.0.0'),
          source: first,
        ),
        OnlineCatalogGame(
          manifest: _manifest(id: 'shared', author: 'A', version: '2.0.0'),
          source: second,
        ),
        OnlineCatalogGame(
          manifest: _manifest(id: 'shared', author: 'B', version: '3.0.0'),
          source: second,
        ),
      ],
      usage: {'shared': const GameLibraryUsageStats(launchCount: 7)},
      sourceOrder: const ['first', 'second'],
    );
    expect(results, hasLength(2));
    expect(results.every((result) => result.heat == 7), isTrue);
    expect(
      results.firstWhere((result) => result.publisher == 'A').versions.length,
      2,
    );
  });

  test('在线游戏聚合结果按最后修改时间最新优先', () {
    final source = OnlineGameSource(
      id: 'source',
      name: 'Source',
      host: Uri.parse('https://source.example'),
    );
    final results = aggregateCatalogOffers(
      [
        OnlineCatalogGame(
          manifest: _manifest(
            id: 'older-hot-game',
            lastModifiedAt: DateTime.utc(2026, 7, 20),
          ),
          source: source,
        ),
        OnlineCatalogGame(
          manifest: _manifest(
            id: 'newer-game',
            lastModifiedAt: DateTime.utc(2026, 7, 27),
          ),
          source: source,
        ),
      ],
      usage: {'older-hot-game': const GameLibraryUsageStats(launchCount: 100)},
    );

    expect(results.map((result) => result.gameId), [
      'newer-game',
      'older-hot-game',
    ]);
  });

  test('更新候选只匹配同 gameId、同发布者和更高严格版本', () {
    final source = OnlineGameSource(
      id: 'source',
      name: 'Local Source Name',
      host: Uri.parse('https://source.example'),
    );
    final installed = _summary('unused');
    final updates = findGameUpdates(
      installedGames: [installed],
      offers: [
        OnlineCatalogGame(
          manifest: _manifest(version: '2.0.0'),
          source: source,
        ),
        OnlineCatalogGame(
          manifest: _manifest(author: 'Other', version: '9.0.0'),
          source: source,
        ),
        OnlineCatalogGame(
          manifest: _manifest(version: '1.0.0'),
          source: source,
        ),
      ],
    );
    expect(updates.single.versions.single.targetVersion, '2.0.0');
    expect(
      updates.single.versions.single.sources.single.localSourceName,
      'Local Source Name',
    );
  });

  test('搜索为每个源维护独立页码', () async {
    final requestedPages = <String, List<int>>{
      'first': <int>[],
      'second': <int>[],
    };
    final firstServer = await _startCatalogServer((request) {
      final page = int.parse(request.uri.queryParameters['page']!);
      requestedPages['first']!.add(page);
      return {
        'total': 20,
        'current': page,
        'size': 5,
        'data': [_manifest(id: 'com.example.first$page').toJson()],
      };
    });
    final secondServer = await _startCatalogServer((request) {
      final page = int.parse(request.uri.queryParameters['page']!);
      requestedPages['second']!.add(page);
      return {
        'total': 20,
        'current': page,
        'size': 5,
        'data': [_manifest(id: 'com.example.second$page').toJson()],
      };
    });
    addTearDown(() => firstServer.close(force: true));
    addTearDown(() => secondServer.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-source-pages-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(firstServer, id: 'first'),
      _sourceFor(secondServer, id: 'second'),
    ]);
    addTearDown(controller.close);

    final result = await controller.search(
      pagesBySource: const {'first': 2, 'second': 3},
    );

    expect(requestedPages['first'], [2]);
    expect(requestedPages['second'], [3]);
    expect(
      {for (final section in result.sections) section.source.id: section.page},
      {'first': 2, 'second': 3},
    );
  });

  test('游戏源每页结果按最后修改时间最新优先', () async {
    final server = await _startCatalogServer(
      (_) => {
        'total': 2,
        'data': [
          _manifest(
            id: 'com.example.older',
            lastModifiedAt: DateTime.utc(2026, 7, 20),
          ).toJson(),
          _manifest(
            id: 'com.example.newer',
            lastModifiedAt: DateTime.utc(2026, 7, 27),
          ).toJson(),
        ],
      },
    );
    addTearDown(() => server.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-source-newest-first-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(server, id: 'newest-source'),
    ]);
    addTearDown(controller.close);

    final result = await controller.loadHomeSource('newest-source');

    expect(result.offers.map((offer) => offer.manifest.id), [
      'com.example.newer',
      'com.example.older',
    ]);
  });

  test('后台更新检查读取每个源的全部分页', () async {
    final requestedPages = <int>[];
    final server = await _startCatalogServer((request) {
      final page = int.parse(request.uri.queryParameters['page']!);
      requestedPages.add(page);
      final data = page == 1
          ? [
              for (var index = 0; index < 5; index += 1)
                _manifest(id: 'com.example.unrelated$index').toJson(),
            ]
          : [_manifest(id: 'com.example.catalog', version: '2.0.0').toJson()];
      return {'total': 6, 'current': page, 'size': 5, 'data': data};
    });
    addTearDown(() => server.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-update-pages-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(server, id: 'updates'),
    ]);
    addTearDown(controller.close);

    final result = await controller.checkUpdates([_summary('unused')]);

    expect(requestedPages, [1, 2]);
    expect(result.candidates.single.versions.single.targetVersion, '2.0.0');
    expect(result.sourceErrors, isEmpty);
  });

  test('latest 协议错误保留同源合法游戏并只采用最高版本', () async {
    final server = await _startCatalogServer(
      (_) => {
        'total': 3,
        'data': [
          _manifest(id: 'com.example.catalog', version: '1.5.0').toJson(),
          _manifest(id: 'com.example.other', version: '4.0.0').toJson(),
          _manifest(id: 'com.example.catalog', version: '2.0.0').toJson(),
        ],
      },
    );
    addTearDown(() => server.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-latest-protocol-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(server, id: 'latest-source'),
    ]);
    addTearDown(controller.close);

    final search = await controller.search();
    final catalogOffers = search.games
        .where((offer) => offer.manifest.id == 'com.example.catalog')
        .toList();
    expect(search.errors['latest-source'], contains('多个版本'));
    expect(
      search.games.map((offer) => offer.manifest.id),
      contains('com.example.other'),
    );
    expect(catalogOffers, hasLength(1));
    expect(catalogOffers.single.manifest.version, '2.0.0');

    final update = await controller.checkUpdates([_summary('unused')]);
    expect(update.sourceErrors, hasLength(1));
    expect(update.candidates.single.versions.single.targetVersion, '2.0.0');
  });

  test('跨页重复 gameId 排除历史 offer 且继续保留其他游戏', () async {
    final server = await _startCatalogServer((request) {
      final page = int.parse(request.uri.queryParameters['page']!);
      if (page == 1) {
        return {
          'total': 7,
          'data': [
            _manifest(id: 'com.example.catalog', version: '1.5.0').toJson(),
            for (var index = 0; index < 4; index += 1)
              _manifest(id: 'com.example.cross$index').toJson(),
          ],
        };
      }
      return {
        'total': 7,
        'data': [
          _manifest(id: 'com.example.catalog', version: '2.0.0').toJson(),
          _manifest(id: 'com.example.cross-final').toJson(),
        ],
      };
    });
    addTearDown(() => server.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-cross-page-latest-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(server, id: 'cross-source'),
    ]);
    addTearDown(controller.close);

    final result = await controller.searchAll();
    final catalogOffers = result.games
        .where((offer) => offer.manifest.id == 'com.example.catalog')
        .toList();

    expect(result.errors['cross-source'], contains('不同分页重复'));
    expect(catalogOffers, hasLength(1));
    expect(catalogOffers.single.manifest.version, '2.0.0');
    expect(
      result.games.map((offer) => offer.manifest.id),
      contains('com.example.cross-final'),
    );
  });

  test('全量查询继续使用源返回的 cursor', () async {
    final requestedCursors = <String?>[];
    final server = await _startCatalogServer((request) {
      final cursor = request.uri.queryParameters['cursor'];
      requestedCursors.add(cursor);
      if (cursor == null) {
        return {
          'total': 999,
          'data': [
            for (var index = 0; index < 5; index += 1)
              _manifest(id: 'com.example.cursor$index').toJson(),
          ],
          'nextCursor': 'opaque-cursor-2',
        };
      }
      expect(cursor, 'opaque-cursor-2');
      return {
        'total': 999,
        'data': [
          _manifest(id: 'com.example.catalog', version: '2.0.0').toJson(),
        ],
      };
    });
    addTearDown(() => server.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-update-cursor-',
    );
    addTearDown(() => root.delete(recursive: true));
    final controller = await _catalogController(root, [
      _sourceFor(server, id: 'cursor-source'),
    ]);
    addTearDown(controller.close);

    final result = await controller.checkUpdates([_summary('unused')]);

    expect(requestedCursors, [null, 'opaque-cursor-2']);
    expect(result.candidates.single.versions.single.targetVersion, '2.0.0');
  });

  test('更新检查隔离源错误并记录完成时间', () async {
    final good = await _startCatalogServer(
      (_) => {
        'total': 1,
        'data': [
          _manifest(id: 'com.example.catalog', version: '2.0.0').toJson(),
        ],
      },
    );
    final bad = await _startCatalogServer((_) => {'unexpected': true});
    addTearDown(() => good.close(force: true));
    addTearDown(() => bad.close(force: true));
    final root = await Directory.systemTemp.createTemp(
      'playmesh-update-errors-',
    );
    addTearDown(() => root.delete(recursive: true));
    final checkedAt = DateTime.utc(2026, 7, 26, 8, 30);
    final controller = await _catalogController(root, [
      _sourceFor(good, id: 'good'),
      OnlineGameSource(
        id: 'bad',
        name: '用户源 β / 原样',
        host: Uri.parse('http://127.0.0.1:${bad.port}'),
      ),
    ], now: () => checkedAt);
    addTearDown(controller.close);

    final result = await controller.checkUpdates([_summary('unused')]);

    expect(result.checkedAt, checkedAt);
    expect(result.candidates, hasLength(1));
    expect(result.sourceErrors, hasLength(1));
    expect(result.sourceErrors.single.sourceId, 'bad');
    expect(result.sourceErrors.single.localSourceName, '用户源 β / 原样');
    expect(result.sourceErrors.single.message, contains('FormatException'));
  });

  test('App Catalog 暴露 2.0 info/icon/带版本 download', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-catalog-v2-');
    addTearDown(() => root.delete(recursive: true));
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.catalog',
    );
    await Directory(
      '${package.path}${Platform.pathSeparator}app',
    ).create(recursive: true);
    await File(
      '${package.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}index.html',
    ).writeAsString('<!doctype html>');
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString(jsonEncode(_manifest().toJson()));
    await File(
      '${package.path}${Platform.pathSeparator}icon.png',
    ).writeAsBytes(_pngBytes);
    final game = _summary(package.path);
    final repository = GameLibraryRepository(
      () async => [game],
      initialGames: [game],
    );
    final server = GameCatalogServer(
      repository,
      GamePackageTransferService(libraryRoot: root),
      nicknameProvider: () => 'Tester',
    );
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    await server.start(port: port, token: 'read-token');
    addTearDown(server.stop);
    final base = Uri.parse('http://127.0.0.1:$port');
    const headers = {HttpHeaders.authorizationHeader: 'Bearer read-token'};

    final info = await http.get(base.resolve('/apps/info'), headers: headers);
    expect(info.statusCode, HttpStatus.ok);
    expect(jsonDecode(info.body), containsPair('catalogApiVersion', '2.0.0'));
    expect((jsonDecode(info.body) as Map)['userUpload'], {'supported': false});

    final list = await http.get(base.resolve('/apps/list'), headers: headers);
    final offer =
        ((jsonDecode(list.body) as Map)['data'] as List).single as Map;
    expect(offer['icon'], contains('/apps/icon'));

    final missingVersion = await http.get(
      base.resolve('/apps/download?id=com.example.catalog'),
      headers: headers,
    );
    expect(missingVersion.statusCode, HttpStatus.badRequest);
    final download = await http.get(
      base.resolve('/apps/download?id=com.example.catalog&version=1.2.3'),
      headers: headers,
    );
    expect(download.statusCode, HttpStatus.ok);
    expect(download.bodyBytes, isNotEmpty);
    final icon = await http.get(
      base.resolve('/apps/icon?id=com.example.catalog&version=1.2.3'),
      headers: headers,
    );
    expect(icon.statusCode, HttpStatus.ok);
    expect(icon.headers[HttpHeaders.contentTypeHeader], contains('image/png'));
  });

  test('App Catalog skips a repair item without hiding valid games', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-catalog-repair-isolation-',
    );
    addTearDown(() => root.delete(recursive: true));
    final packages = Directory('${root.path}${Platform.pathSeparator}packages');
    final validPackage = Directory(
      '${packages.path}${Platform.pathSeparator}com.example.valid',
    );
    final repairPackage = Directory(
      '${packages.path}${Platform.pathSeparator}com.example.repair',
    );
    for (final package in [validPackage, repairPackage]) {
      await Directory(
        '${package.path}${Platform.pathSeparator}app',
      ).create(recursive: true);
      await File(
        '${package.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}index.html',
      ).writeAsString('<!doctype html>');
    }
    await File(
      '${validPackage.path}${Platform.pathSeparator}main.json',
    ).writeAsString(jsonEncode(_manifest(id: 'com.example.valid').toJson()));
    await File(
      '${repairPackage.path}${Platform.pathSeparator}main.json',
    ).writeAsString('{broken json');
    await File(
      '${repairPackage.path}${Platform.pathSeparator}icon.png',
    ).writeAsBytes(_pngBytes);

    final valid = _summary(validPackage.path, id: 'com.example.valid');
    final repair = _summary(
      repairPackage.path,
      id: 'com.example.repair',
      version: '9.9.9',
      manifestError: 'raw parser error',
    );
    final repository = GameLibraryRepository(
      () async => [repair, valid],
      initialGames: [repair, valid],
    );
    final server = GameCatalogServer(
      repository,
      GamePackageTransferService(libraryRoot: root),
      nicknameProvider: () => 'Tester',
    );
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    await server.start(port: port, token: '');
    addTearDown(server.stop);
    final base = Uri.parse('http://127.0.0.1:$port');

    final response = await http.get(base.resolve('/apps/list'));
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(response.body) as Map;
    expect(body['total'], 1);
    final offers = body['data']! as List;
    expect(offers, hasLength(1));
    expect((offers.single as Map)['id'], 'com.example.valid');

    final repairDownload = await http.get(
      base.resolve('/apps/download?id=com.example.repair&version=9.9.9'),
    );
    expect(repairDownload.statusCode, HttpStatus.notFound);
    final repairIcon = await http.get(
      base.resolve('/apps/icon?id=com.example.repair&version=9.9.9'),
    );
    expect(repairIcon.statusCode, HttpStatus.notFound);
  });
}

GameManifest _manifest({
  String id = 'com.example.catalog',
  String author = 'Publisher',
  String version = '1.2.3',
  DateTime? lastModifiedAt,
}) => GameManifest(
  id: id,
  name: 'Catalog Game',
  author: author,
  lastModifiedAt: lastModifiedAt ?? DateTime.utc(2026, 7, 26),
  remarks: 'Catalog test',
  version: version,
  sdkVersion: '1.0.0',
  appSdkVersion: '1.0.0',
  orientation: GameOrientation.landscape,
  modes: const {GameMode.solo},
  displayModes: const {GameDisplayMode.multiScreen},
  players: const GamePlayerLimits(min: 1, max: 1),
  tags: const [],
  entries: const GameEntriesManifest(
    game: 'app/index.html',
    controller: 'app/controller/index.html',
  ),
);

GameSummary _summary(
  String packagePath, {
  String id = 'com.example.catalog',
  String version = '1.2.3',
  String? manifestError,
}) => GameSummary(
  id: id,
  name: 'Catalog Game',
  version: version,
  author: 'Publisher',
  manifestError: manifestError,
  description: 'Catalog test',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多人多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(
    assetPath: 'app/index.html',
    statusLabel: 'SDK',
    packageRootFilePath: packagePath,
  ),
);

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
  'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<HttpServer> _startCatalogServer(
  Map<String, Object?> Function(HttpRequest request) listResponse,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    if (request.uri.path == '/apps/list') {
      request.response.write(jsonEncode(listResponse(request)));
    } else if (request.uri.path == '/apps/info') {
      request.response.write(
        jsonEncode({
          'catalogApiVersion': '2.0.0',
          'supportsGameRelay': false,
          'userUpload': {'supported': false},
        }),
      );
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  return server;
}

OnlineGameSource _sourceFor(HttpServer server, {required String id}) {
  return OnlineGameSource(
    id: id,
    name: id,
    host: Uri.parse('http://127.0.0.1:${server.port}'),
  );
}

Future<GameCatalogController> _catalogController(
  Directory root,
  List<OnlineGameSource> sources, {
  DateTime Function()? now,
}) async {
  final preferences = GameCatalogPreferences(libraryRoot: root);
  await preferences.save(GameCatalogPreferencesValue(sources: sources));
  final repository = GameLibraryRepository(
    () async => const <GameSummary>[],
    initialGames: const <GameSummary>[],
  );
  final controller = GameCatalogController(
    library: repository,
    transfer: GamePackageTransferService(libraryRoot: root),
    onImported: (_) async {},
    nicknameProvider: () => 'Tester',
    preferences: preferences,
    now: now,
  );
  await controller.initialize();
  return controller;
}
