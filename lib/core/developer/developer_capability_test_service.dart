import 'dart:async';

import '../capabilities/capability_plugin.dart';
import '../capabilities/capability_registry.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/support/motion_sensor_source.dart';
import '../platform/app_device_service.dart';
import 'developer_event_hub.dart';

/// 开发者工作区能力自检服务。
///
/// 清单、平台可用性和测试实现全部来自已注册能力插件。工作区始终展示当前
/// App 的完整平台注册表，不按某个项目的 capabilities.json 过滤。
class DeveloperCapabilityTestService {
  DeveloperCapabilityTestService({
    MotionSensorSource? motionSource,
    AppDeviceService? deviceService,
    CapabilityRegistry? registry,
    void Function(Map<String, Object?> event)? emitEvent,
  }) : registry =
           registry ??
           createDefaultCapabilityRegistry(
             motionSource: motionSource,
             deviceService: deviceService,
           ),
       _emitEvent = emitEvent ?? developerEventHub.emit;

  final CapabilityRegistry registry;
  final void Function(Map<String, Object?> event) _emitEvent;
  final Map<String, _DeveloperCapabilityTestInstance> _instances = {};
  int _instanceSequence = 0;

  List<Map<String, Object?>> describe() => registry.plugins
      .map(
        (plugin) => {
          ...plugin.descriptor.toJson(),
          'testable': true,
          'platformAvailable': plugin.isAvailable,
        },
      )
      .toList(growable: false);

  Future<List<Map<String, Object?>>> run({
    List<String>? codes,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final selected = codes == null || codes.isEmpty
        ? registry.plugins
        : codes
              .map((code) {
                final plugin = registry.plugin(code);
                if (plugin == null) throw FormatException('未知能力 code：$code');
                return plugin;
              })
              .toList(growable: false);
    final results = <Map<String, Object?>>[];
    for (final plugin in selected) {
      results.add(await _runOne(plugin, timeout));
    }
    return results;
  }

  Future<Map<String, Object?>> createInstance({
    required String code,
    required Map<String, Object?> options,
  }) async {
    final plugin = registry.plugin(code);
    if (plugin == null) throw FormatException('未知能力 code：$code');
    if (!plugin.isAvailable) {
      throw DeveloperCapabilityUnavailable('当前平台不支持 $code');
    }
    final CapabilityInstance instance;
    try {
      instance = await plugin.create(options);
    } on UnsupportedError catch (error) {
      throw DeveloperCapabilityUnavailable(
        error.message?.toString() ?? error.toString(),
      );
    }
    final instanceId =
        'capability-test-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_instanceSequence}';
    final descriptor = plugin.descriptor;
    final declaredEvents = descriptor.events.map((event) => event.name).toSet();
    final subscription = instance.events.listen(
      (event) {
        if (!declaredEvents.contains(event.name)) {
          _emitEvent({
            'type': 'capability.test.error',
            'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
            'instanceId': instanceId,
            'code': code,
            'error': '能力实例发送了未声明事件：${event.name}',
          });
          return;
        }
        _emitEvent({
          'type': 'capability.test.event',
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
          'instanceId': instanceId,
          'code': code,
          'event': event.name,
          'data': event.data,
        });
      },
      onError: (Object error) {
        _emitEvent({
          'type': 'capability.test.error',
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
          'instanceId': instanceId,
          'code': code,
          'error': error.toString(),
        });
      },
    );
    _instances[instanceId] = _DeveloperCapabilityTestInstance(
      code: code,
      descriptor: descriptor,
      instance: instance,
      events: subscription,
    );
    return {
      'instanceId': instanceId,
      'code': code,
      'apiVersion': descriptor.apiVersion,
      'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>> invokeInstance({
    required String instanceId,
    required String method,
    required Map<String, Object?> arguments,
  }) async {
    final open = _instances[instanceId];
    if (open == null) throw StateError('能力测试实例不存在或已释放：$instanceId');
    if (!open.descriptor.methods.any(
      (definition) => definition.name == method,
    )) {
      throw FormatException('${open.code} 未声明能力方法：$method');
    }
    final Object? result;
    try {
      result = await open.instance.invoke(method, arguments);
    } on UnsupportedError catch (error) {
      throw DeveloperCapabilityUnavailable(
        error.message?.toString() ?? error.toString(),
      );
    }
    return {
      'instanceId': instanceId,
      'code': open.code,
      'method': method,
      'result': result,
      'invokedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>> disposeInstance(String instanceId) async {
    final open = _instances.remove(instanceId);
    if (open == null) {
      return {'instanceId': instanceId, 'disposed': false};
    }
    await open.close();
    return {
      'instanceId': instanceId,
      'code': open.code,
      'disposed': true,
      'disposedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>> _runOne(
    CapabilityPlugin plugin,
    Duration timeout,
  ) async {
    final started = DateTime.now();
    if (!plugin.isAvailable) {
      return _result(
        plugin.descriptor,
        started,
        status: 'unavailable',
        message: '当前平台不可用',
      );
    }
    try {
      final detail = await plugin.test(timeout);
      return _result(
        plugin.descriptor,
        started,
        status: 'passed',
        message: '能力插件测试通过',
        detail: detail,
      );
    } on TimeoutException {
      return _result(
        plugin.descriptor,
        started,
        status: 'timeout',
        message: '在 ${timeout.inMilliseconds}ms 内未收到能力数据',
      );
    } on UnsupportedError catch (error) {
      return _result(
        plugin.descriptor,
        started,
        status: 'unavailable',
        message: error.message?.toString() ?? error.toString(),
      );
    } on Object catch (error) {
      return _result(
        plugin.descriptor,
        started,
        status: 'failed',
        message: error.toString(),
      );
    }
  }

  Future<void> dispose() async {
    final instances = _instances.values.toList(growable: false);
    _instances.clear();
    await Future.wait(instances.map((instance) => instance.close()));
    await registry.dispose();
  }

  static Map<String, Object?> _result(
    CapabilityDescriptor descriptor,
    DateTime started, {
    required String status,
    required String message,
    Map<String, Object?>? detail,
  }) => {
    'code': descriptor.code,
    'name': descriptor.name,
    'apiVersion': descriptor.apiVersion,
    'status': status,
    'message': message,
    'durationMs': DateTime.now().difference(started).inMilliseconds,
    ...?detail,
  };
}

class _DeveloperCapabilityTestInstance {
  const _DeveloperCapabilityTestInstance({
    required this.code,
    required this.descriptor,
    required this.instance,
    required this.events,
  });

  final String code;
  final CapabilityDescriptor descriptor;
  final CapabilityInstance instance;
  final StreamSubscription<CapabilityInstanceEvent> events;

  Future<void> close() async {
    await events.cancel();
    await instance.dispose();
  }
}

class DeveloperCapabilityUnavailable implements Exception {
  const DeveloperCapabilityUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
