import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_ai_prompt_templates.dart';
import 'package:playmesh/core/developer/developer_background_host.dart';
import 'package:playmesh/core/developer/developer_capability_test_service.dart';
import 'package:playmesh/core/developer/developer_event_hub.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/developer_preferences.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_share_files.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';
import 'package:playmesh/core/lifecycle/go_core_host.dart';
import 'package:playmesh/core/network/go_core_client.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_runtime.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

import '../../support/gdevelop_editor_lease_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('开发者通道使用独立固定端口并读取项目和文件', () async {
    final port = await _availablePort();
    final promptRoot = await Directory.systemTemp.createTemp(
      'playmesh-ai-prompts-',
    );
    final gdevelopProjectsRoot = await Directory.systemTemp.createTemp(
      'playmesh-gdevelop-gateway-projects-',
    );
    var restartCount = 0;
    var stopCount = 0;
    var workspaceLocaleId = 'zh-CN';
    var workspaceLocaleMode = 'system';
    var workspaceThemeMode = 'system';
    var workspaceEffectiveTheme = 'light';
    final executedJavaScript = <String>[];
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
    final unregisterJavaScript = runController.registerJavaScriptExecutor(
      'demo',
      (source) async {
        executedJavaScript.add(source);
        return {'title': 'Demo', 'answer': 42};
      },
    );
    addTearDown(unregisterJavaScript);
    final runtime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerProjectCatalog: _FakeCatalog(),
      developerAiPromptTemplates: DeveloperAiPromptTemplateStore(
        root: promptRoot,
      ),
      developerPreferences: DeveloperPreferences(libraryRoot: promptRoot),
      developerRunController: runController,
      developerCapabilityTests: DeveloperCapabilityTestService(),
      developerGDevelopWebIdeSource: _MemoryGDevelopWebIdeSource(),
      developerGDevelopHistory: GDevelopProjectHistoryAdapter(
        rootResolver: FileSystemGDevelopProjectRootResolver(
          projectsRoot: gdevelopProjectsRoot,
        ),
      ),
      developerWorkspaceLocalizationBridge:
          DeveloperWorkspaceLocalizationBridge(
            current: () => DeveloperWorkspaceLocalization(
              localeId: workspaceLocaleId,
              localeMode: workspaceLocaleMode,
              defaultLocale: 'zh-CN',
              allowLocaleSwitch: true,
              themeMode: workspaceThemeMode,
              effectiveTheme: workspaceEffectiveTheme,
              allowThemeSwitch: true,
              locales: const [
                DeveloperWorkspaceLocale(id: 'zh-CN', label: '简体中文'),
                DeveloperWorkspaceLocale(id: 'en-US', label: 'English'),
              ],
              messages: {
                'workspace.title': workspaceLocaleId == 'zh-CN'
                    ? 'Playmesh 开发者工作区'
                    : 'Playmesh Developer Workspace',
                'workspace.gdevelop_ai.title': 'AI 开发',
                'workspace.gdevelopLeak': 'must not enter bootstrap',
                'developer.prompt.runtime.gdevelop.secret':
                    'must not enter localization',
              },
            ),
            resolve: (localeId) => DeveloperWorkspaceLocalization(
              localeId: localeId.toLowerCase().startsWith('en')
                  ? 'en-US'
                  : 'zh-CN',
              localeMode: workspaceLocaleMode,
              defaultLocale: 'zh-CN',
              allowLocaleSwitch: true,
              themeMode: workspaceThemeMode,
              effectiveTheme: workspaceEffectiveTheme,
              allowThemeSwitch: true,
              locales: const [
                DeveloperWorkspaceLocale(id: 'zh-CN', label: '简体中文'),
                DeveloperWorkspaceLocale(id: 'en-US', label: 'English'),
              ],
              messages: {
                'workspace.gdevelop_ai.title':
                    localeId.toLowerCase().startsWith('en')
                    ? 'Local AI'
                    : '本地 AI',
                'workspace.gdevelopLeak': 'must not enter query response',
                'developer.prompt.runtime.gdevelop.secret':
                    'must not enter localization',
              },
            ),
            useLocale: (localeId) async {
              workspaceLocaleMode = localeId == null ? 'system' : 'fixed';
              workspaceLocaleId = localeId ?? 'zh-CN';
            },
            useTheme: (themeMode) async {
              workspaceThemeMode = themeMode;
              workspaceEffectiveTheme = themeMode == 'dark' ? 'dark' : 'light';
            },
          ),
    );
    addTearDown(runtime.close);
    addTearDown(() => promptRoot.delete(recursive: true));
    addTearDown(() => gdevelopProjectsRoot.delete(recursive: true));

    final session = await runtime.enableDeveloperMode(
      port: port,
      token: 'custom-dev-token',
    );
    final links = await runtime.sourceWorkspaceLinks(session);
    final visualLinks = await runtime.gdevelopWorkspaceLinks(session);

    expect(session.port, port);
    expect(runtime.endpoint.port, 43210);
    expect(links, isNotEmpty);
    expect(links.first.uri.port, port);
    expect(links.first.uri.queryParameters['token'], 'custom-dev-token');
    expect(visualLinks, isNotEmpty);
    expect(visualLinks.first.uri.path, '/dev/${session.path}/gdevelop/');

    // A normal LAN browser has no App-injected channel. It exchanges the
    // one-shot query token for an HttpOnly cookie, removes the token from the
    // redirected URL, and then uses that cookie for every App-authoritative
    // project operation (including non-GET requests).
    final browserClient = _plainHttpClient();
    addTearDown(browserClient.close);
    final browserBootstrapRequest = _plainHttpRequest(
      'GET',
      visualLinks.first.uri,
    )..followRedirects = false;
    final browserBootstrap = await browserClient.send(browserBootstrapRequest);
    final browserLocation = browserBootstrap.headers['location'];
    final browserSetCookie = browserBootstrap.headers['set-cookie'];
    await browserBootstrap.stream.drain<void>();
    expect(browserBootstrap.statusCode, HttpStatus.seeOther);
    expect(browserLocation, visualLinks.first.uri.path);
    expect(browserLocation, isNot(contains('token=')));
    expect(browserSetCookie, isNotNull);
    final browserCookie = browserSetCookie!.split(';').first;
    final browserLease = await GDevelopEditorLeaseTestClient.acquire(
      baseUri: visualLinks.first.uri,
      workspaceUri: visualLinks.first.uri,
      developerToken: 'custom-dev-token',
    );
    addTearDown(browserLease.release);
    final browserHeaders = <String, String>{
      HttpHeaders.cookieHeader: browserCookie,
      ...browserLease.leaseHeaders,
    };
    final browserProjectsBefore = await browserClient.get(
      visualLinks.first.uri.resolve('/dev/api/gdevelop/projects'),
      headers: browserHeaders,
    );
    expect(browserProjectsBefore.statusCode, HttpStatus.ok);
    final browserCreate = await browserClient.post(
      visualLinks.first.uri.resolve('/dev/api/gdevelop/projects'),
      headers: {
        ...browserHeaders,
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode({
        'gameId': 'com.playmesh.test.lanbrowser',
        'origin': 'create',
        'fileIdentifier': 'lan-browser-file',
        'name': 'LAN browser project',
      }),
    );
    expect(
      browserCreate.statusCode,
      HttpStatus.created,
      reason: browserCreate.body,
    );
    final browserOpen = await browserClient.post(
      visualLinks.first.uri.resolve(
        '/dev/api/gdevelop/projects/com.playmesh.test.lanbrowser/open',
      ),
      headers: {
        ...browserHeaders,
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode({
        'fileIdentifier': 'lan-browser-file',
        'name': 'LAN browser project',
      }),
    );
    expect(browserOpen.statusCode, HttpStatus.ok, reason: browserOpen.body);
    final browserCurrent = await browserClient.get(
      visualLinks.first.uri.resolve(
        '/dev/api/gdevelop/projects/com.playmesh.test.lanbrowser/history/current',
      ),
      headers: browserHeaders,
    );
    expect(
      browserCurrent.statusCode,
      HttpStatus.ok,
      reason: browserCurrent.body,
    );

    final currentVisualLink = (await runtime.gdevelopWorkspaceLinks(
      session,
    )).first.uri;
    final gdevelop = await _openWorkspaceBootstrapLink(currentVisualLink);
    expect(gdevelop.statusCode, HttpStatus.ok);
    expect(gdevelop.body, contains('PLAYMESH_GDEVELOP_TEST'));
    expect(gdevelop.headers['content-type'], contains('text/html'));
    expect(
      gdevelop.body,
      contains('__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__'),
    );
    expect(gdevelop.body, contains('__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__'));
    expect(gdevelop.body, contains(r'"enabled":true'));
    expect(gdevelop.body, contains('"localeId":"zh-CN"'));
    expect(gdevelop.body, contains('workspace.gdevelop_ai.title'));
    expect(gdevelop.body, isNot(contains('workspace.gdevelopLeak')));
    expect(
      gdevelop.body,
      isNot(contains('developer.prompt.runtime.gdevelop.secret')),
    );
    expect(
      gdevelop.headers['cache-control'],
      'no-store, no-cache, must-revalidate',
    );
    expect(
      gdevelop.body.indexOf('__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__'),
      lessThan(gdevelop.body.indexOf('PLAYMESH_GDEVELOP_TEST')),
    );

    final workspace = await _openWorkspaceBootstrapLink(links.first.uri);
    expect(workspace.statusCode, HttpStatus.ok);
    expect(workspace.headers['referrer-policy'], 'no-referrer');
    expect(workspace.headers['x-content-type-options'], 'nosniff');
    expect(workspace.body, contains('data-i18n="workspace.brand"'));
    expect(workspace.body, contains('workspace-localization.js'));
    expect(
      workspace.body,
      contains(
        '"themeMode":"system","effectiveTheme":"light",'
        '"allowThemeSwitch":true',
      ),
    );
    expect(
      workspace.body,
      contains(
        '"features":{"gdevelopAi":{"formatVersion":"1.0.0",'
        '"enabled":true',
      ),
    );
    expect(workspace.body, isNot(contains('__PLAYMESH_APP_UI_BOOTSTRAP__')));
    expect(workspace.body, contains('id="aiPanel" class="ai-action"'));
    expect(
      workspace.body.indexOf('id="aiPanel"'),
      lessThan(workspace.body.indexOf('</header>')),
    );
    expect(workspace.body, contains('id="projectPickerMenu"'));
    expect(workspace.body, contains('id="projectSettingsFromPicker"'));
    expect(workspace.body, contains('id="copyProjectFromPicker"'));
    expect(workspace.body, contains('id="deleteProjectFromPicker"'));
    expect(workspace.body, contains('id="manifestForm"'));
    expect(
      workspace.body,
      contains(
        'id="manifestSdkVersion" name="manifestSdkVersion" required '
        'pattern="\\d+\\.\\d+\\.\\d+" autocomplete="off" readonly',
      ),
    );
    expect(
      workspace.body,
      contains('data-i18n="workspace.sdk_version_managed_help"'),
    );
    expect(workspace.body, isNot(contains('id="manifestId"')));
    expect(workspace.body, isNot(contains('id="manifestAuthor"')));
    expect(workspace.body, isNot(contains('id="manifestIcon"')));
    expect(workspace.body, isNot(contains('id="manifestPermissions"')));
    expect(workspace.body, contains('id="publishModal"'));
    expect(workspace.body, contains('id="publishForm"'));
    expect(workspace.body, contains('id="publishSources"'));
    expect(workspace.body, contains('id="retryPublish"'));
    expect(workspace.body, contains('id="manifestTags"'));
    expect(workspace.body, contains('id="capabilityOptions"'));
    expect(workspace.body, contains('id="capabilityTests"'));
    expect(workspace.body, contains('id="capabilityTestModal"'));
    expect(workspace.body, contains('id="capabilityTestDetail"'));
    expect(workspace.body, contains('id="capabilityTestLog"'));
    expect(workspace.body, contains('id="clearGameData"'));
    expect(workspace.body, contains('data-i18n="workspace.clear_game_data"'));
    expect(workspace.body, contains('id="projectDescription"'));
    expect(workspace.body, contains('id="projectTags"'));
    expect(workspace.body, contains('id="projectCapabilityOptions"'));
    expect(workspace.body, contains('id="copyCurrentFile"'));
    expect(workspace.body, contains('id="projectPicker"'));
    expect(workspace.body, contains('id="projectSearch"'));
    expect(workspace.body, contains('id="toolbarMenu"'));
    expect(workspace.body, contains('id="diffMergeHost"'));
    expect(
      workspace.body,
      contains('data-i18n="workspace.conversation_console"'),
    );
    expect(workspace.body, contains('id="aiApprovalModal"'));
    expect(workspace.body, contains('data-i18n="workspace.ai_allow_once"'));
    expect(workspace.body, contains('data-i18n="workspace.ai_allow_project"'));
    expect(workspace.body, contains('data-i18n="workspace.ai_allow_always"'));
    expect(workspace.body, contains('id="historyMergeHost"'));
    expect(workspace.body, contains('codemirror/addon/merge/merge.js'));
    expect(workspace.body, contains('diff-match-patch/index.js'));
    expect(workspace.body, contains('id="stop"'));
    expect(workspace.body, contains('id="diffLeftFile"'));
    expect(workspace.body, contains('addon/hint/javascript-hint.js'));
    expect(
      workspace.body,
      contains('data-i18n="workspace.get_project_prompts"'),
    );
    expect(workspace.body, contains('id="copyPlatformCapabilities"'));
    expect(workspace.body, contains('id="agentBaseUrl"'));
    expect(workspace.body, contains('id="webviewJavaScriptPanel"'));
    expect(workspace.body, contains('id="webviewJavaScriptModal"'));
    expect(workspace.body, contains('id="webviewJavaScriptHistory"'));
    expect(workspace.body, contains('/playmesh/developer/workspace-icons.js'));
    expect(workspace.body, contains('href="#play"'));
    expect(workspace.body, isNot(contains('/playmesh/developer/lucide.svg#')));
    expect(workspace.body, isNot(contains('cdn')));
    expect(workspace.body, isNot(matches(RegExp(r'[\u3400-\u9fff]'))));

    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    final http = _DeveloperBearerClient('custom-dev-token');
    addTearDown(http.close);
    final localization = await http.get(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
    );
    expect(localization.statusCode, HttpStatus.ok);
    expect(
      localization.headers['x-playmesh-operation-id'],
      'workspace.localization',
    );
    final localizationJson = Map<String, Object?>.from(
      jsonDecode(localization.body) as Map,
    );
    expect(localizationJson['formatVersion'], '1.0.0');
    expect(localizationJson['localeId'], 'zh-CN');
    expect(localizationJson['localeMode'], 'system');
    expect(localizationJson['themeMode'], 'system');
    expect(localizationJson['effectiveTheme'], 'light');
    expect(localizationJson['allowThemeSwitch'], isTrue);
    expect(localization.headers['referrer-policy'], 'no-referrer');
    expect(localization.headers['x-content-type-options'], 'nosniff');
    expect(
      localizationJson['messages'],
      containsPair('workspace.title', 'Playmesh 开发者工作区'),
    );

    final exactSessionLocalization = await http.get(
      base.resolve('/dev/api/localization?token=custom-dev-token&locale=en-US'),
    );
    expect(exactSessionLocalization.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(exactSessionLocalization.body),
      allOf(
        containsPair('localeId', 'en-US'),
        containsPair('resolvedLocale', 'en-US'),
      ),
    );
    expect(
      exactSessionLocalization.body,
      isNot(contains('workspace.gdevelopLeak')),
    );
    expect(
      exactSessionLocalization.body,
      isNot(contains('developer.prompt.runtime.gdevelop.secret')),
    );
    final baseSessionLocalization = await http.get(
      base.resolve('/dev/api/localization?token=custom-dev-token&locale=en_GB'),
    );
    expect(baseSessionLocalization.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(baseSessionLocalization.body),
      containsPair('localeId', 'en-US'),
    );
    final fallbackSessionLocalization = await http.get(
      base.resolve('/dev/api/localization?token=custom-dev-token&locale=xx-ZZ'),
    );
    expect(fallbackSessionLocalization.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(fallbackSessionLocalization.body),
      containsPair('localeId', 'zh-CN'),
    );
    final unchangedLocalization = await http.get(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
    );
    expect(
      jsonDecode(unchangedLocalization.body),
      allOf(
        containsPair('localeId', 'zh-CN'),
        isNot(contains('resolvedLocale')),
      ),
      reason: '只读 session locale 解析不得调用 App updater',
    );
    final invalidSessionLocalization = await http.get(
      base.resolve(
        '/dev/api/localization?token=custom-dev-token&locale=en%0d%0aevil',
      ),
    );
    expect(invalidSessionLocalization.statusCode, HttpStatus.badRequest);

    final switchedLocalization = await http.put(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'localeId': 'en-US'}),
    );
    expect(switchedLocalization.statusCode, HttpStatus.ok);
    expect(
      switchedLocalization.headers['x-playmesh-operation-id'],
      'workspace.localization_update',
    );
    final switchedLocalizationJson = Map<String, Object?>.from(
      jsonDecode(switchedLocalization.body) as Map,
    );
    expect(switchedLocalizationJson['localeId'], 'en-US');
    expect(switchedLocalizationJson['localeMode'], 'fixed');
    expect(
      switchedLocalizationJson['messages'],
      containsPair('workspace.title', 'Playmesh Developer Workspace'),
    );

    final systemLocalization = await http.put(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'localeId': null}),
    );
    expect(systemLocalization.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(systemLocalization.body),
      containsPair('localeMode', 'system'),
    );

    final themedLocalization = await http.put(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'themeMode': 'dark'}),
    );
    expect(themedLocalization.statusCode, HttpStatus.ok);
    final themedLocalizationJson = Map<String, Object?>.from(
      jsonDecode(themedLocalization.body) as Map,
    );
    expect(themedLocalizationJson['localeMode'], 'system');
    expect(themedLocalizationJson['themeMode'], 'dark');
    expect(themedLocalizationJson['effectiveTheme'], 'dark');

    final combinedUiUpdate = await http.put(
      base.resolve('/dev/api/localization?token=custom-dev-token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'localeId': 'en-US', 'themeMode': 'light'}),
    );
    expect(combinedUiUpdate.statusCode, HttpStatus.ok);
    expect(
      jsonDecode(combinedUiUpdate.body),
      allOf(
        containsPair('localeId', 'en-US'),
        containsPair('themeMode', 'light'),
        containsPair('effectiveTheme', 'light'),
      ),
    );

    final workspaceScript = await http.get(
      base.resolve('/playmesh/developer/workspace.js?token=custom-dev-token'),
    );
    expect(workspaceScript.statusCode, HttpStatus.ok);
    expect(workspaceScript.headers['referrer-policy'], 'no-referrer');
    expect(workspaceScript.headers['x-content-type-options'], 'nosniff');
    expect(workspaceScript.body, isNot(contains('localStorage')));
    expect(
      workspaceScript.body,
      contains('webviewJavaScriptHistoryByProject=new Map()'),
    );
    expect(workspaceScript.body, contains('data.activeProjectId'));
    expect(workspaceScript.body, contains('openProjectPicker()'));
    expect(workspaceScript.body, contains('positionAnchoredMenu'));
    expect(workspaceScript.body, contains('CodeMirror.MergeView'));
    expect(workspaceScript.body, contains('executeConversationConsole'));
    expect(workspaceScript.body, contains("'X-Playmesh-AI-Channel':'chat'"));
    expect(workspaceScript.body, contains("'ai.approval.requested'"));
    expect(workspaceScript.body, contains('executeWebViewJavaScript'));
    expect(workspaceScript.body, contains('webviewJavaScriptHistory'));
    expect(workspaceScript.body, contains('applyHistoryChunks'));
    expect(workspaceScript.body, contains('appendCapabilityTestJson'));
    expect(workspaceScript.body, contains('createCapabilitySchemaEditor'));
    expect(workspaceScript.body, contains('capabilitySchemaNode'));
    expect(workspaceScript.body, contains("'capability.test.event'"));
    expect(workspaceScript.body, isNot(contains('capabilityDraftText')));
    expect(workspaceScript.body, contains('copyPlatformCapabilities'));
    expect(workspaceScript.body, contains('openPublishPanel'));
    expect(workspaceScript.body, contains('JSON.stringify({sourceIds})'));
    expect(
      workspaceScript.body,
      contains("bindMenuKeyboard(q('moreActions'),toolbarMenu"),
    );
    expect(workspaceScript.body, isNot(contains('manifestIcon')));
    expect(workspaceScript.body, isNot(contains('manifestPermissions')));
    expect(
      workspaceScript.body,
      isNot(contains('delete manifest.permissions')),
    );
    expect(workspaceScript.body, isNot(contains('delete manifest.icon')));
    expect(workspaceScript.body, isNot(contains('...manifestSource')));
    expect(
      workspaceScript.body,
      contains('manifestFromForm(sdk.gameSdkVersion,sdk.appSdkVersion)'),
    );
    expect(workspaceScript.body, contains("sdk=await api('/dev/api/status')"));
    final projectSettingsSdkLookup = workspaceScript.body.indexOf(
      "sdk=await api('/dev/api/status')",
    );
    expect(
      workspaceScript.body.indexOf(
        "api(endpoint('manifest',''),{method:'PUT'",
        projectSettingsSdkLookup,
      ),
      greaterThan(projectSettingsSdkLookup),
    );
    expect(
      workspaceScript.body,
      isNot(contains("sdkVersion:q('manifestSdkVersion').value")),
    );
    expect(workspaceScript.body, isNot(contains('uploadKey')));
    final gatewaySource = await File(
      'lib/core/developer/developer_web_gateway_io.dart',
    ).readAsString();
    expect(gatewaySource, contains('_developerOperationRegistry.dispatch'));
    expect(gatewaySource, contains("..set('Referrer-Policy', 'no-referrer')"));
    expect(
      gatewaySource,
      contains("..set('X-Content-Type-Options', 'nosniff')"),
    );
    expect(
      gatewaySource,
      contains(
        "workspaceTemplate.replaceFirst(\n"
        "        '__PLAYMESH_APP_UI_BOOTSTRAP__',",
      ),
    );
    final dispatchSource = gatewaySource.substring(
      gatewaySource.indexOf('Future<void> _dispatch'),
      gatewaySource.indexOf('String _requireCurrentAuthor'),
    );
    expect(
      RegExp(r'''['"]/dev(?:/|['"])''').allMatches(dispatchSource),
      isEmpty,
      reason: '所有 Developer 接口必须通过统一操作注册表，不得在网关分发入口手写旁路路由',
    );
    final workspaceStyles = await http.get(
      base.resolve('/playmesh/developer/workspace.css?token=custom-dev-token'),
    );
    expect(workspaceStyles.statusCode, HttpStatus.ok);
    expect(workspaceStyles.headers['referrer-policy'], 'no-referrer');
    expect(workspaceStyles.headers['x-content-type-options'], 'nosniff');
    expect(
      workspaceStyles.body,
      contains('grid-template-columns: minmax(112px, 1fr) repeat(4, 46px)'),
    );
    expect(workspaceStyles.body, contains('min-width: 180px'));
    expect(workspaceStyles.body, contains('@media (max-width: 360px)'));
    expect(
      workspaceStyles.body,
      contains('grid-template-columns: minmax(84px, 1fr) repeat(4, 42px)'),
    );
    final workspaceIcons = await http.get(
      base.resolve(
        '/playmesh/developer/workspace-icons.js?token=custom-dev-token',
      ),
    );
    expect(workspaceIcons.statusCode, HttpStatus.ok);
    expect(workspaceIcons.body, contains('"folder-kanban"'));
    expect(workspaceIcons.body, contains('"file-question"'));
    final status = await http.get(
      base.resolve('/dev/api/status?token=custom-dev-token'),
    );
    expect(status.statusCode, HttpStatus.ok);
    expect(status.headers['x-playmesh-operation-id'], 'workspace.status');
    final statusJson = Map<String, Object?>.from(
      jsonDecode(status.body) as Map,
    );
    final baseUrls = (statusJson['baseUrls']! as List).cast<String>();
    expect(baseUrls, isNotEmpty);
    expect(baseUrls, contains(base.toString()));
    expect(statusJson['gameSdkVersion'], '4.1.0');
    expect(statusJson['appSdkVersion'], '3.3.0');
    expect(
      statusJson['gameSdkCompatibility'],
      contains(containsPair('minimumRequestedVersion', '4.1.0')),
    );
    expect(
      statusJson['appSdkCompatibility'],
      contains(containsPair('minimumRequestedVersion', '3.2.0')),
    );
    expect(
      statusJson['appSdkCompatibility'],
      contains(containsPair('maximumRequestedVersion', '3.3.0')),
    );

    final sdkBundle = await http.get(
      base.resolve('/dev/api/sdk?token=custom-dev-token'),
    );
    expect(sdkBundle.statusCode, HttpStatus.ok);
    final sdkBundleJson = jsonDecode(sdkBundle.body) as Map;
    expect(sdkBundleJson['gameSdkVersion'], '4.1.0');
    expect(sdkBundleJson['appSdkVersion'], '3.3.0');
    expect(
      sdkBundleJson['gameSdkCompatibility'],
      contains(containsPair('bundleVersion', '4.1.0')),
    );
    expect(
      sdkBundleJson['appSdkCompatibility'],
      contains(containsPair('bundleVersion', '3.3.0')),
    );
    expect(
      (sdkBundleJson['files'] as Map).keys,
      containsAll([
        'playmesh-main.js',
        'playmesh-app.js',
        'playmesh-main.d.ts',
        'playmesh-app.d.ts',
      ]),
    );
    for (final name in const [
      'playmesh-main.js',
      'playmesh-app.js',
      'playmesh-main.d.ts',
      'playmesh-app.d.ts',
    ]) {
      expect(
        utf8.decode(
          base64Decode((sdkBundleJson['files'] as Map)[name] as String),
        ),
        SdkFeatureRegistry.sdkFile(name),
        reason: name,
      );
    }
    final publicSdk = await http.get(
      base.resolve('/playmesh/sdk/v1/playmesh-main.js?token=custom-dev-token'),
    );
    expect(publicSdk.statusCode, HttpStatus.ok);
    expect(publicSdk.body, SdkFeatureRegistry.sdkFile('playmesh-main.js'));

    final capabilityRegistry = await http.get(
      base.resolve('/dev/api/capabilities?token=custom-dev-token'),
    );
    expect(capabilityRegistry.statusCode, HttpStatus.ok);
    final capabilityItems =
        (jsonDecode(capabilityRegistry.body) as Map)['capabilities'] as List;
    expect(capabilityItems, contains(containsPair('code', 'media.camera')));
    expect(capabilityItems, everyElement(contains('supportedPlatforms')));
    expect(capabilityItems, everyElement(isNot(contains('appSupported'))));
    expect(capabilityItems, everyElement(isNot(contains('htmlSupported'))));
    expect(capabilityItems, everyElement(contains('apiVersion')));
    expect(capabilityItems, everyElement(contains('optionsSchema')));
    expect(capabilityItems, everyElement(contains('methods')));
    expect(capabilityItems, everyElement(contains('events')));
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
        'codes': ['device.midi'],
        'timeoutMs': 250,
      }),
    );
    expect(capabilityTestRun.statusCode, HttpStatus.ok);
    final capabilityTestResult = Map<String, Object?>.from(
      jsonDecode(capabilityTestRun.body) as Map,
    );
    expect(capabilityTestResult['total'], 1);
    final createdCapabilityInstance = await http.post(
      base.resolve(
        '/dev/api/capability-tests/instances?token=custom-dev-token',
      ),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'code': 'device.midi', 'options': <String, Object?>{}}),
    );
    expect(createdCapabilityInstance.statusCode, HttpStatus.created);
    final createdCapabilityJson =
        jsonDecode(createdCapabilityInstance.body) as Map<String, dynamic>;
    expect(createdCapabilityJson['code'], 'device.midi');
    expect(createdCapabilityJson['instanceId'], isNotEmpty);
    expect(capabilityTestResult['results'], isA<List>());
    final editorHint = await http.get(
      base.resolve(
        '/playmesh/developer/editor/node_modules/codemirror/'
        'addon/hint/javascript-hint.js',
      ),
    );
    expect(editorHint.statusCode, HttpStatus.ok);
    expect(editorHint.body, contains('additionalContext'));
    final mergeAddon = await http.get(
      base.resolve(
        '/playmesh/developer/editor/node_modules/codemirror/'
        'addon/merge/merge.js',
      ),
    );
    expect(mergeAddon.statusCode, HttpStatus.ok);
    expect(mergeAddon.body, contains('CodeMirror.MergeView'));
    final diffMatchPatch = await http.get(
      base.resolve(
        '/playmesh/developer/editor/node_modules/'
        'diff-match-patch/index.js',
      ),
    );
    expect(diffMatchPatch.statusCode, HttpStatus.ok);
    expect(diffMatchPatch.body, contains('diff_match_patch'));

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

    final sseClient = http.streamingClient();
    addTearDown(sseClient.close);
    final sseRequest = http.request(
      'GET',
      base.resolve('/dev/api/events?token=custom-dev-token'),
    );
    final sseResponse = await sseClient.send(sseRequest);
    expect(sseResponse.statusCode, HttpStatus.ok);
    expect(sseResponse.headers['referrer-policy'], 'no-referrer');
    expect(sseResponse.headers['x-content-type-options'], 'nosniff');
    final approvalEvent = sseResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.startsWith('data: '))
        .map((line) => jsonDecode(line.substring(6)) as Map)
        .firstWhere((event) => event['type'] == 'ai.approval.requested')
        .timeout(const Duration(seconds: 3));

    final rejectedDelete = http.delete(
      base.resolve('/dev/api/projects/demo/data?token=custom-dev-token'),
      headers: const {'X-Playmesh-AI-Channel': 'agent'},
    );
    final rejectedApproval = await _waitForAiApproval(
      base,
      token: 'custom-dev-token',
    );
    expect(rejectedApproval['operationId'], 'projects.clear_data');
    expect(rejectedApproval['channel'], 'agent');
    expect(rejectedApproval['timeoutSeconds'], 30);
    final notifiedApproval = await approvalEvent;
    expect(notifiedApproval['approvalId'], rejectedApproval['approvalId']);
    final rejectDecision = await http.post(
      base.resolve(
        '/dev/api/ai-approvals/${rejectedApproval['approvalId']}'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'decision': 'reject'}),
    );
    expect(rejectDecision.statusCode, HttpStatus.ok);
    final rejectedResponse = await rejectedDelete;
    expect(rejectedResponse.statusCode, HttpStatus.forbidden);
    expect(
      jsonDecode(rejectedResponse.body)['error']['code'],
      'ai_operation_rejected',
    );

    final approvedDelete = http.delete(
      base.resolve('/dev/api/projects/demo/data?token=custom-dev-token'),
      headers: const {'X-Playmesh-AI-Channel': 'chat'},
    );
    final approvedApproval = await _waitForAiApproval(
      base,
      token: 'custom-dev-token',
    );
    final allowDecision = await http.post(
      base.resolve(
        '/dev/api/ai-approvals/${approvedApproval['approvalId']}'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'decision': 'once'}),
    );
    expect(allowDecision.statusCode, HttpStatus.ok);
    final cleared = await approvedDelete;
    expect(cleared.statusCode, HttpStatus.ok, reason: cleared.body);
    expect(jsonDecode(cleared.body)['directory'], 'data');
    expect(jsonDecode(cleared.body)['cachePreserved'], isTrue);

    final stagedPackage = await http.post(
      base.resolve(
        '/dev/api/projects/demo/development/package?token=custom-dev-token',
      ),
      headers: const {HttpHeaders.contentTypeHeader: 'application/zip'},
      body: _developmentPackage('demo'),
    );
    expect(
      stagedPackage.statusCode,
      HttpStatus.created,
      reason: stagedPackage.body,
    );
    final packageId = jsonDecode(stagedPackage.body)['packageId'] as String;
    final run = await http.post(
      base.resolve('/dev/api/projects/demo/development?token=custom-dev-token'),
      headers: const {HttpHeaders.contentTypeHeader: 'application/json'},
      body: jsonEncode({
        'resourceBaseUrl': 'http://127.0.0.1:4173/',
        'credential': List<String>.filled(40, 'c').join(),
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
        'packageId': packageId,
      }),
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
    final executeJavaScript = await http.post(
      base.resolve(
        '/dev/api/projects/demo/webview/javascript'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'source': 'document.title'}),
    );
    expect(executeJavaScript.statusCode, HttpStatus.ok);
    final executeJavaScriptJson = jsonDecode(executeJavaScript.body) as Map;
    expect(executeJavaScriptJson['resultType'], 'object');
    expect(executeJavaScriptJson['result'], {'title': 'Demo', 'answer': 42});
    expect(executedJavaScript, ['document.title']);
    final mismatchedJavaScript = await http.post(
      base.resolve(
        '/dev/api/projects/another-project/webview/javascript'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'source': 'window.location.href'}),
    );
    expect(mismatchedJavaScript.statusCode, HttpStatus.notFound);
    expect(executedJavaScript, ['document.title']);

    final aiExecuteJavaScript = http.post(
      base.resolve(
        '/dev/api/projects/demo/webview/javascript'
        '?token=custom-dev-token',
      ),
      headers: const {
        'Content-Type': 'application/json',
        'X-Playmesh-AI-Channel': 'agent',
      },
      body: jsonEncode({'source': '1 + 1'}),
    );
    final javaScriptApproval = await _waitForAiApproval(
      base,
      token: 'custom-dev-token',
    );
    expect(
      javaScriptApproval['operationId'],
      'runtime.webview.execute_javascript',
    );
    final approveJavaScript = await http.post(
      base.resolve(
        '/dev/api/ai-approvals/${javaScriptApproval['approvalId']}'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'decision': 'once'}),
    );
    expect(approveJavaScript.statusCode, HttpStatus.ok);
    expect((await aiExecuteJavaScript).statusCode, HttpStatus.ok);
    expect(executedJavaScript, ['document.title', '1 + 1']);
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
    final projectsBody = jsonDecode(projects.body) as Map;
    expect(projectsBody['projects'], hasLength(1));
    expect(projectsBody['activeProjectId'], 'demo');

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
    expect(aiPrompt.body, contains('统一 SDK TypeScript 声明（唯一游戏接口事实源）'));
    expect(
      aiPrompt.body,
      contains('===== BEGIN SDK DECLARATION: playmesh-main.d.ts ====='),
    );
    expect(aiPrompt.body, contains('readonly version: "4.1.0"'));
    expect(
      aiPrompt.body,
      contains('===== BEGIN SDK DECLARATION: playmesh-app.d.ts ====='),
    );
    expect(aiPrompt.body, contains('playmesh.main.session.getCurrent()'));
    expect(aiPrompt.body, contains('playmesh.main.player.getCurrent()'));
    expect(aiPrompt.body, contains('playmesh.main.sync.submitAction(input)'));
    expect(
      aiPrompt.body,
      contains('playmesh.main.sync.startAuthority(options)'),
    );
    expect(aiPrompt.body, contains('playmesh.main.sync.observe'));
    expect(aiPrompt.body, contains('isAvailable(): boolean'));
    expect(aiPrompt.body, contains('playmesh.app.capabilities.create'));
    expect(aiPrompt.body, contains('onPlayerReconnect(callback)'));
    expect(aiPrompt.body, contains('playmesh.main.session.finish()'));
    expect(
      aiPrompt.body,
      contains('state: "lobby" | "running" | "paused" | "stopped"'),
    );
    expect(aiPrompt.body, contains('manifest API'));
    expect(aiPrompt.body, contains('绝对不能修改 `id`'));
    expect(aiPrompt.body, contains('entries.game: index.html'));
    expect(aiPrompt.body, contains('- [file] app/index.html'));
    expect(aiPrompt.body, contains('按需读取项目文件'));
    expect(aiPrompt.body, contains('本提示词不预载任何项目文件内容'));
    expect(aiPrompt.body, contains('通过 files.read 读取必要的文本文件'));
    expect(aiPrompt.body, contains('### files.read'));
    expect(aiPrompt.body, isNot(contains('===== BEGIN WORKSPACE FILE:')));
    expect(aiPrompt.body, isNot(contains('<title>Demo</title>')));
    expect(aiPrompt.body, contains('对话控制台默认基础指令'));
    expect(aiPrompt.body, contains('X-Playmesh-AI-Channel: chat'));
    expect(aiPrompt.body, isNot(contains('----replace_file:')));
    expect(aiPrompt.body, contains('只有非 Authority 多人页面'));
    expect(aiPrompt.body, contains('stateType 可选'));
    expect(aiPrompt.body, contains('getState()'));
    expect(aiPrompt.body, contains('多人 Player 页面在普通浏览器和 App WebView 中可用'));
    expect(aiPrompt.body, contains('当前 origin 的 localStorage'));
    expect(aiPrompt.body, contains('App 由宿主持久化'));
    expect(aiPrompt.body, contains('都同步当前 Core'));
    expect(
      aiPrompt.body,
      contains('single_screen_multiplayer 公共 Authority 屏不可用'),
    );
    expect(aiPrompt.body, isNot(contains('仅浏览器联机玩家可用')));
    expect(aiPrompt.body, isNot(contains('仅浏览器控制器可用')));
    expect(aiPrompt.body, isNot(contains('重载后 SDK 会自动请求最新快照')));
    expect(aiPrompt.body, contains('static/js/service/index.js'));
    expect(aiPrompt.body, contains('当前项目已声明的平台能力'));
    expect(aiPrompt.body, contains('未声明平台能力。'));
    expect(aiPrompt.body, contains('非敏感能力优先直接使用标准 Web API'));
    expect(
      aiPrompt.body,
      contains('`media.camera`、`media.microphone`、`device.midi`'),
    );
    expect(aiPrompt.body, contains('`<input type="file">`'));

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
    expect(agentPrompt.body, contains('baseUrl: $takeoverBaseUrl'));
    expect(
      agentPrompt.body,
      contains('Authorization: Bearer custom-dev-token'),
    );
    expect(agentPrompt.body, contains('X-Playmesh-AI-Channel: agent'));
    expect(agentPrompt.body, contains('拒绝返回 403'));
    expect(agentPrompt.body, contains('30 秒未决定返回 408'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/file'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/run/restart'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/run/stop'));
    expect(
      agentPrompt.body,
      contains('/dev/api/projects/demo/webview/javascript'),
    );
    expect(agentPrompt.body, contains('DELETE'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/data'));
    expect(agentPrompt.body, contains('保留 cache'));
    expect(agentPrompt.body, contains('/dev/api/logs'));
    expect(agentPrompt.body, contains('不必维持 SSE'));
    expect(agentPrompt.body, contains('isAvailable(): boolean'));
    expect(agentPrompt.body, contains('onPlayerReconnect(callback)'));
    expect(agentPrompt.body, contains('playmesh.main.session.finish()'));
    expect(agentPrompt.body, contains('manifest API'));
    expect(agentPrompt.body, contains('`id`、`author`、`lastModifiedAt` 不可修改'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/manifest'));
    expect(agentPrompt.body, contains('/dev/api/projects/demo/capabilities'));
    expect(agentPrompt.body, contains('/dev/api/capabilities'));
    expect(agentPrompt.body, contains('读取平台注册表中的全部能力声明'));
    expect(agentPrompt.body, contains('/dev/api/capability-tests'));
    expect(agentPrompt.body, contains('"timeoutMs": 3000'));
    expect(agentPrompt.body, contains('capabilities.required: 未声明'));
    expect(agentPrompt.body, contains('非敏感能力直接使用标准 Web API'));
    expect(
      agentPrompt.body,
      contains('`media.camera`、`media.microphone`、`device.midi`'),
    );
    expect(agentPrompt.body, contains('`<input type="file">`'));
    expect(agentPrompt.body, isNot(contains('平台统一能力注册表（code')));
    expect(agentPrompt.body, contains('entries.game: index.html'));
    expect(agentPrompt.body, contains('- [file] app/index.html'));
    expect(agentPrompt.body, contains('按需读取项目文件'));
    expect(agentPrompt.body, contains('本提示词不预载任何项目文件内容'));
    expect(agentPrompt.body, contains('通过 files.read 读取必要的文本文件'));
    expect(agentPrompt.body, contains('### files.read'));
    expect(agentPrompt.body, isNot(contains('===== BEGIN WORKSPACE FILE:')));
    expect(agentPrompt.body, isNot(contains('<title>Demo</title>')));
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
    expect(commonTemplate['content'], isNot(contains('playmesh.main.sync')));
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
      contains('playmesh.main.authority 或 playmesh.main.sync'),
    );
    final englishTemplates = await http.get(
      base.resolve(
        '/dev/api/ai-prompt-templates'
        '?token=custom-dev-token&locale=en-GB',
      ),
    );
    expect(englishTemplates.statusCode, HttpStatus.ok);
    final englishCategories =
        (jsonDecode(englishTemplates.body)['categories'] as List)
            .cast<Map<String, Object?>>();
    final englishCommon =
        (englishCategories.firstWhere(
                  (category) => category['id'] == 'common',
                )['items']
                as List)
            .cast<Map>()
            .firstWhere((item) => item['id'] == 'common');
    expect(englishCommon['locale'], 'en-US');
    expect(englishCommon['name'], 'Shared chat AI rules');
    expect(
      englishCommon['content'],
      contains('PLAYMESH CHAT AI GAME DEVELOPMENT PROMPT'),
    );
    final englishPrompt = await http.get(
      base.resolve(
        '/dev/api/projects/demo/chat-prompt.txt'
        '?token=custom-dev-token&locale=en-US',
      ),
    );
    expect(englishPrompt.statusCode, HttpStatus.ok);
    expect(englishPrompt.body, contains('Current project'));
    expect(englishPrompt.body, contains('Read project files on demand'));
    expect(englishPrompt.body, isNot(contains('当前项目')));
    expect(englishPrompt.body, isNot(matches(RegExp(r'[\u3400-\u9fff]'))));
    final customizedEnglish = await http.put(
      base.resolve(
        '/dev/api/ai-prompt-templates/common'
        '?token=custom-dev-token&locale=en-US',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'content': 'CUSTOM_ENGLISH_PROMPT'}),
    );
    expect(customizedEnglish.statusCode, HttpStatus.ok);
    expect(jsonDecode(customizedEnglish.body)['template']['locale'], 'en-US');
    final chineseAfterEnglishCustomization = await http.get(
      base.resolve(
        '/dev/api/projects/demo/chat-prompt.txt?token=custom-dev-token',
      ),
    );
    expect(
      chineseAfterEnglishCustomization.body,
      isNot(contains('CUSTOM_ENGLISH_PROMPT')),
    );
    final resetEnglish = await http.delete(
      base.resolve(
        '/dev/api/ai-prompt-templates/common'
        '?token=custom-dev-token&locale=en-US',
      ),
    );
    expect(resetEnglish.statusCode, HttpStatus.ok);
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

    final fileChanges = [
      {
        'type': 'create',
        'path': 'app/static/js/new/module.js',
        'content': 'export const createdByReplace = true;\n',
      },
      {
        'type': 'create',
        'path': 'app/static/css/new/theme.css',
        'content': 'body { color: white; }\n',
      },
    ];
    final changePreview = await http.post(
      base.resolve(
        '/dev/api/projects/demo/file-changes/preview'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'changes': fileChanges}),
    );
    expect(changePreview.statusCode, HttpStatus.ok);
    final previewJson = jsonDecode(changePreview.body) as Map;
    final previewFiles = (previewJson['files'] as List)
        .cast<Map<String, Object?>>();
    expect(
      previewFiles.map((file) => file['path']),
      containsAll([
        'app/static/js/new/module.js',
        'app/static/css/new/theme.css',
      ]),
    );
    expect(previewFiles.every((file) => file['created'] == true), isTrue);
    final changeApply = await http.post(
      base.resolve(
        '/dev/api/projects/demo/file-changes/apply'
        '?token=custom-dev-token',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'changes': fileChanges,
        'baseRevisions': previewJson['baseRevisions'],
        'clientId': 'gateway-test',
      }),
    );
    expect(changeApply.statusCode, HttpStatus.ok, reason: changeApply.body);
    expect((jsonDecode(changeApply.body)['applied'] as List), hasLength(2));

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
    expect(sdkManifest.body, contains('playmesh.main.authority'));
    expect(sdkManifest.body, contains('capabilities.getDeclared'));
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
    expect(paths, contains('/dev/api/projects/{projectId}/development'));
    expect(paths, contains('/dev/api/projects/{projectId}/webview/javascript'));
    expect(paths, contains('/dev/api/projects/{projectId}/data'));
    expect(paths, contains('/dev/api/logs'));
    expect(paths, contains('/dev/api/projects/{projectId}/file-changes/apply'));
    expect(
      paths,
      isNot(contains('/dev/api/projects/{projectId}/quick-operations/apply')),
    );
    expect(paths, contains('/dev/api/ai-approvals'));
    expect(paths, contains('/dev/api/ai-approvals/{approvalId}'));
    expect(paths, contains('/dev/api/projects/{projectId}/chat-prompt.txt'));
    expect(paths, contains('/dev/api/projects/{projectId}/agent-prompt.txt'));
    expect(paths, contains('/dev/api/capabilities'));
    expect(paths, contains('/dev/api/capability-tests'));
    expect(paths, contains('/dev/api/projects/{projectId}/manifest'));
    expect(paths, contains('/dev/api/projects/{projectId}/capabilities'));
    expect(paths, contains('/dev/api/projects/{projectId}/copy'));
    expect(paths, contains('/dev/api/projects/{projectId}'));
    expect((openApiJson['info'] as Map)['version'], '4.3.0');
    final components = Map<String, Object?>.from(
      openApiJson['components']! as Map,
    );
    expect(components, contains('securitySchemes'));
    final clearDataOperation =
        (paths['/dev/api/projects/{projectId}/data'] as Map)['delete'] as Map;
    expect(clearDataOperation['x-dangerous'], isTrue);
    expect((clearDataOperation['responses'] as Map), contains('403'));
    expect((clearDataOperation['responses'] as Map), contains('408'));
    final createProjectOperation =
        (paths['/dev/api/projects'] as Map)['post'] as Map;
    expect((createProjectOperation['responses'] as Map), contains('201'));
    final startRuntimeOperation =
        (paths['/dev/api/projects/{projectId}/run'] as Map)['post'] as Map;
    expect((startRuntimeOperation['responses'] as Map), contains('202'));
    expect(startRuntimeOperation['x-requires-foreground-view'], isTrue);
    final executeJavaScriptOperation =
        (paths['/dev/api/projects/{projectId}/webview/javascript']
                as Map)['post']
            as Map;
    expect(executeJavaScriptOperation['x-dangerous'], isTrue);
    expect(executeJavaScriptOperation['x-requires-foreground-view'], isTrue);
    final executeJavaScriptResponses =
        executeJavaScriptOperation['responses'] as Map;
    expect(executeJavaScriptResponses, contains('403'));
    expect(executeJavaScriptResponses, contains('408'));
    expect(executeJavaScriptResponses, contains('409'));
    expect(executeJavaScriptResponses, contains('422'));

    final aiContext = await http.get(
      base.resolve('/dev/api/ai-context?token=custom-dev-token'),
    );
    expect(aiContext.statusCode, HttpStatus.ok);
    final aiContextJson = Map<String, Object?>.from(
      jsonDecode(aiContext.body) as Map,
    );
    expect(
      (aiContextJson['aiExecution'] as Map)['channelHeader'],
      'X-Playmesh-AI-Channel',
    );
    expect((aiContextJson['rules'] as Map)['mainJsonManagedFields'], [
      'sdkVersion',
      'appSdkVersion',
    ]);
    final allOperationsResponse = await http.get(
      base.resolve('/dev/api/operations?target=all&token=custom-dev-token'),
    );
    expect(allOperationsResponse.statusCode, HttpStatus.ok);
    final allOperationsJson = jsonDecode(allOperationsResponse.body) as Map;
    final documentedOperations = <String>{};
    const httpMethods = {'get', 'post', 'put', 'patch', 'delete'};
    for (final pathEntry in paths.entries) {
      final methods = Map<String, Object?>.from(pathEntry.value! as Map);
      for (final method in methods.keys.where(httpMethods.contains)) {
        documentedOperations.add('${method.toUpperCase()} ${pathEntry.key}');
      }
    }
    final operationDocuments = (allOperationsJson['operations']! as List)
        .cast<Map>();
    final exposedOperationRoutes = operationDocuments
        .map(
          (operation) =>
              '${operation['method']} ${(operation['path']! as String).split('?').first}',
        )
        .toList();
    expect(
      exposedOperationRoutes.toSet(),
      hasLength(exposedOperationRoutes.length),
      reason: '统一操作注册表不允许重复 method/path',
    );
    expect(
      operationDocuments.map((operation) => operation['id']).toSet(),
      hasLength(operationDocuments.length),
      reason: '统一操作注册表不允许重复 operation id',
    );
    expect(exposedOperationRoutes.toSet(), documentedOperations);

    final unauthorized = await http.unauthenticatedGet(
      base.resolve('/dev/api/projects'),
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    expect(unauthorized.headers['x-request-id'], isNotEmpty);
    expect(unauthorized.headers['referrer-policy'], 'no-referrer');
    expect(unauthorized.headers['x-content-type-options'], 'nosniff');
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
    final oldLink = (await firstRuntime.sourceWorkspaceLinks(first)).first.uri;
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
    final newLink = (await secondRuntime.sourceWorkspaceLinks(
      second,
    )).first.uri;

    expect(newLink, oldLink);
    expect(
      (await _openWorkspaceBootstrapLink(newLink)).statusCode,
      HttpStatus.ok,
    );

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
            gameEntryPath: 'index.html',
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
    expect(projects.single.rootFilePath, source.path);
    expect(projects.single.toJson(), isNot(contains('readOnly')));
    expect(
      await catalog.listFiles('com.example.library'),
      contains('app/index.html'),
    );
  });

  test('已安装项目缺少包目录时给出明确修复错误', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-missing-project-root-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(
        () async => const <GameSummary>[],
        initialGames: [
          _installedDeveloperGame(
            id: 'com.example.missing-root',
            packageRootFilePath: null,
          ),
        ],
      ),
      workspaceRoot: workspace,
    );

    await expectLater(
      catalog.listProjects(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('缺少已安装包目录'),
        ),
      ),
    );
  });

  test('已安装项目目录不存在时拒绝用默认模板替代', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-incomplete-project-root-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final missingSource = Directory(
      '${workspace.path}${Platform.pathSeparator}missing-source',
    );
    final project = _installedDeveloperGame(
      id: 'com.example.missing-source',
      packageRootFilePath: missingSource.path,
    );
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(
        () async => const <GameSummary>[],
        initialGames: [project],
      ),
      workspaceRoot: workspace,
    );

    expect(
      (await catalog.listProjects()).single.rootFilePath,
      missingSource.path,
    );
    await expectLater(
      catalog.listFiles(project.id),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('已安装包目录不存在或不完整'),
        ),
      ),
    );
    final materialized = Directory(
      '${workspace.path}${Platform.pathSeparator}${project.id}',
    );
    expect(await materialized.exists(), isFalse);
  });

  test('从默认模板创建项目并通过受控接口编辑 main.json', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-new-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );

    final project = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.created-game',
        name: 'Created Game',
        author: 'Test Author',
        lastModifiedAt: DateTime.utc(2026, 7, 24),
        description: 'A polished party game.',
        orientation: GameOrientation.portrait,
        displayMode: 'multi_screen',
        minPlayers: 2,
        maxPlayers: 4,
        tags: ['party', 'motion'],
        requiredCapabilities: ['media.camera'],
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
    expect(utf8.decode(capabilities.bytes), contains('media.camera'));
    expect(manifest.readOnly, isTrue);
    expect(repository.cachedGames.map((game) => game.id), contains(project.id));
    final initialIndex = utf8.decode(
      (await catalog.readFile(project.id, 'app/index.html')).bytes,
    );
    final unchangedIndexDiff = await catalog.diffFile(
      project.id,
      'app/index.html',
    );
    expect(unchangedIndexDiff.changed, isFalse);
    expect(unchangedIndexDiff.original, initialIndex);
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
          ..['tags'] = ['party', 'motion']
          ..['permissions'] = ['keyboard']
          ..['icon'] = 'app/legacy.png'
          ..['redundant'] = {'nested': true}
          ..['sdkVersion'] = '0.0.1'
          ..['appSdkVersion'] = '0.0.2';
    final updatedManifest = await catalog.updateManifest(
      project.id,
      manifestJson,
      expectedRevision: 0,
    );
    expect(updatedManifest.readOnly, isTrue);
    expect(utf8.decode(updatedManifest.bytes), contains('Updated Game'));
    expect(utf8.decode(updatedManifest.bytes), contains('motion'));
    expect(
      utf8.decode(updatedManifest.bytes),
      isNot(contains('"permissions"')),
    );
    expect(utf8.decode(updatedManifest.bytes), isNot(contains('"icon"')));
    expect(utf8.decode(updatedManifest.bytes), isNot(contains('"redundant"')));
    final updatedManifestJson =
        jsonDecode(utf8.decode(updatedManifest.bytes)) as Map;
    expect(
      updatedManifestJson,
      containsPair('sdkVersion', SdkFeatureRegistry.gameSdkVersion),
    );
    expect(
      updatedManifestJson,
      containsPair('appSdkVersion', SdkFeatureRegistry.appSdkVersion),
    );
    final manifestDiff = await catalog.diffFile(project.id, 'main.json');
    expect(manifestDiff.changed, isTrue);
    expect(manifestDiff.original, contains('"name": "Created Game"'));
    expect(manifestDiff.current, contains('"name": "Updated Game"'));
    final changedIndex = '$initialIndex\n<!-- workspace diff baseline -->\n';
    await catalog.writeFile(
      project.id,
      'app/index.html',
      utf8.encode(changedIndex),
    );
    final changedIndexDiff = await catalog.diffFile(
      project.id,
      'app/index.html',
    );
    expect(changedIndexDiff.changed, isTrue);
    expect(changedIndexDiff.original, initialIndex);
    expect(changedIndexDiff.current, changedIndex);
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
    await expectLater(
      catalog.updateManifest(project.id, {
        ...manifestJson,
        'author': 'Changed Author',
      }),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      catalog.updateManifest(project.id, {
        ...manifestJson,
        'lastModifiedAt': 0,
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
    expect(history.single.summaryCode, 'delete_directory');
    expect(history.single.summaryArguments, {'path': 'app/static/empty'});
    expect(
      history.single.toJson()['summary'],
      contains('app/static/empty'),
      reason: 'The raw API summary remains available for unknown clients.',
    );
    expect(
      history.single.toJson()['summaryCode'],
      'delete_directory',
      reason: 'The App shell localizes only the stable built-in code.',
    );
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
    expect(
      await catalog.prepareGame(project.id),
      isA<GameSummary>(),
      reason: '启动只读取已保存项目，不应再次执行全量项目校验',
    );
  });

  test('复制项目允许使用新 ID 且不继承运行数据，删除项目清理目录', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-copy-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );
    final source = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.copy-source',
        name: 'Copy Source',
        author: 'Source Author',
        lastModifiedAt: DateTime.utc(2026, 7, 24),
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 2,
        maxPlayers: 4,
      ),
    );
    final sourceManifestFile = File(
      '${workspace.path}${Platform.pathSeparator}${source.id}'
      '${Platform.pathSeparator}main.json',
    );
    final sourceManifest =
        jsonDecode(await sourceManifestFile.readAsString()) as Map;
    sourceManifest
      ..['permissions'] = ['keyboard']
      ..['icon'] = 'app/legacy.png'
      ..['redundant'] = true;
    await sourceManifestFile.writeAsString(jsonEncode(sourceManifest));
    await catalog.writeFile(
      source.id,
      'app/copied.js',
      utf8.encode('export const copied = true;\n'),
      expectedRevision: 0,
    );
    await Directory(
      '${workspace.path}${Platform.pathSeparator}${source.id}'
      '${Platform.pathSeparator}app${Platform.pathSeparator}cache',
    ).create(recursive: true);
    await File(
      '${workspace.path}${Platform.pathSeparator}${source.id}'
      '${Platform.pathSeparator}app${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}asset.js',
    ).writeAsString('export const assetCache = true;\n');
    final sourceDirectory = Directory(
      '${workspace.path}${Platform.pathSeparator}${source.id}',
    );
    for (final internalName in ['data', 'cache', '.playmesh']) {
      final internal = Directory(
        '${sourceDirectory.path}${Platform.pathSeparator}$internalName',
      );
      await internal.create(recursive: true);
      await File(
        '${internal.path}${Platform.pathSeparator}private.bin',
      ).writeAsBytes([1, 2, 3]);
    }

    final copied = await catalog.copyProject(
      source.id,
      id: 'com.example.copy-target',
      name: 'Copy Target',
      author: 'Current Nickname',
      lastModifiedAt: DateTime.utc(2026, 7, 25),
    );
    final copiedDirectory = Directory(
      '${workspace.path}${Platform.pathSeparator}${copied.id}',
    );
    final manifest =
        jsonDecode(
              utf8.decode(
                (await catalog.readFile(copied.id, 'main.json')).bytes,
              ),
            )
            as Map;

    expect(copied.id, 'com.example.copy-target');
    expect(copied.name, 'Copy Target');
    expect(await catalog.listFiles(copied.id), contains('app/copied.js'));
    expect(await catalog.listFiles(copied.id), contains('app/cache/asset.js'));
    expect(manifest['id'], copied.id);
    expect(manifest['name'], copied.name);
    expect(manifest, isNot(contains('permissions')));
    expect(manifest, isNot(contains('icon')));
    expect(manifest, isNot(contains('redundant')));
    expect(manifest['author'], 'Current Nickname');
    expect(
      manifest['lastModifiedAt'],
      DateTime.utc(2026, 7, 25).millisecondsSinceEpoch,
    );
    for (final internalName in ['data', 'cache']) {
      expect(
        await Directory(
          '${copiedDirectory.path}${Platform.pathSeparator}$internalName',
        ).exists(),
        isFalse,
      );
    }
    final copiedMetadataDirectory = Directory(
      '${copiedDirectory.path}${Platform.pathSeparator}.playmesh',
    );
    expect(await copiedMetadataDirectory.exists(), isTrue);
    expect(
      await File(
        '${copiedMetadataDirectory.path}${Platform.pathSeparator}private.bin',
      ).exists(),
      isFalse,
    );

    await catalog.deleteProject(copied.id);

    expect(await copiedDirectory.exists(), isFalse);
    expect(
      (await catalog.listProjects()).map((project) => project.id),
      isNot(contains(copied.id)),
    );
    expect(await sourceDirectory.exists(), isTrue);
  });

  test('开发者 API 可视化保存清单和能力声明但拒绝修改 id', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-manifest-api-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
    );
    final project = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.visual-settings',
        name: 'Visual Settings',
        author: 'Test Author',
        lastModifiedAt: DateTime.utc(2026, 7, 24),
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
      developerAuthorProvider: () => 'API User',
    );
    addTearDown(runtime.close);
    final port = await _availablePort();
    await runtime.enableDeveloperMode(port: port, token: 'manifest-api-token');
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    Uri endpoint(String suffix) =>
        base.resolve('/dev/api/projects/${project.id}/$suffix');
    const auth = {'Authorization': 'Bearer manifest-api-token'};

    final read = await http.get(endpoint('manifest'), headers: auth);
    final readBody = jsonDecode(read.body) as Map<String, Object?>;
    final manifest = Map<String, Object?>.from(readBody['manifest']! as Map)
      ..['name'] = '可视化设置游戏'
      ..['tags'] = ['体感', '聚会']
      ..['sdkVersion'] = '0.0.1'
      ..['appSdkVersion'] = '0.0.2';
    final saved = await http.put(
      endpoint('manifest'),
      headers: const {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'manifest': manifest,
        'baseRevision': readBody['revision'],
      }),
    );
    expect(saved.statusCode, HttpStatus.ok, reason: saved.body);
    final savedManifest = (jsonDecode(saved.body) as Map)['manifest'] as Map;
    expect(savedManifest['id'], project.id);
    expect(savedManifest['tags'], ['体感', '聚会']);
    expect(savedManifest['sdkVersion'], SdkFeatureRegistry.gameSdkVersion);
    expect(savedManifest['appSdkVersion'], SdkFeatureRegistry.appSdkVersion);
    final persistedManifest =
        jsonDecode(
              utf8.decode(
                (await catalog.readFile(project.id, 'main.json')).bytes,
              ),
            )
            as Map;
    expect(
      persistedManifest,
      containsPair('sdkVersion', SdkFeatureRegistry.gameSdkVersion),
    );
    expect(
      persistedManifest,
      containsPair('appSdkVersion', SdkFeatureRegistry.appSdkVersion),
    );

    final changedId = await http.put(
      endpoint('manifest'),
      headers: const {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'manifest': {...manifest, 'id': 'com.example.changed'},
      }),
    );
    expect(changedId.statusCode, HttpStatus.badRequest);

    final savedCapabilities = await http.put(
      endpoint('capabilities'),
      headers: const {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'required': ['media.camera'],
        'baseRevision': 0,
      }),
    );
    expect(savedCapabilities.statusCode, HttpStatus.ok);
    expect((jsonDecode(savedCapabilities.body) as Map)['exists'], isTrue);
    final capabilityPrompt = await http.get(
      endpoint('agent-prompt.txt'),
      headers: auth,
    );
    expect(capabilityPrompt.statusCode, HttpStatus.ok);
    expect(
      capabilityPrompt.body,
      contains('capabilities.required: media.camera'),
    );
    expect(capabilityPrompt.body, isNot(contains('"code": "media.camera"')));
    final capabilityChatPrompt = await http.get(
      endpoint('chat-prompt.txt'),
      headers: auth,
    );
    expect(capabilityChatPrompt.statusCode, HttpStatus.ok);
    expect(capabilityChatPrompt.body, contains('当前项目已声明的平台能力'));
    expect(capabilityChatPrompt.body, contains('"code": "media.camera"'));
    expect(
      capabilityChatPrompt.body,
      isNot(contains('"code": "media.microphone"')),
    );
    expect(capabilityChatPrompt.body, contains('"optionsSchema"'));
    expect(capabilityChatPrompt.body, contains('"methods"'));
    expect(capabilityChatPrompt.body, contains('"events"'));
    final capabilityRevision =
        (jsonDecode(savedCapabilities.body) as Map)['revision'];
    final removedCapabilities = await http.put(
      endpoint('capabilities'),
      headers: const {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'required': <String>[],
        'baseRevision': capabilityRevision,
      }),
    );
    expect(removedCapabilities.statusCode, HttpStatus.ok);
    expect((jsonDecode(removedCapabilities.body) as Map)['exists'], isFalse);

    final copied = await http.post(
      endpoint('copy'),
      headers: const {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'id': 'com.example.visual-settings-copy',
        'name': 'Visual Settings Copy',
        'clientId': 'test-client',
      }),
    );
    expect(copied.statusCode, HttpStatus.created, reason: copied.body);
    final copiedProject = (jsonDecode(copied.body) as Map)['project'] as Map;
    expect(copiedProject['id'], 'com.example.visual-settings-copy');
    final copiedManifest =
        jsonDecode(
              utf8.decode(
                (await catalog.readFile(
                  'com.example.visual-settings-copy',
                  'main.json',
                )).bytes,
              ),
            )
            as Map;
    expect(copiedManifest['author'], 'API User');

    final deleted = await http.delete(
      base.resolve(
        '/dev/api/projects/com.example.visual-settings-copy'
        '?clientId=test-client',
      ),
      headers: auth,
    );
    expect(deleted.statusCode, HttpStatus.ok, reason: deleted.body);
    expect((jsonDecode(deleted.body) as Map)['deleted'], isTrue);
    expect(
      (await catalog.listProjects()).map((item) => item.id),
      isNot(contains('com.example.visual-settings-copy')),
    );
  });

  test('可以创建不包含控制器和 Authority 入口的单机骨架', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-solo-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const <GameSummary>[]),
      workspaceRoot: workspace,
    );

    final project = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.solo-game',
        name: 'Solo Game',
        author: 'Test Author',
        lastModifiedAt: DateTime.utc(2026, 7, 24),
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
    final staleControllerManifest = Map<String, Object?>.from(
      jsonDecode(manifest) as Map,
    );
    staleControllerManifest['entries'] = {
      ...Map<String, Object?>.from(staleControllerManifest['entries']! as Map),
      'controller': 'controller/index.html',
    };
    final normalized =
        jsonDecode(
              utf8.decode(
                (await catalog.updateManifest(
                  project.id,
                  staleControllerManifest,
                )).bytes,
              ),
            )
            as Map;
    expect(normalized['entries'], {'game': 'index.html'});
    expect((await catalog.validateProject(project.id)).valid, isTrue);
  });
  test('Agent/CLI 发布写入作者时间并生成可恢复的本地历史', () async {
    final libraryRoot = await Directory.systemTemp.createTemp(
      'playmesh-publish-history-',
    );
    addTearDown(() => libraryRoot.delete(recursive: true));
    final workspace = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}packages',
    );
    await workspace.create(recursive: true);
    final repository = GameLibraryRepository(() async => const <GameSummary>[]);
    final transfer = GamePackageTransferService(libraryRoot: libraryRoot);
    final catalog = GameLibraryDeveloperProjectCatalog(
      repository,
      workspaceRoot: workspace,
      packageTransfer: transfer,
    );
    final project = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.publish-history',
        name: 'Publish History',
        author: 'Original Author',
        lastModifiedAt: DateTime.utc(2026, 7, 23),
        mode: 'solo',
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 1,
        maxPlayers: 1,
      ),
    );
    final source = File(
      '${libraryRoot.path}${Platform.pathSeparator}published.zip',
    );
    await transfer.exportPackage(await catalog.prepareGame(project.id), source);
    final index = File(
      '${workspace.path}${Platform.pathSeparator}${project.id}'
      '${Platform.pathSeparator}app${Platform.pathSeparator}index.html',
    );
    await index.writeAsString('<!doctype html><title>Before publish</title>');

    final publishedAt = DateTime.utc(2026, 7, 24, 9, 30);
    await catalog.publishPackage(
      source,
      author: 'Current Nickname',
      lastModifiedAt: publishedAt,
    );

    final publishedManifest =
        jsonDecode(
              utf8.decode(
                (await catalog.readFile(project.id, 'main.json')).bytes,
              ),
            )
            as Map;
    expect(publishedManifest['author'], 'Current Nickname');
    expect(
      publishedManifest['lastModifiedAt'],
      publishedAt.millisecondsSinceEpoch,
    );
    final history = await catalog.listLocalHistory(project.id, '');
    expect(history, hasLength(1));

    await catalog.restoreLocalHistory(
      project.id,
      history.single.id,
      '',
      DeveloperHistoryVersion.before,
    );

    expect(await index.readAsString(), contains('Before publish'));
    final restoredManifest =
        jsonDecode(
              utf8.decode(
                (await catalog.readFile(project.id, 'main.json')).bytes,
              ),
            )
            as Map;
    expect(restoredManifest['author'], 'Original Author');
    expect(
      restoredManifest['lastModifiedAt'],
      DateTime.utc(2026, 7, 23).millisecondsSinceEpoch,
    );
  });

  test('锁屏时后台安全接口继续工作并准确拒绝 View 操作', () async {
    final port = await _availablePort();
    final root = await Directory.systemTemp.createTemp(
      'playmesh-background-gateway-',
    );
    final backgroundHost = _FakeDeveloperBackgroundHost(
      const DeveloperViewAvailability(
        available: false,
        reason: 'device_locked',
        activityAttached: true,
        activityResumed: false,
        windowFocused: false,
        screenInteractive: false,
        deviceLocked: true,
      ),
    );
    var launchCount = 0;
    var stopCount = 0;
    final runController = DeveloperRunController(
      onLaunch: (_) async => launchCount += 1,
    );
    runController
      ..reportRunning(projectId: 'demo')
      ..registerStopHandler('demo', () async => stopCount += 1)
      ..registerJavaScriptExecutor('demo', (_) async => 'unexpected');
    var notificationLocalization = _notificationLocalization(
      localeId: 'zh-CN',
      title: '开发者模式',
    );
    final runtime = GoCoreRuntime(
      host: _StubHost(),
      client: _StubHealthClient(),
      developerProjectCatalog: _FakeCatalog(),
      developerPreferences: DeveloperPreferences(libraryRoot: root),
      developerRunController: runController,
      developerCapabilityTests: DeveloperCapabilityTestService(),
      developerBackgroundNotificationLocalizationProvider: () =>
          notificationLocalization,
      developerBackgroundHost: backgroundHost,
    );
    addTearDown(runtime.close);
    addTearDown(() => root.delete(recursive: true));
    await runtime.enableDeveloperMode(
      port: port,
      token: 'background-dev-token',
    );
    expect(backgroundHost.port, port);
    expect(backgroundHost.localization?.localeId, 'zh-CN');
    notificationLocalization = _notificationLocalization(
      localeId: 'en-US',
      title: 'Developer mode',
    );
    await runtime.refreshDeveloperBackgroundNotification();
    expect(backgroundHost.notificationUpdateCount, 1);
    expect(backgroundHost.port, port);
    expect(backgroundHost.localization?.localeId, 'en-US');
    expect(
      backgroundHost
          .localization
          ?.messages['platform.android.developer_service.title'],
      'Developer mode',
    );
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    Uri api(String path) => base.resolve(path);
    const auth = {'Authorization': 'Bearer background-dev-token'};

    final status = await http.get(api('/dev/api/status'), headers: auth);
    expect(status.statusCode, HttpStatus.ok);
    expect(jsonDecode(status.body)['appView']['reason'], 'device_locked');
    expect(
      (await http.get(api('/dev/api/projects'), headers: auth)).statusCode,
      HttpStatus.ok,
    );

    for (final request in [
      http.post(api('/dev/api/projects/demo/run'), headers: auth),
      http.post(
        api('/dev/api/capability-tests'),
        headers: const {...auth, 'Content-Type': 'application/json'},
        body: '{}',
      ),
      http.post(
        api('/dev/api/projects/demo/webview/javascript'),
        headers: const {...auth, 'Content-Type': 'application/json'},
        body: jsonEncode({'source': 'document.title'}),
      ),
    ]) {
      final response = await request;
      expect(response.statusCode, HttpStatus.conflict, reason: response.body);
      final error = jsonDecode(response.body)['error'] as Map;
      expect(error['code'], 'app_view_unavailable');
      expect(error['details']['reason'], 'device_locked');
      expect(error['details']['requiresForegroundView'], isTrue);
    }
    expect(launchCount, 0);

    final stopped = await http.post(
      api('/dev/api/projects/demo/run/stop'),
      headers: auth,
    );
    expect(stopped.statusCode, HttpStatus.ok, reason: stopped.body);
    expect(stopCount, 1);
    expect(backgroundHost.active, isTrue);

    await runtime.disableDeveloperMode();
    expect(backgroundHost.active, isFalse);
  });

  test('项目包导出复用宽松 Operation 并只包含发布内容', () async {
    final port = await _availablePort();
    final libraryRoot = await Directory.systemTemp.createTemp(
      'playmesh-workspace-export-',
    );
    addTearDown(() => libraryRoot.delete(recursive: true));
    final workspace = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}packages',
    );
    await workspace.create(recursive: true);
    final transfer = GamePackageTransferService(libraryRoot: libraryRoot);
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const <GameSummary>[]),
      workspaceRoot: workspace,
      packageTransfer: transfer,
    );
    final project = await catalog.createProject(
      DeveloperProjectDraft(
        id: 'com.example.source-export',
        name: "源码'Odd(版)*",
        author: 'Test Author',
        lastModifiedAt: DateTime.utc(2026, 8, 20),
        mode: 'solo',
        orientation: GameOrientation.landscape,
        displayMode: 'multi_screen',
        minPlayers: 1,
        maxPlayers: 1,
      ),
    );
    final projectRoot = Directory(
      '${workspace.path}${Platform.pathSeparator}${project.id}',
    );
    await File(
      '${projectRoot.path}${Platform.pathSeparator}capabilities.json',
    ).writeAsString('{broken-json');
    for (final path in [
      'data/private.json',
      'cache/developer/history.json',
      '.playmesh/internal.json',
    ]) {
      final file = File(
        '${projectRoot.path}${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}',
      );
      await file.create(recursive: true);
      await file.writeAsString('private');
    }

    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'source-export-token',
      catalog: catalog,
      packageTransfer: transfer,
    );
    addTearDown(gateway.close);
    final response = await http.get(
      Uri.parse(
        'http://127.0.0.1:$port/dev/api/projects/${project.id}/package',
      ),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer source-export-token',
      },
    );

    expect(response.statusCode, HttpStatus.ok, reason: response.body);
    expect(
      response.headers['x-playmesh-operation-id'],
      'packages.export_project',
    );
    expect(response.headers['content-type'], startsWith('application/zip'));
    final disposition = response.headers['content-disposition']!;
    final fallbackName = gamePackageFileName(
      name: project.id,
      version: project.version,
    );
    expect(
      disposition,
      startsWith('attachment; filename="$fallbackName"; filename*=UTF-8\'\''),
    );
    final encodedName = disposition.split("filename*=UTF-8''").last;
    expect(encodedName, contains('%27'));
    expect(encodedName, contains('%28'));
    expect(encodedName, contains('%29'));
    expect(encodedName, isNot(contains("'")));
    expect(encodedName, isNot(contains('(')));
    expect(encodedName, isNot(contains(')')));
    expect(
      Uri.decodeComponent(encodedName),
      gamePackageFileName(name: project.name, version: project.version),
    );
    expect(
      int.parse(response.headers['content-length']!),
      response.bodyBytes.length,
    );
    final archive = ZipDecoder().decodeBytes(response.bodyBytes);
    final paths = archive.files
        .where((file) => file.isFile)
        .map((file) => file.name)
        .toSet();
    expect(paths, contains('main.json'));
    expect(paths, contains('capabilities.json'));
    expect(paths.any((path) => path.startsWith('app/')), isTrue);
    expect(paths.any((path) => path.startsWith('data/')), isFalse);
    expect(paths.any((path) => path.startsWith('cache/')), isFalse);
    expect(paths.any((path) => path.startsWith('.playmesh/')), isFalse);
  });

  test('工作区发布仅暴露候选源并支持部分成功后重试失败源', () async {
    final port = await _availablePort();
    final publisher = _FakeProjectPublisher();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'publish-dev-token',
      catalog: _FakeCatalog(),
      projectPublisher: publisher,
    );
    addTearDown(gateway.close);
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    const headers = {
      HttpHeaders.authorizationHeader: 'Bearer publish-dev-token',
      HttpHeaders.contentTypeHeader: 'application/json',
    };

    final candidates = await http.get(
      base.resolve('/dev/api/projects/demo/publish'),
      headers: headers,
    );
    expect(candidates.statusCode, HttpStatus.ok, reason: candidates.body);
    expect(
      candidates.headers['x-playmesh-operation-id'],
      'projects.publish_sources',
    );
    expect(candidates.body, isNot(contains('uploadKey')));
    expect(candidates.body, isNot(contains('token')));
    final candidateJson = jsonDecode(candidates.body) as Map;
    expect(candidateJson['available'], isTrue);
    final candidateSources = (candidateJson['sources'] as List).cast<Map>();
    expect(candidateSources.map((source) => source['id']), [
      'official',
      'community',
    ]);

    final first = await http.post(
      base.resolve('/dev/api/projects/demo/publish'),
      headers: headers,
      body: jsonEncode({
        'sourceIds': ['official', 'community'],
      }),
    );
    expect(first.statusCode, HttpStatus.ok, reason: first.body);
    expect(first.headers['x-playmesh-operation-id'], 'projects.publish');
    final firstJson = jsonDecode(first.body) as Map;
    final firstResult = firstJson['result'] as Map;
    expect(firstResult['succeeded'], isFalse);
    expect(firstResult['partiallySucceeded'], isTrue);
    expect(firstResult['failedSourceIds'], ['community']);
    final firstSources = (firstResult['sources'] as List).cast<Map>();
    expect(
      firstSources.singleWhere((source) => source['sourceId'] == 'community'),
      containsPair('detail', 'main.json.entries.game 对应文件不存在'),
    );
    expect(publisher.requests.single, ['official', 'community']);

    final retry = await http.post(
      base.resolve('/dev/api/projects/demo/publish'),
      headers: headers,
      body: jsonEncode({
        'sourceIds': ['community'],
      }),
    );
    expect(retry.statusCode, HttpStatus.ok, reason: retry.body);
    final retryResult = (jsonDecode(retry.body) as Map)['result'] as Map;
    expect(retryResult['succeeded'], isTrue);
    expect(retryResult['failedSourceIds'], isEmpty);
    expect(publisher.requests.last, ['community']);

    final extraField = await http.post(
      base.resolve('/dev/api/projects/demo/publish'),
      headers: headers,
      body: jsonEncode({
        'projectId': 'demo',
        'sourceIds': ['official'],
      }),
    );
    expect(extraField.statusCode, HttpStatus.badRequest);
    expect(publisher.requests, hasLength(2));

    final unavailable = await http.post(
      base.resolve('/dev/api/projects/demo/publish'),
      headers: headers,
      body: jsonEncode({
        'sourceIds': ['hidden-source'],
      }),
    );
    expect(unavailable.statusCode, HttpStatus.conflict);
    expect(
      (jsonDecode(unavailable.body) as Map)['error'],
      containsPair('code', 'publish_source_not_eligible'),
    );
    expect(publisher.requests, hasLength(2));
  });

  test('工作区发布在服务端完整校验失败时不准备或导出游戏包', () async {
    final port = await _availablePort();
    final catalog = _InvalidPublishCatalog();
    final publisher = _FakeProjectPublisher();
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'invalid-publish-token',
      catalog: catalog,
      projectPublisher: publisher,
    );
    addTearDown(gateway.close);
    final response = await http.post(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/dev/api/projects/demo/publish',
      ),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer invalid-publish-token',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode({
        'sourceIds': ['official'],
      }),
    );

    expect(
      response.statusCode,
      HttpStatus.unprocessableEntity,
      reason: response.body,
    );
    final body = jsonDecode(response.body) as Map;
    expect(body['error'], containsPair('code', 'package_validation_failed'));
    expect(body['validation'], containsPair('valid', false));
    expect(catalog.prepareCount, 0);
    expect(publisher.requests, isEmpty);
  });

  test('开发资源会话只接受当前 CLI 对端并在撤销时停止临时运行', () async {
    final port = await _availablePort();
    final launched = <DeveloperProjectLaunchRequest>[];
    var stopped = 0;
    var restarted = 0;
    final now = DateTime.utc(2026, 7, 30, 12);
    final runController = DeveloperRunController(
      onLaunch: (request) async => launched.add(request),
      clock: () => now,
    );
    runController.registerStopHandler('demo', () async => stopped += 1);
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'development-session-token',
      catalog: _FakeCatalog(),
      runController: runController,
      clock: () => now,
    );
    addTearDown(gateway.close);
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    const headers = {
      HttpHeaders.authorizationHeader: 'Bearer development-session-token',
      HttpHeaders.contentTypeHeader: 'application/json',
    };
    final credential = List<String>.filled(40, 'c').join();
    final expiresAt = now.add(const Duration(minutes: 30));
    final stagedResponse = await http.post(
      base.resolve('/dev/api/projects/demo/development/package'),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer development-session-token',
        HttpHeaders.contentTypeHeader: 'application/zip',
      },
      body: _developmentPackage('demo'),
    );
    expect(
      stagedResponse.statusCode,
      HttpStatus.created,
      reason: stagedResponse.body,
    );
    final packageId = jsonDecode(stagedResponse.body)['packageId'] as String;

    final foreign = await http.post(
      base.resolve('/dev/api/projects/demo/development'),
      headers: headers,
      body: jsonEncode({
        'resourceBaseUrl': 'http://192.0.2.10:4173/',
        'credential': credential,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'packageId': packageId,
      }),
    );
    expect(foreign.statusCode, HttpStatus.badRequest);
    expect(launched, isEmpty);

    final invalidExpiry = await http.post(
      base.resolve('/dev/api/projects/demo/development'),
      headers: headers,
      body: jsonEncode({
        'resourceBaseUrl': 'http://127.0.0.1:4173/',
        'credential': credential,
        'expiresAt': 9223372036854775807,
        'packageId': packageId,
      }),
    );
    expect(invalidExpiry.statusCode, HttpStatus.badRequest);
    expect(launched, isEmpty);

    final started = await http.post(
      base.resolve('/dev/api/projects/demo/development'),
      headers: headers,
      body: jsonEncode({
        'resourceBaseUrl': 'http://127.0.0.1:4173/',
        'credential': credential,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'packageId': packageId,
      }),
    );
    expect(started.statusCode, HttpStatus.accepted, reason: started.body);
    final startedRunId = jsonDecode(started.body)['runId'] as String;
    expect(launched, hasLength(1));
    expect(launched.single.projectId, 'demo');
    expect(
      launched.single.resourceSession?.resourceBaseUri,
      Uri.parse('http://127.0.0.1:4173/'),
    );
    final status = await http.get(
      base.resolve('/dev/api/projects/demo/development'),
      headers: headers,
    );
    expect(status.statusCode, HttpStatus.ok);
    expect(jsonDecode(status.body)['active'], isTrue);
    expect(status.body, isNot(contains(credential)));
    runController.registerRestartHandler(
      'demo',
      () async => restarted += 1,
      expectedRunId: startedRunId,
    );
    final restart = await http.post(
      base.resolve('/dev/api/projects/demo/run/restart'),
      headers: headers,
    );
    expect(restart.statusCode, HttpStatus.accepted, reason: restart.body);
    expect(jsonDecode(restart.body)['runId'], startedRunId);
    expect(restarted, 1);
    expect(launched, hasLength(1));
    expect(runController.resourceSession('demo'), isNotNull);

    final revoked = await http.delete(
      base.resolve('/dev/api/projects/demo/development'),
      headers: headers,
    );
    expect(revoked.statusCode, HttpStatus.ok, reason: revoked.body);
    expect(stopped, 1);
    expect(runController.resourceSession('demo'), isNull);
  });

  test('源码运行校验并显式启动已保存的受管项目', () async {
    final port = await _availablePort();
    final catalog = _CountingPrepareCatalog();
    final launches = <DeveloperProjectLaunchRequest>[];
    late DeveloperRunController runController;
    runController = DeveloperRunController(
      onLaunch: (request) async {
        launches.add(request);
        runController.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
      },
    );
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'saved-source-run-token',
      catalog: catalog,
      runController: runController,
    );
    addTearDown(gateway.close);

    final response = await http.post(
      Uri.parse('http://127.0.0.1:$port/dev/api/projects/demo/run'),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer saved-source-run-token',
      },
    );

    expect(response.statusCode, HttpStatus.accepted, reason: response.body);
    final body = jsonDecode(response.body) as Map;
    expect(body['phase'], 'starting');
    expect(catalog.prepareCount, 1);
    expect(launches, hasLength(1));
    expect(launches.single.source, isA<DeveloperSavedProjectLaunchSource>());
    expect(launches.single.resourceSession, isNull);
    expect(
      launches.single.savedProject?.entry.packageRootFilePath,
      '/managed/packages/demo',
    );
  });

  test('源码运行在服务端校验失败时不准备或启动项目', () async {
    final port = await _availablePort();
    final catalog = _InvalidPublishCatalog();
    var launches = 0;
    final gateway = await startDeveloperWebGateway(
      port: port,
      token: 'invalid-source-run-token',
      catalog: catalog,
      runController: DeveloperRunController(onLaunch: (_) async => launches++),
    );
    addTearDown(gateway.close);

    final response = await http.post(
      Uri.parse('http://127.0.0.1:$port/dev/api/projects/demo/run'),
      headers: const {
        HttpHeaders.authorizationHeader: 'Bearer invalid-source-run-token',
      },
    );

    expect(
      response.statusCode,
      HttpStatus.unprocessableEntity,
      reason: response.body,
    );
    final body = jsonDecode(response.body) as Map;
    expect(body['error'], containsPair('code', 'package_validation_failed'));
    expect(body['validation'], containsPair('valid', false));
    expect(catalog.prepareCount, 0);
    expect(launches, 0);
  });
}

