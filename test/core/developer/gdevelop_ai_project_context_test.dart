import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_project_context.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

void main() {
  final registry = loadGDevelopAiToolRegistryForTest();

  test(
    'canonical context validates official summaries and hashes stably',
    () async {
      final capabilities = await GDevelopAiProjectContext.capabilitiesReference(
        registry.contractJson(),
      );
      final first = await GDevelopAiProjectContext.parse(
        _validContext(capabilities),
        canonicalToolContract: registry.contractJson(),
      );
      final reordered = await GDevelopAiProjectContext.parse({
        'capabilities': capabilities,
        'projectSummary': {
          'projectSpecificExtensionsSummary': {
            'extensionSummaries': <Object?>[],
          },
          'simplifiedProject': {
            'resources': <Object?>[],
            'globalVariables': <Object?>[],
            'scenes': [_scene('Scene')],
            'globalObjectGroups': <Object?>[],
            'globalObjects': <Object?>[],
            'properties': <String, Object?>{
              'gameResolutionWidth': 800,
              'gameResolutionHeight': 600,
            },
          },
        },
        'selectedScene': {'eventsText': 'Scene event text', 'name': 'Scene'},
        'schemaVersion': '1.0.0',
      }, canonicalToolContract: registry.contractJson());

      expect(first.contentHash, reordered.contentHash);
      expect(
        first.encodedBytes,
        lessThan(GDevelopAiProjectContext.maxEncodedBytes),
      );
      expect(first.selectedSceneName, 'Scene');
      expect(first.sceneNames, const ['Scene']);
      expect(first.sceneIndexJson(), const {
        'sceneNames': ['Scene'],
        'selectedSceneName': 'Scene',
      });
      expect(first.metadataJson()['schemaVersion'], '1.0.0');

      final localResources = _validContext(capabilities);
      final summary = localResources['projectSummary']! as Map;
      final simplified = summary['simplifiedProject']! as Map;
      (simplified['resources']! as List).addAll(const [
        {'name': 'HeroImage', 'type': 'image', 'file': 'HeroImage'},
        {'name': 'ThemeAudio', 'type': 'audio', 'file': 'theme-audio'},
        {'name': 'Voice', 'type': 'audio', 'file': 'voice-logical'},
      ]);
      await expectLater(
        GDevelopAiProjectContext.parse(
          localResources,
          canonicalToolContract: registry.contractJson(),
        ),
        completes,
      );
    },
  );

  test(
    'rejects stale capability references and missing selected scenes',
    () async {
      final capabilities = await GDevelopAiProjectContext.capabilitiesReference(
        registry.contractJson(),
      );
      await expectLater(
        GDevelopAiProjectContext.parse(
          _validContext({...capabilities, 'toolCount': 999}),
          canonicalToolContract: registry.contractJson(),
        ),
        throwsA(
          isA<GDevelopAiProjectContextValidationException>().having(
            (error) => error.code,
            'code',
            'project_context_capabilities_mismatch',
          ),
        ),
      );
      final missingScene = _validContext(capabilities);
      (missingScene['selectedScene']! as Map)['name'] = 'DeletedScene';
      await expectLater(
        GDevelopAiProjectContext.parse(
          missingScene,
          canonicalToolContract: registry.contractJson(),
        ),
        throwsA(
          isA<GDevelopAiProjectContextValidationException>().having(
            (error) => error.code,
            'code',
            'project_context_selected_scene_missing',
          ),
        ),
      );
    },
  );

  test(
    'rejects tokens, URLs, bridges, render failures, and oversized events',
    () async {
      final capabilities = await GDevelopAiProjectContext.capabilitiesReference(
        registry.contractJson(),
      );
      final cases = <({Map<String, Object?> value, String code})>[
        (
          value: _validContext(capabilities, eventsText: 'Bearer secret-value'),
          code: 'project_context_url_or_token_forbidden',
        ),
        (
          value: _validContext(
            capabilities,
            eventsText: 'https://example.invalid/asset.png',
          ),
          code: 'project_context_url_or_token_forbidden',
        ),
        (
          value: _validContext(
            capabilities,
            eventsText: '?token=fresh-lan-bootstrap-secret',
          ),
          code: 'project_context_url_or_token_forbidden',
        ),
        (
          value: _validContext(
            capabilities,
            eventsText: '__playmeshBridge.invoke()',
          ),
          code: 'project_context_bridge_forbidden',
        ),
        (
          value: _validContext(
            capabilities,
            eventsText: 'Error while rendering events as text.',
          ),
          code: 'project_context_events_render_failed',
        ),
        (
          value: _validContext(
            capabilities,
            eventsText: List.filled(
              GDevelopAiProjectContext.maxSelectedSceneEventsBytes + 1,
              'x',
            ).join(),
          ),
          code: 'project_context_selected_scene_too_large',
        ),
      ];
      for (final item in cases) {
        await expectLater(
          GDevelopAiProjectContext.parse(
            item.value,
            canonicalToolContract: registry.contractJson(),
          ),
          throwsA(
            isA<GDevelopAiProjectContextValidationException>().having(
              (error) => error.code,
              'code',
              item.code,
            ),
          ),
        );
      }

      final plainTokenWord = _validContext(
        capabilities,
        eventsText: 'The token economy is an ordinary game design concept.',
      );
      await expectLater(
        GDevelopAiProjectContext.parse(
          plainTokenWord,
          canonicalToolContract: registry.contractJson(),
        ),
        completes,
      );

      try {
        await GDevelopAiProjectContext.parse(
          _validContext(capabilities, eventsText: 'Bearer secret-value'),
          canonicalToolContract: registry.contractJson(),
        );
        fail('Bearer content must be rejected');
      } on GDevelopAiProjectContextValidationException catch (error) {
        expect(error.path, r'$.selectedScene.eventsText');
        expect(error.valueType, 'string');
        expect(
          error.safeDiagnosticReason,
          r'path=$.selectedScene.eventsText type=string',
        );
        expect(error.safeDiagnosticReason, isNot(contains('secret-value')));
      }

      final tokenKey = _validContext(capabilities);
      final summary = tokenKey['projectSummary']! as Map;
      final simplified = summary['simplifiedProject']! as Map;
      (simplified['properties']! as Map)['accessToken'] = 'not-even-a-secret';
      await expectLater(
        GDevelopAiProjectContext.parse(
          tokenKey,
          canonicalToolContract: registry.contractJson(),
        ),
        throwsA(
          isA<GDevelopAiProjectContextValidationException>().having(
            (error) => error.code,
            'code',
            'project_context_sensitive_field',
          ),
        ),
      );
    },
  );
}

Map<String, Object?> _validContext(
  Map<String, Object?> capabilities, {
  String eventsText = 'Scene event text',
}) => <String, Object?>{
  'schemaVersion': '1.0.0',
  'selectedScene': {'name': 'Scene', 'eventsText': eventsText},
  'projectSummary': {
    'simplifiedProject': {
      'properties': <String, Object?>{
        'gameResolutionWidth': 800,
        'gameResolutionHeight': 600,
      },
      'globalObjects': <Object?>[],
      'globalObjectGroups': <Object?>[],
      'scenes': [_scene('Scene')],
      'globalVariables': <Object?>[],
      'resources': <Object?>[],
    },
    'projectSpecificExtensionsSummary': {'extensionSummaries': <Object?>[]},
  },
  'capabilities': capabilities,
};

Map<String, Object?> _scene(String name) => {
  'sceneName': name,
  'objects': <Object?>[],
  'objectGroups': <Object?>[],
  'sceneVariables': <Object?>[],
  'layers': <Object?>[],
  'instancesOnSceneDescription': '',
};
