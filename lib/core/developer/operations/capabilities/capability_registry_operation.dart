part of '../../developer_web_gateway_io.dart';

class _CapabilityRegistryOperation implements _DeveloperHttpOperation {
  const _CapabilityRegistryOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'capabilities.list',
      method: 'GET',
      path: '/dev/api/capabilities',
      summary: '读取平台注册表中的全部能力声明',
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
    'capabilities': gateway.capabilityTests.registry.descriptors
        .map((item) => item.toJson())
        .toList(),
  });
}
