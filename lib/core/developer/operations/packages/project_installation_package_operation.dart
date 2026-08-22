part of '../../developer_web_gateway_io.dart';

class _ProjectInstallationPackageOperation implements _DeveloperHttpOperation {
  const _ProjectInstallationPackageOperation();

  static const _collectionSuffix = 'package-exports';
  static const _createSchema = <String, Object?>{
    'type': 'object',
    'required': [
      'target',
      'refreshRuntime',
      'runtimeDownloadId',
      'autoApproveCapabilities',
      'relayServer',
    ],
    'additionalProperties': false,
    'properties': {
      'target': {
        'type': 'string',
        'enum': [
          developerInstallationPackageTargetAndroidArm64,
          developerInstallationPackageTargetAndroidX86_64,
          developerInstallationPackageTargetWindowsX64,
        ],
      },
      'refreshRuntime': {'type': 'boolean'},
      'runtimeDownloadId': {
        'type': ['string', 'null'],
        'pattern': r'^[a-f0-9]{64}$',
      },
      'autoApproveCapabilities': {'type': 'boolean'},
      'relayServer': {
        'type': ['string', 'null'],
        'maxLength': 2048,
      },
    },
  };

  static const _optionsScopeParameter = DeveloperOperationParameter(
    name: 'scope',
    location: DeveloperOperationParameterLocation.query,
    description: '按需读取本地状态、Runtime 线路、线路延迟或中转服务器',
    schema: {
      'type': 'string',
      'enum': ['local', 'runtime', 'probes', 'relays'],
      'default': 'local',
    },
  );

  static const _optionsTargetParameter = DeveloperOperationParameter(
    name: 'target',
    location: DeveloperOperationParameterLocation.query,
    description: '读取 Runtime 线路或延迟时指定的导出目标',
    schema: {
      'type': 'string',
      'enum': [
        developerInstallationPackageTargetAndroidArm64,
        developerInstallationPackageTargetAndroidX86_64,
        developerInstallationPackageTargetWindowsX64,
      ],
    },
  );

  static const _optionsSourceParameter = DeveloperOperationParameter(
    name: 'source',
    location: DeveloperOperationParameterLocation.query,
    description: '测速时指定已选择的 Runtime 清单来源 opaque ID',
    schema: {'type': 'string', 'pattern': r'^[a-f0-9]{64}$'},
  );

  static const _exportIdParameter = DeveloperOperationParameter(
    name: 'exportId',
    location: DeveloperOperationParameterLocation.path,
    description: '安装包导出服务返回的随机暂存 ID',
    required: true,
  );

