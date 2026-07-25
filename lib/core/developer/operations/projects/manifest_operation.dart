part of '../../developer_web_gateway_io.dart';

class _ManifestOperation implements _DeveloperHttpOperation {
  const _ManifestOperation();

  static const _schema = <String, Object?>{
    'type': 'object',
    'required': ['manifest'],
    'properties': {
      'manifest': {'type': 'object'},
      'baseRevision': {'type': 'integer', 'minimum': 1},
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'manifest.read',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/manifest',
      summary: '读取 main.json 可视化编辑数据',
      parameters: [developerProjectIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'manifest.update',
      method: 'PUT',
      path: '/dev/api/projects/{projectId}/manifest',
      summary: '校验并保存 main.json；id、author 和 lastModifiedAt 不可修改',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _schema,
      requestExample: {
        'manifest': {'id': 'com.example.game', 'name': '游戏名称'},
        'baseRevision': 2,
        'clientId': 'chat-console',
      },
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
    if (request.method == 'GET') {
      final file = await gateway.catalog.readFile(projectId, 'main.json');
      final decoded = jsonDecode(utf8.decode(file.bytes));
      if (decoded is! Map) {
        throw const FormatException('项目 main.json 无效');
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'revision': file.revision,
        'manifest': Map<String, Object?>.from(decoded),
      });
      return;
    }
    final body = await _jsonBody(request);
    final rawManifest = body['manifest'];
    if (rawManifest is! Map) {
      throw const FormatException('manifest 必须是对象');
    }
    final before = await gateway.catalog.readFile(projectId, 'main.json');
    final saved = await gateway.catalog.updateManifest(
      projectId,
      Map<String, Object?>.from(rawManifest),
      expectedRevision: body['baseRevision'] as int?,
    );
    final content = utf8.decode(saved.bytes);
    _emitDeveloperFileEvent(
      type: 'manifest.saved',
      projectId: projectId,
      path: 'main.json',
      revision: saved.revision,
      clientId: body['clientId'] as String?,
      operations: _minimalOperations(utf8.decode(before.bytes), content),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'revision': saved.revision,
      'manifest': jsonDecode(content),
    });
  }
}
