part of '../../developer_web_gateway_io.dart';

class _GDevelopProjectAllocationOperation implements _DeveloperHttpOperation {
  const _GDevelopProjectAllocationOperation();

  static const _hashSchema = <String, Object?>{
    'type': 'string',
    'pattern': r'^[a-f0-9]{64}$',
  };

  static const _workspaceTargetSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'fileIdentifier',
      'gameId',
      'packageName',
      'projectUuid',
      'projectFilesHash',
      'resourceManifestHash',
    ],
    'properties': {
      'fileIdentifier': {'type': 'string'},
      'gameId': {'type': 'string'},
      'packageName': {'type': 'string'},
      'projectUuid': {'type': 'string'},
      'projectFilesHash': _hashSchema,
      'resourceManifestHash': _hashSchema,
    },
  };

  static const _prepareSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['idempotencyKey', 'gameId', 'origin', 'workspaceTarget'],
    'properties': {
      'idempotencyKey': {
        'type': 'string',
        'pattern': r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
      },
      'gameId': {'type': 'string'},
      'origin': {
        'type': 'string',
        'enum': ['create', 'import', 'copy'],
      },
      'name': {'type': 'string'},
      'clientId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
      'workspaceTarget': _workspaceTargetSchema,
    },
  };

  static const _resourceSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['logicalId', 'name', 'contentHash', 'mime', 'size'],
    'properties': {
      'logicalId': {'type': 'string'},
      'name': {'type': 'string'},
      'contentHash': _hashSchema,
      'mime': {'type': 'string'},
      'size': {'type': 'integer', 'minimum': 1},
      'metadata': {'type': 'object'},
    },
  };

  static const _resourcePresenceSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['resources'],
    'properties': {
      'resources': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 2048,
        'items': _resourceSchema,
      },
    },
  };

  static const _workspaceFinalizationSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'packageName',
      'projectUuid',
      'projectFilesHash',
      'projectFilesSize',
      'resourceManifestHash',
    ],
    'properties': {
      'packageName': {'type': 'string'},
      'projectUuid': {'type': 'string'},
      'projectFilesHash': _hashSchema,
      'projectFilesSize': {'type': 'integer', 'minimum': 1},
      'resourceManifestHash': _hashSchema,
    },
  };

  static const _emptySchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
  };

  static const _txIdParameters = [
    DeveloperOperationParameter(
      name: 'txId',
      location: DeveloperOperationParameterLocation.path,
      description: 'project allocation 事务 ID',
      required: true,
    ),
  ];

  static const _resourceParameters = [
    ..._txIdParameters,
    DeveloperOperationParameter(
      name: 'contentHash',
      location: DeveloperOperationParameterLocation.path,
      description: '已纳入事务资源计划的 SHA-256',
      required: true,
    ),
  ];

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.prepare',
      method: 'POST',
      path: '/dev/api/gdevelop/project-allocation-transactions',
      summary: '冻结 create/import/copy 的 App staging 与 workspace target',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      successStatus: 201,
      requestBodySchema: _prepareSchema,
      additionalResponses: {409: 'gameId 已占用、事务锁定或幂等键冲突'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.resources.presence',
      method: 'POST',
      path:
          '/dev/api/gdevelop/project-allocation-transactions/{txId}/resources/presence',
      summary: '追加事务资源计划并批量返回 staging CAS presence',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _txIdParameters,
      requestBodySchema: _resourcePresenceSchema,
      additionalResponses: {409: '资源计划或 phase 冲突', 413: '资源计划超出配额'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.resource.put',
      method: 'PUT',
      path:
          '/dev/api/gdevelop/project-allocation-transactions/{txId}/resources/{contentHash}',
      summary: '流式校验并写入事务 staging CAS 资源',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _resourceParameters,
      additionalResponses: {409: '资源未计划、内容不匹配或 phase 冲突', 413: '资源超出配额'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.workspace.project-files.put',
      method: 'PUT',
      path:
          '/dev/api/gdevelop/project-allocation-transactions/{txId}/workspace/project-files',
      summary: '流式写入 GDevelop 官方多文件 projectFiles JSON DTO',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _txIdParameters,
      additionalResponses: {409: '工程 evidence 或 phase 冲突', 413: '工程过大'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.workspace.finalize',
      method: 'POST',
      path:
          '/dev/api/gdevelop/project-allocation-transactions/{txId}/workspace/finalize',
      summary: '验证工程、官方资源顺序与 staging current 并冻结 workspace',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _txIdParameters,
      requestBodySchema: _workspaceFinalizationSchema,
      additionalResponses: {409: 'workspace evidence 或 phase 冲突'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.commit',
      method: 'POST',
      path: '/dev/api/gdevelop/project-allocation-transactions/{txId}/commit',
      summary: '复核 finalized workspace 后持久化 decision 并原子发布项目根',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _txIdParameters,
      requestBodySchema: _emptySchema,
      additionalResponses: {
        202: 'commit decision 已持久化，正在只向前恢复',
        409: 'decision 前发现冲突',
      },
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.status',
      method: 'GET',
      path: '/dev/api/gdevelop/project-allocation-transactions/{txId}',
      summary: '读取稳定 project allocation transaction/receipt',
      permission: 'gdevelop.project.allocate',
      parameters: _txIdParameters,
      additionalResponses: {404: '事务不存在或 receipt 已过期'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.recover',
      method: 'POST',
      path: '/dev/api/gdevelop/project-allocation-transactions/{txId}/recover',
      summary: '重启后恢复过期预决策或只向前完成 canonical 发布',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: _txIdParameters,
      requestBodySchema: _emptySchema,
      additionalResponses: {202: 'durable decision 尚未完成发布'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.allocation.abort',
      method: 'POST',
      path: '/dev/api/gdevelop/project-allocation-transactions/{txId}/abort',
      summary: '放弃 decision 前 allocation 并清理 sibling staging',
      permission: 'gdevelop.project.allocate',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: _txIdParameters,
      requestBodySchema: _emptySchema,
      additionalResponses: {409: 'durable decision 后禁止回退'},
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
    switch (definition.id) {
      case 'gdevelop.project.allocation.prepare':
        final body = await _jsonBodyWithLimit(request, 64 * 1024);
        if (body.keys.any(
              (key) => !const {
                'idempotencyKey',
                'gameId',
                'origin',
                'name',
                'clientId',
                'workspaceTarget',
              }.contains(key),
            ) ||
            body['idempotencyKey'] is! String ||
            body['gameId'] is! String ||
            body['origin'] is! String ||
            (body['name'] != null && body['name'] is! String) ||
            (body['clientId'] != null && body['clientId'] is! String)) {
          throw const FormatException('GDevelop allocation PREPARE 请求无效');
        }
        final transaction = await gateway.gdevelopProjectAllocation.prepare(
          gameId: body['gameId']! as String,
          idempotencyKey: body['idempotencyKey']! as String,
          origin: GDevelopProjectAllocationOrigin.parse(
            body['origin']! as String,
          ),
          name: body['name'] as String?,
          clientId: body['clientId'] as String?,
          workspaceTarget: GDevelopProjectAllocationWorkspaceTarget.fromJson(
            body['workspaceTarget'],
          ),
        );
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
      case 'gdevelop.project.allocation.resources.presence':
        final body = await _jsonBodyWithLimit(request, 2 * 1024 * 1024);
        if (body.length != 1 || body['resources'] is! List) {
          throw const FormatException(
            'GDevelop allocation resource presence 请求无效',
          );
        }
        final resources = (body['resources']! as List)
            .map((raw) {
              if (raw is! Map) {
                throw const FormatException('GDevelop allocation resource 无效');
              }
              final resourceJson = Map<String, Object?>.from(raw);
              const required = {
                'logicalId',
                'name',
                'contentHash',
                'mime',
                'size',
              };
              const allowed = {...required, 'metadata'};
              if (!resourceJson.keys.toSet().containsAll(required) ||
                  resourceJson.keys.any((key) => !allowed.contains(key))) {
                throw const FormatException(
                  'GDevelop allocation resource 字段无效',
                );
              }
              return GDevelopProjectResource.fromJson(resourceJson);
            })
            .toList(growable: false);
        final presence = await gateway.gdevelopProjectAllocation
            .resourcePresence(
              txId: pathParameters['txId']!,
              resources: resources,
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...presence.toJson(),
        });
        return;
      case 'gdevelop.project.allocation.resource.put':
        final reference = await gateway.gdevelopProjectAllocation
            .uploadResource(
              txId: pathParameters['txId']!,
              contentHash: pathParameters['contentHash']!,
              bytes: request,
              contentLength: request.contentLength < 0
                  ? null
                  : request.contentLength,
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'resource': reference.toJson(),
        });
        return;
      case 'gdevelop.project.allocation.workspace.project-files.put':
        final reference = await gateway.gdevelopProjectAllocation
            .uploadWorkspaceProjectFiles(
              txId: pathParameters['txId']!,
              bytes: request,
              contentLength: request.contentLength < 0
                  ? null
                  : request.contentLength,
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'project': reference.toJson(),
        });
        return;
      case 'gdevelop.project.allocation.workspace.finalize':
        final body = await _jsonBodyWithLimit(request, 8 * 1024);
        final transaction = await gateway.gdevelopProjectAllocation
            .finalizeWorkspace(
              txId: pathParameters['txId']!,
              evidence: GDevelopProjectAllocationWorkspaceFinalization.fromJson(
                body,
              ),
            );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.allocation.commit':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopProjectAllocation.commit(
          pathParameters['txId']!,
        );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.allocation.status':
        final transaction = await gateway.gdevelopProjectAllocation.status(
          pathParameters['txId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
      case 'gdevelop.project.allocation.recover':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopProjectAllocation.recover(
          pathParameters['txId']!,
        );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.allocation.abort':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopProjectAllocation.abort(
          pathParameters['txId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
    }
  }

  Future<void> _transactionResponse(
    HttpRequest request,
    String requestId,
    GDevelopProjectAllocationTransaction transaction,
  ) => _json(
    request.response,
    switch (transaction.phase) {
      GDevelopProjectAllocationPhase.commitRequested => HttpStatus.accepted,
      GDevelopProjectAllocationPhase.conflict => HttpStatus.conflict,
      _ => HttpStatus.ok,
    },
    {'requestId': requestId, 'transaction': transaction.toJson()},
  );
}
