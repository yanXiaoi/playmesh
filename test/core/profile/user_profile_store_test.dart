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

    final generated = await store.load(fallback);
    expect(generated.nickname, fallback.nickname);
    expect(generated.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    await store.save(updated);
    final restored = await store.load(fallback);

    expect(restored.userId, updated.userId);
    expect(restored.nickname, updated.nickname);
    expect(restored.avatarLabel, updated.avatarLabel);
  });

  test('不同新安装生成并持久化不同的随机用户 ID', () async {
    final firstRoot = await Directory.systemTemp.createTemp(
      'playmesh-profile-first-',
    );
    final secondRoot = await Directory.systemTemp.createTemp(
      'playmesh-profile-second-',
    );
    addTearDown(() => firstRoot.delete(recursive: true));
    addTearDown(() => secondRoot.delete(recursive: true));
    const fallback = UserProfile(
      userId: 'unused',
      nickname: '本机玩家',
      avatarLabel: 'PM',
    );

    final firstStore = UserProfileStore(root: firstRoot);
    final secondStore = UserProfileStore(root: secondRoot);
    final first = await firstStore.load(fallback);
    final second = await secondStore.load(fallback);

    expect(first.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    expect(second.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    expect(second.userId, isNot(first.userId));
    expect((await firstStore.load(fallback)).userId, first.userId);
  });
}
