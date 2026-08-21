import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../models/game_capabilities.dart';
import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../game_package/game_package_share_files.dart';
import '../game_package/game_package_transfer_service.dart';
import '../game_package/game_web_resource_source.dart';
import '../game_sdk/sdk_feature_registry.dart';
import '../network/lan_endpoint_resolver.dart';
import '../network/lan_endpoint.dart';
import 'developer_ai_prompt_templates.dart';
import 'developer_preview_service.dart';
import 'developer_capability_test_service.dart';
import 'developer_channel.dart';
import 'developer_event_hub.dart';
import 'developer_background_host.dart';
import 'developer_installation_package_service.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
import 'developer_web_gateway_contract.dart';
import 'gdevelop_web_ide_source.dart';
import 'gdevelop_web_ide_installer_contract.dart';
import 'gdevelop_ai_event.dart';
import 'gdevelop_ai_event_hub.dart';
import 'gdevelop_ai_feature_policy.dart';
import 'gdevelop_ai_session_service.dart';
import 'gdevelop_ai_project_context.dart';
import 'gdevelop_ai_tool_registry.dart';
import 'gdevelop_event_payload.dart';
import 'gdevelop_project_config.dart';
import 'gdevelop_project_config_controller.dart';
import 'gdevelop_project_files.dart';
import 'gdevelop_project_history.dart';
import 'gdevelop_project_allocation.dart';
import 'gdevelop_project_allocation_controller.dart';
import 'gdevelop_project_rekey.dart';
import 'gdevelop_project_rekey_controller.dart';
import 'gdevelop_project_root_resolver.dart';
import 'gdevelop_restore_transaction.dart';
import 'project_provisioning_service.dart';
import 'foundation/local_version_store.dart';
import 'foundation/pending_project_commit_store.dart';
import 'foundation/package_upload_spooler.dart';
import 'foundation/developer_native_file_save_store.dart';
import 'foundation/developer_ai_approval.dart';
import 'operations/developer_operation_definition.dart';
import 'operations/documentation/developer_agent_operation_renderer.dart';
import 'operations/documentation/developer_chat_operation_renderer.dart';
import 'operations/documentation/developer_operation_document_renderer.dart';
import 'operations/middleware/developer_operation_metadata_middleware.dart';
import 'operations/middleware/developer_operation_middleware.dart';
import 'operations/middleware/developer_operation_responses_middleware.dart';
import 'operations/middleware/developer_operation_security_middleware.dart';

import 'gdevelop_catalog_artifact_service.dart';
import 'gdevelop_capability_catalog_service.dart';
import 'gdevelop_editor_instance_lease.dart';
import 'gdevelop_generated_code_store.dart';

part 'operations/developer_http_operation.dart';
part 'operations/developer_operation_registry.dart';
part 'operations/infrastructure/developer_file_support.dart';
part 'operations/infrastructure/developer_http_support.dart';
part 'operations/infrastructure/empty_developer_project_catalog.dart';
part 'operations/approvals/developer_operation_execution_middleware.dart';
part 'operations/approvals/ai_approval_operation.dart';
part 'operations/middleware/developer_request_middleware.dart';
part 'operations/middleware/gdevelop_editor_instance_middleware.dart';
part 'operations/ai/ai_context_operation.dart';
part 'operations/ai/operation_catalog_operation.dart';
part 'operations/ai/project_prompt_operation.dart';
part 'operations/ai/prompt_templates_operation.dart';
part 'operations/capabilities/capability_registry_operation.dart';
part 'operations/capabilities/capability_tests_operation.dart';
part 'operations/capabilities/project_capabilities_operation.dart';
part 'operations/files/asset_operation.dart';
part 'operations/files/diff_operation.dart';
part 'operations/files/directory_operation.dart';
part 'operations/files/file_changes_operation.dart';
part 'operations/files/file_management_operation.dart';
part 'operations/files/file_operation.dart';
part 'operations/files/file_tree_operation.dart';
part 'operations/files/local_history_operation.dart';
part 'operations/gdevelop/gdevelop_history_operation.dart';
part 'operations/gdevelop/gdevelop_editor_instance_operation.dart';
part 'operations/gdevelop/gdevelop_catalog_artifact_operation.dart';
part 'operations/gdevelop/gdevelop_capability_catalog_operation.dart';
part 'operations/gdevelop/gdevelop_generated_code_operation.dart';
part 'operations/gdevelop/gdevelop_project_allocation_operation.dart';
part 'operations/gdevelop/gdevelop_project_config_operation.dart';
part 'operations/gdevelop/gdevelop_project_rekey_operation.dart';
part 'operations/gdevelop/gdevelop_preview_debugger_operation.dart';
part 'operations/gdevelop/gdevelop_preview_operation.dart';
part 'operations/gdevelop/gdevelop_native_file_save_operation.dart';
part 'operations/gdevelop/gdevelop_ai_operation.dart';
part 'operations/gdevelop/gdevelop_ai_events_operation.dart';
part 'operations/packages/package_import_operation.dart';
part 'operations/packages/project_package_operation.dart';
part 'operations/packages/project_installation_package_operation.dart';
part 'operations/publishing/project_publish_operation.dart';
part 'operations/projects/data_operation.dart';
part 'operations/projects/manifest_operation.dart';
part 'operations/projects/project_copy_operation.dart';
part 'operations/projects/project_operation.dart';
part 'operations/projects/projects_operation.dart';
part 'operations/projects/validate_operation.dart';
part 'operations/runtime/active_run_operation.dart';
part 'operations/runtime/development_session_operation.dart';
part 'operations/runtime/events_operation.dart';
part 'operations/runtime/logs_operation.dart';
part 'operations/runtime/project_run_operation.dart';
part 'operations/runtime/webview_javascript_operation.dart';
part 'operations/system/documentation_operation.dart';
part 'operations/system/clipboard_operation.dart';
part 'operations/system/localization_operation.dart';
part 'operations/system/qr_operation.dart';
part 'operations/system/sdk_bundle_operation.dart';
part 'operations/system/status_operation.dart';

