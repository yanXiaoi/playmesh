part of '../../developer_web_gateway_io.dart';

class _GDevelopEditorInstanceOperation implements _DeveloperHttpOperation {
  const _GDevelopEditorInstanceOperation();

  static const _base = '/dev/api/gdevelop/editor-instance';
  static const _bodyLimit = 4096;

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.editor_instance.acquire',
      method: 'POST',
      path: '$_base/acquire',
      summary: '申请进程级 GDevelop 编辑器实例 lease',
      permission: 'gdevelop.editor_instance.acquire',
      idempotent: false,
      chatEnabled: false,
      agentEnabled: false,
      additionalResponses: {409: '已有未过期的编辑器实例'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.editor_instance.heartbeat',
      method: 'POST',
      path: '$_base/heartbeat',
      summary: '续租当前 GDevelop 编辑器实例',
      permission: 'gdevelop.editor_instance.heartbeat',
      idempotent: true,
      chatEnabled: false,
      agentEnabled: false,
      additionalResponses: {409: 'lease 已过期或不属于当前实例'},
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.editor_instance.release',
      method: 'POST',
      path: '$_base/release',
      summary: '显式释放当前 GDevelop 编辑器实例',
      permission: 'gdevelop.editor_instance.release',
      idempotent: true,
      chatEnabled: false,
      agentEnabled: false,
      additionalResponses: {409: 'lease 已过期或不属于当前实例'},
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
    final acquireCapability = _gdevelopEditorAcquireCapability(request);
    if (definition.id == 'gdevelop.editor_instance.acquire' &&
        !gateway.gdevelopEditorInstances.validatesAcquireCapability(
          acquireCapability,
        )) {
      await _invalidAcquireCapability(request.response, requestId);
      return;
    }
    final body = await _jsonBodyWithLimit(request, _bodyLimit);
    final instanceId = _requiredString(body, 'instanceId');
    final pageId = _requiredString(body, 'pageId');
    if (definition.id == 'gdevelop.editor_instance.acquire') {
      final previousLeaseToken = body['previousLeaseToken'];
      final resumeAfterReload = body['resumeAfterReload'];
      if (previousLeaseToken != null && previousLeaseToken is! String ||
          resumeAfterReload != null && resumeAfterReload is! bool) {
        throw const FormatException('GDevelop editor acquire 请求格式无效');
      }
      final authorized = gateway.gdevelopEditorInstances.acquireWithCapability(
        instanceId: instanceId,
        pageId: pageId,
        acquireCapability: acquireCapability,
        previousLeaseToken: previousLeaseToken as String?,
        resumeAfterReload: resumeAfterReload == true,
      );
      if (!authorized.authorized) {
        await _invalidAcquireCapability(request.response, requestId);
        return;
      }
      final result = authorized.acquireResult!;
      if (!result.acquired) {
        if (result.installationInProgress) {
          await _json(request.response, HttpStatus.conflict, {
            'requestId': requestId,
            'error': {
              'code': 'gdevelop_webide_install_in_progress',
              'message': 'GDevelop WebIDE 正在安装或更新',
            },
          });
          return;
        }
        await _json(request.response, HttpStatus.conflict, {
          'requestId': requestId,
          'error': {
            'code': 'gdevelop_editor_instance_occupied',
            'message': 'GDevelop 编辑器已在其他窗口中打开',
          },
          'occupied': result.occupiedBy!.toOccupiedJson(),
        });
        return;
      }
      request.response.cookies.add(
        _gdevelopEditorAcquireCapabilityCookie(authorized.nextCapability!),
      );
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'status': result.resumed ? 'resumed' : 'acquired',
        'lease': result.lease!.toClientJson(
          heartbeatInterval: gateway.gdevelopEditorInstances.heartbeatInterval,
        ),
      });
      return;
    }

    final leaseToken = _requiredString(body, 'leaseToken');
    if (definition.id == 'gdevelop.editor_instance.heartbeat') {
      final lease = gateway.gdevelopEditorInstances.heartbeat(
        instanceId: instanceId,
        pageId: pageId,
        leaseToken: leaseToken,
      );
      if (lease == null) {
        await _stale(request.response, requestId);
        return;
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'status': 'renewed',
        'expiresAt': lease.expiresAt.toIso8601String(),
      });
      return;
    }

    final released = gateway.gdevelopEditorInstances.release(
      instanceId: instanceId,
      pageId: pageId,
      leaseToken: leaseToken,
    );
    if (!released) {
      await _stale(request.response, requestId);
      return;
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  static String _requiredString(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('GDevelop editor $key 无效');
    }
    return value;
  }

  static Future<void> _stale(HttpResponse response, String requestId) => _error(
    response,
    HttpStatus.conflict,
    requestId,
    'gdevelop_editor_lease_stale',
    'GDevelop 编辑器 lease 已过期或不属于当前页面',
  );

  static Future<void> _invalidAcquireCapability(
    HttpResponse response,
    String requestId,
  ) => _error(
    response,
    HttpStatus.forbidden,
    requestId,
    'gdevelop_editor_acquire_capability_invalid',
    'GDevelop 编辑器 acquire capability 无效或已轮换',
  );
}

String _gdevelopEditorAcquireCapability(HttpRequest request) =>
    request.cookies
        .where((cookie) => cookie.name == gdevelopEditorAcquireCapabilityCookie)
        .map((cookie) => cookie.value)
        .firstOrNull ??
    '';

Cookie _gdevelopEditorAcquireCapabilityCookie(String capability) =>
    Cookie(gdevelopEditorAcquireCapabilityCookie, capability)
      ..httpOnly = true
      ..sameSite = SameSite.strict
      ..path = '/dev/api/gdevelop/editor-instance/acquire';
