import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final path in const <String>[
    'ios/Runner/Info.plist',
    'macos/Runner/Info.plist',
  ]) {
    test('$path 保留本地网络用途且不再声明 Bonjour 服务', () {
      final plist = File(path).readAsStringSync();

      expect(plist, contains('<key>NSLocalNetworkUsageDescription</key>'));
      expect(plist, isNot(contains('<key>NSBonjourServices</key>')));
      expect(plist, isNot(contains('_playmesh-game._tcp')));
    });
  }

  for (final path in const <String>[
    'macos/Runner/DebugProfile.entitlements',
    'macos/Runner/Release.entitlements',
  ]) {
    test('$path 保留自定义 UDP client/server sandbox 权限', () {
      final entitlements = File(path).readAsStringSync();

      expect(
        _enabledBooleanKey(entitlements, 'com.apple.security.network.client'),
        isTrue,
      );
      expect(
        _enabledBooleanKey(entitlements, 'com.apple.security.network.server'),
        isTrue,
      );
    });
  }

  test('iOS 不声明 multicast entitlement，自动发现由平台适配器拒绝', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final info = File('ios/Runner/Info.plist').readAsStringSync();

    expect(
      project,
      isNot(contains('com.apple.developer.networking.multicast')),
    );
    expect(info, isNot(contains('com.apple.developer.networking.multicast')));
  });
}

bool _enabledBooleanKey(String plist, String key) =>
    RegExp('<key>${RegExp.escape(key)}</key>\\s*<true\\s*/>').hasMatch(plist);
