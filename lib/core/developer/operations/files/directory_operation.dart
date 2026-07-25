part of '../../developer_web_gateway_io.dart';

class _DirectoryOperation implements _DeveloperHttpOperation {
  const _DirectoryOperation();

  static const _clientSchema = <String, Object?>{
    'type': 'object',
    'properties': {
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'directories.create',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/directory',
      summary: '创建项目文件夹',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 201,
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      requestBodySchema: _clientSchema,
      requestExample: {'clientId': 'chat-console'},
    ),
    DeveloperOperationDefinition(
      id: 'directories.delete',
      method: 'DELETE',
      path: '/dev/api/projects/{projectId}/directory',
      summary: '递归删除项目文件夹',
      permission: 'project.write',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      requestBodySchema: _clientSchema,
      requestExample: {'clientId': 'chat-console'},
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
    final path = request.uri.queryParameters['path'] ?? '';
    final body = await _optionalJsonBody(request);
    if (request.method == 'POST') {
      await gateway.catalog.createDirectory(projectId, path);
      developerEventHub.emit({
        'type': 'directory.created',
        'projectId': projectId,
        'path': path,
        'clientId': body['clientId'],
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.created, {
        'requestId': requestId,
        'projectId': projectId,
        'path': path,
        'created': true,
      });
      return;
    }
    await gateway.catalog.deleteDirectory(projectId, path);
    developerEventHub.emit({
      'type': 'directory.deleted',
      'projectId': projectId,
      'path': path,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'deleted': true,
    });
  }
}
