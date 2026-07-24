import 'dart:async';

import 'generated_sdk_versions.dart';
import 'dart:convert';

import 'game_sdk_bridge.dart';
import '../session/go_core_session_client.dart';
import '../storage/game_storage_service.dart';

class GameRuntimeBridge implements GameSdkBridge {
  GameRuntimeBridge(this.connection, {required this.storage}) {
    _sessionSubscription = connection.messages.listen(
      (message) => unawaited(_handleTransportMessage(message)),
      onError: (Object error) =>
          _send({'type': 'transport.error', 'error': error.toString()}),
      onDone: () => _send({'type': 'transport.closed'}),
    );
  }

  final GameSessionConnection connection;
  final GameStorageService storage;
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
      switch (command['command']) {
        case 'sdk.ready':
          _sendBootstrap(requestId);
          return;
        case 'game.submitAction':
          connection.submitAction(payload);
          _sendResult(requestId, null);
          return;
        case 'authority.result':
          final targets = command['targetPlayerIds'];
          if (targets is! List) {
            throw const FormatException('targetPlayerIds 必须是数组');
          }
          connection.submitAuthorityResult(
            targetPlayerIds: targets.cast<String>(),
            message: payload,
          );
          _sendResult(requestId, null);
          return;
        case 'session.start':
          final snapshot = await connection.start();
          _sendResult(requestId, snapshot.toJson());
          return;
        case 'session.finish':
          final snapshot = await connection.finish();
          _sendResult(requestId, snapshot.toJson());
          return;
        case 'storage.get':
        case 'storage.set':
        case 'storage.remove':
        case 'storage.clear':
          await _handleStorageCommand(
            command['command']! as String,
            requestId,
            payload,
          );
          return;
        case 'performance.fps':
          final fps = payload['fps'];
          if (fps is! num || !fps.isFinite || fps < 0) {
            throw const FormatException('fps 必须是非负有限数值');
          }
          if (!_fpsValues.isClosed) _fpsValues.add(fps.toDouble());
          _sendResult(requestId, null);
          return;
        case 'performance.ping':
          connection.submitLatencyProbe(payload);
          _sendResult(requestId, null);
          return;
        case 'performance.pong':
          final targetPlayerId = command['targetPlayerId'];
          if (targetPlayerId is! String || targetPlayerId.isEmpty) {
            throw const FormatException('targetPlayerId 必须是非空字符串');
          }
          connection.submitLatencyResult(
            targetPlayerId: targetPlayerId,
            probe: payload,
          );
          _sendResult(requestId, null);
          return;
        case 'performance.latency':
          final latency = payload['latencyMs'];
          if (latency != null &&
              (latency is! num || !latency.isFinite || latency < 0)) {
            throw const FormatException('latencyMs 必须为空或非负有限数值');
          }
          if (!_latencyValues.isClosed) {
            _latencyValues.add((latency as num?)?.toDouble());
          }
          _sendResult(requestId, null);
          return;
        case 'lifecycle.complete':
          final lifecycleRequestId = _requiredString(
            payload,
            'lifecycleRequestId',
          );
          _lifecycleOperations.remove(lifecycleRequestId)?.complete();
          _sendResult(requestId, null);
          return;
        default:
          throw FormatException('未知 SDK 命令: ${command['command']}');
      }
    } on Object catch (error) {
      _send({
        'type': 'command.error',
        'requestId': requestId,
        'error': error.toString(),
      });
    }
  }

  void _sendBootstrap(String? requestId) {
    _send({
      'type': 'sdk.bootstrap',
      'requestId': requestId,
      'sdkVersion': generatedGameSdkVersion,
      'player': connection.snapshot.displayMode == 'single_screen_multiplayer'
          ? null
          : connection.currentPlayer.toJson(),
      'isAuthority': connection.isAuthority,
      'session': connection.snapshot.toJson(),
      // 二进制连接配置只供 SDK 内部使用；SDK 接收后会从公开 bootstrap 中移除。
      'binaryTransport': {'url': connection.binaryEndpoint.toString()},
    });
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

  Future<void> _handleStorageCommand(
    String command,
    String? sdkRequestId,
    Map<String, Object?> payload,
  ) async {
    if (!connection.isAuthority) {
      final transportRequestId = 'storage-${++_storageSequence}';
      _remoteStorageRequests[transportRequestId] = sdkRequestId;
      connection.submitAction({
        '__playmeshStorageRequest': {
          'requestId': transportRequestId,
          'command': command,
          ...payload,
        },
      });
      return;
    }
    _sendResult(sdkRequestId, await _executeStorageCommand(command, payload));
  }

  Future<Object?> _executeStorageCommand(
    String command,
    Map<String, Object?> payload,
  ) async {
    final bucket = _requiredString(payload, 'bucket');
    switch (command) {
      case 'storage.get':
        return storage.getData(bucket, _requiredString(payload, 'key'));
      case 'storage.set':
        await storage.setData(
          bucket,
          _requiredString(payload, 'key'),
          payload['value'],
        );
        return null;
      case 'storage.remove':
        await storage.removeData(bucket, _requiredString(payload, 'key'));
        return null;
      case 'storage.clear':
        await storage.clearData(bucket);
        return null;
      default:
        throw FormatException('未知存储命令: $command');
    }
  }

  Future<void> _handleTransportMessage(Map<String, Object?> message) async {
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

  Future<void> _handleRemoteStorageRequest(
    Map<String, Object?> message,
    Map<String, Object?> request,
  ) async {
    final senderPlayerId = _requiredString(message, 'senderPlayerId');
    final requestId = _requiredString(request, 'requestId');
    try {
      final result = await _executeStorageCommand(
        _requiredString(request, 'command'),
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
    final requestId = _requiredString(response, 'requestId');
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
    await storage.close();
    await _sessionSubscription.cancel();
    await connection.close();
    await _fpsValues.close();
    await _latencyValues.close();
    await _outbound.close();
  }
}

String _requiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}
