import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/join_game_page.dart';

void main() {
  test('局域网二维码只解析通道 ID 与当前分享 Token', () {
    final invitation = GameInvitation.parse(
      'http://192.168.1.9:16667/app/controller/index.html?'
      'channelId=channel_A1B2&token=share-token',
    );

    expect(invitation.endpoint, Uri.parse('http://192.168.1.9:16667'));
    expect(invitation.channelId, 'channel_A1B2');
    expect(invitation.usesRelay, isFalse);
    expect(
      invitation.entryUri,
      Uri.parse(
        'http://192.168.1.9:16667/app/controller/index.html?'
        'channelId=channel_A1B2&token=share-token',
      ),
    );
  });

  test('局域网 App 保留游戏声明的嵌套入口', () {
    final invitation = GameInvitation.parse(
      'http://192.168.1.9:16667/app/play/main.html?'
      'channelId=channel_A1B2&token=share-token',
    );

    expect(invitation.entryUri.path, '/app/play/main.html');
    expect(invitation.channelId, 'channel_A1B2');
    expect(invitation.usesRelay, isFalse);
  });

  test('拒绝携带运行时元数据的局域网二维码', () {
    expect(
      () => GameInvitation.parse(
        'http://192.168.1.9:16667/app/index.html?'
        'channelId=channel_A1B2&token=share-token&'
        'playmeshCorePort=54321',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('公共中转邀请只保留隧道 ID 与 fragment inviteToken', () {
    final invitation = GameInvitation.parse(
      'https://relay.example/j/tunnel_A1B2#inviteToken=opaque-token',
    );

    expect(invitation.endpoint, Uri.parse('https://relay.example'));
    expect(invitation.channelId, 'tunnel_A1B2');
    expect(invitation.usesRelay, isTrue);
    expect(
      Uri.splitQueryString(invitation.entryUri.fragment)['inviteToken'],
      'opaque-token',
    );
  });

  test('拒绝会把 inviteToken 发送给中转服务器的查询参数格式', () {
    expect(
      () => GameInvitation.parse(
        'https://relay.example/j/tunnel_A1B2?inviteToken=opaque-token',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
