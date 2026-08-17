part of '../../developer_web_gateway_io.dart';

class _AiApprovalOperation implements _DeveloperHttpOperation {
  const _AiApprovalOperation();

  static const _decisionSchema = <String, Object?>{
    'type': 'object',
    'required': ['decision'],
    'properties': {
      'decision': {
        'type': 'string',
        'enum': ['once', 'project', 'always', 'reject'],
      },
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'ai_approvals.list',
      method: 'GET',
      path: '/dev/api/ai-approvals',
      summary: '读取等待开发者决定的 AI 危险操作',
      permission: 'ai.approval.manage',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'ai_approvals.decide',
      method: 'POST',
      path: '/dev/api/ai-approvals/{approvalId}',
      summary: '允许一次、按项目允许、始终允许或拒绝 AI 危险操作',
      permission: 'ai.approval.manage',
      parameters: [
        DeveloperOperationParameter(
          name: 'approvalId',
          location: DeveloperOperationParameterLocation.path,
          description: '待审批请求 ID',
          required: true,
        ),
      ],
      requestBodySchema: _decisionSchema,
      requestExample: {'decision': 'once'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'ai_approval_grants.list',
      method: 'GET',
      path: '/dev/api/ai-approval-grants',
      summary: '读取按项目和工具持久保存的 AI 始终允许授权',
      permission: 'ai.approval.manage',
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'ai_approval_grants.revoke',
      method: 'DELETE',
      path: '/dev/api/ai-approval-grants/{grantId}',
      summary: '撤销一个按项目和工具持久保存的 AI 授权',
      permission: 'ai.approval.manage',
      parameters: [
        DeveloperOperationParameter(
          name: 'grantId',
          location: DeveloperOperationParameterLocation.path,
          description: '持久授权 ID',
          required: true,
        ),
      ],
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
    if (definition.id == 'ai_approvals.list') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'approvals': gateway.approvalBroker.pending,
      });
      return;
    }
    if (definition.id == 'ai_approval_grants.list') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'grants': await gateway.approvalBroker.listAlwaysGrants(),
      });
      return;
    }
    if (definition.id == 'ai_approval_grants.revoke') {
      final grantId = pathParameters['grantId']!;
      final removed = await gateway.approvalBroker.revokeAlways(grantId);
      if (!removed) {
        await _error(
          request.response,
          HttpStatus.notFound,
          requestId,
          'ai_approval_grant_not_found',
          '持久 AI 审批授权不存在',
        );
        return;
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'grantId': grantId,
        'revoked': true,
      });
      return;
    }
    final body = await _jsonBody(request);
    final rawDecision = body['decision'];
    if (rawDecision is! String) {
      throw const FormatException('decision 必须是字符串');
    }
    final decision = switch (rawDecision) {
      'once' => DeveloperAiApprovalDecision.once,
      'project' => DeveloperAiApprovalDecision.project,
      'always' => DeveloperAiApprovalDecision.always,
      'reject' => DeveloperAiApprovalDecision.reject,
      _ => throw const FormatException(
        'decision 只支持 once、project、always 或 reject',
      ),
    };
    await gateway.approvalBroker.decide(
      pathParameters['approvalId']!,
      decision,
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'approvalId': pathParameters['approvalId'],
      'decision': decision.name,
      'accepted': true,
    });
  }
}
