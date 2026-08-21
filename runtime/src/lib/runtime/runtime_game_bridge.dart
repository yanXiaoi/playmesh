import 'dart:async';
import 'dart:convert';

import 'runtime_package.dart';
import 'runtime_nickname_coordinator.dart';
import 'runtime_session.dart';
import 'runtime_storage.dart';

final class RuntimeGameBridge {
  static const supportedCommandNames = <String>{
    'sdk.ready',
    'game.submitAction',
    'authority.result',
    'session.start',
    'session.reset',
    'session.finish',
    'player.setNickname',
    'performance.ping',
    'performance.pong',
    'lifecycle.complete',
  };

  RuntimeGameBridge({
    required this.game,
    required this.session,
    this.storage,
    this.onNicknameUpdate,
  }) {
    _sessionSubscription = session?.messages.listen(
      (message) => unawaited(
        _handleTransportMessage(message).catchError((Object error) {
          _send({'type': 'transport.error', 'error': error.toString()});
        }),
      ),
      onError: (Object error) =>
          _send({'type': 'transport.error', 'error': error.toString()}),
      onDone: () {
        if (!_detachedForRemote) _send({'type': 'transport.closed'});
      },
    );
  }

  final RuntimeGameManifest game;
  final RuntimeSessionConnection? session;
  final RuntimeStorage? storage;
  final Future<RuntimeNicknameUpdate> Function(String nickname)?
  onNicknameUpdate;
  final StreamController<String> _outbound = StreamController.broadcast();
  StreamSubscription<Map<String, Object?>>? _sessionSubscription;
  bool _detachedForRemote = false;
  final Map<String, Completer<void>> _lifecycleOperations = {};
  int _lifecycleSequence = 0;
  static const _maxBridgeJsonBytes = 4 * 1024 * 1024;

  Stream<String> get outboundMessages => _outbound.stream;

