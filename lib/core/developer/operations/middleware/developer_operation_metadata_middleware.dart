import '../developer_operation_definition.dart';
import 'developer_operation_middleware.dart';

class DeveloperOperationMetadataMiddleware
    implements DeveloperOperationMiddleware {
  const DeveloperOperationMetadataMiddleware();

  @override
  void apply(
    DeveloperOperationDefinition operation,
    DeveloperOperationDocumentTarget target,
    Map<String, Object?> document,
  ) {
    if (target == DeveloperOperationDocumentTarget.openApi) {
      document
        ..['x-permission'] = operation.permission
        ..['x-risk'] = operation.risk.name
        ..['x-idempotent'] = operation.idempotent
        ..['x-retry'] = operation.idempotent ? 'safe' : 'revision_guarded'
        ..['x-dangerous'] = operation.dangerous
        ..['x-requires-foreground-view'] = operation.requiresForegroundView;
      return;
    }
    document
      ..['permission'] = operation.permission
      ..['risk'] = operation.risk.name
      ..['idempotent'] = operation.idempotent
      ..['retry'] = operation.idempotent ? 'safe' : 'revision_guarded'
      ..['dangerous'] = operation.dangerous
      ..['requiresForegroundView'] = operation.requiresForegroundView;
  }
}
