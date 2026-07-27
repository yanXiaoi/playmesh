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

  static const promptsRoot = 'assets/playmesh-library/public/developer/prompts';
  static const manifestAssetPath = '$promptsRoot/manifest.json';
  static const _maxTemplateBytes = 512 * 1024;
  static const _reservedTemplateIds = {'common', 'agent-common'};

  final AssetBundle _bundle;
  final Directory? _injectedRoot;
  Directory? _resolvedRoot;
  Future<List<DeveloperAiPromptTemplateDescriptor>>? _descriptorsOperation;

  Future<List<DeveloperAiPromptTemplate>> list() async {
    final templates = <DeveloperAiPromptTemplate>[];
    for (final descriptor in await descriptors()) {
      templates.add(await read(descriptor.id));
    }
    return List.unmodifiable(templates);
  }

  Future<List<DeveloperAiPromptTemplateDescriptor>> descriptors() {
    return _descriptorsOperation ??= _loadDescriptors();
  }

  Future<DeveloperAiPromptTemplate> read(String id) async {
    final descriptor = await _descriptor(id);
    final defaultContent = await _readDefault(descriptor);
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
    await _descriptor(id);
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
    await _descriptor(id);
    final file = File(
      '${(await _root()).path}${Platform.pathSeparator}$id.txt',
    );
    if (await file.exists()) await file.delete();
    return read(id);
  }

  Future<DeveloperAiPromptTemplateDescriptor> _descriptor(String id) async {
    for (final descriptor in await descriptors()) {
      if (descriptor.id == id) return descriptor;
    }
    throw FormatException('未知 AI 提示模板: $id');
  }

  Future<List<DeveloperAiPromptTemplateDescriptor>> _loadDescriptors() async {
    final manifestText = await _bundle.loadString(manifestAssetPath);
    final decoded = jsonDecode(manifestText);
    if (decoded is! Map) {
      throw const FormatException('AI 提示词清单根节点必须是对象');
    }
    final manifest = Map<String, Object?>.from(decoded);
    final version = manifest['manifestVersion'];
    if (version is! String ||
        !RegExp(
          r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
        ).hasMatch(version)) {
      throw const FormatException(
        'AI 提示词 manifestVersion 必须使用严格 MAJOR.MINOR.PATCH',
      );
    }
    final rawTemplates = manifest['templates'];
    if (rawTemplates is! List || rawTemplates.isEmpty) {
      throw const FormatException('AI 提示词清单 templates 必须是非空数组');
    }
    final ids = <String>{};
    final files = <String>{};
    final result = <DeveloperAiPromptTemplateDescriptor>[];
    for (final raw in rawTemplates) {
      if (raw is! Map) {
        throw const FormatException('AI 提示词清单模板必须是对象');
      }
      final item = Map<String, Object?>.from(raw);
      final id = _requiredManifestString(item, 'id');
      final file = _requiredManifestString(item, 'file');
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(id)) {
        throw FormatException('AI 提示词模板 id 无效: $id');
      }
      if (!RegExp(r'^[^/\\]+\.txt$').hasMatch(file) ||
          file.contains('..') ||
          file.contains('/') ||
          file.contains(r'\')) {
        throw FormatException('AI 提示词模板 file 必须是当前目录内的 .txt 文件: $file');
      }
      if (!ids.add(id)) {
        throw FormatException('AI 提示词清单包含重复 id: $id');
      }
      if (!files.add(file)) {
        throw FormatException('AI 提示词清单包含重复 file: $file');
      }
      result.add(
        DeveloperAiPromptTemplateDescriptor(
          id: id,
          name: _requiredManifestString(item, 'name'),
          category: _requiredManifestString(item, 'category'),
          categoryName: _requiredManifestString(item, 'categoryName'),
          assetPath: '$promptsRoot/$file',
        ),
      );
    }
    final missingReserved = _reservedTemplateIds.difference(ids);
    if (missingReserved.isNotEmpty) {
      throw FormatException('AI 提示词清单缺少保留模板: ${missingReserved.join(', ')}');
    }
    for (final descriptor in result) {
      await _readDefault(descriptor);
    }
    return List.unmodifiable(result);
  }

  Future<String> _readDefault(
    DeveloperAiPromptTemplateDescriptor descriptor,
  ) async {
    final data = await _bundle.load(descriptor.assetPath);
    if (data.lengthInBytes == 0 || data.lengthInBytes > _maxTemplateBytes) {
      throw FormatException('AI 提示词模板 ${descriptor.id} 必须在 1 B 至 512 KiB 之间');
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final content = utf8.decode(bytes, allowMalformed: false);
    if (content.trim().isEmpty) {
      throw FormatException('AI 提示词模板 ${descriptor.id} 不能为空');
    }
    return content;
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

String _requiredManifestString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('AI 提示词清单 $field 必须是非空字符串');
  }
  return value.trim();
}
