part of '../developer_web_gateway_io.dart';

class _DeveloperOperationRegistry {
  _DeveloperOperationRegistry(
    this.operations, {
    List<DeveloperOperationMiddleware> middleware = const [
      DeveloperOperationSecurityMiddleware(),
      DeveloperOperationMetadataMiddleware(),
      DeveloperOperationResponsesMiddleware(),
    ],
    List<_DeveloperOperationExecutionMiddleware> executionMiddleware = const [
      _DeveloperForegroundViewMiddleware(),
      _DeveloperAiApprovalMiddleware(),
    ],
  }) : middleware = List.unmodifiable(middleware),
       executionMiddleware = List.unmodifiable(executionMiddleware);

  static const catalogVersion = '4.2.0';

  final List<_DeveloperHttpOperation> operations;
  final List<DeveloperOperationMiddleware> middleware;
  final List<_DeveloperOperationExecutionMiddleware> executionMiddleware;

  late final List<DeveloperOperationDefinition> definitions = List.unmodifiable(
    operations.expand((operation) => operation.definitions),
  );

  _DeveloperOperationMatch? match(HttpRequest request) {
    for (final operation in operations) {
      for (final definition in operation.definitions) {
        if (definition.normalizedMethod != request.method.toUpperCase()) {
          continue;
        }
        final parameters = _matchPath(definition.path, request.uri.path);
        if (parameters != null) {
          return _DeveloperOperationMatch(
            operation: operation,
            definition: definition,
            pathParameters: parameters,
          );
        }
      }
    }
    return null;
  }

  Future<bool> dispatch(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
  ) async {
    final matched = match(request);
    if (matched == null) return false;
    if (!gateway.gdevelopAiFeaturePolicy.allowsRequest(
      operationId: matched.definition.id,
      pathParameters: matched.pathParameters,
      queryParameters: request.uri.queryParameters,
    )) {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'route_not_found',
        '开发者接口不存在',
      );
      return true;
    }
    request.response.headers.set(
      'X-Playmesh-Operation-ID',
      matched.definition.id,
    );
    Future<void> invoke(int index) {
      if (index == executionMiddleware.length) {
        return matched.operation.handle(
          gateway,
          request,
          requestId,
          matched.definition,
          matched.pathParameters,
        );
      }
      return executionMiddleware[index].handle(
        gateway,
        request,
        requestId,
        matched.definition,
        matched.pathParameters,
        () => invoke(index + 1),
      );
    }

    await invoke(0);
    return true;
  }

  Map<String, Object?> openApi({
    bool Function(DeveloperOperationDefinition operation)? where,
  }) {
    final paths = <String, Map<String, Object?>>{};
    for (final definition in definitions) {
      if (where != null && !where(definition)) continue;
      final path = paths.putIfAbsent(
        definition.path,
        () => <String, Object?>{},
      );
      path[definition.normalizedMethod.toLowerCase()] = _document(
        definition,
        DeveloperOperationDocumentTarget.openApi,
      );
    }
    return {
      'openapi': '3.1.0',
      'info': {
        'title': 'Playmesh Developer Channel',
        'version': catalogVersion,
      },
      'paths': paths,
      'components': {
        'securitySchemes': {
          'developerToken': {
            'type': 'http',
            'scheme': 'bearer',
            'description': '持久开发者工作区 token，与端口和工作区路径一起保存。',
          },
        },
      },
    };
  }

  List<Map<String, Object?>> catalog({
    required bool Function(DeveloperOperationDefinition operation) where,
  }) => definitions
      .where(where)
      .map(
        (operation) =>
            _document(operation, DeveloperOperationDocumentTarget.catalog),
      )
      .toList(growable: false);

  Map<String, Object?> _document(
    DeveloperOperationDefinition operation,
    DeveloperOperationDocumentTarget target,
  ) {
    final document = target == DeveloperOperationDocumentTarget.openApi
        ? operation.toOpenApiBase()
        : operation.toCatalogBase();
    for (final item in middleware) {
      item.apply(operation, target, document);
    }
    return document;
  }

  Map<String, String>? _matchPath(String template, String actual) {
    final templateParts = Uri.parse(template).pathSegments;
    final actualParts = Uri.parse(actual).pathSegments;
    if (templateParts.length != actualParts.length) return null;
    final parameters = <String, String>{};
    for (var index = 0; index < templateParts.length; index += 1) {
      final expected = templateParts[index];
      final value = actualParts[index];
      if (expected.startsWith('{') && expected.endsWith('}')) {
        parameters[expected.substring(1, expected.length - 1)] = value;
      } else if (expected != value) {
        return null;
      }
    }
    return parameters;
  }
}
