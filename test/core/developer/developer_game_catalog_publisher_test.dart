import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/game_catalog_preferences.dart';
import 'package:playmesh/core/catalog/online_game_catalog.dart';
import 'package:playmesh/core/developer/developer_game_catalog_publisher.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';

void main() {
  test('Catalog 发布适配器只返回合格源且不会暴露读取或上传凭据', () async {
    final root = await Directory.systemTemp.createTemp('developer-publisher-');
    final preferences = GameCatalogPreferences(libraryRoot: root);
    final upload = GameCatalogDeclaration(
      catalogApiVersion: gameCatalogApiVersion,
      supportsGameRelay: false,
      userUpload: const GameCatalogUserUploadDeclaration(
        supported: true,
        protocolVersion: '1.0.0',
        path: '/api/user/uploads',
        maxUploadBytes: 1024 * 1024,
      ),
    );
    await preferences.save(
      GameCatalogPreferencesValue(
        sources: [
          OnlineGameSource(
            id: 'eligible',
            name: 'Eligible source',
            host: Uri.parse('https://catalog.example'),
            token: 'read-secret',
            uploadKey: 'upload-secret',
            declaration: upload,
          ),
          OnlineGameSource(
            id: 'disabled',
            name: 'Disabled source',
            host: Uri.parse('https://disabled.example'),
            token: 'disabled-read-secret',
            uploadKey: 'disabled-upload-secret',
            enabled: false,
            declaration: upload,
          ),
          OnlineGameSource(
            id: 'missing-key',
            name: 'Missing key',
            host: Uri.parse('https://missing-key.example'),
            token: 'another-read-secret',
            declaration: upload,
          ),
          OnlineGameSource(
            id: 'read-only',
            name: 'Read only',
            host: Uri.parse('https://read-only.example'),
            token: 'read-only-secret',
            declaration: const GameCatalogDeclaration(
              catalogApiVersion: gameCatalogApiVersion,
              supportsGameRelay: false,
            ),
          ),
        ],
      ),
    );
    final controller = GameCatalogController(
      library: GameLibraryRepository(() async => const []),
      transfer: GamePackageTransferService(),
      onImported: (_) async {},
      nicknameProvider: () => 'Developer',
      preferences: preferences,
    );
    addTearDown(controller.close);
    addTearDown(() => root.delete(recursive: true));

    final candidates = await GameCatalogDeveloperProjectPublisher(
      controller,
    ).listCandidates();

    expect(candidates, hasLength(1));
    expect(candidates.single.id, 'eligible');
    expect(candidates.single.name, 'Eligible source');
    expect(candidates.single.protocolVersion, '1.0.0');
    expect(candidates.single.maxUploadBytes, 1024 * 1024);
    final responseJson = jsonEncode(
      candidates.map((source) => source.toJson()).toList(),
    );
    expect(responseJson, isNot(contains('read-secret')));
    expect(responseJson, isNot(contains('upload-secret')));
    expect(responseJson, isNot(contains('token')));
    expect(responseJson, isNot(contains('uploadKey')));
    expect(responseJson, isNot(contains('host')));
  });
}
