part of '../../developer_web_gateway_io.dart';

class _ProjectOperation implements _DeveloperHttpOperation {
  const _ProjectOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.delete',
      method: 'DELETE',
      path: '/dev/api/projects/{projectId}',
      summary: '永久删除已停止的项目、数据、缓存和本地历史',
      permission: 'project.delete',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      parameters: [developerProjectIdParameter],
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
    final phase = gateway.runController.status(projectId).phase;
    if (phase == DeveloperRunPhase.starting ||
        phase == DeveloperRunPhase.running) {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'game_running',
        '请先退出当前运行中的游戏，再删除项目',
      );
      return;
    }
    // Revocation is deliberately performed by this source-workspace
    // controller before deletion. The persistence mechanism is shared, while
    // GDevelop keeps its own lifecycle controller and scopeKind.
    await gateway.approvalBroker.clearScopeApprovals(
      scopeKind: 'source',
      scopeId: projectId,
    );
    await gateway.catalog.deleteProject(projectId);
    developerEventHub.emit({
      'type': 'project.deleted',
      'projectId': projectId,
      'clientId': request.uri.queryParameters['clientId'] ?? 'api',
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'deleted': true,
    });
  }
}
