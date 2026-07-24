import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../../models/user_profile.dart';

class UserProfileStore {
  const UserProfileStore({this.root});

  final Directory? root;

  Future<UserProfile> load(UserProfile fallback) async {
    try {
      final file = await _profileFile();
      if (!await file.exists()) return _persistGenerated(fallback);
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return _persistGenerated(fallback);
      final json = Map<String, Object?>.from(value);
      final nickname = (json['nickname'] as String?)?.trim() ?? '';
      final avatarLabel = (json['avatarLabel'] as String?)?.trim() ?? '';
      final userId = (json['userId'] as String?)?.trim() ?? '';
      if (nickname.isEmpty || avatarLabel.isEmpty || userId.isEmpty) {
        return _persistGenerated(fallback);
      }
      final restored = UserProfile(
        userId: userId,
        nickname: nickname,
        avatarLabel: avatarLabel,
      );
      return restored;
    } on Object {
      return _persistGenerated(fallback);
    }
  }

  static String generateUserId() {
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'u_$hex';
  }

  Future<UserProfile> _persistGenerated(UserProfile source) async {
    final generated = RegExp(r'^u_[a-f0-9]{32}$').hasMatch(source.userId)
        ? source
        : source.copyWith(userId: generateUserId());
    await save(generated);
    return generated;
  }

  Future<void> save(UserProfile profile) async {
    final file = await _profileFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'userId': profile.userId,
        'nickname': profile.nickname,
        'avatarLabel': profile.avatarLabel,
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<File> _profileFile() async {
    final root = this.root ?? await getApplicationSupportDirectory();
    return File(
      '${root.path}${Platform.pathSeparator}playmesh-library'
      '${Platform.pathSeparator}profile.json',
    );
  }
}
