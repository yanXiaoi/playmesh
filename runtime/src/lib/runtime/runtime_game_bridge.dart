import 'dart:async';
import 'dart:convert';

import 'package:playmesh_database/playmesh_database.dart';
import 'package:flutter/foundation.dart';

import 'runtime_nickname_coordinator.dart';
import 'runtime_package.dart';
import 'runtime_sdk_compatibility.dart';
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
    'webrtc.getSignalingEndpoint',
    'lifecycle.complete',
    'db.open',
    'db.select',
    'db.update',
    'db.delete',
    'db.insert',
    'db.ddl',
    'db.transaction.begin',
    'db.transaction.select',
    'db.transaction.update',
    'db.transaction.delete',
    'db.transaction.insert',
    'db.transaction.ddl',
    'db.transaction.commit',
    'db.transaction.rollback',
  };

  RuntimeGameBridge({
    required this.game,
    required this.session,
    this.storage,
    this.database,
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
  final PlaymeshDatabase? database;
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
      if (sdkVersion is! String ||
          !RuntimeSdkCompatibility.supportsGameRequest(sdkVersion)) {
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
        case 'webrtc.getSignalingEndpoint':
          _requireExactPayload(payload, const {'identifier'});
          final identifier = payload['identifier'];
          if (identifier is! String ||
              !RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$',
              ).hasMatch(identifier)) {
            throw const FormatException('identifier 必须是 1～128 位安全通道标识');
          }
          _result(
            requestId,
            await _requireSession().createWebRTCSignalingEndpoint(
              identifier,
              requestId: requestId,
            ),
          );
        case 'db.open':
        case 'db.select':
        case 'db.update':
        case 'db.delete':
        case 'db.insert':
        case 'db.ddl':
        case 'db.transaction.begin':
        case 'db.transaction.select':
        case 'db.transaction.update':
        case 'db.transaction.delete':
        case 'db.transaction.insert':
        case 'db.transaction.ddl':
        case 'db.transaction.commit':
        case 'db.transaction.rollback':
          _result(requestId, await _executeDatabaseCommand(name, payload));
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
        'code': error is PlaymeshDatabaseException
            ? error.code
            : 'runtime_command_failed',
      });
    }
  }

  static const _databaseStatementCommands = {
    'db.select': PlaymeshDatabaseOperation.select,
    'db.update': PlaymeshDatabaseOperation.update,
    'db.delete': PlaymeshDatabaseOperation.delete,
    'db.insert': PlaymeshDatabaseOperation.insert,
    'db.transaction.select': PlaymeshDatabaseOperation.select,
    'db.transaction.update': PlaymeshDatabaseOperation.update,
    'db.transaction.delete': PlaymeshDatabaseOperation.delete,
    'db.transaction.insert': PlaymeshDatabaseOperation.insert,
  };

  Future<Object?> _executeDatabaseCommand(
    String name,
    Map<String, Object?> payload,
  ) async {
    final current = session;
    if (current != null && !current.isAuthority) {
      throw const PlaymeshDatabaseException(
        'not_authority',
        '只有 Authority Client 可以访问 main.db',
      );
    }
    final target = database;
    if (target == null) {
      throw const PlaymeshDatabaseException(
        'db_unavailable',
        '当前 Runtime 没有提供数据库能力',
      );
    }
    if (name == 'db.open') {
      _requireExactPayload(payload, const {});
      await target.open();
      return const {'file': '_game.db'};
    }
    if (name == 'db.transaction.begin') {
      _requireExactPayload(payload, const {});
      return {'transactionId': await target.beginTransaction()};
    }
    if (name == 'db.transaction.commit' || name == 'db.transaction.rollback') {
      _requireExactPayload(payload, const {'transactionId'});
      final transactionId = _requiredBridgeString(payload, 'transactionId');
      if (name == 'db.transaction.commit') {
        await target.commitTransaction(transactionId);
      } else {
        await target.rollbackTransaction(transactionId);
      }
      return null;
    }
    if (name == 'db.ddl' || name == 'db.transaction.ddl') {
      final transactionCommand = name == 'db.transaction.ddl';
      final allowedKeys = transactionCommand
          ? const {'transactionId', 'name'}
          : const {'name'};
      if (!payload.keys.every(allowedKeys.contains) ||
          (transactionCommand && !payload.containsKey('transactionId'))) {
        throw const FormatException('DDL 请求参数无效');
      }
      final rawName = payload['name'];
      if (rawName != null && (rawName is! String || rawName.isEmpty)) {
        throw const FormatException('DDL 名称必须是非空字符串');
      }
      final ddlName = rawName as String?;
      return transactionCommand
          ? target.getTransactionDdl(
              _requiredBridgeString(payload, 'transactionId'),
              ddlName,
            )
          : target.getDdl(ddlName);
    }
    final operation = _databaseStatementCommands[name];
    if (operation == null) throw UnsupportedError('未知数据库命令: $name');
    final transactionCommand = name.startsWith('db.transaction.');
    _requireExactPayload(
      payload,
      transactionCommand
          ? const {'transactionId', 'sql', 'args'}
          : const {'sql', 'args'},
    );
    final sql = _requiredBridgeString(payload, 'sql');
    final rawArguments = payload['args'];
    if (rawArguments is! List &&
        (rawArguments is! Map ||
            !rawArguments.keys.every((key) => key is String))) {
      throw const FormatException('SQL args 必须是数组或命名参数对象');
    }
    final arguments = rawArguments is List
        ? List<Object?>.from(rawArguments)
        : Map<String, Object?>.from(rawArguments as Map);
    return transactionCommand
        ? target.executeTransaction(
            _requiredBridgeString(payload, 'transactionId'),
            operation,
            sql,
            arguments,
          )
        : target.execute(operation, sql, arguments);
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
    if (event == 'exit') {
      // exit 只结束当前 WebView 文档；restart 会继续复用这个 bridge。
      try {
        await database?.rollbackAllTransactions();
      } on Object catch (error) {
        debugPrint('重置游戏数据库事务失败: $error');
      }
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
    await database?.close();
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
    await database?.close();
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
