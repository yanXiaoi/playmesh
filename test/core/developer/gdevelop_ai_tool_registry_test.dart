import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_project_context.dart';
import 'package:playmesh/core/developer/gdevelop_ai_session_service.dart';
import 'package:playmesh/core/developer/gdevelop_ai_tool_registry.dart';

const _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _toolContractPath =
    'assets/playmesh-library/public/GDevelop/playmesh/runtime/ai/tools.json';

Map<String, Object?> _contract({
  required String version,
  required List<Map<String, Object?>> tools,
}) => <String, Object?>{
  'protocolVersion': 'future-editor-protocol',
  'toolsVersion': version,
  'toolCount': tools.length,
  'discovery': <String, Object?>{
    'toolDetailsToolName': 'editor_declared_details',
    'toolNameArgument': 'target',
  },
  'tools': tools,
};

Map<String, Object?> _tool(
  String name, {
  String executionKind = 'editor_function',
  Map<String, Object?>? executionConfig,
  bool chatEnabled = true,
  bool agentEnabled = true,
  bool modifiesProject = false,
  bool approvalRequired = false,
  String risk = 'editor-defined-risk',
  Object? implementation,
}) => <String, Object?>{
  'name': name,
  'summary': 'Editor-defined tool $name.',
  'argumentsSchema': <String, Object?>{
    r'$defs': <String, Object?>{
      'value': <String, Object?>{
        'type': <String>['string', 'number', 'null'],
      },
    },
    'oneOf': <Object?>[
      <String, Object?>{'type': 'object'},
      <String, Object?>{r'$ref': r'#/$defs/value'},
    ],
  },
  'risk': risk,
  'modifiesProject': modifiesProject,
  'approvalRequired': approvalRequired,
  'chatEnabled': chatEnabled,
  'agentEnabled': agentEnabled,
  'timeoutMs': 30000,
  'executionKind': executionKind,
  'executionConfig': ?executionConfig,
  'implementation': ?implementation,
};

GDevelopAiToolRegistry _registry(
  String version,
  List<Map<String, Object?>> tools, {
  String hash = _hashA,
}) => GDevelopAiToolRegistry.fromContract(
  _contract(version: version, tools: tools),
  contractHash: hash,
);

