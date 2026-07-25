part of '../../developer_web_gateway_io.dart';

class _FileOperation implements _DeveloperHttpOperation {
  const _FileOperation();

  static const _writeSchema = <String, Object?>{
    'type': 'object',
    'required': ['content'],
    'properties': {
      'content': {'type': 'string'},
      'encoding': {
        'type': 'string',
        'enum': ['utf8', 'base64'],
      },
      'baseRevision': {'type': 'integer', 'minimum': 0},
      'clientId': {'type': 'string'},
    },
  };

  static const _patchSchema = <String, Object?>{
    'type': 'object',
    'required': ['operations', 'baseRevision'],
    'properties': {
      'baseRevision': {'type': 'integer', 'minimum': 1},
      'clientId': {'type': 'string'},
      'operations': {
        'type': 'array',
        'minItems': 1,
        'items': {
          'type': 'object',
          'required': ['start', 'end', 'text'],
          'properties': {
            'start': {'type': 'integer', 'minimum': 0},
            'end': {'type': 'integer', 'minimum': 0},
            'text': {'type': 'string'},
          },
        },
      },
    },
  };

  static const _deleteSchema = <String, Object?>{
    'type': 'object',
    'properties': {
      'baseRevision': {'type': 'integer', 'minimum': 1},
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'files.read',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/file',
      summary: '读取项目文本文件及 revision 响应头',
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      chatBootstrap: true,
    ),
    DeveloperOperationDefinition(
      id: 'files.write',
      method: 'PUT',
      path: '/dev/api/projects/{projectId}/file',
      summary: '创建或完整替换项目文件',
      description: '创建时提交 baseRevision=0；替换现有文件前必须先读取并提交当前 revision。',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      requestBodySchema: _writeSchema,
      requestExample: {
        'content': 'console.log("hello");\n',
        'encoding': 'utf8',
        'baseRevision': 0,
        'clientId': 'chat-console',
      },
      chatBootstrap: true,
    ),
    DeveloperOperationDefinition(
      id: 'files.patch',
      method: 'PATCH',
      path: '/dev/api/projects/{projectId}/file',
      summary: '按 UTF-16 偏移精确替换或插入文本',
      description: '替换使用 start < end；插入使用 start == end。多个操作按数组顺序应用。',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      requestBodySchema: _patchSchema,
      requestExample: {
        'baseRevision': 3,
        'operations': [
          {'start': 10, 'end': 15, 'text': 'replacement'},
          {'start': 30, 'end': 30, 'text': '\ninserted'},
        ],
        'clientId': 'chat-console',
      },
      chatBootstrap: true,
    ),
    DeveloperOperationDefinition(
      id: 'files.delete',
      method: 'DELETE',
      path: '/dev/api/projects/{projectId}/file',
      summary: '删除项目文件',
      permission: 'project.write',
      risk: DeveloperOperationRisk.high,
      idempotent: false,
      dangerous: true,
      parameters: [developerProjectIdParameter, developerPathQueryParameter],
      requestBodySchema: _deleteSchema,
      requestExample: {'baseRevision': 3, 'clientId': 'chat-console'},
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
    final projectId = pathParameters['projectId']!;
    final path = request.uri.queryParameters['path'] ?? '';
    switch (request.method) {
      case 'GET':
        final file = await gateway.catalog.readFile(projectId, path);
        if (!file.isText) throw const FormatException('该接口只读取文本文件');
        request.response.headers
          ..contentType = ContentType.parse(file.contentType)
          ..set('X-Playmesh-Revision', file.revision)
          ..set('X-Playmesh-Readonly', file.readOnly);
        request.response.add(file.bytes);
        await request.response.close();
      case 'PUT':
        final body = await _jsonBody(request);
        final content = body['content'];
        if (content is! String) {
          throw const FormatException('content 必须是字符串');
        }
        DeveloperProjectFile? before;
        try {
          before = await gateway.catalog.readFile(projectId, path);
        } on StateError {
          // PUT 同时承担项目沙箱内的新文件创建。
        }
        final encoding = body['encoding'] as String? ?? 'utf8';
        final bytes = switch (encoding) {
          'utf8' => utf8.encode(content),
          'base64' => base64Decode(content),
          _ => throw const FormatException('encoding 只支持 utf8 或 base64'),
        };
        final saved = await gateway.catalog.writeFile(
          projectId,
          path,
          bytes,
          expectedRevision: body['baseRevision'] as int?,
        );
        final operations = before != null && before.isText && encoding == 'utf8'
            ? _minimalOperations(utf8.decode(before.bytes), content)
            : const <Map<String, Object?>>[];
        _emitDeveloperFileEvent(
          type: 'file.saved',
          projectId: projectId,
          path: path,
          revision: saved.revision,
          clientId: body['clientId'] as String?,
          operations: operations,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ..._fileJson(saved),
        });
      case 'PATCH':
        final body = await _jsonBody(request);
        final current = await gateway.catalog.readFile(projectId, path);
        if (!current.isText) {
          throw const FormatException('仅文本文件支持范围编辑');
        }
        final rawOperations = body['operations'];
        if (rawOperations is! List || rawOperations.isEmpty) {
          throw const FormatException('operations 必须是非空数组');
        }
        var content = utf8.decode(current.bytes);
        final operations = <Map<String, Object?>>[];
        for (final raw in rawOperations) {
          if (raw is! Map) throw const FormatException('编辑操作格式无效');
          final operation = Map<String, Object?>.from(raw);
          final start = operation['start'];
          final end = operation['end'];
          final text = operation['text'];
          if (start is! int ||
              end is! int ||
              text is! String ||
              start < 0 ||
              end < start ||
              end > content.length) {
            throw const FormatException('编辑范围无效');
          }
          content = content.replaceRange(start, end, text);
          operations.add({'start': start, 'end': end, 'text': text});
        }
        final saved = await gateway.catalog.writeFile(
          projectId,
          path,
          utf8.encode(content),
          expectedRevision: body['baseRevision'] as int?,
        );
        _emitDeveloperFileEvent(
          type: 'file.patched',
          projectId: projectId,
          path: path,
          revision: saved.revision,
          clientId: body['clientId'] as String?,
          operations: operations,
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ..._fileJson(saved),
        });
      case 'DELETE':
        final body = await _optionalJsonBody(request);
        await gateway.catalog.deleteFile(
          projectId,
          path,
          expectedRevision: body['baseRevision'] as int?,
        );
        final revision = (body['baseRevision'] as int? ?? 0) + 1;
        _emitDeveloperFileEvent(
          type: 'file.deleted',
          projectId: projectId,
          path: path,
          revision: revision,
          clientId: body['clientId'] as String?,
          operations: const [],
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'projectId': projectId,
          'path': path,
          'deleted': true,
          'revision': revision,
        });
    }
  }
}
