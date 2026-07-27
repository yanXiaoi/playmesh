import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/profile/user_profile_store.dart';
import 'package:playmesh/models/user_profile.dart';

void main() {
  test('用户资料保存后可以从本机目录恢复', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-profile-');
    addTearDown(() => root.delete(recursive: true));
    final store = UserProfileStore(root: root);
    const fallback = UserProfile(userId: 'u-local', nickname: '本机玩家');
    const updated = UserProfile(userId: 'u-local', nickname: '新玩家');

    final generated = await store.load(fallback);
    expect(generated.nickname, fallback.nickname);
    expect(generated.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    await store.save(updated);
    final restored = await store.load(fallback);

    expect(restored.userId, updated.userId);
    expect(restored.nickname, updated.nickname);
    expect(restored.hasCustomAvatar, isFalse);
    final persisted =
        jsonDecode(
              await File(
                '${root.path}${Platform.pathSeparator}playmesh-library'
                '${Platform.pathSeparator}profile.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(persisted['formatVersion'], 2);
    expect(persisted.containsKey('avatarLabel'), isFalse);
    expect(persisted['avatar'], isNull);
  });

  test('profile v2 使用嵌套 avatar 对象保存规范化头像', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-profile-avatar-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = UserProfileStore(root: root);
    await store.save(
      UserProfile(
        userId: 'u_avatar',
        nickname: '头像玩家',
        avatarBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        avatarUpdatedAt: DateTime.utc(2026, 7, 26),
      ),
    );

    final profile = await store.load(
      const UserProfile(userId: 'unused', nickname: '默认玩家'),
    );
    final persisted =
        jsonDecode(
              await File(
                '${root.path}${Platform.pathSeparator}playmesh-library'
                '${Platform.pathSeparator}profile.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final avatar = Map<String, Object?>.from(persisted['avatar']! as Map);

    expect(profile.hasCustomAvatar, isTrue);
    expect(avatar['path'], 'profile/avatar.png');
    expect(avatar['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      avatar['updatedAt'],
      DateTime.utc(2026, 7, 26).millisecondsSinceEpoch,
    );
    expect(persisted.containsKey('avatarRelativePath'), isFalse);
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
    const fallback = UserProfile(userId: 'unused', nickname: '本机玩家');

    final firstStore = UserProfileStore(root: firstRoot);
    final secondStore = UserProfileStore(root: secondRoot);
    final first = await firstStore.load(fallback);
    final second = await secondStore.load(fallback);

    expect(first.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    expect(second.userId, matches(RegExp(r'^u_[a-f0-9]{32}$')));
    expect(second.userId, isNot(first.userId));
    expect((await firstStore.load(fallback)).userId, first.userId);
  });

  test('旧 avatarLabel 资料被隔离且不会被读取', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-profile-old-');
    addTearDown(() => root.delete(recursive: true));
    final library = Directory(
      '${root.path}${Platform.pathSeparator}playmesh-library',
    );
    await library.create(recursive: true);
    await File(
      '${library.path}${Platform.pathSeparator}profile.json',
    ).writeAsString(
      jsonEncode({'userId': 'u_old', 'nickname': '旧昵称', 'avatarLabel': '旧'}),
    );

    final profile = await UserProfileStore(
      root: root,
    ).load(const UserProfile(userId: 'unused', nickname: '默认玩家'));

    expect(profile.nickname, '默认玩家');
    expect(profile.userId, isNot('u_old'));
    expect(
      library.listSync().where(
        (entry) => entry.path.contains('profile.json.legacy-'),
      ),
      hasLength(1),
    );
  });

  test('临时扁平头像字段不作为 profile v2 兼容格式读取', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-profile-flat-avatar-',
    );
    addTearDown(() => root.delete(recursive: true));
    final library = Directory(
      '${root.path}${Platform.pathSeparator}playmesh-library',
    );
    await library.create(recursive: true);
    await File(
      '${library.path}${Platform.pathSeparator}profile.json',
    ).writeAsString(
      jsonEncode({
        'formatVersion': 2,
        'userId': 'u_old_flat',
        'nickname': '旧昵称',
        'avatarRelativePath': 'profile/avatar.png',
        'avatarSha256': List.filled(64, '0').join(),
        'avatarUpdatedAt': 1,
      }),
    );

    final profile = await UserProfileStore(
      root: root,
    ).load(const UserProfile(userId: 'unused', nickname: '默认玩家'));

    expect(profile.nickname, '默认玩家');
    expect(profile.userId, isNot('u_old_flat'));
    expect(
      library.listSync().where(
        (entry) => entry.path.contains('profile.json.legacy-'),
      ),
      hasLength(1),
    );
  });
}
