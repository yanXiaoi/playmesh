import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_web_external_navigation.dart';

void main() {
  test('识别系统浏览器、第三方应用和 Android Intent 链接', () {
    expect(
      parseGameWebViewExternalUri('https://example.com/help'),
      Uri.parse('https://example.com/help'),
    );
    expect(parseGameWebViewExternalUri('weixin://'), Uri.parse('weixin://'));
    expect(
      parseGameWebViewExternalUri(
        'androidamap://navi?lat=39.9&lon=116.3&dev=0',
      ),
      Uri.parse('androidamap://navi?lat=39.9&lon=116.3&dev=0'),
    );
    expect(
      parseGameWebViewExternalUri(
        'intent://www.example.com#Intent;scheme=https;'
        'action=android.intent.action.VIEW;end',
      ),
      isNotNull,
    );
  });

  test('不把 WebView 私有及可执行协议交给系统', () {
    for (final url in [
      'javascript:alert(1)',
      'data:text/html,hello',
      'blob:http://127.0.0.1/value',
      'file:///C:/secret.txt',
      'content://provider/item',
      'https:///missing-host',
      'relative/path',
    ]) {
      expect(parseGameWebViewExternalUri(url), isNull, reason: url);
    }
  });

  test('同窗口 Web 导航留在游戏，第三方协议转交系统', () {
    expect(
      classifyGameWebViewNavigation('https://example.com/next'),
      GameWebViewNavigationDisposition.navigate,
    );
    expect(
      classifyGameWebViewNavigation('weixin://'),
      GameWebViewNavigationDisposition.openExternal,
    );
    expect(
      classifyGameWebViewNavigation('not a url'),
      GameWebViewNavigationDisposition.prevent,
    );
  });

  test('解析 window.open 兼容脚本发出的消息', () {
    expect(
      parseGameWebViewExternalNavigationMessage(
        '{"__playmeshGameExternalNavigation":'
        '{"href":"https://example.com/docs"}}',
      ),
      Uri.parse('https://example.com/docs'),
    );
    expect(
      parseGameWebViewExternalNavigationMessage(
        '{"__playmeshGameExternalNavigation":'
        '{"href":"javascript:alert(1)"}}',
      ),
      isNull,
    );
    expect(playmeshGameWindowOpenScript, contains('global.open ='));
  });

  test('普通协议使用系统打开器，Intent 仅走 Android 原生通道', () async {
    final opened = <Uri>[];
    expect(
      await openGameWebViewExternalUri(
        Uri.parse('weixin://'),
        platform: TargetPlatform.android,
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
      isTrue,
    );
    expect(opened, [Uri.parse('weixin://')]);

    String? intent;
    final intentUri = Uri.parse(
      'intent://www.example.com#Intent;scheme=https;end',
    );
    expect(
      await openGameWebViewExternalUri(
        intentUri,
        platform: TargetPlatform.android,
        androidIntentLauncher: (value) async {
          intent = value;
          return true;
        },
      ),
      isTrue,
    );
    expect(intent, intentUri.toString());
    expect(
      await openGameWebViewExternalUri(
        intentUri,
        platform: TargetPlatform.windows,
        androidIntentLauncher: (_) async => true,
      ),
      isFalse,
    );
  });
}
