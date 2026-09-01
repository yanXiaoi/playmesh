import 'package:flutter/services.dart';

import 'playmesh_localization.dart';

const platformGameUiMessagePrefix = 'platform.game.';
const platformGameBrowserFallbackLocaleId = 'zh-CN';

const platformGameUiRequiredKeys = <String>{
  'capability.current_game',
  'capability.title',
  'capability.description',
  'capability.unsupported',
  'capability.deny',
  'capability.allow',
  'capability.denied',
  'capability.media.camera.name',
  'capability.media.camera.description',
  'capability.media.microphone.name',
  'capability.media.microphone.description',
  'capability.device.midi.name',
  'capability.device.midi.description',
  'capability.device.vibration.name',
  'capability.device.vibration.description',
  'sidebar.title',
  'sidebar.continue',
  'sidebar.restart',
  'sidebar.share',
  'sidebar.join',
  'sidebar.logs',
  'sidebar.enter_fullscreen',
  'sidebar.exit_fullscreen',
  'sidebar.info',
  'sidebar.performance',
  'sidebar.performance_hide',
  'sidebar.exit',
  'nickname.label',
  'nickname.set_title',
  'nickname.edit_action',
  'nickname.edit_title',
  'nickname.invalid',
  'nickname.update_failed',
  'common.cancel',
  'common.save',
  'common.close',
  'common.clear',
  'info.title',
  'info.default_game',
  'info.tags',
  'info.join_code',
  'info.solo_share',
  'info.game_id',
  'info.role',
  'info.role_solo',
  'info.role_authority',
  'info.role_player',
  'info.join_code_label',
  'info.player',
  'info.players',
  'info.platform',
  'info.game_sdk',
  'info.app_sdk',
  'info.capabilities',
  'info.none',
  'logs.title',
  'logs.empty',
  'logs.copy',
  'logs.copied',
  'join.title',
  'join.empty',
  'join.starting',
  'join.scanning',
  'join.scan',
  'join.input',
  'join.action',
  'join.failed',
};

class PlatformGameUiConfiguration {
  const PlatformGameUiConfiguration({
    required this.localeId,
    required this.messages,
    required this.theme,
  });

  final String localeId;
  final Map<String, String> messages;
  final String theme;

  Map<String, Object?> toJson() => {
    'locale': localeId,
    'messages': messages,
    'theme': theme,
  };
}

class PlatformGameUiBrowserCatalog {
  const PlatformGameUiBrowserCatalog._({required this.configurations});

  final List<PlatformGameUiConfiguration> configurations;

  Map<String, Object?> toJson() => {
    'fallbackLocale': platformGameBrowserFallbackLocaleId,
    'locales': configurations
        .map((configuration) => configuration.toJson())
        .toList(growable: false),
  };
}

PlatformGameUiConfiguration platformGameUiConfigurationFor(
  PlaymeshLocalizations localizations, {
  required Brightness brightness,
}) {
  final messages = localizations.messagesWithPrefix(
    platformGameUiMessagePrefix,
    stripPrefix: true,
  );
  final missing = platformGameUiRequiredKeys.difference(messages.keys.toSet());
  if (missing.isNotEmpty) {
    final sorted = missing.toList()..sort();
    throw StateError(
      'Locale ${localizations.localeId} is missing platform game UI keys: '
      '$sorted',
    );
  }
  return PlatformGameUiConfiguration(
    localeId: localizations.localeId,
    messages: messages,
    theme: brightness == Brightness.dark ? 'dark' : 'light',
  );
}

/// App 统一本地化目录中只读、仅限平台 UI 的投影。
///
/// App WebView 接收宿主选择的一份配置；普通浏览器接收启用的投影，并根据
/// `navigator` 选择语言。
class PlatformGameUiAssets {
  PlatformGameUiAssets._({
    required this.manifest,
    required this._configurations,
    required this._descriptorsById,
  });

  final PlaymeshLocalizationManifest manifest;
  final Map<String, PlatformGameUiConfiguration> _configurations;
  final Map<String, PlaymeshLocaleDescriptor> _descriptorsById;

  static Future<PlatformGameUiAssets> load({AssetBundle? bundle}) async {
    final catalog = await PlaymeshLocalizationCatalog.load(bundle: bundle);
    final configurations = <String, PlatformGameUiConfiguration>{};
    final descriptorsById = <String, PlaymeshLocaleDescriptor>{};

    for (final descriptor in catalog.manifest.locales) {
      descriptorsById[descriptor.id.toLowerCase()] = descriptor;
      final allMessages = catalog.resolvedMessages(
        descriptor.id,
        PlaymeshLocalizationBundle.app,
      );
      final platformMessages = <String, String>{
        for (final entry in allMessages.entries)
          if (entry.key.startsWith(platformGameUiMessagePrefix))
            entry.key.substring(platformGameUiMessagePrefix.length):
                entry.value,
      };
      final missing = platformGameUiRequiredKeys.difference(
        platformMessages.keys.toSet(),
      );
      if (missing.isNotEmpty) {
        final sorted = missing.toList()..sort();
        throw FormatException(
          'Locale ${descriptor.id} is missing platform game UI keys: $sorted',
        );
      }
      configurations[descriptor.id] = PlatformGameUiConfiguration(
        localeId: descriptor.id,
        messages: Map.unmodifiable(platformMessages),
        theme: 'system',
      );
    }
    final browserFallback =
        descriptorsById[platformGameBrowserFallbackLocaleId.toLowerCase()];
    if (browserFallback == null || !browserFallback.enabled) {
      throw const FormatException(
        'Browser platform UI fallback locale zh-CN must be enabled',
      );
    }

    return PlatformGameUiAssets._(
      manifest: catalog.manifest,
      configurations: Map.unmodifiable(configurations),
      descriptorsById: Map.unmodifiable(descriptorsById),
    );
  }

  PlatformGameUiConfiguration configurationForLocale(String? localeId) {
    final descriptor = _resolveDescriptor(localeId);
    return _configurations[descriptor.id]!;
  }

  PlatformGameUiBrowserCatalog get browserCatalog =>
      PlatformGameUiBrowserCatalog._(
        configurations: List.unmodifiable(
          manifest.enabledLocales.map(
            (descriptor) => _configurations[descriptor.id]!,
          ),
        ),
      );

  PlaymeshLocaleDescriptor _resolveDescriptor(String? localeId) {
    return _resolveDescriptorOrNull(localeId) ??
        _descriptorsById[manifest.defaultLocale.toLowerCase()]!;
  }

  PlaymeshLocaleDescriptor? _resolveDescriptorOrNull(String? localeId) {
    if (localeId == null) return null;
    var descriptor = _descriptorsById[localeId.toLowerCase()];
    final visited = <String>{};
    while (descriptor != null && !descriptor.enabled) {
      if (!visited.add(descriptor.id)) return null;
      final fallback = descriptor.fallback;
      descriptor = fallback == null
          ? null
          : _descriptorsById[fallback.toLowerCase()];
    }
    return descriptor;
  }
}
