part of '../../developer_web_gateway_io.dart';

class _CapabilityTestsOperation implements _DeveloperHttpOperation {
  const _CapabilityTestsOperation();

  static const _runSchema = <String, Object?>{
    'type': 'object',
    'properties': {
      'codes': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'timeoutMs': {'type': 'integer', 'minimum': 250, 'maximum': 10000},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'capability_tests.list',
      method: 'GET',
      path: '/dev/api/capability-tests',
      summary: '读取平台注册表驱动的能力自检清单',
    ),
    DeveloperOperationDefinition(
      id: 'capability_tests.run',
      method: 'POST',
      path: '/dev/api/capability-tests',
      summary: '测试全部或指定平台能力',
      permission: 'capability.test',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      requestBodySchema: _runSchema,
      requestExample: {
        'codes': ['device.vibration'],
        'timeoutMs': 3000,
      },
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
    if (request.method == 'GET') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'capabilities': gateway.capabilityTests.describe(),
      });
      return;
    }
    final body = await _optionalJsonBody(request);
    final rawCodes = body['codes'];
    final List<Object?>? codeItems;
    if (rawCodes == null) {
      codeItems = null;
    } else if (rawCodes is List) {
      codeItems = rawCodes.cast<Object?>();
    } else {
      throw const FormatException('codes 必须是字符串数组');
    }
    final codes = codeItems
        ?.map((item) {
          if (item is! String || item.isEmpty) {
            throw const FormatException('codes 必须是非空字符串数组');
          }
          return item;
        })
        .toList(growable: false);
    final timeoutMs = body['timeoutMs'] ?? 3000;
    if (timeoutMs is! int || timeoutMs < 250 || timeoutMs > 10000) {
      throw const FormatException('timeoutMs 必须是 250 到 10000 的整数');
    }
    final results = await gateway.capabilityTests.run(
      codes: codes,
      timeout: Duration(milliseconds: timeoutMs),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'testedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
      'results': results,
      'passed': results.where((item) => item['status'] == 'passed').length,
      'total': results.length,
    });
  }
}
