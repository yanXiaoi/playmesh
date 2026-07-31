import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_registry.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';

void main() {
  test('能力测试实例按定义创建、调用、转发事件并释放', () async {
    final plugin = _FakeCapabilityPlugin();
    final emitted = <Map<String, Object?>>[];
    final service = DeveloperCapabilityTestService(
      registry: CapabilityRegistry([
        plugin,
      ], platform: CapabilityPlatform.ANDROID),
      emitEvent: emitted.add,
    );

    final descriptions = await service.describe();
    expect(descriptions, hasLength(1));
    expect(descriptions.single['code'], 'test.streaming');
    expect(
      (descriptions.single['methods'] as List).cast<Map<String, Object?>>().map(
        (method) => method['name'],
      ),
      containsAll(['start', 'stop']),
    );

    final created = await service.createInstance(
      code: 'test.streaming',
      options: {'fps': 24},
    );
    final instanceId = created['instanceId']! as String;
    expect(plugin.createdOptions, {'fps': 24});

    final invoked = await service.invokeInstance(
      instanceId: instanceId,
      method: 'start',
      arguments: {'sampleCount': 3},
    );
    expect(invoked['result'], {
      'method': 'start',
      'arguments': {'sampleCount': 3},
    });
    expect(
      emitted,
      contains(
        allOf(
          containsPair('type', 'capability.test.event'),
          containsPair('instanceId', instanceId),
          containsPair('code', 'test.streaming'),
          containsPair('event', 'reading'),
          containsPair('data', {'sample': 1}),
        ),
      ),
    );

    await expectLater(
      service.invokeInstance(
        instanceId: instanceId,
        method: 'undeclared',
        arguments: const {},
      ),
      throwsFormatException,
    );

    expect(
      await service.disposeInstance(instanceId),
      containsPair('disposed', true),
    );
    expect(plugin.instance?.disposed, isTrue);
    expect(
      await service.disposeInstance(instanceId),
      containsPair('disposed', false),
    );

    await service.dispose();
    expect(plugin.disposed, isTrue);
  });

  test('不可用能力不能创建交互测试实例', () async {
    final service = DeveloperCapabilityTestService(
      registry: CapabilityRegistry([
        _FakeCapabilityPlugin(available: false),
      ], platform: CapabilityPlatform.ANDROID),
      emitEvent: (_) {},
    );

    await expectLater(
      service.createInstance(code: 'test.streaming', options: const {}),
      throwsA(isA<DeveloperCapabilityUnavailable>()),
    );

    await service.dispose();
  });

  test('能力自检使用默认参数创建实例并立即释放', () async {
    final plugin = _FakeCapabilityPlugin();
    final service = DeveloperCapabilityTestService(
      registry: CapabilityRegistry([
        plugin,
      ], platform: CapabilityPlatform.ANDROID),
      emitEvent: (_) {},
    );

    final results = await service.run(codes: const ['test.streaming']);

    expect(results.single, containsPair('status', 'passed'));
    expect(results.single, containsPair('created', true));
    expect(results.single, containsPair('disposed', true));
    expect(plugin.createdOptions, isEmpty);
    expect(plugin.instance?.disposed, isTrue);
    await service.dispose();
  });

  test('能力实例创建失败时自检直接失败', () async {
    final plugin = _FakeCapabilityPlugin(
      createError: StateError('native create failed'),
    );
    final service = DeveloperCapabilityTestService(
      registry: CapabilityRegistry([
        plugin,
      ], platform: CapabilityPlatform.ANDROID),
      emitEvent: (_) {},
    );

    final results = await service.run(codes: const ['test.streaming']);

    expect(results.single, containsPair('status', 'failed'));
    expect(results.single['message'], contains('native create failed'));
    expect(plugin.instance, isNull);
    await service.dispose();
  });
}

class _FakeCapabilityPlugin implements CapabilityPlugin {
  _FakeCapabilityPlugin({this.available = true, this.createError});

  final bool available;
  final Object? createError;
  Map<String, Object?>? createdOptions;
  _FakeCapabilityInstance? instance;
  bool disposed = false;

  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    code: 'test.streaming',
    name: 'Streaming Test',
    description: 'Definition-driven test capability.',
    apiVersion: '1.0.0',
    supportedPlatforms: [CapabilityPlatform.ANDROID],
    optionsSchema: {
      'type': 'object',
      'properties': {
        'fps': {'type': 'integer', 'minimum': 1, 'maximum': 120, 'default': 30},
      },
    },
    methods: [
      CapabilityMethodDescriptor(
        name: 'start',
        description: 'Start the stream.',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            'sampleCount': {'type': 'integer', 'minimum': 1, 'default': 1},
          },
        },
        resultSchema: {'type': 'object'},
      ),
      CapabilityMethodDescriptor(name: 'stop', description: 'Stop the stream.'),
    ],
    events: [
      CapabilityEventDescriptor(
        name: 'reading',
        description: 'A streamed reading.',
        dataSchema: {'type': 'object'},
      ),
    ],
  );

  @override
  bool get isAvailable => available;

  @override
  Future<CapabilityInstance> create(Map<String, Object?> options) async {
    createdOptions = Map<String, Object?>.from(options);
    final error = createError;
    if (error != null) throw error;
    return instance = _FakeCapabilityInstance();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeCapabilityInstance implements CapabilityInstance {
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController<CapabilityInstanceEvent>.broadcast(sync: true);
  bool disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, Map<String, Object?> arguments) async {
    if (method == 'start') {
      _events.add(const CapabilityInstanceEvent('reading', {'sample': 1}));
    }
    return {'method': method, 'arguments': arguments};
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}
