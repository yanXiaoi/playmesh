import 'dart:async';

import '../storage/game_storage_service.dart';

abstract interface class GameSdkBridge {
  Stream<String> get outboundMessages;

  Stream<double> get fpsValues;

  Stream<double?> get latencyValues;

  Future<void> handleJavaScriptMessage(String rawMessage);

  Future<void> notifyLifecycle(String event);

  void setPerformanceVisible(bool visible);

  /// Requests that the private SDK runtime restore the game DOM focus captured
  /// immediately before an App-owned overlay was opened.
  void restoreGameContentFocus();

  /// 返回当前游戏唯一的存储实例，供 SDK Bridge 与同源资源网关共享。
  Future<GameStorageService> ensureStorage();

  Future<void> close();
}

/// 将宿主 JSON 作为对象传给 Game SDK，避免 WebView 再包一层字符串。
String gameSdkReceiveScript(String message) =>
    'window.playmesh && window.playmesh.__receive($message);';
