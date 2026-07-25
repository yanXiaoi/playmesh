part of '../../developer_web_gateway_io.dart';

class _PackageImportOperation implements _DeveloperHttpOperation {
  const _PackageImportOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'packages.import',
      method: 'POST',
      path: '/dev/api/packages/import',
      summary: '导入或更新标准 Playmesh 游戏包并保留 data/cache',
      description: '请求体是 application/zip 原始字节，不是 JSON；主要供 Developer CLI 使用。',
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
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in request) {
      length += chunk.length;
      if (length > GamePackageTransferService.maxCompressedBytes) {
        throw const FormatException('游戏包压缩文件不能超过 64 MiB');
      }
      builder.add(chunk);
    }
    if (length == 0) throw const FormatException('上传的游戏包不能为空');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-developer-import.playmesh.zip',
    );
    try {
      if (await file.exists()) await file.delete();
      await file.writeAsBytes(builder.takeBytes(), flush: true);
      final game = await gateway.catalog.publishPackage(
        file,
        author: gateway._requireCurrentAuthor(),
        lastModifiedAt: gateway.clock().toUtc(),
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
        'preservedDirectories': ['data', 'cache'],
      });
    } finally {
      if (await file.exists()) await file.delete();
    }
  });
}
