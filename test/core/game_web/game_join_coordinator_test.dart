import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_invitation.dart';
import 'package:playmesh/core/game_web/game_invitation_inspector.dart';
import 'package:playmesh/core/game_web/game_join_coordinator.dart';
import 'package:playmesh/core/game_web/game_web_gateway_contract.dart';
import 'package:playmesh/core/network/lan_endpoint.dart';
import 'package:playmesh/core/network/lan_game_join_candidate_source.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';

void main() {
  test('直接链接统一解析、预检并生成 RemoteGameLaunch', () async {
    final inspector = _FakeInspector(
      (invitation) async => _inspected(invitation),
    );
    final coordinator = GameJoinCoordinator(inspector: inspector);

    final launch = await coordinator.prepareLink(
      _lanUrl('192.168.1.9'),
      context: const GameJoinContext(expectedGameId: 'com.example.game'),
    );

    expect(inspector.calls, hasLength(1));
    expect(launch.gameId, 'com.example.game');
    expect(launch.gameName, '示例游戏');
    expect(launch.sourceInstanceId, isNull);
    expect(launch.entryUri, inspector.calls.single.entryUri);
    expect(launch.toString(), isNot(contains('opaque-token')));
  });

  test('Relay 成功预检把已建立会话和受控入口单次移交给 RemoteGameLaunch', () async {
    final session = _FakeRelayClientSession();
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector(
        (invitation) async => InspectedGameInvitation(
          invitation: invitation,
          gameId: 'com.example.game',
          gameName: '示例游戏',
          resolvedEntryPath: '/controller/index.html',
          relayClientSession: session,
        ),
      ),
    );

    final launch = await coordinator.prepareLink(
      'https://relay.example/j/room_123#inviteToken=relay-token',
      context: const GameJoinContext(expectedGameId: 'com.example.game'),
    );

    expect(launch.resolvedEntryPath, '/controller/index.html');
    expect(launch.takeRelayClientSession(), same(session));
    expect(launch.takeRelayClientSession(), isNull);
    await session.close();
  });

  test('Relay 预检后发现 gameId 不匹配时立即关闭未移交会话', () async {
    final session = _FakeRelayClientSession();
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector(
        (invitation) async => InspectedGameInvitation(
          invitation: invitation,
          gameId: 'com.example.other',
          gameName: '其他游戏',
          resolvedEntryPath: '/controller/index.html',
          relayClientSession: session,
        ),
      ),
    );

    await expectLater(
      coordinator.prepareLink(
        'https://relay.example/j/room_123#inviteToken=relay-token',
        context: const GameJoinContext(expectedGameId: 'com.example.game'),
      ),
      _joinFailure(GameJoinErrorCode.gameMismatch),
    );
    expect(session.closeCount, 1);
  });

  test('非法直接链接稳定映射为 invalid_invitation 且不预检', () async {
    final inspector = _FakeInspector(
      (invitation) async => _inspected(invitation),
    );
    final coordinator = GameJoinCoordinator(inspector: inspector);

    await expectLater(
      coordinator.prepareLink(
        'https://attacker.invalid/not-an-invitation',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.invalidInvitation),
    );
    expect(inspector.calls, isEmpty);
  });

  test('直接链接预检失败保留稳定错误码、原始异常和完整 cause 链', () async {
    final rootStack = StackTrace.fromString('root inspection stack');
    final root = UnsupportedError('当前加入入口没有可用的 Go Core');
    final inspectionError = GameInvitationInspectionException(
      GameInvitationInspectionFailure.unavailable,
      cause: root,
      causeStackTrace: rootStack,
      context: const {'operation': 'relay_inspection'},
    );
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector((_) async => throw inspectionError),
    );

    try {
      await coordinator.prepareLink(
        _lanUrl('192.168.1.9'),
        context: const GameJoinContext(),
      );
      fail('prepareLink should throw');
    } on GameJoinException catch (error) {
      expect(error.error, GameJoinErrorCode.invitationUnavailable);
      expect(error.code, 'invitation_unavailable');
      expect(error.cause, same(inspectionError));
      expect(error.toString(), contains('GameInvitationInspectionException'));
      expect(error.toString(), contains('UnsupportedError'));
      expect(error.toString(), contains('当前加入入口没有可用的 Go Core'));
      expect(error.toString(), contains('root inspection stack'));
    }
  });

  test('直接链接在创建 launch 前执行 expectedGameId 精确比较', () async {
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector(
        (invitation) async =>
            _inspected(invitation, gameId: 'com.example.Other'),
      ),
    );

    await expectLater(
      coordinator.prepareLink(
        _lanUrl('192.168.1.9'),
        context: const GameJoinContext(expectedGameId: 'com.example.other'),
      ),
      _joinFailure(GameJoinErrorCode.gameMismatch),
    );
  });

  test('宿主链接自加入在网络预检前拒绝', () async {
    final inspector = _FakeInspector(
      (invitation) async => _inspected(invitation),
    );
    final selfUri = GameInvitation.parse(_lanUrl('192.168.1.9')).entryUri;
    final coordinator = GameJoinCoordinator(inspector: inspector);

    await expectLater(
      coordinator.prepareLink(
        selfUri.toString(),
        context: GameJoinContext(
          isSelfInvitation: (invitation) => invitation.entryUri == selfUri,
        ),
      ),
      _joinFailure(GameJoinErrorCode.selfInvitation),
    );
    expect(inspector.calls, isEmpty);
  });

  test('发现加入按既有风险序尝试候选并在首个有效项停止', () async {
    final calls = <String>[];
    final inspector = _FakeInspector((invitation) async {
      calls.add(invitation.entryUri.host);
      if (invitation.entryUri.host == '192.168.1.20') {
        throw const GameInvitationInspectionException(
          GameInvitationInspectionFailure.unavailable,
        );
      }
      return _inspected(invitation);
    });
    final source = _FakeCandidateSource({
      'instance-remote': LanGameJoinCandidateSet(
        instanceId: 'instance-remote',
        advertisedGameId: 'com.example.game',
        candidates: [
          _candidate(
            '8.8.8.8',
            type: LanAddressType.publicIpv4,
            risk: LanEndpointRisk.high,
          ),
          _candidate(
            '100.64.1.3',
            type: LanAddressType.carrierGradeNatIpv4,
            risk: LanEndpointRisk.caution,
          ),
          _candidate(
            '192.168.1.20',
            type: LanAddressType.privateIpv4,
            risk: LanEndpointRisk.low,
          ),
        ],
      ),
    });
    final coordinator = GameJoinCoordinator(
      inspector: inspector,
      discoveredGames: source,
    );

    final launch = await coordinator.prepareDiscovered(
      'instance-remote',
      context: const GameJoinContext(expectedGameId: 'com.example.game'),
    );

    expect(calls, ['192.168.1.20', '100.64.1.3']);
    expect(launch.entryUri.host, '100.64.1.3');
    expect(launch.sourceInstanceId, 'instance-remote');
  });

  test('发现广告 gameId 与预检结果不一致时稳定拒绝', () async {
    final source = _singleTargetSource(advertisedGameId: 'com.advertised.game');
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector(
        (invitation) async => _inspected(invitation, gameId: 'com.actual.game'),
      ),
      discoveredGames: source,
    );

    await expectLater(
      coordinator.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.gameMismatch),
    );
  });

  test('发现预检结果与宿主 expectedGameId 不一致时稳定拒绝', () async {
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector(
        (invitation) async => _inspected(invitation, gameId: 'com.remote.game'),
      ),
      discoveredGames: _singleTargetSource(advertisedGameId: 'com.remote.game'),
    );

    await expectLater(
      coordinator.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(expectedGameId: 'com.current.game'),
      ),
      _joinFailure(GameJoinErrorCode.gameMismatch),
    );
  });

  test('发现候选全部不可达时映射为 discovery_not_found', () async {
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector((_) async {
        throw const GameInvitationInspectionException(
          GameInvitationInspectionFailure.timedOut,
        );
      }),
      discoveredGames: _singleTargetSource(),
    );

    await expectLater(
      coordinator.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.discoveryNotFound),
    );
  });

  test('预检期间丢失的短期发现映射不会生成过期 launch', () async {
    final source = _singleTargetSource();
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector((invitation) async {
        source.targets.clear();
        return _inspected(invitation);
      }),
      discoveredGames: source,
    );

    await expectLater(
      coordinator.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.discoveryNotFound),
    );
  });

  test('发现源失败、丢失与当前实例分别使用稳定错误', () async {
    final inspector = _FakeInspector(
      (invitation) async => _inspected(invitation),
    );
    final unavailable = GameJoinCoordinator(
      inspector: inspector,
      discoveredGames: _UnavailableCandidateSource(),
    );
    await expectLater(
      unavailable.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.discoveryUnavailable),
    );

    final missing = GameJoinCoordinator(
      inspector: inspector,
      discoveredGames: _FakeCandidateSource(const {}),
    );
    await expectLater(
      missing.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(),
      ),
      _joinFailure(GameJoinErrorCode.discoveryNotFound),
    );

    final self = GameJoinCoordinator(
      inspector: inspector,
      discoveredGames: _singleTargetSource(),
    );
    await expectLater(
      self.prepareDiscovered(
        'instance-remote',
        context: const GameJoinContext(selfInstanceId: 'instance-remote'),
      ),
      _joinFailure(GameJoinErrorCode.selfInvitation),
    );
  });

  test('异步预检后失效的 generation 映射为 operation_cancelled', () async {
    var cancelled = false;
    final coordinator = GameJoinCoordinator(
      inspector: _FakeInspector((invitation) async {
        cancelled = true;
        return _inspected(invitation);
      }),
    );

    await expectLater(
      coordinator.prepareLink(
        _lanUrl('192.168.1.9'),
        context: GameJoinContext(isCancelled: () => cancelled),
      ),
      _joinFailure(GameJoinErrorCode.operationCancelled),
    );
  });

  test('稳定错误 wire code 与 SDK 契约一致', () {
    expect(GameJoinErrorCode.values.map((value) => value.wireValue), [
      'invalid_invitation',
      'invitation_invalid_response',
      'invitation_unavailable',
      'invitation_timed_out',
      'invitation_inspection_closed',
      'game_mismatch',
      'self_invitation',
      'discovery_not_found',
      'discovery_unavailable',
      'game_context_unavailable',
      'operation_cancelled',
    ]);
  });
}

