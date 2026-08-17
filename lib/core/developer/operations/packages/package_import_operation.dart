part of '../../developer_web_gateway_io.dart';

class _PackageImportOperation implements _DeveloperHttpOperation {
  const _PackageImportOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'packages.import',
      method: 'POST',
      path: '/dev/api/packages/import',
      summary: '导入或更新标准 Playmesh 游戏包并保留平台目录',
      description: '请求体是 application/zip 原始字节，不是 JSON；支持定长或 HTTP chunked 流式上传。',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      chatEnabled: false,
    ),
  ];

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) => gateway._serializePackageFile(() async {
    TemporaryPackageUpload? upload;
    try {
      try {
        upload =
            await PackageUploadSpooler(
              maxBytes: GamePackageTransferService.maxCompressedBytes,
            ).spool(
              request,
              declaredLength: request.contentLength < 0
                  ? null
                  : request.contentLength,
            );
      } on PackageUploadTooLarge catch (error) {
        throw _DeveloperRequestTooLarge(error.limit);
      } on PackageUploadEmpty {
        throw const FormatException('上传的游戏包不能为空');
      }
      final author = gateway._requireCurrentAuthor();
      final lastModifiedAt = gateway.clock().toUtc();
      final validated = await gateway.packageTransfer.readPackage(
        upload.file,
        author: author,
        lastModifiedAt: lastModifiedAt,
      );
      final game = await gateway.gdevelopProjectRekey.runIdentityMutation(
        validated.manifest.id,
        () => gateway.catalog.publishPackage(
          upload!.file,
          author: author,
          lastModifiedAt: lastModifiedAt,
        ),
      );
      developerEventHub.emit({
        'type': 'project.imported',
        'projectId': game.id,
        'version': game.version,
        'clientId': request.headers.value('X-Playmesh-Client-ID') ?? 'cli',
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'project': {'id': game.id, 'name': game.name, 'version': game.version},
        'committed': true,
        'preservedDirectories': ['data', 'cache', '.playmesh'],
      });
    } finally {
      await upload?.dispose();
    }
  });
}
