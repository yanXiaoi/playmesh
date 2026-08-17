import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../game_package/game_package_transfer_service.dart';
import '../../game_package/game_web_resource_provider_io.dart';
import '../../game_package/game_web_resource_source.dart';
import '../../../models/game_package_layout.dart';
import '../developer_run_controller.dart';

/// A validated package staged outside the installed game library and exposed
/// only over a credential-protected loopback HTTP server.
class StagedDevelopmentSource {
  StagedDevelopmentSource._({
    required this.previewId,
    required this.gameId,
    required this.generation,
    required this.expiresAt,
    required this.runtimeDeclaration,
    required this.root,
    required this.appDirectory,
    required this.server,
    required this._credential,
  });

  final String previewId;
  final String gameId;
  final int generation;
  final DateTime expiresAt;
  final DeveloperRuntimeDeclaration runtimeDeclaration;
  final Directory root;
  final Directory appDirectory;
  final HttpServer server;
  final String _credential;
  Timer? _expiryTimer;
  bool _closed = false;

  Uri get resourceBaseUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/',
  );

  DeveloperResourceSession get resourceSession => DeveloperResourceSession(
    projectId: gameId,
    resourceBaseUri: resourceBaseUri,
    credential: _credential,
    expiresAt: expiresAt,
    runtimeDeclaration: runtimeDeclaration,
  );

  static Future<StagedDevelopmentSource> create({
    required String previewId,
    required String gameId,
    required int generation,
    required DateTime expiresAt,
    required DeveloperRuntimeDeclaration runtimeDeclaration,
    required ValidatedGamePackage package,
    required GamePackageTransferService packageTransfer,
    Directory? temporaryRoot,
    String? credential,
  }) async {
    final root = await (temporaryRoot ?? Directory.systemTemp).createTemp(
      'playmesh-development-preview-',
    );
    final packageDirectory = Directory(
      '${root.path}${Platform.pathSeparator}package',
    );
    HttpServer? server;
    try {
      await packageTransfer.commitPackage(package, packageDirectory);
      final app = Directory(
        '${packageDirectory.path}${Platform.pathSeparator}app',
      );
      if (!await app.exists()) {
        throw const FormatException('预览包缺少 app 目录');
      }
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = StagedDevelopmentSource._(
        previewId: previewId,
        gameId: gameId,
        generation: generation,
        expiresAt: expiresAt,
        runtimeDeclaration: runtimeDeclaration,
        root: root,
        appDirectory: app,
        server: server,
        credential: credential ?? _randomCredential(),
      );
      source._listen();
      return source;
    } on Object {
      await server?.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
      rethrow;
    }
  }

  void _listen() {
    server.listen((request) {
      unawaited(_handleSafely(request));
    });
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    _expiryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => unawaited(close()),
    );
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handle(request);
    } on Object {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.text;
        request.response.write('Temporary development resource unavailable');
        await request.response.close();
      } on Object {
        // The response may already have been committed by a failed file pipe.
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (_closed || !DateTime.now().toUtc().isBefore(expiresAt)) {
      await _text(request.response, HttpStatus.gone, 'Preview expired');
      return;
    }
    if (request.headers.value(playmeshDevelopmentCredentialHeader) !=
        _credential) {
      await _text(request.response, HttpStatus.forbidden, 'Forbidden');
      return;
    }
    final relativePath = request.uri.path == '/'
        ? ''
        : request.uri.path.substring(1);
    if (relativePath == playmeshDevelopmentRestartControlPath &&
        request.method == 'POST') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _text(
        request.response,
        HttpStatus.methodNotAllowed,
        'Method not allowed',
      );
      return;
    }
    if (relativePath.isEmpty || relativePath.contains('%')) {
      await _text(request.response, HttpStatus.notFound, 'Not found');
      return;
    }
    late final String normalized;
    try {
      normalized = playmeshGamePackageLayout.validateRelativePath(
        relativePath,
        field: '预览资源路径',
      );
    } on FormatException {
      await _text(request.response, HttpStatus.notFound, 'Not found');
      return;
    }
    final file = File(
      '${appDirectory.path}${Platform.pathSeparator}'
      '${normalized.replaceAll('/', Platform.pathSeparator)}',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      await _text(request.response, HttpStatus.notFound, 'Not found');
      return;
    }
    request.response.headers
      ..contentType = gameWebResourceContentType(normalized)
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    if (request.method == 'HEAD') {
      request.response.contentLength = await file.length();
      await request.response.close();
      return;
    }
    await file.openRead().pipe(request.response);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<void> _text(HttpResponse response, int status, String value) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(value);
  await response.close();
}

String _randomCredential() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
}
