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
    final files = <String, String>{};
    for (final name in names) {
      final data = await rootBundle.load(
        'assets/playmesh-library/public/sdk/v1/$name',
      );
      files[name] = base64Encode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'gameSdkVersion': generatedGameSdkVersion,
      'appSdkVersion': generatedAppSdkVersion,
      'encoding': 'base64',
      'files': files,
    });
  }
}
