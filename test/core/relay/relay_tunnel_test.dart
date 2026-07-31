import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/game_web_gateway.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';

void main() {
  test('公共中转在端点间建立透明加密字节流', () async {
    final authority = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authoritySubscription = authority.listen((request) async {
      final body = await request.fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      request.response.headers
        ..contentType = ContentType.binary
        ..set('X-Test-Authority-Uri', request.uri.toString());
      request.response.add(body);
      await request.response.close();
    });
    final relay = await _FakeOpaqueRelay.start();
    final authorityBase = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: authority.port,
    );
    final host = await startRelayHostSession(
      serverBaseUri: relay.baseUri,
      sourceToken: 'source-token',
      hostPath: '/relay/v1/host',
      clientPath: '/relay/v1/client',
      authorityWebBaseUri: authorityBase,
      authorityCoreBaseUri: authorityBase,
      authorityEntryUri: authorityBase.replace(
        path: playmeshGameInvitationPath,
        fragment: Uri(
          queryParameters: {
            playmeshGameInvitationTokenParameter: 'authority-share-token',
          },
        ).query,
      ),
      maxConnectionsPerTunnel: 1,
    );
    final client = await startRelayClientGateway(
      invitationUri: host.joinUri,
      target: RelayTarget.web,
    );

    try {
      final payload = List<int>.generate(
        128 * 1024,
        (index) => (index * 31) % 251,
      );
      final response = await http
          .post(
            client.localBaseUri.replace(path: '/probe.txt', query: 'x=1'),
            body: payload,
          )
          .timeout(const Duration(seconds: 5));

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['x-test-authority-uri'], '/probe.txt?x=1');
      expect(response.bodyBytes, payload);
      expect(host.joinUri.path, '/j/test-tunnel');
      expect(host.joinUri.hasQuery, isFalse);
      final invitationFragment = Uri.splitQueryString(host.joinUri.fragment);
      expect(invitationFragment.keys, ['inviteToken']);
      expect(invitationFragment['inviteToken'], isNotEmpty);
      final inviteToken = invitationFragment['inviteToken']!;
      expect(client.localEntryUri.path, playmeshGameInvitationPath);
      expect(client.localEntryUri.hasQuery, isFalse);
      expect(
        parsePlaymeshInvitationFragment(
          client.localEntryUri.fragment,
        )[playmeshGameInvitationTokenParameter],
        'authority-share-token',
      );
      expect(
        relay.observedRequests.any((request) => request.contains(inviteToken)),
        isFalse,
      );
      expect(relay.clientCiphertext.take(4).toList(), <int>[
        0x50,
        0x4d,
        0x52,
        0x31,
      ]);
      expect(
        utf8.decode(relay.clientCiphertext, allowMalformed: true),
        isNot(contains('POST /probe.txt')),
      );
      expect(relay.deleted, isFalse);
    } finally {
      await client.close();
      await host.close();
      await relay.close();
      await authoritySubscription.cancel();
      await authority.close(force: true);
    }

    expect(relay.deleted, isTrue);
  });

  test('公共中转主机池按服务器上限维持少量热连接并动态补充', () async {
    final authority = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authoritySubscription = authority.listen((request) async {
      request.response.write('OK');
      await request.response.close();
    });
    final relay = await _FakeOpaqueRelay.start();
    final authorityBase = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: authority.port,
    );
    final host = await startRelayHostSession(
      serverBaseUri: relay.baseUri,
      sourceToken: 'source-token',
      hostPath: '/relay/v1/host',
      clientPath: '/relay/v1/client',
      authorityWebBaseUri: authorityBase,
      authorityCoreBaseUri: authorityBase,
      authorityEntryUri: authorityBase.replace(
        path: playmeshGameInvitationPath,
        fragment: Uri(
          queryParameters: {
            playmeshGameInvitationTokenParameter: 'authority-share-token',
          },
        ).query,
      ),
      maxConnectionsPerTunnel: 6,
    );

    RelayClientGateway? client;
    try {
      await _waitFor(
        () => relay.pendingHostCount == 4 && host.connectionCount == 4,
      );
      expect(relay.hostUpgradeCount, 4);

      client = await startRelayClientGateway(
        invitationUri: host.joinUri,
        target: RelayTarget.web,
      );
      final response = await http
          .get(client.localBaseUri.resolve('/probe'))
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, HttpStatus.ok);

      await _waitFor(
        () =>
            relay.pendingHostCount == 4 &&
            host.connectionCount == 4 &&
            relay.hostUpgradeCount >= 5,
      );
      expect(relay.hostUpgradeCount, 5);
    } finally {
      await client?.close();
      await host.close();
      await relay.close();
      await authoritySubscription.cancel();
      await authority.close(force: true);
    }
  });
}

