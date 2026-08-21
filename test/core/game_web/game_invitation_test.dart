import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_web_gateway_contract.dart';

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
    expect(invitation.inviteToken, 'opaque-token');
    expect(
      invitation.requestUri,
      Uri.parse('http://192.168.1.9:16667$playmeshGameInvitationPath'),
    );
  });

  test('局域网邀请拒绝旧的入口查询鉴权协议和无效端口', () {
    for (final value in [
      'http://192.168.1.9:16667/index.html?'
          'channelId=channel_A1B2&token=share-token',
      'http://192.168.1.9:16667$playmeshGameInvitationPath?'
          'token=share-token',
      'http://192.168.1.9:16667$playmeshGameInvitationPath',
      'http://192.168.1.9:0$playmeshGameInvitationPath#inviteToken=token',
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
    expect(invitation.inviteToken, 'opaque-token');
    expect(
      invitation.requestUri,
      Uri.parse('https://relay.example/j/tunnel_A1B2'),
    );
  });

  test('拒绝会把 inviteToken 发送给中转服务器的查询参数格式', () {
    expect(
      () => GameInvitation.parse(
        'https://relay.example/j/tunnel_A1B2?inviteToken=opaque-token',
      ),
      throwsFormatException,
    );
  });

  test('诊断字符串不泄露 bearer 邀请凭据', () {
    final invitation = GameInvitation.parse(
      'http://192.168.1.9:16667$playmeshGameInvitationPath'
      '#inviteToken=never-log-this-token',
    );

    expect(invitation.toString(), isNot(contains('never-log-this-token')));
    expect(invitation.toString(), 'GameInvitation(lan)');
  });
}
