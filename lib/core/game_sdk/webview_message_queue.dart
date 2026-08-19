import 'dart:async';

typedef WebViewMessageSender = Future<void> Function(String message);

class _PendingWebViewMessage {
  _PendingWebViewMessage(this.value, {required this.generation, this.delivery});

  final String value;
  final int generation;
  final Completer<void>? delivery;
}

/// 页面脚本尚未完成加载时缓存宿主消息，避免启动阶段的 Bridge 响应丢失。
class WebViewMessageQueue {
  WebViewMessageQueue(this._send);

  final WebViewMessageSender _send;
  final List<_PendingWebViewMessage> _pending = [];
  bool _ready = false;
  Future<void> _delivery = Future<void>.value();
  int _generation = 0;

  bool get isReady => _ready;
  int get generation => _generation;

  void pause({bool clearPending = false}) {
    _ready = false;
    if (!clearPending) return;
    _generation += 1;
    final discarded = _pending.toList(growable: false);
    _pending.clear();
    for (final pending in discarded) {
      pending.delivery?.completeError(
        StateError('WebView document changed before message delivery'),
      );
    }
  }

  Future<void> resume() async {
    _ready = true;
    await _scheduleDelivery();
  }

  Future<void> add(String message) async {
    _pending.add(_PendingWebViewMessage(message, generation: _generation));
    if (_ready) await _scheduleDelivery();
  }

  /// Adds a document-bound response and completes only after JavaScript ran.
  ///
  /// Navigation clears the response with an error, so callers cannot perform
  /// a post-response action after the originating document disappeared.
  Future<void> addAndWait(String message, {required int generation}) {
    if (generation != _generation) {
      return Future<void>.error(
        StateError('WebView message belongs to a stale document'),
      );
    }
    final delivery = Completer<void>();
    _pending.add(
      _PendingWebViewMessage(
        message,
        generation: generation,
        delivery: delivery,
      ),
    );
    if (_ready) {
      unawaited(_scheduleDelivery().catchError((Object _) {}));
    }
    return delivery.future;
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
      final pending = _pending.first;
      if (pending.generation != _generation) {
        _pending.removeAt(0);
        pending.delivery?.completeError(
          StateError('WebView message belongs to a stale document'),
        );
        continue;
      }
      try {
        await _send(pending.value);
        if (_pending.isNotEmpty && identical(_pending.first, pending)) {
          _pending.removeAt(0);
          pending.delivery?.complete();
        }
      } on Object {
        if (_pending.isNotEmpty && identical(_pending.first, pending)) {
          // 当前 document 的 executeScript 暂时失败时保留同一消息。
          // 要求投递确认的调用方继续等待；只有后续真实执行成功才完成，
          // 导航清理则由 pause(clearPending: true) 以错误结束等待。
          _ready = false;
          rethrow;
        }
        // 发送期间若已经换页并清除了旧消息，这个失败只属于旧文档，
        // 不能把新文档刚恢复的队列再次暂停。
      }
    }
  }
}
