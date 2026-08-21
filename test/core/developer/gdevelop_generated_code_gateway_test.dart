import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'generated event code is served by the authenticated App gateway',
    () async {
      final port = await _availablePort();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: 'generated-code-token-0123456789',
        path: 'generated-code-test',
        gdevelopWebIdeSource: const GDevelopEditorLeaseTestWebIdeSource(),
      );
      addTearDown(gateway.close);
      final uri = Uri.parse(
        'http://127.0.0.1:$port/dev/api/gdevelop/generated-code/'
        'session-events.js',
      );
      final lease = await GDevelopEditorLeaseTestClient.acquire(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        workspaceUri: (await gateway.gdevelopWorkspaceLinks()).first,
        developerToken: 'generated-code-token-0123456789',
      );
      addTearDown(lease.release);
      final headers = {
        ...lease.authHeaders,
        'Content-Type': 'text/javascript; charset=utf-8',
      };

      final written = await http.put(
        uri,
        headers: headers,
        body: 'runtimeScene.test = true;',
      );
      expect(written.statusCode, HttpStatus.noContent);

      final read = await http.get(uri, headers: lease.authHeaders);
      expect(read.statusCode, HttpStatus.ok);
      expect(read.body, 'runtimeScene.test = true;');
      expect(read.headers['cache-control'], 'no-store');
    },
  );
}

Future<int> _availablePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}
