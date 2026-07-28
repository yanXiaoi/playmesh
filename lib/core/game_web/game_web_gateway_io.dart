import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../network/lan_endpoint_resolver.dart';
import '../storage/game_bucket_http.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../capabilities/default_capability_plugins.dart';
import '../game_sdk/sdk_feature_registry.dart';
import '../localization/platform_game_ui_assets.dart';
import 'game_web_gateway_contract.dart';
import 'local_tunnel_gateway_contract.dart';

Future<GameWebGateway> startGameWebGateway({
  required String gameRootAssetPath,
  String? gameRootFilePath,
  required bool multiplayer,
  required String displayMode,
  required GameOrientation orientation,
  GameOrientation? controllerOrientation,
  String gameEntryPath = 'app/index.html',
  String controllerEntryPath = 'app/controller/index.html',
  required String gameId,
  String gameName = 'Playmesh 游戏',
  String? gameSdkVersion,
  String? appSdkVersion,
  List<String> requiredCapabilities = const [],
  List<String> controllerRequiredCapabilities = const [],
  Uri? coreEndpoint,
  String? joinCode,
  required String shareToken,
  required GameStorageService storage,
}) async {
  if (displayMode != 'multi_screen' &&
      displayMode != 'single_screen_multiplayer') {
    throw FormatException('不支持的浏览器分享显示模式: $displayMode');
  }
  if (!multiplayer && displayMode != 'multi_screen') {
    throw const FormatException('单机分享必须使用 multi_screen');
  }
  if (displayMode == 'single_screen_multiplayer' &&
      controllerOrientation == null) {
    throw const FormatException('单屏多人分享缺少控制器方向');
  }
  if (multiplayer && (coreEndpoint == null || joinCode?.isNotEmpty != true)) {
    throw const FormatException('联机分享缺少 Core 地址或联机码');
  }
  final resolvedGameSdkVersion = SdkFeatureRegistry.resolveGameSdkVersion(
    gameSdkVersion,
  );
  final resolvedAppSdkVersion = SdkFeatureRegistry.resolveAppSdkVersion(
    appSdkVersion,
  );
  final platformUiAssets = await PlatformGameUiAssets.load();
  _appRelativeHtmlEntry(gameEntryPath, field: 'entries.game');
  _appRelativeHtmlEntry(controllerEntryPath, field: 'entries.controller');
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  final gateway = _IoGameWebGateway(
    server: server,
    channelId: _randomChannelId(),
    gameRootAssetPath: gameRootAssetPath,
    gameRootFilePath: gameRootFilePath,
    multiplayer: multiplayer,
    displayMode: displayMode,
    orientation: orientation,
    controllerOrientation: controllerOrientation,
    gameEntryPath: gameEntryPath,
    controllerEntryPath: controllerEntryPath,
    gameId: gameId,
    gameName: gameName,
    gameSdkVersion: resolvedGameSdkVersion,
    appSdkVersion: resolvedAppSdkVersion,
    platformUiAssets: platformUiAssets,
    requiredCapabilities: List.unmodifiable(requiredCapabilities),
    controllerRequiredCapabilities: List.unmodifiable(
      controllerRequiredCapabilities,
    ),
    coreEndpoint: coreEndpoint?.replace(path: '/', query: null, fragment: null),
    joinCode: joinCode,
    shareToken: shareToken,
    storage: storage,
  );
  gateway.listen();
  return gateway;
}

class _IoGameWebGateway implements GameWebGateway {
  _IoGameWebGateway({
    required this.server,
    required this.channelId,
    required this.gameRootAssetPath,
    this.gameRootFilePath,
    required this.multiplayer,
    required this.displayMode,
    required this.orientation,
    required this.controllerOrientation,
    required this.gameEntryPath,
    required this.controllerEntryPath,
    required this.gameId,
    required this.gameName,
    required this.gameSdkVersion,
    required this.appSdkVersion,
    required this.platformUiAssets,
    required this.requiredCapabilities,
    required this.controllerRequiredCapabilities,
    required this.coreEndpoint,
    required this.joinCode,
    required this.shareToken,
    required this.storage,
  });

  final HttpServer server;
  final String channelId;
  final String gameRootAssetPath;
  final String? gameRootFilePath;
  final bool multiplayer;
  final String displayMode;
  final GameOrientation orientation;
  final GameOrientation? controllerOrientation;
  final String gameEntryPath;
  final String controllerEntryPath;
  final String gameId;
  final String gameName;
  final String gameSdkVersion;
  final String appSdkVersion;
  final PlatformGameUiAssets platformUiAssets;
  final List<String> requiredCapabilities;
  final List<String> controllerRequiredCapabilities;
  final Uri? coreEndpoint;
  final String? joinCode;
  final String shareToken;
  final GameStorageService storage;

  @override
  int get port => server.port;

