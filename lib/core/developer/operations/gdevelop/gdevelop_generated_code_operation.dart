part of '../../developer_web_gateway_io.dart';

class _GDevelopGeneratedCodeOperation implements _DeveloperHttpOperation {
  const _GDevelopGeneratedCodeOperation();

  static const _path = '/dev/api/gdevelop/generated-code/{codeKey}';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.generatedCode.write',
      method: 'PUT',
      path: _path,
      summary: '暂存 GDevelop 当前会话生成的事件函数代码',
      description: '仅保存在 App 内存中，供预览和 HTML 导出读取；开发者通道关闭后自动释放。',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'codeKey',
          location: DeveloperOperationParameterLocation.path,
          description: '当前 WebIDE 会话内唯一的生成代码 key',
          required: true,
        ),
      ],
      additionalResponses: {413: '单份生成代码超过内存限制'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.generatedCode.read',
      method: 'GET',
      path: _path,
      summary: '读取 GDevelop 当前会话生成的事件函数代码',
      permission: 'runtime.run',
      parameters: [
        DeveloperOperationParameter(
          name: 'codeKey',
          location: DeveloperOperationParameterLocation.path,
          description: '当前 WebIDE 会话内唯一的生成代码 key',
          required: true,
        ),
      ],
      additionalResponses: {404: '生成代码不存在或已随通道关闭释放'},
      chatEnabled: false,
      agentEnabled: false,
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
    final key = GDevelopGeneratedCodeStore.validateKey(
      pathParameters['codeKey']!,
    );
    switch (definition.id) {
      case 'gdevelop.generatedCode.write':
        final mimeType = request.headers.contentType?.mimeType;
        if (mimeType != 'text/javascript' &&
            mimeType != 'application/javascript' &&
            mimeType != 'application/octet-stream') {
          throw const FormatException('GDevelop 临时代码必须是 JavaScript');
        }
        try {
          final bytes = await _bytesBodyWithLimit(
            request,
            gateway.gdevelopGeneratedCode.maximumEntryBytes,
          );
          gateway.gdevelopGeneratedCode.put(key, bytes);
        } on GDevelopGeneratedCodeTooLarge catch (error) {
          throw _DeveloperRequestTooLarge(error.limit);
        }
        request.response.statusCode = HttpStatus.noContent;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        await request.response.close();
      case 'gdevelop.generatedCode.read':
        final bytes = gateway.gdevelopGeneratedCode.read(key);
        if (bytes == null) {
          await _error(
            request.response,
            HttpStatus.notFound,
            requestId,
            'gdevelop_generated_code_not_found',
            'GDevelop 临时代码不存在或已释放',
          );
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
          ..contentType = ContentType.parse('text/javascript; charset=utf-8')
          ..contentLength = bytes.length
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        request.response.add(bytes);
        await request.response.close();
    }
  }
}
