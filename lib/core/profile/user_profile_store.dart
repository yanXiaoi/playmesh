import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/user_profile.dart';

class UserProfileStore {
  const UserProfileStore({this.root});

  final Directory? root;

  Future<UserProfile> load(UserProfile fallback) async {
    try {
      final file = await _profileFile();
      if (!await file.exists()) return fallback;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return fallback;
      final json = Map<String, Object?>.from(value);
      final nickname = (json['nickname'] as String?)?.trim() ?? '';
      final avatarLabel = (json['avatarLabel'] as String?)?.trim() ?? '';
      final userId = (json['userId'] as String?)?.trim() ?? '';
      if (nickname.isEmpty || avatarLabel.isEmpty || userId.isEmpty) {
        return fallback;
      }
      return UserProfile(
        userId: userId,
        nickname: nickname,
        avatarLabel: avatarLabel,
      );
    } on Object {
      return fallback;
    }
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
