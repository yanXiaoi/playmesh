part of '../../developer_web_gateway_io.dart';

/// Gateway protocol used by both the local copy/paste Chat surface and the
/// external Agent surface. Neither surface executes an LLM inside Playmesh.
class _GDevelopAiOperation implements _DeveloperHttpOperation {
  const _GDevelopAiOperation();

  static const _projectBase = '/dev/api/gdevelop/projects/{gameId}/ai';
  static const _sessionBase = '$_projectBase/editor-sessions';
  static const _sessionPath = '$_sessionBase/{editorSessionId}';
  static const _approvalModePath =
      '$_projectBase/editor-settings/{editorSessionId}/approval-mode';
  static const _callBase = '$_sessionPath/calls';
  static const _resourceStagingPath =
      '$_sessionPath/resource-staging/{contentHash}';
  static const _promptModeParameter = DeveloperOperationParameter(
    name: 'mode',
    location: DeveloperOperationParameterLocation.query,
    description: '当前提示词视图；Chat 不含 Token，Agent 使用开发者根 Token',
    schema: {
      'type': 'string',
      'enum': ['chat', 'agent'],
    },
  );
  static const _promptBaseUrlParameter = DeveloperOperationParameter(
    name: 'baseUrl',
    location: DeveloperOperationParameterLocation.query,
    description: '当前设备状态接口枚举出的 Agent 可访问 Base URL',
  );

  static const _contextSchema = <String, Object?>{
    'type': 'object',
    'required': [
      'schemaVersion',
      'selectedScene',
      'projectSummary',
      'capabilities',
    ],
    'additionalProperties': false,
    'properties': {
      'schemaVersion': {
        'type': 'string',
        'enum': [GDevelopAiProjectContext.schemaVersion],
      },
      'selectedScene': {
        'oneOf': [
          {'type': 'null'},
          {'type': 'object'},
        ],
      },
      'projectSummary': {'type': 'object'},
      'capabilities': {'type': 'object'},
    },
  };