final _developerOperationRegistry = _DeveloperOperationRegistry(const [
  _DocumentationOperation(),
  _ClipboardOperation(),
  _LocalizationOperation(),
  _StatusOperation(),
  _SdkBundleOperation(),
  _ActiveRunOperation(),
  _ProjectsOperation(),
  _ProjectOperation(),
  _ProjectCopyOperation(),
  _PackageImportOperation(),
  _ProjectPackageOperation(),
  _ProjectInstallationPackageOperation(),
  _ProjectPublishOperation(),
  _CapabilityRegistryOperation(),
  _CapabilityTestsOperation(),
  _ProjectCapabilitiesOperation(),
  _FileTreeOperation(),
  _FileOperation(),
  _FileChangesOperation(),
  _DirectoryOperation(),
  _FileManagementOperation(),
  _LocalHistoryOperation(),
  _GDevelopProjectAllocationOperation(),
  _GDevelopProjectConfigOperation(),
  _GDevelopProjectRekeyOperation(),
  _GDevelopHistoryOperation(),
  _GDevelopEditorInstanceOperation(),
  _GDevelopCatalogArtifactOperation(),
  _GDevelopCapabilityCatalogOperation(),
  _GDevelopGeneratedCodeOperation(),
  _GDevelopPreviewDebuggerOperation(),
  _GDevelopPreviewOperation(),
  _GDevelopNativeFileSaveOperation(),
  _GDevelopAiOperation(),
  _GDevelopAiEventsOperation(),
  _AssetOperation(),
  _DiffOperation(),
  _ManifestOperation(),
  _ValidateOperation(),
  _ProjectDataOperation(),
  _ProjectRunOperation(),
  _DevelopmentSessionOperation(),
  _WebViewJavaScriptOperation(),
  _EventsOperation(),
  _LogsOperation(),
  _OperationCatalogOperation(),
  _AiContextOperation(),
  _PromptTemplatesOperation(),
  _ProjectPromptOperation(),
  _AiApprovalOperation(),
  _QrOperation(),
]);

const _developerRequestPipeline = _DeveloperRequestPipeline([
  _DeveloperErrorMiddleware(),
  _DeveloperAuthenticationMiddleware(),
  _GDevelopEditorInstanceMiddleware(),
]);

