import 'developer_ai_prompt_templates.dart';
import 'developer_capability_test_service.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
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
  String Function()? currentAuthor,
  DateTime Function()? clock,
}) {
  throw UnsupportedError('当前平台不支持网页开发者通道');
}
