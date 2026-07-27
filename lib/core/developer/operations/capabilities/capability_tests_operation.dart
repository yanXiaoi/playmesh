part of '../../developer_web_gateway_io.dart';

class _CapabilityTestsOperation implements _DeveloperHttpOperation {
  const _CapabilityTestsOperation();

  static const _createInstanceSchema = <String, Object?>{
    'type': 'object',
    'required': ['code'],
    'properties': {
      'code': {'type': 'string', 'minLength': 1},
      'options': {'type': 'object'},
    },
    'additionalProperties': false,
  };
  static const _invokeInstanceSchema = <String, Object?>{
    'type': 'object',
    'required': ['method'],
    'properties': {
      'method': {'type': 'string', 'minLength': 1},
      'arguments': {'type': 'object'},
    },
    'additionalProperties': false,
  };
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
    DeveloperOperationDefinition(
      id: 'capability_tests.instances.create',
      method: 'POST',
      path: '/dev/api/capability-tests/instances',
      summary: '按能力定义创建一个交互式测试实例',
      permission: 'capability.test',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      requiresForegroundView: true,
      requestBodySchema: _createInstanceSchema,
      requestExample: {'code': 'capability.code', 'options': {}},
      successStatus: 201,
    ),
    DeveloperOperationDefinition(
      id: 'capability_tests.instances.invoke',
      method: 'POST',
      path: '/dev/api/capability-tests/instances/{instanceId}/invoke',
      summary: '调用交互式能力测试实例中已声明的方法',
      permission: 'capability.test',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      requiresForegroundView: true,
      parameters: [
        DeveloperOperationParameter(
          name: 'instanceId',
          location: DeveloperOperationParameterLocation.path,
          description: '能力测试实例 ID',
          required: true,
        ),
      ],
      requestBodySchema: _invokeInstanceSchema,
      requestExample: {'method': 'methodName', 'arguments': {}},
    ),
    DeveloperOperationDefinition(
      id: 'capability_tests.instances.dispose',
      method: 'DELETE',
      path: '/dev/api/capability-tests/instances/{instanceId}',
      summary: '释放一个交互式能力测试实例',
      permission: 'capability.test',
      risk: DeveloperOperationRisk.medium,
      parameters: [
        DeveloperOperationParameter(
          name: 'instanceId',
          location: DeveloperOperationParameterLocation.path,
          description: '能力测试实例 ID',
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
    switch (definition.id) {
      case 'capability_tests.list':
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'capabilities': gateway.capabilityTests.describe(),
        });
        return;
      case 'capability_tests.run':
        await _runTests(gateway, request, requestId);
        return;
      case 'capability_tests.instances.create':
        final body = await _optionalJsonBody(request);
        if (body.keys.any((key) => key != 'code' && key != 'options')) {
          throw const FormatException('创建能力测试实例包含未知字段');
        }
        final code = body['code'];
        final rawOptions = body['options'];
        if (code is! String || code.isEmpty) {
          throw const FormatException('code 必须是非空字符串');
        }
        if (rawOptions != null && rawOptions is! Map) {
          throw const FormatException('options 必须是对象');
        }
        final options = rawOptions == null
            ? const <String, Object?>{}
            : Map<String, Object?>.from(rawOptions as Map);
        final result = await gateway.capabilityTests.createInstance(
          code: code,
          options: options,
        );
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          ...result,
        });
        return;
      case 'capability_tests.instances.invoke':
        final instanceId = pathParameters['instanceId']!;
        final body = await _optionalJsonBody(request);
        if (body.keys.any((key) => key != 'method' && key != 'arguments')) {
          throw const FormatException('调用能力测试方法包含未知字段');
        }
        final method = body['method'];
        final rawArguments = body['arguments'];
        if (method is! String || method.isEmpty) {
          throw const FormatException('method 必须是非空字符串');
        }
        if (rawArguments != null && rawArguments is! Map) {
          throw const FormatException('arguments 必须是对象');
        }
        final arguments = rawArguments == null
            ? const <String, Object?>{}
            : Map<String, Object?>.from(rawArguments as Map);
        final result = await gateway.capabilityTests.invokeInstance(
          instanceId: instanceId,
          method: method,
          arguments: arguments,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...result,
        });
        return;
      case 'capability_tests.instances.dispose':
        final result = await gateway.capabilityTests.disposeInstance(
          pathParameters['instanceId']!,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...result,
        });
        return;
    }
    throw StateError('未注册能力测试操作：${definition.id}');
  }

  Future<void> _runTests(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
  ) async {
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
