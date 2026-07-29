import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/game_webview_exit.dart';

void main() {
  test('游戏菜单退出先发起 Flutter WebView 的 about:blank 导航', () async {
    final events = <String>[];

    await exitGameMenuWithBlankPage(
      loadRequest: (uri) async => events.add('load:$uri'),
      exit: () async => events.add('exit'),
    );

    expect(events, ['load:about:blank', 'exit']);
  });

  test('Windows 游戏菜单退出通过脚本发起 about:blank 导航', () async {
    final events = <String>[];

    await exitGameMenuWithBlankPage(
      runJavaScript: (script) async => events.add('script:$script'),
      exit: () async => events.add('exit'),
    );

    expect(events, ["script:window.location.replace('about:blank');", 'exit']);
  });

  test('加载空页面失败时仍继续退出游戏', () async {
    var exited = false;

    await exitGameMenuWithBlankPage(
      loadRequest: (_) => Future<void>.error(StateError('load failed')),
      exit: () async => exited = true,
    );

    expect(exited, isTrue);
  });

  test('加载空页面不阻塞退出回调', () async {
    final blankPageLoaded = Completer<void>();
    var exited = false;

    await exitGameMenuWithBlankPage(
      loadRequest: (_) => blankPageLoaded.future,
      exit: () async => exited = true,
    );

    expect(exited, isTrue);
    expect(blankPageLoaded.isCompleted, isFalse);
    blankPageLoaded.complete();
  });
}
