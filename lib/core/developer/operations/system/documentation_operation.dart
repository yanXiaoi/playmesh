part of '../../developer_web_gateway_io.dart';

class _DocumentationOperation implements _DeveloperHttpOperation {
  const _DocumentationOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'docs.human',
      method: 'GET',
      path: '/dev/docs',
      summary: '读取由统一操作注册表生成的人类可读文档',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.openapi',
      method: 'GET',
      path: '/dev/openapi.json',
      summary: '读取由统一操作注册表生成的 OpenAPI 3.1 文档',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.sdk_manifest',
      method: 'GET',
      path: '/dev/sdk-manifest.json',
      summary: '读取 Game SDK 方法契约',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.session_schema',
      method: 'GET',
      path: '/dev/schemas/developer-session.json',
      summary: '读取开发者会话 JSON Schema',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.validation_schema',
      method: 'GET',
      path: '/dev/schemas/project-validation.json',
      summary: '读取项目校验报告 JSON Schema',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.sdk_schema',
      method: 'GET',
      path: '/dev/schemas/sdk-v1.json',
      summary: '读取 Game SDK 数据 JSON Schema',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.manifest_schema',
      method: 'GET',
      path: '/dev/schemas/game-manifest.json',
      summary: '读取游戏 Manifest JSON Schema',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.capabilities_schema',
      method: 'GET',
      path: '/dev/schemas/game-capabilities.json',
      summary: '读取项目能力声明 JSON Schema',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.example_projects',
      method: 'GET',
      path: '/dev/examples/list-projects.json',
      summary: '读取项目列表请求示例',
      permission: 'docs.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'docs.example_validation',
      method: 'GET',
      path: '/dev/examples/validate-project.json',
      summary: '读取项目校验请求和响应示例',
      permission: 'docs.read',
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
    switch (definition.id) {
      case 'docs.human':
        await _text(
          request.response,
          _humanDocumentation(),
          'text/markdown; charset=utf-8',
        );
      case 'docs.openapi':
        await _json(
          request.response,
          HttpStatus.ok,
          _developerOperationRegistry.openApi(),
        );
      case 'docs.sdk_manifest':
        await _serveDeveloperAsset(request, 'contracts/sdk-manifest.json');
      case 'docs.session_schema':
        await _json(request.response, HttpStatus.ok, _sessionSchema);
      case 'docs.validation_schema':
        await _json(request.response, HttpStatus.ok, _projectValidationSchema);
      case 'docs.sdk_schema':
        await _serveDeveloperAsset(request, 'contracts/schemas/sdk-v1.json');
      case 'docs.manifest_schema':
        await _serveDeveloperAsset(
          request,
          'contracts/schemas/game-manifest.json',
        );
      case 'docs.capabilities_schema':
        await _serveDeveloperAsset(
          request,
          'contracts/schemas/game-capabilities.json',
        );
      case 'docs.example_projects':
        await _json(request.response, HttpStatus.ok, {
          'method': 'GET',
          'path': '/dev/api/projects',
          'authorization': 'Bearer <developer-token>',
        });
      case 'docs.example_validation':
        await _json(request.response, HttpStatus.ok, {
          'method': 'GET',
          'path': '/dev/api/projects/{projectId}/validate',
          'authorization': 'Bearer <developer-token>',
          'success': {
            'valid': true,
            'errorCount': 0,
            'warningCount': 0,
            'diagnostics': <Object>[],
          },
        });
    }
  }

  String _humanDocumentation() {
    final output = StringBuffer()
      ..writeln('# Playmesh Developer Channel API')
      ..writeln()
      ..writeln(
        '契约版本：`${_DeveloperOperationRegistry.catalogVersion}`。'
        '所有路由、OpenAPI、对话控制台和 Agent 操作目录都来自同一运行时注册表。',
      )
      ..writeln()
      ..writeln('鉴权使用 `Authorization: Bearer <token>` 或 `token` 查询参数。')
      ..writeln(
        '普通文件接口不能写入 `main.json`；必须使用 Manifest 接口。'
        '项目路径受沙箱、revision、原子事务和本地历史保护。',
      )
      ..writeln()
      ..writeln('## 已注册操作');
    for (final operation in _developerOperationRegistry.definitions) {
      output
        ..writeln()
        ..writeln(
          '- `${operation.normalizedMethod} ${operation.path}` '
          '`${operation.id}`：${operation.summary}',
        );
    }
    return output.toString();
  }
}

const _sessionSchema = {
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'title': 'DeveloperSession',
  'type': 'object',
  'required': ['enabled', 'port'],
  'properties': {
    'enabled': {'type': 'boolean'},
    'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
    'path': {'type': 'string'},
    'tokenHint': {'type': 'string'},
    'workspacePath': {'type': 'string'},
    'createdAt': {'type': 'integer'},
  },
};

const _projectValidationSchema = {
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'title': 'DeveloperProjectValidationReport',
  'type': 'object',
  'required': [
    'projectId',
    'valid',
    'errorCount',
    'warningCount',
    'fileCount',
    'totalBytes',
    'diagnostics',
  ],
  'properties': {
    'projectId': {'type': 'string'},
    'valid': {'type': 'boolean'},
    'errorCount': {'type': 'integer', 'minimum': 0},
    'warningCount': {'type': 'integer', 'minimum': 0},
    'fileCount': {'type': 'integer', 'minimum': 0},
    'totalBytes': {'type': 'integer', 'minimum': 0},
    'diagnostics': {
      'type': 'array',
      'items': {
        'type': 'object',
        'required': ['code', 'severity', 'message', 'path'],
        'properties': {
          'code': {'type': 'string'},
          'severity': {
            'type': 'string',
            'enum': ['error', 'warning', 'info'],
          },
          'message': {'type': 'string'},
          'path': {'type': 'string'},
          'line': {'type': 'integer', 'minimum': 1},
          'column': {'type': 'integer', 'minimum': 1},
          'hint': {'type': 'string'},
        },
      },
    },
  },
};
