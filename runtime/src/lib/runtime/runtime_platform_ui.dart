import 'dart:convert';

import 'package:flutter/services.dart';

const runtimePlatformUiAsset = 'assets/runtime/platform-ui.json';

/// Minimal, Runtime-owned projection of the platform game UI translations.
///
/// It intentionally excludes the main App's screens and localization engine.
final class RuntimePlatformUiCatalog {
  const RuntimePlatformUiCatalog._({
    required this.fallbackLocale,
    required this._messagesByLocale,
  });

  factory RuntimePlatformUiCatalog.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Runtime 平台 UI 目录版本不受支持');
    }
    final fallback = json['fallbackLocale'];
    if (fallback is! String || fallback != 'zh-CN') {
      throw const FormatException('Runtime 平台 UI 必须保留 zh-CN 回退');
    }
    final rawLocales = json['locales'];
    if (rawLocales is! List || rawLocales.isEmpty) {
      throw const FormatException('Runtime 平台 UI 缺少语言目录');
    }
    final messagesByLocale = <String, Map<String, String>>{};
    Set<String>? requiredKeys;
    for (final rawLocale in rawLocales) {
      if (rawLocale is! Map) {
        throw const FormatException('Runtime 平台 UI 语言条目无效');
      }
      final locale = rawLocale['locale'];
      final rawMessages = rawLocale['messages'];
      if (locale is! String ||
          !_localePattern.hasMatch(locale) ||
          rawMessages is! Map ||
          rawMessages.isEmpty) {
        throw const FormatException('Runtime 平台 UI 语言条目无效');
      }
      if (messagesByLocale.keys.any(
        (candidate) => candidate.toLowerCase() == locale.toLowerCase(),
      )) {
        throw FormatException('Runtime 平台 UI 语言重复: $locale');
      }
      final messages = <String, String>{};
      for (final entry in rawMessages.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String ||
            !_messageKeyPattern.hasMatch(key) ||
            value is! String) {
          throw FormatException('Runtime 平台 UI $locale 包含无效消息');
        }
        messages[key] = value;
      }
      final keys = messages.keys.toSet();
      requiredKeys ??= keys;
      if (keys.length != requiredKeys.length ||
          !keys.containsAll(requiredKeys)) {
        throw FormatException('Runtime 平台 UI $locale 的消息集合不完整');
      }
      messagesByLocale[locale] = Map.unmodifiable(messages);
    }
    if (!messagesByLocale.containsKey(fallback)) {
      throw const FormatException('Runtime 平台 UI 缺少 zh-CN 回退内容');
    }
    return RuntimePlatformUiCatalog._(
      fallbackLocale: fallback,
      messagesByLocale: Map.unmodifiable(messagesByLocale),
    );
  }

  static Future<RuntimePlatformUiCatalog> load() async {
    final source = await rootBundle.loadString(runtimePlatformUiAsset);
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Runtime 平台 UI 目录根节点必须是对象');
    }
    return RuntimePlatformUiCatalog.fromJson(
      Map<String, Object?>.from(decoded),
    );
  }

  final String fallbackLocale;
  final Map<String, Map<String, String>> _messagesByLocale;

  Map<String, Object?> appConfiguration({
    required String? locale,
    required bool showShareAction,
  }) {
    final selected = _resolveLocale(locale);
    return {
      'locale': selected,
      'messages': _messagesByLocale[selected]!,
      'theme': 'system',
      'actions': _actions(showShareAction),
    };
  }

  Map<String, Object?> browserConfiguration() => {
    'fallbackLocale': fallbackLocale,
    'locales': [
      for (final entry in _messagesByLocale.entries)
        {'locale': entry.key, 'messages': entry.value, 'theme': 'system'},
    ],
    'actions': _actions(false),
  };

  String _resolveLocale(String? requested) {
    final normalized = requested?.replaceAll('_', '-').toLowerCase();
    if (normalized != null) {
      for (final locale in _messagesByLocale.keys) {
        if (locale.toLowerCase() == normalized) return locale;
      }
      final language = normalized.split('-').first;
      for (final locale in _messagesByLocale.keys) {
        if (locale.toLowerCase().split('-').first == language) return locale;
      }
    }
    return fallbackLocale;
  }
}

Map<String, bool> _actions(bool showShareAction) => {
  'share': showShareAction,
  'restart': true,
  'logs': true,
  'fullscreen': true,
  'info': true,
  'performance': true,
  'exit': true,
};

final _localePattern = RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$');
final _messageKeyPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$');