String _lanUrl(String host) =>
    'http://$host:16667$playmeshGameInvitationPath#inviteToken=opaque-token';

InspectedGameInvitation _inspected(
  GameInvitation invitation, {
  String gameId = 'com.example.game',
  String gameName = '示例游戏',
}) => InspectedGameInvitation(
  invitation: invitation,
  gameId: gameId,
  gameName: gameName,
);

LanEndpointCandidate _candidate(
  String host, {
  required LanAddressType type,
  required LanEndpointRisk risk,
}) => LanEndpointCandidate(
  uri: Uri.parse(_lanUrl(host)),
  interfaceName: host,
  interfaceIndex: 0,
  addressType: type,
  risk: risk,
);

_FakeCandidateSource _singleTargetSource({
  String advertisedGameId = 'com.example.game',
}) => _FakeCandidateSource({
  'instance-remote': LanGameJoinCandidateSet(
    instanceId: 'instance-remote',
    advertisedGameId: advertisedGameId,
    candidates: [
      _candidate(
        '192.168.1.20',
        type: LanAddressType.privateIpv4,
        risk: LanEndpointRisk.low,
      ),
    ],
  ),
});

Matcher _joinFailure(GameJoinErrorCode error) => throwsA(
  isA<GameJoinException>()
      .having((exception) => exception.error, 'error', error)
      .having((exception) => exception.code, 'code', error.wireValue),
);

