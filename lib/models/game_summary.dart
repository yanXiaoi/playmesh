import 'local_game_entry.dart';
import 'game_capabilities.dart';

enum GameOrientation {
  landscape('landscape'),
  portrait('portrait');

  const GameOrientation(this.manifestValue);

  final String manifestValue;

  static GameOrientation fromManifestValue(String value) {
    return GameOrientation.values.firstWhere(
      (orientation) => orientation.manifestValue == value,
      orElse: () => throw FormatException('不支持的游戏屏幕方向: $value'),
    );
  }
}

class GameSummary {
  const GameSummary({
    required this.id,
    required this.name,
    required this.version,
    this.author = '',
    this.lastModifiedAt,
    this.lastOpenedAt,
    this.launchCount = 0,
    this.localIconPath,
    this.manifestError,
    this.sdkVersion = '',
    this.appSdkVersion = '',
    required this.description,
    required this.minPlayers,
    required this.maxPlayers,
    required this.supportsMultiplayer,
    required this.displayModeLabel,
    required this.displayMode,
    required this.orientation,
    this.controllerOrientation,
    required this.entry,
    this.tags = const [],
    this.capabilities = const GameCapabilities(),
    this.config,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final DateTime? lastModifiedAt;
  final DateTime? lastOpenedAt;
  final int launchCount;
  final String? localIconPath;
  final String? manifestError;
  final String sdkVersion;
  final String appSdkVersion;
  final String description;
  final int minPlayers;
  final int maxPlayers;
  final bool supportsMultiplayer;
  final String displayModeLabel;
  final String displayMode;
  final GameOrientation orientation;
  final GameOrientation? controllerOrientation;
  final LocalGameEntry entry;
  final List<String> tags;
  final GameCapabilities capabilities;
  final Object? config;

  bool get isRunnable => manifestError == null;

  GameOrientation orientationForRole({required bool controller}) =>
      controller ? controllerOrientation ?? orientation : orientation;

  GameSummary withUsage({DateTime? lastOpenedAt, int? launchCount}) =>
      GameSummary(
        id: id,
        name: name,
        version: version,
        author: author,
        lastModifiedAt: lastModifiedAt,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
        launchCount: launchCount ?? this.launchCount,
        localIconPath: localIconPath,
        manifestError: manifestError,
        sdkVersion: sdkVersion,
        appSdkVersion: appSdkVersion,
        description: description,
        minPlayers: minPlayers,
        maxPlayers: maxPlayers,
        supportsMultiplayer: supportsMultiplayer,
        displayModeLabel: displayModeLabel,
        displayMode: displayMode,
        orientation: orientation,
        controllerOrientation: controllerOrientation,
        entry: entry,
        tags: tags,
        capabilities: capabilities,
        config: config,
      );

  GameSummary withLastOpenedAt(DateTime value) =>
      withUsage(lastOpenedAt: value);
}
