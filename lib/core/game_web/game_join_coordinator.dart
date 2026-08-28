import '../../models/game_id.dart';
import '../diagnostics/playmesh_error_diagnostic.dart';
import '../network/lan_endpoint.dart';
import '../network/lan_game_join_candidate_source.dart';
import '../relay/relay_tunnel.dart';
import 'game_invitation.dart';
import 'game_invitation_inspector.dart';

typedef GameInvitationSelfMatcher = bool Function(GameInvitation invitation);
typedef GameJoinCancellationCheck = bool Function();

GameJoinErrorCode _joinErrorForInspection(
  GameInvitationInspectionFailure failure,
) => switch (failure) {
  GameInvitationInspectionFailure.invalidInvitation =>
    GameJoinErrorCode.invalidInvitation,
  GameInvitationInspectionFailure.invalidResponse =>
    GameJoinErrorCode.invitationInvalidResponse,
  GameInvitationInspectionFailure.unavailable =>
    GameJoinErrorCode.invitationUnavailable,
  GameInvitationInspectionFailure.timedOut =>
    GameJoinErrorCode.invitationTimedOut,
  GameInvitationInspectionFailure.closed =>
    GameJoinErrorCode.invitationInspectionClosed,
};

class GameJoinContext {
  const GameJoinContext({
    this.expectedGameId,
    this.selfInstanceId,
    this.isSelfInvitation,
    this.isCancelled,
  });

  final String? expectedGameId;
  final String? selfInstanceId;
  final GameInvitationSelfMatcher? isSelfInvitation;
  final GameJoinCancellationCheck? isCancelled;
}

enum GameJoinErrorCode {
  invalidInvitation('invalid_invitation'),
  invitationInvalidResponse('invitation_invalid_response'),
  invitationUnavailable('invitation_unavailable'),
  invitationTimedOut('invitation_timed_out'),
  invitationInspectionClosed('invitation_inspection_closed'),
  gameMismatch('game_mismatch'),
  selfInvitation('self_invitation'),
  discoveryNotFound('discovery_not_found'),
  discoveryUnavailable('discovery_unavailable'),
  gameContextUnavailable('game_context_unavailable'),
  operationCancelled('operation_cancelled');

  const GameJoinErrorCode(this.wireValue);

  final String wireValue;
}

