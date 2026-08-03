part of '../../developer_web_gateway_io.dart';

class _ProjectCopyOperation implements _DeveloperHttpOperation {
  const _ProjectCopyOperation();

  static const _schema = <String, Object?>{
    'type': 'object',
    'required': ['id', 'name'],
    'properties': {
      'id': {'type': 'string'},
      'name': {'type': 'string'},
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.copy',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/copy',
      summary: '复制项目源码并使用新的项目 ID',
      permission: 'project.create',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 201,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _schema,
      requestExample: {'id': 'com.example.copied-game', 'name': 'Copied game'},
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
    final sourceProjectId = pathParameters['projectId']!;
    final body = await _jsonBody(request);
    final project = await gateway.catalog.copyProject(
      sourceProjectId,
      id: body['id'] as String? ?? '',
      name: body['name'] as String? ?? '',
      author: gateway._requireCurrentAuthor(),
      lastModifiedAt: gateway.clock().toUtc(),
    );
    developerEventHub.emit({
      'type': 'project.created',
      'projectId': project.id,
      'sourceProjectId': sourceProjectId,
      'project': project.toJson(),
      'clientId': body['clientId'] as String? ?? 'api',
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.created, {
      'requestId': requestId,
      'sourceProjectId': sourceProjectId,
      'project': project.toJson(),
    });
  }
}
