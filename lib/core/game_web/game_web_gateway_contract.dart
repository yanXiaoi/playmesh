const playmeshGameInvitationPath = '/playmesh/join';
const playmeshGameInvitationTokenParameter = 'inviteToken';

Map<String, String> parsePlaymeshInvitationFragment(String value) {
  final result = <String, String>{};
  for (final segment in value.split('&')) {
    final separator = segment.indexOf('=');
    final name = Uri.decodeQueryComponent(
      separator < 0 ? segment : segment.substring(0, separator),
    );
    final parameterValue = Uri.decodeQueryComponent(
      separator < 0 ? '' : segment.substring(separator + 1),
    );
    if (name.isEmpty || result.containsKey(name)) {
      throw const FormatException('游戏邀请 fragment 参数无效');
    }
    result[name] = parameterValue;
  }
  return result;
}

abstract interface class GameWebGateway {
  int get port;

  /// 当前分享通道的邀请凭据，只供统一分享协调器生成组播公告载荷。
  String get invitationToken;

  /// Relay 主机回环入口。它不属于可公开 LAN 地址，也不能进入分享快照。
  Uri get loopbackInvitationUri;

  Future<List<Uri>> shareLinks();

  Future<void> close();
}
