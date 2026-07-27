part of '../../developer_web_gateway_io.dart';

class _ProjectPublishOperation implements _DeveloperHttpOperation {
  const _ProjectPublishOperation();

  static const _publishSchema = <String, Object?>{
    'type': 'object',
    'required': ['sourceIds'],
    'additionalProperties': false,
    'properties': {
      'sourceIds': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 32,
        'uniqueItems': true,
        'items': {'type': 'string', 'minLength': 1, 'maxLength': 128},
      },
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'projects.publish_sources',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/publish',
      summary: '列出当前项目可发布的游戏源，不返回访问令牌或上传密钥',
      parameters: [developerProjectIdParameter],
      chatEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'projects.publish',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/publish',
      summary: '完整校验项目并将同一游戏包发布到所选游戏源',
      description: '请求体只接受 sourceIds；上传凭据始终保留在 App 内。',
      permission: 'project.publish',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _publishSchema,
      requestExample: {
        'sourceIds': ['official', 'community'],
      },
      additionalResponses: {
        409: '发布服务未接线或所选源已不可用',
        422: '项目完整校验失败，未导出或上传游戏包',
        503: '发布服务不可用',
      },
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
    final projectId = pathParameters['projectId']!;
    await _requireProject(gateway, projectId);
    if (request.method == 'GET') {
      final publisher = gateway.projectPublisher;
      final sources = publisher == null
          ? const <DeveloperPublishSource>[]
          : await publisher.listCandidates();
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'available': publisher != null,
        'sources': sources.map((source) => source.toJson()).toList(),
      });
      return;
    }

    final body = await _jsonBody(request);
    final sourceIds = _sourceIds(body);
    final publisher = gateway.projectPublisher;
    if (publisher == null) {
      await _error(
        request.response,
        HttpStatus.serviceUnavailable,
        requestId,
        'publishing_unavailable',
        '当前 App 尚未接入游戏源发布服务',
      );
      return;
    }

    final candidates = await publisher.listCandidates();
    final candidateIds = candidates.map((source) => source.id).toSet();
    final unavailable = sourceIds
        .where((sourceId) => !candidateIds.contains(sourceId))
        .toList(growable: false);
    if (unavailable.isNotEmpty) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'publish_source_not_eligible',
          'message': '所选游戏源已不可用，请刷新候选列表后重试',
        },
        'unavailableSourceIds': unavailable,
      });
      return;
    }

    final validation = await gateway.catalog.validateProject(projectId);
    if (!validation.valid) {
      developerEventHub.emit({
        'type': 'project.publish.rejected',
        'projectId': projectId,
        'reason': 'package_validation_failed',
        'timestamp': gateway.clock().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.unprocessableEntity, {
        'requestId': requestId,
        'error': {
          'code': 'package_validation_failed',
          'message': '项目完整校验未通过，未导出或上传游戏包',
        },
        'validation': validation.toJson(),
      });
      return;
    }

    final game = await gateway.catalog.prepareGame(projectId);
    final result = await publisher.publish(
      game: game,
      sourceIds: sourceIds,
      onEvent: (event) {
        developerEventHub.emit({
          'type': 'project.publish.status',
          'projectId': projectId,
          ...event.toJson(),
          'timestamp': gateway.clock().toUtc().millisecondsSinceEpoch,
        });
      },
    );
    developerEventHub.emit({
      'type': 'project.published',
      'projectId': projectId,
      'gameId': result.gameId,
      'version': result.version,
      'succeeded': result.succeeded,
      'partiallySucceeded': result.partiallySucceeded,
      'failedSourceIds': result.failedSourceIds,
      'timestamp': gateway.clock().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'validation': validation.toJson(),
      'result': result.toJson(),
    });
  }

  Future<void> _requireProject(
    _IoDeveloperWebGateway gateway,
    String projectId,
  ) async {
    final projects = await gateway.catalog.listProjects();
    if (!projects.any((project) => project.id == projectId)) {
      throw StateError('开发者项目不存在');
    }
  }

  List<String> _sourceIds(Map<String, Object?> body) {
    if (body.keys.any((key) => key != 'sourceIds')) {
      throw const FormatException('发布请求只允许 sourceIds 字段');
    }
    final raw = body['sourceIds'];
    if (raw is! List || raw.isEmpty || raw.length > 32) {
      throw const FormatException('sourceIds 必须包含 1 到 32 个游戏源 ID');
    }
    final result = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      if (value is! String) {
        throw const FormatException('sourceIds 只能包含字符串');
      }
      final sourceId = value.trim();
      if (sourceId.isEmpty || sourceId.length > 128) {
        throw const FormatException('游戏源 ID 长度必须为 1 到 128 个字符');
      }
      if (!seen.add(sourceId)) {
        throw const FormatException('sourceIds 不得重复');
      }
      result.add(sourceId);
    }
    return List.unmodifiable(result);
  }
}
