import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/game_catalog_publisher.dart';
import 'package:playmesh/core/game_package/game_package_share_files.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('一次安全打包并以 package multipart + UploadKey 逐源提交', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final events = <GameCatalogPublishStatus>[];
    late http.Request captured;
    final publisher = fixture.publisher((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'code': 'entered_review'}),
        HttpStatus.accepted,
      );
    });

    final result = await publisher.publish(
      game: fixture.game,
      sourceIds: ['source'],
      configuredSources: [fixture.source],
      onEvent: (event) => events.add(event.status),
    );

    expect(
      result.sources.single.status,
      GameCatalogPublishStatus.enteredReview,
    );
    expect(events, [
      GameCatalogPublishStatus.waiting,
      GameCatalogPublishStatus.uploading,
      GameCatalogPublishStatus.enteredReview,
    ]);
    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/user/uploads');
    expect(
      captured.headers[HttpHeaders.authorizationHeader],
      'UploadKey upload-SECRET',
    );
    final body = latin1.decode(captured.bodyBytes, allowInvalid: true);
    expect(body, contains('name="package"'));
    expect(body, contains('filename="Publish Game-v1.0.0.zip"'));
    expect(await fixture.shareFiles.directory.list().isEmpty, isTrue);
    final exposed = jsonEncode(result.toJson());
    expect(exposed, isNot(contains('upload-SECRET')));
    expect(exposed, isNot(contains('read-SECRET')));
  });

  test('鉴权和限流映射为稳定结果且保留 Retry-After', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);

    final invalid = await fixture
        .publisher((_) async => http.Response('', HttpStatus.unauthorized))
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );
    expect(
      invalid.sources.single.status,
      GameCatalogPublishStatus.invalidUploadKey,
    );

    final limited = await fixture
        .publisher(
          (_) async => http.Response(
            '',
            HttpStatus.tooManyRequests,
            headers: {'retry-after': '30'},
          ),
        )
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );
    expect(limited.sources.single.status, GameCatalogPublishStatus.rateLimited);
    expect(limited.sources.single.retryAfter, '30');
  });

  test('包校验失败保留具体原因且不会向工作区泄露源凭据', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final result = await fixture
        .publisher(
          (_) async => http.Response(
            jsonEncode({
              'code': 'package_rejected',
              'message':
                  'main.json.sdkVersion 必须显式声明为 4.1.0\n'
                  'upload-SECRET read-SECRET',
            }),
            HttpStatus.unprocessableEntity,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        )
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );

    final source = result.sources.single;
    expect(source.status, GameCatalogPublishStatus.packageValidationFailed);
    expect(source.detail, contains('main.json.sdkVersion 必须显式声明为 4.1.0'));
    expect(source.detail, isNot(contains('SECRET')));
    expect(result.toJson().toString(), isNot(contains('SECRET')));
  });

  test('所有权与版本冲突映射 code 和安全的当前最高版本', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final cases = {
      'game_ownership_conflict': GameCatalogPublishStatus.gameOwnershipConflict,
      'version_already_exists': GameCatalogPublishStatus.versionAlreadyExists,
      'version_must_increase': GameCatalogPublishStatus.versionMustIncrease,
    };
    for (final entry in cases.entries) {
      final result = await fixture
          .publisher(
            (_) async => http.Response(
              jsonEncode({
                'code': entry.key,
                'currentHighestVersion': '2.3.4',
                'message': 'upload-SECRET read-SECRET',
              }),
              HttpStatus.conflict,
            ),
          )
          .publish(
            game: fixture.game,
            sourceIds: ['source'],
            configuredSources: [fixture.source],
          );
      expect(result.sources.single.status, entry.value);
      if (entry.key == 'game_ownership_conflict') {
        expect(result.sources.single.currentHighestVersion, isNull);
      } else {
        expect(result.sources.single.currentHighestVersion, '2.3.4');
      }
      expect(result.toString(), isNot(contains('SECRET')));
    }
  });

  test('响应体限制固定为 64 KiB，超限服务端详情不会进入结果', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    expect(GameCatalogPublisher.requestTimeout, const Duration(seconds: 30));
    expect(GameCatalogPublisher.maxResponseBytes, 64 * 1024);
    final marker = 'server-read-SECRET-upload-SECRET';
    final result = await fixture
        .publisher(
          (_) async => http.Response(
            jsonEncode({
              'code': 'version_already_exists',
              'message':
                  '${List.filled(GameCatalogPublisher.maxResponseBytes, 'x').join()}$marker',
            }),
            HttpStatus.conflict,
          ),
        )
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );

    expect(
      result.sources.single.status,
      GameCatalogPublishStatus.packageValidationFailed,
    );
    expect(result.toString(), isNot(contains(marker)));
  });

  test('包校验失败、源超限和网络异常互不伪装为成功', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var requests = 0;
    final tinySource = fixture.sourceWith(maxUploadBytes: 1);
    final oversized = await fixture
        .publisher((_) async {
          requests += 1;
          return http.Response('', HttpStatus.accepted);
        })
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [tinySource],
        );
    expect(
      oversized.sources.single.status,
      GameCatalogPublishStatus.packageTooLarge,
    );
    expect(requests, 0);

    final network = await fixture
        .publisher((_) async => throw const SocketException('offline'))
        .publish(
          game: fixture.game,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );
    expect(
      network.sources.single.status,
      GameCatalogPublishStatus.networkFailed,
    );

    final invalidGame = fixture.gameAt(
      '${fixture.root.path}${Platform.pathSeparator}outside',
    );
    final invalid = await fixture
        .publisher((_) async {
          requests += 1;
          return http.Response('', HttpStatus.accepted);
        })
        .publish(
          game: invalidGame,
          sourceIds: ['source'],
          configuredSources: [fixture.source],
        );
    expect(
      invalid.sources.single.status,
      GameCatalogPublishStatus.packageValidationFailed,
    );
    expect(requests, 0);
  });

  test('未知/不合格源明确失败，重试只提交先前失败源', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final disabled = fixture.sourceWith(id: 'disabled', enabled: false);
    final classified = await fixture
        .publisher((_) async => http.Response('', HttpStatus.accepted))
        .publish(
          game: fixture.game,
          sourceIds: ['unknown', 'disabled'],
          configuredSources: [disabled],
        );
    expect(classified.sources.map((result) => result.status), [
      GameCatalogPublishStatus.unknownSource,
      GameCatalogPublishStatus.sourceNotEligible,
    ]);

    final failedSource = fixture.sourceWith(
      id: 'failed',
      host: Uri.parse('https://offline.example'),
    );
    final partial = await fixture
        .publisher((request) async {
          if (request.url.host == 'offline.example') {
            throw const SocketException('offline');
          }
          return http.Response('', HttpStatus.accepted);
        })
        .publish(
          game: fixture.game,
          sourceIds: ['source', 'failed'],
          configuredSources: [fixture.source, failedSource],
        );
    expect(partial.sources.map((result) => result.status), [
      GameCatalogPublishStatus.enteredReview,
      GameCatalogPublishStatus.networkFailed,
    ]);
    expect(fixture.transfer.exports, 1);

    final requestedHosts = <String>[];
    final retried = await fixture
        .publisher((request) async {
          requestedHosts.add(request.url.host);
          return http.Response('', HttpStatus.accepted);
        })
        .retryFailures(
          game: fixture.game,
          previous: partial,
          configuredSources: [fixture.source, failedSource],
        );
    expect(requestedHosts, ['offline.example']);
    expect(retried.sources.single.sourceId, 'failed');
    expect(
      retried.sources.single.status,
      GameCatalogPublishStatus.enteredReview,
    );
    expect(fixture.transfer.exports, 2);
    expect(await fixture.shareFiles.directory.list().isEmpty, isTrue);
  });
}

