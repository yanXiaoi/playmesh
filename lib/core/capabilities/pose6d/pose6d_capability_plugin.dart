import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';

import '../../app_media/app_media_adapter.dart';
import '../../app_media/app_media_runtime.dart';
import '../capability_plugin.dart';
import '../web_permission/web_permission_platform_authorizer.dart';

typedef Pose6dJson = Map<String, Object?>;

abstract interface class Pose6dPlatformDriver {
  Stream<Pose6dJson> get events;

  Future<void> start(int rateHz);

  Future<void> updateRate(int rateHz);

  Future<void> stop();

  Future<void> dispose();
}

final class NativePose6dPlatformDriver implements Pose6dPlatformDriver {
  NativePose6dPlatformDriver();

  static const MethodChannel _channel = MethodChannel('playmesh/pose6d');
  static const EventChannel _eventChannel = EventChannel(
    'playmesh/pose6d/events',
  );

  Stream<Pose6dJson>? _events;

  @override
  Stream<Pose6dJson> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => Map<String, Object?>.from(event as Map))
      .asBroadcastStream();

  @override
  Future<void> start(int rateHz) =>
      _channel.invokeMethod<void>('start', {'rateHz': rateHz});

  @override
  Future<void> updateRate(int rateHz) =>
      _channel.invokeMethod<void>('updateRate', {'rateHz': rateHz});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> dispose() async {
    try {
      await stop();
    } on MissingPluginException {
      // 非 Android 测试宿主没有原生通道，释放仍保持幂等。
    } on FlutterError {
      // 未初始化 Flutter Binding 的纯 Dart 测试同样没有原生通道。
    }
  }
}

/// 多个能力实例共享一个 ARCore Session；最高订阅频率决定原生采样频率。
final class Pose6dHub {
  Pose6dHub(this.driver);

  final Pose6dPlatformDriver driver;
  final Map<int, int> _rates = {};
  StreamSubscription<Pose6dJson>? _subscription;
  final StreamController<Pose6dJson> _events = StreamController.broadcast();
  int _sequence = 0;
  int _nativeRate = 0;
  bool _disposed = false;

  Stream<Pose6dJson> get events => _events.stream;

