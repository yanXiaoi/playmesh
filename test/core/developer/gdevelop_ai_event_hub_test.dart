import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_event.dart';
import 'package:playmesh/core/developer/gdevelop_ai_event_hub.dart';
import 'package:playmesh/core/developer/gdevelop_ai_feature_policy.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

final _webIdeToolRegistry = loadGDevelopAiToolRegistryForTest();

void main() {
  const projectHash =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  group('GDevelopAiEvent', () {
    test('serializes only the exact minimal keys for every event kind', () {
      final session = GDevelopAiEvent.sessionUpdated(
        gameId: 'game-a',
        editorSessionId: 'session-a',
        sequence: 7,
        state: GDevelopAiSessionEventState.updated,
      );
      final turn = GDevelopAiEvent.turnCreated(
        gameId: 'game-a',
        editorSessionId: 'session-a',
        sequence: 8,
        turnId: 'turn-a',
      );
      final call = GDevelopAiEvent.callUpdated(
        gameId: 'game-a',
        editorSessionId: 'session-a',
        sequence: 9,
        turnId: 'turn-a',
        callId: 'call-a',
        state: 'running',
      );

      expect(session.toJson(), {
        'type': 'gdevelop.ai.session.updated',
        'gameId': 'game-a',
        'editorSessionId': 'session-a',
        'sequence': 7,
        'state': 'updated',
      });
      expect(turn.toJson(), {
        'type': 'gdevelop.ai.turn.created',
        'gameId': 'game-a',
        'editorSessionId': 'session-a',
        'sequence': 8,
        'turnId': 'turn-a',
      });
      expect(call.toJson(), {
        'type': 'gdevelop.ai.call.updated',
        'gameId': 'game-a',
        'editorSessionId': 'session-a',
        'sequence': 9,
        'turnId': 'turn-a',
        'callId': 'call-a',
        'state': 'running',
      });

      const forbiddenKeys = {
        'args',
        'arguments',
        'output',
        'commit',
        'error',
        'project',
      };
      for (final event in [session, turn, call]) {
        expect(
          event.toJson().keys.toSet().difference(GDevelopAiEvent.allowedKeys),
          isEmpty,
        );
        expect(
          event.toJson().keys.toSet().intersection(forbiddenKeys),
          isEmpty,
        );
        expect(event.encodedBytes, lessThanOrEqualTo(GDevelopAiEvent.maxBytes));
      }
    });
  });

  group('GDevelopAiEventHub', () {
    test('replay is isolated to the exact game and editor session', () {
      final sessions = GDevelopAiSessionService();
      addTearDown(sessions.dispose);
      final hub = GDevelopAiEventHub(
        policy: const GDevelopAiFeaturePolicy.testOverride(enabled: true),
        sessions: sessions,
      );
      addTearDown(hub.dispose);

      final gameAFirst = _open(sessions, 'game-a', projectHash);
      final gameASecond = _open(sessions, 'game-a', projectHash);
      final gameB = _open(sessions, 'game-b', projectHash);
      sessions.createTurn(gameAFirst.id);
      sessions.createTurn(gameASecond.id);
      sessions.createTurn(gameB.id);

      final gameAFirstEvents = hub.replay(
        gameId: 'game-a',
        editorSessionId: gameAFirst.id,
        afterSequence: 0,
      );
      expect(gameAFirstEvents, hasLength(1));
      expect(
        gameAFirstEvents.every(
          (event) =>
              event.gameId == 'game-a' &&
              event.editorSessionId == gameAFirst.id,
        ),
        isTrue,
      );
      expect(
        hub.replay(
          gameId: 'game-a',
          editorSessionId: gameB.id,
          afterSequence: 0,
        ),
        isEmpty,
      );
      expect(
        hub.replay(
          gameId: 'game-b',
          editorSessionId: gameAFirst.id,
          afterSequence: 0,
        ),
        isEmpty,
      );
      expect(
        hub
            .replay(
              gameId: 'game-a',
              editorSessionId: gameASecond.id,
              afterSequence: 0,
            )
            .single
            .editorSessionId,
        gameASecond.id,
      );
    });

    test('sequence cursors reconnect without duplicates or stale events', () {
      final sessions = GDevelopAiSessionService();
      addTearDown(sessions.dispose);
      final hub = GDevelopAiEventHub(
        policy: const GDevelopAiFeaturePolicy.testOverride(enabled: true),
        sessions: sessions,
      );
      addTearDown(hub.dispose);
      final observed = <GDevelopAiEvent>[];
      final subscription = hub.events.listen(observed.add);
      addTearDown(subscription.cancel);

      final session = _open(sessions, 'game-a', projectHash);
      final first = sessions.createTurn(
        session.id,
        clientMessageId: 'message-1',
      );
      sessions.createTurn(session.id, clientMessageId: 'message-2');

      expect(
        hub
            .replay(
              gameId: 'game-a',
              editorSessionId: session.id,
              afterSequence: 0,
            )
            .map((event) => event.sequence),
        [1, 2],
      );

      final idempotentReplay = sessions.createTurn(
        session.id,
        clientMessageId: 'message-1',
      );
      expect(idempotentReplay.id, first.id);
      sessions.createTurn(session.id, clientMessageId: 'message-3');

      expect(
        hub
            .replay(
              gameId: 'game-a',
              editorSessionId: session.id,
              afterSequence: 2,
            )
            .map((event) => event.sequence),
        [3],
      );
      expect(
        hub.replay(
          gameId: 'game-a',
          editorSessionId: session.id,
          afterSequence: 3,
        ),
        isEmpty,
      );
      expect(observed.map((event) => event.sequence), [0, 1, 2, 3]);
      expect(
        observed.map((event) => event.sequence).toSet(),
        hasLength(observed.length),
      );
    });

    test('journals are bounded per scope and by total scope count', () {
      final sessions = GDevelopAiSessionService();
      addTearDown(sessions.dispose);
      final hub = GDevelopAiEventHub(
        policy: const GDevelopAiFeaturePolicy.testOverride(enabled: true),
        sessions: sessions,
        maxScopes: 2,
        maxEventsPerScope: 3,
      );
      addTearDown(hub.dispose);

      final first = _open(sessions, 'game-a', projectHash);
      for (var index = 0; index < 4; index += 1) {
        sessions.createTurn(first.id, clientMessageId: 'first-$index');
      }
      expect(
        hub
            .replay(
              gameId: 'game-a',
              editorSessionId: first.id,
              afterSequence: 0,
            )
            .map((event) => event.sequence),
        [2, 3, 4],
      );

      final second = _open(sessions, 'game-b', projectHash);
      final third = _open(sessions, 'game-c', projectHash);
      sessions.createTurn(second.id);
      sessions.createTurn(third.id);
      expect(
        hub.replay(
          gameId: 'game-a',
          editorSessionId: first.id,
          afterSequence: 0,
        ),
        isEmpty,
      );
      expect(
        hub.replay(
          gameId: 'game-b',
          editorSessionId: second.id,
          afterSequence: 0,
        ),
        isNotEmpty,
      );
      expect(
        hub.replay(
          gameId: 'game-c',
          editorSessionId: third.id,
          afterSequence: 0,
        ),
        isNotEmpty,
      );
    });

    test('disabled production policy emits and retains no external events', () {
      final sessions = GDevelopAiSessionService();
      addTearDown(sessions.dispose);
      final hub = GDevelopAiEventHub(
        policy: const GDevelopAiFeaturePolicy.disabled(),
        sessions: sessions,
      );
      addTearDown(hub.dispose);
      final observed = <GDevelopAiEvent>[];
      final subscription = hub.events.listen(observed.add);
      addTearDown(subscription.cancel);

      final session = _open(sessions, 'game-a', projectHash);
      sessions.createTurn(session.id);
      sessions.close(session.id);

      expect(observed, isEmpty);
      expect(
        hub.replay(
          gameId: 'game-a',
          editorSessionId: session.id,
          afterSequence: 0,
        ),
        isEmpty,
      );
    });
  });
}

GDevelopAiEditorSession _open(
  GDevelopAiSessionService service,
  String gameId,
  String _,
) => service.open(
  gameId: gameId,
  mode: GDevelopAiMode.chat,
  locale: 'en-US',
  registry: _webIdeToolRegistry,
);
