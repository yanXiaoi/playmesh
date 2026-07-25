part of '../../developer_web_gateway_io.dart';

class _ProjectCapabilitiesOperation implements _DeveloperHttpOperation {
  const _ProjectCapabilitiesOperation();

  static const _schema = <String, Object?>{
    'type': 'object',
    'properties': {
      'required': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'controllerRequired': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'baseRevision': {'type': 'integer', 'minimum': 0},
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'project_capabilities.read',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/capabilities',
      summary: '读取当前项目的能力声明',
      parameters: [developerProjectIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'project_capabilities.update',
      method: 'PUT',
      path: '/dev/api/projects/{projectId}/capabilities',
      summary: '创建、更新或删除当前项目能力声明',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _schema,
      requestExample: {
        'required': ['device.vibration'],
        'controllerRequired': <String>[],
        'baseRevision': 0,
        'clientId': 'chat-console',
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
    if (request.method == 'GET') {
      try {
        final file = await gateway.catalog.readFile(
          projectId,
          'capabilities.json',
        );
        final decoded = jsonDecode(utf8.decode(file.bytes));
        if (decoded is! Map) {
          throw const FormatException('项目 capabilities.json 无效');
        }
        final capabilities = GameCapabilities.fromJson(
          Map<String, Object?>.from(decoded),
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'projectId': projectId,
          'exists': true,
          'revision': file.revision,
          'required': capabilities.required.toList(),
          'controllerRequired': capabilities.controllerRequired.toList(),
        });
      } on StateError {
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'projectId': projectId,
          'exists': false,
          'revision': 0,
          'required': <String>[],
          'controllerRequired': <String>[],
        });
      }
      return;
    }
    final body = await _jsonBody(request);
    final capabilities = GameCapabilities.fromJson({
      'required': body['required'],
      'controllerRequired': body['controllerRequired'],
    });
    final manifest = jsonDecode(
      utf8.decode(
        (await gateway.catalog.readFile(projectId, 'main.json')).bytes,
      ),
    );
    final singleScreen =
        manifest is Map &&
        manifest['displayModes'] is List &&
        (manifest['displayModes'] as List).contains(
          'single_screen_multiplayer',
        );
    if (!singleScreen && capabilities.controllerRequired.isNotEmpty) {
      throw const FormatException('仅单屏多人项目可以声明控制器能力');
    }
    DeveloperProjectFile? before;
    try {
      before = await gateway.catalog.readFile(projectId, 'capabilities.json');
    } on StateError {
      // 空能力声明以可选文件不存在表示。
    }
    final clientId = body['clientId'] as String?;
    if (capabilities.isEmpty) {
      if (before != null) {
        await gateway.catalog.deleteFile(
          projectId,
          'capabilities.json',
          expectedRevision: body['baseRevision'] as int?,
        );
        _emitDeveloperFileEvent(
          type: 'file.deleted',
          projectId: projectId,
          path: 'capabilities.json',
          revision: before.revision + 1,
          clientId: clientId,
          operations: const [],
        );
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'exists': false,
        'revision': before == null ? 0 : before.revision + 1,
        'required': <String>[],
        'controllerRequired': <String>[],
      });
      return;
    }
    final content =
        '${const JsonEncoder.withIndent('  ').convert(capabilities.toJson())}\n';
    final saved = await gateway.catalog.writeFile(
      projectId,
      'capabilities.json',
      utf8.encode(content),
      expectedRevision: body['baseRevision'] as int?,
    );
    _emitDeveloperFileEvent(
      type: 'capabilities.saved',
      projectId: projectId,
      path: 'capabilities.json',
      revision: saved.revision,
      clientId: clientId,
      operations: before == null
          ? const []
          : _minimalOperations(utf8.decode(before.bytes), content),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'exists': true,
      'revision': saved.revision,
      'required': capabilities.required.toList(),
      'controllerRequired': capabilities.controllerRequired.toList(),
    });
  }
}
