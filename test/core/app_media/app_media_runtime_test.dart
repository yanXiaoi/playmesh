import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/app_media/app_media_adapter.dart';
import 'package:playmesh/core/app_media/app_media_runtime.dart';

void main() {
  test('注册器拒绝重复协议并按优先级选择生产者适配器', () async {
    final lower = _FakeMediaAdapter(protocol: 'lower', priority: 1);
    final higher = _FakeMediaAdapter(protocol: 'higher', priority: 10);
    final unavailable = _FakeMediaAdapter(
      protocol: 'unavailable',
      priority: 100,
      available: false,
    );
    final runtime = AppMediaRuntime([lower, higher, unavailable]);
    addTearDown(runtime.dispose);

    final source = await runtime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
      sourceOptions: const {'width': 1280},
      adapterOptions: const {'codec': 'H264'},
    );

    expect(source['type'], appMediaSourceType);
    expect(source['protocol'], 'higher');
    expect(source, isNot(contains('adapterSourceId')));
    expect(higher.lastSourceRequest?.sourceOptions, {'width': 1280});
    expect(higher.lastSourceRequest?.adapterOptions, {'codec': 'H264'});
    expect(lower.createCount, 0);
    expect(unavailable.createCount, 0);
    expect(runtime.availableProtocols, ['lower', 'higher']);
    expect(
      () => AppMediaRuntime([
        _FakeMediaAdapter(protocol: 'duplicate'),
        _FakeMediaAdapter(protocol: 'duplicate'),
      ]),
      throwsArgumentError,
    );
  });

  test('公共运行时原样转交 adapterOptions 并统一关闭私有会话', () async {
    final adapter = _FakeMediaAdapter();
    final runtime = AppMediaRuntime([adapter]);
    addTearDown(runtime.dispose);
    final source = await runtime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
    );

    final opened = await runtime.open({
      'source': source,
      'adapterOptions': {
        'offer': {'type': 'offer', 'sdp': 'v=0'},
      },
    });

    expect(opened['protocol'], 'fake');
    expect(opened['sessionId'], startsWith('media-session-'));
    expect(opened['answer'], {'type': 'answer', 'sdp': 'answer-sdp'});
    expect(adapter.lastOpenOptions, {
      'offer': {'type': 'offer', 'sdp': 'v=0'},
    });

    await runtime.close({'sessionId': opened['sessionId']});
    await runtime.close({'sessionId': opened['sessionId']});
    expect(adapter.closedSessionIds, ['adapter-session-1']);
  });

  test('释放源会先关闭全部消费者且拒绝伪造描述符', () async {
    final adapter = _FakeMediaAdapter();
    final runtime = AppMediaRuntime([adapter]);
    addTearDown(runtime.dispose);
    final source = await runtime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
    );
    await runtime.open({
      'source': source,
      'adapterOptions': const <String, Object?>{},
    });
    await runtime.open({
      'source': source,
      'adapterOptions': const <String, Object?>{},
    });

    await runtime.releaseSource(source);

    expect(adapter.closedSessionIds, [
      'adapter-session-1',
      'adapter-session-2',
    ]);
    expect(adapter.releasedSourceIds, ['adapter-source-1']);
    expect(
      () => runtime.open({
        'source': {...source, 'kind': 'audio'},
        'adapterOptions': const <String, Object?>{},
      }),
      throwsStateError,
    );
  });

  test('适配器元数据不能覆盖公共字段且嵌套描述符不会共享可变引用', () async {
    final invalidAdapter = _FakeMediaAdapter(
      metadata: const {'protocol': 'forged'},
    );
    final invalidRuntime = AppMediaRuntime([invalidAdapter]);
    addTearDown(invalidRuntime.dispose);

    await expectLater(
      invalidRuntime.createSource(producer: 'sensor.pose6d', kind: 'video'),
      throwsStateError,
    );
    expect(invalidAdapter.releasedSourceIds, ['adapter-source-1']);

    final formats = <Object?>['I420'];
    final adapter = _FakeMediaAdapter(metadata: {'formats': formats});
    final runtime = AppMediaRuntime([adapter]);
    addTearDown(runtime.dispose);
    final source = await runtime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
    );
    formats.add('H264');

    expect(source['formats'], ['I420']);
    (source['formats']! as List<Object?>).add('VP8');
    await expectLater(runtime.releaseSource(source), throwsStateError);
  });

  test('单个适配器清理失败不会阻止其余会话和媒体源释放', () async {
    final adapter = _FakeMediaAdapter(closeFailures: {'adapter-session-1'});
    final runtime = AppMediaRuntime([adapter]);
    addTearDown(() async {
      try {
        await runtime.dispose();
      } on Object {
        // 本测试只验证尽力清理顺序。
      }
    });
    final source = await runtime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
    );
    await runtime.open({
      'source': source,
      'adapterOptions': const <String, Object?>{},
    });
    await runtime.open({
      'source': source,
      'adapterOptions': const <String, Object?>{},
    });

    await expectLater(runtime.releaseSource(source), throwsStateError);
    expect(adapter.closedSessionIds, [
      'adapter-session-1',
      'adapter-session-2',
    ]);
    expect(adapter.releasedSourceIds, ['adapter-source-1']);
  });
}

final class _FakeMediaAdapter implements AppMediaAdapter {
  _FakeMediaAdapter({
    this.protocol = 'fake',
    this.priority = 1,
    this.available = true,
    this.metadata = const {'requestedFps': 30},
    this.closeFailures = const {},
  });

  @override
  final String protocol;

  @override
  final int priority;

  final bool available;
  final AppMediaJson metadata;
  final Set<String> closeFailures;
  int createCount = 0;
  int openCount = 0;
  AppMediaSourceRequest? lastSourceRequest;
  AppMediaJson? lastOpenOptions;
  final List<String> closedSessionIds = [];
  final List<String> releasedSourceIds = [];

  @override
  bool get isAvailable => available;

  @override
  bool supportsProducer(String producer, String kind) =>
      producer == 'sensor.pose6d' && kind == 'video';

  @override
  Future<AppMediaAdapterSource> createSource(
    AppMediaSourceRequest request,
  ) async {
    createCount += 1;
    lastSourceRequest = request;
    return AppMediaAdapterSource(
      id: 'adapter-source-$createCount',
      metadata: metadata,
    );
  }

  @override
  Future<AppMediaAdapterSession> open(
    AppMediaAdapterSource source,
    AppMediaJson adapterOptions,
  ) async {
    openCount += 1;
    lastOpenOptions = adapterOptions;
    return AppMediaAdapterSession(
      id: 'adapter-session-$openCount',
      answer: const {'type': 'answer', 'sdp': 'answer-sdp'},
    );
  }

  @override
  Future<void> close(String sessionId) async {
    closedSessionIds.add(sessionId);
    if (closeFailures.contains(sessionId)) {
      throw StateError('close failed: $sessionId');
    }
  }

  @override
  Future<void> releaseSource(String sourceId) async {
    releasedSourceIds.add(sourceId);
  }

  @override
  Future<AppMediaJson> test(Duration timeout) async => const {'status': 'ok'};

  @override
  Future<void> dispose() async {}
}
