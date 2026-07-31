import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../models/game_capabilities.dart';
import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../game_package/game_package_transfer_service.dart';
import '../game_sdk/sdk_feature_registry.dart';
import '../network/lan_endpoint_resolver.dart';
import 'developer_ai_prompt_templates.dart';
import 'developer_capability_test_service.dart';
import 'developer_channel.dart';
import 'developer_event_hub.dart';
import 'developer_background_host.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
import 'developer_web_gateway_contract.dart';
import 'operations/developer_operation_definition.dart';
import 'operations/documentation/developer_agent_operation_renderer.dart';
import 'operations/documentation/developer_chat_operation_renderer.dart';
import 'operations/documentation/developer_operation_document_renderer.dart';
import 'operations/middleware/developer_operation_metadata_middleware.dart';
import 'operations/middleware/developer_operation_middleware.dart';
import 'operations/middleware/developer_operation_responses_middleware.dart';
import 'operations/middleware/developer_operation_security_middleware.dart';

part 'operations/developer_http_operation.dart';
part 'operations/developer_operation_registry.dart';
part 'operations/infrastructure/developer_file_support.dart';
part 'operations/infrastructure/developer_http_support.dart';
part 'operations/infrastructure/empty_developer_project_catalog.dart';
part 'operations/approvals/developer_ai_approval_broker.dart';
part 'operations/approvals/developer_operation_execution_middleware.dart';
part 'operations/approvals/ai_approval_operation.dart';
part 'operations/middleware/developer_request_middleware.dart';
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
part 'operations/packages/package_import_operation.dart';
part 'operations/packages/project_package_operation.dart';
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
part 'operations/system/localization_operation.dart';
part 'operations/system/qr_operation.dart';
part 'operations/system/sdk_bundle_operation.dart';
part 'operations/system/status_operation.dart';

final _developerOperationRegistry = _DeveloperOperationRegistry(const [
  _DocumentationOperation(),
  _LocalizationOperation(),
  _StatusOperation(),
  _SdkBundleOperation(),
  _ActiveRunOperation(),
  _ProjectsOperation(),
  _ProjectOperation(),
  _ProjectCopyOperation(),
  _PackageImportOperation(),
  _ProjectPackageOperation(),
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
  DeveloperWorkspaceLocalizationBridge? localizationBridge,
  String Function()? currentAuthor,
  DeveloperViewAvailabilityProvider? viewAvailability,
  DateTime Function()? clock,
}) async {
  if (port < 1 || port > 65535) {
    throw const FormatException('开发者通道端口必须在 1 到 65535 之间');
  }
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final gateway = _IoDeveloperWebGateway(
      server: server,
      token: _createToken(token),
      path: _createPath(path),
      catalog: catalog ?? const _EmptyDeveloperProjectCatalog(),
      promptTemplates: promptTemplates ?? DeveloperAiPromptTemplateStore(),
      runController: runController ?? DeveloperRunController(),
      capabilityTests: capabilityTests ?? DeveloperCapabilityTestService(),
      packageTransfer: packageTransfer ?? GamePackageTransferService(),
      projectPublisher: projectPublisher,
      localizationBridge: localizationBridge,
      currentAuthor: currentAuthor,
      viewAvailability:
          viewAvailability ??
          (() async => const DeveloperViewAvailability.available()),
      clock: clock ?? DateTime.now,
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
    required this.localizationBridge,
    required this.currentAuthor,
    required this.viewAvailability,
    required this.clock,
  }) : session = DeveloperSession(
         enabled: true,
         port: server.port,
         path: path,
         token: token,
         tokenHint: token.substring(token.length - 6),
         workspacePath: '/dev/$path/workspace',
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
  final DeveloperWorkspaceLocalizationBridge? localizationBridge;
  final String Function()? currentAuthor;
  final DeveloperViewAvailabilityProvider viewAvailability;
  final DateTime Function() clock;
  final _DeveloperAiApprovalBroker approvalBroker =
      _DeveloperAiApprovalBroker();

  Future<void> _packageFileTail = Future<void>.value();

  @override
  final DeveloperSession session;

  void listen() {
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
      request.response.cookies.add(
        Cookie('playmesh_developer_token', token)
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..path = '/',
      );
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

  String _workspaceUiBootstrapJson() {
    final snapshot = localizationBridge?.current();
    if (snapshot == null) return 'null';
    return jsonEncode({
          'themeMode': snapshot.themeMode,
          'effectiveTheme': snapshot.effectiveTheme,
          'allowThemeSwitch': snapshot.allowThemeSwitch,
        })
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026')
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
  }

  Future<T> _serializePackageFile<T>(Future<T> Function() action) {
    final operation = _packageFileTail.then((_) => action());
    _packageFileTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<List<Uri>> workspaceLinks() async {
    final endpoints = await resolveLanEndpoints(server.port);
    return endpoints
        .map(
          (endpoint) => endpoint.replace(
            path: session.workspacePath,
            queryParameters: {'token': token},
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() async {
    approvalBroker.dispose();
    await runController.stopAllDevelopment();
    await server.close(force: true);
    await capabilityTests.dispose();
  }
}
