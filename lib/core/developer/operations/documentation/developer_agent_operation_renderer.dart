import 'dart:convert';

import '../developer_operation_definition.dart';
import 'developer_operation_document_renderer.dart';

class DeveloperAgentOperationRenderer
    implements DeveloperOperationDocumentRenderer {
  const DeveloperAgentOperationRenderer();

  @override
  String get id => 'agent';

  @override
  String render(
    Iterable<DeveloperOperationDefinition> operations,
    DeveloperOperationDocumentContext context,
  ) {
    final visible = operations
        .where((operation) => operation.agentEnabled)
        .toList(growable: false);
    final output = StringBuffer()
      ..writeln('Playmesh Agent Developer API 操作目录')
      ..writeln('catalogVersion: ${context.catalogVersion}')
      ..writeln('baseUrl: ${context.baseUrl}')
      ..writeln('projectId: ${context.projectId}')
      ..writeln('鉴权：Authorization: Bearer ${context.token}')
      ..writeln('AI 通道：$developerAiChannelHeader: agent')
      ..writeln()
      ..writeln('所有操作都来自运行时实际路由使用的同一注册表。')
      ..writeln(
        '每个 Agent 请求都必须携带 `$developerAiChannelHeader: agent`；'
        '危险操作会暂停执行并等待开发者审批，拒绝返回 403，30 秒未决定返回 408。',
      )
      ..writeln('修改现有文件前读取 revision；非幂等请求不得盲目重试。');
    for (final operation in visible) {
      final path = operation.path.replaceAll(
        '{projectId}',
        Uri.encodeComponent(context.projectId),
      );
      output
        ..writeln()
        ..writeln(
          '### ${operation.id} — ${operation.normalizedMethod} '
          '${context.baseUrl.resolve(path)}',
        )
        ..writeln(operation.summary)
        ..writeln(
          'permission=${operation.permission} risk=${operation.risk.name} '
          'idempotent=${operation.idempotent} '
          'dangerous=${operation.dangerous}',
        );
      if (operation.description.isNotEmpty) {
        output.writeln(operation.description);
      }
      if (operation.parameters.isNotEmpty) {
        output.writeln('参数：');
        for (final parameter in operation.parameters) {
          output.writeln(
            '- ${parameter.location.name}.${parameter.name}: '
            '${parameter.description}',
          );
        }
      }
      if (operation.requestExample != null) {
        output
          ..writeln('application/json 示例：')
          ..writeln('```json')
          ..writeln(
            const JsonEncoder.withIndent(
              '  ',
            ).convert(operation.requestExample),
          )
          ..writeln('```');
      }
    }
    return output.toString().trimRight();
  }
}
