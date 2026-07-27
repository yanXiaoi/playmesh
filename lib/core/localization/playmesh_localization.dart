import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const playmeshLocalizationRoot = 'assets/playmesh-localization';
const playmeshLocalizationManifestAsset =
    '$playmeshLocalizationRoot/manifest.json';

enum PlaymeshLocalizationBundle {
  app('app'),
  goServer('goServer');

  const PlaymeshLocalizationBundle(this.manifestKey);

  final String manifestKey;
}

class PlaymeshLocaleDescriptor {
  const PlaymeshLocaleDescriptor({
    required this.id,
    required this.label,
    required this.enabled,
    required this.fallback,
    required this.bundles,
  });

  final String id;
  final String label;
  final bool enabled;
  final String? fallback;
  final Map<PlaymeshLocalizationBundle, String> bundles;

  Locale get locale {
    final parts = id.split('-');
    return Locale.fromSubtags(
      languageCode: parts.first,
      scriptCode: parts.length == 3 ? parts[1] : null,
      countryCode: parts.length == 2
          ? parts[1]
          : parts.length == 3
          ? parts[2]
          : null,
    );
  }
}

class PlaymeshLocalizationManifest {
  PlaymeshLocalizationManifest._({
    required this.manifestVersion,
    required this.defaultLocale,
    required this.allowLocaleSwitch,
    required this.defaultThemeMode,
    required this.allowThemeSwitch,
    required this.locales,
  }) : _byId = {for (final locale in locales) locale.id: locale};

  final String manifestVersion;
  final String defaultLocale;
  final bool allowLocaleSwitch;
  final String defaultThemeMode;
  final bool allowThemeSwitch;
  final List<PlaymeshLocaleDescriptor> locales;
  final Map<String, PlaymeshLocaleDescriptor> _byId;

  Iterable<PlaymeshLocaleDescriptor> get enabledLocales =>
      locales.where((locale) => locale.enabled);

  PlaymeshLocaleDescriptor descriptor(String id) {
    final descriptor = _byId[id];
    if (descriptor == null) {
      throw FormatException('Unknown Playmesh locale: $id');
    }
    return descriptor;
  }

  String resolveEnabledLocale(String requestedId) {
    var current = descriptor(requestedId);
    final visited = <String>{};
    while (!current.enabled) {
      if (!visited.add(current.id)) {
        throw FormatException(
          'Localization fallback cycle contains ${current.id}',
        );
      }
      final fallback = current.fallback;
      if (fallback == null) return defaultLocale;
      current = descriptor(fallback);
    }
    return current.id;
  }

  String resolvePlatformLocales(Iterable<Locale> preferredLocales) {
    final enabled = enabledLocales.toList(growable: false);
    for (final preferred in preferredLocales) {
      final exact = enabled.where(
        (candidate) =>
            candidate.locale.languageCode == preferred.languageCode &&
            candidate.locale.scriptCode == preferred.scriptCode &&
            candidate.locale.countryCode == preferred.countryCode,
      );
      if (exact.isNotEmpty) return exact.first.id;
    }
    for (final preferred in preferredLocales) {
      final language = enabled.where(
        (candidate) =>
            candidate.locale.languageCode.toLowerCase() ==
            preferred.languageCode.toLowerCase(),
      );
      if (language.isNotEmpty) return language.first.id;
    }
    return defaultLocale;
  }

  List<String> fallbackOrder(String localeId) {
    final reverse = <String>[];
    final visited = <String>{};
    PlaymeshLocaleDescriptor? current = descriptor(localeId);
    while (current != null) {
      if (!visited.add(current.id)) {
        throw FormatException(
          'Localization fallback cycle contains ${current.id}',
        );
      }
      reverse.add(current.id);
      final fallback = current.fallback;
      current = fallback == null ? null : descriptor(fallback);
    }
    return reverse.reversed.toList(growable: false);
  }

