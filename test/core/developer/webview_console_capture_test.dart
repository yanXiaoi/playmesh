import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_event_hub.dart';
import 'package:playmesh/core/developer/webview_console_capture.dart';

void main() {
  setUp(developerEventHub.clearRecentLogs);

  test('宿主捕获的 console 只标记为本机运行日志', () {
    recordLocalWebViewConsole(
      level: 'warning',
      message: 'local warning',
      href: 'https://example.test/app/index.html',
      clientTimestamp: 123,
    );

    expect(
      developerEventHub.recentLogs.single,
      containsPair('scope', 'local-device'),
    );
    expect(developerEventHub.recentLogs.single, containsPair('level', 'warn'));
    expect(
      developerEventHub.recentLogs.single,
      containsPair('message', 'local warning'),
    );
  });

  test('Windows WebView2 宿主消息与 SDK Bridge 消息互不混淆', () {
    final captured = handleWindowsWebViewConsoleMessage(
      jsonEncode({
        '__playmeshHostConsole': {
          'level': 'log',
          'message': 'Playmesh SDK 加载成功',
          'href': 'http://127.0.0.1/app/index.html',
          'timestamp': 456,
        },
      }),
    );

    expect(captured, isTrue);
    expect(
      handleWindowsWebViewConsoleMessage(jsonEncode({'command': 'sdk.ready'})),
      isFalse,
    );
    expect(
      developerEventHub.recentLogs.single,
      containsPair('message', 'Playmesh SDK 加载成功'),
    );
  });

  test('Windows 捕获脚本在页面脚本前接管 console', () {
    expect(
      windowsWebViewConsoleCaptureScript,
      contains('__playmeshHostConsoleCaptureInstalled'),
    );
    expect(
      windowsWebViewConsoleCaptureScript,
      contains('__playmeshForwardingInstalled'),
    );
    expect(windowsWebViewConsoleCaptureScript, contains('chrome.webview'));
  });
}
