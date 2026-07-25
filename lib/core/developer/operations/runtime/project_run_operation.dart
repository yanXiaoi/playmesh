part of '../../developer_web_gateway_io.dart';

class _ProjectRunOperation implements _DeveloperHttpOperation {
  const _ProjectRunOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'runtime.status',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/run',
      summary: '读取指定项目运行状态',
      permission: 'runtime.run',
      parameters: [developerProjectIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'runtime.start',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/run',
      summary: '校验并请求 App 启动项目',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      successStatus: 202,
      parameters: [developerProjectIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'runtime.restart',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/run/restart',
      summary: '重新启动当前运行中的项目并保留会话',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      successStatus: 202,
      parameters: [developerProjectIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'runtime.stop',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/run/stop',
      summary: '停止当前运行中的项目并关闭游戏会话',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
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
    switch (definition.id) {
      case 'runtime.status':
        await _json(
          request.response,
          HttpStatus.ok,
          gateway.runController.status(projectId).toJson(),
        );
      case 'runtime.start':
        await gateway.catalog.prepareGame(projectId);
        final status = await gateway.runController.run(projectId);
        await _json(request.response, HttpStatus.accepted, status.toJson());
      case 'runtime.restart':
        final status = await gateway.runController.restart(projectId);
        await _json(request.response, HttpStatus.accepted, status.toJson());
      case 'runtime.stop':
        final status = await gateway.runController.stop(projectId);
        await _json(request.response, HttpStatus.ok, status.toJson());
    }
  }
}