  Future<Pose6dLease> acquire(int rateHz) async {
    if (_disposed) throw StateError('Pose6d Hub 已释放');
    final id = ++_sequence;
    _rates[id] = rateHz;
    try {
      if (_rates.length == 1) {
        _subscription = driver.events.listen(
          _events.add,
          onError: _events.addError,
        );
        await driver.start(rateHz);
        _nativeRate = rateHz;
      } else {
        await _refreshNativeRate();
      }
    } on Object catch (error, stackTrace) {
      _rates.remove(id);
      if (_rates.isEmpty) {
        final subscription = _subscription;
        _subscription = null;
        _nativeRate = 0;
        try {
          await _runPoseCleanupActions([
            if (subscription != null) subscription.cancel,
            driver.stop,
          ]);
        } on Object {
          // 创建失败时保留原始平台错误，清理仍已逐项尝试。
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    return Pose6dLease._(this, id, rateHz);
  }

  Future<void> _release(int id) async {
    if (_rates.remove(id) == null) return;
    if (_rates.isEmpty) {
      _nativeRate = 0;
      final subscription = _subscription;
      _subscription = null;
      await _runPoseCleanupActions([
        if (subscription != null) subscription.cancel,
        driver.stop,
      ]);
      return;
    }
    await _refreshNativeRate();
  }

  Future<void> _refreshNativeRate() async {
    final rate = _rates.values.reduce(math.max);
    if (rate == _nativeRate) return;
    await driver.updateRate(rate);
    _nativeRate = rate;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _rates.clear();
    final subscription = _subscription;
    _subscription = null;
    await _runPoseCleanupActions([
      if (subscription != null) subscription.cancel,
      driver.dispose,
      _events.close,
    ]);
  }
}

final class Pose6dLease {
  Pose6dLease._(this._hub, this._id, this.rateHz);

  final Pose6dHub _hub;
  final int _id;
  final int rateHz;
  bool _closed = false;

  Stream<Pose6dJson> get events => _hub.events;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _hub._release(_id);
  }
}

final class Pose6dCapabilityPlugin implements CapabilityPlugin {
  factory Pose6dCapabilityPlugin({
    required Pose6dHub hub,
    required AppMediaSourceBroker mediaSourceBroker,
    required WebPermissionPlatformAuthorizer permissionAuthorizer,
  }) => Pose6dCapabilityPlugin._(hub, mediaSourceBroker, permissionAuthorizer);

  Pose6dCapabilityPlugin._(
    this._hub,
    this._mediaSourceBroker,
    this._permissionAuthorizer,
  );

  static const code = 'sensor.pose6d';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '空间位姿',
    description: '通过终端空间跟踪输出米制 XYZ 位置和 XYZW 四元数，并可按需创建摄像头媒体源。',
    apiVersion: '1.0.0',
    supportedPlatforms: [CapabilityPlatform.ANDROID],
    optionsSchema: {
      'type': 'object',
      'properties': {
        'rateHz': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 60,
          'default': 30,
        },
      },
      'additionalProperties': false,
    },
    methods: [
      CapabilityMethodDescriptor(
        name: 'recenter',
        description: '把当前可用位姿作为本实例原点；尚未跟踪时使用下一次有效位姿。',
        argumentsSchema: {'type': 'object', 'additionalProperties': false},
      ),
      CapabilityMethodDescriptor(
        name: 'openVideo',
        description: '创建一个由 playmesh.app.media.open() 按需消费的实时视频源。',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            'width': {'type': 'integer', 'minimum': 160, 'maximum': 3840},
            'height': {'type': 'integer', 'minimum': 120, 'maximum': 2160},
            'fps': {'type': 'integer', 'minimum': 1, 'maximum': 60},
          },
          'additionalProperties': false,
        },
        resultSchema: {
          'type': 'object',
          'required': ['type', 'version', 'id', 'kind', 'protocol', 'live'],
        },
      ),
      CapabilityMethodDescriptor(
        name: 'createVideoSource',
        description: 'openVideo 的兼容别名；返回同一种受控实时视频源。',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            'width': {'type': 'integer', 'minimum': 160, 'maximum': 3840},
            'height': {'type': 'integer', 'minimum': 120, 'maximum': 2160},
            'fps': {'type': 'integer', 'minimum': 1, 'maximum': 60},
          },
          'additionalProperties': false,
        },
        resultSchema: {
          'type': 'object',
          'required': ['type', 'version', 'id', 'kind', 'protocol', 'live'],
        },
      ),
    ],
    events: [
      CapabilityEventDescriptor(
        name: 'pose',
        description: '当前终端相对于本实例原点的空间位姿。',
        dataSchema: {
          'type': 'object',
          'required': [
            'captureTimestampNs',
            'trackingState',
            'position',
            'rotation',
          ],
          'properties': {
            'captureTimestampNs': {'type': 'string'},
            'trackingState': {
              'type': 'string',
              'enum': ['tracking', 'paused', 'stopped'],
            },
            'position': {
              'type': 'array',
              'items': {'type': 'number'},
              'minItems': 3,
              'maxItems': 3,
            },
            'rotation': {
              'type': 'array',
              'items': {'type': 'number'},
              'minItems': 4,
              'maxItems': 4,
            },
          },
        },
      ),
    ],
  );

  final Pose6dHub _hub;
  final AppMediaSourceBroker _mediaSourceBroker;
  final WebPermissionPlatformAuthorizer _permissionAuthorizer;

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  bool get isAvailable => true;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    final rateHz = _integer(
      options,
      'rateHz',
      defaultValue: 30,
      minimum: 1,
      maximum: 60,
    );
    if (options.keys.any((key) => key != 'rateHz')) {
      throw const FormatException('sensor.pose6d 包含未知创建参数');
    }
    final granted = await _permissionAuthorizer.authorize(
      const WebPermissionPlatformRequest(
        androidPermissions: ['android.permission.CAMERA'],
      ),
    );
    if (!granted) throw StateError('用户未授予空间跟踪所需的相机权限');
    final lease = await _hub.acquire(rateHz);
    return _Pose6dCapabilityInstance(
      lease: lease,
      mediaSourceBroker: _mediaSourceBroker,
    );
  }

  @override
  Future<void> dispose() => _hub.dispose();
}

