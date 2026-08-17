part of '../../developer_web_gateway_io.dart';

class _ProjectsOperation implements _DeveloperHttpOperation {
  const _ProjectsOperation();

  static const _createSchema = <String, Object?>{
    'type': 'object',
    'required': ['id', 'name'],
    'properties': {
      'id': {'type': 'string'},
      'name': {'type': 'string'},
      'description': {'type': 'string'},
      'orientation': {
        'type': 'string',
        'enum': ['landscape', 'portrait'],
      },
      'controllerOrientation': {
        'type': 'string',
        'enum': ['landscape', 'portrait'],
      },
      'displayMode': {'type': 'string'},
      'mode': {'type': 'string'},
      'minPlayers': {'type': 'integer'},
      'maxPlayers': {'type': 'integer'},
      'tags': {
        'type': 'array',
        'maxItems': maxGameTagCount,
        'items': {'type': 'string'},
      },
      'requiredCapabilities': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'controllerRequiredCapabilities': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.list',
      method: 'GET',
      path: '/dev/api/projects',
      summary: '列出当前开发者项目',
      chatBootstrap: true,
    ),
    DeveloperOperationDefinition(
      id: 'projects.create',
      method: 'POST',
      path: '/dev/api/projects',
      summary: '从平台默认模板创建项目',
      permission: 'project.create',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 201,
      requestBodySchema: _createSchema,
      requestExample: {
        'id': 'com.example.game',
        'name': '示例游戏',
        'mode': 'solo',
        'displayMode': 'multi_screen',
        'orientation': 'landscape',
        'minPlayers': 1,
        'maxPlayers': 1,
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
    if (request.method == 'GET') {
      final projects = await gateway.catalog.listProjects();
      final runningProjectId = gateway.runController.activeStatus?.projectId;
      final activeProjectId =
          runningProjectId != null &&
              projects.any((project) => project.id == runningProjectId)
          ? runningProjectId
          : projects.isEmpty
          ? null
          : projects.first.id;
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'activeProjectId': activeProjectId,
        'projects': projects.map((project) => project.toJson()).toList(),
      });
      return;
    }
    final body = await _jsonBody(request);
    final orientation = GameOrientation.fromManifestValue(
      body['orientation'] as String? ?? 'landscape',
    );
    final displayMode = body['displayMode'] as String? ?? 'multi_screen';
    final controllerOrientationValue = body['controllerOrientation'] as String?;
    final controllerOrientation = controllerOrientationValue == null
        ? null
        : GameOrientation.fromManifestValue(controllerOrientationValue);
    final project = await gateway.catalog.createProject(
      DeveloperProjectDraft(
        id: body['id'] as String? ?? '',
        name: body['name'] as String? ?? '',
        author: gateway._requireCurrentAuthor(),
        lastModifiedAt: gateway.clock().toUtc(),
        description: body['description'] as String? ?? '',
        orientation: orientation,
        controllerOrientation: controllerOrientation,
        displayMode: displayMode,
        minPlayers: body['minPlayers'] as int? ?? 2,
        maxPlayers: body['maxPlayers'] as int? ?? 5,
        mode: body['mode'] as String? ?? 'multiplayer',
        tags: _stringValues(body['tags']),
        requiredCapabilities: _stringValues(body['requiredCapabilities']),
        controllerRequiredCapabilities: _stringValues(
          body['controllerRequiredCapabilities'],
        ),
      ),
    );
    developerEventHub.emit({
      'type': 'project.created',
      'projectId': project.id,
      'project': project.toJson(),
      'clientId': body['clientId'] as String? ?? 'api',
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.created, {
      'requestId': requestId,
      'project': project.toJson(),
    });
  }
}
