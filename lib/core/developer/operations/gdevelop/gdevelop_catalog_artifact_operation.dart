part of '../../developer_web_gateway_io.dart';

class _GDevelopCatalogArtifactOperation implements _DeveloperHttpOperation {
  const _GDevelopCatalogArtifactOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'gdevelop.catalog.artifact.acquire',
      method: 'POST',
      path: '/dev/api/gdevelop/catalog/artifact',
      summary: '按本地固定目录清单获取官方示例或扩展正文',
      description:
          '仅接受固定官方 repository/commit/path/SHA-256/size；'
          '正文经 App 下载并写入 CAS/LKG，列表和搜索不调用此接口。',
      permission: 'network.catalog.download',
      risk: DeveloperOperationRisk.low,
      idempotent: true,
      additionalResponses: {
        413: 'artifact 请求或正文超过限制',
        422: 'artifact 不匹配本地固定目录策略',
        503: '官方源或可选代理暂时不可达',
      },
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
    final body = await _jsonBodyWithLimit(request, 32 * 1024);
    final artifact = GDevelopCatalogArtifactRequest.fromJson(body);
    GDevelopCatalogArtifactResult result;
    try {
      result = await gateway.gdevelopCatalogArtifacts.acquire(artifact);
    } on GDevelopCatalogArtifactException catch (error) {
      await _error(
        request.response,
        error.retryable
            ? HttpStatus.serviceUnavailable
            : HttpStatus.unprocessableEntity,
        requestId,
        error.code,
        error.message,
      );
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers
      ..contentType = ContentType.parse(result.mediaType)
      ..contentLength = result.size
      ..set('X-Playmesh-Content-SHA256', result.sha256)
      ..set('X-Playmesh-Catalog-Cache', result.cacheHit ? 'hit' : 'miss')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    await request.response.addStream(result.file.openRead());
    await request.response.close();
  }
}
