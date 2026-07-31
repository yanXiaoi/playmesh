import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/platform/app_platform.dart';

void main() {
  test('开发启动的平台策略将手持端与桌面端分开', () {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(isMobileAppPlatform, isTrue);

      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(isMobileAppPlatform, isFalse, reason: '$platform 的开发运行应保持窗口化');
      }
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}
