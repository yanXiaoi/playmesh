import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/localization/platform_game_ui_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'game gateway projection exposes only platform UI localization',
    () async {
      final assets = await PlatformGameUiAssets.load();
      final configuration = assets.configurationForLocale('en-US');
      final messages = configuration.messages;

      expect(assets.manifest.defaultLocale, 'zh-CN');
      expect(configuration.localeId, 'en-US');
      expect(configuration.theme, 'system');
      expect(messages.keys, containsAll(platformGameUiRequiredKeys));
      expect(messages['sidebar.title'], 'Game menu');
      expect(messages['capability.media.microphone.name'], 'Microphone');
      expect(messages, isNot(contains('home.title')));
      expect(
        messages.keys,
        everyElement(isNot(startsWith(platformGameUiMessagePrefix))),
      );
    },
  );

  test(
    'browser catalog exposes enabled platform-only locale projections',
    () async {
      final assets = await PlatformGameUiAssets.load();
      final catalog = assets.browserCatalog;
      final json = catalog.toJson();

      expect(json['fallbackLocale'], platformGameBrowserFallbackLocaleId);
      expect(
        (json['locales']! as List).cast<Map>().every(
          (configuration) => configuration['theme'] == 'system',
        ),
        isTrue,
      );
      expect(
        catalog.configurations.map((configuration) => configuration.localeId),
        assets.manifest.enabledLocales.map((descriptor) => descriptor.id),
      );
      expect(
        catalog.configurations.expand(
          (configuration) => configuration.messages.keys,
        ),
        everyElement(isNot(startsWith(platformGameUiMessagePrefix))),
      );
      expect(
        catalog.configurations.expand(
          (configuration) => configuration.messages.keys,
        ),
        everyElement(isNot(equals('home.title'))),
      );
    },
  );
}
