import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../library/playmesh_library_root.dart';
import 'playmesh_localization.dart';

enum PlaymeshLocaleMode {
  system('system'),
  fixed('fixed');

  const PlaymeshLocaleMode(this.wireName);

  final String wireName;
}

enum PlaymeshThemePreference {
  system('system', ThemeMode.system),
  light('light', ThemeMode.light),
  dark('dark', ThemeMode.dark);

  const PlaymeshThemePreference(this.wireName, this.themeMode);

  final String wireName;
  final ThemeMode themeMode;
}

class PlaymeshUiPreferences {
  const PlaymeshUiPreferences({
    required this.localeMode,
    required this.localeId,
    required this.theme,
  });

  static const formatVersion = '1.0.0';

  final PlaymeshLocaleMode localeMode;
  final String? localeId;
  final PlaymeshThemePreference theme;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'localeMode': localeMode.wireName,
    'localeId': localeMode == PlaymeshLocaleMode.fixed ? localeId : null,
    'themeMode': theme.wireName,
  };

  PlaymeshUiPreferences copyWith({
    PlaymeshLocaleMode? localeMode,
    String? localeId,
    bool clearLocaleId = false,
    PlaymeshThemePreference? theme,
  }) {
    return PlaymeshUiPreferences(
      localeMode: localeMode ?? this.localeMode,
      localeId: clearLocaleId ? null : localeId ?? this.localeId,
      theme: theme ?? this.theme,
    );
  }

  static PlaymeshUiPreferences defaults(PlaymeshLocalizationManifest manifest) {
    return PlaymeshUiPreferences(
      localeMode: PlaymeshLocaleMode.system,
      localeId: null,
      theme: _parseTheme(manifest.defaultThemeMode),
    );
  }

  static PlaymeshUiPreferences parse(
    String source,
    PlaymeshLocalizationManifest manifest,
  ) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('UI preferences root must be an object.');
    }
    final json = Map<String, Object?>.from(decoded);
    if (json['formatVersion'] != formatVersion) {
      throw const FormatException(
        'UI preferences formatVersion is unsupported.',
      );
    }
    final localeMode = _parseLocaleMode(json['localeMode']);
    final rawLocaleId = json['localeId'];
    String? localeId;
    if (localeMode == PlaymeshLocaleMode.fixed) {
      if (rawLocaleId is! String || rawLocaleId.trim().isEmpty) {
        throw const FormatException('Fixed locale mode requires a localeId.');
      }
      localeId = manifest.resolveEnabledLocale(rawLocaleId.trim());
    } else if (rawLocaleId != null) {
      throw const FormatException(
        'System locale mode requires a null localeId.',
      );
    }
    final theme = _parseTheme(json['themeMode']);
    return PlaymeshUiPreferences(
      localeMode: localeMode,
      localeId: localeId,
      theme: theme,
    );
  }
}

class PlaymeshUiPreferencesStore {
  const PlaymeshUiPreferencesStore({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;

  Future<PlaymeshUiPreferences> load(
    PlaymeshLocalizationManifest manifest,
  ) async {
    final file = await _file();
    if (!await file.exists()) return PlaymeshUiPreferences.defaults(manifest);
    try {
      return PlaymeshUiPreferences.parse(await file.readAsString(), manifest);
    } on Object {
      return PlaymeshUiPreferences.defaults(manifest);
    }
  }

  Future<void> save(
    PlaymeshUiPreferences preferences,
    PlaymeshLocalizationManifest manifest,
  ) async {
    final normalized = PlaymeshUiPreferences.parse(
      jsonEncode(preferences.toJson()),
      manifest,
    );
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.playmesh-tmp');
    final backup = File('${file.path}.playmesh-backup');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(normalized.toJson())}\n',
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await file.exists()) await file.delete();
      if (await backup.exists()) await backup.rename(file.path);
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<File> _file() async {
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    return File(
      '${root.path}${Platform.pathSeparator}settings'
      '${Platform.pathSeparator}ui.json',
    );
  }
}

PlaymeshLocaleMode _parseLocaleMode(Object? value) {
  for (final mode in PlaymeshLocaleMode.values) {
    if (mode.wireName == value) return mode;
  }
  throw FormatException('Unknown localeMode: $value');
}

PlaymeshThemePreference _parseTheme(Object? value) {
  for (final theme in PlaymeshThemePreference.values) {
    if (theme.wireName == value) return theme;
  }
  throw FormatException('Unknown themeMode: $value');
}
