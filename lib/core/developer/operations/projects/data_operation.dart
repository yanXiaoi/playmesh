part of '../../developer_web_gateway_io.dart';

class _ProjectDataOperation implements _DeveloperHttpOperation {
  const _ProjectDataOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.clear_data',
      method: 'DELETE',
      path: '/dev/api/projects/{projectId}/data',
      summary: '清理当前游戏 SDK 持久数据并保留 cache',
      permission: 'project.data.clear',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
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
        '请先退出当前运行中的游戏，再清理游戏数据',
      );
      return;
    }
    final existed = await gateway.catalog.clearGameData(projectId);
    developerEventHub.emit({
      'type': 'project.data-cleared',
      'projectId': projectId,
      'existed': existed,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'directory': 'data',
      'existed': existed,
      'cachePreserved': true,
    });
  }
}
