import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:playmesh_database/playmesh_database.dart';

import '../storage/game_database_service.dart';
import '../storage/game_storage_service.dart';
import 'game_sdk_bridge.dart';
import 'sdk_feature_registry.dart';

class StandaloneGameRuntimeBridge implements GameSdkBridge {
  StandaloneGameRuntimeBridge({
    required this.gameId,
    required this.userId,
    required this.nickname,
    this.gameName = 'Playmesh 游戏',
    this.tags = const <String>[],
    this.requiredCapabilities = const <String>[],
    this.databaseService,
  });

  factory StandaloneGameRuntimeBridge.withStorage({
    required String gameId,
    required String userId,
    required String nickname,
    required GameStorageService storage,
    GameDatabaseService? database,
    String gameName = 'Playmesh 游戏',
    List<String> tags = const <String>[],
    List<String> requiredCapabilities = const <String>[],
  }) {
    return StandaloneGameRuntimeBridge(
      gameId: gameId,
      userId: userId,
      nickname: nickname,
      gameName: gameName,
      tags: tags,
      requiredCapabilities: requiredCapabilities,
      databaseService: database,
    ).._storage = storage;
  }

  final String gameId;
  final String gameName;
  final List<String> tags;
  final List<String> requiredCapabilities;
  GameStorageService? _storage;
  Future<GameStorageService>? _storageOperation;
  GameDatabaseService? databaseService;
  Future<GameDatabaseService>? _databaseOperation;
  final String userId;
  final String nickname;
  final StreamController<String> _outbound = StreamController.broadcast();
  final Map<String, Completer<void>> _lifecycleOperations = {};
  int _lifecycleSequence = 0;

  @override
  Stream<String> get outboundMessages => _outbound.stream;

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
      final name = command['command'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('command 必须是非空字符串');
      }
      final execution = await SdkFeatureRegistry.dispatchGame(
        GameSdkCommandContext(
          gameInfo: {
            'id': gameId,
            'name': gameName,
            'tags': tags,
            'multiplayer': false,
            'displayMode': 'solo',
            'requiredCapabilities': requiredCapabilities,
          },
          standalonePlayer: {
            'id': userId,
            'nickname': nickname,
            'avatar': null,
            'role': 'authority_player',
            'connected': true,
          },
          completeLifecycle: (lifecycleRequestId) {
            final operation = _lifecycleOperations.remove(lifecycleRequestId);
            if (operation == null || operation.isCompleted) return false;
            operation.complete();
            return true;
          },
          updateNickname: _rejectNicknameUpdate,
          ensureDatabase: _ensureDatabase,
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
    if (event == 'exit') {
      // exit 只结束当前 WebView 文档；restart 会继续复用这个 bridge。
      try {
        await databaseService?.database.rollbackAllTransactions();
      } on Object catch (error) {
        debugPrint('重置游戏数据库事务失败: $error');
      }
    }
  }

  @override
  void restoreGameContentFocus() {
    _send({'type': 'platform.ui.restoreGameFocus'});
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

  Future<PlaymeshDatabase> _ensureDatabase() async {
    final current = databaseService;
    if (current != null) return current.database;
    final created = await (_databaseOperation ??= GameDatabaseService.create(
      gameId: gameId,
    ));
    databaseService = created;
    return created.database;
  }

  @override
  Future<void> close() async {
    for (final operation in _lifecycleOperations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _lifecycleOperations.clear();
    await databaseService?.database.close();
    await _storage?.close();
    await _outbound.close();
  }

  Future<Map<String, Object?>> _rejectNicknameUpdate(String nickname) {
    throw const SdkCommandException(
      'nickname_managed_by_app',
      '当前 App 玩家昵称由平台资料管理',
    );
  }

  void _sendResult(String? requestId, Object? result) {
    _send({'type': 'command.result', 'requestId': requestId, 'result': result});
  }

  void _send(Map<String, Object?> message) {
    if (!_outbound.isClosed) _outbound.add(jsonEncode(message));
  }
}
