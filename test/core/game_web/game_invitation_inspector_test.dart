import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_invitation_inspector.dart';
import 'package:playmesh/core/game_web/game_web_gateway_contract.dart';
import 'package:playmesh/core/relay/relay_tunnel_contract.dart';

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

    await inspector.close();
    expect(client.closeCount, 1);
  });

  test('Relay 预检复用 Web 回环 token 并始终关闭临时网关', () async {
    final gateway = _FakeRelayGateway(
      Uri.parse(
        'http://127.0.0.1:34567$playmeshGameInvitationPath'
        '#inviteToken=authority-share-token',
      ),
    );
    late Uri factoryInvitation;
    late RelayTarget factoryTarget;
    late http.AbortableRequest sentRequest;
    final client = _RecordingClient((request) async {
      sentRequest = request as http.AbortableRequest;
      return _jsonResponse(_validResponseBody());
    });
    final inspector = DefaultGameInvitationInspector(
      httpClient: client,
      relayClientGatewayFactory:
          ({required invitationUri, required target}) async {
            factoryInvitation = invitationUri;
            factoryTarget = target;
            return gateway;
          },
    );
    final invitation = GameInvitation.parse(
      'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
    );

    final result = await inspector.inspect(invitation);

    expect(factoryInvitation, invitation.entryUri);
    expect(factoryTarget, RelayTarget.web);
    expect(
      sentRequest.url,
      Uri.parse('http://127.0.0.1:34567$playmeshGameInvitationPath'),
    );
    expect(jsonDecode(sentRequest.body), {
      playmeshGameInvitationTokenParameter: 'authority-share-token',
    });
    expect(result.invitation, same(invitation));
    expect(gateway.closeCount, 1);
    await inspector.close();
  });

  test('Relay HTTP 失败也在 finally 关闭临时网关', () async {
    final gateway = _FakeRelayGateway(
      Uri.parse(
        'http://127.0.0.1:34567$playmeshGameInvitationPath'
        '#inviteToken=authority-share-token',
      ),
    );
    final inspector = DefaultGameInvitationInspector(
      httpClient: _RecordingClient(
        (_) async => _jsonResponse(_validResponseBody(), statusCode: 403),
      ),
      relayClientGatewayFactory:
          ({required invitationUri, required target}) async => gateway,
    );

    await expectLater(
      inspector.inspect(
        GameInvitation.parse(
          'https://relay.example/j/tunnel_123#inviteToken=opaque-relay-token',
        ),
      ),
      _inspectionFailure(GameInvitationInspectionFailure.invalidResponse),
    );

    expect(gateway.closeCount, 1);
    await inspector.close();
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
