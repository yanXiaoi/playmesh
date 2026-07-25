part of '../../developer_web_gateway_io.dart';

class _ActiveRunOperation implements _DeveloperHttpOperation {
  const _ActiveRunOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'runtime.active',
      method: 'GET',
      path: '/dev/api/run',
      summary: '读取当前唯一运行项目',
      permission: 'runtime.run',
    ),
  ];

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) => _json(request.response, HttpStatus.ok, {
    'requestId': requestId,
    'run': gateway.runController.activeStatus?.toJson(),
  });
}
