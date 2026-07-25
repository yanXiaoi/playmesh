import 'dart:convert';

import '../developer_operation_definition.dart';
import 'developer_operation_document_renderer.dart';

class DeveloperChatOperationRenderer
    implements DeveloperOperationDocumentRenderer {
  const DeveloperChatOperationRenderer({this.bootstrapOnly = false});

  final bool bootstrapOnly;

  @override
  String get id => bootstrapOnly ? 'chat-bootstrap' : 'chat';

  @override
  String render(
    Iterable<DeveloperOperationDefinition> operations,
    DeveloperOperationDocumentContext context,
  ) {
    final visible = operations
        .where(
          (operation) =>
              operation.chatEnabled &&
              (!bootstrapOnly || operation.chatBootstrap),
        )
        .toList(growable: false);
    final output = StringBuffer()
      ..writeln('Playmesh 对话控制台指令协议')
      ..writeln('catalogVersion: ${context.catalogVersion}')
      ..writeln('projectId: ${context.projectId}')
      ..writeln()
      ..writeln('把一个 JSON 对象或 JSON 数组粘贴到“对话控制台”。')
      ..writeln('控制台只执行当前工作区同源的 /dev/api/** 请求，并把结构化结果返回给 AI。')
      ..writeln(
        '控制台会自动附加 `$developerAiChannelHeader: chat`；'
        '危险操作会等待开发者审批，拒绝返回 403，30 秒未决定返回 408。',
      )
      ..writeln('指令格式：')
      ..writeln('```json')
      ..writeln(
        const JsonEncoder.withIndent('  ').convert({
          'id': '由 AI 生成的关联 ID',
          'method': 'GET|POST|PUT|PATCH|DELETE',
          'path': '/dev/api/...',
          'body': {'仅在接口需要 JSON 请求体时提供': true},
        }),
      )
      ..writeln('```')
      ..writeln()
      ..writeln('规则：')
      ..writeln('- path 必须使用下面声明的真实 Developer API 路径。')
      ..writeln('- 路径参数必须替换，查询参数必须进行 URL 编码。')
      ..writeln('- 修改现有文件前先读取 revision，并提交 baseRevision。')
      ..writeln('- 高风险操作只有在用户明确要求时才能生成；dangerous=true 的接口还必须经过开发者审批。')
      ..writeln('- 不得生成系统命令、外部 URL 或 /dev/api/** 之外的请求。')
      ..writeln()
      ..writeln(bootstrapOnly ? '默认基础指令：' : '完整指令目录：');
    for (final operation in visible) {
      final path = operation.path.replaceAll(
        '{projectId}',
        Uri.encodeComponent(context.projectId),
      );
      output
        ..writeln()
        ..writeln('### ${operation.id} — ${operation.normalizedMethod} $path')
        ..writeln(operation.summary)
        ..writeln(
          '权限 `${operation.permission}`；风险 `${operation.risk.name}`；'
          '幂等 `${operation.idempotent}`；'
          '危险操作 `${operation.dangerous}`。',
        );
      if (operation.description.isNotEmpty) {
        output.writeln(operation.description);
      }
      if (operation.parameters.isNotEmpty) {
        output.writeln('参数：');
        for (final parameter in operation.parameters) {
          output.writeln(
            '- `${parameter.name}` (${parameter.location.name}, '
            '${parameter.required ? '必填' : '可选'})：${parameter.description}',
          );
        }
      }
      if (operation.requestExample != null) {
        output
          ..writeln('请求体示例：')
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
