import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/storage/game_bucket_http.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';

void main() {
  late Directory root;
  late GameStorageService storage;
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late Uri endpoint;
  var authorized = true;
  var scope = 'session-a';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playmesh-json-http-');
    storage = await GameStorageService.create(
      gameId: 'com.playmesh.http-storage',
      libraryRoot: root,
    );
    final ledger = StandardJsonBucketRequestLedger();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse(
      'http://127.0.0.1:${server.port}$playmeshStandardJsonBucketPath',
    );
    subscription = server.listen((request) async {
      try {
        final handled = await handleGameBucketRequest(
          request,
          storage: storage,
          authorizeStandardJson: (_) =>
              authorized ? StandardJsonBucketAuthorization(scope) : null,
          standardJsonLedger: ledger,
        );
        if (!handled) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } on Object {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } on Object {
          // The peer can abort while the bounded body reader is waiting.
        }
      }
    });
  });

  tearDown(() async {
    await subscription.cancel();
    await server.close(force: true);
    await storage.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('私有 JSON route fail closed 校验会话、摘要、game 和 bucket', () async {
    final valid = _restEnvelope(
      requestId: 'request-security-0001',
      operation: 'get',
      bucket: 'save',
      key: 'coins',
      revision: null,
    );

    authorized = false;
    expect((await _restGet(endpoint, valid)).statusCode, HttpStatus.forbidden);
    authorized = true;

    final missingDigest = await http.get(_restQueryUri(endpoint, valid));
    expect(missingDigest.statusCode, HttpStatus.badRequest);
    expect(_errorCode(missingDigest), 'storage_digest_invalid');

    final wrongDigest = await _restGet(endpoint, valid, digest: '0' * 64);
    expect(wrongDigest.statusCode, HttpStatus.badRequest);
    expect(_errorCode(wrongDigest), 'storage_digest_mismatch');

    final wrongGame = {...valid, 'gameId': 'com.playmesh.other'};
    final rejectedGame = await _restGet(endpoint, wrongGame);
    expect(rejectedGame.statusCode, HttpStatus.forbidden);
    expect(_errorCode(rejectedGame), 'storage_game_mismatch');

    final invalidBucket = {...valid, 'bucket': '../other'};
    final rejectedBucket = await _restGet(endpoint, invalidBucket);
    expect(rejectedBucket.statusCode, HttpStatus.badRequest);
    expect(_errorCode(rejectedBucket), 'storage_request_invalid');

    final unknownField = {...valid, 'unexpected': true};
    final rejectedField = await _restGet(endpoint, unknownField);
    expect(rejectedField.statusCode, HttpStatus.badRequest);
    expect(_errorCode(rejectedField), 'storage_request_invalid');

    final legacyBody = jsonEncode(valid);
    final legacyPost = await http.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'X-Playmesh-Content-Sha256': await _sha256(legacyBody),
      },
      body: legacyBody,
    );
    expect(legacyPost.statusCode, HttpStatus.methodNotAllowed);
    expect(legacyPost.headers[HttpHeaders.allowHeader], 'GET, PUT, DELETE');

    final queryWithExtra = _restQueryUri(endpoint, valid).replace(
      queryParameters: {
        ..._restQueryUri(endpoint, valid).queryParameters,
        'bucket': 'save',
      },
    );
    expect(
      (await http.get(
        queryWithExtra,
        headers: {
          'X-Playmesh-Content-Sha256': await _sha256(jsonEncode(valid)),
        },
      )).statusCode,
      HttpStatus.badRequest,
    );
  });

  test('同 requestId 仅重放同一 session/game/bucket/op/payload', () async {
    final initial = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-idempotent-get',
        operation: 'get',
        bucket: 'save',
        key: 'level',
        revision: null,
      ),
    );
    final initialRevision =
        ((jsonDecode(initial.body) as Map)['result'] as Map)['revision']
            as String;
    final set = _restEnvelope(
      requestId: 'request-idempotent-01',
      operation: 'set',
      bucket: 'save',
      key: 'level',
      value: 4,
      expectedRevision: initialRevision,
    );
    expect((await _restPut(endpoint, set)).statusCode, HttpStatus.ok);
    expect((await _restPut(endpoint, set)).statusCode, HttpStatus.ok);

    final changed = {...set, 'value': 5};
    final conflict = await _restPut(endpoint, changed);
    expect(conflict.statusCode, HttpStatus.conflict);
    expect(_errorCode(conflict), 'storage_idempotency_conflict');

    scope = 'session-b';
    final otherSession = await _restPut(endpoint, set);
    expect(otherSession.statusCode, HttpStatus.conflict);
    expect(_errorCode(otherSession), 'storage_idempotency_conflict');
    scope = 'session-a';

    final get = _restEnvelope(
      requestId: 'request-idempotent-02',
      operation: 'get',
      bucket: 'save',
      key: 'level',
      revision: null,
    );
    final response = await _restGet(endpoint, get);
    expect(response.statusCode, HttpStatus.ok);
    expect(((jsonDecode(response.body) as Map)['result'] as Map)['value'], 4);
  });

  test('async REST GET/PUT/DELETE 共用修订 CAS 且区分 remove/clear', () async {
    final initial = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-rest-get-0001',
        operation: 'get',
        bucket: 'rest_save',
        key: 'score',
        revision: null,
      ),
    );
    expect(initial.statusCode, HttpStatus.ok);
    final initialResult = (jsonDecode(initial.body) as Map)['result'] as Map;
    expect(initialResult['value'], isNull);
    final emptyRevision = initialResult['revision']! as String;

    final firstWrite = _restEnvelope(
      requestId: 'request-rest-put-0001',
      operation: 'set',
      bucket: 'rest_save',
      key: 'score',
      value: 8,
      expectedRevision: emptyRevision,
    );
    final firstResponse = await _restPut(endpoint, firstWrite);
    expect(firstResponse.statusCode, HttpStatus.ok);
    expect((await _restPut(endpoint, firstWrite)).statusCode, HttpStatus.ok);
    final firstRevision =
        ((jsonDecode(firstResponse.body) as Map)['result'] as Map)['revision']!
            as String;

    final staleWrite = _restEnvelope(
      requestId: 'request-rest-put-0002',
      operation: 'set',
      bucket: 'rest_save',
      key: 'other',
      value: 9,
      expectedRevision: emptyRevision,
    );
    final staleResponse = await _restPut(endpoint, staleWrite);
    expect(staleResponse.statusCode, HttpStatus.conflict);
    expect(_errorCode(staleResponse), 'storage_revision_conflict');

    final remove = await _restDelete(
      endpoint,
      _restEnvelope(
        requestId: 'request-rest-del-0001',
        operation: 'remove',
        bucket: 'rest_save',
        key: 'score',
        expectedRevision: firstRevision,
      ),
    );
    expect(remove.statusCode, HttpStatus.ok);
    final removeRevision =
        ((jsonDecode(remove.body) as Map)['result'] as Map)['revision']!
            as String;

    final writeAgain = await _restPut(
      endpoint,
      _restEnvelope(
        requestId: 'request-rest-put-0003',
        operation: 'set',
        bucket: 'rest_save',
        key: 'left',
        value: true,
        expectedRevision: removeRevision,
      ),
    );
    final writeAgainRevision =
        ((jsonDecode(writeAgain.body) as Map)['result'] as Map)['revision']!
            as String;
    final clear = await _restDelete(
      endpoint,
      _restEnvelope(
        requestId: 'request-rest-del-0002',
        operation: 'clear',
        bucket: 'rest_save',
        expectedRevision: writeAgainRevision,
      ),
    );
    expect(clear.statusCode, HttpStatus.ok);
    expect(await storage.getData('rest_save', 'left'), isNull);

    final wrongMethod = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-rest-wrong-01',
        operation: 'set',
        bucket: 'rest_save',
        key: 'score',
        value: 1,
        expectedRevision: emptyRevision,
      ),
    );
    expect(wrongMethod.statusCode, HttpStatus.methodNotAllowed);
  });

  test('REST 查询载荷区分非法编码与超限', () async {
    final invalid = await http.get(
      endpoint.replace(query: 'payload=%25'),
      headers: {'X-Playmesh-Content-Sha256': '0' * 64},
    );
    expect(invalid.statusCode, HttpStatus.badRequest);
    expect(_errorCode(invalid), 'storage_request_invalid');

    final oversized = await http.get(
      endpoint.replace(queryParameters: {'payload': 'A' * (16 * 1024 + 1)}),
      headers: {'X-Playmesh-Content-Sha256': '0' * 64},
    );
    expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);
    expect(_errorCode(oversized), 'storage_request_too_large');
  });

  test('HTTP/SDK 和宿主新实例共享未落盘的项目状态', () async {
    final other = await GameStorageService.create(
      gameId: 'com.playmesh.http-storage',
      libraryRoot: root,
    );
    addTearDown(other.close);

    final initial = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-shared-state-00',
        operation: 'get',
        bucket: 'save',
        key: 'fromHttp',
        revision: null,
      ),
    );
    final initialRevision =
        ((jsonDecode(initial.body) as Map)['result'] as Map)['revision']
            as String;
    final setFromHttp = _restEnvelope(
      requestId: 'request-shared-state-01',
      operation: 'set',
      bucket: 'save',
      key: 'fromHttp',
      value: 11,
      expectedRevision: initialRevision,
    );
    expect((await _restPut(endpoint, setFromHttp)).statusCode, HttpStatus.ok);
    expect(await other.getData('save', 'fromHttp'), 11);

    await other.setData('save', 'fromHost', 12);
    final getFromHttp = _restEnvelope(
      requestId: 'request-shared-state-02',
      operation: 'get',
      bucket: 'save',
      key: 'fromHost',
      revision: null,
    );
    final response = await _restGet(endpoint, getFromHttp);
    expect(response.statusCode, HttpStatus.ok);
    expect(((jsonDecode(response.body) as Map)['result'] as Map)['value'], 12);
  });

  test('sync GET/PUT 使用逻辑 JSON envelope 且不写入 binary upload 目录', () async {
    final bucket = '目录/存档.${'长' * 200}';
    final getEnvelope = _syncEnvelope(
      requestId: 'request-sync-get-0001',
      operation: 'sync.get',
      bucket: bucket,
      revision: null,
    );
    final initial = await _syncGet(endpoint, getEnvelope);
    expect(initial.statusCode, HttpStatus.ok);
    final initialResult = (jsonDecode(initial.body) as Map)['result'] as Map;
    expect(initialResult['value'], isNull);
    final initialRevision = initialResult['revision']! as String;
    expect(initialRevision, matches(RegExp(r'^[a-f0-9]{64}$')));

    final packageData = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.http-storage'
      '${Platform.pathSeparator}data',
    );
    expect(
      Directory(
        '${packageData.path}${Platform.pathSeparator}json',
      ).existsSync(),
      isFalse,
      reason: 'GET 只读内存/磁盘，不应创建 JSON 或 binary 文件',
    );

    final putEnvelope = _syncEnvelope(
      requestId: 'request-sync-put-0001',
      operation: 'sync.set',
      bucket: bucket,
      value: {'scene': 6, 'title': '你好'},
      expectedRevision: initialRevision,
    );
    final written = await _syncPut(endpoint, putEnvelope);
    expect(written.statusCode, HttpStatus.ok);
    expect((await _syncPut(endpoint, putEnvelope)).statusCode, HttpStatus.ok);

    final stale = _syncEnvelope(
      requestId: 'request-sync-put-0002',
      operation: 'sync.set',
      bucket: bucket,
      value: {'scene': 7},
      expectedRevision: initialRevision,
    );
    final conflict = await _syncPut(endpoint, stale);
    expect(conflict.statusCode, HttpStatus.conflict);
    expect(_errorCode(conflict), 'storage_revision_conflict');

    final loaded = await _syncGet(
      endpoint,
      _syncEnvelope(
        requestId: 'request-sync-get-0002',
        operation: 'sync.get',
        bucket: bucket,
        revision: initialRevision,
      ),
    );
    expect(((jsonDecode(loaded.body) as Map)['result'] as Map)['value'], {
      'scene': 6,
      'title': '你好',
    });

    await storage.flushAll();
    final logicalFiles = Directory(
      '${packageData.path}${Platform.pathSeparator}json'
      '${Platform.pathSeparator}logical',
    ).listSync().whereType<File>().toList();
    expect(logicalFiles, hasLength(1));
    final persisted =
        jsonDecode(await logicalFiles.single.readAsString()) as Map;
    expect(persisted['bucket'], bucket);
    expect(
      (persisted['values'] as Map)[GameStorageService.gdevelopStorageRootKey],
      {'scene': 6, 'title': '你好'},
    );
    expect(
      Directory(
        '${packageData.path}${Platform.pathSeparator}data',
      ).existsSync(),
      isFalse,
      reason: 'sync JSON 只复用 Bucket 网关，不复用 upload 文件目录',
    );

    final syncPost = await http.post(
      endpoint,
      headers: const {'X-Playmesh-Storage-Sync': '1'},
      body: jsonEncode(putEnvelope),
    );
    expect(syncPost.statusCode, HttpStatus.methodNotAllowed);
    final wrongBody = jsonEncode(putEnvelope);
    final wrongPut = await http.put(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'X-Playmesh-Content-Sha256': await _sha256(wrongBody),
      },
      body: wrongBody,
    );
    expect(wrongPut.statusCode, HttpStatus.methodNotAllowed);
  });

  test('10 MiB bucket 边界成功，增加一个字节原子拒绝', () async {
    const rootOverhead = 11; // {"blob":""}
    final acceptedValue =
        'x' * (GameStorageService.maxStandardJsonBytes - rootOverhead);
    final initial = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-boundary-get-01',
        operation: 'get',
        bucket: 'large',
        key: 'blob',
        revision: null,
      ),
    );
    final initialRevision =
        ((jsonDecode(initial.body) as Map)['result'] as Map)['revision']
            as String;
    final accepted = _restEnvelope(
      requestId: 'request-boundary-0001',
      operation: 'set',
      bucket: 'large',
      key: 'blob',
      value: acceptedValue,
      expectedRevision: initialRevision,
    );
    final acceptedResponse = await _restPut(endpoint, accepted);
    expect(acceptedResponse.statusCode, HttpStatus.ok);
    final acceptedRevision =
        ((jsonDecode(acceptedResponse.body) as Map)['result']
                as Map)['revision']
            as String;

    final rejected = _restEnvelope(
      requestId: 'request-boundary-0002',
      operation: 'set',
      bucket: 'large',
      key: 'blob',
      value: '$acceptedValue+',
      expectedRevision: acceptedRevision,
    );
    final rejectedResponse = await _restPut(endpoint, rejected);
    expect(rejectedResponse.statusCode, HttpStatus.requestEntityTooLarge);
    expect(_errorCode(rejectedResponse), 'standard_bucket_too_large');
    expect(
      (await storage.getData('large', 'blob') as String).length,
      acceptedValue.length,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('请求断流不会产生部分写入', () async {
    final initial = await _restGet(
      endpoint,
      _restEnvelope(
        requestId: 'request-aborted-get-01',
        operation: 'get',
        bucket: 'save',
        key: 'partial',
        revision: null,
      ),
    );
    final initialRevision =
        ((jsonDecode(initial.body) as Map)['result'] as Map)['revision']
            as String;
    final body = jsonEncode(
      _restEnvelope(
        requestId: 'request-aborted-0001',
        operation: 'set',
        bucket: 'save',
        key: 'partial',
        value: 'must-not-commit',
        expectedRevision: initialRevision,
      ),
    );
    final socket = await Socket.connect(endpoint.host, endpoint.port);
    socket.add(
      utf8.encode(
        'PUT ${endpoint.path} HTTP/1.1\r\n'
        'Host: ${endpoint.host}:${endpoint.port}\r\n'
        'Content-Type: application/json\r\n'
        'X-Playmesh-Content-Sha256: ${await _sha256(body)}\r\n'
        'Content-Length: ${utf8.encode(body).length + 20}\r\n'
        'Connection: close\r\n\r\n'
        '$body',
      ),
    );
    await socket.flush();
    socket.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await storage.getData('save', 'partial'), isNull);
  });

  test('逻辑名哈希文件带可校验 envelope，合法旧桶仍用原文件', () async {
    final logicalName = '目录/存档.${'长' * 200}';
    await storage.setLogicalData(
      logicalName,
      GameStorageService.gdevelopStorageRootKey,
      {'scene': 2},
    );
    await storage.setData('legacy_save', 'coins', 3);
    await storage.close();

    final jsonRoot = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.http-storage'
      '${Platform.pathSeparator}data${Platform.pathSeparator}json',
    );
    expect(
      File(
        '${jsonRoot.path}${Platform.pathSeparator}legacy_save.json',
      ).existsSync(),
      isTrue,
    );
    final mapped = Directory(
      '${jsonRoot.path}${Platform.pathSeparator}logical',
    ).listSync().whereType<File>().single;
    expect(
      mapped.uri.pathSegments.last,
      matches(RegExp(r'^sha256-[a-f0-9]{64}\.json$')),
    );
    final envelope = jsonDecode(await mapped.readAsString()) as Map;
    expect(envelope['format'], 'playmesh.logical-bucket.v1');
    expect(envelope['bucket'], logicalName);
    expect(envelope['bucketSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));

    storage = await GameStorageService.create(
      gameId: 'com.playmesh.http-storage',
      libraryRoot: root,
    );
    expect(
      await storage.getLogicalData(
        logicalName,
        GameStorageService.gdevelopStorageRootKey,
      ),
      {'scene': 2},
    );
  });
}

