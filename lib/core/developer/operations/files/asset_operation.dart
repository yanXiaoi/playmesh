part of '../../developer_web_gateway_io.dart';

class _AssetOperation implements _DeveloperHttpOperation {
  const _AssetOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'files.read_asset',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/asset',
      summary: '读取图片或二进制项目资源',
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      chatEnabled: false,
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
    final file = await gateway.catalog.readFile(
      pathParameters['projectId']!,
      request.uri.queryParameters['path'] ?? '',
    );
    request.response.headers
      ..contentType = ContentType.parse(file.contentType)
      ..set('X-Playmesh-Revision', file.revision)
      ..set('X-Playmesh-Readonly', file.readOnly);
    request.response.add(file.bytes);
    await request.response.close();
  }
}
