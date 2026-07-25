import 'dart:async';

import '../../platform/app_device_service.dart';
import '../capability_plugin.dart';

class VibrationCapabilityPlugin implements CapabilityPlugin {
  const VibrationCapabilityPlugin({required this.deviceService});

  static const code = 'device.vibration';
  static const supportedStyles = <String>[
    'selection',
    'light',
    'medium',
    'heavy',
    'vibrate',
  ];
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '震动反馈',
    description: '触发当前设备的原生震动或触觉反馈，可用于按键确认、碰撞和得分反馈。',
    apiVersion: '1.0.0',
    optionsSchema: {'type': 'object', 'additionalProperties': false},
    methods: [
      CapabilityMethodDescriptor(
        name: 'vibrate',
        description: '按指定强度触发一次原生震动或触觉反馈。',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            'style': {
              'type': 'string',
              'enum': supportedStyles,
              'default': 'light',
            },
          },
          'additionalProperties': false,
        },
      ),
    ],
    events: [],
  );

  final AppDeviceService deviceService;

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  bool get isAvailable => deviceService.hapticsAvailable;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    if (options.isNotEmpty) {
      throw const FormatException('震动能力不接受创建参数');
    }
    return _VibrationCapabilityInstance(deviceService);
  }

  @override
  Future<CapabilityJson> test(Duration timeout) async {
    if (!isAvailable) throw UnsupportedError('当前平台不支持原生震动');
    return {
      'available': true,
      'styles': supportedStyles,
      'sideEffectExecuted': false,
    };
  }

  @override
  Future<void> dispose() async {}
}

class _VibrationCapabilityInstance implements CapabilityInstance {
  _VibrationCapabilityInstance(this.deviceService);

  final AppDeviceService deviceService;
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async {
    if (_disposed) throw StateError('能力实例已释放');
    if (method != 'vibrate') {
      throw FormatException('震动能力不支持方法：$method');
    }
    final style = arguments['style'] ?? 'light';
    if (style is! String ||
        !VibrationCapabilityPlugin.supportedStyles.contains(style)) {
      throw const FormatException(
        'style 必须是 selection、light、medium、heavy 或 vibrate',
      );
    }
    if (arguments.keys.any((key) => key != 'style')) {
      throw const FormatException('震动方法包含未知参数');
    }
    await deviceService.haptic(style);
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
  }
}
