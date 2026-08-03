import 'dart:convert';

import '../../developer_ai_prompt_templates.dart';
import '../developer_operation_definition.dart';
import 'developer_operation_document_renderer.dart';

class DeveloperChatOperationRenderer
    implements DeveloperOperationDocumentRenderer {
  const DeveloperChatOperationRenderer({
    required this.resources,
    this.bootstrapOnly = false,
  });

  final DeveloperAiPromptResources resources;
  final bool bootstrapOnly;

  @override
  String get id => bootstrapOnly ? 'chat-bootstrap' : 'chat';

  @override
  String render(
    Iterable<DeveloperOperationDefinition> operations,
    DeveloperOperationDocumentContext context,
  ) {
    String text(String key) => resources.text(key);
    final visible = operations
        .where(
          (operation) =>
              operation.chatEnabled &&
              (!bootstrapOnly || operation.chatBootstrap),
        )
        .toList(growable: false);
    final output = StringBuffer()
      ..writeln(text('chat.title'))
      ..writeln('catalogVersion: ${context.catalogVersion}')
      ..writeln('projectId: ${context.projectId}')
      ..writeln()
      ..writeln(text('chat.paste'))
      ..writeln(text('chat.sameOrigin'))
      ..writeln(text('chat.approval'))
      ..writeln(text('chat.instructionFormat'))
      ..writeln('```json')
      ..writeln(
        const JsonEncoder.withIndent('  ').convert({
          'id': '<correlation-id>',
          'method': 'GET|POST|PUT|PATCH|DELETE',
          'path': '/dev/api/...',
          'body': {'<field>': true},
        }),
      )
      ..writeln('```')
      ..writeln()
      ..writeln(text('chat.rules'))
      ..writeln('- ${text('chat.rulePath')}')
      ..writeln('- ${text('chat.ruleParameters')}')
      ..writeln('- ${text('chat.ruleRevision')}')
      ..writeln('- ${text('chat.ruleRisk')}')
      ..writeln('- ${text('chat.ruleBoundary')}')
      ..writeln()
      ..writeln(
        text(bootstrapOnly ? 'chat.bootstrapTitle' : 'chat.catalogTitle'),
      );
    for (final operation in visible) {
      final path = operation.path.replaceAll(
        '{projectId}',
        Uri.encodeComponent(context.projectId),
      );
      output
        ..writeln()
        ..writeln('### ${operation.id} — ${operation.normalizedMethod} $path');
      if (resources.includeSourceMetadata) {
        output.writeln(operation.summary);
      }
      output.writeln(
        'permission `${operation.permission}`; risk `${operation.risk.name}`; '
        'idempotent `${operation.idempotent}`; '
        'dangerous `${operation.dangerous}`.',
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
            '- `${parameter.name}` (${parameter.location.name}, '
            '$requirement)$description',
          );
        }
      }
      if (operation.requestExample != null) {
        output
          ..writeln(text('chat.requestExample'))
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
