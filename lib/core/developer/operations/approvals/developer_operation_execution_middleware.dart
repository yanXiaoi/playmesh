part of '../../developer_web_gateway_io.dart';

typedef _DeveloperOperationNext = Future<void> Function();

abstract interface class _DeveloperOperationExecutionMiddleware {
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition operation,
    Map<String, String> pathParameters,
    _DeveloperOperationNext next,
  );
}

class _DeveloperForegroundViewMiddleware
    implements _DeveloperOperationExecutionMiddleware {
  const _DeveloperForegroundViewMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition operation,
    Map<String, String> pathParameters,
    _DeveloperOperationNext next,
  ) async {
    if (!operation.requiresForegroundView) {
      await next();
      return;
    }
    final availability = await gateway.viewAvailability();
    if (!availability.available) {
      throw DeveloperViewUnavailable(availability);
    }
    await next();
  }
}

class _DeveloperAiApprovalMiddleware
    implements _DeveloperOperationExecutionMiddleware {
  const _DeveloperAiApprovalMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition operation,
    Map<String, String> pathParameters,
    _DeveloperOperationNext next,
  ) async {
    final channel = request.headers.value(developerAiChannelHeader)?.trim();
    if (!operation.dangerous || channel == null || channel.isEmpty) {
      await next();
      return;
    }
    final result = await gateway.approvalBroker.request(
      requestId: requestId,
      subject: DeveloperAiApprovalSubject(
        scopeKind: 'source',
        scopeId: pathParameters['projectId'],
        operationId: operation.id,
        summary: operation.summary,
        description: operation.description,
        risk: operation.risk.name,
        dangerous: operation.dangerous,
        channel: channel,
        method: operation.normalizedMethod,
        path: operation.path,
      ),
    );
    switch (result) {
      case DeveloperAiApprovalResult.approved:
        await next();
      case DeveloperAiApprovalResult.rejected:
        await _error(
          request.response,
          HttpStatus.forbidden,
          requestId,
          'ai_operation_rejected',
          '开发者拒绝了 AI 危险操作',
        );
      case DeveloperAiApprovalResult.timeout:
        await _error(
          request.response,
          HttpStatus.requestTimeout,
          requestId,
          'ai_approval_timeout',
          'AI 危险操作等待开发者批准超时',
        );
    }
  }
}
