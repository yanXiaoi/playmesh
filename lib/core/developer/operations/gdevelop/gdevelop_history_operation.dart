part of '../../developer_web_gateway_io.dart';

class _GDevelopHistoryOperation implements _DeveloperHttpOperation {
  const _GDevelopHistoryOperation();

  static const _safeInlineResourceMimes = <String>{
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/avif',
    'audio/mpeg',
    'audio/ogg',
    'audio/wav',
    'audio/x-wav',
    'audio/mp4',
    'audio/aac',
    'audio/flac',
    'audio/webm',
    'video/mp4',
    'video/webm',
    'video/ogg',
  };

  static const _createRootSchema = <String, Object?>{
    'type': 'object',
    'required': ['gameId', 'origin'],
    'properties': {
      'gameId': {
        'type': 'string',
        'maxLength': 64,
        'pattern': r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$',
      },
      'origin': {
        'type': 'string',
        'enum': ['create', 'import', 'duplicate'],
      },
      'fileIdentifier': {'type': 'string'},
      'name': {'type': 'string'},
    },
  };

  static const _bindRootSchema = <String, Object?>{
    'type': 'object',
    'properties': {
      'fileIdentifier': {'type': 'string'},
      'name': {'type': 'string'},
    },
  };

  static const _resourceSchema = <String, Object?>{
    'type': 'object',
    'required': ['logicalId', 'contentHash', 'mime', 'size'],
    'properties': {
      'logicalId': {'type': 'string', 'maxLength': 1024},
      'name': {'type': 'string', 'maxLength': 255},
      'contentHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
      'mime': {'type': 'string'},
      'size': {'type': 'integer', 'minimum': 1},
      'metadata': {'type': 'object'},
    },
  };

  static const _projectFileSchema = <String, Object?>{
    'type': 'object',
    'required': ['path', 'content'],
    'properties': {
      'path': {'type': 'string'},
      'content': {'type': 'object'},
    },
  };

  static const _projectSchema = <String, Object?>{
    'type': 'object',
    'required': ['baseRevision', 'source', 'projectFiles', 'resources'],
    'properties': {
      'baseRevision': {'type': 'integer', 'minimum': 0},
      'source': {
        'type': 'string',
        'enum': ['user', 'system'],
      },
      'projectFiles': {'type': 'array', 'items': _projectFileSchema},
      'resources': {'type': 'array', 'items': _resourceSchema},
    },
  };

  static const _snapshotSchema = <String, Object?>{
    'type': 'object',
    'required': [
      'baseRevision',
      'reason',
      'source',
      'projectFiles',
      'resources',
    ],
    'properties': {
      'baseRevision': {'type': 'integer', 'minimum': 0},
      'source': {
        'type': 'string',
        'enum': ['user', 'system'],
      },
      'projectFiles': {'type': 'array', 'items': _projectFileSchema},
      'resources': {'type': 'array', 'items': _resourceSchema},
      'reason': {
        'type': 'string',
        'enum': ['explicit_save', 'important_change', 'autosave'],
      },
    },
  };

