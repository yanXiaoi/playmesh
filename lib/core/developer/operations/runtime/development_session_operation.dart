part of '../../developer_web_gateway_io.dart';

class _DevelopmentSessionOperation implements _DeveloperHttpOperation {
  const _DevelopmentSessionOperation();

  static const _path = '/dev/api/projects/{projectId}/development';
  static const _packagePath = '$_path/package';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'runtime.development.status',
      method: 'GET',
      path: _path,
      summary: '读取项目开发资源会话状态',
      permission: 'runtime.run',
      parameters: [developerProjectIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'runtime.development.package.stage',
      method: 'POST',
      path: _packagePath,
      summary: '校验临时开发 app 包并返回一次性会话凭据',
      description: '只保存内存运行声明，不安装、不写入游戏库。',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      successStatus: 201,
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'runtime.development.start',
      method: 'POST',
      path: _path,
      summary: '绑定受控开发资源源并在真实 App 中启动项目',
      description: '资源地址必须属于当前 CLI 请求来源；会话只保存在内存并受一次性凭据和有效期约束。',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      successStatus: 202,
      parameters: [developerProjectIdParameter],
      requestBodySchema: {
        'type': 'object',
        'additionalProperties': false,
        'required': ['resourceBaseUrl', 'credential', 'expiresAt', 'packageId'],
        'properties': {
          'resourceBaseUrl': {'type': 'string', 'format': 'uri'},
          'credential': {'type': 'string', 'minLength': 32, 'maxLength': 128},
          'expiresAt': {'type': 'integer', 'minimum': 1},
          'packageId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
        },
      },
      requestExample: {
        'resourceBaseUrl': 'http://192.168.1.20:4173/',
        'credential': 'D7P9E0m4o7fXcqs8vYFf4qN1sG-AaB2cK6L3wZxQ',
        'expiresAt': 1785400000000,
        'packageId': 'package-0123456789abcdef0123456789abcdef',
      },
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'runtime.development.stop',
      method: 'DELETE',
      path: _path,
      summary: '撤销开发资源会话并停止临时开发运行',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
  ];

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) async {
    final projectId = pathParameters['projectId']!;
    switch (definition.id) {
      case 'runtime.development.status':
        final session = gateway.runController.resourceSession(projectId);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'active': session != null,
          if (session != null) ...{
            'projectId': projectId,
            'resourceBaseUrl': session.resourceBaseUri.toString(),
            'expiresAt': session.expiresAt.millisecondsSinceEpoch,
            'run': gateway.runController.status(projectId).toJson(),
          },
        });
      case 'runtime.development.package.stage':
        final mime = request.headers.contentType?.mimeType;
        if (mime != 'application/zip' &&
            mime != 'application/x-zip-compressed' &&
            mime != 'application/octet-stream') {
          throw const FormatException('开发临时包必须是 ZIP');
        }
        try {
          final result = await gateway.previewService.stageRuntimeDeclaration(
            gameId: projectId,
            archive: request,
            declaredLength: request.contentLength < 0
                ? null
                : request.contentLength,
          );
          await _json(request.response, HttpStatus.created, result.toJson());
        } on PackageUploadTooLarge catch (error) {
          throw _DeveloperRequestTooLarge(error.limit);
        } on PackageUploadEmpty {
          throw const FormatException('开发临时包不能为空');
        }
      case 'runtime.development.start':
        final body = await _jsonBody(request);
        final packageId = _developmentPackageId(body);
        final candidate = _parseDevelopmentSession(
          projectId: projectId,
          body: body,
          request: request,
          now: gateway.clock().toUtc(),
        );
        final declaration = await gateway.previewService
            .consumeRuntimeDeclaration(gameId: projectId, packageId: packageId);
        final session = DeveloperResourceSession(
          projectId: candidate.projectId,
          resourceBaseUri: candidate.resourceBaseUri,
          credential: candidate.credential,
          expiresAt: candidate.expiresAt,
          runtimeDeclaration: declaration,
        );
        final status = await gateway.runController.runDevelopment(session);
        await _json(request.response, HttpStatus.accepted, status.toJson());
      case 'runtime.development.stop':
        final status = await gateway.runController.stopDevelopment(projectId);
        await _json(request.response, HttpStatus.ok, status.toJson());
    }
  }
}

DeveloperResourceSession _parseDevelopmentSession({
  required String projectId,
  required Map<String, Object?> body,
  required HttpRequest request,
  required DateTime now,
}) {
  if (body.length != 4 ||
      !body.keys.toSet().containsAll({
        'resourceBaseUrl',
        'credential',
        'expiresAt',
        'packageId',
      })) {
    throw const FormatException('开发资源会话请求字段无效');
  }
  final rawBaseUrl = body['resourceBaseUrl'];
  final credential = body['credential'];
  final expiresAtValue = body['expiresAt'];
  if (rawBaseUrl is! String ||
      credential is! String ||
      expiresAtValue is! int) {
    throw const FormatException('开发资源会话请求类型无效');
  }
  final baseUri = Uri.tryParse(rawBaseUrl.trim());
  if (baseUri == null ||
      baseUri.scheme != 'http' ||
      baseUri.host.isEmpty ||
      !baseUri.hasPort ||
      baseUri.userInfo.isNotEmpty ||
      (baseUri.path.isNotEmpty && baseUri.path != '/') ||
      baseUri.hasQuery ||
      baseUri.hasFragment) {
    throw const FormatException('resourceBaseUrl 必须是带端口的 HTTP 根地址');
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(credential)) {
    throw const FormatException('开发资源会话凭据格式无效');
  }
  late final DateTime expiresAt;
  try {
    expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiresAtValue,
      isUtc: true,
    );
  } on RangeError {
    throw const FormatException('开发资源会话有效期不是有效的 Unix 毫秒时间戳');
  }
  if (!expiresAt.isAfter(now) ||
      expiresAt.isAfter(now.add(const Duration(hours: 24)))) {
    throw const FormatException('开发资源会话有效期必须在未来 24 小时内');
  }
  final advertisedAddress = InternetAddress.tryParse(baseUri.host);
  final requesterAddress = request.connectionInfo?.remoteAddress;
  if (advertisedAddress == null ||
      requesterAddress == null ||
      !_sameDevelopmentPeer(advertisedAddress, requesterAddress)) {
    throw const FormatException('开发资源地址必须属于当前 CLI 请求来源');
  }
  return DeveloperResourceSession(
    projectId: projectId,
    resourceBaseUri: baseUri.replace(path: '/'),
    credential: credential,
    expiresAt: expiresAt,
  );
}

String _developmentPackageId(Map<String, Object?> body) {
  final value = body['packageId'];
  if (value is! String || !RegExp(r'^package-[a-f0-9]{32}$').hasMatch(value)) {
    throw const DeveloperPreviewPackageRequired(
      stage: 'development_package_bind',
      operation: 'runtime.development.start',
    );
  }
  return value;
}

bool _sameDevelopmentPeer(
  InternetAddress advertised,
  InternetAddress requester,
) {
  if (advertised.isLoopback && requester.isLoopback) return true;
  return advertised.address == requester.address;
}
