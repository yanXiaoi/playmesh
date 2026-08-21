import 'dart:async';

typedef RuntimeWebViewScriptExecutor = Future<void> Function(String script);

final class _QueuedRuntimeWebViewScript {
  _QueuedRuntimeWebViewScript(
    this.script, {
    required this.generation,
    this.delivery,
  });

  final String script;
  final int generation;
  final Completer<void>? delivery;
}

/// Keeps native bridge replies bound to the WebView document that requested
/// them. Startup replies are held until the document has finished loading, so
/// the private SDK receivers cannot miss them during script initialization.
final class RuntimeWebViewMessageQueue {
  RuntimeWebViewMessageQueue(this._execute);

  final RuntimeWebViewScriptExecutor _execute;
  final List<_QueuedRuntimeWebViewScript> _pending = [];
  bool _ready = false;
  int _generation = 0;
  Future<void> _delivery = Future<void>.value();

  bool get isReady => _ready;
  int get generation => _generation;

  void pause({bool clearPending = false}) {
    _ready = false;
    if (!clearPending) return;
    _generation += 1;
    final discarded = _pending.toList(growable: false);
    _pending.clear();
    for (final item in discarded) {
      item.delivery?.completeError(
        StateError('WebView document changed before message delivery'),
      );
    }
  }

  Future<void> resume() async {
    _ready = true;
    await _scheduleDelivery();
  }

  Future<void> add(String script) async {
    _pending.add(_QueuedRuntimeWebViewScript(script, generation: _generation));
    if (_ready) await _scheduleDelivery();
  }

  Future<void> addAndWait(String script, {required int generation}) {
    if (generation != _generation) {
      return Future<void>.error(
        StateError('WebView message belongs to a stale document'),
      );
    }
    final delivery = Completer<void>();
    _pending.add(
      _QueuedRuntimeWebViewScript(
        script,
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
        // A new document can resume delivery after an earlier failure.
      }
      await _drain();
    });
    return _delivery;
  }

  Future<void> _drain() async {
    while (_ready && _pending.isNotEmpty) {
      final item = _pending.first;
      if (item.generation != _generation) {
        _pending.removeAt(0);
        item.delivery?.completeError(
          StateError('WebView message belongs to a stale document'),
        );
        continue;
      }
      try {
        await _execute(item.script);
        if (_pending.isNotEmpty && identical(_pending.first, item)) {
          _pending.removeAt(0);
          item.delivery?.complete();
        }
      } on Object {
        if (_pending.isNotEmpty && identical(_pending.first, item)) {
          _ready = false;
          rethrow;
        }
      }
    }
  }
}
