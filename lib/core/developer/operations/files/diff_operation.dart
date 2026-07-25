part of '../../developer_web_gateway_io.dart';

class _DiffOperation implements _DeveloperHttpOperation {
  const _DiffOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'files.diff',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/diff',
      summary: '读取当前文件与已保存基线之间的结构化差异',
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
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
    final diff = await gateway.catalog.diffFile(
      pathParameters['projectId']!,
      request.uri.queryParameters['path'] ?? '',
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ...diff.toJson(),
    });
  }
}
