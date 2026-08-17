import 'dart:convert';

/// Host transports understood by this App build. Adding a tool that reuses one
/// of these kinds requires no Dart change; a new kind deliberately does.
enum GDevelopAiToolExecutionKind {
  editorFunction('editor_function'),
  eventPayload('event_payload'),
  agentResourceCas('agent_resource_cas');

  const GDevelopAiToolExecutionKind(this.wireName);
  final String wireName;

  static GDevelopAiToolExecutionKind parse(Object? value) => values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw const GDevelopAiToolValidationException(
      'unsupported_tool_execution_kind',
      'The active editor requires a host execution kind unsupported by this App build.',
    ),
  );
}

class GDevelopAiToolDefinition {
  const GDevelopAiToolDefinition({
    required this.name,
    required this.summary,
    required this.argumentsSchema,
    required this.risk,
    required this.modifiesProject,
    required this.approvalRequired,
    required this.executionKind,
    required this.raw,
    this.executionConfig = const {},
    this.chatEnabled = true,
    this.agentEnabled = true,
    this.timeout = const Duration(seconds: 30),
  });

  final String name;
  final String summary;
  final Map<String, Object?> argumentsSchema;

  /// Display-only metadata reported by the active editor. The host deliberately
  /// does not assign semantics to the editor's risk vocabulary.
  final String risk;
  final bool modifiesProject;
  final bool approvalRequired;
  final GDevelopAiToolExecutionKind executionKind;
  final Map<String, Object?> executionConfig;
  final bool chatEnabled;
  final bool agentEnabled;
  final Duration timeout;
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => raw;
}

class GDevelopAiToolValidationException implements Exception {
  const GDevelopAiToolValidationException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

/// Immutable snapshot loaded from the identity-verified installed WebIDE.
/// Dart contains no tool names, schemas, versions or counts.
class GDevelopAiToolRegistry {
  GDevelopAiToolRegistry._({
    required Map<String, Object?> contract,
    required List<GDevelopAiToolDefinition> definitions,
    required this.contractHash,
  }) : _contract = Map.unmodifiable(contract),
       definitions = List.unmodifiable(definitions),
       _byName = Map.unmodifiable({
         for (final tool in definitions) tool.name: tool,
       });

  factory GDevelopAiToolRegistry.fromContract(
    Object? value, {
    required String contractHash,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(contractHash) || value is! Map) {
      throw const GDevelopAiToolValidationException(
        'invalid_tool_contract',
        'GDevelop AI tool contract is invalid.',
      );
    }
    final contract = _stringMap(value);
    final toolsValue = contract['tools'];
    if (toolsValue is! List) {
      throw const GDevelopAiToolValidationException(
        'invalid_tool_contract',
        'GDevelop AI tool contract envelope is invalid.',
      );
    }
    final names = <String>{};
    final definitions = <GDevelopAiToolDefinition>[];
    for (final rawValue in toolsValue) {
      if (rawValue is! Map) {
        throw const GDevelopAiToolValidationException(
          'invalid_tool_contract',
          'GDevelop AI tool definition is invalid.',
        );
      }
      final raw = _deepFreezeMap(_stringMap(rawValue));
      final name = raw['name'];
      final summary = raw['summary'];
      final schema = raw['argumentsSchema'];
      final modifies = raw['modifiesProject'];
      final approval = raw['approvalRequired'];
      final chat = raw['chatEnabled'];
      final agent = raw['agentEnabled'];
      final timeoutMs = raw['timeoutMs'];
      final executionConfig = raw['executionConfig'];
      final risk = raw['risk'];
      if (name is! String ||
          name.trim().isEmpty ||
          !names.add(name) ||
          (summary != null && summary is! String) ||
          schema is! Map ||
          risk is! String ||
          risk.trim().isEmpty ||
          modifies is! bool ||
          approval is! bool ||
          chat is! bool ||
          agent is! bool ||
          timeoutMs is! int ||
          timeoutMs <= 0 ||
          (executionConfig != null && executionConfig is! Map)) {
        throw const GDevelopAiToolValidationException(
          'invalid_tool_contract',
          'GDevelop AI tool definition fields are invalid.',
        );
      }
      definitions.add(
        GDevelopAiToolDefinition(
          name: name,
          summary: summary is String ? summary : '',
          argumentsSchema: _deepFreezeMap(_stringMap(schema)),
          risk: risk,
          modifiesProject: modifies,
          approvalRequired: approval,
          executionKind: GDevelopAiToolExecutionKind.parse(
            raw['executionKind'],
          ),
          executionConfig: executionConfig is Map
              ? _deepFreezeMap(_stringMap(executionConfig))
              : const {},
          chatEnabled: chat,
          agentEnabled: agent,
          timeout: Duration(milliseconds: timeoutMs),
          raw: raw,
        ),
      );
    }
    return GDevelopAiToolRegistry._(
      contract: _deepFreezeMap(contract),
      definitions: definitions,
      contractHash: contractHash,
    );
  }

  final String contractHash;
  final Map<String, Object?> _contract;
  final List<GDevelopAiToolDefinition> definitions;
  final Map<String, GDevelopAiToolDefinition> _byName;

  GDevelopAiToolDefinition definition(String name) =>
      _byName[name] ??
      (throw const GDevelopAiToolValidationException(
        'tool_not_found',
        'GDevelop AI tool is not registered.',
      ));

  Map<String, Object?> contractJson() => _contract;

  Map<String, Object?> promptIndexJson({bool agent = true}) {
    final visible = definitions.where(
      (definition) => agent ? definition.agentEnabled : definition.chatEnabled,
    );
    return Map.unmodifiable({
      'toolsVersion': _contract['toolsVersion'],
      'toolCount': visible.length,
      'tools': List.unmodifiable(visible.map((definition) => definition.name)),
      if (_contract['discovery'] is Map) 'discovery': _contract['discovery'],
    });
  }

  Map<String, Object?> toolDetailJson(String name) => definition(name).toJson();

  Map<String, Object?> validateCall(
    String name,
    Map<String, Object?> arguments, {
    bool allowAgentOnlyTools = false,
  }) {
    final tool = definition(name);
    if (!tool.chatEnabled && !allowAgentOnlyTools) {
      throw const GDevelopAiToolValidationException(
        'tool_channel_not_allowed',
        'This GDevelop AI tool is available only to the authenticated Agent channel.',
      );
    }
    try {
      jsonEncode(arguments);
    } on JsonUnsupportedObjectError {
      throw const GDevelopAiToolValidationException(
        'invalid_tool_arguments',
        'Tool arguments must be JSON serializable.',
      );
    }
    return Map.unmodifiable(arguments);
  }
}

Map<String, Object?> _stringMap(Map value) => Map<String, Object?>.from(value);

Map<String, Object?> _deepFreezeMap(Map<String, Object?> value) =>
    Map.unmodifiable({
      for (final entry in value.entries) entry.key: _deepFreeze(entry.value),
    });

Object? _deepFreeze(Object? value) {
  if (value is Map) return _deepFreezeMap(_stringMap(value));
  if (value is List) return List.unmodifiable(value.map(_deepFreeze));
  return value;
}
