import 'game_capability_registry.dart';

enum GameSensorCapability {
  accelerometer('accelerometer', GameCapabilityCodes.accelerometer),
  gyroscope('gyroscope', GameCapabilityCodes.gyroscope);

  const GameSensorCapability(this.jsonValue, this.sdkCapability);

  final String jsonValue;
  final String sdkCapability;
  String get label => gameCapabilityRegistry[sdkCapability]!.name;
}

class GameCapabilities {
  const GameCapabilities({this.required = const {}});

  factory GameCapabilities.fromJson(Map<String, Object?> json) {
    final unknownFields = json.keys.where((key) => key != 'required');
    if (unknownFields.isNotEmpty) {
      throw FormatException(
        'capabilities.json 包含未知字段: ${unknownFields.join(', ')}',
      );
    }
    final rawCapabilities = json['required'];
    if (rawCapabilities == null) return const GameCapabilities();
    if (rawCapabilities is! List) {
      throw const FormatException('capabilities.json.required 必须是数组');
    }
    final required = <String>{};
    for (final rawCapability in rawCapabilities) {
      if (rawCapability is! String) {
        throw const FormatException('capabilities.json.required 只能包含字符串');
      }
      if (!gameCapabilityRegistry.containsKey(rawCapability)) {
        throw FormatException('当前平台版本不支持游戏能力: $rawCapability');
      }
      if (!required.add(rawCapability)) {
        throw FormatException(
          'capabilities.json.required 包含重复值: $rawCapability',
        );
      }
    }
    return GameCapabilities(required: Set.unmodifiable(required));
  }

  final Set<String> required;

  bool get isEmpty => required.isEmpty;

  Set<GameSensorCapability> get sensors => Set.unmodifiable(
    GameSensorCapability.values.where(
      (sensor) => required.contains(sensor.sdkCapability),
    ),
  );

  Map<String, Object?> toJson() => {'required': required.toList()};
}