Future<DeveloperWebGateway> startDeveloperWebGateway({
  required int port,
  String? token,
  String? path,
  DeveloperProjectCatalog? catalog,
  DeveloperAiPromptTemplateStore? promptTemplates,
  DeveloperRunController? runController,
  DeveloperCapabilityTestService? capabilityTests,
  GamePackageTransferService? packageTransfer,
  DeveloperProjectPublisher? projectPublisher,
  DeveloperInstallationPackageService? installationPackageService,
  DeveloperWorkspaceLocalizationBridge? localizationBridge,
  String Function()? currentAuthor,
  DeveloperViewAvailabilityProvider? viewAvailability,
  DateTime Function()? clock,
  GDevelopWebIdeSource? gdevelopWebIdeSource,
  GDevelopProjectHistoryAdapter? gdevelopHistory,
  GDevelopProjectConfigController? gdevelopProjectConfig,
  GDevelopRestoreTransactionCoordinator? gdevelopRestoreTransactions,
  GDevelopProjectRekeyController? gdevelopProjectRekey,
  GDevelopProjectAllocationController? gdevelopProjectAllocation,
  DeveloperPreviewService? previewService,
  GDevelopAiSessionService? gdevelopAiSessions,
  GDevelopAiToolRegistryProvider? gdevelopAiToolsProvider,
  GDevelopAiFeaturePolicy? gdevelopAiFeaturePolicy,
  DeveloperAiApprovalBroker? approvalBroker,
  GDevelopCatalogArtifactService? gdevelopCatalogArtifacts,
  GDevelopEditorInstanceLeaseManager? gdevelopEditorInstances,
}) async {
  if (port < 1 || port > 65535) {
    throw const FormatException('开发者通道端口必须在 1 到 65535 之间');
  }
  try {
    final resolvedGDevelopWebIdeSource =
        gdevelopWebIdeSource ?? createGDevelopWebIdeSource();
    final resolvedGDevelopAiFeaturePolicy =
        gdevelopAiFeaturePolicy ??
        GDevelopAiFeaturePolicy.forDeveloperSession(
          developerModeEnabled: true,
          gdevelopWorkspaceAvailable: await resolvedGDevelopWebIdeSource
              .isAvailable(),
        );
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final resolvedRunController = runController ?? DeveloperRunController();
    final resolvedPackageTransfer =
        packageTransfer ?? GamePackageTransferService();
    final resolvedApprovalBroker =
        approvalBroker ?? DeveloperAiApprovalBroker();
    final resolvedGDevelopHistory =
        gdevelopHistory ?? GDevelopProjectHistoryAdapter();
    final resolvedGDevelopProjectConfig =
        gdevelopProjectConfig ??
        GDevelopProjectConfigController(
          GDevelopProjectConfigStore(
            rootResolver: resolvedGDevelopHistory.rootResolver,
          ),
        );
    final resolvedGDevelopRestoreTransactions =
        gdevelopRestoreTransactions ??
        GDevelopRestoreTransactionCoordinator(
          history: resolvedGDevelopHistory,
          projectConfig: resolvedGDevelopProjectConfig,
          clock: clock,
          eventSink: developerEventHub.emit,
        );
    final resolvedPreviewService =
        previewService ??
        DeveloperPreviewService(
          runController: resolvedRunController,
          packageTransfer: resolvedPackageTransfer,
        );
    final resolvedGDevelopAiSessions =
        gdevelopAiSessions ?? GDevelopAiSessionService();
    final resolvedGDevelopEditorInstances =
        gdevelopEditorInstances ??
        GDevelopEditorInstanceLeaseManager(clock: clock);
    final resolvedGDevelopAiEvents = GDevelopAiEventHub(
      policy: resolvedGDevelopAiFeaturePolicy,
      sessions: resolvedGDevelopAiSessions,
    );
    final catalogProxyValue =
        Platform.environment['PLAYMESH_GDEVELOP_CATALOG_PROXY']?.trim() ?? '';
    Future<String> loadGDevelopCatalogIndex(String name) async {
      final bytes = await resolvedGDevelopWebIdeSource.read(
        'playmesh/catalog/$name',
      );
      if (bytes == null) {
        throw StateError('当前 GDevelop 内核缺少本地目录索引：$name');
      }
      return utf8.decode(bytes, allowMalformed: false);
    }

    final resolvedGDevelopCatalogArtifacts =
        gdevelopCatalogArtifacts ??
        GDevelopCatalogArtifactService(
          proxy: catalogProxyValue.isEmpty
              ? null
              : Uri.tryParse(catalogProxyValue),
          catalogIndexLoader: loadGDevelopCatalogIndex,
        );
    final resolvedGDevelopCapabilityCatalog = GDevelopCapabilityCatalogService(
      artifacts: resolvedGDevelopCatalogArtifacts,
      indexLoader: () => loadGDevelopCatalogIndex('extensions-index.json'),
    );
    final resolvedGDevelopProjectRekey =
        gdevelopProjectRekey ??
        GDevelopProjectRekeyController(
          GDevelopProjectRekeyCoordinator(
            history: resolvedGDevelopHistory,
            projectConfig: resolvedGDevelopProjectConfig,
            restoreTransactions: resolvedGDevelopRestoreTransactions,
            approvalMigrator: (oldGameId, newGameId) =>
                resolvedApprovalBroker.migrateScopeApprovals(
                  scopeKind: 'gdevelop',
                  oldScopeId: oldGameId,
                  newScopeId: newGameId,
                ),
            closeAiSessions: (gameId) {
              resolvedGDevelopAiSessions.closeProject(gameId);
            },
            stopPreview: resolvedPreviewService.stopProject,
            eventSink: developerEventHub.emit,
            clock: clock,
          ),
        );
    final resolvedGDevelopProjectAllocation =
        gdevelopProjectAllocation ??
        GDevelopProjectAllocationController(
          GDevelopProjectAllocationCoordinator(
            rootResolver: resolvedGDevelopHistory.rootResolver,
            history: resolvedGDevelopHistory,
            mutationLock: resolvedGDevelopRestoreTransactions.mutationLock,
            clock: clock,
          ),
        );
    resolvedGDevelopRestoreTransactions.registerMutationGuard(
      resolvedGDevelopProjectRekey.ensureMutationAllowed,
    );
    resolvedGDevelopRestoreTransactions.registerMutationGuard(
      resolvedGDevelopProjectAllocation.ensureMutationAllowed,
    );
    resolvedGDevelopProjectRekey.registerMutationGuard(
      resolvedGDevelopProjectAllocation.ensureMutationAllowed,
    );
    resolvedGDevelopProjectAllocation
      ..registerMutationGuard(
        resolvedGDevelopProjectRekey.ensureMutationAllowed,
      )
      ..registerMutationGuard(
        resolvedGDevelopRestoreTransactions.ensureNoActiveRestore,
      );
    await resolvedApprovalBroker.initialize();
    final gateway = _IoDeveloperWebGateway(
      server: server,
      token: _createToken(token),
      path: _createPath(path),
      catalog: catalog ?? const _EmptyDeveloperProjectCatalog(),
      promptTemplates: promptTemplates ?? DeveloperAiPromptTemplateStore(),
      runController: resolvedRunController,
      capabilityTests: capabilityTests ?? DeveloperCapabilityTestService(),
      packageTransfer: resolvedPackageTransfer,
      projectPublisher: projectPublisher,
      installationPackageService: installationPackageService,
      localizationBridge: localizationBridge,
      currentAuthor: currentAuthor,
      viewAvailability:
          viewAvailability ??
          (() async => const DeveloperViewAvailability.available()),
      clock: clock ?? DateTime.now,
      gdevelopWebIdeSource: resolvedGDevelopWebIdeSource,
      gdevelopCatalogArtifacts: resolvedGDevelopCatalogArtifacts,
      gdevelopCapabilityCatalog: resolvedGDevelopCapabilityCatalog,
      gdevelopHistory: resolvedGDevelopHistory,
      gdevelopProjectConfig: resolvedGDevelopProjectConfig,
      gdevelopRestoreTransactions: resolvedGDevelopRestoreTransactions,
      gdevelopProjectRekey: resolvedGDevelopProjectRekey,
      gdevelopProjectAllocation: resolvedGDevelopProjectAllocation,
      previewService: resolvedPreviewService,
      gdevelopAiSessions: resolvedGDevelopAiSessions,
      gdevelopAiEvents: resolvedGDevelopAiEvents,
      gdevelopAiFeaturePolicy: resolvedGDevelopAiFeaturePolicy,
      approvalBroker: resolvedApprovalBroker,
      gdevelopEditorInstances: resolvedGDevelopEditorInstances,
      gdevelopAiToolsProvider: gdevelopAiToolsProvider,
    );
    gateway.listen();
    return gateway;
  } on SocketException catch (error) {
    throw StateError('无法监听开发者端口 $port：${error.message}');
  }
}

