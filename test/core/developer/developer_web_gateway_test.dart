import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_ai_prompt_templates.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';
import 'package:playmesh/core/developer/developer_event_hub.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/developer_preferences.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/core/game_package/asset_game_library_scanner.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/lifecycle/go_core_host.dart';
import 'package:playmesh/core/platform/app_sensor_service.dart';
import 'package:playmesh/core/network/go_core_client.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_runtime.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('开发者通道使用独立固定端口并读取项目和文件', () async {
    final port = await _availablePort();
    final promptRoot = await Directory.systemTemp.createTemp(
      'playmesh-ai-prompts-',
    );
    var restartCount = 0;
    var stopCount = 0;
    final runController = DeveloperRunController(onLaunch: (_) async {});
    final unregisterRestart = runController.registerRestartHandler(
      'demo',
      () async => restartCount += 1,
    );
    addTearDown(unregisterRestart);
    final unregisterStop = runController.registerStopHandler(
      'demo',
      () async => stopCount += 1,
    );
    addTearDown(unregisterStop);
    final runtime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerProjectCatalog: const _FakeCatalog(),
      developerAiPromptTemplates: DeveloperAiPromptTemplateStore(
        root: promptRoot,
      ),
      developerPreferences: DeveloperPreferences(libraryRoot: promptRoot),
      developerRunController: runController,
      developerCapabilityTests: DeveloperCapabilityTestService(
        sensorSource: _UnavailableSensorSource(),
      ),
    );
    addTearDown(runtime.close);
    addTearDown(() => promptRoot.delete(recursive: true));

    final session = await runtime.enableDeveloperMode(
      port: port,
      token: 'custom-dev-token',
    );
    final links = await runtime.developerWorkspaceLinks(session);

    expect(session.port, port);
    expect(runtime.endpoint.port, 43210);
    expect(links, isNotEmpty);
    expect(links.first.port, port);
    expect(links.first.queryParameters['token'], 'custom-dev-token');

    final workspace = await http.get(links.first);
    expect(workspace.statusCode, HttpStatus.ok);
    expect(workspace.body, contains('Playmesh 开发者工作区'));
    expect(workspace.body, contains('id="aiPanel" class="ai-action"'));
    expect(workspace.body, contains('id="manifestSettings"'));
    expect(workspace.body, contains('id="manifestForm"'));
    expect(workspace.body, contains('id="manifestId" readonly'));
    expect(workspace.body, contains('id="manifestTags"'));
    expect(workspace.body, contains('id="capabilityOptions"'));
    expect(workspace.body, contains('id="capabilityTests"'));
    expect(workspace.body, contains('id="capabilityTestModal"'));
    expect(workspace.body, contains('id="capabilityTestLog"'));
    expect(workspace.body, contains('id="clearGameData"'));
    expect(workspace.body, contains('清理游戏数据'));
    expect(workspace.body, contains('id="projectDescription"'));
    expect(workspace.body, contains('id="projectTags"'));
    expect(workspace.body, contains('id="projectCapabilityOptions"'));
    expect(workspace.body, contains('id="copyCurrentFile"'));
    expect(workspace.body, contains('id="projectPicker"'));
    expect(workspace.body, contains('id="projectSearch"'));
    expect(workspace.body, contains('id="projectPickerClose"'));
    expect(workspace.body, contains('id="toolbarMenu"'));
    expect(workspace.body, contains('id="stop"'));
    expect(workspace.body, contains('id="diffLeftFile"'));
    expect(workspace.body, contains('addon/hint/javascript-hint.js'));
    expect(workspace.body, contains('✨ 获取项目提示词'));
    expect(workspace.body, contains('id="agentBaseUrl"'));

    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    final workspaceScript = await http.get(
      base.resolve('/playmesh/developer/workspace.js?token=custom-dev-token'),
    );
    expect(workspaceScript.statusCode, HttpStatus.ok);
    expect(workspaceScript.body, contains('localStorage.setItem'));
    expect(workspaceScript.body, contains('openProjectPicker()'));
    expect(workspaceScript.body, contains('appendCapabilityTestResults'));
    expect(workspaceScript.body, contains('while(generation==='));
    final status = await http.get(
      base.resolve('/dev/api/status?token=custom-dev-token'),
    );
    expect(status.statusCode, HttpStatus.ok);
    final statusJson = Map<String, Object?>.from(
      jsonDecode(status.body) as Map,
    );
    final baseUrls = (statusJson['baseUrls']! as List).cast<String>();
    expect(baseUrls, isNotEmpty);
    expect(baseUrls, contains(base.toString()));
    expect(statusJson['gameSdkVersion'], '1.4.3');
    expect(statusJson['appSdkVersion'], '1.2.1');

    final sdkBundle = await http.get(
      base.resolve('/dev/api/sdk?token=custom-dev-token'),
    );
    expect(sdkBundle.statusCode, HttpStatus.ok);
    final sdkBundleJson = jsonDecode(sdkBundle.body) as Map;
    expect(sdkBundleJson['gameSdkVersion'], '1.4.3');
    expect(sdkBundleJson['appSdkVersion'], '1.2.1');
    expect(
      (sdkBundleJson['files'] as Map).keys,
      containsAll([
        'playmesh.js',
        'playmesh-app.js',
        'playmesh.d.ts',
        'playmesh-app.d.ts',
      ]),
    );

    final capabilityRegistry = await http.get(
      base.resolve('/dev/api/capabilities?token=custom-dev-token'),
    );
    expect(capabilityRegistry.statusCode, HttpStatus.ok);
    final capabilityItems =
        (jsonDecode(capabilityRegistry.body) as Map)['capabilities'] as List;
    expect(
      capabilityItems,
      contains(containsPair('code', 'sensor.accelerometer')),
    );
    expect(capabilityItems, everyElement(contains('appSupported')));
    expect(capabilityItems, everyElement(contains('htmlSupported')));
    final capabilityTestCatalog = await http.get(
      base.resolve('/dev/api/capability-tests?token=custom-dev-token'),
    );
    expect(capabilityTestCatalog.statusCode, HttpStatus.ok);
    final capabilityTestItems =
        (jsonDecode(capabilityTestCatalog.body) as Map)['capabilities'] as List;
    expect(capabilityTestItems, hasLength(capabilityItems.length));
    expect(capabilityTestItems, everyElement(contains('testable')));
    final capabilityTestRun = await http.post(
      base.resolve('/dev/api/capability-tests?token=custom-dev-token'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'codes': ['sensor.accelerometer'],
        'timeoutMs': 250,
      }),
    );
    expect(capabilityTestRun.statusCode, HttpStatus.ok);
    final capabilityTestResult = Map<String, Object?>.from(
      jsonDecode(capabilityTestRun.body) as Map,
    );
    expect(capabilityTestResult['total'], 1);
    expect(capabilityTestResult['results'], isA<List>());
    final editorHint = await http.get(
      base.resolve(
        '/playmesh/developer/editor/node_modules/codemirror/'
        'addon/hint/javascript-hint.js',
      ),
    );
    expect(editorHint.statusCode, HttpStatus.ok);
    expect(editorHint.body, contains('additionalContext'));

    developerEventHub.beginRuntime(projectId: 'demo', runId: 'run-demo');
    for (var index = 0; index < 60; index += 1) {
      developerEventHub.emit({
        'type': 'runtime.log',
        'source': 'app-webview',
        'level': 'log',
        'message': 'gateway-line-$index',
      });
    }
    developerEventHub.emit({
      'type': 'runtime.log',
      'projectId': 'other',
      'runId': 'run-other',
      'source': 'app-webview',
      'level': 'log',
      'message': 'other-project-line',
    });
    final recentLogs = await http.get(
      base.resolve(
        '/dev/api/logs?limit=50&projectId=demo&runId=run-demo&token=custom-dev-token',
      ),
    );
    expect(recentLogs.statusCode, HttpStatus.ok);
    final recentLogJson = jsonDecode(recentLogs.body) as Map;
    final logs = recentLogJson['logs'] as List;
    expect(logs, hasLength(50));
    expect((logs.first as Map)['message'], 'gateway-line-10');
    expect((logs.last as Map)['message'], 'gateway-line-59');
    expect((logs.last as Map)['eventId'], isNotEmpty);

    final cleared = await http.delete(
      base.resolve('/dev/api/projects/demo/data?token=custom-dev-token'),
    );
    expect(cleared.statusCode, HttpStatus.ok, reason: cleared.body);
    expect(jsonDecode(cleared.body)['directory'], 'data');
    expect(jsonDecode(cleared.body)['cachePreserved'], isTrue);

    final run = await http.post(
      base.resolve('/dev/api/projects/demo/run?token=custom-dev-token'),
    );
    expect(run.statusCode, HttpStatus.accepted, reason: run.body);
    expect(jsonDecode(run.body)['runId'], isNotEmpty);
    final restart = await http.post(
      base.resolve('/dev/api/projects/demo/run/restart?token=custom-dev-token'),
    );
    expect(restart.statusCode, HttpStatus.accepted);
    expect(jsonDecode(restart.body)['phase'], 'running');
    final activeRun = await http.get(
      base.resolve('/dev/api/run?token=custom-dev-token'),
    );
    expect(activeRun.statusCode, HttpStatus.ok);
    expect(jsonDecode(activeRun.body)['run']['projectId'], 'demo');
    expect(restartCount, 1);
    final clearWhileRunning = await http.delete(
      base.resolve('/dev/api/projects/demo/data?token=custom-dev-token'),
    );
    expect(clearWhileRunning.statusCode, HttpStatus.conflict);
    expect(jsonDecode(clearWhileRunning.body)['error']['code'], 'game_running');
    final stop = await http.post(
      base.resolve('/dev/api/projects/demo/run/stop?token=custom-dev-token'),
    );
    expect(stop.statusCode, HttpStatus.ok, reason: stop.body);
    expect(jsonDecode(stop.body)['phase'], 'stopped');
    expect(stopCount, 1);

    final projects = await http.get(
      base.resolve('/dev/api/projects'),
      headers: const {'Authorization': 'Bearer custom-dev-token'},
    );
    expect(projects.statusCode, HttpStatus.ok);
    expect(jsonDecode(projects.body)['projects'], hasLength(1));

    final files = await http.get(
      base.resolve('/dev/api/projects/demo/files?token=custom-dev-token'),
    );
    expect(files.statusCode, HttpStatus.ok);
    expect(jsonDecode(files.body)['files'], contains('main.json'));

    final aiPrompt = await http.get(
      base.resolve(
        '/dev/api/projects/demo/chat-prompt.txt?token=custom-dev-token',
      ),
    );
    expect(aiPrompt.statusCode, HttpStatus.ok);
    expect(aiPrompt.headers['content-type'], startsWith('text/plain'));
    expect(aiPrompt.headers['content-disposition'], contains('.txt'));
    expect(aiPrompt.bodyBytes.take(3), orderedEquals([0xef, 0xbb, 0xbf]));
    expect(aiPrompt.body, contains('统一 SDK TypeScript 声明（唯一接口事实源）'));
    expect(
      aiPrompt.body,
      contains('===== BEGIN SDK DECLARATION: playmesh.d.ts ====='),
    );
    expect(aiPrompt.body, contains('readonly version: "1.4.3"'));
    expect(
      aiPrompt.body,
      contains('===== BEGIN SDK DECLARATION: playmesh-app.d.ts ====='),
    );
    expect(aiPrompt.body, contains('playmesh.session.getCurrent()'));
    expect(aiPrompt.body, contains('playmesh.player.getCurrent()'));
    expect(aiPrompt.body, contains('playmesh.sync.submitAction(input)'));
    expect(aiPrompt.body, contains('playmesh.sync.startAuthority(options)'));
    expect(aiPrompt.body, contains('playmesh.sync.observe'));
    expect(aiPrompt.body, contains('playmesh.app.isAvailable()'));
    expect(aiPrompt.body, contains('playmesh.app.device.getCapabilities()'));
    expect(aiPrompt.body, contains('onPlayerReconnect(callback)'));
    expect(aiPrompt.body, contains('playmesh.session.finish()'));
    expect(
      aiPrompt.body,
      contains('state: "lobby" | "running" | "paused" | "stopped"'),
    );
    expect(aiPrompt.body, contains('manifest API'));
    expect(aiPrompt.body, contains('绝对不能修改 `id`'));
    expect(aiPrompt.body, contains('entries.game（快速操作路径）: index.html'));
    expect(aiPrompt.body, contains('===== BEGIN WORKSPACE FILE: index.html'));
    expect(aiPrompt.body, isNot(contains('- [file] app/index.html')));
    expect(aiPrompt.body, contains('操作头数量必须等于 ----end 数量'));
    expect(aiPrompt.body, contains('不能只输出 body 内片段'));
    expect(aiPrompt.body, contains('只有非 Authority 的多人页面'));
    expect(aiPrompt.body, contains('stateType 可选'));
    expect(aiPrompt.body, contains('getState()'));
    expect(aiPrompt.body, contains('仅浏览器联机玩家可用'));
    expect(aiPrompt.body, isNot(contains('仅浏览器控制器可用')));
    expect(aiPrompt.body, isNot(contains('重载后 SDK 会自动请求最新快照')));
    expect(aiPrompt.body, contains('Authority 入口当前存在：false'));
    expect(aiPrompt.body, contains('static/js/service/index.js'));
    expect(aiPrompt.body, contains('===== BEGIN WORKSPACE FILE: main.json'));

    final takeoverBaseUrl = baseUrls.first;
    final agentPrompt = await http.get(
      base
          .resolve('/dev/api/projects/demo/agent-prompt.txt')
          .replace(
            queryParameters: {
              'token': 'custom-dev-token',
              'baseUrl': takeoverBaseUrl,
            },
          ),
    );
    expect(agentPrompt.statusCode, HttpStatus.ok);
    expect(agentPrompt.headers['content-disposition'], contains('.txt'));
    expect(agentPrompt.bodyBytes.take(3), orderedEquals([0xef, 0xbb, 0xbf]));
    expect(agentPrompt.body, contains('PLAYMESH API AGENT'));
    expect(agentPrompt.body, contains('Base URL: $takeoverBaseUrl'));
    expect(
      agentPrompt.body,
      contains('Authorization: Bearer custom-dev-token'),
    );
    expect(agentPrompt.body, contains('/dev/api/projects/demo/file'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/run/restart'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/run/stop'));
    expect(agentPrompt.body, contains('DELETE'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/data'));
    expect(agentPrompt.body, contains('保留 cache'));
    expect(agentPrompt.body, contains('/dev/api/logs?limit=50'));
    expect(agentPrompt.body, contains('不强制消费 SSE'));
    expect(agentPrompt.body, contains('/dev/sdk-manifest.json'));
    expect(agentPrompt.body, contains('/dev/openapi.json'));
    expect(agentPrompt.body, contains('playmesh.app.isAvailable()'));
    expect(agentPrompt.body, contains('onPlayerReconnect(callback)'));
    expect(agentPrompt.body, contains('playmesh.session.finish()'));
    expect(agentPrompt.body, contains('manifest API'));
    expect(agentPrompt.body, contains('禁止修改 `id`'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/manifest'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/capabilities'));
    expect(agentPrompt.body, contains('/dev/api/capabilities'));
    expect(agentPrompt.body, contains('当前 capabilities.json.required：未声明'));
    expect(agentPrompt.body, contains('平台统一能力注册表'));
    expect(agentPrompt.body, contains('sensor.accelerometer | 加速度计'));
    expect(agentPrompt.body, contains('sensor.gyroscope | 陀螺仪'));
    expect(agentPrompt.body, contains('playmesh.app.*'));
    expect(agentPrompt.body, contains('entries.game: app/index.html'));
    expect(
      agentPrompt.body,
      contains('===== BEGIN WORKSPACE FILE: app/index.html'),
    );
    expect(agentPrompt.body, isNot(contains('最终回答只能包含可直接粘贴')));

    final invalidAgentBaseUrl = await http.get(
      base
          .resolve('/dev/api/projects/demo/agent-prompt.txt')
          .replace(
            queryParameters: {
              'token': 'custom-dev-token',
              'baseUrl': 'https://example.com:$port',
            },
          ),
    );
    expect(invalidAgentBaseUrl.statusCode, HttpStatus.badRequest);
    expect(
      jsonDecode(invalidAgentBaseUrl.body)['error']['message'],
      contains('Agent Base URL'),
    );

    final templates = await http.get(
      base.resolve('/dev/api/ai-prompt-templates?token=custom-dev-token'),
    );
    expect(templates.statusCode, HttpStatus.ok);
    expect(jsonDecode(templates.body)['categories'], hasLength(3));
    final templateCategories =
        (jsonDecode(templates.body)['categories'] as List)
            .cast<Map<String, Object?>>();
    final commonTemplates =
        templateCategories.firstWhere(
              (category) => category['id'] == 'common',
            )['items']
            as List;
    expect(
      commonTemplates.map((item) => (item as Map)['id']),
      contains('custom-ideas'),
    );
    final commonTemplate = commonTemplates.cast<Map>().firstWhere(
      (item) => item['id'] == 'common',
    );
    expect(commonTemplate['content'], isNot(contains('playmesh.sync')));
    final modeTemplates =
        templateCategories.firstWhere(
              (category) => category['id'] == 'mode',
            )['items']
            as List;
    final soloTemplate = modeTemplates.cast<Map>().firstWhere(
      (item) => item['id'] == 'solo',
    );
    expect(
      soloTemplate['content'],
      contains('playmesh.authority 或 playmesh.sync'),
    );
    final customized = await http.put(
      base.resolve(
        '/dev/api/ai-prompt-templates/common?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'content': 'CUSTOM_COMMON\nawait playmesh.ready;'}),
    );
    expect(customized.statusCode, HttpStatus.ok);
    expect(jsonDecode(customized.body)['template']['customized'], isTrue);
    final customizedPrompt = await http.get(
      base.resolve(
        '/dev/api/projects/demo/chat-prompt.txt?token=custom-dev-token',
      ),
    );
    expect(customizedPrompt.body, contains('CUSTOM_COMMON'));
    final reset = await http.delete(
      base.resolve(
        '/dev/api/ai-prompt-templates/common?token=custom-dev-token',
      ),
    );
    expect(reset.statusCode, HttpStatus.ok);
    expect(jsonDecode(reset.body)['template']['customized'], isFalse);

    final customIdeas = await http.put(
      base.resolve(
        '/dev/api/ai-prompt-templates/custom-ideas'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'content': 'CUSTOM_GAME_IDEA: 使用几何霓虹视觉'}),
    );
    expect(customIdeas.statusCode, HttpStatus.ok);
    final promptWithIdeas = await http.get(
      base.resolve(
        '/dev/api/projects/demo/chat-prompt.txt?token=custom-dev-token',
      ),
    );
    expect(promptWithIdeas.body, contains('CUSTOM_GAME_IDEA'));

    final quickPreview = await http.post(
      base.resolve(
        '/dev/api/projects/demo/quick-operations/preview'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'commands': '''----replace_file:static/js/new/module.js
export const createdByReplace = true;
----end

----create_file:static/css/new/theme.css
body { color: white; }
----end''',
      }),
    );
    expect(quickPreview.statusCode, HttpStatus.ok);
    final previewFiles = (jsonDecode(quickPreview.body)['files'] as List)
        .cast<Map<String, Object?>>();
    expect(
      previewFiles.map((file) => file['path']),
      containsAll([
        'app/static/js/new/module.js',
        'app/static/css/new/theme.css',
      ]),
    );
    expect(previewFiles.every((file) => file['created'] == true), isTrue);

    final manifest = await http.get(
      base.resolve(
        '/dev/api/projects/demo/file?path=main.json&token=custom-dev-token',
      ),
    );
    expect(manifest.statusCode, HttpStatus.ok);
    expect(manifest.body, contains('"id":"demo"'));

    final validation = await http.get(
      base.resolve('/dev/api/projects/demo/validate?token=custom-dev-token'),
    );
    expect(validation.statusCode, HttpStatus.ok);
    expect(jsonDecode(validation.body)['valid'], isTrue);

    final validationSchema = await http.get(
      base.resolve(
        '/dev/schemas/project-validation.json?token=custom-dev-token',
      ),
    );
    expect(validationSchema.statusCode, HttpStatus.ok);
    expect(validationSchema.body, contains('DeveloperProjectValidationReport'));

    final gameManifestSchema = await http.get(
      base.resolve('/dev/schemas/game-manifest.json?token=custom-dev-token'),
    );
    expect(gameManifestSchema.statusCode, HttpStatus.ok);
    final gameManifestSchemaJson =
        jsonDecode(gameManifestSchema.body) as Map<String, Object?>;
    final manifestProperties =
        gameManifestSchemaJson['properties'] as Map<String, Object?>;
    expect((manifestProperties['modes'] as Map)['maxItems'], 1);
    expect((manifestProperties['displayModes'] as Map)['maxItems'], 1);

    final sdkManifest = await http.get(
      base.resolve('/dev/sdk-manifest.json?token=custom-dev-token'),
    );
    expect(sdkManifest.statusCode, HttpStatus.ok);
    expect(sdkManifest.body, contains('playmesh.authority'));
    expect(sdkManifest.body, contains('device.getDeclaredCapabilities'));
    expect(sdkManifest.body, contains('capabilityConsent'));

    final openApi = await http.get(
      base.resolve('/dev/openapi.json?token=custom-dev-token'),
    );
    expect(openApi.statusCode, HttpStatus.ok);
    final openApiJson = Map<String, Object?>.from(jsonDecode(openApi.body));
    final paths = Map<String, Object?>.from(openApiJson['paths']! as Map);
    expect(paths, contains('/dev/api/ai-prompt-templates'));
    expect(paths, contains('/dev/api/ai-prompt-templates/{templateId}'));
    expect(paths, contains('/dev/api/projects/{projectId}/validate'));
    expect(paths, contains('/dev/api/projects/{projectId}/run/restart'));
    expect(paths, contains('/dev/api/projects/{projectId}/run/stop'));
    expect(paths, contains('/dev/api/projects/{projectId}/data'));
    expect(paths, contains('/dev/api/logs'));
    expect(
      paths,
      contains('/dev/api/projects/{projectId}/quick-operations/apply'),
    );
    expect(paths, contains('/dev/api/projects/{projectId}/chat-prompt.txt'));
    expect(paths, contains('/dev/api/projects/{projectId}/agent-prompt.txt'));
    expect(paths, contains('/dev/api/capabilities'));
    expect(paths, contains('/dev/api/capability-tests'));
    expect(paths, contains('/dev/api/projects/{projectId}/manifest'));
    expect(paths, contains('/dev/api/projects/{projectId}/capabilities'));
    final components = Map<String, Object?>.from(
      openApiJson['components']! as Map,
    );
    final schemas = Map<String, Object?>.from(components['schemas']! as Map);
    expect(schemas, contains('CapabilityDefinition'));
    expect(schemas, contains('CapabilityTestResponse'));
    expect(schemas, contains('CapabilityUpdate'));
    expect(schemas, contains('ManifestUpdate'));

    final aiContext = await http.get(
      base.resolve('/dev/api/ai-context?token=custom-dev-token'),
    );
    expect(aiContext.statusCode, HttpStatus.ok);
    final aiContextJson = Map<String, Object?>.from(
      jsonDecode(aiContext.body) as Map,
    );
    final documentedOperations = <String>{};
    const httpMethods = {'get', 'post', 'put', 'patch', 'delete'};
    for (final pathEntry in paths.entries) {
      final methods = Map<String, Object?>.from(pathEntry.value! as Map);
      for (final method in methods.keys.where(httpMethods.contains)) {
        documentedOperations.add('${method.toUpperCase()} ${pathEntry.key}');
      }
    }
    final exposedOperations = (aiContextJson['operations']! as List)
        .cast<Map>()
        .map(
          (operation) =>
              '${operation['method']} ${(operation['path']! as String).split('?').first}',
        )
        .where((operation) => operation.contains(' /dev/api/'))
        .toSet();
    expect(exposedOperations, documentedOperations);

    final unauthorized = await http.get(base.resolve('/dev/api/projects'));
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    expect(unauthorized.headers['x-request-id'], isNotEmpty);
  });

  test('重新开启或 App Runtime 重建后复用开发者地址', () async {
    final port = await _availablePort();
    final preferenceRoot = await Directory.systemTemp.createTemp(
      'playmesh-developer-workspace-identity-',
    );
    addTearDown(() => preferenceRoot.delete(recursive: true));
    final firstRuntime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerPreferences: DeveloperPreferences(libraryRoot: preferenceRoot),
    );

    final first = await firstRuntime.enableDeveloperMode(
      port: port,
      token: 'custom-dev-token',
    );
    final oldLink = (await firstRuntime.developerWorkspaceLinks(first)).first;
    await firstRuntime.close();

    final secondRuntime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerPreferences: DeveloperPreferences(libraryRoot: preferenceRoot),
    );
    addTearDown(secondRuntime.close);
    final second = await secondRuntime.enableDeveloperMode(
      port: port,
      token: '',
    );
    final newLink = (await secondRuntime.developerWorkspaceLinks(second)).first;

    expect(newLink, oldLink);
    expect((await http.get(newLink)).statusCode, HttpStatus.ok);

    await secondRuntime.disableDeveloperMode();
    await expectLater(http.get(newLink), throwsA(isA<http.ClientException>()));
  });

  test('拒绝过短的自定义 Token', () async {
    final runtime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
    );
    addTearDown(runtime.close);

    await expectLater(
      runtime.enableDeveloperMode(port: await _availablePort(), token: 'short'),
      throwsA(isA<FormatException>()),
    );
  });

  test('开发者项目列表包含游戏库中的本地项目并可建立开发副本', () async {
    final source = await Directory.systemTemp.createTemp(
      'playmesh-library-project-',
    );
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-developer-workspace-',
    );
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => workspace.delete(recursive: true));
    await File(
      '${source.path}${Platform.pathSeparator}main.json',
    ).writeAsString('{"id":"com.example.library","name":"Library Game"}');
    await File(
      '${source.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}index.html',
    ).create(recursive: true);
    final repository = GameLibraryRepository(
      () async => const [],
      initialGames: [
        GameSummary(
          id: 'com.example.library',
          name: 'Library Game',
          version: '1.0.0',
          description: '',
          minPlayers: 1,
          maxPlayers: 1,
          supportsMultiplayer: false,
          displayModeLabel: '多人多屏',
          displayMode: 'multi_screen',
          orientation: GameOrientation.landscape,
          entry: LocalGameEntry(
            assetPath: 'app/index.html',
            statusLabel: 'Game SDK 1.0.0',
            packageRootFilePath: source.path,
          ),
        ),
      ],
    );
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );

    final projects = await catalog.listProjects();
    expect(projects.map((project) => project.id), ['com.example.library']);
    expect(
      await catalog.listFiles('com.example.library'),
      contains('app/index.html'),
    );
  });

  test('从外置模板创建项目并通过受控接口编辑 main.json', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-new-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final repository = GameLibraryRepository(AssetGameLibraryScanner().scan);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );

    final project = await catalog.createProject(
      const DeveloperProjectDraft(
        id: 'com.example.created-game',
        name: 'Created Game',
        description: 'A polished party game.',
        orientation: GameOrientation.portrait,
        displayMode: 'multi_screen',
        minPlayers: 2,
        maxPlayers: 4,
        tags: ['party', 'motion'],
        requiredCapabilities: ['sensor.accelerometer'],
      ),
    );
    final files = await catalog.listFiles(project.id);
    final manifest = await catalog.readFile(project.id, 'main.json');

    expect(
      files,
      containsAll(['main.json', 'capabilities.json', 'app/index.html']),
    );
    expect(files, isNot(contains('app/controller/index.html')));
    expect(files, isNot(contains('app/static/js/player/controller.js')));
    expect(utf8.decode(manifest.bytes), contains(project.id));
    expect(utf8.decode(manifest.bytes), contains('A polished party game.'));
    expect(utf8.decode(manifest.bytes), contains('motion'));
    final capabilities = await catalog.readFile(
      project.id,
      'capabilities.json',
    );
    expect(utf8.decode(capabilities.bytes), contains('sensor.accelerometer'));
    expect(manifest.readOnly, isTrue);
    expect(repository.cachedGames.map((game) => game.id), contains(project.id));
    await expectLater(
      catalog.deleteDirectory(project.id, 'app'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      catalog.writeFile(project.id, 'main.json', utf8.encode('{}')),
      throwsA(isA<FormatException>()),
    );
    final manifestJson =
        Map<String, Object?>.from(
            jsonDecode(utf8.decode(manifest.bytes)) as Map,
          )
          ..['name'] = 'Updated Game'
          ..['tags'] = ['party', 'motion'];
    final updatedManifest = await catalog.updateManifest(
      project.id,
      manifestJson,
      expectedRevision: 0,
    );
    expect(updatedManifest.readOnly, isTrue);
    expect(utf8.decode(updatedManifest.bytes), contains('Updated Game'));
    expect(utf8.decode(updatedManifest.bytes), contains('motion'));
    expect(
      repository.cachedGames.singleWhere((game) => game.id == project.id).name,
      'Updated Game',
    );
    await expectLater(
      catalog.updateManifest(project.id, {
        ...manifestJson,
        'id': 'com.example.changed-id',
      }),
      throwsA(isA<FormatException>()),
    );
    final saved = await catalog.writeFile(
      project.id,
      'app/static/js/shared/new.js',
      utf8.encode('export const ready = true;\n'),
      expectedRevision: 0,
    );
    await catalog.createDirectory(project.id, 'app/static/empty');
    expect(saved.revision, 1);
    expect(
      await catalog.listDirectories(project.id),
      contains('app/static/empty'),
    );
    await catalog.deleteDirectory(project.id, 'app/static/empty');
    expect(
      await catalog.listDirectories(project.id),
      isNot(contains('app/static/empty')),
    );
    final history = await catalog.listLocalHistory(project.id, '');
    expect(history, hasLength(1));
    final historyDiff = await catalog.localHistoryDiff(
      project.id,
      history.single.id,
      'app/static/js/shared/new.js',
    );
    expect(
      historyDiff.changes,
      contains(
        isA<DeveloperLocalHistoryChange>().having(
          (change) => change.change,
          'change',
          'added',
        ),
      ),
    );
    await catalog.restoreLocalHistory(
      project.id,
      history.single.id,
      'app/static/js/shared/new.js',
      DeveloperHistoryVersion.before,
    );
    await expectLater(
      catalog.readFile(project.id, 'app/static/js/shared/new.js'),
      throwsA(isA<StateError>()),
    );
    await catalog.restoreLocalHistory(
      project.id,
      history.single.id,
      'app/static/js/shared/new.js',
      DeveloperHistoryVersion.after,
    );
    expect(
      utf8.decode(
        (await catalog.readFile(
          project.id,
          'app/static/js/shared/new.js',
        )).bytes,
      ),
      contains('ready = true'),
    );
    expect(
      await catalog.validateProject(project.id),
      isA<DeveloperProjectValidationReport>(),
    );
    expect((await catalog.validateProject(project.id)).valid, isTrue);
    expect(await catalog.prepareGame(project.id), isA<GameSummary>());

    final projectDirectory = Directory('${workspace.path}/${project.id}');
    final dataDirectory = Directory('${projectDirectory.path}/data');
    final cacheDirectory = Directory('${projectDirectory.path}/cache');
    await dataDirectory.create(recursive: true);
    await File('${dataDirectory.path}/save.json').writeAsString('{}');
    await cacheDirectory.create(recursive: true);
    await File('${cacheDirectory.path}/history.json').writeAsString('{}');

    expect(await catalog.clearGameData(project.id), isTrue);
    expect(await dataDirectory.exists(), isFalse);
    expect(await cacheDirectory.exists(), isTrue);
    expect(await File('${cacheDirectory.path}/history.json').exists(), isTrue);
    expect(await catalog.clearGameData(project.id), isFalse);

    await catalog.deleteFile(
      project.id,
      'app/static/js/service/index.js',
      expectedRevision: 0,
    );
    final invalid = await catalog.validateProject(project.id);
    expect(invalid.valid, isFalse);
    expect(
      invalid.diagnostics.map((item) => item.code),
      contains('authority_entry_missing'),
    );
    await expectLater(
      catalog.prepareGame(project.id),
      throwsA(isA<DeveloperProjectValidationFailure>()),
    );
  });

  test('开发者 API 可视化保存清单和能力声明但拒绝修改 id', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-manifest-api-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final repository = GameLibraryRepository(AssetGameLibraryScanner().scan);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );
    final project = await catalog.createProject(
      const DeveloperProjectDraft(
        id: 'com.example.visual-settings',
        name: 'Visual Settings',
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 2,
        maxPlayers: 4,
      ),
    );
    final runtime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerProjectCatalog: catalog,
      developerPreferences: DeveloperPreferences(libraryRoot: workspace),
    );
    addTearDown(runtime.close);
    final port = await _availablePort();
    await runtime.enableDeveloperMode(port: port, token: 'manifest-api-token');
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    Uri endpoint(String suffix) => base.resolve(
      '/dev/api/projects/${project.id}/$suffix?token=manifest-api-token',
    );

    final read = await http.get(endpoint('manifest'));
    final readBody = jsonDecode(read.body) as Map<String, Object?>;
    final manifest = Map<String, Object?>.from(readBody['manifest']! as Map)
      ..['name'] = '可视化设置游戏'
      ..['tags'] = ['体感', '聚会'];
    final saved = await http.put(
      endpoint('manifest'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'manifest': manifest,
        'baseRevision': readBody['revision'],
      }),
    );
    expect(saved.statusCode, HttpStatus.ok, reason: saved.body);
    expect((jsonDecode(saved.body) as Map)['manifest']['id'], project.id);
    expect((jsonDecode(saved.body) as Map)['manifest']['tags'], ['体感', '聚会']);

    final changedId = await http.put(
      endpoint('manifest'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'manifest': {...manifest, 'id': 'com.example.changed'},
      }),
    );
    expect(changedId.statusCode, HttpStatus.badRequest);

    final savedCapabilities = await http.put(
      endpoint('capabilities'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'required': ['sensor.accelerometer', 'sensor.gyroscope'],
        'baseRevision': 0,
      }),
    );
    expect(savedCapabilities.statusCode, HttpStatus.ok);
    expect((jsonDecode(savedCapabilities.body) as Map)['exists'], isTrue);
    final capabilityPrompt = await http.get(endpoint('agent-prompt.txt'));
    expect(capabilityPrompt.statusCode, HttpStatus.ok);
    expect(
      capabilityPrompt.body,
      contains(
        '当前 capabilities.json.required：sensor.accelerometer, sensor.gyroscope',
      ),
    );
    final capabilityRevision =
        (jsonDecode(savedCapabilities.body) as Map)['revision'];
    final removedCapabilities = await http.put(
      endpoint('capabilities'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'required': <String>[],
        'baseRevision': capabilityRevision,
      }),
    );
    expect(removedCapabilities.statusCode, HttpStatus.ok);
    expect((jsonDecode(removedCapabilities.body) as Map)['exists'], isFalse);
  });

  test('可以创建不包含控制器和 Authority 入口的单机骨架', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-solo-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(AssetGameLibraryScanner().scan),
      workspaceRoot: workspace,
    );

    final project = await catalog.createProject(
      const DeveloperProjectDraft(
        id: 'com.example.solo-game',
        name: 'Solo Game',
        mode: 'solo',
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 1,
        maxPlayers: 1,
      ),
    );
    final files = await catalog.listFiles(project.id);
    final manifest = utf8.decode(
      (await catalog.readFile(project.id, 'main.json')).bytes,
    );

    expect(files, contains('app/static/js/player/index.js'));
    expect(files, isNot(contains('app/controller/index.html')));
    expect(files, isNot(contains('app/static/js/service/index.js')));
    expect(manifest, contains('"solo"'));
    expect(manifest, isNot(contains('"authority"')));
    expect((await catalog.validateProject(project.id)).valid, isTrue);
  });
}

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _FakeCatalog implements DeveloperProjectCatalog {
  const _FakeCatalog();

  @override
  Future<List<DeveloperProject>> listProjects() async => const [
    DeveloperProject(
      id: 'demo',
      name: 'Demo',
      version: '1.0.0',
      rootAssetPath: 'assets/demo',
      readOnly: true,
    ),
  ];

  @override
  Future<DeveloperProject> createProject(DeveloperProjectDraft draft) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listFiles(String projectId) async => const [
    'app/index.html',
    'main.json',
  ];

  @override
  Future<List<String>> listDirectories(String projectId) async => const ['app'];

  @override
  Future<void> createDirectory(String projectId, String path) =>
      throw UnimplementedError();

  @override
  Future<void> deleteDirectory(String projectId, String path) =>
      throw UnimplementedError();

  @override
  Future<void> copyEntry(String projectId, String source, String destination) =>
      throw UnimplementedError();

  @override
  Future<void> moveEntry(String projectId, String source, String destination) =>
      throw UnimplementedError();

  @override
  Future<List<String>> extractZip(
    String projectId,
    String archivePath,
    String destinationDirectory,
  ) => throw UnimplementedError();

  @override
  Future<DeveloperProjectFile> readFile(String projectId, String path) async {
    final content = path == 'main.json'
        ? '{"id":"demo","modes":["multiplayer"],'
              '"displayModes":["multi_screen"],'
              '"authority":{"entry":"app/static/js/service/index.js"}}'
        : '<!doctype html><title>Demo</title>';
    return DeveloperProjectFile(
      path: path,
      bytes: Uint8List.fromList(utf8.encode(content)),
      contentType: path.endsWith('.json')
          ? 'application/json; charset=utf-8'
          : 'text/html; charset=utf-8',
    );
  }

  @override
  Future<DeveloperProjectFile> updateManifest(
    String projectId,
    Map<String, Object?> manifest, {
    int? expectedRevision,
  }) => throw UnimplementedError();

  @override
  Future<DeveloperProjectFile> writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  }) => throw UnimplementedError();

  @override
  Future<List<DeveloperProjectFile>> writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  }) => throw UnimplementedError();

  @override
  Future<DeveloperFileDiff> diffFile(String projectId, String path) =>
      throw UnimplementedError();

  @override
  Future<List<DeveloperLocalHistoryOperation>> listLocalHistory(
    String projectId,
    String path,
  ) async => const [];

  @override
  Future<DeveloperLocalHistoryDiff> localHistoryDiff(
    String projectId,
    String operationId,
    String path,
  ) => throw UnimplementedError();

  @override
  Future<void> restoreLocalHistory(
    String projectId,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  ) => throw UnimplementedError();

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async => const DeveloperProjectValidationReport(
    projectId: 'demo',
    diagnostics: [],
    fileCount: 2,
    totalBytes: 64,
  );

  @override
  Future<bool> clearGameData(String projectId) async => true;

  @override
  Future<GameSummary> prepareGame(String projectId) async => const GameSummary(
    id: 'demo',
    name: 'Demo',
    version: '1.0.0',
    description: '',
    minPlayers: 2,
    maxPlayers: 5,
    supportsMultiplayer: true,
    displayModeLabel: '多屏',
    displayMode: 'multi_screen',
    orientation: GameOrientation.landscape,
    entry: LocalGameEntry(
      assetPath: 'assets/demo/app/index.html',
      statusLabel: '开发项目',
      packageRootAssetPath: 'assets/demo',
    ),
  );
}

class _UnavailableSensorSource implements AppSensorSource {
  @override
  Set<AppSensorType> get availableTypes => const {};

  @override
  Stream<AppSensorSample> events(
    AppSensorType type, {
    required Duration samplingPeriod,
  }) => Stream.error(UnsupportedError('测试环境无传感器'));
}

class _StubHost implements GoCoreHost {
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _StubHealthClient implements GoCoreHealthClient {
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:43210/health');

  @override
  Future<GoCoreStatus> fetchHealth({String? requestId}) async => GoCoreStatus(
    requestId: requestId ?? 'request-id',
    status: 'online',
    coreVersion: '0.1.0',
    timestamp: DateTime.utc(2026, 7, 16),
    startedAt: DateTime.utc(2026, 7, 16),
  );

  @override
  void close() {}
}