final class _Pose6dCapabilityInstance implements CapabilityInstance {
  _Pose6dCapabilityInstance({
    required Pose6dLease lease,
    required this._mediaSourceBroker,
  }) : _lease = lease {
    _subscription = lease.events.listen(_onRawPose, onError: _events.addError);
  }

  final Pose6dLease _lease;
  final AppMediaSourceBroker _mediaSourceBroker;
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  final List<AppMediaJson> _mediaSources = [];
  late final StreamSubscription<Pose6dJson> _subscription;
  List<double>? _originPosition;
  List<double>? _originRotation;
  Pose6dJson? _latestTrackingPose;
  final Stopwatch _eventClock = Stopwatch()..start();
  int _lastEventMicros = 0;
  bool _recenterOnNextTrackingPose = false;
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async {
    if (_disposed) throw StateError('能力实例已释放');
    switch (method) {
      case 'recenter':
        if (arguments.isNotEmpty) {
          throw const FormatException('recenter 不接受参数');
        }
        final latest = _latestTrackingPose;
        if (latest == null) {
          _recenterOnNextTrackingPose = true;
        } else {
          _setOrigin(latest);
        }
        return null;
      case 'openVideo':
      case 'createVideoSource':
        final sourceOptions = _videoSourceOptions(arguments);
        final source = await _mediaSourceBroker.createSource(
          producer: Pose6dCapabilityPlugin.code,
          kind: 'video',
          sourceOptions: sourceOptions,
        );
        _mediaSources.add(Map<String, Object?>.from(source));
        return source;
    }
    throw FormatException('sensor.pose6d 未声明能力方法：$method');
  }

  void _onRawPose(Pose6dJson raw) {
    if (_disposed) return;
    final timestamp = raw['captureTimestampNs'];
    final trackingState = raw['trackingState'];
    final position = _doubleList(raw['position'], length: 3);
    final rotation = _doubleList(raw['rotation'], length: 4);
    if (timestamp is! String ||
        trackingState is! String ||
        !const {'tracking', 'paused', 'stopped'}.contains(trackingState) ||
        int.tryParse(timestamp) == null ||
        position == null ||
        rotation == null) {
      _events.addError(const FormatException('原生 pose6d 事件格式无效'));
      return;
    }
    final normalizedRaw = <String, Object?>{
      'captureTimestampNs': timestamp,
      'trackingState': trackingState,
      'position': position,
      'rotation': rotation,
    };
    if (trackingState == 'tracking') {
      _latestTrackingPose = normalizedRaw;
      if (_recenterOnNextTrackingPose) {
        _setOrigin(normalizedRaw);
      }
    }
    final nowMicros = _eventClock.elapsedMicroseconds;
    final minimumGap = (1000000 / _lease.rateHz).floor();
    if (_lastEventMicros != 0 && nowMicros - _lastEventMicros < minimumGap) {
      return;
    }
    _lastEventMicros = nowMicros;
    final relative = trackingState == 'tracking'
        ? _relativePose(position, rotation)
        : (position: position, rotation: rotation);
    _events.add(
      CapabilityInstanceEvent('pose', {
        'captureTimestampNs': timestamp,
        'trackingState': trackingState,
        'position': relative.position,
        'rotation': relative.rotation,
      }),
    );
  }

  void _setOrigin(Pose6dJson raw) {
    _originPosition = List<double>.from(raw['position']! as List);
    _originRotation = List<double>.from(raw['rotation']! as List);
    _recenterOnNextTrackingPose = false;
  }

