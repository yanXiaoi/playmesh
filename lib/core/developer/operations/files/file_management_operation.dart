part of '../../developer_web_gateway_io.dart';

class _FileManagementOperation implements _DeveloperHttpOperation {
  const _FileManagementOperation();

  static const _schema = <String, Object?>{
    'type': 'object',
    'required': ['operation', 'source', 'destination'],
    'properties': {
      'operation': {
        'type': 'string',
        'enum': ['copy', 'move', 'extract'],
      },
      'source': {'type': 'string'},
      'destination': {'type': 'string'},
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'files.manage',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/file-operations',
      summary: '复制、移动或解压上传后的项目文件',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _schema,
      requestExample: {
        'operation': 'move',
        'source': 'app/old.js',
        'destination': 'app/static/js/new.js',
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
    final body = await _jsonBody(request);
    final operation = body['operation'];
    final source = body['source'];
    final destination = body['destination'];
    if (operation is! String || source is! String || destination is! String) {
      throw const FormatException('operation、source、destination 必须是字符串');
    }
    List<String> extracted = const [];
    switch (operation) {
      case 'copy':
        await gateway.catalog.copyEntry(projectId, source, destination);
      case 'move':
        await gateway.catalog.moveEntry(projectId, source, destination);
      case 'extract':
        extracted = await gateway.catalog.extractZip(
          projectId,
          source,
          destination,
        );
      default:
        throw const FormatException('operation 只支持 copy、move 或 extract');
    }
    developerEventHub.emit({
      'type': 'files.operated',
      'projectId': projectId,
      'operation': operation,
      'source': source,
      'destination': destination,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'operation': operation,
      'source': source,
      'destination': destination,
      'extracted': extracted,
    });
  }
}
