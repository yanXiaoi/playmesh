import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_invitation_inspector.dart';
import 'package:playmesh/core/game_web/game_web_gateway_contract.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';

void main() {
  test('LAN 预检只向去除 fragment 的受控入口 POST token', () async {
    late http.AbortableRequest sentRequest;
    final client = _RecordingClient((request) async {
      sentRequest = request as http.AbortableRequest;
      return _jsonResponse(_validResponseBody());
    });
    final inspector = DefaultGameInvitationInspector(httpClient: client);
    final invitation = _lanInvitation(host: '192.168.1.20');

    final result = await inspector.inspect(invitation);

    expect(sentRequest.method, 'POST');
    expect(sentRequest.url.fragment, isEmpty);
    expect(sentRequest.url.query, isEmpty);
    expect(sentRequest.url, invitation.requestUri);
    expect(sentRequest.followRedirects, isFalse);
    expect(sentRequest.maxRedirects, 0);
    expect(sentRequest.headers['accept'], 'application/json');
    expect(sentRequest.headers['cache-control'], 'no-store');
    expect(jsonDecode(sentRequest.body), {
      playmeshGameInvitationTokenParameter: invitation.inviteToken,
    });
    expect(result.invitation, same(invitation));
    expect(result.gameId, 'com.example.game');
    expect(result.gameName, '示例游戏');
    expect(result.resolvedEntryPath, '/controller/index.html');

    await inspector.close();
    expect(client.closeCount, 1);
  });

  test('Relay 预检复用 Web 回环 token 并把成功会话移交给导航', () async {
    final gateway = _FakeRelayGateway(
      Uri.parse(
        'http://127.0.0.1:34567$playmeshGameInvitationPath'
        '#inviteToken=authority-share-token',
      ),
    );
    final session = _FakeRelaySession(gateway);
    late Uri factoryInvitation;
    late Uri factoryCoreBase;
    late http.AbortableRequest sentRequest;
    final client = _RecordingClient((request) async {
      sentRequest = request as http.AbortableRequest;
      return _jsonResponse(_validResponseBody());
    });
    final inspector = DefaultGameInvitationInspector(
      coreBaseUri: Uri.parse('http://127.0.0.1:39001/'),
      httpClient: client,
      relayClientSessionFactory:
          ({required coreBaseUri, required invitationUri}) async {
            factoryInvitation = invitationUri;
            factoryCoreBase = coreBaseUri;
            return session;
          },
    );
    final invitation = GameInvitation.parse(
      'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
    );

    final result = await inspector.inspect(invitation);

    expect(factoryInvitation, invitation.entryUri);
    expect(factoryCoreBase, Uri.parse('http://127.0.0.1:39001/'));
    expect(
      sentRequest.url,
      Uri.parse('http://127.0.0.1:34567$playmeshGameInvitationPath'),
    );
    expect(jsonDecode(sentRequest.body), {
      playmeshGameInvitationTokenParameter: 'authority-share-token',
    });
    expect(result.invitation, same(invitation));
    expect(result.resolvedEntryPath, '/controller/index.html');
    expect(session.closeCount, 0, reason: '成功预检不能关闭随后导航还要使用的会话');
    expect(result.takeRelayClientSession(), same(session));
    expect(result.takeRelayClientSession(), isNull, reason: '连接只能移交一次');
    await session.close();
    await inspector.close();
  });

  test('Relay HTTP 失败也在 finally 关闭临时网关', () async {
    final gateway = _FakeRelayGateway(
      Uri.parse(
        'http://127.0.0.1:34567$playmeshGameInvitationPath'
        '#inviteToken=authority-share-token',
      ),
    );
    final session = _FakeRelaySession(gateway);
    final inspector = DefaultGameInvitationInspector(
      coreBaseUri: Uri.parse('http://127.0.0.1:39001/'),
      httpClient: _RecordingClient(
        (_) async => _jsonResponse(_validResponseBody(), statusCode: 403),
      ),
      relayClientSessionFactory:
          ({required coreBaseUri, required invitationUri}) async => session,
    );

    await expectLater(
      inspector.inspect(
        GameInvitation.parse(
          'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
        ),
      ),
      _inspectionFailure(GameInvitationInspectionFailure.invalidResponse),
    );

    expect(session.closeCount, 1);
    await inspector.close();
  });

  test('Relay 预检在每次加入时读取当前 Go Core 动态端口', () async {
    var currentCoreBaseUri = Uri.parse('http://127.0.0.1:0/');
    late Uri factoryCoreBaseUri;
    final gateway = _FakeRelayGateway(
      Uri.parse(
        'http://127.0.0.1:34567$playmeshGameInvitationPath'
        '#inviteToken=authority-share-token',
      ),
    );
    final session = _FakeRelaySession(gateway);
    final inspector = DefaultGameInvitationInspector(
      coreBaseUriProvider: () => currentCoreBaseUri,
      httpClient: _RecordingClient(
        (_) async => _jsonResponse(_validResponseBody()),
      ),
      relayClientSessionFactory:
          ({required coreBaseUri, required invitationUri}) async {
            factoryCoreBaseUri = coreBaseUri;
            return session;
          },
    );
    currentCoreBaseUri = Uri.parse('http://127.0.0.1:39002/');

    final inspected = await inspector.inspect(
      GameInvitation.parse(
        'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
      ),
    );

    expect(factoryCoreBaseUri, currentCoreBaseUri);
    await inspected.close();
    await inspector.close();
  });

  test('Relay 缺少 Go Core 时保留原始 UnsupportedError', () async {
    final inspector = DefaultGameInvitationInspector();

    try {
      await inspector.inspect(
        GameInvitation.parse(
          'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
        ),
      );
      fail('inspect should throw');
    } on GameInvitationInspectionException catch (error) {
      expect(error.failure, GameInvitationInspectionFailure.unavailable);
      expect(error.cause, isA<UnsupportedError>());
      expect(error.toString(), contains('UnsupportedError'));
      expect(error.toString(), contains('当前加入入口没有可用的 Go Core'));
    } finally {
      await inspector.close();
    }
  });

  test('3xx 响应不跟随重定向并按无效响应拒绝', () async {
    late http.AbortableRequest sentRequest;
    final inspector = DefaultGameInvitationInspector(
      httpClient: _RecordingClient((request) async {
        sentRequest = request as http.AbortableRequest;
        return _jsonResponse(
          _validResponseBody(),
          statusCode: 302,
          headers: const {
            'content-type': 'application/json',
            'location': 'http://attacker.invalid/',
          },
        );
      }),
    );

    await expectLater(
      inspector.inspect(_lanInvitation()),
      _inspectionFailure(GameInvitationInspectionFailure.invalidResponse),
    );

    expect(sentRequest.followRedirects, isFalse);
    expect(sentRequest.maxRedirects, 0);
    await inspector.close();
  });

  test('整个发送和读取阶段共享同一个超时并触发请求取消', () async {
    late http.AbortableRequest sentRequest;
    final inspector = DefaultGameInvitationInspector(
      httpClient: _RecordingClient((request) {
        sentRequest = request as http.AbortableRequest;
        return Completer<http.StreamedResponse>().future;
      }),
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      inspector.inspect(_lanInvitation()),
      _inspectionFailure(GameInvitationInspectionFailure.timedOut),
    );
    await sentRequest.abortTrigger;
    await inspector.close();
  });

  test('无 Content-Length 的响应正文也严格限制为 4 KiB', () async {
    final inspector = DefaultGameInvitationInspector(
      httpClient: _RecordingClient(
        (_) async => http.StreamedResponse(
          Stream.value(
            List<int>.filled(
              maxGameInvitationInspectionResponseBytes + 1,
              0x20,
            ),
          ),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      inspector.inspect(_lanInvitation()),
      _inspectionFailure(GameInvitationInspectionFailure.invalidResponse),
    );
    await inspector.close();
  });

  test('严格拒绝非 JSON、缺字段和不受控 entry', () async {
    final responses = <http.StreamedResponse>[
      _jsonResponse(_validResponseBody(), headers: const {}),
      _jsonResponse('{not-json'),
      _jsonResponse(jsonEncode({'entry': '/controller/index.html'})),
      _jsonResponse(
        _validResponseBody(entry: 'https://attacker.invalid/index.html'),
      ),
      _jsonResponse(_validResponseBody(gameId: 'invalid game id')),
      _jsonResponse(_validResponseBody(gameName: '   ')),
    ];

    for (final response in responses) {
      final inspector = DefaultGameInvitationInspector(
        httpClient: _RecordingClient((_) async => response),
      );
      await expectLater(
        inspector.inspect(_lanInvitation()),
        _inspectionFailure(GameInvitationInspectionFailure.invalidResponse),
      );
      await inspector.close();
    }
  });

  test('关闭后的 Inspector 返回净化后的稳定失败', () async {
    final client = _RecordingClient((_) async => _jsonResponse('{}'));
    final inspector = DefaultGameInvitationInspector(httpClient: client);
    await inspector.close();

    await expectLater(
      inspector.inspect(_lanInvitation()),
      _inspectionFailure(GameInvitationInspectionFailure.closed),
    );
    expect(client.closeCount, 1);
  });
}

GameInvitation _lanInvitation({String host = '192.168.1.9'}) =>
    GameInvitation.parse(
      'http://$host:16667$playmeshGameInvitationPath'
      '#$playmeshGameInvitationTokenParameter=opaque-token',
    );

String _validResponseBody({
  String entry = '/controller/index.html',
  String gameId = 'com.example.game',
  String gameName = '示例游戏',
}) => jsonEncode({'entry': entry, 'gameId': gameId, 'gameName': gameName});

http.StreamedResponse _jsonResponse(
  String body, {
  int statusCode = 200,
  Map<String, String> headers = const {
    'content-type': 'application/json; charset=utf-8',
  },
}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream.value(bytes),
    statusCode,
    headers: headers,
    contentLength: bytes.length,
  );
}

Matcher _inspectionFailure(GameInvitationInspectionFailure failure) => throwsA(
  isA<GameInvitationInspectionException>().having(
    (error) => error.failure,
    'failure',
    failure,
  ),
);

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._send);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _send;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _send(request);

  @override
  void close() {
    closeCount += 1;
  }
}

class _FakeRelayGateway implements RelayClientGateway {
  _FakeRelayGateway(this.localEntryUri);

  @override
  final Uri localEntryUri;

  int closeCount = 0;

  @override
  Uri get localBaseUri => Uri(
    scheme: localEntryUri.scheme,
    host: localEntryUri.host,
    port: localEntryUri.hasPort ? localEntryUri.port : null,
  );

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

class _FakeRelaySession implements RelayClientSession {
  _FakeRelaySession(this.webGateway) : coreGateway = webGateway;

  @override
  final RelayClientGateway webGateway;

  @override
  final RelayClientGateway coreGateway;

  int closeCount = 0;

  @override
  String get connectionMode => 'relay';

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}
