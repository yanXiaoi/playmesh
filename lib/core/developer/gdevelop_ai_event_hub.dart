import 'dart:async';
import 'dart:collection';

import 'gdevelop_ai_event.dart';
import 'gdevelop_ai_feature_policy.dart';
import 'gdevelop_ai_session_service.dart';

/// Bounded, in-process journal and fan-out for the scoped GDevelop AI SSE.
/// The domain service can always report its own state transitions, while this
/// boundary emits nothing unless the shared rollout policy is enabled.
final class GDevelopAiEventHub {
  GDevelopAiEventHub({
    required this.policy,
    required GDevelopAiSessionService sessions,
    this.maxScopes = 128,
    this.maxEventsPerScope = 256,
  }) {
    if (maxScopes < 1 || maxEventsPerScope < 1) {
      throw const FormatException('GDevelop AI event journal bounds invalid');
    }
    _subscription = sessions.aiEvents.listen(_accept);
  }

  final GDevelopAiFeaturePolicy policy;
  final int maxScopes;
  final int maxEventsPerScope;
  final LinkedHashMap<String, List<GDevelopAiEvent>> _journals =
      LinkedHashMap<String, List<GDevelopAiEvent>>();
  final StreamController<GDevelopAiEvent> _events =
      StreamController<GDevelopAiEvent>.broadcast(sync: true);
  late final StreamSubscription<GDevelopAiEvent> _subscription;
  bool _disposed = false;

  Stream<GDevelopAiEvent> get events => _events.stream;

  List<GDevelopAiEvent> replay({
    required String gameId,
    required String editorSessionId,
    required int afterSequence,
  }) {
    if (afterSequence < 0) {
      throw const FormatException('GDevelop AI event afterSequence invalid');
    }
    final journal = _journals[_scopeKey(gameId, editorSessionId)];
    if (journal == null) return const [];
    return List.unmodifiable(
      journal.where((event) => event.sequence > afterSequence),
    );
  }

  void _accept(GDevelopAiEvent event) {
    if (_disposed || !policy.enabled) return;
    if (event.encodedBytes > GDevelopAiEvent.maxBytes) return;
    final key = _scopeKey(event.gameId, event.editorSessionId);
    var journal = _journals[key];
    if (journal == null) {
      if (_journals.length >= maxScopes) {
        _journals.remove(_journals.keys.first);
      }
      journal = <GDevelopAiEvent>[];
      _journals[key] = journal;
    }
    if (journal.isNotEmpty && event.sequence <= journal.last.sequence) return;
    journal.add(event);
    if (journal.length > maxEventsPerScope) journal.removeAt(0);
    try {
      _events.add(event);
    } on Object {
      // A diagnostics listener cannot affect the authoritative call/session
      // state that was already committed before this wake-up hint.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _journals.clear();
    await _events.close();
  }

  String _scopeKey(String gameId, String editorSessionId) =>
      '$gameId\u0000$editorSessionId';
}
