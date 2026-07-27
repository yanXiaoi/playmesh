import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/local_tunnel_gateway.dart';

void main() {
  test('本地回环网关双向透明转发原始字节', () async {
    final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final targetSubscription = target.listen((socket) {
      socket.listen(socket.add, onDone: socket.destroy);
    });
    final gateway = await startLocalTunnelGateway(
      targetBaseUri: Uri(scheme: 'http', host: '127.0.0.1', port: target.port),
    );
    addTearDown(() async {
      await gateway.close();
      await targetSubscription.cancel();
      await target.close();
    });

    final client = await Socket.connect(
      gateway.localBaseUri.host,
      gateway.localBaseUri.port,
    );
    addTearDown(client.destroy);
    final sent = List<int>.generate(1024 * 1024, (index) => index % 251);
    final received = <int>[];
    final complete = Completer<void>();
    final subscription = client.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= sent.length && !complete.isCompleted) {
        complete.complete();
      }
    });
    addTearDown(subscription.cancel);

    client.add(sent);
    await client.flush();
    await complete.future.timeout(const Duration(seconds: 10));

    expect(received, sent);
  });
}
