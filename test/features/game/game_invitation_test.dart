import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/features/game/join_game_page.dart';

void main() {
  test('局域网邀请只携带 fragment 中的不透明加入凭据', () {
    final invitation = GameInvitation.parse(
      'http://192.168.1.9:16667$playmeshGameInvitationPath'
      '#$playmeshGameInvitationTokenParameter=opaque-token',
    );

    expect(invitation.endpoint, Uri.parse('http://192.168.1.9:16667'));
    expect(invitation.usesRelay, isFalse);
    expect(invitation.entryUri.path, playmeshGameInvitationPath);
    expect(invitation.entryUri.hasQuery, isFalse);
    expect(
      Uri.splitQueryString(
        invitation.entryUri.fragment,
      )[playmeshGameInvitationTokenParameter],
      'opaque-token',
    );
  });

  test('局域网邀请拒绝旧的入口查询鉴权协议', () {
    for (final value in [
      'http://192.168.1.9:16667/index.html?'
          'channelId=channel_A1B2&token=share-token',
      'http://192.168.1.9:16667$playmeshGameInvitationPath?'
          'token=share-token',
      'http://192.168.1.9:16667$playmeshGameInvitationPath',
    ]) {
      expect(
        () => GameInvitation.parse(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('局域网邀请拒绝重复或额外的 fragment 参数', () {
    for (final fragment in [
      'inviteToken=one&inviteToken=two',
      'inviteToken=one&channelId=legacy',
      'other=value',
    ]) {
      expect(
        () => GameInvitation.parse(
          'http://192.168.1.9:16667$playmeshGameInvitationPath#$fragment',
        ),
        throwsFormatException,
        reason: fragment,
      );
    }
  });

  test('公共中转邀请只保留隧道 ID 与 fragment inviteToken', () {
    final invitation = GameInvitation.parse(
      'https://relay.example/j/tunnel_A1B2#inviteToken=opaque-token',
    );

    expect(invitation.endpoint, Uri.parse('https://relay.example'));
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
