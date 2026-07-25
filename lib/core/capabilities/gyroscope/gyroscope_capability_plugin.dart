import '../capability_plugin.dart';
import '../support/motion_capability_instance.dart';
import '../support/motion_sensor_source.dart';

class GyroscopeCapabilityPlugin implements CapabilityPlugin {
  GyroscopeCapabilityPlugin({required this.source})
    : _hub = MotionStreamHub(
        available: source.gyroscopeAvailable,
        openStream: source.gyroscopeEvents,
      );

  static const code = 'sensor.gyroscope';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '陀螺仪',
    description: '读取设备绕 X、Y、Z 三个轴向的旋转速度，用于姿态和转向控制。',
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
            'unit': {'const': 'rad/s'},
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
  bool get isAvailable => source.gyroscopeAvailable;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async =>
      MotionCapabilityInstance(hub: _hub, fps: capabilityFps(options));

  @override
  Future<CapabilityJson> test(Duration timeout) async {
    if (!isAvailable) throw UnsupportedError('当前平台不支持陀螺仪');
    final sample = await source
        .gyroscopeEvents(const Duration(milliseconds: 50))
        .first
        .timeout(timeout);
    return {'sample': sample.toJson()};
  }

  @override
  Future<void> dispose() => _hub.dispose();
}
