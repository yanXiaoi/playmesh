part of '../../developer_web_gateway_io.dart';

class _StatusOperation implements _DeveloperHttpOperation {
  const _StatusOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'workspace.status',
      method: 'GET',
      path: '/dev/api/status',
      summary: '读取开发者工作区状态、SDK 版本和可访问地址',
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
    final baseUrls = await _availableDeveloperBaseUrls(gateway, request);
    final viewAvailability = await gateway.viewAvailability();
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'catalogVersion': _DeveloperOperationRegistry.catalogVersion,
      'enabled': true,
      'port': gateway.server.port,
      'baseUrls': baseUrls.map((uri) => uri.toString()).toList(),
      'tokenHint': gateway.session.tokenHint,
      'gameSdkVersion': generatedGameSdkVersion,
      'appSdkVersion': generatedAppSdkVersion,
      'createdAt': gateway.session.createdAt?.millisecondsSinceEpoch,
      'appView': viewAvailability.toJson(),
    });
  }
}
