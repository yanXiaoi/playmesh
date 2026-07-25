import 'dart:async';
import 'dart:convert';

import '../storage/game_storage_service.dart';
import 'game_sdk_bridge.dart';
import 'generated_sdk_versions.dart';

class StandaloneGameRuntimeBridge implements GameSdkBridge {
  StandaloneGameRuntimeBridge({
    required this.gameId,
    required this.userId,
    required this.nickname,
  });

  factory StandaloneGameRuntimeBridge.withStorage({
    required String gameId,
    required String userId,
    required String nickname,
    required GameStorageService storage,
  }) {
    return StandaloneGameRuntimeBridge(
      gameId: gameId,
      userId: userId,
      nickname: nickname,
    ).._storage = storage;
  }

  final String gameId;
  GameStorageService? _storage;
  Future<GameStorageService>? _storageOperation;
  final String userId;
  final String nickname;
  final StreamController<String> _outbound = StreamController.broadcast();
  final StreamController<double> _fpsValues = StreamController.broadcast();
  final StreamController<double?> _latencyValues = StreamController.broadcast();
  final Map<String, Completer<void>> _lifecycleOperations = {};
  int _lifecycleSequence = 0;

  @override
  Stream<String> get outboundMessages => _outbound.stream;

  @override
  Stream<double> get fpsValues => _fpsValues.stream;

  @override
  Stream<double?> get latencyValues => _latencyValues.stream;

  @override
  Future<void> handleJavaScriptMessage(String rawMessage) async {
    String? requestId;
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) throw const FormatException('SDK 命令必须是对象');
      final command = Map<String, Object?>.from(decoded);
      requestId = command['requestId'] as String?;
      final payload = command['payload'] is Map
          ? Map<String, Object?>.from(command['payload']! as Map)
          : const <String, Object?>{};
      switch (command['command']) {
        case 'sdk.ready':
          _send({
            'type': 'sdk.bootstrap',
            'requestId': requestId,
            'sdkVersion': generatedGameSdkVersion,
            'player': {'id': userId, 'nickname': nickname, 'connected': true},
            'isAuthority': true,
            'session': null,
          });
          return;
        case 'storage.get':
        case 'storage.set':
        case 'storage.remove':
        case 'storage.clear':
          _sendResult(
            requestId,
            await _executeStorageCommand(
              command['command']! as String,
              payload,
            ),
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
          throw FormatException('单机模式不支持 SDK 命令: ${command['command']}');
      }
    } on Object catch (error) {
      _send({
        'type': 'command.error',
        'requestId': requestId,
        'error': error.toString(),
      });
    }
  }

  Future<Object?> _executeStorageCommand(
    String command,
    Map<String, Object?> payload,
  ) async {
    final storage = await ensureStorage();
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

  @override
  void setPerformanceVisible(bool visible) {
    _send({'type': 'performance.visibility', 'visible': visible});
  }

  @override
  Future<GameStorageService> ensureStorage() {
    final current = _storage;
    if (current != null) return Future.value(current);
    return _storageOperation ??= GameStorageService.create(gameId: gameId).then(
      (created) {
        _storage = created;
        return created;
      },
    );
  }

  Future<void> persistStorage() async {
    await _storage?.flushAll();
  }

  @override
  Future<void> close() async {
    for (final operation in _lifecycleOperations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _lifecycleOperations.clear();
    await _storage?.close();
    await _fpsValues.close();
    await _latencyValues.close();
    await _outbound.close();
  }

  void _sendResult(String? requestId, Object? result) {
    _send({'type': 'command.result', 'requestId': requestId, 'result': result});
  }

  void _send(Map<String, Object?> message) {
    if (!_outbound.isClosed) _outbound.add(jsonEncode(message));
  }
}

String _requiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}
