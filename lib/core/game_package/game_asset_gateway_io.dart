import 'dart:io';

import 'package:flutter/services.dart';

import 'game_asset_gateway_contract.dart';
import '../storage/game_bucket_http.dart';
import '../storage/game_storage_service.dart';

const playmeshPublicAssetRoot = 'assets/playmesh-library/public';

Future<GameAssetGateway> startPlatformGameAssetGateway({
  String? gameRootAssetPath,
  String? gameRootFilePath,
  required String entryAssetPath,
  GameStorageService? storage,
}) async {
  if ((gameRootAssetPath == null) == (gameRootFilePath == null)) {
    throw const FormatException('游戏资源网关必须且只能指定一种包来源');
  }
  final assetRoot = gameRootAssetPath?.replaceAll(RegExp(r'/+$'), '');
  final fileRoot = gameRootFilePath == null
      ? null
      : Directory(gameRootFilePath).absolute;
  final entryRelativePath = fileRoot == null
      ? _assetEntryRelative(assetRoot!, entryAssetPath)
      : _fileEntryRelative(entryAssetPath);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final gateway = _IoGameAssetGateway(
    server: server,
    gameAppAssetPath: assetRoot == null ? null : '$assetRoot/app',
    gameAppDirectory: fileRoot == null
        ? null
        : Directory('${fileRoot.path}${Platform.pathSeparator}app'),
    entryRelativePath: entryRelativePath,
    storage: storage,
  );
  gateway.listen();
  return gateway;
}

class _IoGameAssetGateway implements GameAssetGateway {
  _IoGameAssetGateway({
    required this.server,
    this.gameAppAssetPath,
    this.gameAppDirectory,
    required this.entryRelativePath,
    this.storage,
  });

  final HttpServer server;
  final String? gameAppAssetPath;
  final Directory? gameAppDirectory;
  final String entryRelativePath;
  final GameStorageService? storage;

  @override
  Uri get entryUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/app/$entryRelativePath',
  );

  void listen() {
    server.listen((request) async {
      try {
        await _handle(request);
      } on Object {
        await _text(request.response, HttpStatus.internalServerError, '资源加载失败');
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final bucketStorage = storage;
    if (bucketStorage != null &&
        await handleGameBucketRequest(request, storage: bucketStorage)) {
      return;
    }
    if (request.method != 'GET') {
      await _text(request.response, HttpStatus.methodNotAllowed, '不支持的请求');
      return;
    }
    final path = request.uri.path;
    if (path.contains('..')) {
      await _text(request.response, HttpStatus.forbidden, '资源访问被拒绝');
      return;
    }
    if (path.startsWith('/app/')) {
      final relativePath = path.substring('/app/'.length);
      if (relativePath == entryRelativePath && relativePath.endsWith('.html')) {
        await _entryHtml(request.response);
        return;
      }
      final directory = gameAppDirectory;
      if (directory != null) {
        final file = _safeGameFile(directory, relativePath);
        if (!await file.exists()) {
          await _text(request.response, HttpStatus.notFound, '资源不存在');
          return;
        }
        request.response.headers.contentType = gameAssetContentType(file.path);
        await file.openRead().pipe(request.response);
        return;
      }
      await _asset(request.response, '$gameAppAssetPath/$relativePath');
      return;
    }
    if (path.startsWith('/playmesh/')) {
      await _asset(
        request.response,
        '$playmeshPublicAssetRoot/${path.substring('/playmesh/'.length)}',
      );
      return;
    }
    await _text(request.response, HttpStatus.notFound, '资源不存在');
  }

  Future<void> _entryHtml(HttpResponse response) async {
    final directory = gameAppDirectory;
    final html = directory == null
        ? await rootBundle.loadString('$gameAppAssetPath/$entryRelativePath')
        : await _safeGameFile(directory, entryRelativePath).readAsString();
    const appScript =
        '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>';
    const runtimeScript =
        '<script src="/playmesh/sdk/v1/playmesh.js"></script>';
    final runtimePattern = RegExp(
      r'''<script\b[^>]*\bsrc\s*=\s*(["'])/playmesh/sdk/v1/playmesh\.js(?:\?[^"']*)?\1[^>]*>\s*</script>''',
      caseSensitive: false,
    );
    final appPattern = RegExp(
      r'''<script\b[^>]*\bsrc\s*=\s*(["'])/playmesh/sdk/v1/playmesh-app\.js(?:\?[^"']*)?\1[^>]*>\s*</script>''',
      caseSensitive: false,
    );
    final runtimeMatch = runtimePattern.firstMatch(html);
    final appMatch = appPattern.firstMatch(html);
    final hasAppScript = appMatch != null;
    late final String injected;
    if (runtimeMatch != null) {
      if (appMatch == null) {
        injected = html.replaceFirstMapped(
          runtimePattern,
          (match) => '$appScript${match.group(0)}',
        );
      } else if (appMatch.start < runtimeMatch.start) {
        injected = html;
      } else {
        final withoutLateApp = html.replaceRange(
          appMatch.start,
          appMatch.end,
          '',
        );
        injected = withoutLateApp.replaceFirstMapped(
          runtimePattern,
          (match) => '$appScript${match.group(0)}',
        );
      }
    } else {
      final scripts = '${hasAppScript ? '' : appScript}$runtimeScript';
      injected = html.contains('</head>')
          ? html.replaceFirst('</head>', '$scripts</head>')
          : '$scripts$html';
    }
    response.headers.contentType = ContentType.html;
    response.write(injected);
    await response.close();
  }

  Future<void> _asset(HttpResponse response, String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      response.headers.contentType = gameAssetContentType(assetPath);
      response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await response.close();
    } on Object {
      await _text(response, HttpStatus.notFound, '资源不存在');
    }
  }

  @override
  Future<void> close() => server.close(force: true);
}

String _assetEntryRelative(String root, String entry) {
  final appRoot = '$root/app/';
  if (!entry.startsWith(appRoot)) {
    throw const FormatException('游戏入口必须位于当前游戏包的 app/ 内');
  }
  return entry.substring(appRoot.length);
}

String _fileEntryRelative(String entry) {
  final normalized = entry.replaceAll('\\', '/');
  if (!normalized.startsWith('app/') || normalized.contains('..')) {
    throw const FormatException('游戏入口必须位于当前游戏包的 app/ 内');
  }
  return normalized.substring('app/'.length);
}

File _safeGameFile(Directory appDirectory, String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized
          .split('/')
          .any((segment) => segment.isEmpty || segment == '..')) {
    throw const FormatException('游戏资源路径无效');
  }
  return File(
    '${appDirectory.path}${Platform.pathSeparator}'
    '${normalized.replaceAll('/', Platform.pathSeparator)}',
  );
}

ContentType gameAssetContentType(String path) {
  if (path.endsWith('.html')) return ContentType.html;
  if (path.endsWith('.js')) {
    return ContentType('text', 'javascript', charset: 'utf-8');
  }
  if (path.endsWith('.css')) {
    return ContentType('text', 'css', charset: 'utf-8');
  }
  if (path.endsWith('.json')) return ContentType.json;
  if (path.endsWith('.png')) return ContentType('image', 'png');
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  return ContentType.binary;
}

Future<void> _text(HttpResponse response, int status, String body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
}
