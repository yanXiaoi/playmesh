part of '../../developer_web_gateway_io.dart';

class _GDevelopCapabilityCatalogOperation implements _DeveloperHttpOperation {
  const _GDevelopCapabilityCatalogOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.catalog.capabilities.search',
      method: 'GET',
      path: '/dev/api/gdevelop/catalog/capabilities',
      summary: '搜索本机固定 GDevelop 扩展与行为能力目录',
      description: '搜索仅读取 App 内已打包索引，不下载正文。结果分页且不包含图标、原始 URL 或完整扩展 JSON。',
      permission: 'project.read',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'query',
          location: DeveloperOperationParameterLocation.query,
          description: '匹配名称、摘要、所属扩展、类别和标签的可选搜索文本',
        ),
        DeveloperOperationParameter(
          name: 'kind',
          location: DeveloperOperationParameterLocation.query,
          description: '可选类型：extension 或 behavior',
          schema: {
            'type': 'string',
            'enum': ['extension', 'behavior'],
          },
        ),
        DeveloperOperationParameter(
          name: 'category',
          location: DeveloperOperationParameterLocation.query,
          description: '可选的精确类别过滤',
        ),
        DeveloperOperationParameter(
          name: 'page',
          location: DeveloperOperationParameterLocation.query,
          description: '从 1 开始的页码，默认 1',
          schema: {'type': 'integer', 'minimum': 1, 'default': 1},
        ),
        DeveloperOperationParameter(
          name: 'pageSize',
          location: DeveloperOperationParameterLocation.query,
          description: '每页数量，默认 20，最大 50',
          schema: {
            'type': 'integer',
            'minimum': 1,
            'maximum': 50,
            'default': 20,
          },
        ),
      ],
      additionalResponses: {400: '查询参数无效', 503: '本地能力索引暂时不可用'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.catalog.capabilities.detail',
      method: 'GET',
      path: '/dev/api/gdevelop/catalog/capabilities/{kind}/{stableId}',
      summary: '读取 GDevelop 扩展或行为能力详情',
      description:
          '优先复用 App CAS 中经过固定清单校验的 owner extension 正文；缓存缺失时才下载固定 commit artifact。',
      permission: 'network.catalog.download',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'kind',
          location: DeveloperOperationParameterLocation.path,
          description: '能力类型：extension 或 behavior',
          required: true,
          schema: {
            'type': 'string',
            'enum': ['extension', 'behavior'],
          },
        ),
        DeveloperOperationParameter(
          name: 'stableId',
          location: DeveloperOperationParameterLocation.path,
          description: '扩展名，或 Extension::Behavior 形式的稳定行为 ID',
          required: true,
        ),
      ],
      additionalResponses: {
        400: 'kind 或 stableId 无效',
        404: '能力不存在',
        503: '已验证的能力详情正文当前不可用',
      },
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
    try {
      if (definition.id == 'gdevelop.catalog.capabilities.search') {
        final query = request.uri.queryParameters;
        final result = await gateway.gdevelopCapabilityCatalog.search(
          GDevelopCapabilitySearchRequest(
            query: query['query'] ?? '',
            kind: _emptyToNull(query['kind']),
            category: _emptyToNull(query['category']),
            page: _positiveInteger(query['page'], fallback: 1, name: 'page'),
            pageSize: _positiveInteger(
              query['pageSize'],
              fallback: 20,
              name: 'pageSize',
            ),
          ),
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'page': result.page,
          'pageSize': result.pageSize,
          'total': result.total,
          'items': result.items,
        });
        return;
      }
      final kind = pathParameters['kind'] ?? '';
      final stableId = pathParameters['stableId'] ?? '';
      final result = await gateway.gdevelopCapabilityCatalog.detail(
        kind: kind,
        stableId: stableId,
      );
      if (result == null) {
        await _error(
          request.response,
          HttpStatus.notFound,
          requestId,
          'capability_not_found',
          'GDevelop capability 不存在',
        );
        return;
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'capability': result.capability,
      });
    } on GDevelopCapabilityCatalogException catch (error) {
      await _error(
        request.response,
        error.retryable
            ? HttpStatus.serviceUnavailable
            : HttpStatus.unprocessableEntity,
        requestId,
        error.code,
        error.message,
      );
    }
  }

  static int _positiveInteger(
    String? source, {
    required int fallback,
    required String name,
  }) {
    if (source == null || source.isEmpty) return fallback;
    final value = int.tryParse(source);
    if (value == null || value < 1) {
      throw FormatException('GDevelop capability $name 无效');
    }
    return value;
  }

  static String? _emptyToNull(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}
