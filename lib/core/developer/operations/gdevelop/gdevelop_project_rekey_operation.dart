part of '../../developer_web_gateway_io.dart';

class _GDevelopProjectRekeyOperation implements _DeveloperHttpOperation {
  const _GDevelopProjectRekeyOperation();

  static const _historyEvidenceSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'revision',
      'currentContentHash',
      'projectJsonHash',
      'resourceManifestHash',
    ],
    'properties': {
      'revision': {'type': 'integer', 'minimum': 1},
      'currentContentHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
      'projectJsonHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
      'resourceManifestHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
    },
  };

  static const _configEvidenceSchema = <String, Object?>{
    'oneOf': [
      {
        'type': 'object',
        'additionalProperties': false,
        'required': ['status'],
        'properties': {
          'status': {'const': 'missing'},
        },
      },
      {
        'type': 'object',
        'additionalProperties': false,
        'required': ['status', 'revision', 'contentHash', 'config'],
        'properties': {
          'status': {'const': 'ready'},
          'revision': {'type': 'integer', 'minimum': 1},
          'contentHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
          'config': {'type': 'object'},
        },
      },
    ],
  };

  static const _prepareSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'idempotencyKey',
      'newGameId',
      'expectedOldEvidence',
      'browserSource',
      'browserTarget',
    ],
    'properties': {
      'idempotencyKey': {
        'type': 'string',
        'pattern': r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
      },
      'newGameId': {'type': 'string'},
      'expectedOldEvidence': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['history', 'config'],
        'properties': {
          'history': _historyEvidenceSchema,
          'config': _configEvidenceSchema,
        },
      },
      'browserSource': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['fileIdentifier', 'projectJsonHash'],
        'properties': {
          'fileIdentifier': {'type': 'string'},
          'projectJsonHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
        },
      },
      'browserTarget': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['fileIdentifier', 'projectJsonHash'],
        'properties': {
          'fileIdentifier': {'type': 'string'},
          'projectJsonHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
        },
      },
      'clientId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
    },
  };

  static const _ackSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['fileMetadata', 'packageName', 'projectJsonHash'],
    'properties': {
      'fileMetadata': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['fileIdentifier', 'gameId'],
        'properties': {
          'fileIdentifier': {'type': 'string'},
          'gameId': {'type': 'string'},
        },
      },
      'packageName': {'type': 'string'},
      'projectJsonHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
    },
  };

  static const _emptySchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
  };

  static const _rollbackSchema = <String, Object?>{
    'oneOf': [_emptySchema, _ackSchema],
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.prepare',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions',
      summary: '冻结 packageName/gameId 原子迁移 staging 与 old/target evidence',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      successStatus: 201,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 GDevelop packageName/gameId',
          required: true,
        ),
      ],
      requestBodySchema: _prepareSchema,
      additionalResponses: {409: 'old evidence 变化、target 冲突或项目已锁定'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.commit',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/commit',
      summary: '提交 rekey decision 并原子发布新项目根',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: 'rekey 事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _emptySchema,
      additionalResponses: {409: 'target/source/staging 冲突或 phase 不允许提交'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.status',
      method: 'GET',
      path: '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}',
      summary: '读取稳定 rekey transaction/receipt',
      permission: 'gdevelop.project.rekey',
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: 'rekey 事务 ID',
          required: true,
        ),
      ],
      additionalResponses: {404: 'rekey 事务不存在或 receipt 已过期'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.ack',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/ack',
      summary: '确认浏览器已在单个 IndexedDB 事务中切换新身份',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: 'rekey 事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _ackSchema,
      additionalResponses: {
        202: 'BROWSER_UPDATED 已持久化，但副作用或旧项目根清理仍待 recover',
        409: '浏览器 evidence 不匹配、target 已变化或 phase 不允许 ACK',
      },
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.rollback',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/rollback',
      summary: '持久化回滚决议，并在浏览器恢复旧身份后删除新项目根',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: 'rekey 事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _rollbackSchema,
      additionalResponses: {
        202: '回滚决议已持久化，等待浏览器反向切换 evidence',
        409: '已越过墓碑提交点、evidence 变化或 phase 不允许回滚',
      },
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.recover',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/recover',
      summary: '重启后按 durable journal 默认回滚提交点前的 rekey',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
      ],
      requestBodySchema: _emptySchema,
      additionalResponses: {202: '等待浏览器反向切换或 cleanupPending 尚待幂等 recover'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.rekey.abort',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{oldGameId}/rekey-transactions/{txId}/abort',
      summary: '放弃尚未产生外部副作用的 PREPARED/CONFLICT rekey',
      permission: 'gdevelop.project.rekey',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'oldGameId',
          location: DeveloperOperationParameterLocation.path,
          description: '迁移前 gameId',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: 'rekey 事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _emptySchema,
      additionalResponses: {409: '已发布新项目根或 phase 不允许 abort'},
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
    final oldGameId = pathParameters['oldGameId']!;
    switch (definition.id) {
      case 'gdevelop.project.rekey.prepare':
        final body = await _jsonBodyWithLimit(request, 64 * 1024);
        if (body.keys.any(
              (key) => !const {
                'idempotencyKey',
                'newGameId',
                'expectedOldEvidence',
                'browserSource',
                'browserTarget',
                'clientId',
              }.contains(key),
            ) ||
            body['idempotencyKey'] is! String ||
            body['newGameId'] is! String ||
            (body['clientId'] != null && body['clientId'] is! String)) {
          throw const FormatException('GDevelop rekey PREPARE 请求无效');
        }
        final transaction = await gateway.gdevelopProjectRekey.prepare(
          oldGameId: oldGameId,
          newGameId: body['newGameId']! as String,
          idempotencyKey: body['idempotencyKey']! as String,
          expectedOldEvidence: GDevelopProjectRekeyExpectedEvidence.fromJson(
            body['expectedOldEvidence'],
            gameId: oldGameId,
          ),
          browserSource: GDevelopProjectRekeyBrowserTarget.fromJson(
            body['browserSource'],
          ),
          browserTarget: GDevelopProjectRekeyBrowserTarget.fromJson(
            body['browserTarget'],
          ),
          clientId: body['clientId'] as String?,
        );
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
      case 'gdevelop.project.rekey.commit':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopProjectRekey.commit(
          oldGameId: oldGameId,
          txId: pathParameters['txId']!,
        );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.rekey.rollback':
        final body = await _jsonBodyWithLimit(request, 8 * 1024);
        final transaction = await gateway.gdevelopProjectRekey.rollback(
          oldGameId: oldGameId,
          txId: pathParameters['txId']!,
          browserEvidence: body.isEmpty
              ? null
              : GDevelopProjectRekeyBrowserEvidence.fromJson(body),
        );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.rekey.status':
        final transaction = await gateway.gdevelopProjectRekey.status(
          oldGameId: oldGameId,
          txId: pathParameters['txId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
      case 'gdevelop.project.rekey.ack':
        final body = await _jsonBodyWithLimit(request, 8 * 1024);
        final transaction = await gateway.gdevelopProjectRekey.acknowledge(
          oldGameId: oldGameId,
          txId: pathParameters['txId']!,
          browserEvidence: GDevelopProjectRekeyBrowserEvidence.fromJson(body),
        );
        await _transactionResponse(request, requestId, transaction);
        return;
      case 'gdevelop.project.rekey.recover':
        await _requireEmptyJsonBody(request);
        final recovery = await gateway.gdevelopProjectRekey.recover(oldGameId);
        await _json(
          request.response,
          recovery.transaction?.phase ==
                      GDevelopProjectRekeyPhase.rollbackRequested ||
                  recovery.cleanupPendingTxIds.isNotEmpty
              ? HttpStatus.accepted
              : HttpStatus.ok,
          {
            'requestId': requestId,
            'transaction': recovery.transaction?.toJson(),
            'replayedEventTxIds': recovery.replayedEventTxIds,
            'cleanupPendingTxIds': recovery.cleanupPendingTxIds,
          },
        );
        return;
      case 'gdevelop.project.rekey.abort':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopProjectRekey.abort(
          oldGameId: oldGameId,
          txId: pathParameters['txId']!,
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
    GDevelopProjectRekeyTransaction transaction,
  ) => _json(
    request.response,
    transaction.phase == GDevelopProjectRekeyPhase.conflict
        ? HttpStatus.conflict
        : transaction.phase == GDevelopProjectRekeyPhase.browserUpdated ||
              transaction.phase ==
                  GDevelopProjectRekeyPhase.rollbackRequested ||
              transaction.record.payload.cleanupPending
        ? HttpStatus.accepted
        : HttpStatus.ok,
    {'requestId': requestId, 'transaction': transaction.toJson()},
  );
}
