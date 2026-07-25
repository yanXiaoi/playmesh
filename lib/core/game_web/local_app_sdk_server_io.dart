import 'dart:async';
import 'dart:io';

import '../game_sdk/sdk_feature_registry.dart';
import 'local_app_sdk_server_contract.dart';

Future<LocalAppSdkServer> startLocalAppSdkServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final result = _IoLocalAppSdkServer(server);
  result.start();
  return result;
}

class _IoLocalAppSdkServer implements LocalAppSdkServer {
  _IoLocalAppSdkServer(this.server);

  final HttpServer server;
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
        final unexpectedParameters = request.uri.queryParameters.keys.where(
          (name) => name != 'version',
        );
        if (unexpectedParameters.isNotEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('App SDK 请求参数无效');
        } else {
          try {
            request.response.write(
              SdkFeatureRegistry.sdkFile(
                'playmesh-app.js',
                version: request.uri.queryParameters['version'],
              ),
            );
          } on FormatException catch (error) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write(error.message);
          } on UnsupportedError catch (error) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write(error.message);
          }
        }
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