  static const _restorePrepareSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'idempotencyKey',
      'baseRevision',
      'targetRevision',
      'source',
      'currentProjectFiles',
      'currentResources',
    ],
    'properties': {
      'idempotencyKey': {
        'type': 'string',
        'pattern': r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
      },
      'baseRevision': {'type': 'integer', 'minimum': 1},
      'targetRevision': {'type': 'integer', 'minimum': 1},
      'source': {
        'type': 'string',
        'enum': ['user', 'system'],
      },
      'currentProjectFiles': {'type': 'array', 'items': _projectFileSchema},
      'currentResources': {'type': 'array', 'items': _resourceSchema},
      'clientId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
    },
  };

  static const _restoreAckSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['projectFilesHash', 'resourceManifestHash'],
    'properties': {
      'projectFilesHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
      'resourceManifestHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
    },
  };

  static const _emptySchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
  };

  static const _presenceSchema = <String, Object?>{
    'type': 'object',
    'required': ['resources'],
    'properties': {
      'resources': {
        'type': 'array',
        'maxItems': 2048,
        'items': {
          'type': 'object',
          'required': ['contentHash', 'size'],
          'properties': {
            'contentHash': {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
            'size': {'type': 'integer', 'minimum': 1},
          },
        },
      },
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.project.list',
      method: 'GET',
      path: '/dev/api/gdevelop/projects',
      summary: '列出 App 权威的 GDevelop 托管项目与 current evidence',
      permission: 'gdevelop.history.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.create',
      method: 'POST',
      path: '/dev/api/gdevelop/projects',
      summary: '为 GDevelop 新项目分配 Playmesh managed root',
      permission: 'project.create',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 201,
      requestBodySchema: _createRootSchema,
      additionalResponses: {409: 'gameId 已存在'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.open',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{gameId}/open',
      summary: '打开并绑定现有 GDevelop 项目根',
      permission: 'gdevelop.history.read',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [developerGameIdParameter],
      requestBodySchema: _bindRootSchema,
      additionalResponses: {409: '项目 kind 冲突'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.metadata.patch',
      method: 'PATCH',
      path: '/dev/api/gdevelop/projects/{gameId}',
      summary: '更新 GDevelop 项目名称或浏览器记录元数据',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [developerGameIdParameter],
      requestBodySchema: _bindRootSchema,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.project.delete',
      method: 'DELETE',
      path: '/dev/api/gdevelop/projects/{gameId}',
      summary: '删除完整 GDevelop 本地工程，失败时记录重试',
      permission: 'project.delete',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.list',
      method: 'GET',
      path: '/dev/api/gdevelop/projects/{gameId}/history',
      summary: '列出 GDevelop 工程本地历史',
      permission: 'gdevelop.history.read',
      parameters: [developerGameIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.clear',
      method: 'DELETE',
      path: '/dev/api/gdevelop/projects/{gameId}/history',
      summary: '仅删除 GDevelop 历史版本，保留当前工程源码',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.current.get',
      method: 'GET',
      path: '/dev/api/gdevelop/projects/{gameId}/history/current',
      summary: '原样读取 GDevelop 当前工程与资源清单供 WebIDE 打开',
      permission: 'gdevelop.history.read',
      parameters: [developerGameIdParameter],
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.current.put',
      method: 'PUT',
      path: '/dev/api/gdevelop/projects/{gameId}/history/current',
      summary: '更新 GDevelop 当前工程资源 pin，不创建历史修订',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerGameIdParameter],
      requestBodySchema: _projectSchema,
      additionalResponses: {413: '工程或资源超过本地历史配额'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.diff',
      method: 'GET',
      path: '/dev/api/gdevelop/projects/{gameId}/history/diff',
      summary: '比较两个 GDevelop 历史修订及其资源清单',
      permission: 'gdevelop.history.read',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'fromRevision',
          location: DeveloperOperationParameterLocation.query,
          description: '来源修订号',
          required: true,
          schema: {'type': 'integer', 'minimum': 1},
        ),
        DeveloperOperationParameter(
          name: 'toRevision',
          location: DeveloperOperationParameterLocation.query,
          description: '目标修订号',
          required: true,
          schema: {'type': 'integer', 'minimum': 1},
        ),
      ],
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.resource.presence',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{gameId}/history/resources/presence',
      summary: '批量返回尚未进入当前项目 CAS 的 GDevelop 资源',
      description: '客户端只上传 missing；历史仍 pin 的旧 hash 可直接复用。',
      permission: 'gdevelop.history.read',
      parameters: [developerGameIdParameter],
      requestBodySchema: _presenceSchema,
      additionalResponses: {413: '资源数量、大小或请求体超过上限'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.resource.put',
      method: 'PUT',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/resources/{contentHash}',
      summary: '按 SHA-256 流式暂存 GDevelop 资源',
      description: '必须提供 Content-Length；服务端流式复算 hash，30 秒无数据即超时。',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'contentHash',
          location: DeveloperOperationParameterLocation.path,
          description: '资源 SHA-256 小写十六进制',
          required: true,
        ),
      ],
      additionalResponses: {408: '资源上传超过空闲超时', 413: '单资源超过配置上限'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.resource.get',
      method: 'GET',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/resources/{contentHash}',
      summary: '按安全 hash 路径原样读取 GDevelop current 资源',
      permission: 'gdevelop.history.read',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'contentHash',
          location: DeveloperOperationParameterLocation.path,
          description: '资源 SHA-256 小写十六进制',
          required: true,
        ),
      ],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.revision.resource.get',
      method: 'GET',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/revisions/{revision}/resources/{contentHash}',
      summary: '读取指定 GDevelop 历史修订中精确匹配的资源',
      description: 'logicalId 与 contentHash 必须同时属于该修订的资源清单。',
      permission: 'gdevelop.history.read',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'revision',
          location: DeveloperOperationParameterLocation.path,
          description: '历史修订号',
          required: true,
          schema: {'type': 'integer', 'minimum': 1},
        ),
        DeveloperOperationParameter(
          name: 'contentHash',
          location: DeveloperOperationParameterLocation.path,
          description: '资源 SHA-256 小写十六进制',
          required: true,
        ),
        DeveloperOperationParameter(
          name: 'logicalId',
          location: DeveloperOperationParameterLocation.query,
          description: '该修订资源清单中的逻辑标识',
          required: true,
        ),
      ],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.snapshot',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{gameId}/history/snapshots',
      summary: '创建 GDevelop 工程与完整资源历史修订',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerGameIdParameter],
      requestBodySchema: _snapshotSchema,
      additionalResponses: {
        409: 'baseRevision 冲突或资源尚未暂存',
        413: '工程或资源超过本地历史配额',
      },
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.prepare',
      method: 'POST',
      path: '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions',
      summary: '冻结 GDevelop 恢复意图与完整 old/target evidence',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      successStatus: 201,
      parameters: [developerGameIdParameter],
      requestBodySchema: _restorePrepareSchema,
      additionalResponses: {409: 'baseline 冲突或项目已被另一事务锁定'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.commit',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions/{txId}/commit',
      summary: '提交已准备的 GDevelop 恢复事务',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: '服务端恢复事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _emptySchema,
      additionalResponses: {409: '恢复事务进入 CONFLICT'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.status',
      method: 'GET',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions/{txId}',
      summary: '读取稳定的 GDevelop 恢复事务或 receipt',
      permission: 'gdevelop.history.read',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: '服务端恢复事务 ID',
          required: true,
        ),
      ],
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.ack',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions/{txId}/ack',
      summary: '确认浏览器已持久化 target evidence',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: '服务端恢复事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _restoreAckSchema,
      additionalResponses: {409: '浏览器 evidence 不匹配'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.recover',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions/recover',
      summary: '重启后恢复只前进事务并补发 receipt 事件',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: [developerGameIdParameter],
      requestBodySchema: _emptySchema,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.history.restore.abort',
      method: 'POST',
      path:
          '/dev/api/gdevelop/projects/{gameId}/history/restore-transactions/{txId}/abort',
      summary: '显式放弃 PREPARED 或 CONFLICT 恢复事务',
      permission: 'gdevelop.history.write',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      dangerous: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'txId',
          location: DeveloperOperationParameterLocation.path,
          description: '服务端恢复事务 ID',
          required: true,
        ),
      ],
      requestBodySchema: _emptySchema,
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
    if (definition.id == 'gdevelop.project.list') {
      final listed = await gateway.gdevelopHistory.listManagedProjects();
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'activeGameId': listed.activeGameId,
        'projects': listed.projects.map((project) => project.toJson()).toList(),
        // 坏根不静默丢弃；HTTP 是否升级为 fail-fast 由产品策略另行冻结。
        'diagnostics': listed.diagnostics
            .map((diagnostic) => diagnostic.toJson())
            .toList(),
      });
      return;
    }
    if (definition.id == 'gdevelop.project.create') {
      final body = await _jsonBodyWithLimit(request, 64 * 1024);
      final gameId = body['gameId'];
      final origin = body['origin'];
      if (gameId is! String || origin is! String) {
        throw const FormatException('gameId 和 origin 必须是字符串');
      }
      final parsedOrigin = GDevelopProjectEnsureOrigin.parse(origin);
      if (!{
        GDevelopProjectEnsureOrigin.create,
        GDevelopProjectEnsureOrigin.importProject,
        GDevelopProjectEnsureOrigin.duplicate,
      }.contains(parsedOrigin)) {
        throw const FormatException('GDevelop create origin 无效');
      }
      final identity = ProjectProvisioningService.validateNewProjectIdentity(
        gameId: gameId,
        name: body['name'] as String? ?? gameId,
      );
      final created = await gateway.gdevelopRestoreTransactions
          .runProjectAllocation(identity.gameId, () async {
            final info = await gateway.gdevelopHistory.createProjectRoot(
              gameId: identity.gameId,
              origin: parsedOrigin,
              fileIdentifier: body['fileIdentifier'] as String?,
              name: identity.name,
            );
            final configInitialized = await gateway.gdevelopProjectConfig
                .initializeNewProject(info.gameId);
            return (info: info, configInitialized: configInitialized);
          });
      await _json(request.response, HttpStatus.created, {
        'requestId': requestId,
        'project': created.info.toJson(),
        'configInitialized': created.configInitialized,
        'historyCapability': GDevelopProjectHistoryAdapter.capability,
      });
      return;
    }
    final gameId = pathParameters['gameId']!;
    switch (definition.id) {
      case 'gdevelop.project.open':
        final body = await _jsonBodyWithLimit(request, 64 * 1024);
        final info = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(
              gameId,
              () => gateway.gdevelopHistory.openProjectRoot(
                gameId: gameId,
                fileIdentifier: body['fileIdentifier'] as String?,
                name: body['name'] as String?,
              ),
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'project': info.toJson(),
          'historyCapability': GDevelopProjectHistoryAdapter.capability,
        });
        return;
      case 'gdevelop.project.metadata.patch':
        final body = await _jsonBodyWithLimit(request, 64 * 1024);
        final info = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(
              gameId,
              () => gateway.gdevelopHistory.updateProjectMetadata(
                gameId: gameId,
                fileIdentifier: body['fileIdentifier'] as String?,
                name: body['name'] as String?,
              ),
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'project': info.toJson(),
        });
        return;
      case 'gdevelop.project.delete':
        final result = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(gameId, () async {
              await gateway.approvalBroker.clearScopeApprovals(
                scopeKind: 'gdevelop',
                scopeId: gameId,
              );
              return gateway.gdevelopHistory.deleteProject(gameId);
            });
        await _json(
          request.response,
          result.pendingRetry ? HttpStatus.accepted : HttpStatus.ok,
          {
            'requestId': requestId,
            'gameId': gameId,
            // packages/{gameId} 已在一次同卷 rename 中从权威项目列表摘除；
            // cleanupPending 仅表示不可见 tombstone 尚待物理回收。
            'projectDeleted': true,
            'historyDeleted': true,
            'configDeleted': true,
            'cleanupPending': result.pendingRetry,
          },
        );
        return;
      case 'gdevelop.history.list':
        final versions = await gateway.gdevelopHistory.list(gameId);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'capability': GDevelopProjectHistoryAdapter.capability,
          'gameId': gameId,
          'retention': _retentionJson(gateway.gdevelopHistory.retentionPolicy),
          'versions': versions
              .map((version) => version.toJson(includeChangeSummary: true))
              .toList(),
        });
        return;
      case 'gdevelop.history.clear':
        await gateway.gdevelopRestoreTransactions.runProjectMutation(
          gameId,
          () => gateway.gdevelopHistory.clearHistory(gameId),
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'gameId': gameId,
          'historyDeleted': true,
          'currentPreserved':
              await gateway.gdevelopHistory.currentReferenceSnapshot(gameId) !=
              null,
        });
        return;
      case 'gdevelop.history.current.get':
        final current = await gateway.gdevelopHistory.openCurrent(gameId);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'capability': GDevelopProjectHistoryAdapter.capability,
          'gameId': gameId,
          'current': current,
        });
        return;
      case 'gdevelop.history.current.put':
        final body = await _jsonBodyWithLimit(
          request,
          GDevelopProjectHistoryAdapter.maxProjectFilesBytes + 1024 * 1024,
        );
        final input = _projectInput(body);
        final result = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(gameId, () async {
              final configSnapshot = await gateway.gdevelopRestoreTransactions
                  .captureProjectConfigSnapshot(gameId);
              return gateway.gdevelopHistory.saveCurrent(
                projectId: gameId,
                baseRevision: input.baseRevision,
                source: input.source,
                projectFiles: input.projectFiles,
                resources: input.resources,
                projectConfigSnapshot: configSnapshot,
              );
            });
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'gameId': gameId,
          'current': result.version.toJson(),
          'historyCreated': false,
        });
        return;
      case 'gdevelop.history.diff':
        final from = int.tryParse(
          request.uri.queryParameters['fromRevision'] ?? '',
        );
        final to = int.tryParse(
          request.uri.queryParameters['toRevision'] ?? '',
        );
        if (from == null || to == null) {
          throw const FormatException('fromRevision 和 toRevision 必须是整数');
        }
        final diff = await gateway.gdevelopHistory.diff(
          projectId: gameId,
          fromRevision: from,
          toRevision: to,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...diff.toJson(),
        });
        return;
      case 'gdevelop.history.resource.presence':
        final body = await _jsonBodyWithLimit(request, 512 * 1024);
        final rawResources = body['resources'];
        if (rawResources is! List) {
          throw const FormatException('resources 必须是数组');
        }
        if (rawResources.length > 2048) {
          throw const FormatException('GDevelop 资源预检最多支持 2048 项');
        }
        final references = rawResources
            .map((raw) {
              if (raw is! Map) throw const FormatException('资源预检项无效');
              final hash = raw['contentHash'];
              final size = raw['size'];
              if (hash is! String || size is! int) {
                throw const FormatException('资源预检项无效');
              }
              return LocalCasObjectReference(hash: hash, bytes: size);
            })
            .toList(growable: false);
        final missing = await gateway.gdevelopHistory.missingResources(
          projectId: gameId,
          resources: references,
        );
        final missingHashes = missing.map((item) => item.hash).toSet();
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'gameId': gameId,
          'missing': missing.map(_presenceReferenceJson).toList(),
          'available': references
              .where((item) => !missingHashes.contains(item.hash))
              .map(_presenceReferenceJson)
              .toList(),
        });
        return;
      case 'gdevelop.history.resource.put':
        final length = request.contentLength;
        if (length < 1) {
          throw const FormatException('资源上传必须提供有效 Content-Length');
        }
        final reference = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(
              gameId,
              () => gateway.gdevelopHistory.stageResourceStream(
                projectId: gameId,
                expectedHash: pathParameters['contentHash']!,
                contentLength: length,
                bytes: request,
              ),
            );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'gameId': gameId,
          'contentHash': reference.hash,
          'size': reference.bytes,
          'staged': true,
        });
        return;
      case 'gdevelop.history.resource.get':
        final bytes = await gateway.gdevelopHistory.readOpenResource(
          projectId: gameId,
          contentHash: pathParameters['contentHash']!,
        );
        request.response.headers
          ..contentType = ContentType.binary
          ..set(HttpHeaders.cacheControlHeader, 'no-store')
          ..set('Content-Disposition', 'attachment');
        request.response.add(bytes);
        await request.response.close();
        return;
      case 'gdevelop.history.revision.resource.get':
        final revision = int.tryParse(pathParameters['revision'] ?? '');
        final logicalId = request.uri.queryParameters['logicalId'];
        if (revision == null || logicalId == null) {
          throw const FormatException('revision 和 logicalId 必须有效');
        }
        final result = await gateway.gdevelopHistory.readResourceAtRevision(
          projectId: gameId,
          revision: revision,
          logicalId: logicalId,
          contentHash: pathParameters['contentHash']!,
        );
        final mayRenderInline = _safeInlineResourceMimes.contains(
          result.resource.mime.trim().toLowerCase(),
        );
        request.response.headers
          ..contentType = ContentType.parse(result.resource.mime)
          ..set(HttpHeaders.cacheControlHeader, 'private, immutable')
          ..set(HttpHeaders.etagHeader, '"${result.resource.contentHash}"')
          ..set(
            'Content-Disposition',
            mayRenderInline ? 'inline' : 'attachment',
          )
          ..set('X-Content-Type-Options', 'nosniff');
        request.response.add(result.bytes);
        await request.response.close();
        return;
      case 'gdevelop.history.snapshot':
        final body = await _jsonBodyWithLimit(
          request,
          GDevelopProjectHistoryAdapter.maxProjectFilesBytes + 1024 * 1024,
        );
        final input = _projectInput(body);
        final reasonValue = body['reason'];
        if (reasonValue is! String) {
          throw const FormatException('reason 必须是字符串');
        }
        final reason = GDevelopHistoryReason.parse(reasonValue);
        if ({
          GDevelopHistoryReason.beforeRestore,
          GDevelopHistoryReason.restore,
        }.contains(reason)) {
          throw const FormatException('snapshot reason 无效');
        }
        final result = await gateway.gdevelopRestoreTransactions
            .runProjectMutation(gameId, () async {
              final configSnapshot = await gateway.gdevelopRestoreTransactions
                  .captureProjectConfigSnapshot(gameId);
              return gateway.gdevelopHistory.snapshot(
                projectId: gameId,
                baseRevision: input.baseRevision,
                reason: reason,
                source: input.source,
                projectFiles: input.projectFiles,
                resources: input.resources,
                projectConfigSnapshot: configSnapshot,
              );
            });
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'gameId': gameId,
          'version': result.version.toJson(),
          'deduplicated': result.deduplicated,
          'historyCreated': result.historyCreated,
        });
        return;
      case 'gdevelop.history.restore.prepare':
        final body = await _jsonBodyWithLimit(
          request,
          GDevelopProjectHistoryAdapter.maxProjectFilesBytes + 1024 * 1024,
        );
        final idempotencyKey = body['idempotencyKey'];
        final baseRevision = body['baseRevision'];
        final targetRevision = body['targetRevision'];
        final source = body['source'];
        final currentProjectFiles = body['currentProjectFiles'];
        final currentResources = body['currentResources'];
        if (body.keys.any(
              (key) => !const {
                'idempotencyKey',
                'baseRevision',
                'targetRevision',
                'source',
                'currentProjectFiles',
                'currentResources',
                'clientId',
              }.contains(key),
            ) ||
            idempotencyKey is! String ||
            baseRevision is! int ||
            targetRevision is! int ||
            source is! String ||
            currentProjectFiles is! List ||
            currentResources is! List ||
            (body['clientId'] != null && body['clientId'] is! String)) {
          throw const FormatException('GDevelop restore 请求格式无效');
        }
        final transaction = await gateway.gdevelopRestoreTransactions.prepare(
          gameId: gameId,
          idempotencyKey: idempotencyKey,
          baseRevision: baseRevision,
          targetRevision: targetRevision,
          source: GDevelopHistorySource.parse(source),
          currentProjectFiles: gdevelopProjectFilesFromJson(
            currentProjectFiles,
          ),
          currentResources: _resources(currentResources),
          clientId: body['clientId'] as String?,
        );
        final targetSnapshot = await gateway.gdevelopRestoreTransactions
            .targetSnapshot(transaction);
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          'transaction': transaction.toJson(targetSnapshot: targetSnapshot),
        });
        return;
      case 'gdevelop.history.restore.commit':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopRestoreTransactions.commit(
          gameId: gameId,
          txId: pathParameters['txId']!,
        );
        final restored = await gateway.gdevelopRestoreTransactions
            .restoredSnapshot(transaction);
        await _json(
          request.response,
          transaction.phase == PendingProjectCommitPhase.conflict
              ? HttpStatus.conflict
              : HttpStatus.ok,
          {
            'requestId': requestId,
            'transaction': transaction.toJson(restored: restored),
          },
        );
        return;
      case 'gdevelop.history.restore.status':
        final transaction = await gateway.gdevelopRestoreTransactions.status(
          gameId: gameId,
          txId: pathParameters['txId']!,
        );
        final restored = await gateway.gdevelopRestoreTransactions
            .restoredSnapshot(transaction);
        final targetSnapshot = await gateway.gdevelopRestoreTransactions
            .targetSnapshot(transaction);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction.toJson(
            targetSnapshot: targetSnapshot,
            restored: restored,
          ),
        });
        return;
      case 'gdevelop.history.restore.ack':
        final body = await _jsonBodyWithLimit(request, 8 * 1024);
        if (body.length != 2 ||
            !body.keys.every(
              const {'projectFilesHash', 'resourceManifestHash'}.contains,
            ) ||
            body['projectFilesHash'] is! String ||
            body['resourceManifestHash'] is! String) {
          throw const FormatException('GDevelop restore ACK 请求无效');
        }
        final transaction = await gateway.gdevelopRestoreTransactions
            .acknowledge(
              gameId: gameId,
              txId: pathParameters['txId']!,
              browserEvidence: GDevelopRestoreBrowserEvidence(
                projectFilesHash: body['projectFilesHash']! as String,
                resourceManifestHash: body['resourceManifestHash']! as String,
              ),
            );
        await _json(
          request.response,
          transaction.phase == PendingProjectCommitPhase.conflict
              ? HttpStatus.conflict
              : HttpStatus.ok,
          {'requestId': requestId, 'transaction': transaction.toJson()},
        );
        return;
      case 'gdevelop.history.restore.recover':
        await _requireEmptyJsonBody(request);
        final recovery = await gateway.gdevelopRestoreTransactions.recover(
          gameId,
        );
        final transaction = recovery.transaction;
        final restored = transaction == null
            ? null
            : await gateway.gdevelopRestoreTransactions.restoredSnapshot(
                transaction,
              );
        final targetSnapshot = transaction == null
            ? null
            : await gateway.gdevelopRestoreTransactions.targetSnapshot(
                transaction,
              );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction?.toJson(
            targetSnapshot: targetSnapshot,
            restored: restored,
          ),
          'replayedEventTxIds': recovery.replayedEventTxIds,
        });
        return;
      case 'gdevelop.history.restore.abort':
        await _requireEmptyJsonBody(request);
        final transaction = await gateway.gdevelopRestoreTransactions.abort(
          gameId: gameId,
          txId: pathParameters['txId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'transaction': transaction.toJson(),
        });
        return;
    }
  }
}

