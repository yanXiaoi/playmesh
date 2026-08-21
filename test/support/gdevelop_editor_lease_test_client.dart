import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/gdevelop_editor_instance_lease.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';

class GDevelopEditorLeaseTestWebIdeSource implements GDevelopWebIdeSource {
  const GDevelopEditorLeaseTestWebIdeSource();

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

class GDevelopEditorLeaseTestClient {
  GDevelopEditorLeaseTestClient._({
    required this.baseUri,
    required this.developerToken,
    required this.instanceId,
    required this.pageId,
    required this.leaseToken,
    required this._client,
  });

  final Uri baseUri;
  final String developerToken;
  final String instanceId;
  final String pageId;
  final String leaseToken;
  final http.Client _client;

  Map<String, String> get leaseHeaders => {
    gdevelopEditorInstanceHeader: instanceId,
    gdevelopEditorPageHeader: pageId,
    gdevelopEditorLeaseHeader: leaseToken,
  };

  Map<String, String> get authHeaders => {
    'Authorization': 'Bearer $developerToken',
    ...leaseHeaders,
  };

  static Future<GDevelopEditorLeaseTestClient> acquire({
    required Uri baseUri,
    required Uri workspaceUri,
    required String developerToken,
    String instanceId = 'test_editor_instance_0001',
    String pageId = 'test_editor_page_000001',
    http.Client? client,
  }) async {
    final activeClient = client ?? http.Client();
    try {
      final bootstrapRequest = http.Request(
        'GET',
        workspaceUri.replace(
          scheme: baseUri.scheme,
          host: baseUri.host,
          port: baseUri.port,
        ),
      )..followRedirects = false;
      final bootstrapResponse = await activeClient.send(bootstrapRequest);
      final bootstrapBody = await bootstrapResponse.stream.bytesToString();
      if (bootstrapResponse.statusCode != 303) {
        throw StateError(
          'Unable to bootstrap GDevelop test editor acquire capability: '
          '${bootstrapResponse.statusCode} $bootstrapBody',
        );
      }
      final capabilityCookie = _cookiePair(
        bootstrapResponse.headers['set-cookie'],
        gdevelopEditorAcquireCapabilityCookie,
      );
      if (capabilityCookie == null) {
        throw StateError(
          'GDevelop test editor bootstrap did not set the '
          '$gdevelopEditorAcquireCapabilityCookie cookie',
        );
      }

      final response = await activeClient.post(
        baseUri.resolve('/dev/api/gdevelop/editor-instance/acquire'),
        headers: {
          'Authorization': 'Bearer $developerToken',
          'Content-Type': 'application/json',
          'Cookie': capabilityCookie,
        },
        body: jsonEncode({
          'instanceId': instanceId,
          'pageId': pageId,
          'previousLeaseToken': null,
          'resumeAfterReload': false,
        }),
      );
      if (response.statusCode != 200) {
        throw StateError(
          'Unable to acquire GDevelop test editor lease: '
          '${response.statusCode} ${response.body}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, Object?>;
      final lease = Map<String, Object?>.from(payload['lease']! as Map);
      return GDevelopEditorLeaseTestClient._(
        baseUri: baseUri,
        developerToken: developerToken,
        instanceId: lease['instanceId']! as String,
        pageId: lease['pageId']! as String,
        leaseToken: lease['leaseToken']! as String,
        client: activeClient,
      );
    } catch (_) {
      if (client == null) activeClient.close();
      rethrow;
    }
  }

  Future<void> release() async {
    await _client.post(
      baseUri.resolve('/dev/api/gdevelop/editor-instance/release'),
      headers: {
        'Authorization': 'Bearer $developerToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'instanceId': instanceId,
        'pageId': pageId,
        'leaseToken': leaseToken,
      }),
    );
    _client.close();
  }
}

String? _cookiePair(String? setCookieHeader, String name) {
  if (setCookieHeader == null) return null;
  final match = RegExp(
    '(?:^|,\\s*)${RegExp.escape(name)}=([^;,]+)',
  ).firstMatch(setCookieHeader);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : '$name=$value';
}