  static PlaymeshLocalizationManifest parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException(
        'Localization manifest root must be an object.',
      );
    }
    final json = Map<String, Object?>.from(decoded);
    final version = _requiredString(json, 'manifestVersion');
    if (!_strictSemver.hasMatch(version)) {
      throw const FormatException(
        'Localization manifestVersion must use strict MAJOR.MINOR.PATCH.',
      );
    }
    final defaultLocale = _requiredString(json, 'defaultLocale');
    final rawUi = json['ui'];
    if (rawUi is! Map) {
      throw const FormatException(
        'Localization manifest ui must be an object.',
      );
    }
    final ui = Map<String, Object?>.from(rawUi);
    final allowLocaleSwitch = _requiredBool(ui, 'allowLocaleSwitch');
    final defaultThemeMode = _requiredString(ui, 'defaultThemeMode');
    if (!const {'system', 'light', 'dark'}.contains(defaultThemeMode)) {
      throw FormatException('Unknown default theme mode: $defaultThemeMode');
    }
    final allowThemeSwitch = _requiredBool(ui, 'allowThemeSwitch');
    final rawLocales = json['locales'];
    if (rawLocales is! List || rawLocales.isEmpty) {
      throw const FormatException(
        'Localization manifest locales must be a non-empty array.',
      );
    }

    final ids = <String>{};
    final bundlePaths = <String>{};
    final locales = <PlaymeshLocaleDescriptor>[];
    for (final rawLocale in rawLocales) {
      if (rawLocale is! Map) {
        throw const FormatException(
          'Localization locale entries must be objects.',
        );
      }
      final localeJson = Map<String, Object?>.from(rawLocale);
      final id = _requiredString(localeJson, 'id');
      if (!_localeId.hasMatch(id) || !ids.add(id)) {
        throw FormatException('Invalid or duplicate locale id: $id');
      }
      final fallbackValue = localeJson['fallback'];
      final fallback = fallbackValue == null
          ? null
          : _requiredString(localeJson, 'fallback');
      final rawBundles = localeJson['bundles'];
      if (rawBundles is! Map) {
        throw FormatException('Locale $id bundles must be an object.');
      }
      final bundleJson = Map<String, Object?>.from(rawBundles);
      final bundles = <PlaymeshLocalizationBundle, String>{};
      for (final kind in PlaymeshLocalizationBundle.values) {
        final relative = _requiredString(bundleJson, kind.manifestKey);
        _validateBundlePath(relative, localeId: id);
        if (!bundlePaths.add(relative)) {
          throw FormatException(
            'Localization bundle path is reused: $relative',
          );
        }
        bundles[kind] = '$playmeshLocalizationRoot/$relative';
      }
      locales.add(
        PlaymeshLocaleDescriptor(
          id: id,
          label: _requiredString(localeJson, 'label'),
          enabled: _requiredBool(localeJson, 'enabled'),
          fallback: fallback,
          bundles: Map.unmodifiable(bundles),
        ),
      );
    }

    final result = PlaymeshLocalizationManifest._(
      manifestVersion: version,
      defaultLocale: defaultLocale,
      allowLocaleSwitch: allowLocaleSwitch,
      defaultThemeMode: defaultThemeMode,
      allowThemeSwitch: allowThemeSwitch,
      locales: List.unmodifiable(locales),
    );
    final defaultDescriptor = result._byId[defaultLocale];
    if (defaultDescriptor == null || !defaultDescriptor.enabled) {
      throw const FormatException(
        'Localization defaultLocale must reference an enabled locale.',
      );
    }
    for (final locale in locales) {
      if (locale.fallback != null &&
          !result._byId.containsKey(locale.fallback)) {
        throw FormatException(
          'Locale ${locale.id} references unknown fallback ${locale.fallback}.',
        );
      }
      result.fallbackOrder(locale.id);
    }
    return result;
  }
}

class PlaymeshLocalizationCatalog {
  PlaymeshLocalizationCatalog._({
    required this.manifest,
    required this._messages,
  });

  final PlaymeshLocalizationManifest manifest;
  final Map<String, Map<PlaymeshLocalizationBundle, Map<String, String>>>
  _messages;

  static Future<PlaymeshLocalizationCatalog> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final manifest = PlaymeshLocalizationManifest.parse(
      await assets.loadString(playmeshLocalizationManifestAsset),
    );
    final messages =
        <String, Map<PlaymeshLocalizationBundle, Map<String, String>>>{};
    for (final locale in manifest.locales) {
      final localeMessages =
          <PlaymeshLocalizationBundle, Map<String, String>>{};
      for (final kind in PlaymeshLocalizationBundle.values) {
        final path = locale.bundles[kind]!;
        localeMessages[kind] = _parseMessages(
          await assets.loadString(path),
          assetPath: path,
        );
      }
      messages[locale.id] = Map.unmodifiable(localeMessages);
    }
    final result = PlaymeshLocalizationCatalog._(
      manifest: manifest,
      messages: Map.unmodifiable(messages),
    );
    result._validateKeyCoverage();
    return result;
  }

  Map<String, String> resolvedMessages(
    String localeId,
    PlaymeshLocalizationBundle kind,
  ) {
    final resolved = <String, String>{};
    for (final id in manifest.fallbackOrder(localeId)) {
      resolved.addAll(_messages[id]![kind]!);
    }
    return Map.unmodifiable(resolved);
  }

  void _validateKeyCoverage() {
    for (final kind in PlaymeshLocalizationBundle.values) {
      final requiredKeys = <String>{};
      for (final locale in manifest.locales) {
        requiredKeys.addAll(_messages[locale.id]![kind]!.keys);
      }
      for (final locale in manifest.enabledLocales) {
        final available = resolvedMessages(locale.id, kind).keys.toSet();
        final missing = requiredKeys.difference(available);
        if (missing.isNotEmpty) {
          throw FormatException(
            'Locale ${locale.id} is missing ${kind.manifestKey} keys: '
            '${missing.toList()..sort()}',
          );
        }
      }
    }
  }
}

