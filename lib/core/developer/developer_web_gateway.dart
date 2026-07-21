import 'developer_ai_prompt_templates.dart';
import 'developer_capability_test_service.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
import 'developer_web_gateway_contract.dart';
import 'developer_web_gateway_stub.dart'
    if (dart.library.io) 'developer_web_gateway_io.dart'
    as implementation;
import '../game_package/game_package_transfer_service.dart';

export 'developer_web_gateway_contract.dart';

Future<DeveloperWebGateway> startDeveloperWebGateway({
  required int port,
  String? token,
  String? path,
  DeveloperProjectCatalog? catalog,
  DeveloperAiPromptTemplateStore? promptTemplates,
  DeveloperRunController? runController,
  DeveloperCapabilityTestService? capabilityTests,
  GamePackageTransferService? packageTransfer,
}) {
  return implementation.startDeveloperWebGateway(
    port: port,
    token: token,
    path: path,
    catalog: catalog,
    promptTemplates: promptTemplates,
    runController: runController,
    capabilityTests: capabilityTests,
    packageTransfer: packageTransfer,
  );
}
