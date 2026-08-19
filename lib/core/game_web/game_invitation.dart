import 'game_web_gateway_contract.dart';

class GameInvitation {
  const GameInvitation._({
    required this.endpoint,
    required this.entryUri,
    required this.inviteToken,
    required this.usesRelay,
  });

  final Uri endpoint;
  final Uri entryUri;
  final String inviteToken;
  final bool usesRelay;

  Uri get requestUri => Uri(
    scheme: entryUri.scheme,
    host: entryUri.host,
    port: entryUri.hasPort ? entryUri.port : null,
    path: entryUri.path,
  );

  static GameInvitation parse(String rawValue) {
    try {
      final uri = Uri.tryParse(rawValue.trim());
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
        throw const FormatException('请输入有效的 Playmesh 对局邀请链接');
      }
      final fragment = uri.fragment.isEmpty
          ? const <String, String>{}
          : parsePlaymeshInvitationFragment(uri.fragment);
      final inviteToken = fragment[playmeshGameInvitationTokenParameter];
      final usesRelay =
          uri.pathSegments.length == 2 && uri.pathSegments.first == 'j';
      if (usesRelay) {
        if (!_validInvitationId(uri.pathSegments.last) ||
            fragment.length != 1 ||
            inviteToken?.isNotEmpty != true ||
            uri.hasQuery) {
          throw const FormatException('公共中转邀请只能携带 inviteToken');
        }
      } else if (uri.scheme != 'http' ||
          uri.path != playmeshGameInvitationPath ||
          uri.hasQuery ||
          fragment.length != 1 ||
          inviteToken?.isNotEmpty != true) {
        throw const FormatException('局域网邀请必须使用受控加入入口');
      }
      return GameInvitation._(
        endpoint: Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ),
        entryUri: uri,
        inviteToken: inviteToken!,
        usesRelay: usesRelay,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('请输入有效的 Playmesh 对局邀请链接');
    }
  }

  @override
  String toString() =>
      usesRelay ? 'GameInvitation(relay)' : 'GameInvitation(lan)';
}

bool _validInvitationId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(value);