  static const _progressRequestIdParameter = DeveloperOperationParameter(
    name: developerInstallationPackageProgressRequestIdHeader,
    location: DeveloperOperationParameterLocation.header,
    description: '客户端生成的安装包导出进度关联 ID；省略时退回本次 HTTP requestId',
    schema: {
      'type': 'string',
      'minLength': 8,
      'maxLength': 64,
      'pattern': r'^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$',
    },
  );

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'package_exports.options',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/package-exports',
      summary: '按需读取 Runtime 本地状态、下载选项、延迟或游戏中转服务器',
      parameters: [
        developerProjectIdParameter,
        _optionsScopeParameter,
        _optionsTargetParameter,
        _optionsSourceParameter,
      ],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'package_exports.create',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/package-exports',
      summary: '校验项目并生成 Android APK 或 Windows ZIP 安装包',
      permission: 'project.export',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter, _progressRequestIdParameter],
      requestBodySchema: _createSchema,
      requestExample: {
        'target': developerInstallationPackageTargetAndroidArm64,
        'refreshRuntime': false,
        'runtimeDownloadId': null,
        'autoApproveCapabilities': false,
        'relayServer': null,
      },
      successStatus: 201,
      additionalResponses: {
        409: '所选 Runtime 底包没有安装且当前没有可用下载线路',
        422: '项目、Runtime 底包或所选中转服务器校验失败',
        503: '安装包导出服务或 Runtime 下载暂时不可用',
      },
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'package_exports.download',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/package-exports/{exportId}',
      summary: '流式下载已经生成的安装包',
      permission: 'project.export',
      parameters: [developerProjectIdParameter, _exportIdParameter],
      additionalResponses: {404: '安装包暂存文件不存在或已经释放'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'package_exports.release',
      method: 'DELETE',
      path: '/dev/api/projects/{projectId}/package-exports/{exportId}',
      summary: '释放已经生成的安装包暂存文件',
      permission: 'project.export',
      parameters: [developerProjectIdParameter, _exportIdParameter],
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
    await _requireProject(gateway, projectId);
    switch (definition.id) {
      case 'package_exports.options':
        await _options(gateway, request, requestId, projectId);
      case 'package_exports.create':
        await _create(gateway, request, requestId, projectId);
      case 'package_exports.download':
        await _download(
          gateway,
          request,
          requestId,
          projectId,
          _validExportId(pathParameters['exportId']!),
        );
      case 'package_exports.release':
        final service = gateway.installationPackageService;
        if (service != null) {
          final exportId = _validExportId(pathParameters['exportId']!);
          final artifact = service.find(exportId);
          if (artifact != null && artifact.projectId == projectId) {
            await service.release(exportId);
          }
        }
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
    }
  }

  Future<void> _options(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final service = gateway.installationPackageService;
    final query = request.uri.queryParametersAll;
    if (query.keys.toSet().difference(const {
          'scope',
          'target',
          'source',
        }).isNotEmpty ||
        query.values.any((values) => values.length != 1)) {
      throw const FormatException('安装包选项查询参数无效');
    }
    final scope = query['scope']?.single ?? 'local';
    final targetId = query['target']?.single;
    final sourceId = query['source']?.single;
    final validTarget =
        targetId != null &&
        developerInstallationPackageTargetIds.contains(targetId);
    final validSource =
        sourceId != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceId);
    final validQuery = switch (scope) {
      'local' || 'relays' => targetId == null && sourceId == null,
      'runtime' => validTarget && sourceId == null,
      'probes' => validTarget && validSource,
      _ => false,
    };
    if (!validQuery) {
      throw const FormatException('安装包选项 scope、target 与 source 不匹配');
    }
    final response = <String, Object?>{
      'requestId': requestId,
      'projectId': projectId,
      'available': service != null,
      'scope': scope,
    };
    switch (scope) {
      case 'local':
        final targets = service == null
            ? const <DeveloperInstallationPackageTargetStatus>[]
            : await service.inspectLocalTargets();
        response['targets'] = [
          for (final target in targets)
            {...target.toJson(), 'runtimeOptionsLoaded': false},
        ];
      case 'runtime':
        response['target'] = service == null
            ? null
            : {
                ...(await service.inspectRuntimeTarget(targetId!)).toJson(),
                'runtimeOptionsLoaded': true,
              };
      case 'probes':
        final downloads = service == null
            ? const <DeveloperInstallationPackageRuntimeDownload>[]
            : await service.probeRuntimeTargetDownloads(targetId!, sourceId!);
        response['targetId'] = targetId;
        response['sourceId'] = sourceId;
        response['runtimeDownloads'] = [
          for (final download in downloads) download.toJson(),
        ];
      case 'relays':
        final relayServers = service == null
            ? const <DeveloperInstallationPackageRelayServer>[]
            : await service.inspectRelayServers();
        response['relayServers'] = [
          for (final server in relayServers) server.toJson(),
        ];
    }
    await _json(request.response, HttpStatus.ok, response);
  }

  Future<void> _create(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    if (body.keys.toSet().difference(const {
          'target',
          'refreshRuntime',
          'runtimeDownloadId',
          'autoApproveCapabilities',
          'relayServer',
        }).isNotEmpty ||
        !body.keys.toSet().containsAll(const {
          'target',
          'refreshRuntime',
          'runtimeDownloadId',
          'autoApproveCapabilities',
          'relayServer',
        })) {
      throw const FormatException('安装包导出请求字段不完整或包含未知字段');
    }
    final targetId = body['target'];
    final refreshRuntime = body['refreshRuntime'];
    final runtimeDownloadId = body['runtimeDownloadId'];
    final autoApproveCapabilities = body['autoApproveCapabilities'];
    final rawRelayServer = body['relayServer'];
    if (targetId is! String ||
        !developerInstallationPackageTargetIds.contains(targetId)) {
      throw const FormatException('安装包导出目标无效');
    }
    if (refreshRuntime is! bool) {
      throw const FormatException('refreshRuntime 必须是布尔值');
    }
    if (runtimeDownloadId != null &&
        (runtimeDownloadId is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(runtimeDownloadId))) {
      throw const FormatException('runtimeDownloadId 必须是有效的下载线路 ID 或 null');
    }
    if (autoApproveCapabilities is! bool) {
      throw const FormatException('autoApproveCapabilities 必须是布尔值');
    }
    if (rawRelayServer != null && rawRelayServer is! String) {
      throw const FormatException('relayServer 必须是字符串或 null');
    }
    final relayText = rawRelayServer is String ? rawRelayServer.trim() : '';
    final relayServer = relayText.isEmpty
        ? null
        : parseDeveloperRuntimeRelayServer(relayText);
    final progressRequestId = _installationPackageProgressRequestId(
      request,
      fallback: requestId,
    );
    request.response.headers.set(
      developerInstallationPackageProgressRequestIdHeader,
      progressRequestId,
    );
    final progress =
        _InstallationPackageProgressEvents(
          projectId: projectId,
          requestId: progressRequestId,
          targetId: targetId,
          clock: gateway.clock,
        )..emit(
          const DeveloperInstallationPackageProgress(
            stage: DeveloperInstallationPackageProgressStage.preparing,
          ),
        );

    final service = gateway.installationPackageService;
    if (service == null) {
      progress.failed('package_export_unavailable');
      await _error(
        request.response,
        HttpStatus.serviceUnavailable,
        requestId,
        'package_export_unavailable',
        '当前 App 尚未接入安装包导出服务',
      );
      return;
    }
    try {
      final validation = await gateway.catalog.validateProject(projectId);
      if (!validation.valid) {
        progress.failed('package_validation_failed');
        await _json(request.response, HttpStatus.unprocessableEntity, {
          'requestId': requestId,
          'progressRequestId': progressRequestId,
          'error': {
            'code': 'package_validation_failed',
            'message': '项目完整校验未通过，未生成安装包',
          },
          'validation': validation.toJson(),
        });
        return;
      }
      final game = await gateway.catalog.prepareGame(projectId);
      final artifact = await service.create(
        game: game,
        targetId: targetId,
        refreshRuntime: refreshRuntime,
        runtimeDownloadId: runtimeDownloadId as String?,
        autoApproveCapabilities: autoApproveCapabilities,
        relayServer: relayServer,
        onProgress: progress.emit,
      );
      progress.completed();
      await _json(request.response, HttpStatus.created, {
        'requestId': requestId,
        'progressRequestId': progressRequestId,
        'projectId': projectId,
        ...artifact.toJson(),
        'downloadPath':
            '/dev/api/projects/$projectId/$_collectionSuffix/${artifact.id}',
      });
    } on DeveloperInstallationPackageException catch (error) {
      progress.failed(error.code);
      await _installationPackageError(request, requestId, error);
    } on Object {
      progress.failed('package_export_failed');
      rethrow;
    }
  }

  Future<void> _download(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String projectId,
    String exportId,
  ) async {
    final artifact = gateway.installationPackageService?.find(exportId);
    if (artifact == null || artifact.projectId != projectId) {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'package_export_not_found',
        '安装包暂存文件不存在或已经释放',
      );
      return;
    }
    final file = File(artifact.filePath);
    if (!await file.exists() || await file.length() != artifact.size) {
      await gateway.installationPackageService?.release(exportId);
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'package_export_not_found',
        '安装包暂存文件不存在或已经释放',
      );
      return;
    }
    request.response.headers
      ..contentType = ContentType.parse(artifact.mimeType)
      ..contentLength = artifact.size
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set(
        'Content-Disposition',
        'attachment; filename*=UTF-8\'\'${Uri.encodeComponent(artifact.filename)}',
      );
    try {
      await file.openRead().pipe(request.response);
    } finally {
      // 浏览器下载没有可靠的后续 DELETE 回调；流结束或中断后
      // 都立即释放单次产物。原生保存层的冗余 DELETE 保持幂等。
      await gateway.installationPackageService?.release(exportId);
    }
  }

  Future<void> _requireProject(
    _IoDeveloperWebGateway gateway,
    String projectId,
  ) async {
    final projects = await gateway.catalog.listProjects();
    if (!projects.any((project) => project.id == projectId)) {
      throw StateError('开发者项目不存在');
    }
  }

  String _validExportId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{20,64}$').hasMatch(value)) {
      throw const FormatException('安装包暂存 ID 无效');
    }
    return value;
  }

  Future<void> _installationPackageError(
    HttpRequest request,
    String requestId,
    DeveloperInstallationPackageException error,
  ) {
    final status = switch (error.kind) {
      DeveloperInstallationPackageFailureKind.targetUnavailable ||
      DeveloperInstallationPackageFailureKind.runtimeDownloadUnavailable =>
        HttpStatus.conflict,
      DeveloperInstallationPackageFailureKind.invalidRuntimePackage =>
        HttpStatus.unprocessableEntity,
      DeveloperInstallationPackageFailureKind.runtimeDownloadFailed =>
        HttpStatus.serviceUnavailable,
      DeveloperInstallationPackageFailureKind.exportFailed =>
        HttpStatus.internalServerError,
    };
    return _error(
      request.response,
      status,
      requestId,
      error.code,
      error.message,
    );
  }
}

