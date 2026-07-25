part of '../../developer_web_gateway_io.dart';

class _OperationCatalogOperation implements _DeveloperHttpOperation {
  const _OperationCatalogOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'operations.list',
      method: 'GET',
      path: '/dev/api/operations',
      summary: '获取由真实路由注册表生成的完整 AI 操作声明',
      description: 'target 支持 all、chat、agent 和 chat-bootstrap。',
      permission: 'docs.read',
      parameters: [
        DeveloperOperationParameter(
          name: 'target',
          location: DeveloperOperationParameterLocation.query,
          description: '选择全部、对话、Agent 或默认基础操作',
          schema: {
            'type': 'string',
            'enum': ['all', 'chat', 'agent', 'chat-bootstrap'],
          },
        ),
      ],
      chatBootstrap: true,
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
    final target = request.uri.queryParameters['target'] ?? 'all';
    bool include(DeveloperOperationDefinition operation) => switch (target) {
      'all' => true,
      'chat' => operation.chatEnabled,
      'agent' => operation.agentEnabled,
      'chat-bootstrap' => operation.chatEnabled && operation.chatBootstrap,
      _ => throw const FormatException(
        'target 只支持 all、chat、agent 或 chat-bootstrap',
      ),
    };
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'catalogVersion': _DeveloperOperationRegistry.catalogVersion,
      'target': target,
      'operations': _developerOperationRegistry.catalog(where: include),
    });
  }
}