List<int> _developmentPackage(String gameId) {
  final manifest = utf8.encode(
    jsonEncode({
      'id': gameId,
      'name': 'Development package',
      'author': 'Tester',
      'lastModifiedAt': 0,
      'remarks': 'Temporary only',
      'version': '1.0.0',
      'sdkVersion': '4.1.0',
      'appSdkVersion': '3.3.0',
      'orientation': 'landscape',
      'modes': ['solo'],
      'displayModes': ['multi_screen'],
      'players': {'min': 1, 'max': 1},
      'entries': {'game': 'index.html'},
      'tags': <String>[],
    }),
  );
  final index = utf8.encode('<!doctype html><title>Development</title>');
  return ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile('main.json', manifest.length, manifest))
      ..addFile(ArchiveFile('app/index.html', index.length, index)),
  )!;
}

GameSummary _installedDeveloperGame({
  required String id,
  required String? packageRootFilePath,
}) => GameSummary(
  id: id,
  name: id,
  version: '1.0.0',
  description: '',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多人多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(
    gameEntryPath: 'index.html',
    statusLabel: 'Game SDK 4.0.0',
    packageRootFilePath: packageRootFilePath,
  ),
);

Future<Map<String, Object?>> _waitForAiApproval(
  Uri base, {
  required String token,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final response = await http.get(
      base.resolve('/dev/api/ai-approvals'),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    );
    expect(response.statusCode, HttpStatus.ok, reason: response.body);
    final approvals = (jsonDecode(response.body) as Map)['approvals'] as List;
    if (approvals.isNotEmpty) {
      return Map<String, Object?>.from(approvals.single as Map);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('没有收到 AI 危险操作审批请求');
}

/// Sends ordinary Developer API requests with the persistent bearer and strips
/// the URL bootstrap token used by the legacy test URLs. The bootstrap token is
/// therefore exercised only by [_openWorkspaceBootstrapLink].
final class _DeveloperBearerClient {
  _DeveloperBearerClient(this.token);

  final String token;
  final http.Client _client = http.Client();

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _client.get(_withoutBootstrapToken(url), headers: _headers(headers));

  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _client.post(
    _withoutBootstrapToken(url),
    headers: _headers(headers),
    body: body,
    encoding: encoding,
  );

  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _client.put(
    _withoutBootstrapToken(url),
    headers: _headers(headers),
    body: body,
    encoding: encoding,
  );

  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _client.delete(
    _withoutBootstrapToken(url),
    headers: _headers(headers),
    body: body,
    encoding: encoding,
  );

  http.Client streamingClient() => http.Client();

  http.Request request(String method, Uri url) =>
      http.Request(method, _withoutBootstrapToken(url))
        ..headers.addAll(_headers(null));

  Future<http.Response> unauthenticatedGet(Uri url) => _client.get(url);

  Uri _withoutBootstrapToken(Uri url) {
    if (!url.queryParameters.containsKey('token')) return url;
    final query = Map<String, String>.from(url.queryParameters)
      ..remove('token');
    return url.replace(queryParameters: query);
  }

  Map<String, String> _headers(Map<String, String>? headers) => {
    ...?headers,
    HttpHeaders.authorizationHeader: 'Bearer $token',
  };

  void close() => _client.close();
}

Future<http.Response> _openWorkspaceBootstrapLink(Uri link) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', link)..followRedirects = false;
    final bootstrap = await client.send(request);
    final location = bootstrap.headers['location'];
    final setCookie = bootstrap.headers['set-cookie'];
    await bootstrap.stream.drain<void>();
    expect(bootstrap.statusCode, HttpStatus.seeOther);
    expect(location, isNotNull);
    expect(setCookie, isNotNull);
    final cookie = setCookie!.split(';').first;
    return await client.get(
      link.resolve(location!),
      headers: {HttpHeaders.cookieHeader: cookie},
    );
  } finally {
    client.close();
  }
}

