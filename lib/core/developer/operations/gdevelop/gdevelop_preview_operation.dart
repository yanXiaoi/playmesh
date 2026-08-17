part of '../../developer_web_gateway_io.dart';

class _GDevelopPreviewOperation implements _DeveloperHttpOperation {
  const _GDevelopPreviewOperation();

  static const _path = '/dev/api/gdevelop/projects/{gameId}/preview';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.preview.start',
      method: 'POST',
      path: _path,
      summary: '暂存标准 Playmesh ZIP 并通过 App 真实运行链启动预览',
      description:
          '接受固定长度 Blob 或 unknown-length chunked body；不安装、不写入 Catalog。'
          '包必须包含 main.json 与 app/**，且 manifest.id 必须等于 gameId。',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      successStatus: 202,
      parameters: [developerGameIdParameter],
      additionalResponses: {
        408: '本机预览传输空闲超时',
        413: '压缩包超过标准 Playmesh package 上限',
        422: '标准 package 校验失败',
      },
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'runtime.preview.start',
      method: 'POST',
      path: '/dev/api/projects/{gameId}/preview',
      summary: '上传并校验临时 app 包，通过 App 真实运行链启动预览',
      description: '不安装、不写入 Catalog，临时包是本次开发运行的唯一资源源。',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      successStatus: 202,
      parameters: [developerGameIdParameter],
      additionalResponses: {
        408: '本机预览传输空闲超时',
        413: '临时 Playmesh package 超过上限',
        422: '临时 package 校验失败',
      },
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.preview.status',
      method: 'GET',
      path: _path,
      summary: '读取当前 GDevelop 临时预览及真实运行状态',
      permission: 'runtime.run',
      parameters: [developerGameIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.preview.stop',
      method: 'DELETE',
      path: '$_path/{previewId}',
      summary: '停止匹配 generation 的 GDevelop 临时预览',
      permission: 'runtime.run',
      risk: DeveloperOperationRisk.medium,
      idempotent: true,
      parameters: [
        developerGameIdParameter,
        DeveloperOperationParameter(
          name: 'previewId',
          location: DeveloperOperationParameterLocation.path,
          description: 'POST 返回的不可变 previewId',
          required: true,
        ),
      ],
      additionalResponses: {409: 'previewId 已被新 generation 取代'},
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
    final gameId = pathParameters['gameId']!;
    switch (definition.id) {
      case 'gdevelop.preview.start':
      case 'runtime.preview.start':
        final mime = request.headers.contentType?.mimeType;
        if (mime != 'application/zip' &&
            mime != 'application/x-zip-compressed' &&
            mime != 'application/octet-stream') {
          throw const FormatException('GDevelop preview body 必须是 ZIP');
        }
        try {
          final surfaceName = request.uri.queryParameters['surface'];
          final surface = surfaceName == 'embedded'
              ? DeveloperPreviewSurface.embedded
              : DeveloperPreviewSurface.app;
          if (surfaceName != null &&
              surfaceName != 'app' &&
              surfaceName != 'embedded') {
            throw const FormatException('GDevelop preview surface 无效');
          }
          if (definition.id == 'runtime.preview.start' &&
              surface != DeveloperPreviewSurface.app) {
            throw const FormatException('通用开发预览不支持 embedded surface');
          }
          final result = await gateway.gdevelopRestoreTransactions
              .runProjectAllocation(
                gameId,
                () => gateway.previewService.start(
                  gameId: gameId,
                  archive: request,
                  declaredLength: request.contentLength < 0
                      ? null
                      : request.contentLength,
                  surface: surface,
                  embeddedLinkBuilder:
                      surface == DeveloperPreviewSurface.embedded
                      ? (previewId) => request.requestedUri.replace(
                          path:
                              '${gateway.session.gdevelopWorkspacePath!}'
                              'embedded-preview/$gameId/$previewId/index.html',
                          query: '',
                          fragment: null,
                        )
                      : null,
                ),
              );
          await _json(request.response, HttpStatus.accepted, result.toJson());
        } on PackageUploadTooLarge catch (error) {
          throw _DeveloperRequestTooLarge(error.limit);
        } on PackageUploadEmpty {
          throw const FormatException('GDevelop preview ZIP 不能为空');
        }
      case 'gdevelop.preview.status':
        final result = await gateway.previewService.status(gameId);
        await _json(request.response, HttpStatus.ok, result.toJson());
      case 'gdevelop.preview.stop':
        final result = await gateway.gdevelopRestoreTransactions
            .runProjectAllocation(
              gameId,
              () => gateway.previewService.stop(
                gameId: gameId,
                previewId: pathParameters['previewId']!,
              ),
            );
        await _json(request.response, HttpStatus.ok, result.toJson());
    }
  }
}
