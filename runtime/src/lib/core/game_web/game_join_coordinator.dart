import '../../models/game_id.dart';
import '../network/lan_endpoint.dart';
import '../network/lan_game_join_candidate_source.dart';
import 'game_invitation.dart';
import 'game_invitation_inspector.dart';

typedef GameInvitationSelfMatcher = bool Function(GameInvitation invitation);
typedef GameJoinCancellationCheck = bool Function();

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
  gameMismatch('game_mismatch'),
  selfInvitation('self_invitation'),
  discoveryNotFound('discovery_not_found'),
  discoveryUnavailable('discovery_unavailable'),
  gameContextUnavailable('game_context_unavailable'),
  operationCancelled('operation_cancelled');

  const GameJoinErrorCode(this.wireValue);

  final String wireValue;
}

class GameJoinException implements Exception {
  const GameJoinException(this.error);

  final GameJoinErrorCode error;

  String get code => error.wireValue;

  String get message => switch (error) {
    GameJoinErrorCode.invalidInvitation => '游戏邀请无效',
    GameJoinErrorCode.gameMismatch => '目标游戏与当前游戏不一致',
    GameJoinErrorCode.selfInvitation => '不能加入当前主机自己的对局',
    GameJoinErrorCode.discoveryNotFound => '附近对局已经失效',
    GameJoinErrorCode.discoveryUnavailable => '附近对局发现不可用',
    GameJoinErrorCode.gameContextUnavailable => '当前游戏上下文不可用',
    GameJoinErrorCode.operationCancelled => '加入操作已经取消',
  };

  @override
  String toString() => message;
}

class RemoteGameLaunch {
  const RemoteGameLaunch({
    required this.invitation,
    required this.gameId,
    required this.gameName,
    this.sourceInstanceId,
  });

  final GameInvitation invitation;
  final String gameId;
  final String gameName;
  final String? sourceInstanceId;

  Uri get entryUri => invitation.entryUri;

  bool get usesRelay => invitation.usesRelay;

  @override
  String toString() => 'RemoteGameLaunch(gameId: $gameId)';
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
    } on FormatException {
      throw const GameJoinException(GameJoinErrorCode.invalidInvitation);
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
    } on GameInvitationInspectionException {
      throw const GameJoinException(GameJoinErrorCode.invalidInvitation);
    } on Object {
      throw const GameJoinException(GameJoinErrorCode.invalidInvitation);
    }
    _throwIfCancelled(context);
    if (inspected.invitation.entryUri != invitation.entryUri) {
      throw const GameJoinException(GameJoinErrorCode.invalidInvitation);
    }
    _ensureExpectedGame(inspected.gameId, context);
    return RemoteGameLaunch(
      invitation: invitation,
      gameId: inspected.gameId,
      gameName: inspected.gameName,
    );
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
      );
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
