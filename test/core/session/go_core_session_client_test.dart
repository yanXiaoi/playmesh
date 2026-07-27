import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playmesh/core/session/go_core_session_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('主会话掉线后持续重连并发送掉线期间排队的消息', () async {
    final channels = <_FakeWebSocketChannel>[];
    final client = GoCoreSessionClient(
      baseUri: Uri.parse('http://127.0.0.1:42000/'),
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'webSocketPath': '/v1/sessions/s-1/ws',
              'binaryWebSocketPath': '/v1/sessions/s-1/binary',
              'credential': {
                'token': 'token-1',
                'reconnected': false,
                'player': {
                  'id': 'p-authority',
                  'nickname': '主机',
                  'connected': true,
                  'role': 'authority',
                },
              },
              'session': {
                'id': 's-1',
                'joinCode': 'ABC123',
                'gameId': 'game.test',
                'displayMode': 'multi_screen',
                'state': 'lobby',
                'minPlayers': 1,
                'maxPlayers': 4,
                'authorityClientId': 'p-authority',
                'players': [
                  {
                    'id': 'p-authority',
                    'nickname': '主机',
                    'connected': true,
                    'role': 'authority',
                  },
                ],
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      channelFactory: (_) {
        final channel = _FakeWebSocketChannel(initiallyReady: channels.isEmpty);
        channels.add(channel);
        return channel;
      },
    );
    final connection = await client.create(
      gameId: 'game.test',
      displayMode: 'multi_screen',
      minPlayers: 1,
      maxPlayers: 4,
      nickname: '主机',
    );
    final messages = <Map<String, Object?>>[];
    final subscription = connection.messages.listen(messages.add);

    await channels.single.disconnect();
    await _waitFor(
      () => messages.any(
        (message) =>
            message['type'] == 'transport.status' &&
            message['state'] == 'disconnected',
      ),
    );
    await _waitFor(() => channels.length == 2);
    connection.submitAction({'type': 'queued-action'});
    channels.last.allowReady();

    await _waitFor(
      () => messages.any(
        (message) =>
            message['type'] == 'transport.status' &&
            message['state'] == 'reconnected',
      ),
    );
    final sent =
        jsonDecode(await channels.last.sent.stream.first as String)
            as Map<String, Object?>;

    expect(sent['type'], 'game.action');
    expect(sent['payload'], {'type': 'queued-action'});
    expect(
      messages
          .where((message) => message['type'] == 'transport.status')
          .map((message) => message['state']),
      containsAllInOrder(['disconnected', 'reconnecting', 'reconnected']),
    );

    await subscription.cancel();
    await connection.close();
    client.close();
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待条件超时');
}

class _FakeWebSocketChannel implements WebSocketChannel {
  _FakeWebSocketChannel({required bool initiallyReady}) {
    if (initiallyReady) _ready.complete();
  }

  final StreamController<Object?> incoming = StreamController<Object?>();
  final StreamController<Object?> sent = StreamController<Object?>();
  final Completer<void> _ready = Completer<void>();
  late final WebSocketSink _sink = _FakeWebSocketSink(sent);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => _ready.future;

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => incoming.stream;

  Future<void> disconnect() => incoming.close();

  void allowReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this.controller);

  final StreamController<Object?> controller;

  @override
  void add(Object? data) => controller.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      controller.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream stream) => controller.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      controller.close();

  @override
  Future<void> get done => controller.done;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
