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
}
