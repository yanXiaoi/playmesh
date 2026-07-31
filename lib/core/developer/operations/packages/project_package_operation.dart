part of '../../developer_web_gateway_io.dart';

class _ProjectPackageOperation implements _DeveloperHttpOperation {
  const _ProjectPackageOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'packages.export_project',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/package',
      summary: '无语义校验导出项目包，用于损坏项目修复',
      parameters: [developerProjectIdParameter],
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
  ) => gateway._serializePackageFile(() async {
    final projectId = pathParameters['projectId']!;
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-developer-export.playmesh.zip',
    );
    try {
      if (await file.exists()) await file.delete();
      final project = (await gateway.catalog.listProjects()).firstWhere(
        (candidate) => candidate.id == projectId,
        orElse: () => throw StateError('开发者项目不存在'),
      );
      final rootFilePath = project.rootFilePath;
      final game = GameSummary(
        id: project.id,
        name: project.name,
        version: project.version,
        description: '',
        minPlayers: 1,
        maxPlayers: 1,
        supportsMultiplayer: false,
        displayModeLabel: '',
        displayMode: 'multi_screen',
        orientation: GameOrientation.landscape,
        entry: LocalGameEntry(
          gameEntryPath: 'index.html',
          statusLabel: '',
          packageRootFilePath: rootFilePath,
        ),
      );
      await gateway.packageTransfer.exportPackage(game, file, validate: false);
      request.response.headers
        ..contentType = ContentType('application', 'zip')
        ..set(
          'Content-Disposition',
          'attachment; filename="$projectId.playmesh.zip"',
        )
        ..set('X-Request-ID', requestId);
      await file.openRead().pipe(request.response);
    } finally {
      if (await file.exists()) await file.delete();
    }
  });
}