/// IO 网关只负责生命周期、中间件和路由分发；业务处理全部位于已注册操作文件。
class _IoDeveloperWebGateway implements DeveloperWebGateway {
  _IoDeveloperWebGateway({
    required this.server,
    required this.token,
    required this.path,
    required this.catalog,
    required this.promptTemplates,
    required this.runController,
    required this.capabilityTests,
    required this.packageTransfer,
    required this.projectPublisher,
    required this.installationPackageService,
    required this.localizationBridge,
    required this.currentAuthor,
    required this.viewAvailability,
    required this.clock,
    required this.gdevelopWebIdeSource,
    required this.gdevelopCatalogArtifacts,
    required this.gdevelopCapabilityCatalog,
    required this.gdevelopHistory,
    required this.gdevelopProjectConfig,
    required this.gdevelopRestoreTransactions,
    required this.gdevelopProjectRekey,
    required this.gdevelopProjectAllocation,
    required this.previewService,
    required this.gdevelopAiSessions,
    required this.gdevelopAiEvents,
    required this.gdevelopAiFeaturePolicy,
    required this.approvalBroker,
    required this.gdevelopEditorInstances,
    required this.gdevelopAiToolsProvider,
  }) : session = DeveloperSession(
         enabled: true,
         port: server.port,
         path: path,
         token: token,
         tokenHint: token.substring(token.length - 6),
         workspacePath: '/dev/$path/workspace',
         gdevelopWorkspacePath: '/dev/$path/gdevelop/',
         docsPath: '/dev/docs',
         openApiPath: '/dev/openapi.json',
         sdkManifestPath: '/dev/sdk-manifest.json',
         createdAt: DateTime.now().toUtc(),
       );

