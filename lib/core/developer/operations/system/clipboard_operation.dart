part of '../../developer_web_gateway_io.dart';

/// Provides the App WebView with a local, authenticated clipboard-read
/// fallback when the embedded browser does not expose navigator.clipboard.
///
/// The operation is deliberately absent from Chat/Agent catalogs and rejects
/// non-loopback callers: a remote Developer Gateway client must never be able
/// to read the clipboard of the machine running Playmesh.
class _ClipboardOperation implements _DeveloperHttpOperation {
  const _ClipboardOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'workspace.clipboard_read',
      method: 'GET',
      path: '/dev/api/clipboard',
      summary: '读取当前设备剪贴板中的纯文本',
      description: '仅供本机可见 App WebView 在浏览器剪贴板 API 不可用时回退。',
      permission: 'workspace.clipboard.read',
      risk: DeveloperOperationRisk.medium,
      requiresForegroundView: true,
      chatEnabled: false,
      agentEnabled: false,
      additionalResponses: {403: '只允许本机回环连接读取剪贴板', 503: '当前平台无法读取剪贴板'},
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
    final aiChannel = request.headers.value(developerAiChannelHeader)?.trim();
    if (aiChannel != null && aiChannel.isNotEmpty) {
      await _error(
        request.response,
        HttpStatus.forbidden,
        requestId,
        'clipboard_read_ui_only',
        '剪贴板读取仅供用户主动操作的 App WebView 使用',
      );
      return;
    }
    final remoteAddress = request.connectionInfo?.remoteAddress;
    if (remoteAddress == null || !remoteAddress.isLoopback) {
      await _error(
        request.response,
        HttpStatus.forbidden,
        requestId,
        'clipboard_read_local_only',
        '剪贴板只允许本机 App WebView 读取',
      );
      return;
    }

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'text': data?.text ?? '',
      });
    } on PlatformException {
      await _error(
        request.response,
        HttpStatus.serviceUnavailable,
        requestId,
        'clipboard_read_unavailable',
        '当前平台无法读取剪贴板',
      );
    } on MissingPluginException {
      await _error(
        request.response,
        HttpStatus.serviceUnavailable,
        requestId,
        'clipboard_read_unavailable',
        '当前平台未提供剪贴板读取能力',
      );
    }
  }
}
