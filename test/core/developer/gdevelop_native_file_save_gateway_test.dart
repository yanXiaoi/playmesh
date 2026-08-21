import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'Gateway stages, streams, and explicitly releases raw Blob bytes',
    () async {
      final port = await _availablePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'native-file-save-token-0123456789',
        path: 'native-save-test',
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(gateway.close);
      final client = http.Client();
      addTearDown(client.close);
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: 'native-file-save-token-0123456789',
      );
      addTearDown(lease.release);
      final archive = List<int>.generate(8192, (index) => index % 251);
      final collection = Uri.parse(
        'http://127.0.0.1:$port/dev/api/gdevelop/native-file-saves',
      );
      const hostAuthHeaders = {
        HttpHeaders.authorizationHeader:
            'Bearer native-file-save-token-0123456789',
      };
      final rejectedStage = await client.post(
        collection,
        headers: {
          ...hostAuthHeaders,
          HttpHeaders.contentTypeHeader: 'application/zip',
          'X-Playmesh-Filename': Uri.encodeComponent('Rejected.zip'),
        },
        body: const [1, 2, 3],
      );
      expect(rejectedStage.statusCode, HttpStatus.conflict);
      expect(
        (jsonDecode(rejectedStage.body) as Map)['error']['code'],
        'gdevelop_editor_lease_required',
      );

      final stage = http.StreamedRequest('POST', collection)
        ..headers.addAll(lease.authHeaders)
        ..headers['Content-Type'] = 'application/zip'
        ..headers['X-Playmesh-Filename'] = Uri.encodeComponent('My Game.zip');
      final stageResponseFuture = client.send(stage);
      stage.sink
        ..add(archive.sublist(0, 3072))
        ..add(archive.sublist(3072));
      await stage.sink.close();

      final stageResponse = await stageResponseFuture;
      final receipt =
          jsonDecode(await stageResponse.stream.bytesToString()) as Map;
      expect(stageResponse.statusCode, HttpStatus.created);
      expect(receipt['protocolVersion'], 1);
      expect(receipt['filename'], 'My Game.zip');
      expect(receipt['size'], archive.length);
      expect(jsonEncode(receipt), isNot(contains('base64')));
      final download = collection.resolve(receipt['downloadPath']! as String);

      final unauthenticated = await client.get(download);
      expect(unauthenticated.statusCode, HttpStatus.unauthorized);

      final downloaded = await client.get(download, headers: hostAuthHeaders);
      expect(downloaded.statusCode, HttpStatus.ok);
      expect(downloaded.bodyBytes, archive);
      expect(downloaded.headers['cache-control'], 'no-store');

      final released = await client.delete(download, headers: hostAuthHeaders);
      expect(released.statusCode, HttpStatus.noContent);
      final missing = await client.get(download, headers: hostAuthHeaders);
      expect(missing.statusCode, HttpStatus.notFound);
    },
  );

  test('same-origin workspace cookie authorizes Blob staging', () async {
    final port = await _availablePort();
    const token = 'native-file-save-cookie-token-0123456789';
    const path = 'native-save-cookie-test';
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: token,
      path: path,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    addTearDown(gateway.close);
    final client = http.Client();
    addTearDown(client.close);
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: token,
    );
    addTearDown(lease.release);

    final bootstrap = http.Request(
      'GET',
      Uri.parse('http://127.0.0.1:$port/dev/$path/workspace?token=$token'),
    )..followRedirects = false;
    final bootstrapResponse = await client.send(bootstrap);
    await bootstrapResponse.stream.drain<void>();
    expect(bootstrapResponse.statusCode, HttpStatus.seeOther);
    final setCookie = bootstrapResponse.headers['set-cookie'];
    expect(setCookie, isNotNull);
    final cookie = setCookie!.split(';').first;

    final archive = List<int>.generate(1024, (index) => index % 251);
    final collection = Uri.parse(
      'http://127.0.0.1:$port/dev/api/gdevelop/native-file-saves',
    );
    final stage = await client.post(
      collection,
      headers: {
        HttpHeaders.cookieHeader: cookie,
        ...lease.leaseHeaders,
        HttpHeaders.contentTypeHeader: 'application/zip',
        'X-Playmesh-Filename': Uri.encodeComponent('Cookie Game.zip'),
      },
      body: archive,
    );
    expect(stage.statusCode, HttpStatus.created);
    final receipt = jsonDecode(stage.body) as Map;
    expect(receipt['filename'], 'Cookie Game.zip');
    expect(receipt['size'], archive.length);

    final released = await client.delete(
      collection.resolve(receipt['downloadPath']! as String),
      headers: {HttpHeaders.cookieHeader: cookie, ...lease.leaseHeaders},
    );
    expect(released.statusCode, HttpStatus.noContent);
  });
}

Future<int> _availablePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}
