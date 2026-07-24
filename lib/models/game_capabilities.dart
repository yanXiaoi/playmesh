import '../core/capabilities/default_capability_plugins.dart';

class GameCapabilities {
  const GameCapabilities({
    this.required = const {},
    this.controllerRequired = const {},
  });

  factory GameCapabilities.fromJson(Map<String, Object?> json) {
    final unknownFields = json.keys.where(
      (key) => key != 'required' && key != 'controllerRequired',
    );
    if (unknownFields.isNotEmpty) {
      throw FormatException(
        'capabilities.json 包含未知字段: ${unknownFields.join(', ')}',
      );
    }
    return GameCapabilities(
      required: Set.unmodifiable(_parseRequired(json['required'], 'required')),
      controllerRequired: Set.unmodifiable(
        _parseRequired(json['controllerRequired'], 'controllerRequired'),
      ),
    );
  }

  static Set<String> _parseRequired(Object? value, String field) {
    if (value == null) return {};
    if (value is! List) {
      throw FormatException('capabilities.json.$field 必须是数组');
    }
    final required = <String>{};
    for (final rawCapability in value) {
      if (rawCapability is! String) {
        throw FormatException('capabilities.json.$field 只能包含字符串');
      }
      if (!defaultCapabilityDescriptorRegistry.containsKey(rawCapability)) {
        throw FormatException('当前平台版本不支持游戏能力: $rawCapability');
      }
      if (!required.add(rawCapability)) {
        throw FormatException('capabilities.json.$field 包含重复值: $rawCapability');
      }
    }
    return required;
  }

  final Set<String> required;
  final Set<String> controllerRequired;

  bool get isEmpty => required.isEmpty && controllerRequired.isEmpty;

  Set<String> requiredForRole({required bool controller}) =>
      controller ? controllerRequired : required;

  Map<String, Object?> toJson() => {
    'required': required.toList(),
    if (controllerRequired.isNotEmpty)
      'controllerRequired': controllerRequired.toList(),
  };
}
