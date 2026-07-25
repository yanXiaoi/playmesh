import '../developer_operation_definition.dart';

enum DeveloperOperationDocumentTarget { catalog, openApi }

/// 操作声明中间件只注入跨接口公共数据，接口文件仅保留自身差异。
abstract interface class DeveloperOperationMiddleware {
  void apply(
    DeveloperOperationDefinition operation,
    DeveloperOperationDocumentTarget target,
    Map<String, Object?> document,
  );
}
