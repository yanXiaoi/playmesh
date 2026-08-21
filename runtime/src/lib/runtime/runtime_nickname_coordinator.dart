import 'runtime_session.dart';

typedef RuntimeNicknameReader = String Function();
typedef RuntimeNicknamePersister = Future<String> Function(String nickname);

final class RuntimeNicknameCoordinator {
  RuntimeNicknameCoordinator({
    required this.session,
    required this.readNickname,
    required this.persistNickname,
  });

  final RuntimeSessionConnection? session;
  final RuntimeNicknameReader readNickname;
  final RuntimeNicknamePersister persistNickname;
  Future<void> _updateTail = Future<void>.value();

  Future<RuntimeNicknameUpdate> update(String value) {
    final previous = _updateTail;
    final operation = () async {
      await previous;
      return _performUpdate(value);
    }();
    _updateTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<RuntimeNicknameUpdate> _performUpdate(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.runes.length > 32) {
      throw const RuntimeNicknameUpdateException(
        'invalid_argument',
        '昵称必须为 1 至 32 个字符',
      );
    }
    final connection = session;
    if (connection == null) {
      throw const RuntimeNicknameUpdateException(
        'nickname_update_unavailable',
        '当前游戏没有可更新昵称的多人会话',
      );
    }
    if (connection.snapshot['displayMode'] == 'single_screen_multiplayer') {
      throw const RuntimeNicknameUpdateException(
        'nickname_update_unavailable',
        '单屏多人公共屏幕不对应任何玩家，无法修改昵称',
      );
    }

    final expectedSessionId = _requiredId(connection.snapshot, 'id');
    final expectedPlayerId = _requiredId(connection.currentPlayer, 'id');
    final previousNickname = readNickname();
    final requestedNickname = await persistNickname(normalized);
    Object? lastError;

    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final player = await connection.updateNickname(requestedNickname);
        final update = _validatedUpdate(
          connection,
          player,
          expectedSessionId: expectedSessionId,
          expectedPlayerId: expectedPlayerId,
          expectedNickname: requestedNickname,
        );
        if (update != null) return update;
        lastError = const FormatException('昵称更新响应与当前会话不一致');
      } on RuntimeSessionRequestException catch (error) {
        if (error.isDefinitiveRejection) {
          await _restore(previousNickname);
          throw const RuntimeNicknameUpdateException(
            'nickname_update_failed',
            '昵称修改被房间拒绝',
          );
        }
        lastError = error;
      } on Object catch (error) {
        lastError = error;
      }
    }

    String? reconciledNickname;
    try {
      final refreshed = await connection.refreshSnapshot();
      if (refreshed['id'] == expectedSessionId) {
        final player = _findPlayer(refreshed, expectedPlayerId);
        final authoritativeNickname = player?['nickname'];
        if (authoritativeNickname is String &&
            authoritativeNickname.trim().isNotEmpty &&
            authoritativeNickname.runes.length <= 32) {
          if (authoritativeNickname == requestedNickname) {
            return RuntimeNicknameUpdate(session: refreshed, player: player!);
          }
          reconciledNickname = authoritativeNickname;
        }
      }
    } on Object {
      // 超时后无法判定 PATCH 是否已提交，不能盲目回滚本地意图。
    }
    if (reconciledNickname != null) {
      await persistNickname(reconciledNickname);
      throw const RuntimeNicknameUpdateException(
        'nickname_update_failed',
        '房间未接受该昵称，已恢复房间中的昵称',
      );
    }

    throw RuntimeNicknameUpdateException(
      'nickname_update_pending',
      '昵称已保存在本机，等待与房间重新同步',
      cause: lastError,
    );
  }

  Future<void> _restore(String nickname) async {
    try {
      await persistNickname(nickname);
    } on Object {
      // 保留 Core 的明确拒绝结果，不用本地回滚失败覆盖它。
    }
  }
}

final class RuntimeNicknameUpdate {
  const RuntimeNicknameUpdate({required this.session, required this.player});

  final Map<String, Object?> session;
  final Map<String, Object?> player;
}

final class RuntimeNicknameUpdateException implements Exception {
  const RuntimeNicknameUpdateException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

RuntimeNicknameUpdate? _validatedUpdate(
  RuntimeSessionConnection connection,
  Map<String, Object?> player, {
  required String expectedSessionId,
  required String expectedPlayerId,
  required String expectedNickname,
}) {
  final snapshot = connection.snapshot;
  if (snapshot['id'] != expectedSessionId ||
      player['id'] != expectedPlayerId ||
      player['nickname'] != expectedNickname) {
    return null;
  }
  final snapshotPlayer = _findPlayer(snapshot, expectedPlayerId);
  if (snapshotPlayer?['nickname'] != expectedNickname) return null;
  return RuntimeNicknameUpdate(session: snapshot, player: player);
}

Map<String, Object?>? _findPlayer(
  Map<String, Object?> snapshot,
  String playerId,
) {
  final players = snapshot['players'];
  if (players is! List) return null;
  for (final candidate in players) {
    if (candidate is Map && candidate['id'] == playerId) {
      return Map<String, Object?>.from(candidate);
    }
  }
  return null;
}

String _requiredId(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty || value.length > 128) {
    throw RuntimeNicknameUpdateException(
      'nickname_update_failed',
      '当前会话缺少有效的 $key',
    );
  }
  return value;
}
