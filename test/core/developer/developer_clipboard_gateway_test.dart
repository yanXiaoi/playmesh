import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('本机已认证 WebView 可通过 Developer Gateway 读取纯文本剪贴板', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var clipboardReads = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      clipboardReads += 1;
      expect(call.arguments, Clipboard.kTextPlain);
      return <String, Object?>{'text': 'clipboard payload'};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final port = await _availablePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'clipboard-test-token',
    );
    addTearDown(gateway.close);

    final response = await http.get(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/dev/api/clipboard',
      ),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer clipboard-test-token',
      },
    );

    expect(response.statusCode, HttpStatus.ok, reason: response.body);
    expect(
      response.headers['x-playmesh-operation-id'],
      'workspace.clipboard_read',
    );
    expect(
      jsonDecode(response.body),
      containsPair('text', 'clipboard payload'),
    );
    expect(clipboardReads, 1);
  });

  test('剪贴板读取仍受 Developer Gateway 认证保护', () async {
    final port = await _availablePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'clipboard-test-token',
    );
    addTearDown(gateway.close);

    final response = await http.get(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/dev/api/clipboard',
      ),
    );

    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('Agent 通道不能调用用户剪贴板读取回退', () async {
    final port = await _availablePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'clipboard-test-token',
    );
    addTearDown(gateway.close);

    final response = await http.get(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/dev/api/clipboard',
      ),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer clipboard-test-token',
        'X-Playmesh-AI-Channel': 'agent',
      },
    );

    expect(response.statusCode, HttpStatus.forbidden);
    final body = jsonDecode(response.body) as Map;
    expect((body['error'] as Map)['code'], 'clipboard_read_ui_only');
  });
}

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
