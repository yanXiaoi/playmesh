part of '../../developer_web_gateway_io.dart';

class _LogsOperation implements _DeveloperHttpOperation {
  const _LogsOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'runtime.logs',
      method: 'GET',
      path: '/dev/api/logs',
      summary: '读取最近 1 到 50 条当前设备运行日志',
      permission: 'log.read',
      parameters: [
        DeveloperOperationParameter(
          name: 'limit',
          location: DeveloperOperationParameterLocation.query,
          description: '返回条数，范围 1 到 50，默认 50',
          schema: {'type': 'integer', 'minimum': 1, 'maximum': 50},
        ),
        DeveloperOperationParameter(
          name: 'projectId',
          location: DeveloperOperationParameterLocation.query,
          description: '可选项目过滤',
        ),
        DeveloperOperationParameter(
          name: 'runId',
          location: DeveloperOperationParameterLocation.query,
          description: '可选运行实例过滤',
        ),
      ],
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
    final requestedLimit = int.tryParse(
      request.uri.queryParameters['limit'] ?? '50',
    );
    if (requestedLimit == null || requestedLimit < 1 || requestedLimit > 50) {
      throw const FormatException('日志 limit 必须在 1 到 50 之间');
    }
    final projectId = request.uri.queryParameters['projectId'];
    final runId = request.uri.queryParameters['runId'];
    final cached = developerEventHub.recentLogs.where((event) {
      if (projectId != null && event['projectId'] != projectId) return false;
      if (runId != null && event['runId'] != runId) return false;
      return true;
    }).toList();
    final start = cached.length > requestedLimit
        ? cached.length - requestedLimit
        : 0;
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'logs': cached.sublist(start),
      'count': cached.length - start,
      'maxLimit': 50,
      'cachedEntries': cached.length,
    });
  }
}
