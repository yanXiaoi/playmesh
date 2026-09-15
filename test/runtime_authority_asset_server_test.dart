// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../runtime/src/lib/runtime/runtime_asset_server.dart';
import '../runtime/src/lib/runtime/runtime_config.dart';
import '../runtime/src/lib/runtime/runtime_package.dart';
import '../runtime/src/lib/runtime/runtime_platform_ui.dart';
import '../runtime/src/lib/runtime/runtime_storage.dart';

void main() {
  test('Runtime returns an empty authority script only to joiners', () async {
    final directory = await Directory.systemTemp.createTemp(
      'playmesh-runtime-authority-assets-',
    );
    final game = RuntimeGamePackage(
      files: {
        'index.html': Uint8List.fromList(utf8.encode('<html></html>')),
        'service/authority.mjs': Uint8List.fromList(
          utf8.encode('throw new Error("Authority code leaked");'),
        ),
        'static/player.js': Uint8List.fromList(
          utf8.encode('window.playerLoaded = true;'),
        ),
      },
      manifest: const RuntimeGameManifest(
        id: 'com.playmesh.runtime-authority-test',
        name: 'Runtime Authority Test',
        gameSdkVersion: '4.1.0',
        appSdkVersion: '3.3.0',
        orientation: 'landscape',
        multiplayer: true,
        displayMode: 'multi_screen',
        minPlayers: 1,
        maxPlayers: 4,
        gameEntry: 'index.html',
        authorityEntry: 'service/authority.mjs',
        requiredCapabilities: [],
        tags: [],
      ),
      config: const RuntimeConfig(
        gameAsset: 'assets/runtime/game.pmp',
        packageCodec: 'plain-zip',
        packageKeyId: null,
      ),
    );
    final server = RuntimeAssetServer(
      game: game,
      shareAccess: const RuntimeShareAccess.multiplayer(
        corePort: 39001,
        joinCode: 'ABC123',
        shareToken: 'share-token',
      ),
      browserCapabilityRegistry: const [],
      platformUi: _platformUi,
      storage: RuntimeStorage(
        gameId: game.manifest.id,
        file: File('${directory.path}/storage.json'),
      ),
    );
    addTearDown(() async {
      await server.close();
      await directory.delete(recursive: true);
    });
    await server.start();

    final authorityUri = server.entryUri.replace(
      path: '/service/authority.mjs',
      query: null,
    );
    final localAuthority = await _get(authorityUri);
    expect(localAuthority.$1, HttpStatus.ok);
    expect(localAuthority.$2, contains('Authority code leaked'));

    final accepted = await _postJson(server.loopbackInvitationUri, {
      'inviteToken': server.invitationToken,
    });
    expect(accepted.$1, HttpStatus.ok);

    final joinedAuthority = await _get(
      authorityUri.replace(queryParameters: const {'cacheBust': '1'}),
      cookies: accepted.$3,
    );
    expect(joinedAuthority.$1, HttpStatus.ok);
    expect(joinedAuthority.$2, isEmpty);
    expect(joinedAuthority.$3?.mimeType, 'text/javascript');

    final joinedPlayer = await _get(
      authorityUri.replace(path: '/static/player.js'),
      cookies: accepted.$3,
    );
    expect(joinedPlayer.$1, HttpStatus.ok);
    expect(joinedPlayer.$2, 'window.playerLoaded = true;');
  });
}

final _platformUi = RuntimePlatformUiCatalog.fromJson({
  'schemaVersion': 1,
  'fallbackLocale': 'zh-CN',
  'locales': [
    {
      'locale': 'zh-CN',
      'messages': {'common.close': '关闭'},
    },
  ],
});

Future<(int, String, ContentType?)> _get(
  Uri uri, {
  List<Cookie> cookies = const [],
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.cookies.addAll(cookies);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (response.statusCode, body, response.headers.contentType);
  } finally {
    client.close(force: true);
  }
}

Future<(int, String, List<Cookie>)> _postJson(
  Uri uri,
  Map<String, Object?> payload,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(payload));
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (response.statusCode, body, response.cookies);
  } finally {
    client.close(force: true);
  }
}
