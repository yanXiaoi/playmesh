import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('主 SDK 在 App 与浏览器初始化前统一完成能力确认', () async {
    final source = await File(
      'assets/playmesh-library/public/sdk/v1/playmesh.js',
    ).readAsString();

    expect(source, contains('function requestCapabilityConsent'));
    expect(source, contains('（本平台暂不支持）'));
    expect(source, contains('拒绝并退出'));
    expect(source, contains('同意并进入'));
    expect(source, contains('max-height:calc(100dvh - 32px)'));
    expect(source, contains('overflow-y:auto'));
    expect(source, contains('<div class="content">'));
    expect(source, contains('error.code = "capability_denied"'));
    expect(
      source.indexOf('await requestCapabilityConsent(appBootstrap);'),
      lessThan(source.indexOf('? connectBrowserFullscreen({')),
    );
  });

  test('App SDK 只转发退出请求，不实现能力弹窗', () async {
    final source = await File(
      'assets/playmesh-library/public/sdk/v1/playmesh-app.js',
    ).readAsString();

    expect(source, contains('return request("app.game.exit")'));
    expect(source, contains('return request("app.capabilities.confirm")'));
    expect(source, isNot(contains('拒绝并退出')));
    expect(source, isNot(contains('同意并进入')));
  });
}
