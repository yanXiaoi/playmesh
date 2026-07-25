part of '../../developer_web_gateway_io.dart';

class _SdkBundleOperation implements _DeveloperHttpOperation {
  const _SdkBundleOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'sdk.read_bundle',
      method: 'GET',
      path: '/dev/api/sdk',
      summary: '读取统一生成的 SDK 运行文件和 TypeScript 类型声明',
      permission: 'sdk.read',
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
  ) async {
    const names = [
      'playmesh.js',
      'playmesh-app.js',
      'playmesh.d.ts',
      'playmesh-app.d.ts',
    ];
    final files = <String, String>{
      for (final name in names)
        name: base64Encode(utf8.encode(SdkFeatureRegistry.sdkFile(name))),
    };
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'gameSdkVersion': SdkFeatureRegistry.gameSdkVersion,
      'appSdkVersion': SdkFeatureRegistry.appSdkVersion,
      'gameSdkCompatibility': SdkFeatureRegistry.gameSdkReleases
          .map((release) => release.toJson())
          .toList(),
      'appSdkCompatibility': SdkFeatureRegistry.appSdkReleases
          .map((release) => release.toJson())
          .toList(),
      'encoding': 'base64',
      'files': files,
    });
  }
}
