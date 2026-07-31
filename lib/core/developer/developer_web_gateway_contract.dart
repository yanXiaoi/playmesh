import '../../models/game_summary.dart';
import 'developer_channel.dart';

class DeveloperWorkspaceLocale {
  const DeveloperWorkspaceLocale({required this.id, required this.label});

  final String id;
  final String label;

  Map<String, Object?> toJson() => {'id': id, 'label': label};
}

class DeveloperWorkspaceLocalization {
  const DeveloperWorkspaceLocalization({
    required this.localeId,
    required this.localeMode,
    required this.defaultLocale,
    required this.allowLocaleSwitch,
    required this.themeMode,
    required this.effectiveTheme,
    required this.allowThemeSwitch,
    required this.locales,
    required this.messages,
  });

  static const formatVersion = '1.0.0';

  final String localeId;
  final String localeMode;
  final String defaultLocale;
  final bool allowLocaleSwitch;
  final String themeMode;
  final String effectiveTheme;
  final bool allowThemeSwitch;
  final List<DeveloperWorkspaceLocale> locales;
  final Map<String, String> messages;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'localeId': localeId,
    'localeMode': localeMode,
    'defaultLocale': defaultLocale,
    'allowLocaleSwitch': allowLocaleSwitch,
    'themeMode': themeMode,
    'effectiveTheme': effectiveTheme,
    'allowThemeSwitch': allowThemeSwitch,
    'locales': locales.map((locale) => locale.toJson()).toList(),
    'messages': messages,
  };
}

typedef DeveloperWorkspaceLocalizationProvider =
    DeveloperWorkspaceLocalization Function();
typedef DeveloperWorkspaceLocaleUpdater =
    Future<void> Function(String? localeId);
typedef DeveloperWorkspaceThemeUpdater =
    Future<void> Function(String themeMode);

class DeveloperWorkspaceLocalizationBridge {
  const DeveloperWorkspaceLocalizationBridge({
    required this.current,
    required this.useLocale,
    required this.useTheme,
  });

  final DeveloperWorkspaceLocalizationProvider current;
  final DeveloperWorkspaceLocaleUpdater useLocale;
  final DeveloperWorkspaceThemeUpdater useTheme;
}

class DeveloperPublishSource {
  const DeveloperPublishSource({
    required this.id,
    required this.name,
    required this.protocolVersion,
    required this.maxUploadBytes,
  });

  final String id;
  final String name;
  final String protocolVersion;
  final int maxUploadBytes;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'protocolVersion': protocolVersion,
    'maxUploadBytes': maxUploadBytes,
  };
}

class DeveloperPublishSourceResult {
  const DeveloperPublishSourceResult({
    required this.sourceId,
    required this.status,
    this.sourceName,
    this.detail,
    this.retryAfter,
    this.currentHighestVersion,
  });

  final String sourceId;
  final String? sourceName;
  final String status;
  final String? detail;
  final String? retryAfter;
  final String? currentHighestVersion;

  bool get succeeded => status == 'entered_review';

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    if (sourceName != null) 'sourceName': sourceName,
    'status': status,
    if (detail != null) 'detail': detail,
    if (retryAfter != null) 'retryAfter': retryAfter,
    if (currentHighestVersion != null)
      'currentHighestVersion': currentHighestVersion,
  };
}

class DeveloperPublishBatchResult {
  const DeveloperPublishBatchResult({
    required this.gameId,
    required this.version,
    required this.sources,
    required this.failedSourceIds,
  });

  final String gameId;
  final String version;
  final List<DeveloperPublishSourceResult> sources;
  final List<String> failedSourceIds;

  bool get succeeded =>
      sources.isNotEmpty && sources.every((result) => result.succeeded);
  bool get partiallySucceeded =>
      sources.any((result) => result.succeeded) && !succeeded;

  Map<String, Object?> toJson() => {
    'gameId': gameId,
    'version': version,
    'succeeded': succeeded,
    'partiallySucceeded': partiallySucceeded,
    'failedSourceIds': failedSourceIds,
    'sources': sources.map((result) => result.toJson()).toList(),
  };
}

typedef DeveloperPublishEventCallback =
    void Function(DeveloperPublishSourceResult event);

abstract interface class DeveloperProjectPublisher {
  Future<List<DeveloperPublishSource>> listCandidates();

  Future<DeveloperPublishBatchResult> publish({
    required GameSummary game,
    required Iterable<String> sourceIds,
    DeveloperPublishEventCallback? onEvent,
  });
}

abstract interface class DeveloperWebGateway {
  DeveloperSession get session;

  Future<List<Uri>> workspaceLinks();

  Future<void> close();
}
