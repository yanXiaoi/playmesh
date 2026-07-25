import '../developer_operation_definition.dart';

class DeveloperOperationDocumentContext {
  const DeveloperOperationDocumentContext({
    required this.projectId,
    required this.baseUrl,
    required this.token,
    required this.catalogVersion,
  });

  final String projectId;
  final Uri baseUrl;
  final String token;
  final String catalogVersion;
}

abstract interface class DeveloperOperationDocumentRenderer {
  String get id;

  String render(
    Iterable<DeveloperOperationDefinition> operations,
    DeveloperOperationDocumentContext context,
  );
}
