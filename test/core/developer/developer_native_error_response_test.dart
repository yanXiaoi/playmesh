import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/capabilities/capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_registry.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('开发者能力实例创建失败时返回原生平台错误', () async {
    final port = await _availablePort();
    final capabilityTests = DeveloperCapabilityTestService(
      registry: CapabilityRegistry(const [
        _NativeFailureCapabilityPlugin(),
      ], platform: CapabilityPlatform.ANDROID),
      emitEvent: (_) {},
    );
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'native-error-token',
      capabilityTests: capabilityTests,
    );
    addTearDown(gateway.close);

    final response = await http.post(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/dev/api/capability-tests/instances',
      ),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer native-error-token',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode({
        'code': 'sensor.native-failure',
        'options': <String, Object?>{},
      }),
    );

    expect(response.statusCode, HttpStatus.conflict, reason: response.body);
    final body = jsonDecode(response.body) as Map;
    final error = body['error'] as Map;
    expect(error['code'], 'pose6d_arcore_install_not_completed');
    expect(
      error['message'],
      'com.google.ar.core.exceptions.'
      'UnavailableUserDeclinedInstallationException',
    );
    expect(error['details'], {
      'exception':
          'com.google.ar.core.exceptions.'
          'UnavailableUserDeclinedInstallationException',
    });
  });
}

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

final class _NativeFailureCapabilityPlugin implements CapabilityPlugin {
  const _NativeFailureCapabilityPlugin();

  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    code: 'sensor.native-failure',
    name: 'Native failure',
    description: 'Throws a native platform error.',
    apiVersion: '1.0.0',
    supportedPlatforms: [CapabilityPlatform.ANDROID],
    methods: [],
    events: [],
  );

  @override
  bool get isAvailable => true;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    throw PlatformException(
      code: 'pose6d_arcore_install_not_completed',
      message:
          'com.google.ar.core.exceptions.'
          'UnavailableUserDeclinedInstallationException',
      details: const {
        'exception':
            'com.google.ar.core.exceptions.'
            'UnavailableUserDeclinedInstallationException',
      },
    );
  }

  @override
  Future<void> dispose() async {}
}
