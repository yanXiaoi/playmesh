import 'dart:convert';

import '../../developer_ai_prompt_templates.dart';
import '../developer_operation_definition.dart';
import 'developer_operation_document_renderer.dart';

class DeveloperAgentOperationRenderer
    implements DeveloperOperationDocumentRenderer {
  const DeveloperAgentOperationRenderer({required this.resources});

  final DeveloperAiPromptResources resources;

  @override
  String get id => 'agent';

  @override
  String render(
    Iterable<DeveloperOperationDefinition> operations,
    DeveloperOperationDocumentContext context,
  ) {
    String text(String key) => resources.text(key);
    final visible = operations
        .where((operation) => operation.agentEnabled)
        .toList(growable: false);
    final output = StringBuffer()
      ..writeln(text('agent.title'))
      ..writeln('catalogVersion: ${context.catalogVersion}')
      ..writeln('baseUrl: ${context.baseUrl}')
      ..writeln('projectId: ${context.projectId}')
      ..writeln('${text('agent.authorization')}: Bearer ${context.token}')
      ..writeln('${text('agent.aiChannel')}: $developerAiChannelHeader: agent')
      ..writeln()
      ..writeln(text('agent.registry'))
      ..writeln(text('agent.approval'))
      ..writeln(text('agent.revision'));
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
        );
      if (resources.includeSourceMetadata) {
        output.writeln(operation.summary);
      }
      output.writeln(
        'permission=${operation.permission} risk=${operation.risk.name} '
        'idempotent=${operation.idempotent} '
        'dangerous=${operation.dangerous}',
      );
      if (resources.includeSourceMetadata && operation.description.isNotEmpty) {
        output.writeln(operation.description);
      }
      if (operation.parameters.isNotEmpty) {
        output.writeln(text('common.parameters'));
        for (final parameter in operation.parameters) {
          final requirement = parameter.required
              ? text('common.required')
              : text('common.optional');
          final description = resources.includeSourceMetadata
              ? ': ${parameter.description}'
              : '';
          output.writeln(
            '- ${parameter.location.name}.${parameter.name} '
            '($requirement)$description',
          );
        }
      }
      if (operation.requestExample != null) {
        output
          ..writeln(text('agent.jsonExample'))
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
