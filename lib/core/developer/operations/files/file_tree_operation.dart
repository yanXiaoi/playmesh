part of '../../developer_web_gateway_io.dart';

class _FileTreeOperation implements _DeveloperHttpOperation {
  const _FileTreeOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'files.list',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/files',
      summary: '列出项目中的全部文件和文件夹',
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
    final files = await gateway.catalog.listFiles(projectId);
    final directories = await gateway.catalog.listDirectories(projectId);
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'files': files,
      'directories': directories,
    });
  }
}
