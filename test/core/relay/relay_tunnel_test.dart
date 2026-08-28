import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';

void main() {
  test('Authority 通过本地 Go Core 创建 WebRTC 会话并保持原邀请入口', () async {
    final core = await _FakeCoreControl.start();
    final authority = Uri.parse('http://127.0.0.1:41001/');
    final session = await startRelayHostSession(
      coreBaseUri: core.baseUri,
      sessionId: 's_room',
      serverBaseUri: Uri.parse('https://relay.example.test/'),
      sourceToken: 'source-token',
      hostPath: '/relay/v1/host',
      clientPath: '/relay/v1/client',
      authorityWebBaseUri: authority,
      authorityCoreBaseUri: Uri.parse('http://127.0.0.1:42001/'),
      authorityEntryUri: authority.replace(
        path: playmeshGameInvitationPath,
        fragment: 'inviteToken=share-token',
      ),
      maxConnectionsPerTunnel: 8,
    );

    try {
      expect(
        session.joinUri,
        Uri.parse('https://relay.example.test/j/tunnel#inviteToken=opaque'),
      );
      expect(session.status, RelayConnectionStatus.connected);
      expect(session.connectionCount, 2);
      expect(core.hostBody?['sessionId'], 's_room');
      expect(core.hostBody?['maxPeers'], 8);
      expect(core.hostBody?['sourceToken'], 'source-token');
    } finally {
      await session.close();
      await core.close();
    }
    expect(core.deletedPaths, contains('/v1/relay/host/host-session'));
  });

  test('一次加入只创建一个 PeerConnection 控制会话并返回 Web/Core 两个网关', () async {
    final core = await _FakeCoreControl.start();
    final invitation = Uri.parse(
      'https://relay.example.test/j/tunnel#inviteToken=opaque',
    );
    final session = await startRelayClientSession(
      coreBaseUri: core.baseUri,
      invitationUri: invitation,
    );

    try {
      expect(core.clientCreateCount, 1);
      expect(core.clientBody?['invitationUri'], invitation.toString());
      expect(session.connectionMode, 'direct');
      expect(
        session.webGateway.localBaseUri,
        Uri.parse('http://127.0.0.1:43001'),
      );
      expect(
        session.coreGateway.localBaseUri,
        Uri.parse('http://127.0.0.1:43002'),
      );
      expect(
        session.webGateway.localEntryUri,
        Uri.parse(
          'http://127.0.0.1:43001$playmeshGameInvitationPath'
          '#inviteToken=share-token',
        ),
      );
    } finally {
      await session.close();
      await core.close();
    }
    expect(core.deletedPaths, contains('/v1/relay/client/client-session'));
  });

  test('Go Core 控制失败保留原始 HTTP 状态、requestId 与响应体', () async {
    final core = await _FakeCoreControl.start(
      hostFailureStatus: HttpStatus.badGateway,
      hostFailureBody:
          '{"error":"webrtc_tunnel_failed","message":"upstream raw failure"}',
    );
    try {
      await expectLater(
        startRelayHostSession(
          coreBaseUri: core.baseUri,
          sessionId: 's_failure',
          serverBaseUri: Uri.parse('https://relay.example.test/'),
          sourceToken: 'source-token',
          hostPath: '/relay/v1/host',
          clientPath: '/relay/v1/client',
          authorityWebBaseUri: Uri.parse('http://127.0.0.1:41001/'),
          authorityCoreBaseUri: Uri.parse('http://127.0.0.1:42001/'),
          authorityEntryUri: Uri.parse(
            'http://127.0.0.1:41001$playmeshGameInvitationPath'
            '#inviteToken=share-token',
          ),
          maxConnectionsPerTunnel: 8,
        ),
        throwsA(
          predicate<Object>((error) {
            final text = error.toString();
            return text.contains('statusCode=502') &&
                text.contains('requestId=relay-') &&
                text.contains('upstream raw failure') &&
                text.contains('webrtc_tunnel_failed');
          }),
        ),
      );
    } finally {
      await core.close();
    }
  });
}

class _FakeCoreControl {
  _FakeCoreControl._(
    this.server, {
    this.hostFailureStatus,
    this.hostFailureBody,
  });

  static Future<_FakeCoreControl> start({
    int? hostFailureStatus,
    String? hostFailureBody,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _FakeCoreControl._(
      server,
      hostFailureStatus: hostFailureStatus,
      hostFailureBody: hostFailureBody,
    );
    result.subscription = server.listen(result.handle);
    return result;
  }

  final HttpServer server;
  StreamSubscription<HttpRequest>? subscription;
  Map<String, Object?>? hostBody;
  Map<String, Object?>? clientBody;
  int clientCreateCount = 0;
  final List<String> deletedPaths = [];
  final int? hostFailureStatus;
  final String? hostFailureBody;

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> handle(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/v1/relay/host') {
      hostBody = await _readObject(request);
      if (hostFailureStatus != null) {
        request.response.statusCode = hostFailureStatus!;
        request.response.headers.contentType = ContentType.json;
        request.response.write(hostFailureBody ?? '');
        await request.response.close();
        return;
      }
      await _json(request, HttpStatus.created, {
        'id': 'host-session',
        'status': 'connected',
        'joinUri': 'https://relay.example.test/j/tunnel#inviteToken=opaque',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
        'connectionCount': 2,
      });
      return;
    }
    if (request.method == 'GET' &&
        request.uri.path == '/v1/relay/host/host-session') {
      await _json(request, HttpStatus.ok, {
        'id': 'host-session',
        'status': 'connected',
        'connectionCount': 2,
      });
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/v1/relay/client') {
      clientCreateCount += 1;
      clientBody = await _readObject(request);
      await _json(request, HttpStatus.created, {
        'id': 'client-session',
        'status': 'connected',
        'connectionMode': 'direct',
        'webBaseUri': 'http://127.0.0.1:43001',
        'coreBaseUri': 'http://127.0.0.1:43002',
        'localEntryUri':
            'http://127.0.0.1:43001$playmeshGameInvitationPath#inviteToken=share-token',
      });
      return;
    }
    if (request.method == 'DELETE') {
      deletedPaths.add(request.uri.path);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> close() async {
    await subscription?.cancel();
    await server.close(force: true);
  }
}

Future<Map<String, Object?>> _readObject(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  return Map<String, Object?>.from(jsonDecode(text) as Map);
}

Future<void> _json(
  HttpRequest request,
  int status,
  Map<String, Object?> body,
) async {
  final response = request.response;
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(
    jsonEncode({
      'type': 'playmesh.webrtc-tunnel.snapshot',
      'protocolVersion': relayCoreControlProtocolVersion,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': request.headers.value('x-playmesh-request-id'),
      ...body,
    }),
  );
  await response.close();
}
