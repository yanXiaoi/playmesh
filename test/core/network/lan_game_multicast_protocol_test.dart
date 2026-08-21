import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_game_multicast_protocol.dart';

void main() {
  test('announcement 与不携带凭据的 goodbye 严格往返', () {
    final announcement = _message(
      instanceId: _instanceA,
      revision: 7,
      payload: _payload('游戏 A'),
    );
    final decoded = LanGameMulticastMessage.decode(announcement.encode());

    expect(decoded.kind, LanGameMulticastMessageKind.announcement);
    expect(decoded.instanceId, _instanceA);
    expect(decoded.revision, 7);
    expect(decoded.gatewayPort, 4100);
    expect(decoded.payload, _payload('游戏 A'));
    expect(announcement.encode().length, lessThanOrEqualTo(1200));

    final goodbye = LanGameMulticastMessage(
      kind: LanGameMulticastMessageKind.goodbye,
      instanceId: _instanceA,
      revision: 7,
    );
    final goodbyeJson = jsonDecode(utf8.decode(goodbye.encode())) as Map;
    expect(goodbyeJson.keys, <String>[
      'magic',
      'version',
      'kind',
      'instance',
      'revision',
    ]);
    expect(goodbyeJson, isNot(contains('payload')));
    expect(goodbyeJson, isNot(contains('gatewayPort')));
  });

  test('严格拒绝超限、未知字段、错误类型、错误版本和畸形 UTF-8', () {
    final valid = jsonDecode(utf8.decode(_message().encode())) as Map;

    expect(
      () => LanGameMulticastMessage.decode(
        utf8.encode(jsonEncode(<Object?, Object?>{...valid, 'address': 'x'})),
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameMulticastMessage.decode(
        utf8.encode(jsonEncode(<Object?, Object?>{...valid, 'version': 2})),
      ),
      throwsFormatException,
    );
    final badPayload = Map<Object?, Object?>.of(
      valid['payload']! as Map<Object?, Object?>,
    )..['address'] = '192.168.1.9';
    expect(
      () => LanGameMulticastMessage.decode(
        utf8.encode(
          jsonEncode(<Object?, Object?>{...valid, 'payload': badPayload}),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameMulticastMessage.decode(
        utf8.encode(jsonEncode(<Object?, Object?>{...valid, 'revision': 1.0})),
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameMulticastMessage.decode(
        List<int>.filled(maxLanGameMulticastDatagramBytes + 1, 0),
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameMulticastMessage.decode(const <int>[0xff, 0xfe]),
      throwsFormatException,
    );
    expect(
      () => LanGameMulticastMessage(
        kind: LanGameMulticastMessageKind.announcement,
        instanceId: _instanceA,
        revision: 1,
        gatewayPort: 4100,
        payload: <String, String>{'key': 'x' * 1100},
      ).encode(),
      throwsFormatException,
    );
  });

  test('source IP 是唯一地址来源，link-local 接受而非单播来源拒绝', () {
    final cache = LanGameMulticastCache();
    final bytes = _message(payload: _payload('来源测试')).encode();

    final accepted = cache.accept(
      datagram: bytes,
      sourceAddress: '169.254.3.7',
      now: Duration.zero,
    );
    final resolved = accepted.single as LanGameMulticastCacheResolved;
    expect(resolved.sourceAddress, '169.254.3.7');
    expect(resolved.platformId, '$_instanceA\u0000169.254.3.7');
    expect(resolved.payload, _payload('来源测试'));

    for (final source in const <String>[
      '0.2.3.4',
      '127.0.0.1',
      '224.0.0.1',
      '240.0.0.1',
      '255.255.255.255',
      'not-an-ip',
    ]) {
      expect(
        cache.accept(
          datagram: _message(instanceId: _instanceB).encode(),
          sourceAddress: source,
          now: Duration.zero,
        ),
        isEmpty,
      );
    }
  });

  test('低 revision 与同 revision 冲突不刷新 TTL，合法心跳会刷新', () {
    final cache = LanGameMulticastCache(recordTtl: const Duration(seconds: 4));
    expect(
      cache.accept(
        datagram: _message(revision: 5).encode(),
        sourceAddress: _sourceA,
        now: Duration.zero,
      ),
      hasLength(1),
    );
    expect(
      cache.accept(
        datagram: _message(revision: 4).encode(),
        sourceAddress: _sourceA,
        now: const Duration(seconds: 2),
      ),
      isEmpty,
    );
    expect(
      cache.accept(
        datagram: _message(revision: 5, payload: _payload('冲突内容')).encode(),
        sourceAddress: _sourceA,
        now: const Duration(seconds: 3),
      ),
      isEmpty,
    );
    expect(cache.expire(const Duration(seconds: 4)), hasLength(1));

    cache.accept(
      datagram: _message(revision: 6).encode(),
      sourceAddress: _sourceA,
      now: const Duration(seconds: 5),
    );
    expect(
      cache.accept(
        datagram: _message(revision: 6).encode(),
        sourceAddress: _sourceA,
        now: const Duration(seconds: 8),
      ),
      isEmpty,
    );
    expect(cache.expire(const Duration(seconds: 11)), isEmpty);
    expect(cache.expire(const Duration(seconds: 12)), hasLength(1));
  });

  test('goodbye 立即 lost、阻止同 revision 乱序复活并允许更高 revision 重试', () {
    final cache = LanGameMulticastCache();
    cache.accept(
      datagram: _message(revision: 8).encode(),
      sourceAddress: _sourceA,
      now: Duration.zero,
    );

    final lost = cache.accept(
      datagram: LanGameMulticastMessage(
        kind: LanGameMulticastMessageKind.goodbye,
        instanceId: _instanceA,
        revision: 8,
      ).encode(),
      sourceAddress: _sourceA,
      now: const Duration(seconds: 1),
    );
    expect(lost.single, isA<LanGameMulticastCacheLost>());
    expect(
      cache.accept(
        datagram: _message(revision: 8).encode(),
        sourceAddress: _sourceA,
        now: const Duration(seconds: 2),
      ),
      isEmpty,
    );
    expect(
      cache
          .accept(
            datagram: _message(revision: 9).encode(),
            sourceAddress: _sourceA,
            now: const Duration(seconds: 2),
          )
          .single,
      isA<LanGameMulticastCacheResolved>(),
    );
    expect(
      LanGameMulticastCache().accept(
        datagram: LanGameMulticastMessage(
          kind: LanGameMulticastMessageKind.goodbye,
          instanceId: _instanceB,
          revision: 1,
        ).encode(),
        sourceAddress: _sourceA,
        now: Duration.zero,
      ),
      isEmpty,
      reason: '未知 goodbye 不能占缓存或驱逐合法记录',
    );
  });

  test('缓存按最近合法心跳 LRU 驱逐且先发 lost 再发 resolved', () {
    final cache = LanGameMulticastCache(maxRecords: 2);
    cache.accept(
      datagram: _message(instanceId: _instanceA).encode(),
      sourceAddress: _sourceA,
      now: Duration.zero,
    );
    cache.accept(
      datagram: _message(instanceId: _instanceB).encode(),
      sourceAddress: _sourceA,
      now: const Duration(seconds: 1),
    );
    cache.accept(
      datagram: _message(instanceId: _instanceA).encode(),
      sourceAddress: _sourceA,
      now: const Duration(seconds: 2),
    );
    final events = cache.accept(
      datagram: _message(instanceId: _instanceC).encode(),
      sourceAddress: _sourceA,
      now: const Duration(seconds: 3),
    );

    expect(cache.length, 2);
    expect(events, hasLength(2));
    expect(events.first, isA<LanGameMulticastCacheLost>());
    expect(events.first.platformId, '$_instanceB\u0000$_sourceA');
    expect(events.last, isA<LanGameMulticastCacheResolved>());
  });

  test('缓存构造拒绝无效 TTL 与容量', () {
    expect(
      () => LanGameMulticastCache(recordTtl: Duration.zero),
      throwsArgumentError,
    );
    expect(() => LanGameMulticastCache(maxRecords: 0), throwsRangeError);
    expect(
      () => LanGameMulticastCache(maxRecordsPerSource: 0),
      throwsRangeError,
    );
  });

  test('单个 source 的随机 instance 有独立硬上限且不影响其他 source', () {
    final cache = LanGameMulticastCache(maxRecords: 10, maxRecordsPerSource: 2);
    cache.accept(
      datagram: _message(instanceId: _instanceA).encode(),
      sourceAddress: _sourceA,
      now: Duration.zero,
    );
    cache.accept(
      datagram: _message(instanceId: _instanceB).encode(),
      sourceAddress: _sourceA,
      now: Duration.zero,
    );

    expect(
      cache.accept(
        datagram: _message(instanceId: _instanceC).encode(),
        sourceAddress: _sourceA,
        now: Duration.zero,
      ),
      isEmpty,
    );
    expect(cache.length, 2);
    expect(
      cache.accept(
        datagram: _message(instanceId: _instanceC).encode(),
        sourceAddress: '192.168.1.21',
        now: Duration.zero,
      ),
      hasLength(1),
    );
    expect(cache.length, 3);
  });
}

LanGameMulticastMessage _message({
  String instanceId = _instanceA,
  int revision = 1,
  Map<String, String>? payload,
}) => LanGameMulticastMessage(
  kind: LanGameMulticastMessageKind.announcement,
  instanceId: instanceId,
  revision: revision,
  gatewayPort: 4100,
  payload: payload ?? _payload('协议测试游戏'),
);

Map<String, String> _payload(String name) => <String, String>{
  'gameId': 'com.example.multicast',
  'name': name,
  'inviteToken': 'opaque-token',
  'hostNickname': '房主',
  'mode': 'solo',
};

const _instanceA = 'instance-multicast-0001';
const _instanceB = 'instance-multicast-0002';
const _instanceC = 'instance-multicast-0003';
const _sourceA = '192.168.1.20';
