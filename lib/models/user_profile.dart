import 'dart:typed_data';

/// 与语言区域无关的初始值，仅在用户选择昵称前使用。
///
/// 昵称创建后属于用户/运行时数据，必须始终原样显示，不得作为本地化键处理。
const playmeshDefaultLocalNickname = 'Playmesh Player';

class UserProfile {
  const UserProfile({
    required this.userId,
    required this.nickname,
    this.avatarRelativePath,
    this.avatarSha256,
    this.avatarUpdatedAt,
    this.avatarBytes,
  });

  final String userId;
  final String nickname;
  final String? avatarRelativePath;
  final String? avatarSha256;
  final DateTime? avatarUpdatedAt;

  /// 当前本机头像的规范化 PNG。它只在内存中传递，不写入 profile.json。
  final Uint8List? avatarBytes;

  bool get hasCustomAvatar =>
      avatarRelativePath != null &&
      avatarSha256 != null &&
      avatarUpdatedAt != null;

  UserProfile copyWith({
    String? userId,
    String? nickname,
    Object? avatarRelativePath = _unset,
    Object? avatarSha256 = _unset,
    Object? avatarUpdatedAt = _unset,
    Object? avatarBytes = _unset,
  }) {
    return UserProfile(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      avatarRelativePath: identical(avatarRelativePath, _unset)
          ? this.avatarRelativePath
          : avatarRelativePath as String?,
      avatarSha256: identical(avatarSha256, _unset)
          ? this.avatarSha256
          : avatarSha256 as String?,
      avatarUpdatedAt: identical(avatarUpdatedAt, _unset)
          ? this.avatarUpdatedAt
          : avatarUpdatedAt as DateTime?,
      avatarBytes: identical(avatarBytes, _unset)
          ? this.avatarBytes
          : avatarBytes as Uint8List?,
    );
  }
}

const Object _unset = Object();
