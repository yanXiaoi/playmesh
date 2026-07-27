import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/app_webview_bridge.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';

void main() {
  test(
    'App bridge carries locale privately and SDK removes it from ready',
    () async {
      final bridge = AppWebViewBridge(
        userId: 'u-platform-ui',
        nickname: 'Player',
        platformUiConfiguration: const {
          'locale': 'en-US',
          'theme': 'light',
          'messages': {'toolbar.expand': 'Open game tools'},
        },
      );
      addTearDown(bridge.close);
      final messages = <Map<String, Object?>>[];

      await bridge.handleJavaScriptMessage(
        jsonEncode({
          'command': 'app.bootstrap',
          'requestId': 'bootstrap',
          'sdkVersion': SdkFeatureRegistry.appSdkVersion,
          'payload': <String, Object?>{},
        }),
        (message) async {
          messages.add(Map<String, Object?>.from(jsonDecode(message) as Map));
        },
      );

      final internalResult = messages.single['result']! as Map<String, Object?>;
      expect(
        internalResult['_playmeshPlatformUi'],
        containsPair('locale', 'en-US'),
      );
      expect(
        internalResult['_playmeshPlatformUi'],
        containsPair('theme', 'light'),
      );

      final appSource = SdkFeatureRegistry.sdkFile('playmesh-app.js');
      expect(appSource, contains('delete bootstrap._playmeshPlatformUi'));
      expect(appSource, contains('return clone(bootstrap)'));
      expect(
        SdkFeatureRegistry.sdkFile('playmesh-app.d.ts'),
        isNot(contains('_playmeshPlatformUi')),
      );
    },
  );

  test(
    'Game SDK exposes locale only and keeps platform UI messages private',
    () {
      final source = SdkFeatureRegistry.sdkFile('playmesh.js');
      final declaration = SdkFeatureRegistry.sdkFile('playmesh.d.ts');

      expect(source, contains('message.type === "platform.ui.configure"'));
      expect(source, contains('configurePlatformUi('));
      expect(source, contains('runtimeLocaleUsesBrowserSystem'));
      expect(source, contains('platformUiSystemThemeChanged'));
      expect(source, contains('data-theme'));
      expect(source, contains('resolveBrowserPlatformUiConfiguration'));
      expect(source, contains('navigatorObject?.languages'));
      expect(source, contains('navigatorObject?.language'));
      expect(source, contains('browserRuntimeLocale'));
      expect(source, contains('runtimeLocale = normalizedExposedLocale'));
      expect(source, contains('"zh-CN"'));
      expect(source, isNot(contains('readPlatformUiJson')));
      expect(source, isNot(contains('/playmesh/localization/')));
      expect(source, contains('platformHtml("toolbar.expand")'));
      expect(
        source,
        contains('setPlatformControlLabel(ui.expand, "toolbar.expand")'),
      );
      expect(source, contains('platformText("nickname.invalid")'));
      expect(source, contains('platformText("nickname.update_failed")'));
      expect(source, contains('platformText("capability.denied")'));
      expect(source, isNot(contains('title="展开游戏工具"')));
      expect(source, isNot(contains('>拒绝并退出<')));
      expect(source, isNot(contains('>暂无运行日志<')));
      expect(source, contains('getLocale()'));
      expect(declaration, contains('readonly runtime:'));
      expect(declaration, contains('getLocale(): string'));
      expect(declaration, isNot(contains('platform.ui.configure')));
      expect(declaration, isNot(contains('platformUiMessages')));
      expect(declaration, isNot(contains('_playmeshPlatformUi')));
    },
  );
}
