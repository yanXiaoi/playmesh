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
      parameters: [
        DeveloperOperationParameter(
          name: 'locale',
          location: DeveloperOperationParameterLocation.query,
          description: 'BCP 47 提示词 locale；按提示词清单匹配，未命中使用 defaultLocale',
        ),
        DeveloperOperationParameter(
          name: 'surface',
          location: DeveloperOperationParameterLocation.query,
          description: '提示词入口；默认 source，可选 gdevelop',
        ),
      ],
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
        DeveloperOperationParameter(
          name: 'locale',
          location: DeveloperOperationParameterLocation.query,
          description: '要保存的提示词语言',
        ),
      ],
      requestBodySchema: _saveSchema,
      requestExample: {'content': 'Custom prompt template content'},
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
        DeveloperOperationParameter(
          name: 'locale',
          location: DeveloperOperationParameterLocation.query,
          description: '要恢复默认值的提示词语言',
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
    final locale = request.requestedUri.queryParameters['locale'];
    if (definition.id == 'prompts.templates.list') {
      final surface =
          request.requestedUri.queryParameters['surface'] ?? 'source';
      final templates = await gateway.promptTemplates.list(
        locale: locale,
        surface: surface,
      );
      final resources = await gateway.promptTemplates.resources(locale: locale);
      final categories = <String, Map<String, Object?>>{};
      for (final template in templates) {
        final descriptor = template.descriptor;
        final category = categories.putIfAbsent(
          descriptor.category,
          () => {
            'id': descriptor.category,
            'name': resources.appText(
              'workspace.prompt.category.${descriptor.category}',
            ),
            'items': <Object?>[],
          },
        );
        (category['items']! as List<Object?>).add(
          _localizedPromptTemplateJson(template, resources),
        );
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
      final template = await gateway.promptTemplates.save(
        templateId,
        content,
        locale: locale,
      );
      developerEventHub.emit({
        'type': 'ai.prompt-template.saved',
        'templateId': templateId,
        'locale': template.locale,
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'template': _localizedPromptTemplateJson(
          template,
          await gateway.promptTemplates.resources(locale: template.locale),
        ),
      });
      return;
    }
    final template = await gateway.promptTemplates.reset(
      templateId,
      locale: locale,
    );
    developerEventHub.emit({
      'type': 'ai.prompt-template.reset',
      'templateId': templateId,
      'locale': template.locale,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'template': _localizedPromptTemplateJson(
        template,
        await gateway.promptTemplates.resources(locale: template.locale),
      ),
    });
  }
}

Map<String, Object?> _localizedPromptTemplateJson(
  DeveloperAiPromptTemplate template,
  DeveloperAiPromptResources resources,
) {
  final localizationId = template.descriptor.id.replaceAll('-', '_');
  return {
    ...template.toJson(),
    'name': resources.appText('workspace.prompt.template.$localizationId'),
  };
}