class GameJoinException implements Exception, PlaymeshDiagnosticError {
  const GameJoinException(
    this.error, {
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  final GameJoinErrorCode error;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  final Map<String, String> context;

  @override
  String get code => error.wireValue;

  @override
  String get message => switch (error) {
    GameJoinErrorCode.invalidInvitation => '游戏邀请无效',
    GameJoinErrorCode.invitationInvalidResponse => '游戏邀请响应无效',
    GameJoinErrorCode.invitationUnavailable => '游戏邀请入口不可用',
    GameJoinErrorCode.invitationTimedOut => '游戏邀请检查超时',
    GameJoinErrorCode.invitationInspectionClosed => '游戏邀请检查服务已关闭',
    GameJoinErrorCode.gameMismatch => '目标游戏与当前游戏不一致',
    GameJoinErrorCode.selfInvitation => '不能加入当前主机自己的对局',
    GameJoinErrorCode.discoveryNotFound => '附近对局已经失效',
    GameJoinErrorCode.discoveryUnavailable => '附近对局发现不可用',
    GameJoinErrorCode.gameContextUnavailable => '当前游戏上下文不可用',
    GameJoinErrorCode.operationCancelled => '加入操作已经取消',
  };

  @override
  String toString() => formatPlaymeshDiagnosticError(this);
}

class RemoteGameLaunch {
  RemoteGameLaunch({
    required this.invitation,
    required this.gameId,
    required this.gameName,
    this.sourceInstanceId,
    this.resolvedEntryPath,
    RelayClientSession? relayClientSession,
  }) : _relayClientSessionOwner = _RelayClientSessionOwner(relayClientSession);

  final GameInvitation invitation;
  final String gameId;
  final String gameName;
  final String? sourceInstanceId;
  final String? resolvedEntryPath;
  final _RelayClientSessionOwner _relayClientSessionOwner;

  Uri get entryUri => invitation.entryUri;

  bool get usesRelay => invitation.usesRelay;

  RelayClientSession? takeRelayClientSession() =>
      _relayClientSessionOwner.take();

  Future<void> close() async {
    final session = takeRelayClientSession();
    await session?.close();
  }

  @override
  String toString() => 'RemoteGameLaunch(gameId: $gameId)';
}

class _RelayClientSessionOwner {
  _RelayClientSessionOwner(this._session);

  RelayClientSession? _session;

  RelayClientSession? take() {
    final session = _session;
    _session = null;
    return session;
  }
}

abstract interface class GameJoinPreparationService {
  Future<RemoteGameLaunch> prepareLink(
    String invitationUrl, {
    required GameJoinContext context,
  });

  Future<RemoteGameLaunch> prepareDiscovered(
    String instanceId, {
    required GameJoinContext context,
  });
}

class GameJoinCoordinator implements GameJoinPreparationService {
  factory GameJoinCoordinator({
    required GameInvitationInspector inspector,
    LanGameJoinCandidateSource? discoveredGames,
  }) => GameJoinCoordinator._(inspector, discoveredGames);

  const GameJoinCoordinator._(this._inspector, this._discoveredGames);

  final GameInvitationInspector _inspector;
  final LanGameJoinCandidateSource? _discoveredGames;

  @override
  Future<RemoteGameLaunch> prepareLink(
    String invitationUrl, {
    required GameJoinContext context,
  }) async {
    _validateContext(context);
    _throwIfCancelled(context);
    late final GameInvitation invitation;
    try {
      invitation = GameInvitation.parse(invitationUrl);
    } on FormatException catch (error, stackTrace) {
      throw GameJoinException(
        GameJoinErrorCode.invalidInvitation,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'prepare_link'},
      );
    }
    return prepareInvitation(invitation, context: context);
  }

  Future<RemoteGameLaunch> prepareInvitation(
    GameInvitation invitation, {
    required GameJoinContext context,
  }) async {
    _validateContext(context);
    _throwIfCancelled(context);
    if (_matchesSelf(invitation, context)) {
      throw const GameJoinException(GameJoinErrorCode.selfInvitation);
    }
    late final InspectedGameInvitation inspected;
    try {
      inspected = await _inspector.inspect(invitation);
    } on GameInvitationInspectionException catch (error, stackTrace) {
      throw GameJoinException(
        _joinErrorForInspection(error.failure),
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'prepare_invitation'},
      );
    } on Object catch (error, stackTrace) {
      throw GameJoinException(
        GameJoinErrorCode.invitationUnavailable,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'prepare_invitation'},
      );
    }
    try {
      _throwIfCancelled(context);
      if (inspected.invitation.entryUri != invitation.entryUri) {
        throw const GameJoinException(GameJoinErrorCode.invalidInvitation);
      }
      _ensureExpectedGame(inspected.gameId, context);
      return RemoteGameLaunch(
        invitation: invitation,
        gameId: inspected.gameId,
        gameName: inspected.gameName,
        resolvedEntryPath: inspected.resolvedEntryPath,
        relayClientSession: inspected.takeRelayClientSession(),
      );
    } finally {
      await inspected.close();
    }
  }

  @override
  Future<RemoteGameLaunch> prepareDiscovered(
    String instanceId, {
    required GameJoinContext context,
  }) async {
    _validateContext(context);
    _throwIfCancelled(context);
    if (instanceId.isEmpty) {
      throw const GameJoinException(GameJoinErrorCode.discoveryNotFound);
    }
    final source = _discoveredGames;
    if (source == null) {
      throw const GameJoinException(GameJoinErrorCode.discoveryUnavailable);
    }
    late final LanGameJoinCandidateSet? target;
    try {
      target = source.findJoinCandidates(instanceId);
    } on LanGameJoinSourceUnavailableException {
      throw const GameJoinException(GameJoinErrorCode.discoveryUnavailable);
    } on Object {
      throw const GameJoinException(GameJoinErrorCode.discoveryUnavailable);
    }
    if (target == null ||
        target.instanceId != instanceId ||
        target.candidates.isEmpty ||
        !isValidPlaymeshGameId(target.advertisedGameId)) {
      throw const GameJoinException(GameJoinErrorCode.discoveryNotFound);
    }
    if (context.selfInstanceId == instanceId) {
      throw const GameJoinException(GameJoinErrorCode.selfInvitation);
    }

    var sawGameMismatch = false;
    for (final candidate in sortLanEndpointCandidates(target.candidates)) {
      _throwIfCancelled(context);
      late final GameInvitation invitation;
      try {
        invitation = GameInvitation.parse(candidate.uri.toString());
      } on FormatException {
        continue;
      }
      // 组播发现只接受 LAN HTTP 入口，Relay 候选不能由局域网元数据注入。
      if (invitation.usesRelay) continue;
      if (_matchesSelf(invitation, context)) {
        throw const GameJoinException(GameJoinErrorCode.selfInvitation);
      }

      late final InspectedGameInvitation inspected;
      try {
        inspected = await _inspector.inspect(invitation);
      } on GameInvitationInspectionException {
        continue;
      } on Object {
        continue;
      }
      try {
        _throwIfCancelled(context);
        if (inspected.invitation.entryUri != invitation.entryUri) continue;
        _ensureDiscoveredCandidateIsCurrent(
          source,
          target: target,
          invitation: invitation,
        );
        if (inspected.gameId != target.advertisedGameId ||
            (context.expectedGameId != null &&
                inspected.gameId != context.expectedGameId)) {
          sawGameMismatch = true;
          continue;
        }
        return RemoteGameLaunch(
          invitation: invitation,
          gameId: inspected.gameId,
          gameName: inspected.gameName,
          sourceInstanceId: instanceId,
          resolvedEntryPath: inspected.resolvedEntryPath,
          relayClientSession: inspected.takeRelayClientSession(),
        );
      } finally {
        await inspected.close();
      }
    }
    throw GameJoinException(
      sawGameMismatch
          ? GameJoinErrorCode.gameMismatch
          : GameJoinErrorCode.discoveryNotFound,
    );
  }

  void _validateContext(GameJoinContext context) {
    final expectedGameId = context.expectedGameId;
    final selfInstanceId = context.selfInstanceId;
    if ((expectedGameId != null && !isValidPlaymeshGameId(expectedGameId)) ||
        (selfInstanceId != null && selfInstanceId.isEmpty)) {
      throw const GameJoinException(GameJoinErrorCode.gameContextUnavailable);
    }
  }

  void _ensureExpectedGame(String gameId, GameJoinContext context) {
    final expectedGameId = context.expectedGameId;
    if (expectedGameId != null && gameId != expectedGameId) {
      throw const GameJoinException(GameJoinErrorCode.gameMismatch);
    }
  }

  void _ensureDiscoveredCandidateIsCurrent(
    LanGameJoinCandidateSource source, {
    required LanGameJoinCandidateSet target,
    required GameInvitation invitation,
  }) {
    late final LanGameJoinCandidateSet? current;
    try {
      current = source.findJoinCandidates(target.instanceId);
    } on LanGameJoinSourceUnavailableException {
      throw const GameJoinException(GameJoinErrorCode.discoveryUnavailable);
    } on Object {
      throw const GameJoinException(GameJoinErrorCode.discoveryUnavailable);
    }
    final stillCurrent =
        current != null &&
        current.advertisedGameId == target.advertisedGameId &&
        current.candidates.any(
          (candidate) => candidate.uri == invitation.entryUri,
        );
    if (!stillCurrent) {
      throw const GameJoinException(GameJoinErrorCode.discoveryNotFound);
    }
  }

  bool _matchesSelf(GameInvitation invitation, GameJoinContext context) {
    final matcher = context.isSelfInvitation;
    if (matcher == null) return false;
    try {
      return matcher(invitation);
    } on Object {
      throw const GameJoinException(GameJoinErrorCode.gameContextUnavailable);
    }
  }

  void _throwIfCancelled(GameJoinContext context) {
    final isCancelled = context.isCancelled;
    if (isCancelled == null) return;
    try {
      if (!isCancelled()) return;
    } on Object {
      throw const GameJoinException(GameJoinErrorCode.gameContextUnavailable);
    }
    throw const GameJoinException(GameJoinErrorCode.operationCancelled);
  }
}
