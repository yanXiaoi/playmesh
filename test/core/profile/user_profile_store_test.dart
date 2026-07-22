import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/profile/user_profile_store.dart';
import 'package:playmesh/models/user_profile.dart';

void main() {
  test('用户资料保存后可以从本机目录恢复', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-profile-');
    addTearDown(() => root.delete(recursive: true));
    final store = UserProfileStore(root: root);
    const fallback = UserProfile(
      userId: 'u-local',
      nickname: '本机玩家',
      avatarLabel: 'PM',
    );
    const updated = UserProfile(
      userId: 'u-local',
      nickname: '新玩家',
      avatarLabel: 'NP',
    );

    expect((await store.load(fallback)).nickname, fallback.nickname);
    await store.save(updated);
    final restored = await store.load(fallback);

    expect(restored.userId, updated.userId);
    expect(restored.nickname, updated.nickname);
    expect(restored.avatarLabel, updated.avatarLabel);
  });
}