class _FakeInspector implements GameInvitationInspector {
  _FakeInspector(this._inspect);

  final Future<InspectedGameInvitation> Function(GameInvitation invitation)
  _inspect;
  final List<GameInvitation> calls = [];

  @override
  Future<InspectedGameInvitation> inspect(GameInvitation invitation) {
    calls.add(invitation);
    return _inspect(invitation);
  }

  @override
  Future<void> close() async {}
}

class _FakeRelayClientSession implements RelayClientSession {
  _FakeRelayClientSession()
    : webGateway = _FakeRelayClientGateway(
        Uri.parse(
          'http://127.0.0.1:34567/playmesh/join#inviteToken=authority-token',
        ),
      ),
      coreGateway = _FakeRelayClientGateway(
        Uri.parse('http://127.0.0.1:34568/'),
      );

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

class _FakeRelayClientGateway implements RelayClientGateway {
  const _FakeRelayClientGateway(this.localEntryUri);

  @override
  final Uri localEntryUri;

  @override
  Uri get localBaseUri => Uri(
    scheme: localEntryUri.scheme,
    host: localEntryUri.host,
    port: localEntryUri.hasPort ? localEntryUri.port : null,
  );

  @override
  Future<void> close() async {}
}

class _FakeCandidateSource implements LanGameJoinCandidateSource {
  _FakeCandidateSource(this.targets);

  final Map<String, LanGameJoinCandidateSet> targets;

  @override
  LanGameJoinCandidateSet? findJoinCandidates(String instanceId) =>
      targets[instanceId];
}

class _UnavailableCandidateSource implements LanGameJoinCandidateSource {
  @override
  LanGameJoinCandidateSet? findJoinCandidates(String instanceId) =>
      throw const LanGameJoinSourceUnavailableException();
}