http.Client _plainHttpClient() => http.Client();

http.Request _plainHttpRequest(String method, Uri url) =>
    http.Request(method, url);

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _FakeCatalog implements DeveloperProjectCatalog {
  _FakeCatalog()
    : _files = {
        'app/index.html': Uint8List.fromList(
          utf8.encode('<!doctype html><title>Demo</title>'),
        ),
        'main.json': Uint8List.fromList(
          utf8.encode(
            '{"id":"demo","sdkVersion":"4.1.0","appSdkVersion":"3.3.0",'
            '"modes":["multiplayer"],'
            '"displayModes":["multi_screen"],'
            '"entries":{"game":"index.html"},'
            '"authority":{"entry":"static/js/service/index.js"}}',
          ),
        ),
      };

  final Map<String, Uint8List> _files;
  final Map<String, int> _revisions = {};

  @override
  Future<List<DeveloperProject>> listProjects() async => const [
    DeveloperProject(
      id: 'demo',
      name: 'Demo',
      version: '1.0.0',
      rootFilePath: 'test-projects/demo',
    ),
  ];

  @override
  Future<DeveloperProject> createProject(DeveloperProjectDraft draft) =>
      throw UnimplementedError();

  @override
  Future<DeveloperProject> copyProject(
    String sourceProjectId, {
    required String id,
    required String name,
    required String author,
    required DateTime lastModifiedAt,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteProject(String projectId) => throw UnimplementedError();

  @override
  Future<GameSummary> publishPackage(
    File source, {
    required String author,
    required DateTime lastModifiedAt,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> listFiles(String projectId) async =>
      _files.keys.toList()..sort();

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
    final bytes = _files[path];
    if (bytes == null) throw StateError('文件不存在：$path');
    return DeveloperProjectFile(
      path: path,
      bytes: Uint8List.fromList(bytes),
      contentType: path.endsWith('.json')
          ? 'application/json; charset=utf-8'
          : path.endsWith('.html')
          ? 'text/html; charset=utf-8'
          : path.endsWith('.css')
          ? 'text/css; charset=utf-8'
          : 'text/javascript; charset=utf-8',
      revision: _revisions[path] ?? 0,
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
  }) async {
    for (final path in files.keys) {
      final expected = expectedRevisions?[path];
      final current = _revisions[path] ?? 0;
      if (expected != null && expected != current) {
        throw StateError('revision 冲突：$path');
      }
    }
    final saved = <DeveloperProjectFile>[];
    for (final entry in files.entries) {
      _files[entry.key] = Uint8List.fromList(entry.value);
      _revisions[entry.key] = (_revisions[entry.key] ?? 0) + 1;
      saved.add(await readFile(projectId, entry.key));
    }
    return saved;
  }

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
      gameEntryPath: 'index.html',
      statusLabel: '开发项目',
      packageRootFilePath: '/managed/packages/demo',
    ),
  );
}

class _InvalidPublishCatalog extends _FakeCatalog {
  int prepareCount = 0;

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async => const DeveloperProjectValidationReport(
    projectId: 'demo',
    diagnostics: [
      DeveloperProjectDiagnostic(
        code: 'entry_missing',
        severity: DeveloperDiagnosticSeverity.error,
        message: '主游戏入口不存在',
        path: 'app/index.html',
      ),
    ],
    fileCount: 2,
    totalBytes: 64,
  );

  @override
  Future<GameSummary> prepareGame(String projectId) {
    prepareCount += 1;
    return super.prepareGame(projectId);
  }
}

class _CountingPrepareCatalog extends _FakeCatalog {
  int prepareCount = 0;

  @override
  Future<GameSummary> prepareGame(String projectId) async {
    prepareCount++;
    return super.prepareGame(projectId);
  }
}

class _FakeProjectPublisher implements DeveloperProjectPublisher {
  final List<List<String>> requests = [];

  @override
  Future<List<DeveloperPublishSource>> listCandidates() async => const [
    DeveloperPublishSource(
      id: 'official',
      name: 'Official',
      protocolVersion: '1.0.0',
      maxUploadBytes: 1024 * 1024,
    ),
    DeveloperPublishSource(
      id: 'community',
      name: 'Community',
      protocolVersion: '1.0.0',
      maxUploadBytes: 2 * 1024 * 1024,
    ),
  ];

  @override
  Future<DeveloperPublishBatchResult> publish({
    required GameSummary game,
    required Iterable<String> sourceIds,
    DeveloperPublishEventCallback? onEvent,
  }) async {
    final ids = List<String>.unmodifiable(sourceIds);
    requests.add(ids);
    final isRetry = ids.length == 1 && ids.single == 'community';
    final sources = <DeveloperPublishSourceResult>[
      for (final id in ids)
        DeveloperPublishSourceResult(
          sourceId: id,
          sourceName: id == 'official' ? 'Official' : 'Community',
          status: id == 'community' && !isRetry
              ? 'package_validation_failed'
              : 'entered_review',
          detail: id == 'community' && !isRetry
              ? 'main.json.entries.game 对应文件不存在'
              : null,
        ),
    ];
    for (final source in sources) {
      onEvent?.call(source);
    }
    return DeveloperPublishBatchResult(
      gameId: game.id,
      version: game.version,
      sources: List.unmodifiable(sources),
      failedSourceIds: List.unmodifiable([
        for (final source in sources)
          if (!source.succeeded) source.sourceId,
      ]),
    );
  }
}

DeveloperBackgroundNotificationLocalization _notificationLocalization({
  required String localeId,
  required String title,
}) {
  return DeveloperBackgroundNotificationLocalization.fromAppMessages(
    localeId: localeId,
    messages: {
      'platform.android.developer_service.channel_name': 'channel',
      'platform.android.developer_service.channel_description': 'description',
      'platform.android.developer_service.title': title,
      'platform.android.developer_service.listening': 'port {port}',
      'platform.android.developer_service.running': 'running',
    },
  );
}

class _FakeDeveloperBackgroundHost implements DeveloperBackgroundHost {
  _FakeDeveloperBackgroundHost(this.availability);

  DeveloperViewAvailability availability;
  bool active = false;
  int? port;
  DeveloperBackgroundNotificationLocalization? localization;
  var notificationUpdateCount = 0;

  @override
  Future<void> start({
    required int port,
    DeveloperBackgroundNotificationLocalization? localization,
  }) async {
    active = true;
    this.port = port;
    this.localization = localization;
  }

  @override
  Future<void> updateNotification({
    required int port,
    required DeveloperBackgroundNotificationLocalization localization,
  }) async {
    this.port = port;
    this.localization = localization;
    notificationUpdateCount += 1;
  }

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  Future<DeveloperViewAvailability> viewAvailability() async => availability;
}

class _MemoryGDevelopWebIdeSource implements GDevelopWebIdeSource {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Uint8List?> read(String relativePath) async {
    if (relativePath != 'index.html') return null;
    return Uint8List.fromList(
      utf8.encode('<!doctype html><p>PLAYMESH_GDEVELOP_TEST</p>'),
    );
  }
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
