import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows WebView 鼠标进入和离开都实时同步到 WebView2', () {
    final dartSource = File(
      'third_party/webview_flutter_windows/lib/src/webview.dart',
    ).readAsStringSync();
    final nativeHeader = File(
      'third_party/webview_flutter_windows/windows/webview.h',
    ).readAsStringSync();
    final nativeSource = File(
      'third_party/webview_flutter_windows/windows/webview.cc',
    ).readAsStringSync();
    final bridgeSource = File(
      'third_party/webview_flutter_windows/windows/webview_bridge.cc',
    ).readAsStringSync();

    expect(dartSource, contains("invokeMethod('setCursorLeave')"));
    expect(dartSource, contains('onEnter:'));
    expect(dartSource, contains('onExit:'));
    expect(dartSource, contains('_controller._setCursorLeave()'));

    expect(nativeHeader, contains('void SetCursorLeave();'));
    expect(nativeSource, contains('void Webview::SetCursorLeave()'));
    expect(nativeSource, contains('COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE'));
    expect(
      bridgeSource,
      contains('constexpr auto kMethodSetCursorLeave = "setCursorLeave";'),
    );
    expect(bridgeSource, contains('webview_->SetCursorLeave();'));
  });

  test('Windows WebView 每个实例从普通箭头开始且不缓存上一文档光标', () {
    final dartSource = File(
      'third_party/webview_flutter_windows/lib/src/webview.dart',
    ).readAsStringSync();

    expect(
      dartSource,
      contains('MouseCursor _cursor = SystemMouseCursors.basic;'),
    );
    expect(dartSource, contains('if (value == LoadingState.loading)'));
    expect(
      dartSource,
      contains('_cursorStreamController.add(SystemMouseCursors.basic);'),
    );
    expect(dartSource, isNot(contains('_currentCursor')));
    expect(dartSource, isNot(contains('_cachedCursor')));
  });
}