  ({List<double> position, List<double> rotation}) _relativePose(
    List<double> position,
    List<double> rotation,
  ) {
    final originPosition = _originPosition;
    final originRotation = _originRotation;
    if (originPosition == null || originRotation == null) {
      return (position: position, rotation: rotation);
    }
    final inverseOrigin = [
      -originRotation[0],
      -originRotation[1],
      -originRotation[2],
      originRotation[3],
    ];
    final delta = [
      position[0] - originPosition[0],
      position[1] - originPosition[1],
      position[2] - originPosition[2],
    ];
    return (
      position: _rotateVector(inverseOrigin, delta),
      rotation: _normalizeQuaternion(
        _multiplyQuaternion(inverseOrigin, rotation),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sources = _mediaSources.reversed.toList(growable: false);
    _mediaSources.clear();
    await _runPoseCleanupActions([
      _subscription.cancel,
      for (final source in sources)
        () => _mediaSourceBroker.releaseSource(source),
      _lease.close,
      _events.close,
    ]);
  }
}

int _integer(
  Map<String, Object?> value,
  String field, {
  required int defaultValue,
  required int minimum,
  required int maximum,
}) {
  final raw = value[field];
  if (raw == null) return defaultValue;
  if (raw is! int || raw < minimum || raw > maximum) {
    throw FormatException('$field 必须是 $minimum～$maximum 的整数');
  }
  return raw;
}

AppMediaJson _videoSourceOptions(CapabilityJson arguments) {
  const fields = {'width', 'height', 'fps'};
  if (arguments.keys.any((key) => !fields.contains(key))) {
    throw const FormatException('视频源请求包含未知参数');
  }
  return {
    if (arguments.containsKey('width'))
      'width': _integer(
        arguments,
        'width',
        defaultValue: 640,
        minimum: 160,
        maximum: 3840,
      ),
    if (arguments.containsKey('height'))
      'height': _integer(
        arguments,
        'height',
        defaultValue: 480,
        minimum: 120,
        maximum: 2160,
      ),
    if (arguments.containsKey('fps'))
      'fps': _integer(
        arguments,
        'fps',
        defaultValue: 30,
        minimum: 1,
        maximum: 60,
      ),
  };
}

Future<void> _runPoseCleanupActions(
  Iterable<Future<void> Function()> actions,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final action in actions) {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

List<double>? _doubleList(Object? value, {required int length}) {
  if (value is! List || value.length != length) return null;
  final result = <double>[];
  for (final item in value) {
    if (item is! num || !item.isFinite) return null;
    result.add(item.toDouble());
  }
  return result;
}

List<double> _multiplyQuaternion(List<double> left, List<double> right) => [
  left[3] * right[0] +
      left[0] * right[3] +
      left[1] * right[2] -
      left[2] * right[1],
  left[3] * right[1] -
      left[0] * right[2] +
      left[1] * right[3] +
      left[2] * right[0],
  left[3] * right[2] +
      left[0] * right[1] -
      left[1] * right[0] +
      left[2] * right[3],
  left[3] * right[3] -
      left[0] * right[0] -
      left[1] * right[1] -
      left[2] * right[2],
];

List<double> _normalizeQuaternion(List<double> value) {
  final length = math.sqrt(
    value.fold<double>(0, (sum, item) => sum + item * item),
  );
  if (length == 0) return [0, 0, 0, 1];
  return value.map((item) => item / length).toList(growable: false);
}

List<double> _rotateVector(List<double> quaternion, List<double> vector) {
  final vectorQuaternion = [vector[0], vector[1], vector[2], 0.0];
  final inverse = [
    -quaternion[0],
    -quaternion[1],
    -quaternion[2],
    quaternion[3],
  ];
  final rotated = _multiplyQuaternion(
    _multiplyQuaternion(quaternion, vectorQuaternion),
    inverse,
  );
  return [rotated[0], rotated[1], rotated[2]];
}
