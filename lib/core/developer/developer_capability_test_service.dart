import 'dart:async';

import '../capabilities/capability_plugin.dart';
import '../capabilities/capability_registry.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/support/motion_sensor_source.dart';

/// 开发者工作区能力自检服务。
///
/// 清单、平台可用性和测试实现全部来自已注册能力插件。工作区始终展示当前
/// App 的完整平台注册表，不按某个项目的 capabilities.json 过滤。
class DeveloperCapabilityTestService {
  DeveloperCapabilityTestService({
    MotionSensorSource? motionSource,
    CapabilityRegistry? registry,
  }) : registry =
           registry ??
           createDefaultCapabilityRegistry(motionSource: motionSource);

  final CapabilityRegistry registry;

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

  Future<void> dispose() => registry.dispose();

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
