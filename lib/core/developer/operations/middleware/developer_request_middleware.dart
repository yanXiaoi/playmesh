part of '../../developer_web_gateway_io.dart';

typedef _DeveloperRequestNext = Future<void> Function();

abstract interface class _DeveloperRequestMiddleware {
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  );
}

class _DeveloperErrorMiddleware implements _DeveloperRequestMiddleware {
  const _DeveloperErrorMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  ) async {
    try {
      await next();
    } on DeveloperViewUnavailable catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'app_view_unavailable',
          'message': error.message,
          'details': {
            'requiresForegroundView': true,
            ...error.availability.toJson(),
          },
        },
      });
    } on DeveloperCapabilityUnavailable catch (error) {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'capability_unavailable',
        error.message,
      );
    } on FormatException catch (error) {
      await _error(
        request.response,
        HttpStatus.badRequest,
        requestId,
        'invalid_request',
        error.message,
      );
    } on StateError catch (error) {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'not_found',
        error.message,
      );
    } on DeveloperRevisionConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'revision_conflict',
          'message': '文件已被其他客户端修改',
          'currentRevision': error.currentRevision,
        },
      });
    } on DeveloperProjectValidationFailure catch (error) {
      await _json(request.response, HttpStatus.unprocessableEntity, {
        'requestId': requestId,
        'error': {
          'code': 'package_validation_failed',
          'message': '项目校验未通过，不能启动游戏',
        },
        'validation': error.report.toJson(),
      });
    } on Object {
      await _error(
        request.response,
        HttpStatus.internalServerError,
        requestId,
        'internal_error',
        '开发者通道处理请求失败',
      );
    }
  }
}

class _DeveloperAuthenticationMiddleware
    implements _DeveloperRequestMiddleware {
  const _DeveloperAuthenticationMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  ) async {
    if (request.method == 'GET' &&
        request.uri.path.startsWith('/playmesh/developer/')) {
      await next();
      return;
    }
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final bearer = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : '';
    final query = request.uri.queryParameters['token'] ?? '';
    final cookie = request.cookies
        .where((item) => item.name == 'playmesh_developer_token')
        .map((item) => item.value)
        .firstOrNull;
    if (!_constantTimeEquals(bearer, gateway.token) &&
        !_constantTimeEquals(query, gateway.token) &&
        !_constantTimeEquals(cookie ?? '', gateway.token)) {
      await _error(
        request.response,
        HttpStatus.unauthorized,
        requestId,
        'unauthorized',
        '开发者会话 Token 无效',
      );
      return;
    }
    await next();
  }
}

class _DeveloperRequestPipeline {
  const _DeveloperRequestPipeline(this.middleware);

  final List<_DeveloperRequestMiddleware> middleware;

  Future<void> run(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext terminal,
  ) {
    Future<void> invoke(int index) {
      if (index == middleware.length) return terminal();
      return middleware[index].handle(
        gateway,
        request,
        requestId,
        () => invoke(index + 1),
      );
    }

    return invoke(0);
  }
}