  final HttpServer server;
  final String token;
  final String path;
  final DeveloperProjectCatalog catalog;
  final DeveloperAiPromptTemplateStore promptTemplates;
  final DeveloperRunController runController;
  final DeveloperCapabilityTestService capabilityTests;
  final GamePackageTransferService packageTransfer;
  final DeveloperProjectPublisher? projectPublisher;
  final DeveloperInstallationPackageService? installationPackageService;
  final DeveloperWorkspaceLocalizationBridge? localizationBridge;
  final String Function()? currentAuthor;
  final DeveloperViewAvailabilityProvider viewAvailability;
  final DateTime Function() clock;
  final GDevelopWebIdeSource gdevelopWebIdeSource;
  final GDevelopCatalogArtifactService gdevelopCatalogArtifacts;
  final GDevelopCapabilityCatalogService gdevelopCapabilityCatalog;
  final GDevelopGeneratedCodeStore gdevelopGeneratedCode =
      GDevelopGeneratedCodeStore();
  final GDevelopProjectHistoryAdapter gdevelopHistory;
  final GDevelopProjectConfigController gdevelopProjectConfig;
  final GDevelopRestoreTransactionCoordinator gdevelopRestoreTransactions;
  final GDevelopProjectRekeyController gdevelopProjectRekey;
  final GDevelopProjectAllocationController gdevelopProjectAllocation;
  final DeveloperPreviewService previewService;
  final DeveloperNativeFileSaveStore gdevelopNativeFileSaves =
      DeveloperNativeFileSaveStore(
        maxBytes: GamePackageTransferService.maxCompressedBytes,
      );
  final GDevelopAiSessionService gdevelopAiSessions;
  final GDevelopAiEventHub gdevelopAiEvents;
  final GDevelopAiFeaturePolicy gdevelopAiFeaturePolicy;
  final GDevelopAiToolRegistryProvider? gdevelopAiToolsProvider;

