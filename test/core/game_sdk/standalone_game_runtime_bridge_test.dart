import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/game_sdk_bridge.dart';
import 'package:playmesh/core/game_sdk/standalone_game_runtime_bridge.dart';
import 'package:playmesh/core/storage/game_database_service.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';

void main() {
  test('宿主将 Game SDK 回包作为 JSON 对象注入 WebView', () {
    expect(
      gameSdkReceiveScript('{"type":"sdk.bootstrap","requestId":"ready-1"}'),
      'window[Symbol.for("playmesh.main.internal.v1")]?.receive('
      '{"type":"sdk.bootstrap","requestId":"ready-1"});',
    );
  });

  test('单机 bridge 响应 sdk.ready 且不再接受旧 WS 存储命令', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-solo-bridge-');
    addTearDown(() => root.delete(recursive: true));
    final storage = await GameStorageService.create(
      gameId: 'com.example.solo',
      libraryRoot: root,
    );
    final bridge = StandaloneGameRuntimeBridge.withStorage(
      gameId: 'com.example.solo',
      storage: storage,
      userId: 'u_test',
      nickname: '测试玩家',
    );
    addTearDown(bridge.close);
    final messages = <Map<String, Object?>>[];
    final subscription = bridge.outboundMessages.listen((raw) {
      messages.add(Map<String, Object?>.from(jsonDecode(raw) as Map));
    });
    addTearDown(subscription.cancel);

    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'sdk.ready',
        'requestId': 'ready-1',
        'payload': <String, Object?>{},
      }),
    );
    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'storage.set',
        'requestId': 'set-1',
        'payload': {'bucket': 'progress', 'key': 'level', 'value': 3},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(messages.first['type'], 'sdk.bootstrap');
    expect(messages.first['requestId'], 'ready-1');
    expect(messages.first['session'], isNull);
    expect((messages.first['player']! as Map)['id'], 'u_test');
    expect((messages.first['player']! as Map)['role'], 'authority_player');
    expect(messages.last['type'], 'command.error');
    expect(messages.last['requestId'], 'set-1');
    expect(messages.last['error'], contains('storage.set'));
    expect(await storage.getData('progress', 'level'), isNull);
  });

  test('Authority 数据库使用固定路径、占位符和独立事务连接', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-solo-db-');
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.database';
    final storage = await GameStorageService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    final database = await GameDatabaseService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    final bridge = StandaloneGameRuntimeBridge.withStorage(
      gameId: gameId,
      storage: storage,
      database: database,
      userId: 'u_test',
      nickname: '测试玩家',
    );
    addTearDown(bridge.close);
    final messages = <Map<String, Object?>>[];
    final subscription = bridge.outboundMessages.listen((raw) {
      messages.add(Map<String, Object?>.from(jsonDecode(raw) as Map));
    });
    addTearDown(subscription.cancel);

    Future<Map<String, Object?>> command(
      String name,
      String requestId,
      Map<String, Object?> payload,
    ) async {
      await bridge.handleJavaScriptMessage(
        jsonEncode({
          'command': name,
          'requestId': requestId,
          'payload': payload,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      return messages.singleWhere(
        (message) => message['requestId'] == requestId,
      );
    }

    expect((await command('db.open', 'open-1', const {}))['result'], {
      'file': '_game.db',
    });
    await command('db.update', 'create-1', {
      'sql':
          'CREATE TABLE items ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL'
          ') STRICT',
      'args': <Object?>[],
    });
    const boundValue = "entry'); DROP TABLE items; --";
    await command('db.insert', 'insert-1', {
      'sql': 'INSERT INTO items (name) VALUES (?)',
      'args': <Object?>[boundValue],
    });
    expect(
      (await command('db.select', 'select-1', {
        'sql': 'SELECT name FROM items WHERE id = ?',
        'args': <Object?>[1],
      }))['result'],
      [
        {'name': boundValue},
      ],
    );
    expect(
      (await command('db.select', 'select-named-1', {
        'sql': 'SELECT name FROM items WHERE id = :id',
        'args': <String, Object?>{'id': 1},
      }))['result'],
      [
        {'name': boundValue},
      ],
    );

    final begin = await command('db.transaction.begin', 'begin-1', const {});
    final transactionId =
        ((begin['result']! as Map)['transactionId']! as String);
    await command('db.transaction.insert', 'tx-insert-1', {
      'transactionId': transactionId,
      'sql': 'INSERT INTO items (name) VALUES (?)',
      'args': <Object?>['事务数据'],
    });
    expect(
      (await command('db.select', 'outside-1', {
        'sql': 'SELECT COUNT(*) AS count FROM items',
        'args': <Object?>[],
      }))['result'],
      [
        {'count': 1},
      ],
    );
    await command('db.transaction.commit', 'commit-1', {
      'transactionId': transactionId,
    });
    expect(
      (await command('db.ddl', 'ddl-1', const {}))['result'],
      contains(containsPair('sql', contains('CREATE TABLE items'))),
    );

    expect(
      await File(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
        '${Platform.pathSeparator}db${Platform.pathSeparator}_game.db',
      ).exists(),
      isTrue,
    );
  });

  test('restart 退出旧文档后同一 bridge 可重新打开数据库', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-solo-db-restart-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.database.restart';
    final storage = await GameStorageService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    final database = await GameDatabaseService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    final bridge = StandaloneGameRuntimeBridge.withStorage(
      gameId: gameId,
      storage: storage,
      database: database,
      userId: 'u_test',
      nickname: '测试玩家',
    );
    final messages = StreamIterator<String>(bridge.outboundMessages);
    addTearDown(() async {
      await messages.cancel();
      await bridge.close();
    });
    var sequence = 0;

    Future<Map<String, Object?>> command(
      String name, [
      Map<String, Object?> payload = const {},
    ]) async {
      final requestId = 'restart-${sequence++}';
      final next = messages.moveNext();
      await bridge.handleJavaScriptMessage(
        jsonEncode({
          'command': name,
          'requestId': requestId,
          'payload': payload,
        }),
      );
      expect(await next, isTrue);
      return Map<String, Object?>.from(jsonDecode(messages.current) as Map);
    }

    expect((await command('db.open'))['type'], 'command.result');
    await command('db.update', {
      'sql': 'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
      'args': <Object?>[],
    });
    final begin = await command('db.transaction.begin');
    final transactionId = (begin['result']! as Map)['transactionId']! as String;
    await command('db.transaction.insert', {
      'transactionId': transactionId,
      'sql': 'INSERT INTO items (id, name) VALUES (?, ?)',
      'args': <Object?>[1, '应回滚'],
    });

    final lifecycleEvent = messages.moveNext();
    final exit = bridge.notifyLifecycle('exit');
    expect(await lifecycleEvent, isTrue);
    final event = Map<String, Object?>.from(
      jsonDecode(messages.current) as Map,
    );
    expect(event['event'], 'exit');
    await command('lifecycle.complete', {
      'lifecycleRequestId': event['requestId'],
    });
    await exit;

    expect((await command('db.open'))['result'], {'file': '_game.db'});
    expect(
      (await command('db.select', {
        'sql': 'SELECT COUNT(*) AS count FROM items',
        'args': <Object?>[],
      }))['result'],
      [
        {'count': 0},
      ],
    );
    final oldTransaction = await command('db.transaction.commit', {
      'transactionId': transactionId,
    });
    expect(oldTransaction['type'], 'command.error');
    expect(oldTransaction['code'], 'db_transaction_closed');
  });
}