class PlaymeshLocalizations {
  const PlaymeshLocalizations(this.localeId, this._messages);

  final String localeId;
  final Map<String, String> _messages;

  static PlaymeshLocalizations of(BuildContext context) {
    final value = maybeOf(context);
    if (value == null) {
      throw FlutterError(
        'No PlaymeshLocalizations found in the provided BuildContext. '
        'Wrap the widget tree with the Playmesh localization delegate and '
        'catalog before calling BuildContext.tr.',
      );
    }
    return value;
  }

  static PlaymeshLocalizations? maybeOf(BuildContext context) {
    return Localizations.of<PlaymeshLocalizations>(
      context,
      PlaymeshLocalizations,
    );
  }

  String text(String key, {Map<String, Object?> arguments = const {}}) {
    final template = _messages[key];
    if (template == null) {
      throw FlutterError('Missing localized message: $key ($localeId)');
    }
    return _interpolate(template, arguments);
  }

  Map<String, String> messagesWithPrefix(
    String prefix, {
    bool stripPrefix = false,
  }) {
    if (prefix.isEmpty) {
      throw ArgumentError.value(prefix, 'prefix', 'Prefix must not be empty');
    }
    return Map.unmodifiable({
      for (final entry in _messages.entries)
        if (entry.key.startsWith(prefix))
          (stripPrefix ? entry.key.substring(prefix.length) : entry.key):
              entry.value,
    });
  }
}

class PlaymeshLocalizationsDelegate
    extends LocalizationsDelegate<PlaymeshLocalizations> {
  const PlaymeshLocalizationsDelegate(this.catalog);

  final PlaymeshLocalizationCatalog catalog;

  @override
  bool isSupported(Locale locale) {
    return catalog.manifest.enabledLocales.any(
      (candidate) =>
          candidate.locale.languageCode == locale.languageCode &&
          candidate.locale.countryCode == locale.countryCode &&
          candidate.locale.scriptCode == locale.scriptCode,
    );
  }

  @override
  Future<PlaymeshLocalizations> load(Locale locale) {
    final localeId = catalog.manifest.resolvePlatformLocales([locale]);
    return SynchronousFuture(
      PlaymeshLocalizations(
        localeId,
        catalog.resolvedMessages(localeId, PlaymeshLocalizationBundle.app),
      ),
    );
  }

  @override
  bool shouldReload(covariant PlaymeshLocalizationsDelegate old) {
    return !identical(catalog, old.catalog);
  }
}

extension PlaymeshLocalizationContext on BuildContext {
  String tr(String key, {Map<String, Object?> arguments = const {}}) {
    return PlaymeshLocalizations.of(this).text(key, arguments: arguments);
  }
}

Map<String, String> _parseMessages(String source, {required String assetPath}) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw FormatException('Localization bundle must be an object: $assetPath');
  }
  final result = <String, String>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String ||
        key.isEmpty ||
        !_messageKey.hasMatch(key) ||
        value is! String) {
      throw FormatException(
        'Localization values must be keyed strings: $assetPath',
      );
    }
    if (_executableHtml.hasMatch(value)) {
      throw FormatException(
        'Localization value contains executable HTML: $assetPath#$key',
      );
    }
    result[key] = value;
  }
  if (result.isEmpty) {
    throw FormatException('Localization bundle is empty: $assetPath');
  }
  return Map.unmodifiable(result);
}

String _interpolate(String template, Map<String, Object?> arguments) {
  var result = template;
  for (final entry in arguments.entries) {
    result = result.replaceAll('{${entry.key}}', '${entry.value ?? ''}');
  }
  return result;
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field must be a non-empty string.');
  }
  return value.trim();
}

bool _requiredBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! bool) throw FormatException('$field must be a boolean.');
  return value;
}

void _validateBundlePath(String path, {required String localeId}) {
  if (path.startsWith('/') ||
      path.startsWith(r'\') ||
      path.contains(r'\') ||
      path.contains('..') ||
      !RegExp(
        '^locales/${RegExp.escape(localeId)}/[^/]+\\.json\$',
      ).hasMatch(path)) {
    throw FormatException('Locale $localeId has an unsafe bundle path: $path');
  }
}

final _strictSemver = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$');
final _localeId = RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$');
final _messageKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$');
final _executableHtml = RegExp(
  r'<\s*/?\s*(script|iframe|object|embed|style|link)\b',
  caseSensitive: false,
);