String _installationPackageProgressRequestId(
  HttpRequest request, {
  required String fallback,
}) {
  final values =
      request.headers[developerInstallationPackageProgressRequestIdHeader];
  if (values == null || values.isEmpty) return fallback;
  if (values.length != 1 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$').hasMatch(values.single)) {
    throw const FormatException('安装包导出进度 requestId 无效');
  }
  return values.single;
}

final class _InstallationPackageProgressEvents {
  _InstallationPackageProgressEvents({
    required this.projectId,
    required this.requestId,
    required this.targetId,
    required this.clock,
  });

  final String projectId;
  final String requestId;
  final String targetId;
  final DateTime Function() clock;
  var _terminal = false;

  void emit(DeveloperInstallationPackageProgress progress) {
    if (_terminal ||
        progress.stage == DeveloperInstallationPackageProgressStage.completed ||
        progress.stage == DeveloperInstallationPackageProgressStage.failed) {
      return;
    }
    _emit(progress.toJson());
  }

  void completed() {
    if (_terminal) return;
    _terminal = true;
    _emit({
      'stage': DeveloperInstallationPackageProgressStage.completed.wireName,
    });
  }

  void failed(String errorCode) {
    if (_terminal) return;
    _terminal = true;
    final publicErrorCode =
        RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(errorCode)
        ? errorCode
        : 'package_export_failed';
    _emit({
      'stage': DeveloperInstallationPackageProgressStage.failed.wireName,
      'errorCode': publicErrorCode,
    });
  }

  void _emit(Map<String, Object?> payload) {
    try {
      developerEventHub.emit({
        'type': 'package_export.progress',
        'projectId': projectId,
        'requestId': requestId,
        'target': targetId,
        ...payload,
        'timestamp': clock().toUtc().millisecondsSinceEpoch,
      });
    } on Object {
      // SSE 观察者异常不得改变同步导出结果或产生第二个终态。
    }
  }
}
