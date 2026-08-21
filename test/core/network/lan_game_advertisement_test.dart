import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_game_advertisement.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';

void main() {
  test('单机与多人 payload 精确往返且 instance 只存在于 envelope', () {
    final solo = _advertisement(LanGamePresence.solo(hostNickname: '单机房主'));
    final multiplayer = _advertisement(
      LanGamePresence.multiplayer(
        hostNickname: '多人房主',
        playerCount: 3,
        maxPlayers: 8,
      ),
    );

    for (final advertisement in <LanGameAdvertisement>[solo, multiplayer]) {
      final payload = advertisement.toPayload();
      final decoded = LanGameAdvertisement.fromPayload(
        instanceId: advertisement.instanceId,
        payload: payload,
      );

      expect(payload, isNot(contains('instance')));
      expect(payload, isNot(contains('v')));
      expect(decoded.instanceId, advertisement.instanceId);
      expect(decoded.gameId, advertisement.gameId);
      expect(decoded.name, advertisement.name);
      expect(decoded.inviteToken, advertisement.inviteToken);
      expect(decoded.presence, advertisement.presence);
    }
    expect(solo.toPayload(), isNot(contains('playerCount')));
    expect(solo.toPayload(), isNot(contains('maxPlayers')));
    expect(multiplayer.toPayload()['playerCount'], '3');
    expect(multiplayer.toPayload()['maxPlayers'], '8');
  });

  test('payload 拒绝未知、缺失、模式与人数形状不一致', () {
    final payload = _advertisement(
      LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: 1,
        maxPlayers: 4,
      ),
    ).toPayload();

    expect(
      () => LanGameAdvertisement.fromPayload(
        instanceId: _instanceId,
        payload: <String, String>{...payload, 'address': '192.168.1.9'},
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameAdvertisement.fromPayload(
        instanceId: _instanceId,
        payload: Map<String, String>.of(payload)..remove('hostNickname'),
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameAdvertisement.fromPayload(
        instanceId: _instanceId,
        payload: <String, String>{...payload, 'mode': 'solo'},
      ),
      throwsFormatException,
    );
    expect(
      () => LanGameAdvertisement.fromPayload(
        instanceId: _instanceId,
        payload: <String, String>{...payload, 'playerCount': '17'},
      ),
      throwsFormatException,
    );
    for (final nonCanonical in const <String>['+1', '01', '-0', ' 1']) {
      expect(
        () => LanGameAdvertisement.fromPayload(
          instanceId: _instanceId,
          payload: <String, String>{...payload, 'playerCount': nonCanonical},
        ),
        throwsFormatException,
      );
    }
  });

  test('withPresence 只替换可变状态并保留稳定分享标识', () {
    final initial = _advertisement(
      LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: 1,
        maxPlayers: 4,
      ),
    );
    final updated = initial.withPresence(
      LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: 2,
        maxPlayers: 4,
      ),
    );

    expect(updated.instanceId, initial.instanceId);
    expect(updated.gameId, initial.gameId);
    expect(updated.name, initial.name);
    expect(updated.inviteToken, initial.inviteToken);
    expect(updated.presence.playerCount, 2);
  });
}

LanGameAdvertisement _advertisement(LanGamePresence presence) =>
    LanGameAdvertisement(
      instanceId: _instanceId,
      gameId: 'com.example.discovery',
      name: '发现测试游戏',
      inviteToken: 'opaque-invitation-token',
      presence: presence,
    ).validated();

const _instanceId = 'instance-discovery-0001';
