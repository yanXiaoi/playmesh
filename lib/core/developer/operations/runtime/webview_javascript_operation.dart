part of '../../developer_web_gateway_io.dart';

class _WebViewJavaScriptOperation implements _DeveloperHttpOperation {
  const _WebViewJavaScriptOperation();

  static const _requestSchema = <String, Object?>{
    'type': 'object',
    'required': ['source'],
    'properties': {
      'source': {
        'type': 'string',
        'minLength': 1,
        'description': '在当前运行游戏的顶层 WebView 文档中执行的 JavaScript',
      },
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'runtime.webview.execute_javascript',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/webview/javascript',
      summary: '在当前运行游戏的 WebView 中执行任意 JavaScript',
      description: '返回 WebView 对脚本最后一个表达式求值后的 JSON 可序列化结果。',
      permission: 'runtime.debug',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      requiresForegroundView: true,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _requestSchema,
      requestExample: {'source': 'document.title'},
      responseDescription: '脚本执行完成并返回求值结果',
      additionalResponses: {
        409: 'App 页面不在可见且可交互状态',
        422: 'JavaScript 在游戏 WebView 中执行失败',
      },
    ),
  ];

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) async {
    final projectId = pathParameters['projectId']!;
    final body = await _jsonBody(request);
    final source = body['source'];
    if (source is! String || source.trim().isEmpty) {
      throw const FormatException('source 必须是非空 JavaScript 字符串');
    }

    Object? result;
    try {
      result = await gateway.runController.executeJavaScript(projectId, source);
    } on StateError {
      rethrow;
    } on Object catch (error) {
      await _error(
        request.response,
        HttpStatus.unprocessableEntity,
        requestId,
        'javascript_execution_failed',
        error.toString(),
      );
      return;
    }

    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'runId': gateway.runController.status(projectId).runId,
      'executedAt': gateway.clock().toUtc().millisecondsSinceEpoch,
      'resultType': _javaScriptResultType(result),
      'result': _jsonSafeJavaScriptResult(result),
    });
  }
}

String _javaScriptResultType(Object? result) {
  if (result == null) return 'null';
  if (result is bool) return 'boolean';
  if (result is num) return 'number';
  if (result is String) return 'string';
  if (result is List) return 'array';
  if (result is Map) return 'object';
  return result.runtimeType.toString();
}

Object? _jsonSafeJavaScriptResult(Object? result) {
  try {
    jsonEncode(result);
    return result;
  } on Object {
    return result.toString();
  }
}
