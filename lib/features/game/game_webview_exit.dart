import 'dart:async';

import 'package:flutter/foundation.dart';

const gameExitBlankPage = 'about:blank';

/// Requests a blank game document and immediately continues the menu exit.
///
/// Flutter WebViews use [loadRequest] while the Windows WebView uses
/// [runJavaScript] because its controller is owned by the platform-specific
/// widget. The navigation is deliberately not awaited: whether it completes or
/// fails never delays the original exit callback.
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