  Future<GDevelopAiToolRegistry> loadGDevelopAiTools() {
    final provider = gdevelopAiToolsProvider;
    if (provider == null) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_ai_tools_provider_unavailable',
      );
    }
    return provider();
  }

  final DeveloperAiApprovalBroker approvalBroker;
  final GDevelopEditorInstanceLeaseManager gdevelopEditorInstances;
  Future<void> _packageFileTail = Future<void>.value();
  StreamSubscription<({String gameId, GDevelopAiCall call})>?
  _gdevelopAiCallSubscription;
  StreamSubscription<GDevelopAiEvent>? _gdevelopAiLeaseBindingSubscription;

  @override
  final DeveloperSession session;

  void listen() {
    _gdevelopAiLeaseBindingSubscription = gdevelopAiSessions.aiEvents.listen((
      event,
    ) {
      if (event.type != GDevelopAiEventType.sessionUpdated) return;
      if (event.state == GDevelopAiSessionEventState.opened.wireName) {
        gdevelopEditorInstances.bindAiSession(event.editorSessionId);
      } else if (event.state == GDevelopAiSessionEventState.closed.wireName) {
        gdevelopEditorInstances.unbindAiSession(event.editorSessionId);
      }
    });
    _gdevelopAiCallSubscription = gdevelopAiSessions.callUpdates.listen((
      update,
    ) {
      if (gdevelopAiFeaturePolicy.enabled) {
        developerEventHub.emit({
          'type': 'gdevelop.ai.call.updated',
          'gameId': update.gameId,
          ...update.call.toJson(),
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
      }
    });
    server.listen((request) {
      final requestId = 'dev-${_randomHex(8)}';
      request.response.headers
        ..set('X-Request-ID', requestId)
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Content-Type-Options', 'nosniff');
      unawaited(
        _developerRequestPipeline.run(
          this,
          request,
          requestId,
          () => _dispatch(request, requestId),
        ),
      );
    });
  }

  Future<void> _dispatch(HttpRequest request, String requestId) async {
    final route = request.uri.path;
    if (request.method == 'GET' && route.startsWith('/playmesh/developer/')) {
      await _servePublicAsset(request, route);
      return;
    }
    if (request.method == 'GET' && route == session.workspacePath) {
      if (_constantTimeEquals(
        request.uri.queryParameters['token'] ?? '',
        token,
      )) {
        request.response.cookies.add(_developerSessionCookie());
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers
          ..set(HttpHeaders.locationHeader, request.uri.path)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        await request.response.close();
        return;
      }
      request.response.cookies.add(_developerSessionCookie());
      final workspaceTemplate = await rootBundle.loadString(
        'assets/playmesh-library/public/developer/workspace.html',
      );
      final workspace = workspaceTemplate.replaceFirst(
        '__PLAYMESH_APP_UI_BOOTSTRAP__',
        _workspaceUiBootstrapJson(),
      );
      await _html(request.response, workspace);
      return;
    }
    final gdevelopPath = session.gdevelopWorkspacePath!;
    if (request.method == 'GET' &&
        route == gdevelopPath.substring(0, gdevelopPath.length - 1)) {
      if (_constantTimeEquals(
        request.uri.queryParameters['token'] ?? '',
        token,
      )) {
        final queryCapability =
            request
                .uri
                .queryParameters[gdevelopEditorBootstrapQueryParameter] ??
            '';
        final validQueryCapability = gdevelopEditorInstances
            .validatesAcquireCapability(queryCapability);
        if (!validQueryCapability) {
          await _error(
            request.response,
            HttpStatus.forbidden,
            requestId,
            'gdevelop_editor_bootstrap_capability_invalid',
            'GDevelop 编辑器 bootstrap capability 无效或已轮换',
          );
          return;
        }
        request.response.cookies.add(_developerSessionCookie());
        if (validQueryCapability) {
          request.response.cookies.add(
            _gdevelopEditorAcquireCapabilityCookie(queryCapability),
          );
        }
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers
          ..set(HttpHeaders.locationHeader, gdevelopPath)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.temporaryRedirect;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        request.uri.replace(path: gdevelopPath).toString(),
      );
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && route.startsWith(gdevelopPath)) {
      if (_constantTimeEquals(
        request.uri.queryParameters['token'] ?? '',
        token,
      )) {
        final queryCapability =
            request
                .uri
                .queryParameters[gdevelopEditorBootstrapQueryParameter] ??
            '';
        final validQueryCapability = gdevelopEditorInstances
            .validatesAcquireCapability(queryCapability);
        if (!validQueryCapability) {
          await _error(
            request.response,
            HttpStatus.forbidden,
            requestId,
            'gdevelop_editor_bootstrap_capability_invalid',
            'GDevelop 编辑器 bootstrap capability 无效或已轮换',
          );
          return;
        }
        request.response.cookies.add(_developerSessionCookie());
        if (validQueryCapability) {
          request.response.cookies.add(
            _gdevelopEditorAcquireCapabilityCookie(queryCapability),
          );
        }
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers
          ..set(HttpHeaders.locationHeader, request.uri.path)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        await request.response.close();
        return;
      }
      await _serveGDevelopAsset(request, route.substring(gdevelopPath.length));
      return;
    }
    if (request.method == 'GET' && route.startsWith('/playmesh/')) {
      await _servePublicAsset(request, route);
      return;
    }
    if (await _developerOperationRegistry.dispatch(this, request, requestId)) {
      return;
    }
    await _error(
      request.response,
      HttpStatus.notFound,
      requestId,
      'route_not_found',
      '开发者接口不存在',
    );
  }

  String _requireCurrentAuthor() {
    final author = currentAuthor?.call().trim() ?? '';
    if (author.isEmpty) {
      throw StateError('当前 App 昵称不可用，无法写入项目发布者');
    }
    return author;
  }

  Cookie _developerSessionCookie() => Cookie('playmesh_developer_token', token)
    ..httpOnly = true
    ..sameSite = SameSite.strict
    ..path = '/';

  String _workspaceUiBootstrapJson() {
    final snapshot = localizationBridge?.current();
    return _safeInlineJson({
      'features': {'gdevelopAi': gdevelopAiFeaturePolicy.toUiBootstrapJson()},
      if (snapshot != null) ...{
        'themeMode': snapshot.themeMode,
        'effectiveTheme': snapshot.effectiveTheme,
        'allowThemeSwitch': snapshot.allowThemeSwitch,
      },
    });
  }

  String _safeInlineJson(Object? value) {
    return jsonEncode(value)
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026')
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
  }

  List<int> _injectGDevelopLocalizationBootstrap(List<int> data) {
    DeveloperWorkspaceLocalization? snapshot;
    try {
      snapshot = localizationBridge?.current();
    } on Object {
      // Localization is an optional first-paint optimization. App startup or
      // locale loading failures must never prevent the official IDE shell.
      snapshot = null;
    }
    final featurePolicy = _safeInlineJson(
      gdevelopAiFeaturePolicy.toUiBootstrapJson(),
    );
    final script = StringBuffer('<script>(function(){')
      ..write(
        "Object.defineProperty(globalThis,"
        "'__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__',{value:Object.freeze("
        '$featurePolicy),writable:false,configurable:false});',
      );
    if (snapshot != null) {
      final messages = <String, String>{
        for (final entry in snapshot.messages.entries)
          if (entry.key.startsWith('workspace.gdevelop_'))
            entry.key: entry.value,
      };
      final bootstrap = _safeInlineJson({
        ...snapshot.toJson(),
        'messages': messages,
      });
      script.write(
        'globalThis.__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__='
        '$bootstrap;',
      );
    }
    final editorBootstrap = _safeInlineJson({
      'pageId': 'editor_page_${_randomHex(24)}',
    });
    script
      ..write(
        'Object.defineProperty(globalThis,'
        "'__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_BOOTSTRAP__',"
        '{value:Object.freeze($editorBootstrap),writable:false,'
        'configurable:false});',
      )
      ..write(
        '})();</script>'
        '<script src="/playmesh/developer/gdevelop-editor-instance.js">'
        '</script>',
      );
    final html = utf8.decode(data);
    final lowerHtml = html.toLowerCase();
    final headStart = lowerHtml.indexOf('<head');
    if (headStart >= 0) {
      final headEnd = html.indexOf('>', headStart);
      if (headEnd >= 0) {
        return utf8.encode(
          '${html.substring(0, headEnd + 1)}${script.toString()}'
          '${html.substring(headEnd + 1)}',
        );
      }
    }
    final firstScript = lowerHtml.indexOf('<script');
    if (firstScript >= 0) {
      return utf8.encode(
        '${html.substring(0, firstScript)}${script.toString()}'
        '${html.substring(firstScript)}',
      );
    }
    final doctypeEnd = lowerHtml.startsWith('<!doctype')
        ? html.indexOf('>')
        : -1;
    if (doctypeEnd >= 0) {
      return utf8.encode(
        '${html.substring(0, doctypeEnd + 1)}${script.toString()}'
        '${html.substring(doctypeEnd + 1)}',
      );
    }
    return utf8.encode('${script.toString()}$html');
  }

  Future<T> _serializePackageFile<T>(Future<T> Function() action) {
    final operation = _packageFileTail.then((_) => action());
    _packageFileTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<List<LanEndpointCandidate>> sourceWorkspaceEndpoints() async {
    final endpoints = await resolveLanEndpointCandidates(server.port);
    return endpoints
        .map(
          (endpoint) => endpoint.withUri(
            endpoint.uri.replace(
              path: session.workspacePath!,
              queryParameters: {'token': token},
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<Uri>> sourceWorkspaceLinks() async =>
      (await sourceWorkspaceEndpoints())
          .map((endpoint) => endpoint.uri)
          .toList(growable: false);

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceEndpoints() async {
    if (!await gdevelopWebIdeSource.isAvailable()) return const [];
    final endpoints = await resolveLanEndpointCandidates(server.port);
    final editorBootstrap = gdevelopEditorInstances.issueAcquireCapability();
    return endpoints
        .map(
          (endpoint) => endpoint.withUri(
            endpoint.uri.replace(
              path: session.gdevelopWorkspacePath!,
              queryParameters: {
                'token': token,
                gdevelopEditorBootstrapQueryParameter: editorBootstrap,
              },
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<Uri>> gdevelopWorkspaceLinks() async =>
      (await gdevelopWorkspaceEndpoints())
          .map((endpoint) => endpoint.uri)
          .toList(growable: false);

  @override
  bool beginGDevelopWebIdeInstall() => gdevelopEditorInstances.beginInstall();

  @override
  void endGDevelopWebIdeInstall() => gdevelopEditorInstances.endInstall();

  Future<void> _serveGDevelopAsset(
    HttpRequest request,
    String requestedPath,
  ) async {
    if (requestedPath.startsWith('embedded-preview/')) {
      await _serveGDevelopEmbeddedPreviewAsset(request, requestedPath);
      return;
    }
    final relativePath = requestedPath.isEmpty ? 'index.html' : requestedPath;
    if (relativePath
        .split('/')
        .any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw const FormatException('GDevelop 资源路径无效');
    }
    final sourceData = await gdevelopWebIdeSource.read(relativePath);
    if (sourceData == null) {
      await _error(
        request.response,
        HttpStatus.notFound,
        'gdevelop-${_randomHex(8)}',
        'gdevelop_asset_not_found',
        'GDevelop Web IDE 资源不存在',
      );
      return;
    }
    if (relativePath == 'index.html') {
      // The WebIDE may be installed or repaired after Developer Mode starts.
      // A successful authenticated index read is the authoritative late
      // verification point. Activate the shared UI/backend policy before the
      // bootstrap is injected so the entry and its routes become available in
      // the same request, without requiring an App restart.
      gdevelopAiFeaturePolicy.markWorkspaceVerified();
      request.response.cookies.add(_developerSessionCookie());
      request.response.headers.set(
        HttpHeaders.cacheControlHeader,
        'no-store, no-cache, must-revalidate',
      );
    }
    final data = relativePath == 'index.html'
        ? _injectGDevelopLocalizationBootstrap(sourceData)
        : sourceData;
    request.response.headers.contentType = ContentType.parse(
      _publicContentType(relativePath),
    );
    request.response.add(data);
    await request.response.close();
  }

  Future<void> _serveGDevelopEmbeddedPreviewAsset(
    HttpRequest request,
    String requestedPath,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final segments = requestedPath.split('/');
    if (segments.length < 4 ||
        segments[0] != 'embedded-preview' ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw const FormatException('GDevelop 嵌入式预览资源路径无效');
    }
    final gameId = segments[1];
    final previewId = segments[2];
    final resourceSession = previewService.embeddedResourceSession(
      gameId: gameId,
      previewId: previewId,
    );
    if (resourceSession == null) {
      await _error(
        request.response,
        HttpStatus.notFound,
        'gdevelop-preview-${_randomHex(8)}',
        'gdevelop_embedded_preview_not_found',
        'GDevelop 嵌入式预览不存在或已过期',
      );
      return;
    }

    final upstreamUri = resourceSession.resourceBaseUri.replace(
      pathSegments: segments.sublist(3),
    );
    final client = HttpClient()..autoUncompress = false;
    try {
      final upstreamRequest = await client.openUrl(request.method, upstreamUri);
      upstreamRequest.headers.set(
        playmeshDevelopmentCredentialHeader,
        resourceSession.credential,
      );
      final upstreamResponse = await upstreamRequest.close();
      request.response.statusCode = upstreamResponse.statusCode;
      final contentType = upstreamResponse.headers.contentType;
      if (contentType != null) {
        request.response.headers.contentType = contentType;
      }
      final contentLength = upstreamResponse.contentLength;
      if (contentLength >= 0) request.response.contentLength = contentLength;
      request.response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        await upstreamResponse.pipe(request.response);
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> close() async {
    await _gdevelopAiLeaseBindingSubscription?.cancel();
    await _gdevelopAiCallSubscription?.cancel();
    await gdevelopAiEvents.dispose();
    gdevelopAiSessions.dispose();
    approvalBroker.dispose();
    gdevelopGeneratedCode.clear();
    gdevelopEditorInstances.clear();
    await gdevelopNativeFileSaves.dispose();
    await previewService.dispose();
    await runController.stopAllDevelopment();
    await server.close(force: true);
    await capabilityTests.dispose();
  }
}
