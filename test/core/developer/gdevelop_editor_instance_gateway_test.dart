import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_editor_instance_lease.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

void main() {
  test('Gateway enforces one global GDevelop editor lease', () async {
    var now = DateTime.utc(2026, 8, 11, 10);
    var tokenIndex = 0;
    var capabilityIndex = 0;
    final leases = GDevelopEditorInstanceLeaseManager(
      clock: () => now,
      tokenFactory: () => 'gateway_lease_${++tokenIndex}'.padRight(24, '_'),
      acquireCapabilityFactory: () =>
          'gateway_capability_${++capabilityIndex}'.padRight(32, '_'),
      ttl: const Duration(seconds: 30),
      heartbeatInterval: const Duration(seconds: 5),
    );
    final port = await _freePort();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'editor-instance-gateway-token',
      path: 'editor-instance-test',
      gdevelopWebIdeSource: const _MemoryWebIdeSource(),
      gdevelopEditorInstances: leases,
      clock: () => now,
      gdevelopAiToolsProvider: () async => loadGDevelopAiToolRegistryForTest(),
    );
    addTearDown(gateway.close);
    final base = Uri.parse('http://127.0.0.1:$port');
    const auth = {'Authorization': 'Bearer editor-instance-gateway-token'};
    final workspace = (await gateway.gdevelopWorkspaceLinks()).first.replace(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
    );
    expect(workspace.queryParameters['token'], 'editor-instance-gateway-token');
    final bootstrapCapability =
        workspace.queryParameters[gdevelopEditorBootstrapQueryParameter];
    expect(bootstrapCapability, isNotEmpty);

    final index = await http.get(
      workspace.replace(queryParameters: const {}),
      headers: auth,
    );
    expect(index.statusCode, HttpStatus.ok);
    expect(index.body, contains('gdevelop-editor-instance.js'));
    expect(
      index.body,
      contains('__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_BOOTSTRAP__'),
    );
    expect(
      _cookieValue(index, gdevelopEditorAcquireCapabilityCookie),
      isNull,
      reason: 'Bearer-authenticated index GET must not mint page capability',
    );

    final bearerOnly = await _acquire(
      base,
      auth,
      instanceId: 'agent_instance_0001',
      pageId: 'agent_page_00000001',
    );
    expect(bearerOnly.statusCode, HttpStatus.forbidden);
    expect(
      bearerOnly.body,
      contains('gdevelop_editor_acquire_capability_invalid'),
    );

    final missingBootstrapCapability = await _getWithoutRedirects(
      workspace.replace(
        queryParameters: {'token': workspace.queryParameters['token']!},
      ),
    );
    expect(missingBootstrapCapability.statusCode, HttpStatus.forbidden);
    final wrongBootstrapCapability = await _getWithoutRedirects(
      workspace.replace(
        queryParameters: {
          ...workspace.queryParameters,
          gdevelopEditorBootstrapQueryParameter: 'wrong_capability_value',
        },
      ),
    );
    expect(wrongBootstrapCapability.statusCode, HttpStatus.forbidden);

    final bootstrap = await _getWithoutRedirects(workspace);
    expect(bootstrap.statusCode, HttpStatus.seeOther);
    var acquireCapability = _cookieValue(
      bootstrap,
      gdevelopEditorAcquireCapabilityCookie,
    );
    expect(acquireCapability, bootstrapCapability);
    final bootstrapSetCookie = bootstrap.headers['set-cookie']!;
    expect(bootstrapSetCookie, contains('HttpOnly'));
    expect(bootstrapSetCookie, contains('SameSite=Strict'));
    expect(
      bootstrapSetCookie,
      contains('Path=/dev/api/gdevelop/editor-instance/acquire'),
    );

    final first = await _acquire(
      base,
      auth,
      acquireCapability: acquireCapability,
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    expect(first.statusCode, HttpStatus.ok);
    final firstLease = _lease(first);
    final firstCapability = acquireCapability;
    acquireCapability = _cookieValue(
      first,
      gdevelopEditorAcquireCapabilityCookie,
    );
    expect(acquireCapability, isNotNull);
    expect(acquireCapability, isNot(firstCapability));

    final replayedCapability = await _acquire(
      base,
      auth,
      acquireCapability: firstCapability,
      instanceId: firstLease['instanceId']! as String,
      pageId: firstLease['pageId']! as String,
      previousLeaseToken: firstLease['leaseToken']! as String,
      resumeAfterReload: true,
    );
    expect(replayedCapability.statusCode, HttpStatus.forbidden);

    final otherHost = await _acquire(
      base,
      auth,
      acquireCapability: acquireCapability,
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );
    expect(otherHost.statusCode, HttpStatus.conflict);

    final withoutLease = await http.get(
      base.resolve('/dev/api/gdevelop/projects'),
      headers: auth,
    );
    expect(withoutLease.statusCode, HttpStatus.conflict);
    expect(withoutLease.body, contains('gdevelop_editor_lease_required'));

    final withLease = await http.get(
      base.resolve('/dev/api/gdevelop/projects'),
      headers: {...auth, ..._leaseHeaders(firstLease)},
    );
    expect(withLease.statusCode, HttpStatus.ok);

    final unboundAgent = await http.get(
      base.resolve('/dev/api/gdevelop/ai/tools'),
      headers: {...auth, 'X-Playmesh-AI-Channel': 'agent'},
    );
    expect(unboundAgent.statusCode, HttpStatus.conflict);
    expect(leases.bindAiSession('gdas-test-session-01'), isTrue);
    final boundAgent = await http.get(
      base.resolve('/dev/api/gdevelop/ai/tools'),
      headers: {...auth, 'X-Playmesh-AI-Channel': 'agent'},
    );
    expect(boundAgent.statusCode, HttpStatus.ok);

    final refreshed = await _acquire(
      base,
      auth,
      acquireCapability: acquireCapability,
      instanceId: firstLease['instanceId']! as String,
      pageId: 'app_page_00000002',
      previousLeaseToken: firstLease['leaseToken']! as String,
      resumeAfterReload: true,
    );
    expect(refreshed.statusCode, HttpStatus.ok);
    final refreshedLease = _lease(refreshed);
    final preRefreshCapability = acquireCapability;
    acquireCapability = _cookieValue(
      refreshed,
      gdevelopEditorAcquireCapabilityCookie,
    );
    expect(acquireCapability, isNotNull);
    expect(acquireCapability, isNot(preRefreshCapability));
    expect(refreshedLease['leaseToken'], isNot(firstLease['leaseToken']));
    final agentAfterRefresh = await http.get(
      base.resolve('/dev/api/gdevelop/ai/tools'),
      headers: {...auth, 'X-Playmesh-AI-Channel': 'agent'},
    );
    expect(agentAfterRefresh.statusCode, HttpStatus.conflict);

    final runtimeToolFromOldLease = await http.get(
      base.resolve('/dev/api/gdevelop/ai/tools?name=pause_runtime'),
      headers: {
        ...auth,
        ..._leaseHeaders(firstLease),
        'X-Playmesh-AI-Channel': 'agent',
      },
    );
    expect(runtimeToolFromOldLease.statusCode, HttpStatus.conflict);
    final runtimeToolFromCurrentLease = await http.get(
      base.resolve('/dev/api/gdevelop/ai/tools?name=pause_runtime'),
      headers: {
        ...auth,
        ..._leaseHeaders(refreshedLease),
        'X-Playmesh-AI-Channel': 'agent',
      },
    );
    expect(runtimeToolFromCurrentLease.statusCode, HttpStatus.ok);
    final runtimeTool =
        (jsonDecode(runtimeToolFromCurrentLease.body) as Map)['tool'] as Map;
    expect(runtimeTool['argumentsSchema'], {
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, Object?>{},
    });

    final oldPage = await http.get(
      base.resolve('/dev/api/gdevelop/projects'),
      headers: {...auth, ..._leaseHeaders(firstLease)},
    );
    expect(oldPage.statusCode, HttpStatus.conflict);
    final currentPage = await http.get(
      base.resolve('/dev/api/gdevelop/projects'),
      headers: {...auth, ..._leaseHeaders(refreshedLease)},
    );
    expect(currentPage.statusCode, HttpStatus.ok);

    final staleWorkspaceBootstrap = await _getWithoutRedirects(workspace);
    expect(staleWorkspaceBootstrap.statusCode, HttpStatus.forbidden);
    final currentWorkspace = (await gateway.gdevelopWorkspaceLinks()).first
        .replace(scheme: base.scheme, host: base.host, port: base.port);
    expect(
      currentWorkspace.queryParameters[gdevelopEditorBootstrapQueryParameter],
      acquireCapability,
    );
    final currentWorkspaceBootstrap = await _getWithoutRedirects(
      currentWorkspace,
    );
    expect(currentWorkspaceBootstrap.statusCode, HttpStatus.seeOther);
    expect(
      _cookieValue(
        currentWorkspaceBootstrap,
        gdevelopEditorAcquireCapabilityCookie,
      ),
      acquireCapability,
    );

    final released = await http.post(
      base.resolve('/dev/api/gdevelop/editor-instance/release'),
      headers: {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode(refreshedLease),
    );
    expect(released.statusCode, HttpStatus.noContent);
    final browserAfterRelease = await _acquire(
      base,
      auth,
      acquireCapability: acquireCapability,
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );
    expect(browserAfterRelease.statusCode, HttpStatus.ok);
    acquireCapability = _cookieValue(
      browserAfterRelease,
      gdevelopEditorAcquireCapabilityCookie,
    );
    expect(acquireCapability, isNotNull);

    now = now.add(const Duration(seconds: 30));
    final appAfterCrashTtl = await _acquire(
      base,
      auth,
      acquireCapability: acquireCapability,
      instanceId: 'app_instance_0002',
      pageId: 'app_page_00000003',
    );
    expect(appAfterCrashTtl.statusCode, HttpStatus.ok);
  });
}

Future<http.Response> _acquire(
  Uri base,
  Map<String, String> auth, {
  required String instanceId,
  required String pageId,
  String? acquireCapability,
  String? previousLeaseToken,
  bool resumeAfterReload = false,
}) => http.post(
  base.resolve('/dev/api/gdevelop/editor-instance/acquire'),
  headers: {
    ...auth,
    'Content-Type': 'application/json',
    if (acquireCapability != null)
      HttpHeaders.cookieHeader:
          '$gdevelopEditorAcquireCapabilityCookie=$acquireCapability',
  },
  body: jsonEncode({
    'instanceId': instanceId,
    'pageId': pageId,
    'previousLeaseToken': previousLeaseToken,
    'resumeAfterReload': resumeAfterReload,
  }),
);

Future<http.Response> _getWithoutRedirects(Uri uri) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', uri)..followRedirects = false;
    return await http.Response.fromStream(await client.send(request));
  } finally {
    client.close();
  }
}

String? _cookieValue(http.Response response, String name) {
  final setCookie = response.headers['set-cookie'];
  if (setCookie == null) return null;
  return RegExp(
    '(?:^|,\\s*)${RegExp.escape(name)}=([^;,]+)',
  ).firstMatch(setCookie)?.group(1);
}

Map<String, Object?> _lease(http.Response response) =>
    Map<String, Object?>.from(
      (jsonDecode(response.body) as Map<String, Object?>)['lease']! as Map,
    );

Map<String, String> _leaseHeaders(Map<String, Object?> lease) => {
  gdevelopEditorInstanceHeader: lease['instanceId']! as String,
  gdevelopEditorPageHeader: lease['pageId']! as String,
  gdevelopEditorLeaseHeader: lease['leaseToken']! as String,
};

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _MemoryWebIdeSource implements GDevelopWebIdeSource {
  const _MemoryWebIdeSource();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Uint8List?> read(String relativePath) async =>
      relativePath == 'index.html'
      ? Uint8List.fromList(
          utf8.encode('<!doctype html><html><head></head><body></body></html>'),
        )
      : null;
}
