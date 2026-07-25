part of '../../developer_web_gateway_io.dart';

class _FileChangesOperation implements _DeveloperHttpOperation {
  const _FileChangesOperation();

  static const _changeSchema = <String, Object?>{
    'type': 'object',
    'required': ['type', 'path'],
    'properties': {
      'type': {
        'type': 'string',
        'enum': [
          'create',
          'replace',
          'replace_text',
          'insert_before',
          'insert_after',
        ],
      },
      'path': {'type': 'string'},
      'content': {'type': 'string'},
      'oldText': {'type': 'string'},
      'newText': {'type': 'string'},
      'anchor': {'type': 'string'},
      'text': {'type': 'string'},
      'expectedMatches': {'type': 'integer', 'minimum': 1},
    },
  };

  static const _previewSchema = <String, Object?>{
    'type': 'object',
    'required': ['changes'],
    'properties': {
      'changes': {'type': 'array', 'minItems': 1, 'items': _changeSchema},
    },
  };

  static const _applySchema = <String, Object?>{
    'type': 'object',
    'required': ['changes', 'baseRevisions'],
    'properties': {
      'changes': {'type': 'array', 'minItems': 1, 'items': _changeSchema},
      'baseRevisions': {
        'type': 'object',
        'additionalProperties': {'type': 'integer', 'minimum': 0},
      },
      'clientId': {'type': 'string'},
    },
  };

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'file_changes.preview',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/file-changes/preview',
      summary: '预览批量创建、替换、锚点替换和锚点插入',
      description: '返回原文、结果和 baseRevisions，不写入工作区。',
      parameters: [developerProjectIdParameter],
      requestBodySchema: _previewSchema,
      requestExample: {
        'changes': [
          {
            'type': 'replace_text',
            'path': 'app/game.js',
            'oldText': 'const speed = 1;',
            'newText': 'const speed = 2;',
            'expectedMatches': 1,
          },
        ],
      },
      chatBootstrap: true,
    ),
    DeveloperOperationDefinition(
      id: 'file_changes.apply',
      method: 'POST',
      path: '/dev/api/projects/{projectId}/file-changes/apply',
      summary: '按预览 revision 原子应用批量文件修改',
      permission: 'project.write',
      risk: DeveloperOperationRisk.medium,
      idempotent: false,
      parameters: [developerProjectIdParameter],
      requestBodySchema: _applySchema,
      requestExample: {
        'changes': [
          {
            'type': 'insert_after',
            'path': 'app/game.js',
            'anchor': 'const game = createGame();',
            'text': '\ngame.start();',
            'expectedMatches': 1,
          },
        ],
        'baseRevisions': {'app/game.js': 3},
        'clientId': 'chat-console',
      },
      chatBootstrap: true,
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
    final body = await _jsonBody(request);
    final preview = await _buildPreview(gateway, projectId, body['changes']);
    if (definition.id == 'file_changes.preview') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        ...preview.toJson(),
      });
      return;
    }
    final rawRevisions = body['baseRevisions'];
    if (rawRevisions is! Map) {
      throw const FormatException('应用前必须预览并提交 baseRevisions');
    }
    final expectedRevisions = <String, int>{};
    for (final entry in rawRevisions.entries) {
      if (entry.key is! String || entry.value is! int) {
        throw const FormatException('baseRevisions 格式无效');
      }
      expectedRevisions[entry.key as String] = entry.value as int;
    }
    if (expectedRevisions.length != preview.files.length ||
        preview.files.any(
          (file) => expectedRevisions[file.path] != file.revision,
        )) {
      throw const FormatException('baseRevisions 必须与当前预览结果完全一致');
    }
    final changed = {
      for (final file in preview.files)
        if (file.original != file.current) file.path: utf8.encode(file.current),
    };
    if (changed.isEmpty) throw const FormatException('文件修改没有产生差异');
    final saved = await gateway.catalog.writeFilesAtomic(
      projectId,
      changed,
      expectedRevisions: expectedRevisions,
    );
    final clientId = body['clientId'] as String?;
    for (final file in saved) {
      final before = preview.files.firstWhere((item) => item.path == file.path);
      _emitDeveloperFileEvent(
        type: 'file.batch',
        projectId: projectId,
        path: file.path,
        revision: file.revision,
        clientId: clientId,
        operations: _minimalOperations(before.original, before.current),
      );
    }
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'applied': saved.map(_fileJson).toList(),
    });
  }

  Future<_FileChangesPreview> _buildPreview(
    _IoDeveloperWebGateway gateway,
    String projectId,
    Object? rawChanges,
  ) async {
    if (rawChanges is! List || rawChanges.isEmpty) {
      throw const FormatException('changes 必须是非空数组');
    }
    final available = (await gateway.catalog.listFiles(projectId)).toSet();
    final working = <String, String>{};
    final originals = <String, String>{};
    final revisions = <String, int>{};
    final created = <String>{};

    Future<void> load(String path, {required bool mustExist}) async {
      if (working.containsKey(path)) return;
      if (!available.contains(path)) {
        if (mustExist) throw FormatException('文件不存在：$path');
        working[path] = '';
        originals[path] = '';
        revisions[path] = 0;
        return;
      }
      final file = await gateway.catalog.readFile(projectId, path);
      if (!file.isText) throw FormatException('仅文本文件支持批量修改：$path');
      final content = utf8.decode(file.bytes);
      working[path] = content;
      originals[path] = content;
      revisions[path] = file.revision;
    }

    for (final raw in rawChanges) {
      if (raw is! Map) throw const FormatException('change 必须是对象');
      final change = Map<String, Object?>.from(raw);
      final type = change['type'];
      final path = change['path'];
      if (type is! String || path is! String || path.isEmpty) {
        throw const FormatException('change.type 和 change.path 必须是非空字符串');
      }
      final exists = available.contains(path) || created.contains(path);
      switch (type) {
        case 'create':
          if (exists) throw FormatException('文件已存在：$path');
          final content = change['content'];
          if (content is! String) {
            throw const FormatException('create.content 必须是字符串');
          }
          await load(path, mustExist: false);
          working[path] = content;
          created.add(path);
        case 'replace':
          if (!exists) throw FormatException('文件不存在：$path');
          final content = change['content'];
          if (content is! String) {
            throw const FormatException('replace.content 必须是字符串');
          }
          await load(path, mustExist: true);
          working[path] = content;
        case 'replace_text':
          await load(path, mustExist: true);
          final oldText = change['oldText'];
          final newText = change['newText'];
          if (oldText is! String || oldText.isEmpty || newText is! String) {
            throw const FormatException(
              'replace_text.oldText 必须是非空字符串，newText 必须是字符串',
            );
          }
          working[path] = _replaceExpected(
            working[path]!,
            oldText,
            newText,
            _expectedMatches(change),
            path,
          );
        case 'insert_before':
        case 'insert_after':
          await load(path, mustExist: true);
          final anchor = change['anchor'];
          final text = change['text'];
          if (anchor is! String || anchor.isEmpty || text is! String) {
            throw const FormatException('插入操作的 anchor 必须是非空字符串，text 必须是字符串');
          }
          final replacement = type == 'insert_before'
              ? '$text$anchor'
              : '$anchor$text';
          working[path] = _replaceExpected(
            working[path]!,
            anchor,
            replacement,
            _expectedMatches(change),
            path,
          );
        default:
          throw FormatException('不支持的文件修改类型：$type');
      }
    }
    return _FileChangesPreview([
      for (final entry in working.entries)
        _FileChangesPreviewFile(
          path: entry.key,
          original: originals[entry.key]!,
          current: entry.value,
          revision: revisions[entry.key]!,
          created: created.contains(entry.key),
        ),
    ]);
  }

  int _expectedMatches(Map<String, Object?> change) {
    final value = change['expectedMatches'] ?? 1;
    if (value is! int || value < 1) {
      throw const FormatException('expectedMatches 必须是大于 0 的整数');
    }
    return value;
  }

  String _replaceExpected(
    String source,
    String target,
    String replacement,
    int expectedMatches,
    String path,
  ) {
    final matches = target.allMatches(source).length;
    if (matches != expectedMatches) {
      throw FormatException('$path 中目标文本匹配 $matches 次，预期 $expectedMatches 次');
    }
    return source.replaceAll(target, replacement);
  }
}

class _FileChangesPreviewFile {
  const _FileChangesPreviewFile({
    required this.path,
    required this.original,
    required this.current,
    required this.revision,
    required this.created,
  });

  final String path;
  final String original;
  final String current;
  final int revision;
  final bool created;

  Map<String, Object?> toJson() => {
    'path': path,
    'original': original,
    'current': current,
    'revision': revision,
    'created': created,
  };
}

class _FileChangesPreview {
  const _FileChangesPreview(this.files);

  final List<_FileChangesPreviewFile> files;

  Map<String, Object?> toJson() => {
    'files': files.map((file) => file.toJson()).toList(),
    'baseRevisions': {for (final file in files) file.path: file.revision},
  };
}
