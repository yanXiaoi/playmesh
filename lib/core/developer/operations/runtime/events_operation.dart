part of '../../developer_web_gateway_io.dart';

class _EventsOperation implements _DeveloperHttpOperation {
  const _EventsOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'events.subscribe',
      method: 'GET',
      path: '/dev/api/events',
      summary: '订阅项目、文件、运行和日志的实时 SSE 事件',
      permission: 'event.subscribe',
      chatEnabled: false,
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
    final response = request.response;
    response.bufferOutput = false;
    response
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set('Cache-Control', 'no-cache')
      ..headers.set('Connection', 'keep-alive');
    var pendingWrite = Future<void>.value();
    void enqueue(String chunk) {
      pendingWrite = pendingWrite.then((_) async {
        try {
          response.write(chunk);
          await response.flush();
        } on Object {
          // 客户端断开后 response.done 会结束处理；这里不让并发事件污染请求错误通道。
        }
      });
    }

    final subscription = developerEventHub.events.listen((event) {
      enqueue('event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n');
    });
    enqueue('retry: 1500\n\n');
    await pendingWrite;
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      enqueue(': heartbeat\n\n');
    });
    try {
      await response.done;
    } finally {
      heartbeat.cancel();
      await subscription.cancel();
      await pendingWrite;
    }
  }
}
