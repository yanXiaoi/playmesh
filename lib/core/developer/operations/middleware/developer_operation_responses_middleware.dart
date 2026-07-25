import '../developer_operation_definition.dart';
import 'developer_operation_middleware.dart';

class DeveloperOperationResponsesMiddleware
    implements DeveloperOperationMiddleware {
  const DeveloperOperationResponsesMiddleware();

  @override
  void apply(
    DeveloperOperationDefinition operation,
    DeveloperOperationDocumentTarget target,
    Map<String, Object?> document,
  ) {
    document['responses'] = {
      '${operation.successStatus}': {
        'description': operation.responseDescription,
      },
      '400': {'description': '请求参数无效'},
      '401': {'description': 'Token 无效或开发者模式已关闭'},
      if (operation.dangerous) '403': {'description': '开发者拒绝了 AI 危险操作'},
      if (operation.dangerous) '408': {'description': 'AI 危险操作等待开发者批准超过 30 秒'},
      if (!operation.idempotent || operation.requiresForegroundView)
        '409': {
          'description': operation.requiresForegroundView
              ? 'App 页面不在可见且可交互状态，或存在其他状态/修订冲突'
              : '状态或修订冲突',
        },
      for (final response in operation.additionalResponses.entries)
        '${response.key}': {'description': response.value},
      '500': {'description': '开发者通道内部错误'},
    };
  }
}
