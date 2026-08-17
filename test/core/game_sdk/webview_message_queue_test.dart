import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/webview_message_queue.dart';

void main() {
  test('页面就绪前缓存 bootstrap 响应并在就绪后按顺序发送', () async {
    final sent = <String>[];
    final queue = WebViewMessageQueue((message) async => sent.add(message));

    await queue.add('bootstrap');
    await queue.add('capabilities');
    expect(sent, isEmpty);

    await queue.resume();
    expect(sent, ['bootstrap', 'capabilities']);
  });

  test('重新导航时丢弃旧页面消息并缓存新页面消息', () async {
    final sent = <String>[];
    final queue = WebViewMessageQueue((message) async => sent.add(message));

    await queue.add('old-bootstrap');
    queue.pause(clearPending: true);
    await queue.add('new-bootstrap');
    await queue.resume();

    expect(sent, ['new-bootstrap']);
  });

  test('发送失败时保留消息并等待下一次页面就绪', () async {
    final sent = <String>[];
    var failOnce = true;
    final queue = WebViewMessageQueue((message) async {
      if (failOnce) {
        failOnce = false;
        throw StateError('WebView 尚未就绪');
      }
      sent.add(message);
    });

    await queue.add('bootstrap');
    await expectLater(queue.resume(), throwsStateError);
    expect(queue.isReady, isFalse);
    expect(sent, isEmpty);

    await queue.resume();
    expect(sent, ['bootstrap']);
  });

  test('发送期间清空旧页队列不会越界或误删新页的同内容消息', () async {
    final sendStarted = Completer<void>();
    final releaseSend = Completer<void>();
    final sent = <String>[];
    final queue = WebViewMessageQueue((message) async {
      if (!sendStarted.isCompleted) {
        sendStarted.complete();
        await releaseSend.future;
      }
      sent.add(message);
    });

    await queue.add('same-payload');
    final oldDelivery = queue.resume();
    await sendStarted.future;
    queue.pause(clearPending: true);
    await queue.add('same-payload');
    releaseSend.complete();
    await oldDelivery;
    await queue.resume();

    expect(sent, ['same-payload', 'same-payload']);
  });

  test('旧页发送在换页后失败不会暂停新页队列', () async {
    final oldSendStarted = Completer<void>();
    final releaseOldSend = Completer<void>();
    final sent = <String>[];
    var attempt = 0;
    final queue = WebViewMessageQueue((message) async {
      attempt += 1;
      if (attempt == 1) {
        oldSendStarted.complete();
        await releaseOldSend.future;
        throw StateError('旧文档已经销毁');
      }
      sent.add(message);
    });

    await queue.add('same-payload');
    final oldDelivery = queue.resume();
    await oldSendStarted.future;
    queue.pause(clearPending: true);
    await queue.add('same-payload');
    final newDelivery = queue.resume();
    releaseOldSend.complete();
    await oldDelivery;
    await newDelivery;

    expect(queue.isReady, isTrue);
    expect(sent, ['same-payload']);
  });
}
