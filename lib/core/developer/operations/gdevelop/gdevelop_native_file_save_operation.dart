part of '../../developer_web_gateway_io.dart';

class _GDevelopNativeFileSaveOperation implements _DeveloperHttpOperation {
  const _GDevelopNativeFileSaveOperation();

  static const _collectionPath = '/dev/api/gdevelop/native-file-saves';

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.native_file_save.stage',
      method: 'POST',
      path: _collectionPath,
      summary: '将 WebView Blob 流式暂存给 App 系统保存通道',
      description: '仅供 App 注入的原生保存桥使用；归档字节不经过 JSON 或 base64。',
      permission: 'project.export',
      risk: DeveloperOperationRisk.low,
      idempotent: false,
      successStatus: 201,
      additionalResponses: {413: 'Blob 超过标准 Playmesh package 上限'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.native_file_save.download',
      method: 'GET',
      path: '$_collectionPath/{transferId}',
      summary: '由 App 宿主流式读取已暂存的 WebView Blob',
      permission: 'project.export',
      parameters: [_transferIdParameter],
      additionalResponses: {404: '暂存文件不存在或已经释放'},
      chatEnabled: false,
      agentEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'gdevelop.native_file_save.release',
      method: 'DELETE',
      path: '$_collectionPath/{transferId}',
      summary: '释放 App 原生保存通道的暂存文件',
      permission: 'project.export',
      parameters: [_transferIdParameter],
      chatEnabled: false,
      agentEnabled: false,
    ),
  ];

  static const _transferIdParameter = DeveloperOperationParameter(
    name: 'transferId',
    location: DeveloperOperationParameterLocation.path,
    description: 'POST 返回的随机暂存 ID',
    required: true,
  );

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) async {
    switch (definition.id) {
      case 'gdevelop.native_file_save.stage':
        await _stage(gateway, request, requestId);
      case 'gdevelop.native_file_save.download':
        await _download(
          gateway,
          request,
          requestId,
          pathParameters['transferId']!,
        );
      case 'gdevelop.native_file_save.release':
        await gateway.gdevelopNativeFileSaves.remove(
          pathParameters['transferId']!,
        );
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
    }
  }

  Future<void> _stage(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
  ) async {
    final encodedFilename =
        request.headers.value('X-Playmesh-Filename')?.trim() ?? '';
    if (encodedFilename.isEmpty || encodedFilename.length > 1024) {
      throw const FormatException('原生保存文件名缺失或过长');
    }
    final filename = Uri.decodeComponent(encodedFilename);
    try {
      final transfer = await gateway.gdevelopNativeFileSaves.create(
        input: request,
        declaredLength: request.contentLength < 0
            ? null
            : request.contentLength,
        requestedFilename: filename,
        mimeType:
            request.headers.contentType?.mimeType ?? 'application/octet-stream',
      );
      await _json(request.response, HttpStatus.created, {
        'requestId': requestId,
        'protocolVersion': 1,
        'transferId': transfer.id,
        'downloadPath': '$_collectionPath/${transfer.id}',
        'filename': transfer.filename,
        'mimeType': transfer.mimeType,
        'size': transfer.length,
      });
    } on PackageUploadTooLarge catch (error) {
      throw _DeveloperRequestTooLarge(error.limit);
    } on PackageUploadEmpty {
      throw const FormatException('原生保存 Blob 不能为空');
    }
  }

  Future<void> _download(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    String transferId,
  ) async {
    final transfer = gateway.gdevelopNativeFileSaves.find(transferId);
    if (transfer == null) {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'native_file_save_not_found',
        '原生保存暂存文件不存在或已经释放',
      );
      return;
    }
    request.response.headers
      ..contentType = ContentType.parse(transfer.mimeType)
      ..contentLength = transfer.length
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set(
        'Content-Disposition',
        'attachment; filename*=UTF-8\'\'${Uri.encodeComponent(transfer.filename)}',
      );
    await transfer.file.openRead().pipe(request.response);
  }
}
