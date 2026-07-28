import 'dart:async';

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'game_sdk_bridge.dart';
import 'sdk_feature_registry.dart';
import '../session/go_core_session_client.dart';
import '../storage/game_storage_service.dart';

class GameRuntimeBridge implements GameSdkBridge {
  GameRuntimeBridge(
    this.connection, {
    required this.storage,
    this.gameName = 'Playmesh 游戏',
    this.requiredCapabilities = const <String>[],
  }) {
    _sessionSubscription = connection.messages.listen(
      (message) => unawaited(_handleTransportMessage(message)),
      onError: (Object error) =>
          _send({'type': 'transport.error', 'error': error.toString()}),
      onDone: () => _send({'type': 'transport.closed'}),
    );
  }

  final GameSessionConnection connection;
  final GameStorageService storage;
  final String gameName;
  final List<String> requiredCapabilities;
  final StreamController<String> _outbound = StreamController.broadcast();
  final StreamController<double> _fpsValues = StreamController.broadcast();
  final StreamController<double?> _latencyValues = StreamController.broadcast();
  final Map<String, Completer<void>> _lifecycleOperations = {};
  final Map<String, String?> _remoteStorageRequests = {};
  int _lifecycleSequence = 0;
  int _storageSequence = 0;
  late final StreamSubscription<Map<String, Object?>> _sessionSubscription;

  @override
  Stream<String> get outboundMessages => _outbound.stream;
  @override
  Stream<double> get fpsValues => _fpsValues.stream;
  @override
  Stream<double?> get latencyValues => _latencyValues.stream;

  @override
  Future<GameStorageService> ensureStorage() => Future.value(storage);