  static const _openSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['mode', 'locale'],
    'properties': {
      'mode': {
        'type': 'string',
        'enum': ['chat', 'agent'],
      },
      'locale': {'type': 'string'},
      'context': _contextSchema,
      'resumeEditorSessionId': {'type': 'string'},
    },
  };

  static const _sessionPatchSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'locale': {'type': 'string'},
      'context': _contextSchema,
    },
  };

  static const _approvalModeSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['approvalMode'],
    'properties': {
      'approvalMode': {
        'type': 'string',
        'enum': ['request_approval', 'always_allow'],
      },
    },
  };

  static const _turnSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'clientMessageId': {'type': 'string'},
      'echo': {'type': 'integer', 'minimum': 1, 'maximum': 9007199254740991},
    },
  };

  static const _callSchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['turnId', 'callId', 'idempotencyKey', 'toolName', 'arguments'],
    'properties': {
      'turnId': {'type': 'string'},
      'callId': {'type': 'string'},
      'idempotencyKey': {'type': 'string'},
      'toolName': {'type': 'string'},
      'arguments': {'type': 'object'},
      'input': {'type': 'object'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.tools',
      method: 'GET',
      path: '/dev/api/gdevelop/ai/tools',
      summary: '读取版本固定的 GDevelop 5 EditorFunctions 工具合约',
      permission: 'gdevelop.ai.read',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.open',
      method: 'POST',
      path: _sessionBase,
      summary: '开启 Chat 或 Agent 的 GDevelop 编辑器会话',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 201,
      parameters: [developerGameIdParameter],
      requestBodySchema: _openSchema,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.get',
      method: 'GET',
      path: _sessionPath,
      summary: '读取 GDevelop AI 编辑器会话',
      permission: 'gdevelop.ai.read',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.approval_mode.get',
      method: 'GET',
      path: _approvalModePath,
      summary: '读取当前 GDevelop AI 编辑器会话的审批模式',
      permission: 'ai.approval.manage',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.approval_mode.update',
      method: 'PUT',
      path: _approvalModePath,
      summary: '修改当前 GDevelop AI 编辑器会话的审批模式',
      permission: 'ai.approval.manage',
      risk: DeveloperOperationRisk.high,
      idempotent: true,
      parameters: [developerGameIdParameter],
      requestBodySchema: _approvalModeSchema,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.tools',
      method: 'GET',
      path: '$_sessionPath/tools',
      summary: '读取当前 AI 会话固定的 GDevelop 工具合约或指定工具详情',
      permission: 'gdevelop.ai.read',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.locale',
      method: 'PATCH',
      path: _sessionPath,
      summary: '只修改当前 GDevelop AI 会话语言',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.low,
      parameters: [developerGameIdParameter],
      requestBodySchema: _sessionPatchSchema,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.close',
      method: 'DELETE',
      path: _sessionPath,
      summary: '关闭 GDevelop AI 编辑器会话并取消未完成调用',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.low,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.session.prompt',
      method: 'GET',
      path: '$_sessionPath/prompt.txt',
      summary: '为同一 GDevelop AI 会话生成 Chat 或 Agent 视图提示词',
      description:
          'mode 省略时兼容会话原 mode；Chat 永不包含 Token，Agent 包含与源码开发区相同的持久 Developer Token。',
      permission: 'gdevelop.ai.read',
      parameters: [
        developerGameIdParameter,
        _promptModeParameter,
        _promptBaseUrlParameter,
      ],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.resource_staging.put',
      method: 'PUT',
      path: _resourceStagingPath,
      summary: 'Agent-only 流式暂存 GDevelop 资源到当前 AI 会话',
      description:
          '仅接受前台 Agent 通道；远程与回环地址使用相同的会话和认证边界。原始 body 不进入日志。支持 chunked 流；以 Content-Type 与 SHA-256 path 透传并校验资源。',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.medium,
      requiresForegroundView: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'contentHash',
          location: DeveloperOperationParameterLocation.path,
          description: '资源原始字节 SHA-256 小写十六进制',
          required: true,
        ),
      ],
      additionalResponses: {403: '非 Agent 通道'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.resource_staging.get',
      method: 'GET',
      path: _resourceStagingPath,
      summary: 'WebIDE 一次性读取当前会话内存暂存的 Agent 资源',
      permission: 'gdevelop.ai.read',
      risk: DeveloperOperationRisk.low,
      requiresForegroundView: true,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.turn.create',
      method: 'POST',
      path: '$_sessionPath/turns',
      summary: '创建具有 clientMessageId 幂等边界和可选批次 echo 的 AI turn',
      permission: 'gdevelop.ai.write',
      successStatus: 201,
      parameters: [developerGameIdParameter],
      requestBodySchema: _turnSchema,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.turn.cancel',
      method: 'POST',
      path: '$_sessionPath/turns/{turnId}/cancel',
      summary: '取消一个 turn 内全部尚未终止的调用',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.call.enqueue',
      method: 'POST',
      path: _callBase,
      summary: '严格校验并入队一个 GDevelop EditorFunctions 调用',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      successStatus: 202,
      parameters: [developerGameIdParameter],
      requestBodySchema: _callSchema,
      additionalResponses: {409: '调用 ID 或幂等键冲突'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.call.list',
      method: 'GET',
      path: _callBase,
      summary: '按 sequence 增量读取 GDevelop AI 调用状态',
      permission: 'gdevelop.ai.read',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.call.next',
      method: 'POST',
      path: '$_callBase/next',
      summary: '串行租用下一个已获批调用',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.low,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.call.execution',
      method: 'POST',
      path: '$_callBase/{callId}/execution',
      summary: '提交 WebIDE 内部工具函数的业务执行结果',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.call.cancel',
      method: 'POST',
      path: '$_callBase/{callId}/cancel',
      summary: '取消 GDevelop AI 调用',
      permission: 'gdevelop.ai.write',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      parameters: [developerGameIdParameter],
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
    if (definition.id == 'gdevelop.ai.tools') {
      final registry = await gateway.loadGDevelopAiTools();
      final requestedToolName = request.uri.queryParameters['name'];
      if (requestedToolName != null) {
        try {
          await _json(request.response, HttpStatus.ok, {
            'requestId': requestId,
            'tool': registry.toolDetailJson(requestedToolName),
          });
        } on GDevelopAiToolValidationException {
          await _json(request.response, HttpStatus.notFound, {
            'requestId': requestId,
            'error': {
              'code': 'gdevelop_ai_tool_not_found',
              'reason':
                  'The requested GDevelop AI tool is not declared by the installed WebIDE.',
            },
          });
        }
        return;
      }
      final contract = registry.contractJson();
      final capabilitiesReference =
          await GDevelopAiProjectContext.capabilitiesReference(contract);
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        ...contract,
        'contractHash': capabilitiesReference['contractHash'],
        'capabilitiesReference': capabilitiesReference,
      });
      return;
    }
    final gameId = pathParameters['gameId']!;
    switch (definition.id) {
      case 'gdevelop.ai.session.open':
        await _openSession(gateway, request, requestId, gameId);
        return;
    }
    final editorSessionId = pathParameters['editorSessionId']!;
    final session = _sessionForGame(gateway, gameId, editorSessionId);
    switch (definition.id) {
      case 'gdevelop.ai.resource_staging.put':
        await _stageAgentResource(
          gateway,
          request,
          requestId,
          gameId,
          session,
          pathParameters['contentHash']!,
        );
        return;
      case 'gdevelop.ai.resource_staging.get':
        await _takeStagedResource(
          gateway,
          request,
          editorSessionId,
          pathParameters['contentHash']!,
        );
        return;
      case 'gdevelop.ai.session.tools':
        final registry = gateway.gdevelopAiSessions.toolRegistryForSession(
          editorSessionId,
        );
        final requestedToolName = request.uri.queryParameters['name'];
        if (requestedToolName != null) {
          try {
            await _json(request.response, HttpStatus.ok, {
              'requestId': requestId,
              'contractHash': registry.contractHash,
              'tool': registry.toolDetailJson(requestedToolName),
            });
          } on GDevelopAiToolValidationException {
            await _json(request.response, HttpStatus.notFound, {
              'requestId': requestId,
              'error': {
                'code': 'gdevelop_ai_tool_not_found',
                'reason':
                    'The requested GDevelop AI tool is not declared by this editor session snapshot.',
              },
            });
          }
          return;
        }
        final contract = registry.contractJson();
        final capabilitiesReference =
            await GDevelopAiProjectContext.capabilitiesReference(contract);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...contract,
          'contractHash': capabilitiesReference['contractHash'],
          'capabilitiesReference': capabilitiesReference,
        });
        return;
      case 'gdevelop.ai.session.get':
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'protocolVersion': GDevelopAiSessionService.protocolVersion,
          'session': session.toJson(),
        });
        return;
      case 'gdevelop.ai.approval_mode.get':
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'session': session.toJson(),
        });
        return;
      case 'gdevelop.ai.approval_mode.update':
        final body = await _jsonBodyWithLimit(request, 16 * 1024);
        final rawApprovalMode = body['approvalMode'];
        if (body.length != 1 || rawApprovalMode is! String) {
          throw const FormatException(
            'GDevelop AI approvalMode 请求必须精确包含 approvalMode',
          );
        }
        final approvalMode = GDevelopAiApprovalMode.parse(rawApprovalMode);
        final updated = gateway.gdevelopAiSessions.updateSession(
          editorSessionId,
          approvalMode: approvalMode,
        );
        if (approvalMode == GDevelopAiApprovalMode.alwaysAllow) {
          gateway.approvalBroker.approvePendingForEditorSession(
            editorSessionId,
          );
        }
        _emitGDevelopAiSession(updated, action: 'approval_mode_updated');
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'session': updated.toJson(),
        });
        return;
      case 'gdevelop.ai.session.locale':
        final body = await _jsonBodyWithLimit(
          request,
          GDevelopAiProjectContext.maxEncodedBytes + 64 * 1024,
        );
        if (body.isEmpty ||
            body.keys.any(
              (key) => !const {'locale', 'context'}.contains(key),
            )) {
          throw const FormatException(
            'GDevelop AI session PATCH 只允许 locale/context，且至少提供一项',
          );
        }
        final rawLocale = body['locale'];
        if (rawLocale != null && rawLocale is! String) {
          throw const FormatException('locale 必须是字符串');
        }
        final resolved = rawLocale == null
            ? null
            : await gateway.promptTemplates.resolveSessionLocale(
                rawLocale as String,
              );
        final context = body.containsKey('context')
            ? await GDevelopAiProjectContext.parse(
                body['context'],
                canonicalToolContract: gateway.gdevelopAiSessions
                    .toolRegistryForSession(editorSessionId)
                    .contractJson(),
              )
            : null;
        final updated = gateway.gdevelopAiSessions.updateSession(
          editorSessionId,
          locale: resolved,
          projectContext: context,
        );
        _emitGDevelopAiSession(
          updated,
          action: resolved != null && context != null
              ? 'locale_context_updated'
              : resolved != null
              ? 'locale_updated'
              : 'context_updated',
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'session': updated.toJson(),
        });
        return;
      case 'gdevelop.ai.session.close':
        final closeResult = gateway.gdevelopAiSessions.closeWithSnapshot(
          editorSessionId,
        );
        final diagnosticSession = closeResult.snapshot;
        if (diagnosticSession != null) {
          _emitGDevelopAiSession(diagnosticSession, action: 'closed');
        }
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'editorSessionId': editorSessionId,
          'closed': true,
        });
        return;
      case 'gdevelop.ai.session.prompt':
        await _servePrompt(gateway, request, gameId, session);
        return;
      case 'gdevelop.ai.turn.create':
        final body = await _jsonBodyWithLimit(request, 16 * 1024);
        final clientMessageId = body['clientMessageId'];
        final echo = body['echo'];
        if ((clientMessageId != null && clientMessageId is! String) ||
            (echo != null &&
                (echo is! int || echo < 1 || echo > 9007199254740991))) {
          throw const FormatException('GDevelop AI turn 请求无效');
        }
        if (body.keys.any(
          (key) => !const {'clientMessageId', 'echo'}.contains(key),
        )) {
          throw const FormatException('GDevelop AI turn 请求包含未知字段');
        }
        final turn = gateway.gdevelopAiSessions.createTurn(
          editorSessionId,
          echo: echo as int?,
          clientMessageId: clientMessageId as String?,
        );
        developerEventHub.emit({
          'type': 'gdevelop.ai.turn.created',
          'gameId': gameId,
          ...turn.toJson(),
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          'turn': turn.toJson(),
        });
        return;
      case 'gdevelop.ai.turn.cancel':
        final turnId = pathParameters['turnId']!;
        final cancelled = gateway.gdevelopAiSessions.cancelTurn(
          editorSessionId,
          turnId,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'editorSessionId': editorSessionId,
          'turnId': turnId,
          'cancelledCalls': cancelled
              .map((call) => call.toJson(requestId: requestId))
              .toList(),
        });
        return;
      case 'gdevelop.ai.call.enqueue':
        await _enqueueCall(gateway, request, requestId, gameId, session);
        return;
      case 'gdevelop.ai.call.list':
        final afterSequence = int.tryParse(
          request.uri.queryParameters['afterSequence'] ?? '0',
        );
        if (afterSequence == null) {
          throw const FormatException('afterSequence 必须是整数');
        }
        final calls = gateway.gdevelopAiSessions.calls(
          editorSessionId,
          afterSequence: afterSequence,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'editorSessionId': editorSessionId,
          'calls': calls
              .map((call) => call.toJson(requestId: requestId))
              .toList(),
        });
        return;
      case 'gdevelop.ai.call.next':
        final call = gateway.gdevelopAiSessions.leaseNext(editorSessionId);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'editorSessionId': editorSessionId,
          'call': call?.toJson(),
        });
        return;
      case 'gdevelop.ai.call.execution':
        await _finishExecution(
          gateway,
          request,
          requestId,
          editorSessionId,
          pathParameters['callId']!,
        );
        return;
      case 'gdevelop.ai.call.cancel':
        final call = gateway.gdevelopAiSessions.cancelCall(
          editorSessionId,
          pathParameters['callId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'call': call.toJson(requestId: requestId),
        });
        return;
    }
  }

  Future<void> _takeStagedResource(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String editorSessionId,
    String contentHash,
  ) async {
    final size = int.tryParse(request.uri.queryParameters['size'] ?? '');
    if (size == null || size < 1) throw const FormatException('size 必须是正整数');
    final bytes = gateway.gdevelopAiSessions.takeStagedResource(
      editorSessionId: editorSessionId,
      contentHash: contentHash,
      size: size,
    );
    request.response.headers
      ..contentType = ContentType.binary
      ..contentLength = bytes.length
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _stageAgentResource(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String gameId,
    GDevelopAiEditorSession session,
    String contentHash,
  ) async {
    final channel = request.headers.value(developerAiChannelHeader)?.trim();
    if (session.mode != GDevelopAiMode.agent || channel != 'agent') {
      await _error(
        request.response,
        HttpStatus.forbidden,
        requestId,
        'gdevelop_ai_resource_staging_agent_only',
        'GDevelop AI 资源暂存仅允许前台 Agent 通道',
      );
      return;
    }
    final length = request.contentLength;
    const maxBytes = 64 * 1024 * 1024;
    if (length == 0 || length > maxBytes) {
      throw const _DeveloperRequestTooLarge(maxBytes);
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in request) {
      buffer.add(chunk);
      if (buffer.length > maxBytes) {
        throw const _DeveloperRequestTooLarge(maxBytes);
      }
    }
    final bytes = buffer.takeBytes();
    await gateway.gdevelopAiSessions.stageResource(
      editorSessionId: session.id,
      expectedHash: contentHash,
      bytes: bytes,
    );
    request.response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'gameId': gameId,
      'staged': {
        'contentHash': contentHash,
        'mime':
            request.headers.contentType?.mimeType ?? 'application/octet-stream',
        'size': bytes.length,
      },
    });
  }

  Future<void> _openSession(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String gameId,
  ) async {
    final registrySnapshot = await gateway.loadGDevelopAiTools();
    final body = await _jsonBodyWithLimit(
      request,
      GDevelopAiProjectContext.maxEncodedBytes + 128 * 1024,
    );
    final mode = body['mode'];
    final locale = body['locale'];
    final resumeEditorSessionId = body['resumeEditorSessionId'];
    if (mode is! String ||
        locale is! String ||
        resumeEditorSessionId != null && resumeEditorSessionId is! String) {
      throw const FormatException('GDevelop AI session 请求无效');
    }
    if (body.keys.any(
      (key) => !const {
        'mode',
        'locale',
        'context',
        'resumeEditorSessionId',
      }.contains(key),
    )) {
      throw const FormatException('GDevelop AI session 请求包含未知字段');
    }
    final resolvedLocale = await gateway.promptTemplates.resolveSessionLocale(
      locale,
    );
    final context = body.containsKey('context')
        ? await GDevelopAiProjectContext.parse(
            body['context'],
            canonicalToolContract: registrySnapshot.contractJson(),
          )
        : null;
    final session = gateway.gdevelopAiSessions.reattachOrOpen(
      gameId: gameId,
      mode: GDevelopAiMode.parse(mode),
      locale: resolvedLocale,
      projectContext: context,
      resumeEditorSessionId: resumeEditorSessionId as String?,
      registry: registrySnapshot,
    );
    _emitGDevelopAiSession(session, action: 'opened');
    await _json(request.response, HttpStatus.created, {
      'requestId': requestId,
      'protocolVersion': GDevelopAiSessionService.protocolVersion,
      'session': session.toJson(),
    });
  }

  Future<void> _servePrompt(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String gameId,
    GDevelopAiEditorSession session,
  ) async {
    final requestedMode = request.uri.queryParameters['mode'];
    final promptMode = requestedMode == null
        ? session.mode
        : GDevelopAiMode.parse(requestedMode);
    final projectContext = session.projectContext;
    if (projectContext == null) {
      throw const GDevelopAiCallConflict(
        'project_context_missing',
        '生成提示词前必须上传 GDevelop AI project context',
      );
    }
    final templateId = promptMode == GDevelopAiMode.chat
        ? 'gdevelop-chat'
        : 'gdevelop-agent';
    final template = await gateway.promptTemplates.read(
      templateId,
      locale: session.locale,
    );
    final resources = await gateway.promptTemplates.resources(
      locale: session.locale,
    );
    String text(String key) => resources.text('gdevelop.$key');
    // ProjectContext is bounded editor context for prompt generation. The only
    // project state disclosed eagerly is the
    // bounded scene index because most editor tools require an exact scene_name.
    // Objects, resources, events, metadata and hashes stay behind tools. Like
    // GDevelop's structured function-call path, tool schemas are disclosed one
    // at a time on demand.
    final promptToolIndex = gateway.gdevelopAiSessions
        .toolRegistryForSession(session.id)
        .promptIndexJson(agent: promptMode == GDevelopAiMode.agent);
    final sceneIndex = projectContext.sceneIndexJson();
    final output = StringBuffer()
      ..writeln('===== ${text('title')} =====')
      ..writeln(template.content.trim())
      ..writeln()
      ..writeln('===== ${text('tools')} =====')
      ..writeln(const JsonEncoder.withIndent('  ').convert(promptToolIndex))
      ..writeln()
      ..writeln(text('toolDetailsInstruction'))
      ..writeln()
      ..writeln('===== ${text('scenes')} =====')
      ..writeln(const JsonEncoder.withIndent('  ').convert(sceneIndex))
      ..writeln()
      ..writeln('===== ${text('rules')} =====')
      ..writeln('- ${text('noStore')}');
    if (promptMode == GDevelopAiMode.chat) {
      output
        ..writeln()
        ..writeln('===== ${text('chatEnvelopeTitle')} =====')
        ..writeln(text('chatEnvelope'));
    } else {
      // Use the same fail-closed endpoint selection as the source-development
      // Agent prompt. A selected address must be one of /dev/api/status's
      // current Gateway addresses; arbitrary hosts, ports and URL components
      // are rejected by _resolvePromptBaseUrl.
      final origin = await _resolvePromptBaseUrl(gateway, request);
      final sessionApi =
          '/dev/api/gdevelop/projects/$gameId/ai/editor-sessions/${session.id}';
      _writeAgentHttpContract(
        output: output,
        isChinese: session.locale.toLowerCase().startsWith('zh'),
        origin: origin.toString(),
        token: gateway.token,
        sessionApi: sessionApi,
      );
    }
    if (promptMode == GDevelopAiMode.chat) {
      output
        ..writeln()
        ..writeln(text('chatFinal'));
    }
    final promptText = output.toString();
    final bytes = <int>[0xef, 0xbb, 0xbf, ...utf8.encode(promptText)];
    request.response.headers
      ..contentType = ContentType('text', 'plain', charset: 'utf-8')
      ..set(
        'Content-Disposition',
        'attachment; filename="playmesh-gdevelop-${promptMode.wireName}-prompt.txt"',
      )
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  void _writeAgentHttpContract({
    required StringBuffer output,
    required bool isChinese,
    required String origin,
    required String token,
    required String sessionApi,
  }) {
    String localized(String chinese, String english) =>
        isChinese ? chinese : english;

    output
      ..writeln()
      ..writeln('===== AGENT HTTP CONTRACT =====')
      ..writeln(
        localized(
          '使用模型运行环境的 HTTP 请求能力，严格按 baseUrl 和下列结构访问 Playmesh Developer Gateway。',
          'Use the model runtime\'s HTTP request capability to access the Playmesh Developer Gateway at baseUrl with the exact structures below.',
        ),
      )
      ..writeln(
        localized(
          '若该 HTTP 能力不可用，仅返回 {"status":"unavailable","code":"playmesh_gateway_http_unavailable"} 并停止。',
          'If this HTTP capability is unavailable, return only {"status":"unavailable","code":"playmesh_gateway_http_unavailable"} and stop.',
        ),
      )
      ..writeln('baseUrl: $origin')
      ..writeln()
      ..writeln(
        localized(
          '每个请求仅使用以下认证请求头：',
          'Authentication headers for every request:',
        ),
      )
      ..writeln('Authorization: Bearer $token')
      ..writeln('X-Playmesh-AI-Channel: agent')
      ..writeln(
        localized(
          '带 JSON body 的 POST 另外使用：',
          'For a POST with a JSON body also use:',
        ),
      )
      ..writeln('Content-Type: application/json')
      ..writeln(
        localized(
          'Authorization 请求头是 Token 的唯一位置。',
          'The Authorization header is the sole Token location.',
        ),
      )
      ..writeln()
      ..writeln('1. GET $sessionApi/tools?name={exactToolName}')
      ..writeln(
        localized(
          '使用此会话级 GET 完成工具索引中 discovery 所声明的详情查询；业务 call 以返回的精确工具详情为依据。',
          'Use this session-scoped GET for the details lookup declared by discovery in the tool index. The returned exact tool details define the business call.',
        ),
      )
      ..writeln()
      ..writeln('2. POST $sessionApi/turns')
      ..writeln(localized('请求 body 必须是：', 'The request body is exactly:'))
      ..writeln('{"clientMessageId":"<stable-unique-client-message-id>"}')
      ..writeln(
        localized(
          '从响应 turn.turnId 读取 turnId。',
          'Read turnId from response field turn.turnId.',
        ),
      )
      ..writeln()
      ..writeln('3. POST $sessionApi/calls')
      ..writeln(
        localized(
          '每次只入队一个 call，请求 body 必须恰好是以下单个对象：',
          'Enqueue exactly one call per request. The body is exactly this single object:',
        ),
      )
      ..writeln('{')
      ..writeln('  "turnId": "<turn.turnId>",')
      ..writeln('  "callId": "<stable-unique-call-id>",')
      ..writeln('  "idempotencyKey": "<stable-unique-idempotency-key>",')
      ..writeln('  "toolName": "<exact-business-tool-name>",')
      ..writeln('  "arguments": {"<fields-from-tool-details>": "<value>"}')
      ..writeln('}')
      ..writeln(
        localized(
          '请求顶层必须包含 turnId、callId、idempotencyKey、toolName 和 arguments。仅事件载荷工具还必须同时提交 input: {"eventPayload": <完整对象>}，其他工具不得带 input。input 与调用一同进入幂等指纹，审批后不能替换。',
          'The request must contain turnId, callId, idempotencyKey, toolName, and arguments. Event-payload tools must also submit input: {"eventPayload": <complete object>} in the same request; other tools must not include input. input is part of the idempotency fingerprint and cannot be replaced after approval.',
        ),
      )
      ..writeln()
      ..writeln('4. GET $sessionApi/calls?afterSequence=<lastSequence>')
      ..writeln(
        localized(
          '首次从 0 开始，之后使用已看到的最大 sequence 轮询状态；网络结果不明确时，后续动作从 callId/idempotencyKey 对账开始。',
          'Start at 0, then poll with the greatest sequence already seen. After an uncertain network result, the next action begins with reconciliation by callId/idempotencyKey.',
        ),
      )
      ..writeln()
      ..writeln(
        localized(
          '仅可调用本合同明确列出的接口。',
          'Call only the endpoints explicitly listed in this contract.',
        ),
      )
      ..writeln(
        localized(
          '收到 HTTP 409 时按 callId/idempotencyKey 查询调用状态；不要创建不同内容的同键调用。',
          'On HTTP 409, reconcile the call by callId/idempotencyKey; do not reuse the same key for different call content.',
        ),
      )
      ..writeln()
      ..writeln(
        localized(
          '当工具详情声明事件载荷时，仅按完整 payload Schema、生成事件合同和 executionConfig 构造载荷，并将 input: {"eventPayload": <完整对象>} 直接放入创建 call 的同一请求。',
          'When tool details declare an event payload, construct it only from the complete payload schema, generated-events contract, and executionConfig, then include input: {"eventPayload": <complete object>} directly in the same request that creates the call.',
        ),
      );
  }

  Future<void> _enqueueCall(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String gameId,
    GDevelopAiEditorSession session,
  ) async {
    final body = await _jsonBodyWithLimit(request, 8 * 1024 * 1024);
    final turnId = body['turnId'];
    final callId = body['callId'];
    final idempotencyKey = body['idempotencyKey'];
    final toolName = body['toolName'];
    final arguments = body['arguments'];
    final rawInput = body['input'];
    if (turnId is! String ||
        callId is! String ||
        idempotencyKey is! String ||
        toolName is! String ||
        arguments is! Map) {
      throw const FormatException('GDevelop AI call 请求无效');
    }
    if (body.keys.any(
      (key) => !const {
        'turnId',
        'callId',
        'idempotencyKey',
        'toolName',
        'arguments',
        'input',
      }.contains(key),
    )) {
      throw const FormatException('GDevelop AI call 请求包含未知字段');
    }
    final allowAgentOnlyTools =
        session.mode == GDevelopAiMode.agent &&
        request.headers.value(developerAiChannelHeader)?.trim() == 'agent';
    final sessionRegistry = gateway.gdevelopAiSessions.toolRegistryForSession(
      session.id,
    );
    final validatedArguments = sessionRegistry.validateCall(
      toolName,
      Map<String, Object?>.from(arguments),
      allowAgentOnlyTools: allowAgentOnlyTools,
    );
    final expectsEventPayload =
        sessionRegistry.definition(toolName).executionKind ==
        GDevelopAiToolExecutionKind.eventPayload;
    final eventPayload = rawInput is Map ? rawInput['eventPayload'] : null;
    if (expectsEventPayload &&
        (rawInput is! Map ||
            rawInput.length != 1 ||
            !rawInput.containsKey('eventPayload') ||
            eventPayload is! Map)) {
      throw const FormatException('事件工具 input 必须精确为 {eventPayload: <完整对象>}');
    }
    if (!expectsEventPayload && rawInput != null) {
      throw const FormatException('非事件工具不允许提供 input');
    }
    final call = gateway.gdevelopAiSessions.enqueueCall(
      editorSessionId: session.id,
      turnId: turnId,
      callId: callId,
      idempotencyKey: idempotencyKey,
      toolName: toolName,
      arguments: validatedArguments,
      input: rawInput is Map ? Map<String, Object?>.from(rawInput) : null,
      allowAgentOnlyTools: allowAgentOnlyTools,
    );
    if (call.state == GDevelopAiCallState.awaitingApproval &&
        gateway.gdevelopAiSessions.claimApprovalRequest(session.id, call.id)) {
      unawaited(_resolveApproval(gateway, requestId, gameId, session, call));
    }
    await _json(request.response, HttpStatus.accepted, {
      'requestId': requestId,
      'call': call.toJson(requestId: requestId),
    });
  }

  Future<void> _resolveApproval(
    _IoDeveloperWebGateway gateway,
    String requestId,
    String gameId,
    GDevelopAiEditorSession session,
    GDevelopAiCall call,
  ) async {
    final tool = gateway.gdevelopAiSessions
        .toolRegistryForSession(session.id)
        .definition(call.toolName);
    final result = await gateway.approvalBroker.request(
      requestId: requestId,
      cancellation: gateway.gdevelopAiSessions.cancellationSignal(
        session.id,
        call.id,
      ),
      autoApprove: () {
        try {
          final currentSession = gateway.gdevelopAiSessions.session(session.id);
          final currentCall = gateway.gdevelopAiSessions.call(
            session.id,
            call.id,
          );
          return currentSession.approvalMode ==
                  GDevelopAiApprovalMode.alwaysAllow ||
              currentCall.state != GDevelopAiCallState.awaitingApproval;
        } on GDevelopAiSessionNotFound {
          return false;
        }
      },
      subject: DeveloperAiApprovalSubject(
        scopeKind: 'gdevelop',
        scopeId: gameId,
        operationId: 'gdevelop.tool.${tool.name}',
        summary: tool.summary,
        description: 'GDevelop EditorFunctions: ${tool.name}',
        risk: tool.risk,
        dangerous: tool.approvalRequired,
        channel: 'gdevelop-${session.mode.wireName}',
        callId: call.id,
        editorSessionId: session.id,
      ),
    );
    try {
      gateway.gdevelopAiSessions.approvalDecision(
        editorSessionId: session.id,
        callId: call.id,
        approved: result == DeveloperAiApprovalResult.approved,
        rejectionCode: result == DeveloperAiApprovalResult.timeout
            ? 'approval_timeout'
            : 'approval_rejected',
        rejectionMessage: result == DeveloperAiApprovalResult.timeout
            ? 'GDevelop AI 调用等待审批超时'
            : '用户拒绝了 GDevelop AI 调用',
      );
    } on GDevelopAiSessionNotFound {
      // Closing the editor session cancels the call and resolves this race.
    } on GDevelopAiCallConflict {
      // A concurrent explicit cancel is already a terminal decision.
    }
  }

  Future<void> _finishExecution(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String editorSessionId,
    String callId,
  ) async {
    final existing = gateway.gdevelopAiSessions.call(editorSessionId, callId);
    if (existing.state.terminal) {
      await _executionReplay(request, requestId, existing);
      return;
    }
    final body = await _optionalJsonBody(request);
    _validateExecutionSubmission(body);

    final success = body['success']! as bool;
    final call = gateway.gdevelopAiSessions.finishCall(
      editorSessionId: editorSessionId,
      callId: callId,
      success: success,
      output: Map<String, Object?>.from(body['output']! as Map),
      errorCode: body['errorCode'] as String?,
      errorMessage: body['errorMessage'] as String?,
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'call': call.toJson(requestId: requestId),
    });
  }

  void _validateExecutionSubmission(Map<String, Object?> body) {
    const allowed = {'success', 'output', 'errorCode', 'errorMessage'};
    if (body.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
        'GDevelop AI execution 只允许 success、output、errorCode、errorMessage',
      );
    }
    final success = body['success'];
    final output = body['output'];
    final errorCode = body['errorCode'];
    final errorMessage = body['errorMessage'];
    if (success is! bool || output is! Map) {
      throw const FormatException(
        'GDevelop AI execution 必须包含 success 与 output',
      );
    }
    if ((errorCode != null && errorCode is! String) ||
        (errorMessage != null && errorMessage is! String)) {
      throw const FormatException('GDevelop AI execution 错误字段必须是字符串');
    }
    if (success && (errorCode != null || errorMessage != null)) {
      throw const FormatException('成功 execution 不能包含错误字段');
    }
  }

  Future<void> _executionReplay(
    HttpRequest request,
    String requestId,
    GDevelopAiCall call,
  ) async {
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'call': call.toJson(requestId: requestId),
      'idempotentReplay': true,
    });
  }
}

void _emitGDevelopAiSession(
  GDevelopAiEditorSession session, {
  required String action,
}) {
  developerEventHub.emit({
    'type': 'gdevelop.ai.session.updated',
    'action': action,
    ...session.toJson(),
    'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
  });
}

GDevelopAiEditorSession _sessionForGame(
  _IoDeveloperWebGateway gateway,
  String gameId,
  String editorSessionId,
) {
  final session = gateway.gdevelopAiSessions.session(editorSessionId);
  if (session.gameId != gameId) {
    throw const GDevelopAiSessionNotFound();
  }
  return session;
}
