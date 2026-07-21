import 'dart:async';

import '../../models/game_capability_registry.dart';
import '../platform/app_sensor_service.dart';

typedef DeveloperCapabilityTestAdapter =
    Future<Map<String, Object?>> Function(Duration timeout);

/// 开发者工作区能力自检服务。
///
/// 能力元数据始终来自统一注册表；新增能力只需注册对应 adapter，工作区和 API
/// 就会自动出现该测试项，不需要再维护第二份能力列表。
class DeveloperCapabilityTestService {
  DeveloperCapabilityTestService({
    AppSensorSource? sensorSource,
    Map<String, DeveloperCapabilityTestAdapter> adapters = const {},
  }) : _sensorSource = sensorSource ?? const NativeAppSensorSource(),
       _customAdapters = Map.unmodifiable(adapters);

  final AppSensorSource _sensorSource;
  final Map<String, DeveloperCapabilityTestAdapter> _customAdapters;

  List<Map<String, Object?>> describe() => gameCapabilityDefinitions
      .map((definition) {
        final sensorType = _sensorType(definition.code);
        return {
          ...definition.toJson(),
          'testable':
              _customAdapters.containsKey(definition.code) ||
              sensorType != null,
          'platformAvailable':
              sensorType == null ||
              _sensorSource.availableTypes.contains(sensorType),
        };
      })
      .toList(growable: false);

  Future<List<Map<String, Object?>>> run({
    List<String>? codes,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final selected = codes == null || codes.isEmpty
        ? gameCapabilityDefinitions
        : codes
              .map((code) {
                final definition = gameCapabilityRegistry[code];
                if (definition == null) {
                  throw FormatException('未知能力 code：$code');
                }
                return definition;
              })
              .toList(growable: false);
    final results = <Map<String, Object?>>[];
    for (final definition in selected) {
      results.add(await _runOne(definition, timeout));
    }
    return results;
  }

  Future<Map<String, Object?>> _runOne(
    GameCapabilityDefinition definition,
    Duration timeout,
  ) async {
    final started = DateTime.now();
    final adapter =
        _customAdapters[definition.code] ?? _sensorAdapter(definition.code);
    if (adapter == null) {
      return _result(
        definition,
        started,
        status: 'not_testable',
        message: '该能力尚未注册自检 adapter',
      );
    }
    try {
      final detail = await adapter(timeout);
      return _result(
        definition,
        started,
        status: 'passed',
        message: '能力数据输入正常',
        detail: detail,
      );
    } on TimeoutException {
      return _result(
        definition,
        started,
        status: 'timeout',
        message: '在 ${timeout.inMilliseconds}ms 内未收到能力数据',
      );
    } on UnsupportedError catch (error) {
      return _result(
        definition,
        started,
        status: 'unavailable',
        message: error.message?.toString() ?? error.toString(),
      );
    } on Object catch (error) {
      return _result(
        definition,
        started,
        status: 'failed',
        message: error.toString(),
      );
    }
  }

  DeveloperCapabilityTestAdapter? _sensorAdapter(String code) {
    final type = _sensorType(code);
    if (type == null) return null;
    return (timeout) async {
      if (!_sensorSource.availableTypes.contains(type)) {
        throw UnsupportedError('当前平台不支持 ${type.sdkValue}');
      }
      final sample = await _sensorSource
          .events(type, samplingPeriod: const Duration(milliseconds: 50))
          .first
          .timeout(timeout);
      return {'sample': sample.toJson()};
    };
  }

  static AppSensorType? _sensorType(String code) {
    for (final type in AppSensorType.values) {
      if (type.permission == code) return type;
    }
    return null;
  }

  static Map<String, Object?> _result(
    GameCapabilityDefinition definition,
    DateTime started, {
    required String status,
    required String message,
    Map<String, Object?>? detail,
  }) => {
    'code': definition.code,
    'name': definition.name,
    'status': status,
    'message': message,
    'durationMs': DateTime.now().difference(started).inMilliseconds,
    ...?detail,
  };
}
