import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/game_package_layout.dart';
import '../game_sdk/sdk_feature_registry.dart';
import '../storage/game_bucket_http.dart';
import '../storage/game_storage_service.dart';
import 'game_asset_gateway_contract.dart';
import 'game_web_resource_provider_io.dart';
import 'game_web_resource_source.dart';

const playmeshPublicAssetRoot = 'assets/playmesh-library/public';

Future<GameAssetGateway> startPlatformGameAssetGateway({
  required GameWebResourceSource source,
  required String entryPath,
  String? gameSdkVersion,
  String? appSdkVersion,
  GameStorageService? storage,
}) async {
  final entry = playmeshGamePackageLayout.parseWebEntry(
    entryPath,
    field: '游戏入口',
    kind: GameWebEntryKind.html,
  );
  final resolvedGameSdkVersion = SdkFeatureRegistry.resolveGameSdkVersion(
    gameSdkVersion,
  );
  final resolvedAppSdkVersion = SdkFeatureRegistry.resolveAppSdkVersion(
    appSdkVersion,
  );
  final provider = await createGameWebResourceProvider(source);
  try {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _IoGameAssetGateway(
      server: server,
      provider: provider,
      validateRequestPaths: source.validateRequestPaths,
      entryPath: entry.path,
      entryQuery: entry.query,
      gameSdkVersion: resolvedGameSdkVersion,
      appSdkVersion: resolvedAppSdkVersion,
      storage: storage,
    );
    gateway.listen();
    return gateway;
  } on Object {
    await provider.close();
    rethrow;
  }
}

class _IoGameAssetGateway implements GameAssetGateway {
  _IoGameAssetGateway({
    required this.server,
    required this.provider,
    required this.validateRequestPaths,
    required this.entryPath,
    required this.entryQuery,
    required this.gameSdkVersion,
    required this.appSdkVersion,
    this.storage,
  });

  final HttpServer server;
  final GameWebResourceProvider provider;
  final bool validateRequestPaths;
  final String entryPath;
  final String? entryQuery;
  final String gameSdkVersion;
  final String appSdkVersion;
  final GameStorageService? storage;
  bool _closed = false;

  @override
  Uri get entryUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: playmeshGamePackageLayout.webRequestPath(entryPath),
    query: entryQuery,
  );

  void listen() {
    server.listen((request) async {
      try {
        await _handle(request);
      } on FormatException catch (error, stackTrace) {
        debugPrint(
          '[GameAssetGateway][warning] 请求被拒绝 '
          '${request.method} ${request.uri}: $error\n$stackTrace',
        );
        await gameWebResourceText(
          request.response,
          HttpStatus.forbidden,
          '资源访问被拒绝',
        );
      } on Object catch (error, stackTrace) {
        debugPrint(
          '[GameAssetGateway][error] 资源转发失败 '
          '${request.method} ${request.uri}: $error\n$stackTrace',
        );
        await gameWebResourceText(
          request.response,
          HttpStatus.internalServerError,
          '资源加载失败',
        );
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final bucketStorage = storage;
    if (bucketStorage != null &&
        await handleGameBucketRequest(request, storage: bucketStorage)) {
      return;
    }
    final relativePath = gameWebResourceRequestPath(
      request.uri,
      validatePath: validateRequestPaths,
      gatewayName: 'GameAssetGateway',
    );
    if (relativePath == null) {
      await gameWebResourceText(request.response, HttpStatus.notFound, '资源不存在');
      return;
    }
    final firstSegment = relativePath.split('/').first;
    if (firstSegment.toLowerCase() == 'bucket') {
      await gameWebResourceText(request.response, HttpStatus.notFound, '资源不存在');
      return;
    }
    if (firstSegment.toLowerCase() == 'playmesh') {
      if (firstSegment != 'playmesh') {
        await gameWebResourceText(
          request.response,
          HttpStatus.notFound,
          '资源不存在',
        );
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        await gameWebResourceText(
          request.response,
          HttpStatus.methodNotAllowed,
          '不支持的请求',
        );
        return;
      }
      final platformPath = relativePath.length == 'playmesh'.length
          ? ''
          : relativePath.substring('playmesh/'.length);
      await _platformAsset(request, platformPath);
      return;
    }
    if (relativePath == entryPath && request.method == 'GET') {
      await _entryHtml(request);
      return;
    }
    await provider.serve(request, relativePath);
  }

  Future<void> _platformAsset(HttpRequest request, String relativePath) async {
    if (relativePath.isEmpty) {
      await gameWebResourceText(request.response, HttpStatus.notFound, '资源不存在');
      return;
    }
    final liveSdk = SdkFeatureRegistry.sdkFileForPublicPath(
      relativePath,
      gameVersion: gameSdkVersion,
      appVersion: appSdkVersion,
    );
    if (liveSdk != null) {
      request.response.headers.contentType = gameWebResourceContentType(
        relativePath,
      );
      if (request.method != 'HEAD') request.response.write(liveSdk);
      await request.response.close();
      return;
    }
    try {
      final data = await rootBundle.load(
        '$playmeshPublicAssetRoot/$relativePath',
      );
      request.response.headers.contentType = gameWebResourceContentType(
        relativePath,
      );
      if (request.method != 'HEAD') {
        request.response.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      await request.response.close();
    } on Object {
      await gameWebResourceText(request.response, HttpStatus.notFound, '资源不存在');
    }
  }

  Future<void> _entryHtml(HttpRequest request) async {
    final response = request.response;
    late final LoadedGameWebResource? resource;
    try {
      resource = await provider.read(
        entryPath,
        query: request.uri.hasQuery ? request.uri.query : null,
      );
    } on GameWebResourceSessionExpired {
      await gameWebResourceText(response, HttpStatus.gone, '开发资源会话已过期');
      return;
    }
    if (resource == null) {
      await gameWebResourceText(response, HttpStatus.notFound, '资源不存在');
      return;
    }
    final html = utf8.decode(resource.bytes);
    response.headers.contentType = ContentType.html;
    response.write(_injectSdkScripts(html));
    await response.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close(force: true);
    await provider.close();
  }
}

String _injectSdkScripts(String html) {
  const appScript = '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>';
  const runtimeScript =
      '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>';
  final runtimePattern = RegExp(
    r'''<script\b[^>]*\bsrc\s*=\s*(["'])/playmesh/sdk/v1/playmesh-main\.js(?:\?[^"']*)?\1[^>]*>\s*</script>''',
    caseSensitive: false,
  );
  final appPattern = RegExp(
    r'''<script\b[^>]*\bsrc\s*=\s*(["'])/playmesh/sdk/v1/playmesh-app\.js(?:\?[^"']*)?\1[^>]*>\s*</script>''',
    caseSensitive: false,
  );
  final runtimeMatch = runtimePattern.firstMatch(html);
  final appMatch = appPattern.firstMatch(html);
  if (runtimeMatch != null) {
    if (appMatch == null) {
      return html.replaceFirstMapped(
        runtimePattern,
        (match) => '$appScript${match.group(0)}',
      );
    }
    if (appMatch.start < runtimeMatch.start) return html;
    final withoutLateApp = html.replaceRange(appMatch.start, appMatch.end, '');
    return withoutLateApp.replaceFirstMapped(
      runtimePattern,
      (match) => '$appScript${match.group(0)}',
    );
  }
  final scripts = '${appMatch == null ? appScript : ''}$runtimeScript';
  return html.contains('</head>')
      ? html.replaceFirst('</head>', '$scripts</head>')
      : '$scripts$html';
}
