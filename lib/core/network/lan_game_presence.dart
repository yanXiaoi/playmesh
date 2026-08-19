import 'dart:convert';

const maxLanGameHostNicknameCharacters = 32;
const maxLanGameHostNicknameUtf8Bytes = 128;

/// 与 Go Core 创建会话的硬上限保持一致，避免发现协议扩大不可信人数范围。
const maxLanGamePresencePlayers = 32;

/// 当前分享主机在局域网发现协议中的传输无关状态投影。
///
/// 单机分享只声明 [isSolo]，不把本机玩家伪装为 1/1 房间；多人分享的人数来自
/// Authority session 的在线成员快照。IP、端口、邀请凭据和平台句柄不属于该模型。
final class LanGamePresence {
  const LanGamePresence._({
    required this.hostNickname,
    required this.isSolo,
    required this.playerCount,
    required this.maxPlayers,
  });

  factory LanGamePresence.solo({required String hostNickname}) =>
      LanGamePresence._(
        hostNickname: hostNickname,
        isSolo: true,
        playerCount: null,
        maxPlayers: null,
      ).validated();

  factory LanGamePresence.multiplayer({
    required String hostNickname,
    required int playerCount,
    required int maxPlayers,
  }) => LanGamePresence._(
    hostNickname: hostNickname,
    isSolo: false,
    playerCount: playerCount,
    maxPlayers: maxPlayers,
  ).validated();

  final String hostNickname;
  final bool isSolo;
  final int? playerCount;
  final int? maxPlayers;

  LanGamePresence validated() {
    final nicknameBytes = utf8.encode(hostNickname);
    if (hostNickname.isEmpty ||
        hostNickname.trim() != hostNickname ||
        hostNickname.runes.length > maxLanGameHostNicknameCharacters ||
        nicknameBytes.length > maxLanGameHostNicknameUtf8Bytes) {
      throw const FormatException('局域网分享主机昵称无效');
    }
    if (isSolo) {
      if (playerCount != null || maxPlayers != null) {
        throw const FormatException('单机分享不能声明房间人数');
      }
      return this;
    }
    final current = playerCount;
    final maximum = maxPlayers;
    if (current == null ||
        maximum == null ||
        current < 0 ||
        maximum < 1 ||
        current > maximum ||
        maximum > maxLanGamePresencePlayers) {
      throw const FormatException('局域网分享房间人数无效');
    }
    return this;
  }

  @override
  bool operator ==(Object other) =>
      other is LanGamePresence &&
      other.hostNickname == hostNickname &&
      other.isSolo == isSolo &&
      other.playerCount == playerCount &&
      other.maxPlayers == maxPlayers;

  @override
  int get hashCode =>
      Object.hash(hostNickname, isSolo, playerCount, maxPlayers);
}
