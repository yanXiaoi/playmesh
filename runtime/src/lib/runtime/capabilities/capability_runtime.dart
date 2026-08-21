import 'dart:async';

import 'capability_plugin.dart';
import 'capability_registry.dart';

typedef CapabilityEventSender =
    Future<void> Function(Map<String, Object?> message);

class CapabilityRuntime {
  CapabilityRuntime({
    required this.registry,
    required Iterable<String> declaredCapabilities,
  }) : declaredCapabilities = Set.unmodifiable(declaredCapabilities);

  final CapabilityRegistry registry;
  final Set<String> declaredCapabilities;
  final Map<String, _OpenCapability> _instances = {};
  int _sequence = 0;
  bool _confirmed = false;

  Iterable<String> get availableDeclaredCodes =>
      declaredCapabilities.where(registry.isAvailable);

  void confirm() => _confirmed = true;

  Future<Map<String, Object?>> create(
    Map<String, Object?> payload,
    CapabilityEventSender send,
  ) async {
    final code = _requiredString(payload, 'code');
    final plugin = registry.plugin(code);
    if (plugin == null) throw FormatException('未知能力插件：$code');
    if (!declaredCapabilities.contains(code)) {
      throw StateError('当前游戏未在 capabilities.json 声明 $code');
    }
    if (!_confirmed) throw StateError('请先完成本次游戏能力确认');
    if (!registry.isPluginAvailable(plugin)) {
      throw UnsupportedError('当前设备不支持 $code');
    }
    final options = _map(payload['options'], field: 'options');
    final instance = await plugin.create(options);
    final instanceId =
        'capability-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    final eventSubscription = instance.events.listen(
      (event) => unawaited(
        send({
          'type': 'app.capability.event',
          'instanceId': instanceId,
          'event': event.name,
          'data': event.data,
        }),
      ),
      onError: (Object error) => unawaited(
        send({
          'type': 'app.capability.error',
          'instanceId': instanceId,
          'error': error.toString(),
        }),
      ),
    );
    _instances[instanceId] = _OpenCapability(instance, eventSubscription);
    return {
      'instanceId': instanceId,
      'code': code,
      'apiVersion': plugin.descriptor.apiVersion,
    };
  }

  Future<Object?> invoke(Map<String, Object?> payload) {
    final instanceId = _requiredString(payload, 'instanceId');
    final open = _instances[instanceId];
    if (open == null) throw StateError('能力实例不存在或已释放：$instanceId');
    return open.instance.invoke(
      _requiredString(payload, 'method'),
      _map(payload['arguments'], field: 'arguments'),
    );
  }

  Future<void> disposeInstance(Map<String, Object?> payload) async {
    final instanceId = _requiredString(payload, 'instanceId');
    final open = _instances.remove(instanceId);
    if (open == null) return;
    await open.close();
  }

  Future<void> reset() async {
    _confirmed = false;
    final instances = _instances.values.toList(growable: false);
    _instances.clear();
    await Future.wait(instances.map((instance) => instance.close()));
  }
}

class _OpenCapability {
  const _OpenCapability(this.instance, this.events);

  final CapabilityInstance instance;
  final StreamSubscription<CapabilityInstanceEvent> events;

  Future<void> close() async {
    await events.cancel();
    await instance.dispose();
  }
}

String _requiredString(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! String || result.isEmpty) {
    throw FormatException('$field 必须是非空字符串');
  }
  return result;
}

Map<String, Object?> _map(Object? value, {required String field}) {
  if (value == null) return const {};
  if (value is! Map) throw FormatException('$field 必须是对象');
  return Map<String, Object?>.from(value);
}
