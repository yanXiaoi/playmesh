part of '../../developer_web_gateway_io.dart';

class _GDevelopProjectConfigOperation implements _DeveloperHttpOperation {
  const _GDevelopProjectConfigOperation();

  static const _putSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'schemaVersion',
      'gameType',
      'minPlayers',
      'maxPlayers',
      'tags',
      'expectedRevision',
    ],
    'properties': {
      'schemaVersion': {
        'type': 'integer',
        'const': GDevelopProjectConfig.schemaVersion,
      },
      'gameType': {
        'type': 'string',
        'enum': ['single', 'online'],
      },
      'minPlayers': {'type': 'integer', 'minimum': 1, 'maximum': 64},
      'maxPlayers': {'type': 'integer', 'minimum': 1, 'maximum': 64},
      'tags': {
        'type': 'array',
        'maxItems': 5,
        'uniqueItems': true,
        'items': {'type': 'string', 'minLength': 1, 'maxLength': 64},
      },
      'webRuntimeMultithreading': {'type': 'boolean'},
      'expectedRevision': {'type': 'integer', 'minimum': 0},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.project.config.get',
      method: 'GET',
      path: '/dev/api/gdevelop/projects/{gameId}/config',
      summary: '读取独立的 Playmesh GDevelop 项目配置',
      description: 'missing/invalid 均不从官方工程 JSON 推断 gameType。',
      permission: 'gdevelop.config.read',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.config.put',
      method: 'PUT',
      path: '/dev/api/gdevelop/projects/{gameId}/config',
      summary: '使用 revision CAS 更新 Playmesh GDevelop 项目配置',
      permission: 'gdevelop.config.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerGameIdParameter],
      requestBodySchema: _putSchema,
      additionalResponses: {409: 'expectedRevision 已过期或当前配置损坏'},
      chatEnabled: false,
      agentEnabled: false,
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
    final gameId = pathParameters['gameId']!;
    if (definition.id == 'gdevelop.project.config.get') {
      final result = await gateway.gdevelopProjectConfig.read(gameId);
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        ...result.toJson(),
      });
      return;
    }
    final body = await _jsonBodyWithLimit(
      request,
      GDevelopProjectConfigStore.maxBytes,
    );
    if ((body.length != 6 && body.length != 7) ||
        !body.keys.every(
          const {
            'schemaVersion',
            'gameType',
            'minPlayers',
            'maxPlayers',
            'tags',
            'webRuntimeMultithreading',
            'expectedRevision',
          }.contains,
        ) ||
        body['schemaVersion'] != GDevelopProjectConfig.schemaVersion ||
        body['gameType'] is! String ||
        body['minPlayers'] is! int ||
        body['maxPlayers'] is! int ||
        body['tags'] is! List ||
        (body.containsKey('webRuntimeMultithreading') &&
            body['webRuntimeMultithreading'] is! bool) ||
        body['expectedRevision'] is! int ||
        (body['expectedRevision']! as int) < 0) {
      throw const FormatException('GDevelop config PUT 请求格式无效');
    }
    final config = await gateway.gdevelopRestoreTransactions.runProjectMutation(
      gameId,
      () => gateway.gdevelopProjectConfig.update(
        gameId: gameId,
        gameType: GDevelopProjectGameType.parse(body['gameType']! as String),
        minPlayers: body['minPlayers']! as int,
        maxPlayers: body['maxPlayers']! as int,
        tags: GDevelopProjectConfig.normalizeTags(body['tags']! as List),
        webRuntimeMultithreading:
            body['webRuntimeMultithreading'] as bool? ?? false,
        expectedRevision: body['expectedRevision']! as int,
      ),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'status': GDevelopProjectConfigStatus.ready.wireName,
      'config': config.toJson(),
    });
  }
}
