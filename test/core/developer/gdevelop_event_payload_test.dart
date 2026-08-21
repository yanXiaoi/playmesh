import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_event_payload.dart';

void main() {
  test('accepts frozen official AiGeneratedEventChange envelope', () {
    final raw = _validPayload();
    final payload = GDevelopEventPayload.parse(
      raw,
      encodedBytes: utf8.encode(jsonEncode(raw)).length,
    );

    expect(payload.sceneName, 'Current Scene');
    expect(payload.changes, hasLength(1));
    expect(payload.changes.single['operationName'], 'insert_at_end');
    expect(payload.encodedBytes, greaterThan(0));
    expect(GDevelopEventPayload.schemaJson['title'], 'GDevelopEventPayload');
  });

  test(
    'accepts official nullable, delete-event, and missing-resource DTOs',
    () {
      final raw = _validPayload();
      final change = _singleChange(raw)
        ..['operationName'] = 'delete_event'
        ..['operationTargetEvent'] = 'event-7'
        ..['isEventsJsonValid'] = null
        ..['generatedEvents'] = null
        ..['areEventsValid'] = null
        ..['extensionNames'] = null
        ..['missingResources'] = <Object?>[
          {'resourceName': 'player.png', 'resourceKind': 'image'},
        ];

      final parsed = GDevelopEventPayload.parse(
        raw,
        encodedBytes: utf8.encode(jsonEncode(raw)).length,
      );

      expect(change['operationName'], 'delete_event');
      expect(parsed.changes.single, containsPair('generatedEvents', null));
      expect(parsed.changes.single, containsPair('extensionNames', null));
      expect(parsed.changes.single['missingResources'], hasLength(1));
    },
  );

  test('rejects only explicit false validity markers', () {
    for (final field in ['isEventsJsonValid', 'areEventsValid']) {
      final raw = _validPayload();
      _singleChange(raw)[field] = false;
      _expectInvalid(raw, 'event_payload_invalid');
    }
  });

  test('rejects a bare EventsList instead of the frozen envelope', () {
    _expectCode(
      () =>
          GDevelopEventPayload.parse({'events': <Object?>[]}, encodedBytes: 13),
      'event_payload_invalid',
    );
  });

  test('rejects non-official operations and extra placement DTO fields', () {
    final unknownOperation = _validPayload();
    (_singleChange(unknownOperation))['operationName'] = 'custom_insert';
    _expectInvalid(unknownOperation, 'event_payload_operation_invalid');

    final placement = _validPayload();
    (_singleChange(placement))['placement'] = {'kind': 'after'};
    _expectInvalid(placement, 'event_payload_invalid');
  });

  test('passes generatedEvents through to the pinned official applier', () {
    final invalidJson = _validPayload();
    (_singleChange(invalidJson))['generatedEvents'] = '{';
    final objectRoot = _validPayload();
    (_singleChange(objectRoot))['generatedEvents'] = '{}';

    final parsedInvalid = GDevelopEventPayload.parse(
      invalidJson,
      encodedBytes: utf8.encode(jsonEncode(invalidJson)).length,
    );
    final parsedObject = GDevelopEventPayload.parse(
      objectRoot,
      encodedBytes: utf8.encode(jsonEncode(objectRoot)).length,
    );
    expect(parsedInvalid.changes.single['generatedEvents'], '{');
    expect(parsedObject.changes.single['generatedEvents'], '{}');
  });

  test('passes through URL, token-like, and bridge values', () {
    final payload = _validPayload();
    (_singleChange(payload))['diagnosticLines'] = [
      'https://example.invalid',
      '__playmeshBridge',
    ];
    (_singleChange(payload))['generatedEvents'] = jsonEncode([
      {
        'type': 'BuiltinCommonInstructions::Standard',
        'conditions': <Object?>[],
        'actions': <Object?>[],
        'authorization': 'Bearer private-token',
      },
    ]);

    final parsed = GDevelopEventPayload.parse(
      payload,
      encodedBytes: utf8.encode(jsonEncode(payload)).length,
    );
    expect(parsed.changes.single['diagnosticLines'], [
      'https://example.invalid',
      '__playmeshBridge',
    ]);
  });

  test('does not impose Playmesh byte, depth, or change-count limits', () {
    Object? nested = 'leaf';
    for (var index = 0; index < 64; index++) {
      nested = <Object?>[nested];
    }
    final payload = _validPayload();
    final change = _singleChange(payload);
    change['generatedEvents'] = jsonEncode([nested]);
    change['diagnosticLines'] = ['x' * (600 * 1024)];
    final encodedBytes = utf8.encode(jsonEncode(payload)).length;

    final parsed = GDevelopEventPayload.parse(
      payload,
      encodedBytes: encodedBytes,
    );
    expect(encodedBytes, greaterThan(512 * 1024));
    expect(
      ((parsed.changes.first['diagnosticLines'] as List).single as String)
          .length,
      600 * 1024,
    );

    final manyChanges = _validPayload();
    final smallChange = _singleChange(manyChanges);
    manyChanges['changes'] = List<Object?>.generate(
      300,
      (_) => Map<String, Object?>.from(smallChange),
    );
    final manyParsed = GDevelopEventPayload.parse(
      manyChanges,
      encodedBytes: utf8.encode(jsonEncode(manyChanges)).length,
    );
    expect(manyParsed.changes, hasLength(300));
    expect(
      ((GDevelopEventPayload.schemaJson['properties'] as Map)['changes']
          as Map),
      isNot(contains('maxItems')),
    );

    final emptyLongScenePayload = <String, Object?>{
      'schemaVersion': '1.0.0',
      'sceneName': List<String>.filled(4096, 'S').join(),
      'changes': <Object?>[],
    };
    final emptyLongSceneParsed = GDevelopEventPayload.parse(
      emptyLongScenePayload,
      encodedBytes: utf8.encode(jsonEncode(emptyLongScenePayload)).length,
    );
    expect(emptyLongSceneParsed.sceneName, hasLength(4096));
    expect(emptyLongSceneParsed.changes, isEmpty);
    final eventSchemaProperties =
        GDevelopEventPayload.schemaJson['properties'] as Map;
    expect(eventSchemaProperties['sceneName'], isNot(contains('maxLength')));
    expect(eventSchemaProperties['changes'], isNot(contains('minItems')));
  });
}

