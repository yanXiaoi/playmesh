import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import '../library/playmesh_library_root.dart';

class DeveloperAiPromptTemplateDescriptor {
  const DeveloperAiPromptTemplateDescriptor({
    required this.id,
    required this.name,
    required this.category,
    required this.categoryName,
    required this.assetPath,
  });

  final String id;
  final String name;
  final String category;
  final String categoryName;
  final String assetPath;
}

class DeveloperAiPromptTemplate {
  const DeveloperAiPromptTemplate({
    required this.descriptor,
    required this.content,
    required this.defaultContent,
    required this.customized,
  });

  final DeveloperAiPromptTemplateDescriptor descriptor;
  final String content;
  final String defaultContent;
  final bool customized;

  Map<String, Object?> toJson() => {
    'id': descriptor.id,
    'name': descriptor.name,
    'category': descriptor.category,
    'categoryName': descriptor.categoryName,
    'content': content,
    'defaultContent': defaultContent,
    'customized': customized,
  };
}

class DeveloperAiPromptTemplateStore {
  DeveloperAiPromptTemplateStore({AssetBundle? bundle, Directory? root})
    : _bundle = bundle ?? rootBundle,
      _injectedRoot = root;

  static const descriptors = <DeveloperAiPromptTemplateDescriptor>[
    DeveloperAiPromptTemplateDescriptor(
      id: 'common',
      name: '对话 AI 公共规则与快速操作',
      category: 'common',
      categoryName: '公共',
      assetPath: 'assets/playmesh-library/public/developer/prompts/common.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'agent-common',
      name: 'Agent 公共规则与接口操作',
      category: 'common',
      categoryName: '公共',
      assetPath:
          'assets/playmesh-library/public/developer/prompts/agent-common.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'custom-ideas',
      name: '自定义想法',
      category: 'common',
      categoryName: '公共',
      assetPath:
          'assets/playmesh-library/public/developer/prompts/custom-ideas.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'solo',
      name: '单机游戏',
      category: 'mode',
      categoryName: '游戏模式',
      assetPath: 'assets/playmesh-library/public/developer/prompts/solo.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'multiplayer',
      name: '联机游戏公共规则',
      category: 'mode',
      categoryName: '游戏模式',
      assetPath:
          'assets/playmesh-library/public/developer/prompts/multiplayer.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'multi-screen',
      name: '普通多人多屏',
      category: 'display',
      categoryName: '显示模式',
      assetPath:
          'assets/playmesh-library/public/developer/prompts/multi-screen.txt',
    ),
    DeveloperAiPromptTemplateDescriptor(
      id: 'single-screen-multiplayer',
      name: '单屏多人',
      category: 'display',
      categoryName: '显示模式',
      assetPath:
          'assets/playmesh-library/public/developer/prompts/single-screen-multiplayer.txt',
    ),
  ];

  static const _maxTemplateBytes = 512 * 1024;

  final AssetBundle _bundle;
  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<List<DeveloperAiPromptTemplate>> list() async {
    final templates = <DeveloperAiPromptTemplate>[];
    for (final descriptor in descriptors) {
      templates.add(await read(descriptor.id));
    }
    return List.unmodifiable(templates);
  }

  Future<DeveloperAiPromptTemplate> read(String id) async {
    final descriptor = _descriptor(id);
    final defaultContent = await _bundle.loadString(descriptor.assetPath);
    final override = File(
      '${(await _root()).path}${Platform.pathSeparator}$id.txt',
    );
    final customized = await override.exists();
    return DeveloperAiPromptTemplate(
      descriptor: descriptor,
      content: customized ? await override.readAsString() : defaultContent,
      defaultContent: defaultContent,
      customized: customized,
    );
  }

  Future<DeveloperAiPromptTemplate> save(String id, String content) async {
    _descriptor(id);
    if (content.trim().isEmpty) {
      throw const FormatException('提示模板不能为空');
    }
    if (utf8.encode(content).length > _maxTemplateBytes) {
      throw const FormatException('单个提示模板不能超过 512 KiB');
    }
    final root = await _root();
    await root.create(recursive: true);
    final target = File('${root.path}${Platform.pathSeparator}$id.txt');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(content, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    return read(id);
  }

  Future<DeveloperAiPromptTemplate> reset(String id) async {
    _descriptor(id);
    final file = File(
      '${(await _root()).path}${Platform.pathSeparator}$id.txt',
    );
    if (await file.exists()) await file.delete();
    return read(id);
  }

  DeveloperAiPromptTemplateDescriptor _descriptor(String id) {
    for (final descriptor in descriptors) {
      if (descriptor.id == id) return descriptor;
    }
    throw FormatException('未知 AI 提示模板: $id');
  }

  Future<Directory> _root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final injected = _injectedRoot;
    if (injected != null) return _resolvedRoot = injected;
    final libraryRoot = await PlaymeshLibraryRoot.resolve();
    return _resolvedRoot = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}developer'
      '${Platform.pathSeparator}ai-prompts',
    );
  }
}
