class GameCapabilityCodes {
  const GameCapabilityCodes._();

  static const accelerometer = 'sensor.accelerometer';
  static const gyroscope = 'sensor.gyroscope';
}

class GameCapabilityDefinition {
  const GameCapabilityDefinition({
    required this.code,
    required this.name,
    required this.description,
    required this.appSupported,
    required this.htmlSupported,
  });

  final String code;
  final String name;
  final String description;
  final bool appSupported;
  final bool htmlSupported;

  Map<String, Object?> toJson() => {
    'code': code,
    'name': name,
    'description': description,
    'appSupported': appSupported,
    'htmlSupported': htmlSupported,
  };
}

/// 能力声明的唯一元数据注册表。
///
/// SDK 弹窗、开发者工具和 capabilities.json 校验均从这里读取；新增声明能力时
/// 只需在此增加一项。具体原生或浏览器适配器仍由对应运行时实现。
const gameCapabilityDefinitions = <GameCapabilityDefinition>[
  GameCapabilityDefinition(
    code: GameCapabilityCodes.accelerometer,
    name: '加速度计',
    description: '读取设备在 X、Y、Z 三个轴向上的加速度，用于倾斜、晃动和体感控制。',
    appSupported: true,
    htmlSupported: false,
  ),
  GameCapabilityDefinition(
    code: GameCapabilityCodes.gyroscope,
    name: '陀螺仪',
    description: '读取设备绕 X、Y、Z 三个轴向的旋转速度，用于姿态和转向控制。',
    appSupported: true,
    htmlSupported: false,
  ),
];

final Map<String, GameCapabilityDefinition> gameCapabilityRegistry =
    Map.unmodifiable({
      for (final definition in gameCapabilityDefinitions)
        definition.code: definition,
    });
