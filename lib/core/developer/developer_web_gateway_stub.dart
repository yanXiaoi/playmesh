import 'developer_ai_prompt_templates.dart';
import 'developer_capability_test_service.dart';
import 'developer_preview_service.dart';
import 'foundation/developer_ai_approval.dart';
import 'developer_background_host.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
import 'gdevelop_web_ide_source.dart';
import 'gdevelop_project_config_controller.dart';
import 'gdevelop_project_history.dart';
import 'gdevelop_project_allocation_controller.dart';
import 'gdevelop_project_rekey_controller.dart';
import 'gdevelop_restore_transaction.dart';
import 'gdevelop_ai_session_service.dart';
import 'gdevelop_ai_feature_policy.dart';
import 'gdevelop_catalog_artifact_service.dart';
import 'gdevelop_editor_instance_lease.dart';
import 'developer_web_gateway_contract.dart';
import '../game_package/game_package_transfer_service.dart';

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
}) {
  throw UnsupportedError('当前平台不支持网页开发者通道');
}
