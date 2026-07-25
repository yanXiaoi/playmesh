import '../developer_operation_definition.dart';
import 'developer_operation_middleware.dart';

class DeveloperOperationSecurityMiddleware
    implements DeveloperOperationMiddleware {
  const DeveloperOperationSecurityMiddleware();

  @override
  void apply(
    DeveloperOperationDefinition operation,
    DeveloperOperationDocumentTarget target,
    Map<String, Object?> document,
  ) {
    if (target != DeveloperOperationDocumentTarget.openApi) return;
    document['security'] = [
      {'developerToken': <Object>[]},
    ];
  }
}
