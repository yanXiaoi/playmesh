part of '../../developer_web_gateway_io.dart';

class _GDevelopEditorInstanceMiddleware implements _DeveloperRequestMiddleware {
  const _GDevelopEditorInstanceMiddleware();

  static const _apiPrefix = '/dev/api/gdevelop/';
  static const _leasePrefix = '/dev/api/gdevelop/editor-instance/';
  static const _nativeFileSaveTransferPrefix =
      '/dev/api/gdevelop/native-file-saves/';
  static final _aiSessionPath = RegExp(
    r'^/dev/api/gdevelop/projects/[^/]+/ai/editor-sessions/([^/]+)(?:/|$)',
  );

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  ) async {
    final route = request.uri.path;
    if (!route.startsWith(_apiPrefix) ||
        route.startsWith(_leasePrefix) ||
        _isNativeFileSaveHostTransfer(request, route)) {
      await next();
      return;
    }
    final agentRequest =
        request.headers.value(developerAiChannelHeader)?.trim() == 'agent';
    if (agentRequest) {
      final editorSessionId = _aiSessionPath.firstMatch(route)?.group(1);
      final validAgentBinding = editorSessionId != null
          ? gateway.gdevelopEditorInstances.validatesAiSession(editorSessionId)
          : route == '/dev/api/gdevelop/ai/tools' &&
                gateway.gdevelopEditorInstances.hasActiveAiSessionBinding;
      if (validAgentBinding) {
        await next();
        return;
      }
    }
    final instanceId =
        request.headers.value(gdevelopEditorInstanceHeader) ?? '';
    final pageId = request.headers.value(gdevelopEditorPageHeader) ?? '';
    final leaseToken = request.headers.value(gdevelopEditorLeaseHeader) ?? '';
    if (!gateway.gdevelopEditorInstances.validates(
      instanceId: instanceId,
      pageId: pageId,
      leaseToken: leaseToken,
    )) {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'gdevelop_editor_lease_required',
        '请求未绑定当前 GDevelop 编辑器实例',
      );
      return;
    }
    await next();
  }

  /// A successful, lease-bound POST hands the staged transfer to the native
  /// App host. Its HttpClient is outside the WebView lease wrapper, so the
  /// authenticated GET/DELETE continuation must not require page lease
  /// headers. Authentication middleware still runs before this middleware.
  static bool _isNativeFileSaveHostTransfer(HttpRequest request, String route) {
    if (request.method != 'GET' && request.method != 'DELETE') return false;
    if (!route.startsWith(_nativeFileSaveTransferPrefix)) return false;
    final transferId = route.substring(_nativeFileSaveTransferPrefix.length);
    return transferId.isNotEmpty && !transferId.contains('/');
  }
}
