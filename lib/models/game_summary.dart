import 'local_game_entry.dart';
import 'game_capabilities.dart';

enum GameOrientation {
  landscape('landscape', '横屏'),
  portrait('portrait', '竖屏');

  const GameOrientation(this.manifestValue, this.label);

  final String manifestValue;
  final String label;

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
    this.author = '佚名',
    this.lastModifiedAt,
    this.lastOpenedAt,
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
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final DateTime? lastModifiedAt;
  final DateTime? lastOpenedAt;
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

  String get playerRangeLabel {
    if (minPlayers == maxPlayers) {
      return '$minPlayers 人';
    }

    return '$minPlayers-$maxPlayers 人';
  }

  String get modeLabel => supportsMultiplayer ? '支持联机' : '单机';

  GameOrientation orientationForRole({required bool controller}) =>
      controller ? controllerOrientation ?? orientation : orientation;

  GameSummary withLastOpenedAt(DateTime value) => GameSummary(
    id: id,
    name: name,
    version: version,
    author: author,
    lastModifiedAt: lastModifiedAt,
    lastOpenedAt: value,
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
  );
}
