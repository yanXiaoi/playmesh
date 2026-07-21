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
    required this.description,
    required this.minPlayers,
    required this.maxPlayers,
    required this.supportsMultiplayer,
    required this.displayModeLabel,
    required this.displayMode,
    required this.orientation,
    required this.entry,
    this.tags = const [],
    this.capabilities = const GameCapabilities(),
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final int minPlayers;
  final int maxPlayers;
  final bool supportsMultiplayer;
  final String displayModeLabel;
  final String displayMode;
  final GameOrientation orientation;
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
}
