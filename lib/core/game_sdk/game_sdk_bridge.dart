import 'dart:async';
import 'dart:convert';

import '../storage/game_storage_service.dart';

abstract interface class GameSdkBridge {
  Stream<String> get outboundMessages;

  Future<void> handleJavaScriptMessage(String rawMessage);

  Future<void> notifyLifecycle(String event);

  /// Requests that the private SDK runtime restore the game DOM focus captured
  /// immediately before an App-owned overlay was opened.
  void restoreGameContentFocus();

  /// 返回当前游戏唯一的存储实例，供 SDK Bridge 与同源资源网关共享。
  Future<GameStorageService> ensureStorage();

  Future<void> close();
}

const playmeshAppInternalRuntimeSymbol = 'playmesh.app.internal.v1';
const playmeshMainInternalRuntimeSymbol = 'playmesh.main.internal.v1';

String _sdkInternalRuntimeAccessor(String symbol) =>
    'window[Symbol.for(${jsonEncode(symbol)})]';

/// 将宿主 JSON 作为对象传给 Game SDK，避免 WebView 再包一层字符串。
String gameSdkReceiveScript(String message) =>
    '${_sdkInternalRuntimeAccessor(playmeshMainInternalRuntimeSymbol)}'
    '?.receive($message);';

/// 将宿主消息交给 App SDK 的私有 runtime；公开 `playmesh.app` 不暴露桥接入口。
String appSdkReceiveScript(String message) =>
    '${_sdkInternalRuntimeAccessor(playmeshAppInternalRuntimeSymbol)}'
    '?.receive(${jsonEncode(message)});';

/// 只供宿主刷新 App SDK 的平台 UI 配置。
String appSdkConfigurePlatformUiScript(Map<String, Object?> configuration) =>
    '${_sdkInternalRuntimeAccessor(playmeshAppInternalRuntimeSymbol)}'
    '?.configurePlatformUi?.(${jsonEncode(configuration)});';

/// 只供宿主把系统返回键交给 App SDK 的当前覆盖层。
String appSdkHandleNativeBackScript() =>
    'Boolean(${_sdkInternalRuntimeAccessor(playmeshAppInternalRuntimeSymbol)}'
    '?.handleNativeBack?.())';
