import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';

void main() {
  test('主 SDK 在 App 与浏览器初始化前统一完成能力确认', () async {
    final source = SdkFeatureRegistry.sdkFile('playmesh-main.js');

    expect(source, contains('function requestCapabilityConsent'));
    expect(source, contains('function capabilityDisplayText'));
    expect(source, contains('["media.camera", "capability.media.camera"]'));
    expect(source, contains('name: definition?.name || capability'));
    expect(source, contains('description: definition?.description || ""'));
    expect(source, contains('platformHtml("capability.unsupported")'));
    expect(source, contains('platformHtml("capability.deny")'));
    expect(source, contains('platformHtml("capability.allow")'));
    expect(source, contains('max-height:calc(100dvh - 32px)'));
    expect(source, contains('overflow-y:auto'));
    expect(source, contains('<div class="content">'));
    expect(source, contains('error.code = "capability_denied"'));
    expect(
      source,
      contains('appInternalRuntime.shouldAutoApproveCapabilities() === true'),
    );
    expect(source, contains('await appInternalRuntime.confirmCapabilities()'));
    expect(
      source.indexOf('await requestCapabilityConsent(appBootstrap);'),
      lessThan(source.indexOf('? connectBrowserFullscreen({')),
    );
  });

  test('App SDK 只转发退出请求，不实现能力弹窗', () async {
    final source = SdkFeatureRegistry.sdkFile('playmesh-app.js');

    expect(source, contains('return request("app.game.exit")'));
    expect(source, contains('return request("app.capabilities.confirm")'));
    expect(source, contains('shouldAutoApproveCapabilities()'));
    expect(
      source,
      contains('delete bootstrap._playmeshAutoApproveCapabilities'),
    );
    expect(source, isNot(contains('capability.deny')));
    expect(source, isNot(contains('capability.allow')));
  });
}
