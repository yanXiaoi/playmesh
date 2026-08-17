class GDevelopEventPayloadValidationException implements Exception {
  const GDevelopEventPayloadValidationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// An immutable inline payload carrying the official GDevelop
/// `AiGeneratedEventChange[]` input consumed by `applyEventsChanges`.
class GDevelopEventPayload {
  const GDevelopEventPayload._({
    required this.sceneName,
    required this.changes,
    required this.encodedBytes,
  });

  static const schemaVersion = '1.0.0';

  static const officialOperationNames = <String>{
    'delete_event',
    'insert_and_replace_event',
    'replace_entire_event_and_sub_events',
    'replace_event_but_keep_existing_sub_events',
    'insert_before_event',
    'insert_after_event',
    'insert_as_sub_event',
    'insert_actions_conditions_at_end',
    'insert_actions_conditions_at_start',
    'replace_all_actions',
    'replace_all_conditions',
    'insert_at_end',
  };

  static const officialChangeFields = <String>{
    'operationName',
    'operationTargetEvent',
    'isEventsJsonValid',
    'generatedEvents',
    'areEventsValid',
    'extensionNames',
    'diagnosticLines',
    'undeclaredVariables',
    'undeclaredObjectVariables',
    'missingObjectBehaviors',
    'missingResources',
  };

  final String sceneName;
  final List<Map<String, Object?>> changes;
  final int encodedBytes;

  static const schemaJson = <String, Object?>{
    r'$id': 'playmesh.gdevelop.event-payload/1.0.0',
    'title': 'GDevelopEventPayload',
    'type': 'object',
    'additionalProperties': false,
    'required': ['schemaVersion', 'sceneName', 'changes'],
    'properties': {
      'schemaVersion': {'type': 'string', 'const': schemaVersion},
      'sceneName': {'type': 'string'},
      'changes': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'operationName',
            'operationTargetEvent',
            'isEventsJsonValid',
            'generatedEvents',
            'areEventsValid',
            'extensionNames',
            'diagnosticLines',
            'undeclaredVariables',
            'undeclaredObjectVariables',
            'missingObjectBehaviors',
            'missingResources',
          ],
          'properties': {
            'operationName': {
              'type': 'string',
              'enum': [
                'delete_event',
                'insert_and_replace_event',
                'replace_entire_event_and_sub_events',
                'replace_event_but_keep_existing_sub_events',
                'insert_before_event',
                'insert_after_event',
                'insert_as_sub_event',
                'insert_actions_conditions_at_end',
                'insert_actions_conditions_at_start',
                'replace_all_actions',
                'replace_all_conditions',
                'insert_at_end',
              ],
            },
            'operationTargetEvent': {
              'type': ['string', 'null'],
            },
            'isEventsJsonValid': {
              'type': ['boolean', 'null'],
            },
            'generatedEvents': {
              'type': ['string', 'null'],
              'description':
                  'Official serialized gd.EventsList JSON consumed by applyEventsChanges.',
            },
            'areEventsValid': {
              'type': ['boolean', 'null'],
            },
            'extensionNames': {
              'type': ['array', 'null'],
              'items': {'type': 'string'},
            },
            'diagnosticLines': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'undeclaredVariables': {
              'type': 'array',
              'items': {'type': 'object'},
            },
            'undeclaredObjectVariables': {
              'type': 'object',
              'additionalProperties': {
                'type': 'array',
                'items': {'type': 'object'},
              },
            },
            'missingObjectBehaviors': {
              'type': 'object',
              'additionalProperties': {
                'type': 'array',
                'items': {'type': 'object'},
              },
            },
            'missingResources': {
              'type': 'array',
              'items': {'type': 'object'},
            },
          },
        },
      },
    },
  };

  static GDevelopEventPayload parse(Object? raw, {required int encodedBytes}) {
    final envelope = _requiredMap(raw, r'$');
    _requireExactKeys(envelope, const {
      'schemaVersion',
      'sceneName',
      'changes',
    }, r'$');
    if (envelope['schemaVersion'] != schemaVersion) {
      throw const GDevelopEventPayloadValidationException(
        'event_payload_version_unsupported',
        '不支持的 GDevelopEventPayload schemaVersion',
      );
    }
    final sceneName = envelope['sceneName'];
    final rawChanges = envelope['changes'];
    if (sceneName is! String || rawChanges is! List) {
      throw const GDevelopEventPayloadValidationException(
        'event_payload_invalid',
        'GDevelopEventPayload sceneName/changes 无效',
      );
    }

    final changes = <Map<String, Object?>>[];
    for (var index = 0; index < rawChanges.length; index += 1) {
      final change = _requiredMap(rawChanges[index], r'$.changes[]');
      _requireExactKeys(change, officialChangeFields, r'$.changes[]');
      _validateOfficialChange(change, index);
      changes.add(Map.unmodifiable(change));
    }
    _validateJsonValue(envelope, r'$');
    return GDevelopEventPayload._(
      sceneName: sceneName,
      changes: List.unmodifiable(changes),
      encodedBytes: encodedBytes,
    );
  }
}

