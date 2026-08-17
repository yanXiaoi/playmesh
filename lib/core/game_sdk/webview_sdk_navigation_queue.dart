import 'webview_message_queue.dart';

typedef WebViewSdkBeforeSend = Future<void> Function();

class _QueuedSdkScript {
  const _QueuedSdkScript(this.script, this.beforeSend, this.generation);

  final String script;
  final WebViewSdkBeforeSend? beforeSend;
  final int generation;
}

/// Orders App/Game SDK replies around a WebView document navigation.
///
/// App replies are always released before Game replies because Main SDK waits
/// on App SDK readiness. App callbacks are generation-bound so an asynchronous
/// result created by an old document can never be injected into a replacement.
class WebViewSdkNavigationQueue {
  WebViewSdkNavigationQueue(this._send) {
    _app = WebViewMessageQueue((id) => _deliver(_appScripts, id));
    _game = WebViewMessageQueue((id) => _deliver(_gameScripts, id));
  }

  final WebViewMessageSender _send;
  late final WebViewMessageQueue _app;
  late final WebViewMessageQueue _game;
  final Map<String, _QueuedSdkScript> _appScripts = {};
  final Map<String, _QueuedSdkScript> _gameScripts = {};
  int _generation = 0;
  int _messageSequence = 0;
  bool _initialLoadingNotificationExpected = false;
  bool _disposed = false;

  int get generation => _generation;
  bool get appReady => _app.isReady;
  bool get gameReady => _game.isReady;

  int beginNavigation() {
    if (_disposed) return _generation;
    _initialLoadingNotificationExpected = true;
    _generation += 1;
    _app.pause(clearPending: true);
    _game.pause(clearPending: true);
    _appScripts.clear();
    _gameScripts.clear();
    return _generation;
  }

  /// Records the WebView plugin's loading notification.
  ///
  /// A navigation explicitly started with [beginNavigation] can emit its first
  /// loading notification after page scripts have already requested an SDK
  /// response. That notification belongs to the prepared generation and must
  /// not clear those early responses. A later loading notification starts a
  /// new document generation (for example, a navigation initiated by the
  /// page itself).
  int notifyNavigationLoading() {
    if (_disposed) return _generation;
    if (_initialLoadingNotificationExpected) {
      _initialLoadingNotificationExpected = false;
      return _generation;
    }
    final generation = beginNavigation();
    _initialLoadingNotificationExpected = false;
    return generation;
  }

  Future<void> completeNavigation(int generation) async {
    if (_disposed || generation != _generation) return;
    _initialLoadingNotificationExpected = false;
    await _app.resume();
    if (generation != _generation) return;
    await _game.resume();
  }

  Future<void> addApp(String script, {required int generation}) async {
    if (_disposed || generation != _generation) return;
    final id = 'app-${++_messageSequence}';
    _appScripts[id] = _QueuedSdkScript(script, null, generation);
    await _app.add(id);
  }

  Future<void> addGame(
    String script, {
    WebViewSdkBeforeSend? beforeSend,
  }) async {
    if (_disposed) return;
    final generation = _generation;
    final id = 'game-${++_messageSequence}';
    _gameScripts[id] = _QueuedSdkScript(script, beforeSend, generation);
    await _game.add(id);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _initialLoadingNotificationExpected = false;
    _generation += 1;
    _app.pause(clearPending: true);
    _game.pause(clearPending: true);
    _appScripts.clear();
    _gameScripts.clear();
  }

  Future<void> _deliver(
    Map<String, _QueuedSdkScript> scripts,
    String id,
  ) async {
    final queued = scripts[id];
    if (queued == null) return;
    if (!_isCurrent(scripts, id, queued)) {
      _removeIfCurrent(scripts, id, queued);
      return;
    }
    final beforeSend = queued.beforeSend;
    if (beforeSend != null) {
      await beforeSend();
      if (!_isCurrent(scripts, id, queued)) {
        _removeIfCurrent(scripts, id, queued);
        return;
      }
    }
    if (!_isCurrent(scripts, id, queued)) {
      _removeIfCurrent(scripts, id, queued);
      return;
    }
    await _send(queued.script);
    _removeIfCurrent(scripts, id, queued);
  }

  bool _isCurrent(
    Map<String, _QueuedSdkScript> scripts,
    String id,
    _QueuedSdkScript queued,
  ) {
    return !_disposed &&
        queued.generation == _generation &&
        identical(scripts[id], queued);
  }

  void _removeIfCurrent(
    Map<String, _QueuedSdkScript> scripts,
    String id,
    _QueuedSdkScript queued,
  ) {
    if (identical(scripts[id], queued)) scripts.remove(id);
  }
}
