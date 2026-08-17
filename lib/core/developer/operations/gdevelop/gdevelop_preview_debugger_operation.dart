part of '../../developer_web_gateway_io.dart';

class _GDevelopPreviewDebuggerOperation implements _DeveloperHttpOperation {
  const _GDevelopPreviewDebuggerOperation();

  static const _path =
      '/dev/api/gdevelop/projects/{gameId}/preview/{previewId}/debugger';
  static const _drainSource = '''
(() => {
  const relay = window.__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__;
  return relay && typeof relay.drain === 'function'
    ? relay.drain()
    : JSON.stringify({protocolVersion: '1.0.0', ready: false, messages: []});
})()
''';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.preview.debugger.messages',
      method: 'GET',
      path: '$_path/messages',
      summary: '读取当前 App RuntimeView 的 GDevelop 调试消息',
      permission: 'runtime.debug',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'previewId',
          location: DeveloperOperationParameterLocation.path,
          description: '当前 GDevelop 临时预览 generation',
          required: true,
        ),
      ],
      additionalResponses: {409: '预览 generation 已变化或 RuntimeView 未就绪'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.preview.debugger.command',
      method: 'POST',
      path: '$_path/commands',
      summary: '向当前 App RuntimeView 发送 GDevelop 调试命令',
      permission: 'runtime.debug',
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'previewId',
          location: DeveloperOperationParameterLocation.path,
          description: '当前 GDevelop 临时预览 generation',
          required: true,
        ),
      ],
      requestBodySchema: {
        'type': 'object',
        'required': ['command'],
        'properties': {
          'command': {'type': 'object'},
        },
      },
      additionalResponses: {409: '预览 generation 已变化或 RuntimeView 未就绪'},
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
    final gameId = pathParameters['gameId']!;
    final previewId = pathParameters['previewId']!;
    final current = await gateway.previewService.status(
      gameId,
      surface: DeveloperPreviewSurface.app,
    );
    if (current.previewId != previewId) {
      throw DeveloperPreviewGenerationConflict(current.previewId);
    }

    switch (definition.id) {
      case 'gdevelop.preview.debugger.messages':
        final result = await gateway.runController.executeJavaScript(
          gameId,
          _drainSource,
        );
        final relay = _parseGDevelopDebuggerRelayResult(result);
        await _json(request.response, HttpStatus.ok, relay);
        return;
      case 'gdevelop.preview.debugger.command':
        // 官方 set/call 参数不设 Playmesh 额外大小上限；仍由同源鉴权、
        // 当前 preview generation 和 RuntimeView 绑定共同限定目标。
        final body = await _optionalJsonBody(request);
        final command = body['command'];
        if (command is! Map || command['command'] is! String) {
          throw const FormatException('command 必须是包含 command 名称的对象');
        }
        final normalizedCommand = Map<String, Object?>.from(command);
        final encoded = jsonEncode(normalizedCommand);
        final accepted = await gateway.runController.executeJavaScript(
          gameId,
          '''(() => {
  const relay = window.__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__;
  return !!(relay && typeof relay.receive === 'function' && relay.receive($encoded));
})()''',
        );
        await _json(request.response, HttpStatus.ok, {
          'protocolVersion': '1.0.0',
          'accepted': _parseGDevelopDebuggerBoolean(accepted),
        });
        return;
    }
  }
}

Map<String, Object?> _parseGDevelopDebuggerRelayResult(Object? raw) {
  Object? value = raw;
  for (var index = 0; index < 2 && value is String; index += 1) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      break;
    }
  }
  if (value is! Map ||
      value['protocolVersion'] != '1.0.0' ||
      value['ready'] is! bool ||
      value['messages'] is! List) {
    throw const FormatException('GDevelop RuntimeView 调试中继返回无效');
  }
  final messages = <String>[];
  for (final message in value['messages']! as List) {
    if (message is! String) {
      throw const FormatException('GDevelop RuntimeView 调试消息不是字符串');
    }
    messages.add(message);
  }
  return {
    'protocolVersion': '1.0.0',
    'ready': value['ready']! as bool,
    'messages': messages,
  };
}

bool _parseGDevelopDebuggerBoolean(Object? raw) {
  Object? value = raw;
  for (var index = 0; index < 2 && value is String; index += 1) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      break;
    }
  }
  return value == true;
}
