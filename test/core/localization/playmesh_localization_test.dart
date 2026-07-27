import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/localization/playmesh_localization.dart';
import 'package:playmesh/core/localization/playmesh_ui_controller.dart';
import 'package:playmesh/core/localization/playmesh_ui_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('packaged localization manifest and every bundle are valid', () async {
    final catalog = await PlaymeshLocalizationCatalog.load();

    expect(catalog.manifest.manifestVersion, '1.0.0');
    expect(catalog.manifest.defaultLocale, 'zh-CN');
    expect(
      catalog.manifest.enabledLocales.map((locale) => locale.id),
      containsAllInOrder(['zh-CN', 'en-US']),
    );
    expect(
      catalog.resolvedMessages(
        'en-US',
        PlaymeshLocalizationBundle.app,
      )['common.publisher'],
      'Publisher',
    );
  });

  test('manifest rejects a fallback cycle', () async {
    final source = await rootBundle.loadString(
      playmeshLocalizationManifestAsset,
    );
    final json = Map<String, Object?>.from(jsonDecode(source) as Map);
    final locales = (json['locales']! as List)
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList();
    locales.first['fallback'] = 'en-US';
    json['locales'] = locales;

    expect(
      () => PlaymeshLocalizationManifest.parse(jsonEncode(json)),
      throwsFormatException,
    );
  });

  test('manifest rejects a bundle path outside its locale directory', () async {
    final source = await rootBundle.loadString(
      playmeshLocalizationManifestAsset,
    );
    final json = Map<String, Object?>.from(jsonDecode(source) as Map);
    final locales = (json['locales']! as List)
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList();
    final bundles = Map<String, Object?>.from(locales.first['bundles']! as Map);
    bundles['app'] = '../app.json';
    locales.first['bundles'] = bundles;
    json['locales'] = locales;

    expect(
      () => PlaymeshLocalizationManifest.parse(jsonEncode(json)),
      throwsFormatException,
    );
  });

  testWidgets('context localization rejects a missing key', (tester) async {
    final catalog = await tester.runAsync(PlaymeshLocalizationCatalog.load);
    expect(catalog, isNotNull);
    late BuildContext localizedContext;

    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en', 'US'),
        delegates: [
          DefaultWidgetsLocalizations.delegate,
          PlaymeshLocalizationsDelegate(catalog!),
        ],
        child: Builder(
          builder: (context) {
            localizedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      () => localizedContext.tr('test.missing_key'),
      throwsA(isA<FlutterError>()),
    );
  });

  testWidgets('context localization rejects a missing delegate', (
    tester,
  ) async {
    late BuildContext unlocalizedContext;

    await tester.pumpWidget(
      Builder(
        builder: (context) {
          unlocalizedContext = context;
          return const SizedBox.shrink();
        },
      ),
    );

    expect(
      () => unlocalizedContext.tr('common.close'),
      throwsA(isA<FlutterError>()),
    );
  });

  test('UI preferences normalize and persist a fixed locale', () async {
    final catalog = await PlaymeshLocalizationCatalog.load();
    final root = await Directory.systemTemp.createTemp(
      'playmesh-ui-preferences-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = PlaymeshUiPreferencesStore(libraryRoot: root);
    const preferences = PlaymeshUiPreferences(
      localeMode: PlaymeshLocaleMode.fixed,
      localeId: 'en-US',
      theme: PlaymeshThemePreference.dark,
    );

    await store.save(preferences, catalog.manifest);
    final restored = await store.load(catalog.manifest);

    expect(restored.localeMode, PlaymeshLocaleMode.fixed);
    expect(restored.localeId, 'en-US');
    expect(restored.theme, PlaymeshThemePreference.dark);
  });

  test('UI preferences reject fixed mode without a locale', () async {
    final catalog = await PlaymeshLocalizationCatalog.load();

    expect(
      () => PlaymeshUiPreferences.parse(
        jsonEncode({
          'formatVersion': '1.0.0',
          'localeMode': 'fixed',
          'localeId': null,
          'themeMode': 'system',
        }),
        catalog.manifest,
      ),
      throwsFormatException,
    );
  });

  test('UI preference save queue recovers after a failed write', () async {
    final catalog = await PlaymeshLocalizationCatalog.load();
    final failure = StateError('simulated write failure');
    final store = _FailOncePreferencesStore(failure);
    final controller = PlaymeshUiController(
      PlaymeshUiBootstrap(
        catalog: catalog,
        preferences: PlaymeshUiPreferences.defaults(catalog.manifest),
        preferencesStore: store,
      ),
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.useTheme(PlaymeshThemePreference.light),
      throwsA(same(failure)),
    );
    await controller.useTheme(PlaymeshThemePreference.dark);

    expect(store.saveCalls, 2);
    expect(store.savedPreferences, hasLength(1));
    expect(store.savedPreferences.single.theme, PlaymeshThemePreference.dark);
  });
}

class _FailOncePreferencesStore extends PlaymeshUiPreferencesStore {
  _FailOncePreferencesStore(this.failure);

  final Object failure;
  final List<PlaymeshUiPreferences> savedPreferences = [];
  int saveCalls = 0;

  @override
  Future<void> save(
    PlaymeshUiPreferences preferences,
    PlaymeshLocalizationManifest manifest,
  ) async {
    saveCalls += 1;
    if (saveCalls == 1) throw failure;
    savedPreferences.add(preferences);
  }
}
