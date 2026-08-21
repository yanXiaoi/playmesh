import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_game_presence.dart';

void main() {
  test('单机 presence 只声明主机昵称和单机语义', () {
    final presence = LanGamePresence.solo(hostNickname: '本地主机');

    expect(presence.hostNickname, '本地主机');
    expect(presence.isSolo, isTrue);
    expect(presence.playerCount, isNull);
    expect(presence.maxPlayers, isNull);
  });

  test('多人 presence 接受零在线到满员并按值去重', () {
    expect(maxLanGamePresencePlayers, 32);
    final first = LanGamePresence.multiplayer(
      hostNickname: '房主',
      playerCount: 0,
      maxPlayers: 4,
    );
    final same = LanGamePresence.multiplayer(
      hostNickname: '房主',
      playerCount: 0,
      maxPlayers: 4,
    );
    final full = LanGamePresence.multiplayer(
      hostNickname: '房主',
      playerCount: 4,
      maxPlayers: 4,
    );
    final protocolMaximum = LanGamePresence.multiplayer(
      hostNickname: '房主',
      playerCount: maxLanGamePresencePlayers,
      maxPlayers: maxLanGamePresencePlayers,
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(full));
    expect(protocolMaximum.maxPlayers, maxLanGamePresencePlayers);
  });

  test('昵称同时限制 32 个 Unicode scalar 和 128 UTF-8 字节', () {
    expect(
      LanGamePresence.solo(hostNickname: List.filled(32, '😀').join()),
      isA<LanGamePresence>(),
    );
    expect(
      () => LanGamePresence.solo(hostNickname: List.filled(33, 'a').join()),
      throwsFormatException,
    );
    expect(
      () => LanGamePresence.solo(hostNickname: ' 房主'),
      throwsFormatException,
    );
    expect(
      () => LanGamePresence.solo(hostNickname: '房主 '),
      throwsFormatException,
    );
    expect(() => LanGamePresence.solo(hostNickname: ''), throwsFormatException);
  });

  test('单机不能携带人数且多人计数必须满足严格边界', () {
    expect(
      () => LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: -1,
        maxPlayers: 4,
      ),
      throwsFormatException,
    );
    expect(
      () => LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: 5,
        maxPlayers: 4,
      ),
      throwsFormatException,
    );
    expect(
      () => LanGamePresence.multiplayer(
        hostNickname: '房主',
        playerCount: 1,
        maxPlayers: maxLanGamePresencePlayers + 1,
      ),
      throwsFormatException,
    );
  });
}