void main() {
  test('loads the WebIDE artifact without a Dart-owned name or count list', () {
    final contract = jsonDecode(File(_toolContractPath).readAsStringSync());
    final registry = GDevelopAiToolRegistry.fromContract(
      contract,
      contractHash: _hashA,
    );
    final rawTools = (contract as Map<String, dynamic>)['tools'] as List;

    expect(registry.definitions, hasLength(rawTools.length));
    expect(registry.contractJson()['toolsVersion'], contract['toolsVersion']);
    expect(registry.promptIndexJson()['toolCount'], rawTools.length);
    expect(registry.promptIndexJson()['discovery'], contract['discovery']);
    expect(
      registry.definitions.map((definition) => definition.name),
      rawTools.map((tool) => (tool as Map<String, dynamic>)['name']),
    );
    expect(
      (registry.definition('import_project_resource').toJson()['binaryStaging']
          as Map<String, Object?>)['loopbackOnly'],
      isFalse,
    );
    expect(registry.contractJson()['toolsVersion'], '4.0.0');
    expect(registry.contractJson()['officialToolsVersion'], 'v12');
    expect(registry.definitions, hasLength(50));
    const officialNames = <String>[
      'inspect_project_properties_resources',
      'change_project_properties_resources',
      'inspect_object_properties_effects',
      'change_object_properties_effects',
      'add_behavior',
      'inspect_behavior_properties',
      'change_behavior_property',
      'describe_instances',
      'put_2d_instances',
      'put_3d_instances',
      'read_scene_events',
      'read_events_source',
      'create_scene',
      'inspect_scene_properties_layers_effects',
      'change_scene_properties_layers_effects_groups',
      'add_or_edit_variable',
      'inspect_variables',
    ];
    expect(
      registry.definitions
          .where(
            (definition) =>
                definition.toJson()['implementation'] ==
                'official_editor_function',
          )
          .map((definition) => definition.name),
      officialNames,
    );
    for (final name in officialNames) {
      final definition = registry.definition(name).toJson();
      expect(definition['officialImplementationName'], name);
      expect(definition, isNot(contains('officialArguments')));
    }
    for (final removedName in const <String>[
      'list_project_resources',
      'change_project_resources',
      'inspect_object_properties',
      'change_object_property',
      'delete_object',
      'remove_behavior',
      'delete_scene',
    ]) {
      expect(
        () => registry.definition(removedName),
        throwsA(isA<GDevelopAiToolValidationException>()),
      );
    }
    final groupTool = registry.definition(
      'change_scene_properties_layers_effects_groups',
    );
    final groupProperties =
        (((groupTool.argumentsSchema['properties'] as Map)['changed_groups']
                    as Map)['items']
                as Map)['properties']
            as Map;
    expect(groupProperties, contains('objects_to_add'));
    expect(groupProperties, contains('objects_to_remove'));
    expect(groupProperties, isNot(contains('objects')));
    final sceneProperties = groupTool.argumentsSchema['properties'] as Map;
    expect(sceneProperties['delete_this_scene'], {'type': 'boolean'});
    final layerProperties =
        (((sceneProperties['changed_layers'] as Map)['items']
                as Map)['properties']
            as Map);
    expect(layerProperties['new_visibility'], {'type': 'boolean'});

    final objectChange = registry.definition(
      'change_object_properties_effects',
    );
    expect(objectChange.risk, 'high');
    expect(objectChange.approvalRequired, isTrue);
    expect(
      objectChange.argumentsSchema['properties'],
      contains('delete_this_object'),
    );
    expect(
      objectChange.argumentsSchema['properties'],
      contains('changed_effects'),
    );

    final behaviorChange = registry.definition('change_behavior_property');
    expect(behaviorChange.risk, 'high');
    expect(behaviorChange.approvalRequired, isTrue);
    expect(
      behaviorChange.argumentsSchema['properties'],
      contains('delete_this_behavior'),
    );

    final variableChange = registry.definition('add_or_edit_variable');
    expect(variableChange.risk, 'high');
    expect(variableChange.approvalRequired, isTrue);
    final variableProperties =
        variableChange.argumentsSchema['properties'] as Map;
    expect(variableProperties, contains('variables'));
    expect(variableProperties, isNot(contains('variable_name_or_path')));
    expect(
      (variableProperties['variable_scope'] as Map)['enum'],
      contains('group'),
    );

    final put2dProperties =
        registry.definition('put_2d_instances').argumentsSchema['properties']
            as Map;
    expect(put2dProperties['instances_rotation'], {'type': 'number'});
    expect(put2dProperties['instances_opacity'], {'type': 'number'});
    expect(
      registry.definition('create_scene').argumentsSchema['properties'],
      contains('is_first_scene'),
    );
  });

  test(
    'future N+1 tools reuse a known execution kind without an App schema update',
    () {
      final registry = _registry('99.0.0', <Map<String, Object?>>[
        _tool(
          'future_webide_tool',
          implementation: 'custom_editor_implementation_v9',
          risk: 'editor-specific-warning',
        ),
      ]);
      final definition = registry.definition('future_webide_tool');

      expect(definition.risk, 'editor-specific-warning');
      expect(
        definition.toJson()['implementation'],
        'custom_editor_implementation_v9',
      );
      expect(definition.argumentsSchema, contains(r'$defs'));
      expect(definition.argumentsSchema, contains('oneOf'));
      expect(
        registry.validateCall('future_webide_tool', <String, Object?>{
          'a_future_argument_not_described_by_the_schema': true,
        }),
        containsPair('a_future_argument_not_described_by_the_schema', true),
        reason: 'The active WebIDE, not Dart, validates its JSON Schema.',
      );
    },
  );

  test(
    'contract hashing accepts future transport-shaped schema keys',
    () async {
      final tool = _tool('future_network_configuration');
      tool['argumentsSchema'] = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'access_token': <String, Object?>{'type': 'string'},
          'bridgeUrl': <String, Object?>{'type': 'string'},
        },
      };
      final contract = _contract(version: '99.0.1', tools: [tool]);

      final capabilities = await GDevelopAiProjectContext.capabilitiesReference(
        contract,
      );
      final registry = GDevelopAiToolRegistry.fromContract(
        contract,
        contractHash: capabilities['contractHash']! as String,
      );

      expect(
        registry.definition('future_network_configuration').name,
        'future_network_configuration',
      );
    },
  );

  test('rejects only host execution kinds this App cannot transport', () {
    expect(
      () => _registry('1.0.0', <Map<String, Object?>>[
        _tool('future_transport', executionKind: 'future_host_transport'),
      ]),
      throwsA(
        isA<GDevelopAiToolValidationException>().having(
          (error) => error.code,
          'code',
          'unsupported_tool_execution_kind',
        ),
      ),
    );
  });

  test('keeps only channel and JSON-serializability host call gates', () {
    final registry = _registry('1.0.0', <Map<String, Object?>>[
      _tool('agent_only', chatEnabled: false),
    ]);

    expect(
      () => registry.validateCall('agent_only', const <String, Object?>{}),
      throwsA(
        isA<GDevelopAiToolValidationException>().having(
          (error) => error.code,
          'code',
          'tool_channel_not_allowed',
        ),
      ),
    );
    expect(
      registry.validateCall('agent_only', const <String, Object?>{
        'future': true,
      }, allowAgentOnlyTools: true),
      containsPair('future', true),
    );
    expect(
      () => registry.validateCall('agent_only', <String, Object?>{
        'notJson': Object(),
      }, allowAgentOnlyTools: true),
      throwsA(
        isA<GDevelopAiToolValidationException>().having(
          (error) => error.code,
          'code',
          'invalid_tool_arguments',
        ),
      ),
    );
  });

  test('sessions pin immutable contracts across an editor re-registration', () {
    final service = GDevelopAiSessionService();
    final firstRegistry = _registry('1.0.0', <Map<String, Object?>>[
      _tool('first_editor_tool'),
    ]);
    final secondRegistry = _registry('2.0.0', <Map<String, Object?>>[
      _tool('second_editor_tool'),
    ], hash: _hashB);
    final first = service.open(
      gameId: 'com.playmesh.game.snapshot',
      mode: GDevelopAiMode.agent,
      locale: 'en-US',
      registry: firstRegistry,
    );
    final second = service.reattachOrOpen(
      gameId: first.gameId,
      mode: first.mode,
      locale: first.locale,
      resumeEditorSessionId: first.id,
      registry: secondRegistry,
    );

    expect(second.id, isNot(first.id));
    expect(first.toolContractHash, _hashA);
    expect(second.toolContractHash, _hashB);
    expect(
      service.toolRegistryForSession(first.id).definition('first_editor_tool'),
      isNotNull,
    );
    expect(
      service
          .toolRegistryForSession(second.id)
          .definition('second_editor_tool'),
      isNotNull,
    );
    expect(
      () => service
          .toolRegistryForSession(first.id)
          .definition('second_editor_tool'),
      throwsA(isA<GDevelopAiToolValidationException>()),
    );

    service.dispose();
  });
}
