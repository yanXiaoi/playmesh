import 'dart:convert';

enum GDevelopAiEventType {
  sessionUpdated('gdevelop.ai.session.updated'),
  turnCreated('gdevelop.ai.turn.created'),
  callUpdated('gdevelop.ai.call.updated');

  const GDevelopAiEventType(this.wireName);

  final String wireName;
}

enum GDevelopAiSessionEventState {
  opened('opened'),
  updated('updated'),
  closed('closed');

  const GDevelopAiSessionEventState(this.wireName);

  final String wireName;
}

/// Minimal wake-up DTO for one exact GDevelop project/editor session.
///
/// It intentionally has no extension map: arguments, output, errors, project
/// content and timestamps cannot enter the serialized shape.
final class GDevelopAiEvent {
  GDevelopAiEvent._({
    required this.type,
    required this.gameId,
    required this.editorSessionId,
    required this.sequence,
    this.turnId,
    this.callId,
    this.state,
  }) {
    if (!_gameIdPattern.hasMatch(gameId) ||
        !_sessionIdPattern.hasMatch(editorSessionId) ||
        sequence < 0 ||
        (turnId != null && !_pathIdPattern.hasMatch(turnId!)) ||
        (callId != null && !_pathIdPattern.hasMatch(callId!)) ||
        (state != null && !_statePattern.hasMatch(state!))) {
      throw const FormatException('GDevelop AI event identity/state invalid');
    }
    final keys = toJson().keys.toSet();
    if (keys.difference(allowedKeys).isNotEmpty || encodedBytes > maxBytes) {
      throw const FormatException('GDevelop AI event payload too large');
    }
  }

  factory GDevelopAiEvent.sessionUpdated({
    required String gameId,
    required String editorSessionId,
    required int sequence,
    required GDevelopAiSessionEventState state,
  }) => GDevelopAiEvent._(
    type: GDevelopAiEventType.sessionUpdated,
    gameId: gameId,
    editorSessionId: editorSessionId,
    sequence: sequence,
    state: state.wireName,
  );

  factory GDevelopAiEvent.turnCreated({
    required String gameId,
    required String editorSessionId,
    required int sequence,
    required String turnId,
  }) => GDevelopAiEvent._(
    type: GDevelopAiEventType.turnCreated,
    gameId: gameId,
    editorSessionId: editorSessionId,
    sequence: sequence,
    turnId: turnId,
  );

  factory GDevelopAiEvent.callUpdated({
    required String gameId,
    required String editorSessionId,
    required int sequence,
    required String turnId,
    required String callId,
    required String state,
  }) => GDevelopAiEvent._(
    type: GDevelopAiEventType.callUpdated,
    gameId: gameId,
    editorSessionId: editorSessionId,
    sequence: sequence,
    turnId: turnId,
    callId: callId,
    state: state,
  );

  static const maxBytes = 2048;
  static const allowedKeys = {
    'type',
    'gameId',
    'editorSessionId',
    'sequence',
    'turnId',
    'callId',
    'state',
  };
  static final RegExp _gameIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );
  static final RegExp _sessionIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$',
  );
  static final RegExp _pathIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,511}$',
  );
  static final RegExp _statePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  final GDevelopAiEventType type;
  final String gameId;
  final String editorSessionId;
  final int sequence;
  final String? turnId;
  final String? callId;
  final String? state;

  int get encodedBytes => utf8.encode(jsonEncode(toJson())).length;

  Map<String, Object?> toJson() => {
    'type': type.wireName,
    'gameId': gameId,
    'editorSessionId': editorSessionId,
    'sequence': sequence,
    if (turnId != null) 'turnId': turnId,
    if (callId != null) 'callId': callId,
    if (state != null) 'state': state,
  };
}