typedef _Handler = Future<http.Response> Function(http.Request request);

class _Fixture {
  _Fixture({
    required this.root,
    required this.game,
    required this.transfer,
    required this.shareFiles,
    required this.source,
  });

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('catalog-publish-');
    final package = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.example.publish',
    );
    final app = Directory('${package.path}${Platform.pathSeparator}app');
    await app.create(recursive: true);
    await File(
      '${app.path}${Platform.pathSeparator}index.html',
    ).writeAsString('<!doctype html>');
    await File(
      '${package.path}${Platform.pathSeparator}main.json',
    ).writeAsString(
      jsonEncode({
        'id': 'com.example.publish',
        'name': 'Publish Game',
        'author': 'Publisher',
        'version': '1.0.0',
        'sdkVersion': '4.1.0',
        'appSdkVersion': '3.3.0',
        'orientation': 'landscape',
        'modes': ['solo'],
        'displayModes': ['multi_screen'],
        'players': {'min': 1, 'max': 1},
        'entries': {'game': 'index.html'},
      }),
    );
    final game = _game(package.path);
    final transfer = _CountingTransfer(libraryRoot: root);
    final shareFiles = GamePackageShareFiles(
      temporaryRoot: Directory(
        '${root.path}${Platform.pathSeparator}temporary',
      ),
    );
    final fixture = _Fixture(
      root: root,
      game: game,
      transfer: transfer,
      shareFiles: shareFiles,
      source: _source(),
    );
    return fixture;
  }

  final Directory root;
  final GameSummary game;
  final _CountingTransfer transfer;
  final GamePackageShareFiles shareFiles;
  final OnlineGameSource source;

  GameCatalogPublisher publisher(_Handler handler) => GameCatalogPublisher(
    transfer: transfer,
    shareFiles: shareFiles,
    clientFactory: () => MockClient(handler),
  );

  OnlineGameSource sourceWith({
    String id = 'source',
    bool enabled = true,
    int maxUploadBytes = 64 * 1024 * 1024,
    Uri? host,
  }) => _source(
    id: id,
    enabled: enabled,
    maxUploadBytes: maxUploadBytes,
    host: host,
  );

  GameSummary gameAt(String path) => _game(path);

  Future<void> close() => root.delete(recursive: true);
}

OnlineGameSource _source({
  String id = 'source',
  bool enabled = true,
  int maxUploadBytes = 64 * 1024 * 1024,
  Uri? host,
}) => OnlineGameSource(
  id: id,
  name: 'Local Source',
  host: host ?? Uri.parse('https://source.example'),
  token: 'read-SECRET',
  uploadKey: 'upload-SECRET',
  enabled: enabled,
  declaration: GameCatalogDeclaration(
    catalogApiVersion: gameCatalogApiVersion,
    name: 'Official Source',
    supportsGameRelay: false,
    userUpload: GameCatalogUserUploadDeclaration(
      supported: true,
      protocolVersion: '1.0.0',
      path: '/api/user/uploads',
      maxUploadBytes: maxUploadBytes,
    ),
  ),
);

class _CountingTransfer extends GamePackageTransferService {
  _CountingTransfer({required super.libraryRoot});

  int exports = 0;

  @override
  Future<File> exportPackage(
    GameSummary game,
    File destination, {
    bool validate = true,
  }) {
    exports += 1;
    return super.exportPackage(game, destination, validate: validate);
  }
}

GameSummary _game(String packagePath) => GameSummary(
  id: 'com.example.publish',
  name: 'Publish Game',
  version: '1.0.0',
  author: 'Publisher',
  description: '',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(
    gameEntryPath: 'index.html',
    statusLabel: 'SDK',
    packageRootFilePath: packagePath,
  ),
);
