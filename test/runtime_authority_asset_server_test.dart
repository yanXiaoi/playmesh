// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/profile/avatar_image.dart';

import '../runtime/src/lib/runtime/runtime_asset_server.dart';
import '../runtime/src/lib/runtime/runtime_config.dart';
import '../runtime/src/lib/runtime/runtime_package.dart';
import '../runtime/src/lib/runtime/runtime_platform_ui.dart';
import '../runtime/src/lib/runtime/runtime_storage.dart';
import 'core/storage/bucket_http_range_test_support.dart';

void main() {
  late RuntimeAssetServer server;

  setUp(() async {
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
    server = RuntimeAssetServer(
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
  });

  registerBucketHttpRangeTests(
    upload: (bytes) async => server.entryUri.resolve(
      await server.storage.upload(
        bucket: 'karaoke-media',
        originalName: 'video.mp4',
        data: Stream.value(bytes),
        contentLength: bytes.length,
      ),
    ),
    uploadAvatar: (bytes, digest) async => server.entryUri.resolve(
      await server.storage.writeUserAvatar(
        playerId: 'u_range',
        pngBytes: bytes,
        sha256Digest: digest,
      ),
    ),
  );

  test('Runtime returns an empty authority script only to joiners', () async {
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

  test(
    'Runtime Bucket HEAD returns GET metadata for local and joined pages',
    () async {
      final bytes = <int>[0, 1, 255, 7];
      final path = await server.storage.upload(
        bucket: 'karaoke-media',
        originalName: 'video.mp4',
        data: Stream.value(bytes),
        contentLength: bytes.length,
      );
      final uri = server.entryUri.resolve(path);
      final get = await http.get(uri);
      final head = await http.head(uri);
      expect(get.statusCode, HttpStatus.ok);
      expect(get.bodyBytes, bytes);
      expect(head.statusCode, HttpStatus.ok);
      expect(head.bodyBytes, isEmpty);
      expect(head.headers[HttpHeaders.contentTypeHeader], 'video/mp4');
      expect(head.headers[HttpHeaders.contentLengthHeader], '${bytes.length}');
      for (final header in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.cacheControlHeader,
        'x-content-type-options',
      ]) {
        expect(head.headers[header], get.headers[header], reason: header);
      }

      final accepted = await _postJson(server.loopbackInvitationUri, {
        'inviteToken': server.invitationToken,
      });
      expect(accepted.$1, HttpStatus.ok);
      final headers = {
        HttpHeaders.cookieHeader: accepted.$3
            .map((cookie) => '${cookie.name}=${cookie.value}')
            .join('; '),
      };
      final joined = await http.head(uri, headers: headers);
      expect(joined.statusCode, HttpStatus.ok);
      expect(
        joined.headers[HttpHeaders.contentLengthHeader],
        '${bytes.length}',
      );
      expect(joined.bodyBytes, isEmpty);
      final joinedRange = await http.get(
        uri,
        headers: {...headers, 'Range': 'bytes=1-2'},
      );
      expect(joinedRange.statusCode, HttpStatus.partialContent);
      expect(joinedRange.bodyBytes, bytes.sublist(1, 3));
      expect(
        joinedRange.headers[HttpHeaders.contentRangeHeader],
        'bytes 1-2/4',
      );
      server.revokeSharing();
      final revoked = await http.head(uri, headers: headers);
      expect(revoked.statusCode, HttpStatus.forbidden);
      expect(revoked.bodyBytes, isEmpty);
      final revokedRange = await http.get(
        uri,
        headers: {...headers, 'Range': 'bytes=1-2'},
      );
      expect(revokedRange.statusCode, HttpStatus.forbidden);
      expect(revokedRange.headers[HttpHeaders.contentRangeHeader], isNull);
    },
  );

  test(
    'Runtime Bucket HEAD keeps missing, invalid and private files hidden',
    () async {
      for (final path in [
        '/bucket/karaoke-media',
        '/bucket/karaoke-media/1790055457170.mp4',
        '/bucket/karaoke-media/%2Fprivate.mp4',
        '/bucket/_sys-private/1790055457170.mp4',
        '/bucket/save/save.json',
      ]) {
        final head = await http.head(server.entryUri.resolve(path));
        expect(head.statusCode, HttpStatus.notFound, reason: path);
        expect(head.bodyBytes, isEmpty, reason: path);
      }
    },
  );

  test('Runtime avatar HEAD preserves conditional ETag responses', () async {
    final avatar = await AvatarImage.normalize(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l'
        'EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    final path = await server.storage.writeUserAvatar(
      playerId: 'u_avatar',
      pngBytes: avatar.pngBytes,
      sha256Digest: avatar.sha256,
    );
    final uri = server.entryUri.resolve(path);
    final get = await http.get(uri);
    final head = await http.head(uri);
    expect(head.statusCode, HttpStatus.ok);
    expect(head.bodyBytes, isEmpty);
    expect(head.headers[HttpHeaders.contentTypeHeader], 'image/png');
    expect(
      head.headers[HttpHeaders.contentLengthHeader],
      '${avatar.pngBytes.length}',
    );
    expect(head.headers[HttpHeaders.cacheControlHeader], 'private, no-cache');
    expect(
      head.headers[HttpHeaders.etagHeader],
      get.headers[HttpHeaders.etagHeader],
    );
    final cached = await http.head(
      uri,
      headers: {
        HttpHeaders.ifNoneMatchHeader: get.headers[HttpHeaders.etagHeader]!,
      },
    );
    expect(cached.statusCode, HttpStatus.notModified);
    expect(cached.bodyBytes, isEmpty);
    expect(
      cached.headers[HttpHeaders.etagHeader],
      head.headers[HttpHeaders.etagHeader],
    );
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
