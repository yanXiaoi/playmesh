const developerAiChannelHeader = 'X-Playmesh-AI-Channel';

enum DeveloperOperationRisk { low, medium, high }

enum DeveloperOperationParameterLocation { path, query }

class DeveloperOperationParameter {
  const DeveloperOperationParameter({
    required this.name,
    required this.location,
    required this.description,
    this.required = false,
    this.schema = const {'type': 'string'},
  });

  final String name;
  final DeveloperOperationParameterLocation location;
  final String description;
  final bool required;
  final Map<String, Object?> schema;

  Map<String, Object?> toOpenApi() => {
    'name': name,
    'in': location.name,
    'description': description,
    'required':
        required || location == DeveloperOperationParameterLocation.path,
    'schema': schema,
  };

  Map<String, Object?> toJson() => {
    'name': name,
    'location': location.name,
    'description': description,
    'required':
        required || location == DeveloperOperationParameterLocation.path,
    'schema': schema,
  };
}

class DeveloperOperationDefinition {
  const DeveloperOperationDefinition({
    required this.id,
    required this.method,
    required this.path,
    required this.summary,
    this.description = '',
    this.permission = 'project.read',
    this.risk = DeveloperOperationRisk.low,
    this.idempotent = true,
    this.dangerous = false,
    this.requiresForegroundView = false,
    this.parameters = const [],
    this.requestBodySchema,
    this.requestExample,
    this.responseDescription = '成功',
    this.successStatus = 200,
    this.additionalResponses = const {},
    this.chatEnabled = true,
    this.agentEnabled = true,
    this.chatBootstrap = false,
  });

  final String id;
  final String method;
  final String path;
  final String summary;
  final String description;
  final String permission;
  final DeveloperOperationRisk risk;
  final bool idempotent;
  final bool dangerous;
  final bool requiresForegroundView;
  final List<DeveloperOperationParameter> parameters;
  final Map<String, Object?>? requestBodySchema;
  final Object? requestExample;
  final String responseDescription;
  final int successStatus;
  final Map<int, String> additionalResponses;
  final bool chatEnabled;
  final bool agentEnabled;
  final bool chatBootstrap;

  String get normalizedMethod => method.toUpperCase();

  Map<String, Object?> toCatalogBase() => {
    'id': id,
    'method': normalizedMethod,
    'path': path,
    'summary': summary,
    if (description.isNotEmpty) 'description': description,
    'parameters': parameters.map((item) => item.toJson()).toList(),
    if (requestBodySchema != null) 'requestBodySchema': requestBodySchema,
    if (requestExample != null) 'requestExample': requestExample,
    'chatEnabled': chatEnabled,
    'agentEnabled': agentEnabled,
    'chatBootstrap': chatBootstrap,
  };

  Map<String, Object?> toOpenApiBase() => {
    'operationId': id,
    'summary': summary,
    if (description.isNotEmpty) 'description': description,
    if (parameters.isNotEmpty)
      'parameters': parameters.map((item) => item.toOpenApi()).toList(),
    if (requestBodySchema != null)
      'requestBody': {
        'required': true,
        'content': {
          'application/json': {
            'schema': requestBodySchema,
            if (requestExample != null) 'example': requestExample,
          },
        },
      },
  };
}

const developerProjectIdParameter = DeveloperOperationParameter(
  name: 'projectId',
  location: DeveloperOperationParameterLocation.path,
  description: '当前开发者项目 ID',
  required: true,
);

const developerGameIdParameter = DeveloperOperationParameter(
  name: 'gameId',
  location: DeveloperOperationParameterLocation.path,
  description: 'GDevelop packageName 与 Playmesh main.json.id 共用的稳定游戏 ID',
  required: true,
);

const developerPathQueryParameter = DeveloperOperationParameter(
  name: 'path',
  location: DeveloperOperationParameterLocation.query,
  description: '项目内路径；普通源码路径相对于项目根目录',
  required: true,
);