Map<String, Object?> _syncEnvelope({
  required String requestId,
  required String operation,
  required String bucket,
  Object? revision,
  Object? value,
  String? expectedRevision,
}) => {
  'protocolVersion': playmeshStandardJsonProtocolVersion,
  'requestId': requestId,
  'gameId': playmeshEndpointBoundStorageGameId,
  'operation': operation,
  'bucket': bucket,
  'key': GameStorageService.gdevelopStorageRootKey,
  if (operation == 'sync.get') 'revision': revision,
  if (operation == 'sync.set') 'value': value,
  if (operation == 'sync.set') 'expectedRevision': expectedRevision,
};

Map<String, Object?> _restEnvelope({
  required String requestId,
  required String operation,
  required String bucket,
  String? key,
  Object? revision,
  Object? value,
  String? expectedRevision,
}) => {
  'protocolVersion': playmeshStandardJsonProtocolVersion,
  'requestId': requestId,
  'gameId': 'com.playmesh.http-storage',
  'operation': operation,
  'bucket': bucket,
  'key': ?key,
  if (operation == 'get') 'revision': revision,
  if (operation == 'set') 'value': value,
  if (operation != 'get') 'expectedRevision': expectedRevision,
};

Future<http.Response> _syncGet(
  Uri endpoint,
  Map<String, Object?> envelope,
) async {
  final body = jsonEncode(envelope);
  final payload = base64Url.encode(utf8.encode(body)).replaceAll('=', '');
  return http.get(
    endpoint.replace(queryParameters: {'payload': payload}),
    headers: {
      'X-Playmesh-Storage-Sync': '1',
      'X-Playmesh-Content-Sha256': await _sha256(body),
    },
  );
}