void _validateOfficialChange(Map<String, Object?> change, int index) {
  final path = '\$.changes[$index]';
  final operationName = change['operationName'];
  if (operationName is! String ||
      !GDevelopEventPayload.officialOperationNames.contains(operationName)) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_operation_invalid',
      '$path.operationName 不是官方 applyEventsChanges 操作',
    );
  }
  _nullableString(change['operationTargetEvent'], '$path.operationTargetEvent');
  _nullableBool(change['isEventsJsonValid'], '$path.isEventsJsonValid');
  _nullableBool(change['areEventsValid'], '$path.areEventsValid');
  if (change['isEventsJsonValid'] == false ||
      change['areEventsValid'] == false) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 包含官方标记为无效的事件',
    );
  }
  final generatedEvents = change['generatedEvents'];
  _nullableString(generatedEvents, '$path.generatedEvents');
  _nullableStringList(change['extensionNames'], '$path.extensionNames');
  _stringList(change['diagnosticLines'], '$path.diagnosticLines');
  _variableList(change['undeclaredVariables'], '$path.undeclaredVariables');
  _objectListMap(
    change['undeclaredObjectVariables'],
    '$path.undeclaredObjectVariables',
    _variable,
  );
  _objectListMap(
    change['missingObjectBehaviors'],
    '$path.missingObjectBehaviors',
    _missingBehavior,
  );
  final missingResources = change['missingResources'];
  if (missingResources is! List) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path.missingResources 必须是数组',
    );
  }
  for (final resource in missingResources) {
    final value = _requiredMap(resource, '$path.missingResources[]');
    _requireExactKeys(value, const {
      'resourceName',
      'resourceKind',
    }, '$path.missingResources[]');
    if (value['resourceName'] is! String || value['resourceKind'] is! String) {
      throw GDevelopEventPayloadValidationException(
        'event_payload_invalid',
        '$path.missingResources[] 不是官方 missing resource DTO',
      );
    }
  }
}

void _variable(Object? raw, String path) {
  final value = _requiredMap(raw, path);
  _requireExactKeys(value, const {'name', 'type', 'requiredScope'}, path);
  final type = value['type'];
  if (value['name'] is! String ||
      (type != null &&
          !const {
            'number',
            'string',
            'boolean',
            'structure',
            'array',
          }.contains(type)) ||
      !const {'global', 'scene', 'none'}.contains(value['requiredScope'])) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 不是官方 undeclared variable DTO',
    );
  }
}

void _missingBehavior(Object? raw, String path) {
  final value = _requiredMap(raw, path);
  _requireExactKeys(value, const {'objectName', 'name', 'type'}, path);
  if (value.values.any((item) => item is! String)) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 不是官方 missing behavior DTO',
    );
  }
}

void _variableList(Object? raw, String path) {
  if (raw is! List) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 必须是数组',
    );
  }
  for (final item in raw) {
    _variable(item, '$path[]');
  }
}

void _objectListMap(
  Object? raw,
  String path,
  void Function(Object?, String) validate,
) {
  final value = _requiredMap(raw, path);
  for (final entry in value.entries) {
    if (entry.value is! List) {
      throw GDevelopEventPayloadValidationException(
        'event_payload_invalid',
        '$path.${entry.key} 必须是数组',
      );
    }
    for (final item in entry.value! as List) {
      validate(item, '$path.${entry.key}[]');
    }
  }
}

void _nullableString(Object? value, String path) {
  if (value != null && value is! String) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 必须是字符串或 null',
    );
  }
}

void _nullableBool(Object? value, String path) {
  if (value != null && value is! bool) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 必须是布尔值或 null',
    );
  }
}

void _nullableStringList(Object? value, String path) {
  if (value == null) return;
  _stringList(value, path);
}

void _stringList(Object? value, String path) {
  if (value is! List || value.any((item) => item is! String)) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 必须是字符串数组',
    );
  }
}

Map<String, Object?> _requiredMap(Object? raw, String path) {
  if (raw is! Map) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 必须是对象',
    );
  }
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) {
      throw GDevelopEventPayloadValidationException(
        'event_payload_not_json',
        '$path 包含非字符串键',
      );
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _requireExactKeys(
  Map<String, Object?> value,
  Set<String> expected,
  String path,
) {
  final actual = value.keys.toSet();
  if (actual.length != expected.length ||
      !actual.containsAll(expected) ||
      !expected.containsAll(actual)) {
    throw GDevelopEventPayloadValidationException(
      'event_payload_invalid',
      '$path 字段必须精确为 ${expected.toList()..sort()}',
    );
  }
}

void _validateJsonValue(Object? root, String rootPath) {
  final pending = <({Object? value, String path})>[
    (value: root, path: rootPath),
  ];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final value = current.value;
    final path = current.path;
    if (value == null || value is bool || value is int || value is String) {
      continue;
    }
    if (value is double) {
      if (!value.isFinite) {
        throw GDevelopEventPayloadValidationException(
          'event_payload_invalid_number',
          '$path 包含非有限数值',
        );
      }
      continue;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index += 1) {
        pending.add((value: value[index], path: '$path[$index]'));
      }
      continue;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw GDevelopEventPayloadValidationException(
            'event_payload_not_json',
            '$path 包含非字符串键',
          );
        }
        pending.add((value: entry.value, path: '$path.${entry.key}'));
      }
      continue;
    }
    throw GDevelopEventPayloadValidationException(
      'event_payload_not_json',
      '$path 不是 JSON 值',
    );
  }
}
