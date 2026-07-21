class UserProfile {
  const UserProfile({
    required this.userId,
    required this.nickname,
    required this.avatarLabel,
  });

  final String userId;
  final String nickname;
  final String avatarLabel;

  UserProfile copyWith({
    String? userId,
    String? nickname,
    String? avatarLabel,
  }) {
    return UserProfile(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      avatarLabel: avatarLabel ?? this.avatarLabel,
    );
  }
}