  Future<void> handle(String rawMessage) async {
    if (_detachedForRemote) return;
    String? requestId;
    try {
      if (utf8.encode(rawMessage).length > _maxBridgeJsonBytes) {
        throw const FormatException('SDK 命令超过 4 MiB');
      }
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) throw const FormatException('SDK 命令必须是对象');
      final command = Map<String, Object?>.from(decoded);
      final rawRequestId = command['requestId'];
      if (rawRequestId != null &&
          (rawRequestId is! String ||
              rawRequestId.isEmpty ||
              utf8.encode(rawRequestId).length > 256)) {
        throw const FormatException('requestId 无效');
      }
      requestId = rawRequestId as String?;
      final sdkVersion = command['sdkVersion'];
      if (sdkVersion is! String || sdkVersion != game.gameSdkVersion) {
        throw FormatException('Runtime 不支持 Game SDK $sdkVersion');
      }
      final name = command['command'];
      if (name is! String || name.isEmpty || name.length > 128) {
        throw const FormatException('SDK command 无效');
      }
      final rawPayload = command['payload'];
      if (rawPayload is! Map) throw const FormatException('payload 必须是对象');
      final payload = Map<String, Object?>.from(rawPayload);
      switch (name) {
        case 'sdk.ready':
          _send({
            'type': 'sdk.bootstrap',
            'requestId': requestId,
            'sdkVersion': sdkVersion,
            'gameInfo': {
              'id': game.id,
              'name': game.name,
              'tags': game.tags,
              'multiplayer': session != null,
              'displayMode': session == null ? 'solo' : game.displayMode,
              'requiredCapabilities': game.requiredCapabilities,
            },
            'player':
                session != null &&
                    session!.snapshot['displayMode'] ==
                        'single_screen_multiplayer'
                ? null
                : session?.currentPlayer,
            'isAuthority': session?.isAuthority ?? true,
            'session': session?.snapshot,
            if (session != null)
              'binaryTransport': {
                'url': session!.binaryWebSocketUri.toString(),
              },
          });
        case 'game.submitAction':
          _requireSession().submit('game.action', payload);
          _result(requestId);
        case 'authority.result':
          final targets = command['targetPlayerIds'];
          if (targets is! List || targets.any((value) => value is! String)) {
            throw const FormatException('targetPlayerIds 必须是字符串数组');
          }
          final current = _requireSession();
          if (!current.isAuthority) throw StateError('当前页面不是 Authority');
          current.submit(
            'authority.result',
            payload,
            targets: targets.cast<String>(),
          );
          _result(requestId);
        case 'session.start':
          _result(requestId, await _requireSession().start());
        case 'session.reset':
          _result(requestId, await _requireSession().reset());
        case 'session.finish':
          _result(requestId, await _requireSession().finish());
        case 'player.setNickname':
          _requireExactPayload(payload, const {'nickname'});
          final nickname = payload['nickname'];
          if (nickname is! String) {
            throw const FormatException('nickname 必须是字符串');
          }
          final current = _requireSession();
          if (current.snapshot['displayMode'] == 'single_screen_multiplayer') {
            throw const RuntimeNicknameUpdateException(
              'nickname_update_unavailable',
              '单屏多人公共屏幕不对应任何玩家，无法修改昵称',
            );
          }
          final update = onNicknameUpdate;
          if (update == null) {
            throw const RuntimeNicknameUpdateException(
              'nickname_update_unavailable',
              '当前 Runtime 不支持修改玩家昵称',
            );
          }
          _result(requestId, (await update(nickname)).player);
        case 'performance.ping':
          _requireSession().submit('session.ping', payload);
          _result(requestId);
        case 'performance.pong':
          final target = command['targetPlayerId'];
          if (target is! String || target.isEmpty) {
            throw const FormatException('targetPlayerId 无效');
          }
          _requireSession().submit(
            'authority.pong',
            payload,
            targets: [target],
          );
          _result(requestId);
        case 'lifecycle.complete':
          final lifecycleRequestId = payload['lifecycleRequestId'];
          if (lifecycleRequestId is! String || lifecycleRequestId.isEmpty) {
            throw const FormatException('lifecycleRequestId 无效');
          }
          final operation = _lifecycleOperations.remove(lifecycleRequestId);
          if (operation != null && !operation.isCompleted) {
            operation.complete();
          }
          _result(requestId);
        default:
          throw UnsupportedError('Runtime 尚未实现 SDK 命令: $name');
      }
    } on Object catch (error) {
      _send({
        'type': 'command.error',
        'requestId': requestId,
        'error': error.toString(),
        'code': 'runtime_command_failed',
      });
    }
  }

  Future<void> _handleTransportMessage(Map<String, Object?> message) async {
    final current = session;
    final runtimeStorage = storage;
    if (message['type'] == 'platform.avatar.write' &&
        current != null &&
        current.isAuthority &&
        runtimeStorage != null) {
      final payload = message['payload'];
      String? playerId;
      String? digest;
      try {
        if (payload is! Map) throw const FormatException('头像写入负载无效');
        final normalized = Map<String, Object?>.from(payload);
        playerId = _requiredBridgeString(normalized, 'playerId');
        digest = _requiredBridgeString(normalized, 'digest');
        final png = base64Decode(_requiredBridgeString(normalized, 'png'));
        await runtimeStorage.writeUserAvatar(
          playerId: playerId,
          pngBytes: png,
          sha256Digest: digest,
        );
        current.confirmAvatarWritten(playerId: playerId, sha256: digest);
      } on Object {
        if (playerId != null && digest != null) {
          current.rejectAvatarWrite(playerId: playerId, sha256: digest);
        }
      }
      return;
    }
    final snapshot = message['session'];
    if (current?.isAuthority == true &&
        snapshot is Map &&
        snapshot['state'] == 'stopped') {
      await runtimeStorage?.clearSystemAvatars();
    }
    _send({'type': 'transport.message', 'message': message});
  }

  RuntimeSessionConnection _requireSession() =>
      session ?? (throw StateError('单机模式没有 Go Core 会话'));

  void _result(String? requestId, [Object? value]) => _send({
    'type': 'command.result',
    'requestId': requestId,
    'result': value,
  });

  void _send(Map<String, Object?> message) {
    if (!_outbound.isClosed) _outbound.add(jsonEncode(message));
  }

  Future<void> notifyLifecycle(String event) async {
    if (_detachedForRemote || _outbound.isClosed) return;
    final requestId = 'lifecycle-${++_lifecycleSequence}';
    final operation = Completer<void>();
    _lifecycleOperations[requestId] = operation;
    _send({'type': 'lifecycle.event', 'event': event, 'requestId': requestId});
    try {
      await operation.future.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      _lifecycleOperations.remove(requestId);
    }
  }

  void restoreGameContentFocus() {
    if (_detachedForRemote || _outbound.isClosed) return;
    _send({'type': 'platform.ui.restoreGameFocus'});
  }

  Future<void> close() async {
    for (final operation in _lifecycleOperations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _lifecycleOperations.clear();
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    if (session?.isAuthority == true) await storage?.clearSystemAvatars();
    await session?.close();
    await _outbound.close();
  }

  Future<void> detachForRemote() async {
    if (_detachedForRemote) return;
    _detachedForRemote = true;
    for (final operation in _lifecycleOperations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _lifecycleOperations.clear();
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    await session?.close();
  }
}

String _requiredBridgeString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) throw FormatException('$key 无效');
  return value;
}

void _requireExactPayload(
  Map<String, Object?> payload,
  Set<String> expectedKeys,
) {
  if (payload.length != expectedKeys.length ||
      !payload.keys.every(expectedKeys.contains)) {
    throw const FormatException('SDK 命令参数无效');
  }
}