  void listen() {
    server.listen((request) async {
      try {
        await _handle(request);
      } on Object catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('浏览器游戏加载失败: $error');
        await request.response.close();
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    if (await handleGameBucketRequest(
      request,
      storage: storage,
      uploadToken: shareToken,
    )) {
      return;
    }
    final expectedEntryPath = '/$_pageEntryPath';
    if (request.method == 'GET' && request.uri.path == expectedEntryPath) {
      if (request.uri.queryParameters['channelId'] != channelId ||
          request.uri.queryParameters['token'] != shareToken) {
        await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
        return;
      }
      await _browserPage(request);
      return;
    }
    if (request.method == 'GET' && request.uri.path == playmeshCoreTunnelPath) {
      await _coreTunnel(request);
      return;
    }
    if (request.method == 'GET' &&
        (request.uri.path.startsWith('/app/') ||
            request.uri.path.startsWith('/playmesh/'))) {
      await _asset(request);
      return;
    }
    await _text(request.response, HttpStatus.notFound, '页面不存在');
  }

  Future<void> _coreTunnel(HttpRequest request) async {
    if (!multiplayer || coreEndpoint == null) {
      await _text(request.response, HttpStatus.notFound, '连接入口不存在');
      return;
    }
    if (request.headers.value(playmeshShareTokenHeader) != shareToken) {
      await _text(request.response, HttpStatus.forbidden, '分享链接已失效');
      return;
    }
    final connectionTokens =
        request.headers
            .value(HttpHeaders.connectionHeader)
            ?.split(',')
            .map((value) => value.trim().toLowerCase())
            .toSet() ??
        const <String>{};
    if (!connectionTokens.contains('upgrade') ||
        request.headers.value(HttpHeaders.upgradeHeader) !=
            playmeshCoreTunnelProtocol) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    Socket? core;
    var detached = false;
    try {
      core = await Socket.connect(coreEndpoint!.host, coreEndpoint!.port);
      request.response.statusCode = HttpStatus.switchingProtocols;
      request.response.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, playmeshCoreTunnelProtocol);
      final joiningApp = await request.response.detachSocket(
        writeHeaders: true,
      );
      detached = true;
      await _bridgeSockets(joiningApp, core);
    } on Object {
      core?.destroy();
      if (!detached) {
        await _text(
          request.response,
          HttpStatus.serviceUnavailable,
          'Core 连接不可用',
        );
      }
    }
  }

  Future<void> _browserPage(HttpRequest request) async {
    final entryPath = multiplayer && displayMode == 'single_screen_multiplayer'
        ? controllerEntryPath
        : gameEntryPath;
    final relativePath = _appRelativeHtmlEntry(
      entryPath,
      field: entryPath == controllerEntryPath
          ? 'entries.controller'
          : 'entries.game',
    );
    var html = gameRootFilePath == null
        ? await rootBundle.loadString('$gameRootAssetPath/$entryPath')
        : await File(
            '${gameRootFilePath!}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
          ).readAsString();
    final lastSeparator = relativePath.lastIndexOf('/');
    final basePath = lastSeparator < 0
        ? '/app/'
        : '/app/${relativePath.substring(0, lastSeparator + 1)}';
    html = html.replaceFirst('<head>', '<head><base href="$basePath">');
    final browserConfig = jsonEncode({
      '_playmeshPlatformUi': {
        ...platformUiAssets.browserCatalog.toJson(),
        'actions': {
          'share': false,
          'restart': true,
          'logs': true,
          'fullscreen': true,
          'info': true,
          'performance': true,
          'exit': true,
        },
      },
      'mode': multiplayer ? 'multiplayer' : 'solo',
      if (multiplayer)
        'coreBase': Uri(
          scheme: 'http',
          host: request.requestedUri.host,
          port: coreEndpoint!.port,
          path: '/',
        ).toString(),
      if (multiplayer) 'joinCode': joinCode,
      'shareToken': shareToken,
      'gameId': gameId,
      'gameName': gameName,
      'orientation': _pageOrientation.manifestValue,
      'requiredCapabilities': _pageRequiredCapabilities,
      'availableCapabilities': defaultCapabilityDescriptors
          .where((definition) => definition.htmlSupported)
          .map((definition) => definition.code)
          .toList(),
      'capabilityRegistry': defaultCapabilityDescriptors
          .map((definition) => definition.toJson())
          .toList(),
      'bucketEndpoint': '/bucket',
      if (request.uri.queryParameters['playmeshNickname'] != null)
        'nickname': request.uri.queryParameters['playmeshNickname'],
    });
    var appSdkSource = '/playmesh/sdk/v1/playmesh-app.js';
    if (request.uri.queryParameters['playmeshApp'] == '1') {
      final appSdkUri = _localAppSdkUri(
        request.uri.queryParameters['playmeshAppSdkUrl'],
      ).replace(queryParameters: {'version': appSdkVersion});
      appSdkSource = const HtmlEscape(
        HtmlEscapeMode.attribute,
      ).convert(appSdkUri.toString());
    }
    html = html.replaceFirst(
      '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
      '<script>window.__PLAYMESH_BROWSER__=$browserConfig;</script>'
          '<script src="$appSdkSource"></script>'
          '<script src="/playmesh/sdk/v1/playmesh.js"></script>',
    );
    await _html(request.response, html);
  }

  GameOrientation get _pageOrientation =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerOrientation!
      : orientation;

  List<String> get _pageRequiredCapabilities =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerRequiredCapabilities
      : requiredCapabilities;

  String get _pageEntryPath =>
      multiplayer && displayMode == 'single_screen_multiplayer'
      ? controllerEntryPath
      : gameEntryPath;

  Future<void> _asset(HttpRequest request) async {
    final path = request.uri.path;
    if (path.contains('..')) {
      await _text(request.response, HttpStatus.forbidden, '资源访问被拒绝');
      return;
    }
    if (path.startsWith('/app/') && gameRootFilePath != null) {
      final relative = path.substring('/app/'.length);
      final file = File(
        '${gameRootFilePath!}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await file.exists()) {
        await _text(request.response, HttpStatus.notFound, '资源不存在');
        return;
      }
      request.response.headers.contentType = _contentType(file.path);
      await file.openRead().pipe(request.response);
      return;
    }
    if (path.startsWith('/playmesh/')) {
      final liveSdk = SdkFeatureRegistry.sdkFileForPublicPath(
        path.substring('/playmesh/'.length),
        gameVersion: gameSdkVersion,
        appVersion: appSdkVersion,
      );
      if (liveSdk != null) {
        request.response.headers.contentType = _contentType(path);
        request.response.write(liveSdk);
        await request.response.close();
        return;
      }
    }
    final assetPath = path.startsWith('/app/')
        ? '$gameRootAssetPath/app/${path.substring('/app/'.length)}'
        : 'assets/playmesh-library/public/'
              '${path.substring('/playmesh/'.length)}';
    try {
      final data = await rootBundle.load(assetPath);
      request.response.headers.contentType = _contentType(assetPath);
      request.response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await request.response.close();
    } on Object {
      await _text(request.response, HttpStatus.notFound, '资源不存在');
    }
  }

  @override
  Future<List<Uri>> shareLinks() async {
    final endpoints = await resolveLanEndpoints(port);
    final bases = endpoints.isEmpty
        ? [Uri(scheme: 'http', host: '127.0.0.1', port: port)]
        : endpoints;
    return bases
        .map(
          (base) => base.replace(
            path: '/$_pageEntryPath',
            queryParameters: {'channelId': channelId, 'token': shareToken},
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() => server.close(force: true);
}

String _randomChannelId() {
  final random = Random.secure();
  final bytes = List<int>.generate(9, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Future<void> _bridgeSockets(Socket left, Socket right) async {
  final completed = Completer<void>();
  var leftWriting = Future<void>.value();
  var rightWriting = Future<void>.value();
  late final StreamSubscription<Uint8List> leftSubscription;
  late final StreamSubscription<Uint8List> rightSubscription;

  void complete() {
    if (!completed.isCompleted) completed.complete();
  }

  StreamSubscription<Uint8List> pipe(
    Socket source,
    Socket destination,
    void Function(Future<void>) updateWriting,
  ) {
    late final StreamSubscription<Uint8List> subscription;
    subscription = source.listen(
      (chunk) {
        subscription.pause();
        destination.add(chunk);
        final writing = destination.flush();
        updateWriting(writing);
        unawaited(
          writing
              .then((_) {
                if (!completed.isCompleted) subscription.resume();
              })
              .catchError((Object _) {
                complete();
              }),
        );
      },
      onError: (_) => complete(),
      onDone: complete,
      cancelOnError: true,
    );
    return subscription;
  }

  leftSubscription = pipe(left, right, (value) => rightWriting = value);
  rightSubscription = pipe(right, left, (value) => leftWriting = value);
  await completed.future;
  await leftSubscription.cancel();
  await rightSubscription.cancel();
  try {
    await Future.wait([leftWriting, rightWriting]);
  } on Object {
    // 任一方向关闭后只需等待已提交写入结束，失败不覆盖原始断开原因。
  }
  left.destroy();
  right.destroy();
}

Uri _localAppSdkUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.path != '/playmesh-app.js' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('App 加入必须提供有效的本地 playmesh-app.js 地址');
  }
  return uri;
}

String _appRelativeHtmlEntry(String path, {required String field}) {
  final normalized = validateGamePackagePath(path, field: field);
  if (!normalized.startsWith('app/') ||
      !normalized.toLowerCase().endsWith('.html')) {
    throw FormatException('$field 必须指向 app/ 内的 HTML 文件');
  }
  return normalized.substring('app/'.length);
}

Future<void> _html(HttpResponse response, String body) async {
  response.headers.contentType = ContentType.html;
  response.write(body);
  await response.close();
}

Future<void> _text(HttpResponse response, int status, String body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
}

ContentType _contentType(String path) {
  if (path.endsWith('.html')) {
    return ContentType.html;
  }
  if (path.endsWith('.d.ts')) {
    return ContentType.text;
  }
  if (path.endsWith('.js')) {
    return ContentType('text', 'javascript', charset: 'utf-8');
  }
  if (path.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (path.endsWith('.json')) {
    return ContentType.json;
  }
  if (path.endsWith('.png')) {
    return ContentType('image', 'png');
  }
  return ContentType.binary;
}
