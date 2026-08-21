import 'dart:async';

final class RuntimeNavigation {
  final StreamController<Uri> _requests = StreamController<Uri>.broadcast();
  bool _closed = false;

  Stream<Uri> get requests => _requests.stream;

  void navigate(Uri uri) {
    if (_closed) throw StateError('Runtime 导航已经关闭');
    _requests.add(uri);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _requests.close();
  }
}