class _FakeOpaqueRelay {
  _FakeOpaqueRelay._(this.server);

  static Future<_FakeOpaqueRelay> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeOpaqueRelay._(server);
    relay._subscription = server.listen(relay._handle);
    return relay;
  }

  final HttpServer server;
  final List<Socket> _pendingHosts = [];
  final List<Completer<Socket>> _hostWaiters = [];
  final Set<Socket> _hostConnections = {};
  final List<int> clientCiphertext = [];
  final List<String> observedRequests = [];
  StreamSubscription<HttpRequest>? _subscription;
  bool deleted = false;
  int hostUpgradeCount = 0;

  int get pendingHostCount => _pendingHosts.length;

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    observedRequests.add(
      '${request.method} ${request.uri} '
      '${request.headers.value(HttpHeaders.authorizationHeader) ?? ''} '
      '${request.headers.value('X-Playmesh-Host-Lease') ?? ''} '
      '${request.headers.value('X-Playmesh-Join-Capability') ?? ''}',
    );
    if (request.method == 'POST' && request.uri.path == '/relay/v1/host') {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer source-token',
      );
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'tunnelId': 'test-tunnel',
            'hostLease': 'test-host-lease',
            'joinCapability': 'test-join-capability',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          }),
        );
      await request.response.close();
      return;
    }
    if (request.method == 'DELETE' && request.uri.path == '/relay/v1/host') {
      deleted = true;
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.method == 'GET' &&
        request.headers.value(HttpHeaders.upgradeHeader) == 'playmesh-tunnel') {
      request.response.statusCode = HttpStatus.switchingProtocols;
      request.response.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'playmesh-tunnel');
      final socket = await request.response.detachSocket(writeHeaders: true);
      if (request.uri.path == '/relay/v1/host') {
        hostUpgradeCount += 1;
        _hostConnections.add(socket);
        if (_hostWaiters.isNotEmpty) {
          _hostWaiters.removeAt(0).complete(socket);
        } else {
          _pendingHosts.add(socket);
        }
        return;
      }
      if (request.uri.path == '/relay/v1/client') {
        final host = await _takeHost();
        _pipeClientToHost(socket, host);
        _pipe(host, socket);
        return;
      }
      socket.destroy();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<Socket> _takeHost() {
    if (_pendingHosts.isNotEmpty) {
      return Future<Socket>.value(_pendingHosts.removeAt(0));
    }
    final waiter = Completer<Socket>();
    _hostWaiters.add(waiter);
    return waiter.future;
  }

  void _pipeClientToHost(Socket client, Socket host) {
    client.listen(
      (bytes) {
        clientCiphertext.addAll(bytes);
        host.add(bytes);
      },
      onError: (_) => host.destroy(),
      onDone: host.destroy,
      cancelOnError: true,
    );
  }

  void _pipe(Socket source, Socket destination) {
    source.listen(
      destination.add,
      onError: (_) => destination.destroy(),
      onDone: destination.destroy,
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await server.close(force: true);
    for (final host in _hostConnections) {
      host.destroy();
    }
    _hostConnections.clear();
    for (final waiter in _hostWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('模拟中转已关闭'));
      }
    }
    _hostWaiters.clear();
    _pendingHosts.clear();
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待动态中转连接池状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