Map<String, Object?> _validPayload() => {
  'schemaVersion': '1.0.0',
  'sceneName': 'Current Scene',
  'changes': <Object?>[
    <String, Object?>{
      'operationName': 'insert_at_end',
      'operationTargetEvent': null,
      'isEventsJsonValid': true,
      'generatedEvents': jsonEncode([
        {
          'type': 'BuiltinCommonInstructions::Standard',
          'conditions': <Object?>[],
          'actions': <Object?>[],
        },
      ]),
      'areEventsValid': true,
      'extensionNames': <String>[],
      'diagnosticLines': <String>[],
      'undeclaredVariables': <Object?>[],
      'undeclaredObjectVariables': <String, Object?>{},
      'missingObjectBehaviors': <String, Object?>{},
      'missingResources': <Object?>[],
    },
  ],
};

Map<String, Object?> _singleChange(Map<String, Object?> payload) =>
    (payload['changes'] as List).single as Map<String, Object?>;

void _expectInvalid(Map<String, Object?> raw, String code) {
  _expectCode(
    () => GDevelopEventPayload.parse(
      raw,
      encodedBytes: utf8.encode(jsonEncode(raw)).length,
    ),
    code,
  );
}

void _expectCode(void Function() callback, String code) {
  expect(
    callback,
    throwsA(
      isA<GDevelopEventPayloadValidationException>().having(
        (error) => error.code,
        'code',
        code,
      ),
    ),
  );
}
