import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'local_app_sdk_server_contract.dart';

const _appSdkAssetPath =
    'assets/playmesh-library/public/sdk/v1/playmesh-app.js';

Future<LocalAppSdkServer> startLocalAppSdkServer({String? scriptSource}) async {
  final source = scriptSource ?? await rootBundle.loadString(_appSdkAssetPath);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final result = _IoLocalAppSdkServer(server, source);
  result.start();
  return result;
}

class _IoLocalAppSdkServer implements LocalAppSdkServer {
  _IoLocalAppSdkServer(this.server, this.source);

  final HttpServer server;
  final String source;
  StreamSubscription<HttpRequest>? _subscription;

  @override
  Uri get scriptUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: server.port,
    path: '/playmesh-app.js',
  );

  void start() {
    _subscription = server.listen((request) async {
      request.response.headers
        ..contentType = ContentType(
          'application',
          'javascript',
          charset: 'utf-8',
        )
        ..set('Cache-Control', 'no-store');
      if (request.method != 'GET' || request.uri.path != scriptUri.path) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.write(source);
      }
      await request.response.close();
    });
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await server.close(force: true);
  }
}
