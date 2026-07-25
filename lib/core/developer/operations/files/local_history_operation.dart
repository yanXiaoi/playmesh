part of '../../developer_web_gateway_io.dart';

class _LocalHistoryOperation implements _DeveloperHttpOperation {
  const _LocalHistoryOperation();

  static const _restoreSchema = <String, Object?>{
    'type': 'object',
    'required': ['operationId', 'path', 'version'],
    'properties': {
      'operationId': {'type': 'string'},
      'path': {'type': 'string'},
      'version': {
        'type': 'string',
        'enum': ['before', 'after'],
      },
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'history.list',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/local-history',
      summary: '按时间操作列出项目本地历史',
      parameters: [
        developerProjectIdParameter,
        DeveloperOperationParameter(
          name: 'path',
          location: DeveloperOperationParameterLocation.query,
          description: '可选文件、文件夹或空字符串工作区路径',
        ),
      ],
    ),
    DeveloperOperationDefinition(
      id: 'history.diff',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/local-history/diff',
      summary: '读取本地历史结构化差异',
      parameters: [
        developerProjectIdParameter,
        DeveloperOperationParameter(
          name: 'operationId',
          location: DeveloperOperationParameterLocation.query,
          description: '历史操作 ID',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'path',
          location: DeveloperOperationParameterLocation.query,
          description: '文件、文件夹或空字符串工作区路径',
          required: true,
        ),
      ],
    ),
    DeveloperOperationDefinition(
      id: 'history.restore',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/local-history/restore',
      summary: '用历史快照替换文件、文件夹或整个工作区',
      permission: 'project.write',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _restoreSchema,
      requestExample: {
        'operationId': 'operation-id',
        'path': 'app/game.js',
        'version': 'before',
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
    if (definition.id == 'history.list') {
      final path = request.uri.queryParameters['path'] ?? '';
      final operations = await gateway.catalog.listLocalHistory(
        projectId,
        path,
      );
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'path': path,
        'mergeWindowSeconds': DeveloperLocalHistoryStore.mergeWindow.inSeconds,
        'operations': operations.map((item) => item.toJson()).toList(),
      });
      return;
    }
    if (definition.id == 'history.diff') {
      final path = request.uri.queryParameters['path'] ?? '';
      final operationId = request.uri.queryParameters['operationId'] ?? '';
      final diff = await gateway.catalog.localHistoryDiff(
        projectId,
        operationId,
        path,
      );
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        ...diff.toJson(),
      });
      return;
    }
    final body = await _jsonBody(request);
    final operationId = body['operationId'];
    final path = body['path'];
    final versionName = body['version'];
    if (operationId is! String || path is! String || versionName is! String) {
      throw const FormatException('operationId、path 和 version 必须是字符串');
    }
    final version = switch (versionName) {
      'before' => DeveloperHistoryVersion.before,
      'after' => DeveloperHistoryVersion.after,
      _ => throw const FormatException('version 只支持 before 或 after'),
    };
    await gateway.catalog.restoreLocalHistory(
      projectId,
      operationId,
      path,
      version,
    );
    developerEventHub.emit({
      'type': 'workspace.restored',
      'projectId': projectId,
      'path': path,
      'operationId': operationId,
      'version': version.name,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'operationId': operationId,
      'version': version.name,
      'restored': true,
    });
  }
}
