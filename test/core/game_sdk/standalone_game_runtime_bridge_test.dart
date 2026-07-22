import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/game_sdk_bridge.dart';
import 'package:playmesh/core/game_sdk/standalone_game_runtime_bridge.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';

void main() {
  test('宿主将 Game SDK 回包作为 JSON 对象注入 WebView', () {
    expect(
      gameSdkReceiveScript('{"type":"sdk.bootstrap","requestId":"ready-1"}'),
      'window.playmesh && window.playmesh.__receive('
      '{"type":"sdk.bootstrap","requestId":"ready-1"});',
    );
  });

  test('单机 bridge 响应 sdk.ready 并提供本地存储', () async {
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
    await bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'storage.get',
        'requestId': 'get-1',
        'payload': {'bucket': 'progress', 'key': 'level'},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(messages.first['type'], 'sdk.bootstrap');
    expect(messages.first['requestId'], 'ready-1');
    expect(messages.first['session'], isNull);
    expect((messages.first['player']! as Map)['id'], 'u_test');
    expect(messages.last['type'], 'command.result');
    expect(messages.last['requestId'], 'get-1');
    expect(messages.last['result'], 3);
  });
}