({
  int baseRevision,
  GDevelopHistorySource source,
  List<GDevelopProjectFile> projectFiles,
  List<GDevelopProjectResource> resources,
})
_projectInput(Map<String, Object?> body) {
  final baseRevision = body['baseRevision'];
  final source = body['source'];
  final projectFiles = body['projectFiles'];
  final resources = body['resources'];
  if (baseRevision is! int || baseRevision < 0) {
    throw const FormatException('GDevelop 工程 baseRevision 无效');
  }
  if (source is! String) {
    throw const FormatException('GDevelop 工程 source 无效');
  }
  if (projectFiles is! List) {
    throw const FormatException('GDevelop 工程 projectFiles 必须是数组');
  }
  if (resources is! List) {
    throw const FormatException('GDevelop 工程 resources 必须是数组');
  }
  return (
    baseRevision: baseRevision,
    source: GDevelopHistorySource.parse(source),
    projectFiles: gdevelopProjectFilesFromJson(projectFiles),
    resources: _resources(resources),
  );
}

List<GDevelopProjectResource> _resources(List<Object?> resources) {
  final result = <GDevelopProjectResource>[];
  for (var index = 0; index < resources.length; index += 1) {
    final raw = resources[index];
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw FormatException('GDevelop resources[$index] 必须是 JSON 对象');
    }
    try {
      result.add(
        GDevelopProjectResource.fromJson(Map<String, Object?>.from(raw)),
      );
    } on FormatException catch (error) {
      throw FormatException('GDevelop resources[$index]: ${error.message}');
    }
  }
  return List.unmodifiable(result);
}

Map<String, Object?> _retentionJson(LocalVersionRetentionPolicy policy) => {
  'maxVersionsPerProject': policy.maxVersionsPerNamespace,
  'maxUniqueBytesPerProject': policy.maxUniqueBytesPerNamespace,
  'maxObjectBytes': policy.maxObjectBytes,
  'stagingTtlSeconds': policy.stagingTtl.inSeconds,
  'maxProjectFilesBytes': GDevelopProjectHistoryAdapter.maxProjectFilesBytes,
};

Map<String, Object?> _presenceReferenceJson(
  LocalCasObjectReference reference,
) => {'contentHash': reference.hash, 'size': reference.bytes};

Future<void> _requireEmptyJsonBody(HttpRequest request) async {
  final body = await _jsonBodyWithLimit(request, 1024);
  if (body.isNotEmpty) {
    throw const FormatException('该 GDevelop 事务请求不接受字段');
  }
}
