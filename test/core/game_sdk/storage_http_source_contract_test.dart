import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('标准 JSON 存储固定走同源 HTTP 且不存在旧 WS fallback', () {
    final feature = File(
      'lib/core/game_sdk/features/game/game_storage_lifecycle_feature.dart',
    ).readAsStringSync();
    final generated = File(
      'assets/playmesh-library/public/sdk/v1/playmesh-main.js',
    ).readAsStringSync();
    final runtime = File(
      'lib/core/game_sdk/features/game/game_runtime_feature.dart',
    ).readAsStringSync();
    final generatedTypeScript = File(
      'assets/playmesh-library/sdk-src/playmesh.ts',
    ).readAsStringSync();
    final httpRoute = File(
      'lib/core/storage/game_bucket_http.dart',
    ).readAsStringSync();

    for (final source in [feature, generated, generatedTypeScript]) {
      expect(source, contains('/bucket/_playmesh-json/v1'));
      expect(source, contains('X-Playmesh-Content-Sha256'));
      expect(source, contains('credentials: "same-origin"'));
      expect(source, contains('global.crypto.subtle.digest("SHA-256"'));
      expect(source, contains('new global.XMLHttpRequest()'));
      expect(source, contains('xhr.open(method, url, false)'));
      expect(source, contains('X-Playmesh-Storage-Sync'));
      expect(source, isNot(contains('__playmeshStorageRequest')));
      expect(source, isNot(contains('__playmeshStorageResponse')));
      expect(source, isNot(contains('browserStoragePending')));
      expect(source, isNot(contains('browser-storage-')));
      expect(source, isNot(contains('post("storage.')));
      expect(source, isNot(contains('sendBrowserTransport("storage.')));
    }
    expect(runtime, isNot(contains('__playmeshStorageResponse')));
    expect(httpRoute, contains("const {'GET', 'PUT', 'DELETE'}"));
    expect(httpRoute, contains("const {'GET', 'PUT'}"));
    expect(httpRoute, isNot(contains('_executeStandardJsonOperation')));
    expect(httpRoute, isNot(contains('标准 JSON 存储只接受 POST')));
  });

  test('同步 Bucket 只增加精确公开方法且旧异步表面保持完整', () {
    final declaration = File(
      'assets/playmesh-library/public/sdk/v1/playmesh-main.d.ts',
    ).readAsStringSync();
    final feature = File(
      'lib/core/game_sdk/features/game/game_core_feature.dart',
    ).readAsStringSync();
    final generated = File(
      'assets/playmesh-library/public/sdk/v1/playmesh-main.js',
    ).readAsStringSync();

    for (final source in [declaration, feature]) {
      for (final member in [
        'getData',
        'setData',
        'getDataSync',
        'setDataSync',
        'removeData',
        'clearData',
        'upload',
      ]) {
        expect(
          source,
          matches(RegExp('\\b$member(?:<[^>]+>)?\\s*\\(')),
          reason: member,
        );
      }
    }
    for (final source in [declaration, feature, generated]) {
      expect(source, isNot(matches(RegExp(r'\bgetSync\s*\('))));
      expect(source, isNot(matches(RegExp(r'\bsetSync\s*\('))));
      expect(source, isNot(matches(RegExp(r'\bgetBucketSync\s*\('))));
    }
  });

  test('生产源不包含旧 WS JSON 存储协议或宿主接收器', () {
    final sources = <String>[
      ..._productionFiles('lib/core/game_sdk', const {'.dart'}),
      ..._productionFiles('lib/core/storage', const {'.dart'}),
      ..._productionFiles('go-core', const {'.go'}),
      ..._productionFiles('assets/playmesh-library/public/sdk/v1', const {
        '.js',
        '.ts',
      }),
      ..._productionFiles('assets/playmesh-library/sdk-src', const {
        '.js',
        '.ts',
      }),
    ];
    final combined = sources.join('\n');
    for (final forbidden in [
      '__playmeshStorageRequest',
      '__playmeshStorageResponse',
      'browserStoragePending',
      'settleBrowserStorage',
      '_routeRemoteStorage',
      '_handleRemoteStorageRequest',
      '_handleRemoteStorageResponse',
      '_executeStandardJsonOperation',
    ]) {
      expect(combined, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('Core main WebSocket 保持 64 KiB 且不代理标准存储 HTTP', () {
    final handler = File(
      'go-core/internal/session/handler.go',
    ).readAsStringSync();
    expect(handler, contains('const maxMessageBytes = 64 * 1024'));
    expect(handler, contains('connection.SetReadLimit(maxMessageBytes)'));

    final coreSources = Directory('go-core')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.go'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(coreSources, isNot(contains('/bucket/_playmesh-json/v1')));
    expect(coreSources, isNot(contains('X-Playmesh-Content-Sha256')));
  });
}

Iterable<String> _productionFiles(String root, Set<String> extensions) sync* {
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!extensions.any(entity.path.endsWith)) continue;
    yield entity.readAsStringSync();
  }
}
