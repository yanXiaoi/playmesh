part of '../../developer_web_gateway_io.dart';

class _AiContextOperation implements _DeveloperHttpOperation {
  const _AiContextOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'operations.context',
      method: 'GET',
      path: '/dev/api/ai-context',
      summary: '读取 AI 接口、鉴权和统一操作注册表上下文',
      permission: 'ai.context',
      chatBootstrap: true,
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
    final origin = Uri(
      scheme: request.requestedUri.scheme,
      host: request.requestedUri.host,
      port: request.requestedUri.port,
    );
    String endpoint(String path) => origin
        .replace(path: path, queryParameters: {'token': gateway.token})
        .toString();
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'catalogVersion': _DeveloperOperationRegistry.catalogVersion,
      'authentication': {
        'type': 'bearer',
        'token': gateway.token,
        'tokenHint': gateway.session.tokenHint,
        'authorizationHeader': 'Authorization: Bearer ${gateway.token}',
        'queryParameter': 'token=${gateway.token}',
        'scope': 'current_developer_session',
      },
      'aiExecution': {
        'channelHeader': developerAiChannelHeader,
        'channelExamples': ['chat', 'agent'],
        'dangerousApproval': {
          'event': 'ai.approval.requested',
          'decisionEndpoint': '/dev/api/ai-approvals/{approvalId}',
          'decisions': ['once', 'project', 'always', 'reject'],
          'timeoutSeconds': 30,
          'rejectedStatus': 403,
          'timeoutStatus': 408,
        },
      },
      'interfaces': {
        'operationCatalog': endpoint('/dev/api/operations'),
        'openapi': endpoint('/dev/openapi.json'),
        'docs': endpoint('/dev/docs'),
        'sdkManifest': endpoint('/dev/sdk-manifest.json'),
        'capabilityRegistry': endpoint('/dev/api/capabilities'),
        'capabilityTests': endpoint('/dev/api/capability-tests'),
        'events': endpoint('/dev/api/events'),
        'recentLogs': endpoint('/dev/api/logs?limit=50'),
        'projects': endpoint('/dev/api/projects'),
      },
      'operations': _developerOperationRegistry.catalog(
        where: (operation) =>
            gateway.gdevelopAiFeaturePolicy.exposesOperationId(operation.id) &&
            operation.agentEnabled,
      ),
      'rules': {
        'mainJsonWriteEndpoint': '/dev/api/projects/{projectId}/manifest',
        'mainJsonImmutableFields': ['id', 'author', 'lastModifiedAt'],
        'mainJsonManagedFields': ['sdkVersion', 'appSdkVersion'],
        'mainJsonRawFileWriteAllowed': false,
        'capabilitiesWriteEndpoint':
            '/dev/api/projects/{projectId}/capabilities',
        'fileChanges': {
          'preview': '/dev/api/projects/{projectId}/file-changes/preview',
          'apply': '/dev/api/projects/{projectId}/file-changes/apply',
          'types': [
            'create',
            'replace',
            'replace_text',
            'insert_before',
            'insert_after',
          ],
          'atomicApply': true,
          'revisionGuarded': true,
        },
        'localHistory': {
          'mergeWindowSeconds':
              DeveloperLocalHistoryStore.mergeWindow.inSeconds,
          'maxOperations': 100,
          'snapshotExcludes': ['data/', 'cache/'],
        },
        'runtimeLogs': {
          'event': 'runtime.log',
          'pollEndpoint': '/dev/api/logs?limit=50',
          'pollFilters': ['projectId', 'runId'],
          'pollMaxEntries': 50,
          'appCacheEntries': DeveloperEventHub.maxRecentLogs,
          'scope': 'local_device',
        },
      },
    });
  }
}
