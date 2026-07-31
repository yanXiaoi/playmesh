import 'dart:async';

import 'package:flutter/foundation.dart';

const gameExitBlankPage = 'about:blank';

/// 请求加载空白游戏文档，并立即继续退出到菜单。
///
/// Flutter WebView 使用 [loadRequest]，Windows WebView 使用 [runJavaScript]，
/// 因为其控制器由平台专用组件持有。这里有意不等待导航完成：
/// 无论成功或失败，都不延迟原退出回调。
Future<void> exitGameMenuWithBlankPage({
  required Future<void> Function() exit,
  Future<void> Function(Uri uri)? loadRequest,
  Future<void> Function(String script)? runJavaScript,
}) {
  Future<void>? blankPageOperation;
  try {
    if (loadRequest != null) {
      blankPageOperation = loadRequest(Uri.parse(gameExitBlankPage));
    } else if (runJavaScript != null) {
      blankPageOperation = runJavaScript(
        "window.location.replace('$gameExitBlankPage');",
      );
    }
  } on Object catch (error) {
    debugPrint('退出游戏前加载空白页面失败: $error');
  }
  if (blankPageOperation != null) {
    unawaited(
      blankPageOperation.catchError((Object error) {
        debugPrint('退出游戏前加载空白页面失败: $error');
      }),
    );
  }
  return exit();
}
