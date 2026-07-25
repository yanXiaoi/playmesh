import '../capability_plugin.dart';
import '../support/motion_capability_instance.dart';
import '../support/motion_sensor_source.dart';

class AccelerometerCapabilityPlugin implements CapabilityPlugin {
  AccelerometerCapabilityPlugin({required this.source})
    : _hub = MotionStreamHub(
        available: source.accelerometerAvailable,
        openStream: source.accelerometerEvents,
      );

  static const code = 'sensor.accelerometer';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '加速度计',
    description: '读取设备在 X、Y、Z 三个轴向上的加速度，用于倾斜、晃动和体感控制。',
    apiVersion: '1.0.0',
    optionsSchema: {
      'type': 'object',
      'properties': {
        'fps': {'type': 'integer', 'minimum': 1, 'maximum': 120, 'default': 30},
      },
      'additionalProperties': false,
    },
    methods: [
      CapabilityMethodDescriptor(name: 'start', description: '开始发送采样事件。'),
      CapabilityMethodDescriptor(name: 'stop', description: '停止发送采样事件。'),
    ],
    events: [
      CapabilityEventDescriptor(
        name: 'reading',
        description: '包含 X、Y、Z、时间戳和单位的采样。',
        dataSchema: {
          'type': 'object',
          'required': ['x', 'y', 'z', 'timestamp', 'unit'],
          'properties': {
            'x': {'type': 'number'},
            'y': {'type': 'number'},
            'z': {'type': 'number'},
            'timestamp': {'type': 'number'},
            'unit': {'const': 'm/s^2'},
          },
        },
      ),
    ],
  );

  final MotionSensorSource source;
  final MotionStreamHub _hub;

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  bool get isAvailable => source.accelerometerAvailable;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async =>
      MotionCapabilityInstance(hub: _hub, fps: capabilityFps(options));

  @override
  Future<CapabilityJson> test(Duration timeout) async {
    if (!isAvailable) throw UnsupportedError('当前平台不支持加速度计');
    final sample = await source
        .accelerometerEvents(const Duration(milliseconds: 50))
        .first
        .timeout(timeout);
    return {'sample': sample.toJson()};
  }

  @override
  Future<void> dispose() => _hub.dispose();
}
