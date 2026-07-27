import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('分享页只呈现用户配置的本地游戏源名称', () {
    final source = File('lib/features/game/game_page.dart').readAsStringSync();

    expect(source, isNot(contains('share.source.official_name')));
    expect(source, isNot(contains('declaration.displayNameFor')));
    expect(source, isNot(contains('declaration.author')));
    expect(source, contains('probe.source.name'));
    expect(source, contains('source.source.name'));
  });

  test('App 分享覆盖层幂等聚焦、关闭节流并恢复游戏 DOM 焦点', () {
    final pageSource = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final appUiSource = File(
      'lib/core/game_sdk/features/app/app_ui_feature.dart',
    ).readAsStringSync();
    final runtimeSource = File(
      'lib/core/game_sdk/features/game/game_runtime_feature.dart',
    ).readAsStringSync();

    expect(pageSource, contains("Key('game-share-close')"));
    expect(pageSource, contains('requestCloseFocus()'));
    expect(pageSource, contains('Duration(milliseconds: 800)'));
    expect(pageSource, contains("'rate_limited'"));
    expect(pageSource, contains('bridge?.restoreGameContentFocus()'));
    expect(appUiSource, contains('captureAppUiReturnFocus();'));
    expect(appUiSource, contains('returnFocus.focus({ preventScroll: true })'));
    expect(appUiSource, contains('request("app.ui.openSharePanel"'));
    expect(runtimeSource, contains('platform.ui.restoreGameFocus'));
    expect(runtimeSource, contains('appSdk.__restoreGameContentFocus?.()'));
  });
}