  @override
  Future<void> handleJavaScriptMessage(String rawMessage) async {
    String? requestId;
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) {
        throw const FormatException('SDK 命令必须是对象');
      }
      final command = Map<String, Object?>.from(decoded);
      requestId = command['requestId'] as String?;
      final payload = command['payload'] is Map
          ? Map<String, Object?>.from(command['payload']! as Map)
          : const <String, Object?>{};
      final name = command['command'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('command 必须是非空字符串');
      }
      final execution = await SdkFeatureRegistry.dispatchGame(
        GameSdkCommandContext(
          connection: connection,
          gameInfo: {
            'id': connection.snapshot.gameId,
            'name': gameName,
            'multiplayer': true,
            'displayMode': connection.snapshot.displayMode,
            'requiredCapabilities': requiredCapabilities,
          },
          ensureStorage: ensureStorage,
          emitFps: (value) {
            if (!_fpsValues.isClosed) _fpsValues.add(value);
          },
          emitLatency: (value) {
            if (!_latencyValues.isClosed) _latencyValues.add(value);
          },
          completeLifecycle: (lifecycleRequestId) {
            final operation = _lifecycleOperations.remove(lifecycleRequestId);
            if (operation == null || operation.isCompleted) return false;
            operation.complete();
            return true;
          },
          routeRemoteStorage: _routeRemoteStorage,
        ),
        SdkCommandEnvelope(
          name: name,
          requestId: requestId,
          payload: payload,
          raw: command,
        ),
      );
      switch (execution) {
        case SdkCommandResult():
          _sendResult(requestId, execution.value);
        case SdkCommandMessage():
          _send(execution.message);
        case SdkCommandDeferred():
          break;
      }
    } on Object catch (error) {
      _send({
        'type': 'command.error',
        'requestId': requestId,
        'error': error.toString(),
        if (error is SdkCommandException) 'code': error.code,
      });
    }
  }

  void _sendResult(String? requestId, Object? result) {
    _send({'type': 'command.result', 'requestId': requestId, 'result': result});
  }

  void _sendError(String? requestId, Object error) {
    _send({
      'type': 'command.error',
      'requestId': requestId,
      'error': error.toString(),
    });
  }

  Future<void> _routeRemoteStorage(
    String command,
    String? sdkRequestId,
    Map<String, Object?> payload,
  ) async {
    final transportRequestId = 'storage-${++_storageSequence}';
    _remoteStorageRequests[transportRequestId] = sdkRequestId;
    connection.submitAction({
      '__playmeshStorageRequest': {
        'requestId': transportRequestId,
        'command': command,
        ...payload,
      },
    });
  }

  Future<void> _handleTransportMessage(Map<String, Object?> message) async {
    if (message['type'] == 'platform.avatar.write' && connection.isAuthority) {
      await _handleAvatarWrite(message);
      return;
    }
    final session = message['session'];
    if (connection.isAuthority &&
        session is Map &&
        session['state'] == 'stopped') {
      await storage.clearSystemAvatars();
    }
    final payload = message['payload'];
    if (payload is Map) {
      final normalized = Map<String, Object?>.from(payload);
      final storageRequest = normalized['__playmeshStorageRequest'];
      if (connection.isAuthority && storageRequest is Map) {
        await _handleRemoteStorageRequest(
          message,
          Map<String, Object?>.from(storageRequest),
        );
        return;
      }
      final storageResponse = normalized['__playmeshStorageResponse'];
      if (storageResponse is Map) {
        _handleRemoteStorageResponse(
          Map<String, Object?>.from(storageResponse),
        );
        return;
      }
    }
    _send({'type': 'transport.message', 'message': message});
  }

  Future<void> _handleAvatarWrite(Map<String, Object?> message) async {
    final payload = message['payload'];
    if (payload is! Map) {
      _logAuthorityAvatar(
        level: 'WARNING',
        event: 'session.avatar_write_invalid',
        message: 'Playmesh Authority 收到无效头像写入请求',
      );
      return;
    }
    final normalized = Map<String, Object?>.from(payload);
    String? playerId;
    String? digest;
    try {
      playerId = sdkRequiredString(normalized, 'playerId');
      digest = sdkRequiredString(normalized, 'digest');
      final bytes = Uint8List.fromList(
        base64Decode(sdkRequiredString(normalized, 'png')),
      );
      _logAuthorityAvatar(
        level: 'INFO',
        event: 'session.avatar_write_received',
        message: 'Playmesh Authority 收到玩家头像写入请求',
        playerId: playerId,
        sha256: digest,
        extra: {'avatarBytes': bytes.length},
      );
      await storage.writeUserAvatar(
        playerId: playerId,
        pngBytes: bytes,
        sha256: digest,
      );
      connection.confirmAvatarWritten(playerId: playerId, sha256: digest);
      _logAuthorityAvatar(
        level: 'INFO',
        event: 'session.avatar_write_succeeded',
        message: 'Playmesh Authority 已写入玩家头像并发送提交确认',
        playerId: playerId,
        sha256: digest,
      );
    } on Object catch (error) {
      if (playerId != null && digest != null) {
        connection.rejectAvatarWrite(playerId: playerId, sha256: digest);
      }
      _logAuthorityAvatar(
        level: 'WARNING',
        event: 'session.avatar_write_failed',
        message: 'Playmesh Authority 写入玩家头像失败，玩家仍可继续游戏',
        playerId: playerId,
        sha256: digest,
        extra: {'error': error.toString()},
      );
    }
  }

  void _logAuthorityAvatar({
    required String level,
    required String event,
    required String message,
    String? playerId,
    String? sha256,
    Map<String, Object?> extra = const {},
  }) {
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      'level': level,
      'component': 'game-runtime-bridge',
      'event': event,
      'message': message,
      'sessionId': connection.snapshot.id,
      'playerId': ?playerId,
      'avatarSha256': ?sha256,
      ...extra,
    };
    debugPrint('[$level] $message ${jsonEncode(record)}');
  }

  Future<void> _handleRemoteStorageRequest(
    Map<String, Object?> message,
    Map<String, Object?> request,
  ) async {
    final senderPlayerId = sdkRequiredString(message, 'senderPlayerId');
    final requestId = sdkRequiredString(request, 'requestId');
    try {
      final result = await executeSdkStorageCommand(
        storage,
        sdkRequiredString(request, 'command'),
        request,
      );
      connection.submitAuthorityResult(
        targetPlayerIds: [senderPlayerId],
        message: {
          '__playmeshStorageResponse': {
            'requestId': requestId,
            'result': result,
          },
        },
      );
    } on Object catch (error) {
      connection.submitAuthorityResult(
        targetPlayerIds: [senderPlayerId],
        message: {
          '__playmeshStorageResponse': {
            'requestId': requestId,
            'error': error.toString(),
          },
        },
      );
    }
  }

  void _handleRemoteStorageResponse(Map<String, Object?> response) {
    final requestId = sdkRequiredString(response, 'requestId');
    if (!_remoteStorageRequests.containsKey(requestId)) return;
    final sdkRequestId = _remoteStorageRequests.remove(requestId);
    if (response['error'] case final Object error) {
      _sendError(sdkRequestId, error);
    } else {
      _sendResult(sdkRequestId, response['result']);
    }
  }

  @override
  Future<void> notifyLifecycle(String event) async {
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

  void _send(Map<String, Object?> message) {
    if (!_outbound.isClosed) {
      _outbound.add(jsonEncode(message));
    }
  }

  @override
  void setPerformanceVisible(bool visible) {
    _send({'type': 'performance.visibility', 'visible': visible});
  }

  @override
  void restoreGameContentFocus() {
    _send({'type': 'platform.ui.restoreGameFocus'});
  }

  Future<void> persistStorage() => storage.flushAll();

  @override
  Future<void> close() async {
    for (final operation in _lifecycleOperations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _lifecycleOperations.clear();
    for (final requestId in _remoteStorageRequests.values) {
      _sendError(requestId, '主机存储连接已关闭');
    }
    _remoteStorageRequests.clear();
    if (connection.isAuthority) await storage.clearSystemAvatars();
    await storage.close();
    await _sessionSubscription.cancel();
    await connection.close();
    await _fpsValues.close();
    await _latencyValues.close();
    await _outbound.close();
  }
}
