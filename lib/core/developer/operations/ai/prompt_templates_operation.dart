part of '../../developer_web_gateway_io.dart';

class _PromptTemplatesOperation implements _DeveloperHttpOperation {
  const _PromptTemplatesOperation();

  static const _saveSchema = <String, Object?>{
    'type': 'object',
    'required': ['content'],
    'properties': {
      'content': {'type': 'string', 'minLength': 1},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'prompts.templates.list',
      method: 'GET',
      path: '/dev/api/ai-prompt-templates',
      summary: '读取分组后的全局 AI 提示模板',
      permission: 'ai.prompt.read',
      chatEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'prompts.templates.save',
      method: 'PUT',
      path: '/dev/api/ai-prompt-templates/{templateId}',
      summary: '保存全局 AI 提示模板覆盖',
      permission: 'ai.prompt.configure',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [
        DeveloperOperationParameter(
          name: 'templateId',
          location: DeveloperOperationParameterLocation.path,
          description: '提示模板 ID',
          required: true,
        ),
      ],
      requestBodySchema: _saveSchema,
      requestExample: {'content': '自定义提示模板内容'},
      chatEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'prompts.templates.reset',
      method: 'DELETE',
      path: '/dev/api/ai-prompt-templates/{templateId}',
      summary: '恢复全局 AI 提示模板默认值',
      permission: 'ai.prompt.configure',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [
        DeveloperOperationParameter(
          name: 'templateId',
          location: DeveloperOperationParameterLocation.path,
          description: '提示模板 ID',
          required: true,
        ),
      ],
      chatEnabled: false,
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
    if (definition.id == 'prompts.templates.list') {
      final templates = await gateway.promptTemplates.list();
      final categories = <String, Map<String, Object?>>{};
      for (final template in templates) {
        final descriptor = template.descriptor;
        final category = categories.putIfAbsent(
          descriptor.category,
          () => {
            'id': descriptor.category,
            'name': descriptor.categoryName,
            'items': <Object?>[],
          },
        );
        (category['items']! as List<Object?>).add(template.toJson());
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'categories': categories.values.toList(growable: false),
      });
      return;
    }
    final templateId = pathParameters['templateId']!;
    if (request.method == 'PUT') {
      final body = await _jsonBody(request);
      final content = body['content'];
      if (content is! String) {
        throw const FormatException('content 必须是字符串');
      }
      final template = await gateway.promptTemplates.save(templateId, content);
      developerEventHub.emit({
        'type': 'ai.prompt-template.saved',
        'templateId': templateId,
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'template': template.toJson(),
      });
      return;
    }
    final template = await gateway.promptTemplates.reset(templateId);
    developerEventHub.emit({
      'type': 'ai.prompt-template.reset',
      'templateId': templateId,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'template': template.toJson(),
    });
  }
}
