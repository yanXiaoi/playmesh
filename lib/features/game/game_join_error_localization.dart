import '../../core/game_web/game_join_coordinator.dart';

String gameJoinErrorLocalizationKey(GameJoinException error) =>
    switch (error.error) {
      GameJoinErrorCode.invalidInvitation => 'join.invalid_invite',
      GameJoinErrorCode.gameMismatch => 'join.game_mismatch',
      GameJoinErrorCode.selfInvitation => 'join.self_invitation',
      GameJoinErrorCode.discoveryNotFound => 'join.discovery_not_found',
      GameJoinErrorCode.discoveryUnavailable => 'join.nearby_failed',
      GameJoinErrorCode.gameContextUnavailable =>
        'join.game_context_unavailable',
      GameJoinErrorCode.operationCancelled => 'join.cancelled',
    };
