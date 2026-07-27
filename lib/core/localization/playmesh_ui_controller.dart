import 'package:flutter/material.dart';

import 'playmesh_localization.dart';
import 'playmesh_ui_preferences.dart';

class PlaymeshUiBootstrap {
  const PlaymeshUiBootstrap({
    required this.catalog,
    required this.preferences,
    required this.preferencesStore,
  });

  final PlaymeshLocalizationCatalog catalog;
  final PlaymeshUiPreferences preferences;
  final PlaymeshUiPreferencesStore preferencesStore;

  static Future<PlaymeshUiBootstrap> load({
    AssetBundle? bundle,
    PlaymeshUiPreferencesStore preferencesStore =
        const PlaymeshUiPreferencesStore(),
  }) async {
    final catalog = await PlaymeshLocalizationCatalog.load(bundle: bundle);
    final preferences = await preferencesStore.load(catalog.manifest);
    return PlaymeshUiBootstrap(
      catalog: catalog,
      preferences: preferences,
      preferencesStore: preferencesStore,
    );
  }
}

class PlaymeshUiController extends ChangeNotifier {
  PlaymeshUiController(PlaymeshUiBootstrap bootstrap)
    : catalog = bootstrap.catalog,
      _preferences = bootstrap.preferences,
      _store = bootstrap.preferencesStore;

  final PlaymeshLocalizationCatalog catalog;
  final PlaymeshUiPreferencesStore _store;
  PlaymeshUiPreferences _preferences;
  Future<void> _saveOperation = Future<void>.value();

  PlaymeshUiPreferences get preferences => _preferences;
  ThemeMode get themeMode => _preferences.theme.themeMode;
  Locale? get fixedLocale {
    if (_preferences.localeMode != PlaymeshLocaleMode.fixed) return null;
    return catalog.manifest.descriptor(_preferences.localeId!).locale;
  }

  Iterable<Locale> get supportedLocales =>
      catalog.manifest.enabledLocales.map((entry) => entry.locale);

  Locale resolveLocale(Locale? locale, Iterable<Locale> platformLocales) {
    final fixed = fixedLocale;
    if (fixed != null) return fixed;
    final preferred = <Locale>[?locale, ...platformLocales];
    final id = catalog.manifest.resolvePlatformLocales(preferred);
    return catalog.manifest.descriptor(id).locale;
  }

  Future<void> useSystemLocale() async {
    await _replace(
      _preferences.copyWith(
        localeMode: PlaymeshLocaleMode.system,
        clearLocaleId: true,
      ),
    );
  }

  Future<void> useLocale(String localeId) async {
    final normalized = catalog.manifest.resolveEnabledLocale(localeId);
    await _replace(
      _preferences.copyWith(
        localeMode: PlaymeshLocaleMode.fixed,
        localeId: normalized,
      ),
    );
  }

  Future<void> useTheme(PlaymeshThemePreference theme) async {
    await _replace(_preferences.copyWith(theme: theme));
  }

  Future<void> _replace(PlaymeshUiPreferences next) async {
    _preferences = next;
    notifyListeners();
    final operation = _saveOperation.then(
      (_) => _store.save(next, catalog.manifest),
    );
    _saveOperation = operation.catchError((Object _) {});
    await operation;
  }
}
