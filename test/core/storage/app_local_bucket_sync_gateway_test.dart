import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/storage/app_local_bucket_store.dart';
import 'package:playmesh/core/storage/app_local_bucket_sync_gateway.dart';

void main() {
  test('App Bucket 同步回环通道读写当前设备逻辑 Bucket', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-app-sync-gateway-',
    );
    final store = AppLocalBucketStore(
      gameId: 'com.playmesh.sync-gateway',
      gameName: '同步网关游戏',
      libraryRoot: root,
    );
    final gateway = await AppLocalBucketSyncGateway.start(store);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await gateway.close();
      await root.delete(recursive: true);
    });

    const bucket = 'GDJS/存档/一';
    const key = AppLocalBucketStore.gdevelopStorageRootKey;
    final setEnvelope = {
      'protocolVersion': appLocalBucketSyncProtocolVersion,
      'requestId': 'app-storage-sync-test-0001',
      'operation': 'sync.set',
      'bucket': bucket,
      'key': key,
      'value': {'score': 18},
    };
    final setRequest = await client.postUrl(gateway.endpoint);
    setRequest.headers
      ..set('origin', 'http://127.0.0.1:43100')
      ..contentType = ContentType.text;
    setRequest.write(jsonEncode(setEnvelope));
    final setResponse = await setRequest.close();
    expect(setResponse.statusCode, HttpStatus.ok);
    expect(
      setResponse.headers.value(HttpHeaders.accessControlAllowOriginHeader),
      'http://127.0.0.1:43100',
    );
    final setBody = jsonDecode(await utf8.decodeStream(setResponse));
    expect(setBody['requestId'], 'app-storage-sync-test-0001');
    expect(setBody['result'], isNull);

    final getEnvelope = {
      'protocolVersion': appLocalBucketSyncProtocolVersion,
      'requestId': 'app-storage-sync-test-0002',
      'operation': 'sync.get',
      'bucket': bucket,
      'key': key,
    };
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(getEnvelope)))
        .replaceAll('=', '');
    final getRequest = await client.getUrl(
      gateway.endpoint.replace(queryParameters: {'payload': payload}),
    );
    getRequest.headers.set('origin', 'http://127.0.0.1:43100');
    final getResponse = await getRequest.close();
    expect(getResponse.statusCode, HttpStatus.ok);
    final getBody = jsonDecode(await utf8.decodeStream(getResponse));
    expect(getBody['result'], {'score': 18});
  });

  test('App Bucket 同步回环通道拒绝非本机网页来源', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-app-sync-origin-',
    );
    final gateway = await AppLocalBucketSyncGateway.start(
      AppLocalBucketStore(
        gameId: 'com.playmesh.sync-origin',
        gameName: '同步来源游戏',
        libraryRoot: root,
      ),
    );
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await gateway.close();
      await root.delete(recursive: true);
    });

    final request = await client.getUrl(gateway.endpoint);
    request.headers.set('origin', 'https://example.com');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.forbidden);
  });
}
