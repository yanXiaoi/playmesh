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

  Future<List<Uri>> shareLinks();

  Future<void> close();
}
