part of '../../developer_web_gateway_io.dart';

class _ValidateOperation implements _DeveloperHttpOperation {
  const _ValidateOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.validate',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/validate',
      summary: '校验游戏包并返回结构化诊断',
      parameters: [developerProjectIdParameter],
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
    final projectId = pathParameters['projectId']!;
    final report = await gateway.catalog.validateProject(projectId);
    developerEventHub.emit({
      'type': 'project.validated',
      'projectId': projectId,
      'valid': report.valid,
      'errorCount': report.errorCount,
      'warningCount': report.warningCount,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ...report.toJson(),
    });
  }
}
