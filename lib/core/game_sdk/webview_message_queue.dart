import 'dart:async';

typedef WebViewMessageSender = Future<void> Function(String message);

/// 页面脚本尚未完成加载时缓存宿主消息，避免启动阶段的 Bridge 响应丢失。
class WebViewMessageQueue {
  WebViewMessageQueue(this._send);

  final WebViewMessageSender _send;
  final List<String> _pending = [];
  bool _ready = false;
  Future<void> _delivery = Future<void>.value();

  bool get isReady => _ready;

  void pause({bool clearPending = false}) {
    _ready = false;
    if (clearPending) _pending.clear();
  }

  Future<void> resume() async {
    _ready = true;
    await _scheduleDelivery();
  }

  Future<void> add(String message) async {
    _pending.add(message);
    if (_ready) await _scheduleDelivery();
  }

  Future<void> _scheduleDelivery() {
    final previous = _delivery;
    _delivery = Future<void>(() async {
      try {
        await previous;
      } on Object {
        // 上一次发送失败后，页面重新就绪时仍然允许继续投递。
      }
      await _drain();
    });
    return _delivery;
  }

  Future<void> _drain() async {
    while (_ready && _pending.isNotEmpty) {
      final message = _pending.first;
      try {
        await _send(message);
        _pending.removeAt(0);
      } on Object {
        // 页面可能正在重新导航。保留当前消息，等待下一次 onPageFinished。
        _ready = false;
        rethrow;
      }
    }
  }
}
