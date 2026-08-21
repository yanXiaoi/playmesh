import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/game_catalog_preferences.dart';
import 'package:playmesh/core/catalog/online_game_catalog.dart';
import 'package:playmesh/core/developer/developer_installation_package_service_io.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('安装包中转目录只返回实时探测成功且协议兼容的启用源', () async {
    final root = await Directory.systemTemp.createTemp(
      'developer-installation-relay-catalog-',
    );
    final requestsByToken = <String, int>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final catalogOrigin = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final authorization =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final token = authorization.startsWith('Bearer ')
          ? authorization.substring('Bearer '.length)
          : '';
      requestsByToken.update(token, (count) => count + 1, ifAbsent: () => 1);

      if (request.uri.path != '/apps/info') {
        request.response.statusCode = HttpStatus.notFound;
      } else if (token == 'probe-failed-token') {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_declarationFor(token)));
      }
      await request.response.close();
    });

    final cachedCompatibleDeclaration = GameCatalogDeclaration.fromJson(
      _relayDeclaration(),
    );
    final preferences = GameCatalogPreferences(libraryRoot: root);
    await preferences.save(
      GameCatalogPreferencesValue(
        sources: [
          OnlineGameSource(
            id: 'compatible-source',
            name: 'Compatible Relay',
            host: catalogOrigin,
            token: 'compatible-token',
          ),
          OnlineGameSource(
            id: 'disabled-source',
            name: 'Disabled Relay',
            host: catalogOrigin,
            token: 'disabled-token',
            enabled: false,
          ),
          OnlineGameSource(
            id: 'probe-failed-source',
            name: 'Cached But Offline',
            host: catalogOrigin,
            token: 'probe-failed-token',
            declaration: cachedCompatibleDeclaration,
          ),
          OnlineGameSource(
            id: 'relay-disabled-source',
            name: 'No Relay Capability',
            host: catalogOrigin,
            token: 'relay-disabled-token',
          ),
          OnlineGameSource(
            id: 'bad-transport-source',
            name: 'Bad Transport',
            host: catalogOrigin,
            token: 'bad-transport-token',
          ),
          OnlineGameSource(
            id: 'bad-protocol-source',
            name: 'Bad Protocol',
            host: catalogOrigin,
            token: 'bad-protocol-token',
          ),
        ],
      ),
    );
    final controller = GameCatalogController(
      library: GameLibraryRepository(
        () async => const [],
        initialGames: const [],
      ),
      transfer: GamePackageTransferService(libraryRoot: root),
      onImported: (_) async {},
      nicknameProvider: () => 'Developer',
      preferences: preferences,
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => server.close(force: true));
    addTearDown(controller.close);

    final relayServers =
        await GameCatalogDeveloperInstallationPackageRelayServerCatalog(
          controller,
        ).inspect();

    expect(relayServers, hasLength(1));
    final relay = relayServers.single;
    expect(relay.id, 'compatible-source');
    expect(relay.name, 'Compatible Relay');
    expect(relay.address, catalogOrigin);
    expect(relay.token, 'compatible-token');
    expect(relay.latencyMs, isNotNull);
    expect(relay.latencyMs, greaterThanOrEqualTo(0));
    expect(requestsByToken['compatible-token'], 1);
    expect(requestsByToken['disabled-token'], isNull);
    expect(requestsByToken['probe-failed-token'], 1);
    expect(requestsByToken['relay-disabled-token'], 1);
    expect(requestsByToken['bad-transport-token'], 1);
    expect(requestsByToken['bad-protocol-token'], 1);
  });
}

Map<String, Object?> _declarationFor(String token) {
  if (token == 'relay-disabled-token') {
    return {
      'catalogApiVersion': gameCatalogApiVersion,
      'supportsGameRelay': false,
      'userUpload': {'supported': false},
    };
  }
  if (token == 'bad-transport-token') {
    return _relayDeclaration(transport: 'websocket');
  }
  if (token == 'bad-protocol-token') {
    return _relayDeclaration(protocolVersion: '2.0.0');
  }
  return _relayDeclaration();
}

Map<String, Object?> _relayDeclaration({
  String transport = 'playmesh-tcp-upgrade',
  String protocolVersion = '3.0.0',
}) => {
  'catalogApiVersion': gameCatalogApiVersion,
  'supportsGameRelay': true,
  'relay': {
    'protocolVersion': protocolVersion,
    'transport': transport,
    'publicBaseUrl': 'https://declared-relay.example.test',
    'hostPath': '/relay/v1/host',
    'clientPath': '/relay/v1/client',
    'maxConnectionsPerTunnel': 64,
  },
  'userUpload': {'supported': false},
};
