import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  test('标准包定长和 HTTP/1.1 chunked 流式导入均保留 sidecar/history', () async {
    final library = await Directory.systemTemp.createTemp(
      'package-import-gateway-',
    );
    addTearDown(() => library.delete(recursive: true));
    final packages = Directory(
      '${library.path}${Platform.pathSeparator}packages',
    );
    final provisioning = ProjectProvisioningService(projectsRoot: packages);
    const gameId = 'com.playmesh.game.gimportfixture';
    final provisioned = await provisioning.createProject(
      gameId: gameId,
      name: 'Import Fixture',
      kind: PlaymeshProjectKind.gdevelop,
      additionalMetadata: const {
        'fileIdentifiers': ['visual-file-a'],
      },
    );
    final historyState = File(
      '${provisioned.root.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}gdevelop${Platform.pathSeparator}history'
      '${Platform.pathSeparator}state.json',
    );
    await historyState.parent.create(recursive: true);
    await historyState.writeAsString('{"revision":4}');
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final transfer = GamePackageTransferService(libraryRoot: library);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: packages,
      projectProvisioning: provisioning,
      packageTransfer: transfer,
    );
    final port = await _freePort();
    const token = 'package-import-gateway-token';
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'packageimporttest',
      catalog: catalog,
      packageTransfer: transfer,
      currentAuthor: () => 'Local Publisher',
    );
    addTearDown(gateway.close);

    final response = await http.post(
      Uri.parse('http://127.0.0.1:$port/dev/api/packages/import'),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.contentTypeHeader: 'application/zip',
        'X-Playmesh-Client-ID': 'visual-gdevelop-test',
      },
      body: _packageZip(gameId),
    );

    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(response.body) as Map;
    expect(body['committed'], isTrue);
    expect(body['project']['id'], gameId);
    expect(body['preservedDirectories'], ['data', 'cache', '.playmesh']);
    expect(await historyState.readAsString(), '{"revision":4}');
    final metadata =
        jsonDecode(
              await File(
                '${provisioned.root.path}${Platform.pathSeparator}.playmesh'
                '${Platform.pathSeparator}project.json',
              ).readAsString(),
            )
            as Map;
    expect(metadata['kind'], 'gdevelop');
    expect(metadata['gameId'], gameId);
    expect(
      await File(
        '${provisioned.root.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}index.html',
      ).exists(),
      isTrue,
    );
    final installedManifest =
        jsonDecode(
              await File(
                '${provisioned.root.path}${Platform.pathSeparator}main.json',
              ).readAsString(),
            )
            as Map;
    expect(installedManifest['id'], gameId);
    expect(installedManifest['author'], 'Local Publisher');

    final httpClient = HttpClient();
    addTearDown(httpClient.close);
    final chunkedRequest = await httpClient.postUrl(
      Uri.parse('http://127.0.0.1:$port/dev/api/packages/import'),
    );
    chunkedRequest.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.contentTypeHeader, 'application/zip')
      ..set('X-Playmesh-Client-ID', 'visual-gdevelop-chunked-test');
    expect(chunkedRequest.contentLength, -1);
    final zipBytes = _packageZip(gameId);
    for (var offset = 0; offset < zipBytes.length; offset += 17) {
      final end = offset + 17 < zipBytes.length ? offset + 17 : zipBytes.length;
      chunkedRequest.add(zipBytes.sublist(offset, end));
    }
    final chunkedResponse = await chunkedRequest.close();
    final chunkedBody =
        jsonDecode(await utf8.decoder.bind(chunkedResponse).join()) as Map;
    expect(chunkedResponse.statusCode, HttpStatus.ok);
    expect(chunkedBody['committed'], isTrue);
    expect(chunkedBody['project']['id'], gameId);
    expect(await historyState.readAsString(), '{"revision":4}');
  });

  test('上传只在新建持久项目时要求 Android applicationId', () async {
    final library = await Directory.systemTemp.createTemp(
      'package-import-new-project-id-',
    );
    addTearDown(() => library.delete(recursive: true));
    final packages = Directory(
      '${library.path}${Platform.pathSeparator}packages',
    );
    final provisioning = ProjectProvisioningService(projectsRoot: packages);
    const legacyId = 'com.example.legacy-game';
    await provisioning.createProject(
      gameId: legacyId,
      name: 'Legacy Game',
      kind: PlaymeshProjectKind.source,
    );
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final transfer = GamePackageTransferService(libraryRoot: library);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: packages,
      projectProvisioning: provisioning,
      packageTransfer: transfer,
    );
    final port = await _freePort();
    const token = 'package-import-id-token';
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: 'packageimportidtest',
      catalog: catalog,
      packageTransfer: transfer,
      currentAuthor: () => 'Local Publisher',
    );
    addTearDown(gateway.close);
    final endpoint = Uri.parse(
      'http://127.0.0.1:$port/dev/api/packages/import',
    );
    const headers = {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.contentTypeHeader: 'application/zip',
    };

    final invalidNew = await http.post(
      endpoint,
      headers: headers,
      body: _packageZip('com.example.new-game'),
    );
    expect(
      invalidNew.statusCode,
      HttpStatus.badRequest,
      reason: invalidNew.body,
    );

    const androidId = 'Com.Example.Upload_2';
    final validNew = await http.post(
      endpoint,
      headers: headers,
      body: _packageZip(androidId),
    );
    expect(validNew.statusCode, HttpStatus.ok, reason: validNew.body);
    expect(jsonDecode(validNew.body)['project']['id'], androidId);

    final legacyUpdate = await http.post(
      endpoint,
      headers: headers,
      body: _packageZip(legacyId),
    );
    expect(legacyUpdate.statusCode, HttpStatus.ok, reason: legacyUpdate.body);
  });
}

List<int> _packageZip(String gameId) {
  final archive = Archive();
  final manifest = utf8.encode(
    jsonEncode({
      'id': gameId,
      'name': 'Visual Import Fixture',
      'author': 'Browser Placeholder',
      'lastModifiedAt': 0,
      'remarks': '',
      'version': '1.0.0',
      'sdkVersion': '4.1.0',
      'appSdkVersion': '3.3.0',
      'orientation': 'landscape',
      'modes': ['solo'],
      'displayModes': ['multi_screen'],
      'players': {'min': 1, 'max': 1},
      'entries': {'game': 'index.html'},
      'tags': <String>[],
    }),
  );
  final index = utf8.encode('<!doctype html><title>Visual Import</title>');
  archive
    ..addFile(ArchiveFile('main.json', manifest.length, manifest))
    ..addFile(ArchiveFile('app/index.html', index.length, index));
  return ZipEncoder().encode(archive)!;
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
