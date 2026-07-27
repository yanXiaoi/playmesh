import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../models/user_profile.dart';
import 'avatar_image.dart';

class UserProfileStore {
  const UserProfileStore({this.root});

  static const formatVersion = 2;

  final Directory? root;

  Future<UserProfile> load(UserProfile fallback) async {
    final file = await _profileFile();
    if (!await file.exists()) {
      return _persistGenerated(_withoutAvatar(fallback));
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) throw const FormatException('profile 根节点必须是对象');
      final json = Map<String, Object?>.from(value);
      if (json['formatVersion'] != formatVersion) {
        await _isolateLegacy(file);
        return _persistGenerated(_withoutAvatar(fallback));
      }
      final nickname = (json['nickname'] as String?)?.trim() ?? '';
      final userId = (json['userId'] as String?)?.trim() ?? '';
      if (nickname.isEmpty || userId.isEmpty) {
        throw const FormatException('profile v2 身份字段无效');
      }

      if (json.containsKey('avatarRelativePath') ||
          json.containsKey('avatarSha256') ||
          json.containsKey('avatarUpdatedAt')) {
        throw const FormatException('profile v2 不接受扁平头像字段');
      }
      final avatarRaw = json['avatar'];
      if (avatarRaw != null && avatarRaw is! Map) {
        throw const FormatException('profile v2 avatar 必须是对象或 null');
      }
      final avatar = avatarRaw is Map
          ? Map<String, Object?>.from(avatarRaw)
          : null;
      final avatarPath = avatar?['path'] as String?;
      final avatarSha256 = avatar?['sha256'] as String?;
      final avatarUpdatedAt = avatar?['updatedAt'];
      Uint8List? avatarBytes;
      DateTime? updatedAt;
      if (avatar != null) {
        try {
          if (avatarPath != AvatarImage.relativePath ||
              avatarSha256 == null ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(avatarSha256) ||
              avatarUpdatedAt is! int) {
            throw const FormatException('profile v2 头像元数据无效');
          }
          final avatarFile = await _avatarFile();
          if (!await avatarFile.exists()) {
            throw const FormatException('profile v2 头像文件缺失');
          }
          avatarBytes = await avatarFile.readAsBytes();
          final validated = await AvatarImage.validate(avatarBytes);
          if (validated.sha256 != avatarSha256) {
            throw const FormatException('profile v2 头像摘要不匹配');
          }
          updatedAt = DateTime.fromMillisecondsSinceEpoch(
            avatarUpdatedAt,
            isUtc: true,
          );
        } on Object {
          final recovered = UserProfile(userId: userId, nickname: nickname);
          await save(recovered);
          return recovered;
        }
      }
      return UserProfile(
        userId: userId,
        nickname: nickname,
        avatarRelativePath: avatarPath,
        avatarSha256: avatarSha256,
        avatarUpdatedAt: updatedAt,
        avatarBytes: avatarBytes,
      );
    } on Object {
      await _isolateLegacy(file);
      return _persistGenerated(_withoutAvatar(fallback));
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
    if (profile.nickname.trim().isEmpty) {
      throw const FormatException('用户昵称不能为空');
    }
    String? avatarPath = profile.avatarRelativePath;
    String? avatarSha256 = profile.avatarSha256;
    DateTime? avatarUpdatedAt = profile.avatarUpdatedAt;
    final selectedBytes = profile.avatarBytes;
    if (selectedBytes != null) {
      late final AvatarImageData normalized;
      try {
        normalized = await AvatarImage.validate(selectedBytes);
      } on FormatException {
        normalized = await AvatarImage.normalize(selectedBytes);
      }
      avatarPath = AvatarImage.relativePath;
      avatarSha256 = normalized.sha256;
      avatarUpdatedAt = profile.avatarUpdatedAt ?? DateTime.now().toUtc();
      await _writeAvatar(normalized.pngBytes);
    } else if (avatarPath == null) {
      avatarSha256 = null;
      avatarUpdatedAt = null;
      final avatar = await _avatarFile();
      if (await avatar.exists()) await avatar.delete();
    } else {
      final avatar = await _avatarFile();
      if (!await avatar.exists() ||
          avatarPath != AvatarImage.relativePath ||
          avatarSha256 == null ||
          avatarUpdatedAt == null) {
        throw const FormatException('头像元数据与本机文件不一致');
      }
      final validated = await AvatarImage.validate(await avatar.readAsBytes());
      if (validated.sha256 != avatarSha256) {
        throw const FormatException('头像摘要与本机文件不一致');
      }
    }

    final file = await _profileFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'formatVersion': formatVersion,
        'userId': profile.userId,
        'nickname': profile.nickname.trim(),
        'avatar': avatarPath == null
            ? null
            : {
                'path': avatarPath,
                'sha256': avatarSha256,
                'updatedAt': avatarUpdatedAt?.toUtc().millisecondsSinceEpoch,
              },
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _writeAvatar(Uint8List bytes) async {
    final file = await _avatarFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _isolateLegacy(File file) async {
    if (!await file.exists()) return;
    final isolated = File(
      '${file.path}.legacy-${DateTime.now().toUtc().millisecondsSinceEpoch}',
    );
    try {
      await file.rename(isolated.path);
    } on Object {
      // 隔离失败时不继续读取旧资料，下一次保存仍会用 v2 原子覆盖。
    }
    final avatar = await _avatarFile();
    if (await avatar.exists()) await avatar.delete();
  }

  UserProfile _withoutAvatar(UserProfile value) =>
      UserProfile(userId: value.userId, nickname: value.nickname);

  Future<Directory> _libraryRoot() async {
    final base = root ?? await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}playmesh-library');
  }

  Future<File> _profileFile() async {
    return File(
      '${(await _libraryRoot()).path}${Platform.pathSeparator}profile.json',
    );
  }

  Future<File> _avatarFile() async {
    return File(
      '${(await _libraryRoot()).path}${Platform.pathSeparator}profile'
      '${Platform.pathSeparator}avatar.png',
    );
  }
}
