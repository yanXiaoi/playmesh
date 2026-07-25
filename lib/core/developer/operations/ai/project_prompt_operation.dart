part of '../../developer_web_gateway_io.dart';

class _ProjectPromptOperation implements _DeveloperHttpOperation {
  const _ProjectPromptOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'prompts.project.chat',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/chat-prompt.txt',
      summary: '导出包含对话控制台基础指令的项目对话提示词',
      parameters: [developerProjectIdParameter],
      chatEnabled: false,
    ),
    DeveloperOperationDefinition(
      id: 'prompts.project.agent',
      method: 'GET',
      path: '/dev/api/projects/{projectId}/agent-prompt.txt',
      summary: '导出包含统一 Developer API 操作目录的 Agent 提示词',
      parameters: [
        developerProjectIdParameter,
        DeveloperOperationParameter(
          name: 'baseUrl',
          location: DeveloperOperationParameterLocation.query,
          description: '当前设备状态接口枚举出的可访问 Base URL',
        ),
      ],
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
  ) => _serveProjectPrompt(
    gateway,
    request,
    pathParameters['projectId']!,
    isAgent: definition.id == 'prompts.project.agent',
  );

  Future<void> _serveProjectPrompt(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String projectId, {
    required bool isAgent,
  }) async {
    final manifestFile = await gateway.catalog.readFile(projectId, 'main.json');
    final decodedManifest = jsonDecode(utf8.decode(manifestFile.bytes));
    if (decodedManifest is! Map) {
      throw const FormatException('main.json 必须是对象');
    }
    final manifest = Map<String, Object?>.from(decodedManifest);
    final modes = _stringValues(manifest['modes']);
    final displayModes = _stringValues(manifest['displayModes']);
    if (modes.length != 1 || displayModes.length != 1) {
      throw const FormatException('main.json modes 和 displayModes 必须且只能各声明一个值');
    }
    final isSolo = modes.single == 'solo';
    final isMultiplayer = modes.single == 'multiplayer';
    final isMultiScreen = displayModes.single == 'multi_screen';
    final isSingleScreen = displayModes.single == 'single_screen_multiplayer';
    if (!isSolo && !isMultiplayer) {
      throw const FormatException('main.json 未声明支持的游戏模式');
    }
    if (isMultiplayer && !isMultiScreen && !isSingleScreen) {
      throw const FormatException('联机游戏未声明支持的显示模式');
    }
    final entries = manifest['entries'];
    final gameEntry = entries is Map && entries['game'] is String
        ? (entries['game'] as String).trim()
        : 'app/index.html';
    final controllerEntry = entries is Map && entries['controller'] is String
        ? (entries['controller'] as String).trim()
        : 'app/controller/index.html';
    final authority = manifest['authority'];
    final authorityEntry = authority is Map && authority['entry'] is String
        ? (authority['entry'] as String).trim()
        : null;
    if (isMultiplayer && (authorityEntry == null || authorityEntry.isEmpty)) {
      throw const FormatException('联机游戏 main.json 缺少 authority.entry');
    }

    final projectFiles = await gateway.catalog.listFiles(projectId);
    var requiredCapabilities = const <String>[];
    var controllerCapabilities = const <String>[];
    if (projectFiles.contains('capabilities.json')) {
      final raw = jsonDecode(
        utf8.decode(
          (await gateway.catalog.readFile(
            projectId,
            'capabilities.json',
          )).bytes,
        ),
      );
      if (raw is! Map) {
        throw const FormatException('capabilities.json 必须是对象');
      }
      final capabilities = GameCapabilities.fromJson(
        Map<String, Object?>.from(raw),
      );
      requiredCapabilities = capabilities.required.toList()..sort();
      controllerCapabilities = capabilities.controllerRequired.toList()..sort();
    }

    Future<String> promptTemplate(String id) async =>
        (await gateway.promptTemplates.read(id)).content;
    final promptParts = <String>[
      await promptTemplate(isAgent ? 'agent-common' : 'common'),
      await promptTemplate('custom-ideas'),
      await promptTemplate(isSolo ? 'solo' : 'multiplayer'),
      if (isMultiplayer)
        await promptTemplate(
          isSingleScreen ? 'single-screen-multiplayer' : 'multi-screen',
        ),
    ];
    final gameSdkDeclaration = await rootBundle.loadString(
      'assets/playmesh-library/public/sdk/v1/playmesh.d.ts',
    );
    final appSdkDeclaration = await rootBundle.loadString(
      'assets/playmesh-library/public/sdk/v1/playmesh-app.d.ts',
    );
    final allDirectories = [...await gateway.catalog.listDirectories(projectId)]
      ..sort();
    final allFiles = [...projectFiles]..sort();
    bool relevant(String path) => _isPromptRelevantPath(
      path,
      includeAuthority: isMultiplayer,
      includeController: isMultiplayer && isSingleScreen,
    );
    final directories = allDirectories.where(relevant).toList();
    final files = allFiles.where(relevant).toList();
    final origin = isAgent
        ? await _resolvePromptBaseUrl(gateway, request)
        : Uri(
            scheme: request.requestedUri.scheme,
            host: request.requestedUri.host,
            port: request.requestedUri.port,
          );
    final documentContext = DeveloperOperationDocumentContext(
      projectId: projectId,
      baseUrl: origin,
      token: gateway.token,
      catalogVersion: _DeveloperOperationRegistry.catalogVersion,
    );
    final operationDocument = isAgent
        ? const DeveloperAgentOperationRenderer().render(
            _developerOperationRegistry.definitions,
            documentContext,
          )
        : const DeveloperChatOperationRenderer(
            bootstrapOnly: true,
          ).render(_developerOperationRegistry.definitions, documentContext);

    final output = StringBuffer()
      ..writeln(promptParts.map((part) => part.trim()).join('\n\n'))
      ..writeln()
      ..writeln('============================================================')
      ..writeln('统一 SDK TypeScript 声明（唯一游戏接口事实源）')
      ..writeln('============================================================')
      ..writeln('===== BEGIN SDK DECLARATION: playmesh.d.ts =====')
      ..writeln(gameSdkDeclaration.trim())
      ..writeln('===== END SDK DECLARATION: playmesh.d.ts =====')
      ..writeln()
      ..writeln('===== BEGIN SDK DECLARATION: playmesh-app.d.ts =====')
      ..writeln(appSdkDeclaration.trim())
      ..writeln('===== END SDK DECLARATION: playmesh-app.d.ts =====')
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目')
      ..writeln('============================================================')
      ..writeln('projectId: $projectId')
      ..writeln('modes: ${modes.join(', ')}')
      ..writeln('displayModes: ${displayModes.join(', ')}')
      ..writeln('entries.game: $gameEntry')
      ..writeln('entries.controller: $controllerEntry')
      ..writeln('authority.entry: ${authorityEntry ?? '未声明'}')
      ..writeln(
        'capabilities.required: '
        '${requiredCapabilities.isEmpty ? '未声明' : requiredCapabilities.join(', ')}',
      )
      ..writeln(
        'capabilities.controllerRequired: '
        '${controllerCapabilities.isEmpty ? '未声明' : controllerCapabilities.join(', ')}',
      );

    if (!isAgent) {
      final selectedCodes = {
        ...requiredCapabilities,
        ...controllerCapabilities,
      };
      final selectedDefinitions = gateway.capabilityTests.registry.descriptors
          .where((item) => selectedCodes.contains(item.code))
          .map((item) => item.toJson())
          .toList(growable: false);
      output
        ..writeln()
        ..writeln('当前项目已声明的平台能力：')
        ..writeln(
          selectedDefinitions.isEmpty
              ? '未声明平台能力。'
              : const JsonEncoder.withIndent('  ').convert(selectedDefinitions),
        );
    }
    output
      ..writeln()
      ..writeln('============================================================')
      ..writeln(isAgent ? '统一 Agent 操作目录' : '对话控制台默认基础指令')
      ..writeln('============================================================')
      ..writeln(operationDocument)
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目树')
      ..writeln('============================================================');
    for (final directory in directories) {
      output.writeln('- [directory] $directory/');
    }
    for (final path in files) {
      output.writeln('- [file] $path');
    }
    output
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目文件')
      ..writeln('============================================================');
    for (final path in files) {
      final file = await gateway.catalog.readFile(projectId, path);
      final content = _chatAiTextContent(file);
      output
        ..writeln('===== BEGIN WORKSPACE FILE: $path =====')
        ..writeln('content-type: ${file.contentType}')
        ..writeln('size: ${file.bytes.length} bytes')
        ..writeln('revision: ${file.revision}')
        ..writeln('read-only: ${file.readOnly}');
      if (content == null) {
        output.writeln('content: [binary omitted]');
      } else {
        output
          ..writeln('----- CONTENT -----')
          ..writeln(content);
      }
      output.writeln('===== END WORKSPACE FILE: $path =====');
    }
    output
      ..writeln()
      ..writeln('============================================================')
      ..writeln('最终执行要求')
      ..writeln('============================================================')
      ..writeln('只能按照当前项目声明的模式、显示类型和公开 SDK 修改项目。')
      ..writeln('修改完成后必须执行 projects.validate 并修复全部 error。');
    if (isAgent) {
      output.writeln('必须直接调用上面的 Developer API 完成工作，不要只返回代码。');
    } else {
      output.writeln('最终回答只能包含一个可直接粘贴到对话控制台的 JSON 指令对象或数组。');
    }

    final kind = isAgent ? 'agent' : 'chat';
    request.response.headers
      ..contentType = ContentType('text', 'plain', charset: 'utf-8')
      ..set(
        'Content-Disposition',
        'attachment; filename="$projectId-playmesh-$kind-prompt.txt"',
      );
    final bytes = <int>[0xef, 0xbb, 0xbf, ...utf8.encode(output.toString())];
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }
}
