part of '../developer_web_gateway_io.dart';

abstract interface class _DeveloperHttpOperation {
  List<DeveloperOperationDefinition> get definitions;

  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  );
}

class _DeveloperOperationMatch {
  const _DeveloperOperationMatch({
    required this.operation,
    required this.definition,
    required this.pathParameters,
  });

  final _DeveloperHttpOperation operation;
  final DeveloperOperationDefinition definition;
  final Map<String, String> pathParameters;
}
