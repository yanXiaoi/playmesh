import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_preview_service.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'preview Gateway accepts chunked ZIP and exposes run status without credentials',
    () async {
      final port = await _availablePort();
      final temporary = await Directory.systemTemp.createTemp(
        'gdevelop-preview-gateway-',
      );
      final controller = DeveloperRunController();
      final executedJavaScript = <String>[];
      final oversizedDebuggerMessage = 'x' * (4 * 1024 * 1024 + 1);
      controller.onLaunch = (request) async {
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
        controller.reportRunning(
          projectId: request.projectId,
          expectedRunId: request.runId,
          links: [Uri.parse('http://192.168.1.8:4100/join')],
        );
        controller.registerJavaScriptExecutor(request.projectId, (
          source,
        ) async {
          executedJavaScript.add(source);
          if (source.contains('.drain')) {
            return jsonEncode({
              'protocolVersion': '1.0.0',
              'ready': true,
              'messages': [
                oversizedDebuggerMessage,
                jsonEncode({
                  'command': 'status',
                  'payload': {'sceneName': 'Scene'},
                }),
                ...List.generate(
                  550,
                  (index) => jsonEncode({
                    'command': 'console.log',
                    'payload': {'message': 'message-$index'},
                  }),
                ),
              ],
            });
          }
          return true;
        }, expectedRunId: request.runId);
      };
      final previewService = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'gateway-preview-token-0123456789',
        path: 'preview-test',
        runController: controller,
        previewService: previewService,
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(() async {
        await gateway.close();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      const gameId = 'com.example.gateway-preview';
      final zip = _package(gameId);
      final client = http.Client();
      addTearDown(client.close);
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: 'gateway-preview-token-0123456789',
      );
      addTearDown(lease.release);
      final uri = Uri.parse(
        'http://127.0.0.1:$port/dev/api/gdevelop/projects/$gameId/preview',
      );
      final upload = http.StreamedRequest('POST', uri)
        ..headers.addAll(lease.authHeaders)
        ..headers['Content-Type'] = 'application/zip';
      final uploadResponseFuture = client.send(upload);
      upload.sink
        ..add(zip.sublist(0, zip.length ~/ 2))
        ..add(zip.sublist(zip.length ~/ 2));
      await upload.sink.close();

      final uploadResponse = await uploadResponseFuture;
      final uploadJson =
          jsonDecode(await uploadResponse.stream.bytesToString()) as Map;
      expect(uploadResponse.statusCode, HttpStatus.accepted);
      expect(uploadJson['protocolVersion'], '1.0.0');
      expect(uploadJson['gameId'], gameId);
      expect(uploadJson['expiresAt'], isA<int>());
      expect((uploadJson['run'] as Map)['phase'], 'running');
      expect((uploadJson['run'] as Map)['links'], isA<List>());
      expect(jsonEncode(uploadJson), isNot(contains('credential')));
      final previewId = uploadJson['previewId']! as String;

      final status = await client.get(uri, headers: lease.authHeaders);
      expect(status.statusCode, HttpStatus.ok);
      expect((jsonDecode(status.body) as Map)['previewId'], previewId);

      final debuggerBase = uri.resolve('preview/$previewId/debugger/');
      final messages = await client.get(
        debuggerBase.resolve('messages'),
        headers: lease.authHeaders,
      );
      expect(messages.statusCode, HttpStatus.ok, reason: messages.body);
      final messagesJson = jsonDecode(messages.body) as Map;
      expect(messagesJson['protocolVersion'], '1.0.0');
      expect(messagesJson['ready'], true);
      final debuggerMessages = messagesJson['messages'] as List;
      expect(debuggerMessages, hasLength(552));
      expect((debuggerMessages.first as String).length, 4 * 1024 * 1024 + 1);
      expect(messages.body, isNot(contains('gateway-preview-token')));
      expect(messages.body, isNot(contains('http://')));

      final command = await client.post(
        debuggerBase.resolve('commands'),
        headers: {...lease.authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'command': {
            'command': 'set',
            'path': ['_variables'],
            'newValue': 'y' * (4 * 1024 * 1024 + 1),
          },
        }),
      );
      expect(command.statusCode, HttpStatus.ok, reason: command.body);
      expect((jsonDecode(command.body) as Map)['accepted'], true);
      expect(executedJavaScript.last, contains('"command":"set"'));
      expect(executedJavaScript.last.length, greaterThan(4 * 1024 * 1024));

      final stale = await client.get(
        uri.resolve('preview/stale/debugger/messages'),
        headers: lease.authHeaders,
      );
      expect(stale.statusCode, HttpStatus.conflict);
      expect(
        ((jsonDecode(stale.body) as Map)['error'] as Map)['code'],
        'preview_generation_conflict',
      );

      final stopped = await client.delete(
        uri.resolve('preview/$previewId'),
        headers: lease.authHeaders,
      );
      expect(stopped.statusCode, HttpStatus.ok);
      expect(
        ((jsonDecode(stopped.body) as Map)['run'] as Map)['phase'],
        'stopped',
      );
    },
  );

  test('preview Gateway returns 422 for package gameId mismatch', () async {
    final port = await _availablePort();
    final controller = DeveloperRunController(onLaunch: (_) async {});
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'gateway-preview-token-0123456789',
      path: 'preview-id-test',
      runController: controller,
      gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
    );
    addTearDown(gateway.close);
    final lease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
      developerToken: 'gateway-preview-token-0123456789',
    );
    addTearDown(lease.release);
    final response = await http.post(
      Uri.parse(
        'http://127.0.0.1:$port/dev/api/gdevelop/projects/'
        'com.example.expected/preview',
      ),
      headers: {...lease.authHeaders, 'Content-Type': 'application/zip'},
      body: _package('com.example.other'),
    );

    expect(response.statusCode, HttpStatus.unprocessableEntity);
    expect(
      ((jsonDecode(response.body) as Map)['error'] as Map)['code'],
      'preview_package_invalid',
    );
    expect(controller.activeStatus, isNull);
  });

  test(
    'embedded preview is served by the authenticated same-origin GDevelop path without launching App runtime',
    () async {
      final port = await _availablePort();
      final temporary = await Directory.systemTemp.createTemp(
        'gdevelop-embedded-preview-gateway-',
      );
      var launches = 0;
      final controller = DeveloperRunController(
        onLaunch: (_) async => launches++,
      );
      final previewService = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'gateway-embedded-preview-token',
        path: 'embedded-preview-test',
        runController: controller,
        previewService: previewService,
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(() async {
        await gateway.close();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: 'gateway-embedded-preview-token',
      );
      addTearDown(lease.release);
      const gameId = 'com.example.gateway-embedded-preview';
      const authorization = 'Bearer gateway-embedded-preview-token';
      final started = await http.post(
        Uri.parse(
          'http://127.0.0.1:$port/dev/api/gdevelop/projects/'
          '$gameId/preview?surface=embedded',
        ),
        headers: {...lease.authHeaders, 'Content-Type': 'application/zip'},
        body: _package(gameId),
      );
      expect(started.statusCode, HttpStatus.accepted, reason: started.body);
      final payload = jsonDecode(started.body) as Map;
      final run = payload['run'] as Map;
      expect(run['phase'], 'running');
      expect(launches, 0);
      expect(controller.activeStatus, isNull);
      final link = Uri.parse((run['links'] as List).single as String);
      expect(link.query, isEmpty);
      expect(link.path, contains('/gdevelop/embedded-preview/$gameId/'));

      final asset = await http.get(
        link,
        headers: {HttpHeaders.authorizationHeader: authorization},
      );
      expect(asset.statusCode, HttpStatus.ok, reason: asset.body);
      expect(asset.body, contains('OK'));
      expect(asset.headers['cache-control'], 'no-store');
    },
  );

  test(
    'generic preview accepts and runs a temporary package independently',
    () async {
      final port = await _availablePort();
      final controller = DeveloperRunController();
      controller.onLaunch = (request) async {
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
        controller.reportRunning(
          projectId: request.projectId,
          expectedRunId: request.runId,
        );
      };
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'gateway-generic-preview-token',
        runController: controller,
      );
      addTearDown(gateway.close);
      const gameId = 'Com.Example.Generic_2';
      final base = Uri.parse('http://127.0.0.1:$port');
      const headers = {
        'Authorization': 'Bearer gateway-generic-preview-token',
        'Content-Type': 'application/zip',
      };

      final started = await http.post(
        base.resolve('/dev/api/projects/$gameId/preview'),
        headers: headers,
        body: _package(gameId),
      );
      expect(started.statusCode, HttpStatus.accepted, reason: started.body);
      final startedJson = jsonDecode(started.body) as Map;
      expect(startedJson['gameId'], gameId);
      expect((startedJson['run'] as Map)['phase'], 'running');
    },
  );
}

Future<int> _availablePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

List<int> _package(String gameId) {
  final manifest = utf8.encode(
    jsonEncode({
      'id': gameId,
      'name': 'Gateway Preview',
      'author': 'Tester',
      'lastModifiedAt': 0,
      'remarks': 'Temporary preview',
      'version': '0.1.0',
      'sdkVersion': '4.1.0',
      'appSdkVersion': '3.3.0',
      'orientation': 'landscape',
      'modes': ['solo'],
      'displayModes': ['multi_screen'],
      'players': {'min': 1, 'max': 1},
      'entries': {'game': 'index.html'},
      'tags': <String>[],
    }),
  );
  final index = utf8.encode(
    '<!doctype html><html><head></head><body>OK</body></html>',
  );
  return ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile('main.json', manifest.length, manifest))
      ..addFile(ArchiveFile('app/index.html', index.length, index)),
  )!;
}