Future<http.Response> _syncPut(
  Uri endpoint,
  Map<String, Object?> envelope,
) async {
  final body = jsonEncode(envelope);
  return http.put(
    endpoint,
    headers: {
      'Content-Type': 'application/json',
      'X-Playmesh-Storage-Sync': '1',
      'X-Playmesh-Content-Sha256': await _sha256(body),
    },
    body: body,
  );
}

Future<http.Response> _restGet(
  Uri endpoint,
  Map<String, Object?> envelope, {
  String? digest,
}) => _restQuery(endpoint, envelope, method: 'GET', digest: digest);

Future<http.Response> _restDelete(
  Uri endpoint,
  Map<String, Object?> envelope,
) => _restQuery(endpoint, envelope, method: 'DELETE');

Future<http.Response> _restQuery(
  Uri endpoint,
  Map<String, Object?> envelope, {
  required String method,
  String? digest,
}) async {
  final body = jsonEncode(envelope);
  final uri = _restQueryUri(endpoint, envelope);
  final headers = {'X-Playmesh-Content-Sha256': digest ?? await _sha256(body)};
  return method == 'GET'
      ? http.get(uri, headers: headers)
      : http.delete(uri, headers: headers);
}

Uri _restQueryUri(Uri endpoint, Map<String, Object?> envelope) {
  final body = jsonEncode(envelope);
  final payload = base64Url.encode(utf8.encode(body)).replaceAll('=', '');
  return endpoint.replace(queryParameters: {'payload': payload});
}

Future<http.Response> _restPut(
  Uri endpoint,
  Map<String, Object?> envelope,
) async {
  final body = jsonEncode(envelope);
  return http.put(
    endpoint,
    headers: {
      'Content-Type': 'application/json',
      'X-Playmesh-Content-Sha256': await _sha256(body),
    },
    body: body,
  );
}

Future<String> _sha256(String value) async {
  final digest = await Sha256().hash(utf8.encode(value));
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String? _errorCode(http.Response response) =>
    ((jsonDecode(response.body) as Map)['error'] as Map?)?['code'] as String?;
