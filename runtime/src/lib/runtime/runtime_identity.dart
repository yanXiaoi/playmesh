import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final class RuntimeIdentity {
  RuntimeIdentity._(this.userId, this._nickname, this._file);

  final String userId;
  final File _file;
  String _nickname;
  Future<void> _writeOperation = Future<void>.value();

  String get nickname => _nickname;

  static Future<RuntimeIdentity> load(Directory root) async {
    final file = File('${root.path}${Platform.pathSeparator}identity.json');
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final rawUserId = decoded['userId'];
          if (rawUserId is! String || !_validUserId(rawUserId)) {
            throw const FormatException('Runtime userId 无效');
          }
          final userId = rawUserId;
          final rawNickname = decoded['nickname'];
          final nickname = rawNickname is String
              ? _normalizeNickname(rawNickname)
              : null;
          if (nickname != null) {
            final identity = RuntimeIdentity._(userId, nickname, file);
            // 迁移旧版所有设备共用的固定默认昵称。
            if (identity.nickname == '本机玩家') {
              await identity.updateNickname(_randomDefaultNickname());
            }
            return identity;
          }
          if (rawNickname == null ||
              (rawNickname is String && rawNickname.trim().isEmpty)) {
            final identity = RuntimeIdentity._(
              userId,
              _randomDefaultNickname(),
              file,
            );
            await identity._persist();
            return identity;
          }
        }
      } on Object {
        // 无效身份会在下方替换。
      }
    }
    final random = Random.secure();
    final token = List<int>.generate(18, (_) => random.nextInt(256));
    final userId = 'u_${base64UrlEncode(token).replaceAll('=', '')}';
    final identity = RuntimeIdentity._(
      userId,
      _randomDefaultNickname(random),
      file,
    );
    await identity._persist();
    return identity;
  }

  Future<String> updateNickname(String value) async {
    final normalized = _normalizeNickname(value);
    if (normalized == null) {
      throw const FormatException('昵称必须为 1 至 32 个字符');
    }
    final previous = _writeOperation;
    final operation = () async {
      await previous;
      if (normalized == _nickname) return normalized;
      final oldNickname = _nickname;
      _nickname = normalized;
      try {
        await _persist();
      } on Object {
        _nickname = oldNickname;
        rethrow;
      }
      return normalized;
    }();
    _writeOperation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'userId': userId, 'nickname': _nickname}),
      flush: true,
    );
  }
}

String _randomDefaultNickname([Random? source]) {
  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  const digits = '0123456789';
  const alphabet = '$letters$digits';
  final random = source ?? Random.secure();
  final suffix = <String>[
    letters[random.nextInt(letters.length)],
    digits[random.nextInt(digits.length)],
    alphabet[random.nextInt(alphabet.length)],
    alphabet[random.nextInt(alphabet.length)],
  ];
  for (var index = suffix.length - 1; index > 0; index -= 1) {
    final target = random.nextInt(index + 1);
    final value = suffix[index];
    suffix[index] = suffix[target];
    suffix[target] = value;
  }
  return '玩家${suffix.join()}';
}

String? _normalizeNickname(String value) {
  final nickname = value.trim();
  if (nickname.isEmpty || nickname.runes.length > 32) return null;
  return nickname;
}

bool _validUserId(String value) =>
    RegExp(r'^u_[A-Za-z0-9_-]{16,128}$').hasMatch(value);
