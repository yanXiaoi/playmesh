part of '../../developer_web_gateway_io.dart';

class _QrOperation implements _DeveloperHttpOperation {
  const _QrOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'workspace.qr',
      method: 'GET',
      path: '/dev/api/qr.svg',
      summary: '生成指定链接的二维码 SVG',
      chatEnabled: false,
      parameters: [
        DeveloperOperationParameter(
          name: 'value',
          location: DeveloperOperationParameterLocation.query,
          description: '需要编码的非空 URL 或文本',
          required: true,
        ),
      ],
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
    final value = request.uri.queryParameters['value'] ?? '';
    if (value.isEmpty) throw const FormatException('二维码内容不能为空');
    await _text(
      request.response,
      _createQrSvg(value),
      'image/svg+xml; charset=utf-8',
    );
  }

  String _createQrSvg(String value) {
    final code = QrCode.fromData(
      data: value,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final image = QrImage(code);
    const quiet = 4;
    final size = image.moduleCount + quiet * 2;
    final buffer = StringBuffer(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" '
      'shape-rendering="crispEdges"><rect width="100%" height="100%" fill="white"/>',
    );
    for (var row = 0; row < image.moduleCount; row += 1) {
      for (var column = 0; column < image.moduleCount; column += 1) {
        if (image.isDark(row, column)) {
          buffer.write(
            '<rect x="${column + quiet}" y="${row + quiet}" '
            'width="1" height="1" fill="#111"/>',
          );
        }
      }
    }
    return '${buffer.toString()}</svg>';
  }
}
