import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:playmesh/core/localization/playmesh_localization.dart';
import 'package:playmesh/core/localization/playmesh_ui_controller.dart';
import 'package:playmesh/core/localization/playmesh_ui_preferences.dart';

Future<PlaymeshLocalizationCatalog>? _catalogLoad;
PlaymeshLocalizationCatalog? _catalog;

Future<void> initializeLocalizedTestApp() async {
  _catalog ??= await (_catalogLoad ??= PlaymeshLocalizationCatalog.load());
}

PlaymeshUiBootstrap localizedTestUiBootstrap() {
  final catalog = _catalog;
  if (catalog == null) {
    throw StateError(
      'Call initializeLocalizedTestApp from setUpAll before bootstrapping.',
    );
  }
  return PlaymeshUiBootstrap(
    catalog: catalog,
    preferences: const PlaymeshUiPreferences(
      localeMode: PlaymeshLocaleMode.fixed,
      localeId: 'zh-CN',
      theme: PlaymeshThemePreference.system,
    ),
    preferencesStore: const _MemoryPreferencesStore(),
  );
}

MaterialApp localizedTestApp({
  required Widget home,
  Locale locale = const Locale('zh', 'CN'),
  GlobalKey<NavigatorState>? navigatorKey,
  Map<String, WidgetBuilder> routes = const <String, WidgetBuilder>{},
  RouteFactory? onGenerateRoute,
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
}) {
  final catalog = _catalog;
  if (catalog == null) {
    throw StateError(
      'Call initializeLocalizedTestApp from setUpAll before building widgets.',
    );
  }
  return MaterialApp(
    navigatorKey: navigatorKey,
    locale: locale,
    supportedLocales: catalog.manifest.enabledLocales
        .map((entry) => entry.locale)
        .toList(growable: false),
    localeResolutionCallback: (requested, _) {
      final localeId = catalog.manifest.resolvePlatformLocales([?requested]);
      return catalog.manifest.descriptor(localeId).locale;
    },
    localizationsDelegates: [
      PlaymeshLocalizationsDelegate(catalog),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
    routes: routes,
    onGenerateRoute: onGenerateRoute,
    navigatorObservers: navigatorObservers,
  );
}

class _MemoryPreferencesStore extends PlaymeshUiPreferencesStore {
  const _MemoryPreferencesStore();

  @override
  Future<void> save(
    PlaymeshUiPreferences preferences,
    PlaymeshLocalizationManifest manifest,
  ) async {}
}
