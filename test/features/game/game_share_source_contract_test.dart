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
    expect(pageSource, contains('SingleActivator(LogicalKeyboardKey.escape)'));
    expect(pageSource, contains('requestCloseFocus()'));
    expect(pageSource, contains('Duration(milliseconds: 800)'));
    expect(pageSource, contains("'rate_limited'"));
    expect(
      pageSource,
      contains(
        '_soloBridge != null || _bridge?.connection.isAuthority == true',
      ),
    );
    expect(
      pageSource,
      contains(
        'onOpenSharePanel: _canShareFromAppSdk ? _openShareFromAppSdk : null',
      ),
    );
    expect(
      pageSource,
      isNot(
        contains('Boolean(globalThis.navigator?.userActivation?.isActive)'),
      ),
    );
    expect(appUiSource, contains('global.navigator?.userActivation?.isActive'));
    expect(appUiSource, contains("command.payload['userActivation'] != true"));
    expect(pageSource, contains('bridge?.restoreGameContentFocus()'));
    expect(appUiSource, contains('captureAppUiReturnFocus();'));
    expect(appUiSource, contains('returnFocus.focus({ preventScroll: true })'));
    expect(appUiSource, contains('request("app.ui.openSharePanel"'));
    expect(runtimeSource, contains('platform.ui.restoreGameFocus'));
    expect(runtimeSource, contains('appSdk.__restoreGameContentFocus?.()'));
  });

  test('Windows 游戏 WebView 挂载完成后主动取得原生键盘焦点', () {
    final source = File(
      'lib/features/game/windows_local_game_web_view_io.dart',
    ).readAsStringSync();

    expect(source, contains('FocusManager.instance.primaryFocus?.unfocus()'));
    expect(source, contains('await _controller.focus()'));
    expect(source, contains('LoadingState.navigationCompleted'));
    expect(source, contains("'platform.ui.restoreGameFocus'"));
    expect(source, contains('widget.appSdkInputTakenOver'));
    expect(source, contains('_navigationCompleted'));
    expect(source, contains('_controller.onFocusChanged.listen'));
    expect(source, contains('_controller.hasNativeFocus'));
    expect(source, contains('_scheduleInitialFocusRetry()'));
    expect(source, contains('WidgetsBinding.instance.scheduleFrame()'));
  });

  test('Android 游戏 WebView 在 App SDK 接管且页面完成后主动聚焦', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();

    expect(source, contains('_androidNavigationCompleted'));
    expect(source, contains('_scheduleAndroidWebViewFocus()'));
    expect(source, contains('_androidWebViewFocusScopeNode'));
    expect(source, contains('platformViewFocus.requestFocus()'));
    expect(source, contains("_runJavaScript('window.focus();')"));
    expect(source, contains("_evaluateJavaScript('document.hasFocus()')"));
    expect(source, contains('_scheduleAndroidWebViewFocusRetry()'));
    expect(source, contains('WidgetsBinding.instance.scheduleFrame()'));
    expect(source, contains('defaultTargetPlatform != TargetPlatform.android'));
  });

  test('App SDK input takeover keeps both platform WebViews mounted', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();

    expect(source, contains('canRequestFocus: !_appSdkInputTakenOver'));
    expect(source, contains('absorbing: !_appSdkInputTakenOver'));
    expect(
      source,
      isNot(contains('if (!_appSdkInputTakenOver) {\n      content = Focus(')),
    );
  });

  test('App SDK 接管前由平台默认响应，接管后才转交系统返回', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();
    final gamePageSource = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final appSource = File(
      'lib/core/game_sdk/features/app/app_device_feature.dart',
    ).readAsStringSync();

    expect(source, contains('game-native-input-fallback'));
    expect(source, contains('_exitBeforeAppSdkTakeover()'));
    expect(source, contains('onInputTakeover: _takeOverAppSdkInput'));
    expect(source, contains('absorbing: !_appSdkInputTakenOver'));
    expect(source, contains('window.playmeshApp?.__handleNativeBack?.()'));
    expect(source, contains('canPop: !_appSdkInputTakenOver'));
    expect(source, contains('onSystemBackHandlerChanged'));
    expect(source, isNot(contains('key == LogicalKeyboardKey.contextMenu')));
    expect(gamePageSource, contains('onPopInvokedWithResult: (didPop, _)'));
    expect(gamePageSource, contains('_gameSystemBackHandler'));
    expect(
      gamePageSource,
      contains('onSystemBackHandlerChanged: _setGameSystemBackHandler'),
    );
    expect(appSource, contains('request("app.input.takeover")'));
    expect(appSource, contains('__handleNativeBack()'));
  });
}
