part of '../../developer_web_gateway_io.dart';

/// Minimal, exact-scope wake-up stream for one GDevelop editor session.
/// Polling remains authoritative; this endpoint never serializes project,
/// arguments, output or error details.
class _GDevelopAiEventsOperation implements _DeveloperHttpOperation {
  const _GDevelopAiEventsOperation();

  static const _path =
      '/dev/api/gdevelop/projects/{gameId}/ai/editor-sessions/'
      '{editorSessionId}/events';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.ai.events.subscribe',
      method: 'GET',
      path: _path,
      summary: '订阅当前 GDevelop AI 编辑器会话的最小 SSE 唤醒事件',
      description: '事件仅用于唤醒精确 scope 的增量轮询，不携带调用参数或结果。',
      permission: 'gdevelop.ai.read',
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
    final gameId = pathParameters['gameId']!;
    final editorSessionId = pathParameters['editorSessionId']!;
    // The normal Developer bearer/cookie authentication protects this route.
    // Scope isolation is expressed by the exact game/session URL and checked
    // against the in-memory session before any event is replayed.
    _sessionForGame(gateway, gameId, editorSessionId);

    final querySequence = _parseSequence(
      request.uri.queryParameters['afterSequence'],
      field: 'afterSequence',
    );
    final lastEventSequence = _parseSequence(
      request.headers.value('Last-Event-ID'),
      field: 'Last-Event-ID',
    );
    var deliveredSequence = max(querySequence, lastEventSequence);

    final response = request.response;
    response.bufferOutput = false;
    response
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store')
      ..headers.set(HttpHeaders.connectionHeader, 'keep-alive')
      ..headers.set('X-Accel-Buffering', 'no');

    var pendingWrite = Future<void>.value();
    var connectionClosed = false;
    void enqueue(String chunk) {
      if (connectionClosed) return;
      pendingWrite = pendingWrite.then((_) async {
        if (connectionClosed) return;
        try {
          response.write(chunk);
          await response.flush();
        } on Object {
          connectionClosed = true;
        }
      });
    }

    void enqueueEvent(GDevelopAiEvent event) {
      if (event.gameId != gameId ||
          event.editorSessionId != editorSessionId ||
          event.sequence <= deliveredSequence) {
        return;
      }
      deliveredSequence = event.sequence;
      final payload = jsonEncode(event.toJson());
      enqueue(
        'id: ${event.sequence}\n'
        'event: ${event.type.wireName}\n'
        'data: $payload\n\n',
      );
    }

    // Subscribe before reading the synchronous replay journal so an event
    // cannot land between the replay snapshot and live subscription.
    final subscription = gateway.gdevelopAiEvents.events.listen(enqueueEvent);
    enqueue('retry: 1500\n\n');
    for (final event in gateway.gdevelopAiEvents.replay(
      gameId: gameId,
      editorSessionId: editorSessionId,
      afterSequence: deliveredSequence,
    )) {
      enqueueEvent(event);
    }
    await pendingWrite;

    final heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => enqueue(': heartbeat\n\n'),
    );
    try {
      await response.done;
    } finally {
      connectionClosed = true;
      heartbeat.cancel();
      await subscription.cancel();
      await pendingWrite;
    }
  }

  int _parseSequence(String? raw, {required String field}) {
    if (raw == null || raw.trim().isEmpty) return 0;
    final value = int.tryParse(raw.trim());
    if (value == null || value < 0) {
      throw FormatException('$field 必须是非负整数');
    }
    return value;
  }
}
