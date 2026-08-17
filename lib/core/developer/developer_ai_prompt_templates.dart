import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import '../library/playmesh_library_root.dart';
import '../localization/playmesh_localization.dart';

class DeveloperAiPromptResources {
  const DeveloperAiPromptResources({
    required this.locale,
    required this.messages,
    required this.appMessages,
    required this.includeSourceMetadata,
  });

  final String locale;
  final Map<String, String> messages;
  final Map<String, String> appMessages;
  final bool includeSourceMetadata;

  String text(String key) {
    final value = messages[key];
    if (value == null || value.isEmpty) {
      throw FormatException('AI 提示词语言 $locale 缺少 runtime key: $key');
    }
    return value;
  }

  String appText(String key) {
    final value = appMessages[key];
    if (value == null || value.isEmpty) {
      throw FormatException('App 语言资源 $locale 缺少 key: $key');
    }
    return value;
  }
}

class DeveloperAiPromptTemplateDescriptor {
  const DeveloperAiPromptTemplateDescriptor({
    required this.id,
    required this.category,
    required this.surface,
    required this.mode,
    required this.assetPaths,
  });

  final String id;
  final String category;
  final String surface;
  final String mode;
  final Map<String, String> assetPaths;
}

class DeveloperAiPromptTemplate {
  const DeveloperAiPromptTemplate({
    required this.descriptor,
    required this.content,
    required this.defaultContent,
    required this.customized,
    required this.locale,
  });

  final DeveloperAiPromptTemplateDescriptor descriptor;
  final String content;
  final String defaultContent;
  final bool customized;
  final String locale;

  Map<String, Object?> toJson() => {
    'id': descriptor.id,
    'category': descriptor.category,
    'surface': descriptor.surface,
    'mode': descriptor.mode,
    'content': content,
    'defaultContent': defaultContent,
    'customized': customized,
    'locale': locale,
  };
}

class _DeveloperAiPromptManifest {
  const _DeveloperAiPromptManifest({
    required this.defaultLocale,
    required this.locales,
    required this.localizationCatalog,
    required this.templates,
  });

  final String defaultLocale;
  final List<String> locales;
  final PlaymeshLocalizationCatalog localizationCatalog;
  final List<DeveloperAiPromptTemplateDescriptor> templates;
}

class DeveloperAiPromptTemplateStore {
  DeveloperAiPromptTemplateStore({AssetBundle? bundle, Directory? root})
    : _bundle = bundle ?? rootBundle,
      _injectedRoot = root;

  static const promptsRoot = 'assets/playmesh-library/public/developer/prompts';
  static const manifestAssetPath = '$promptsRoot/manifest.json';
  static const _maxTemplateBytes = 512 * 1024;
  static const _reservedTemplateIds = {
    'common',
    'agent-common',
    'gdevelop-chat',
    'gdevelop-agent',
  };

  final AssetBundle _bundle;
  final Directory? _injectedRoot;
  Directory? _resolvedRoot;
  Future<_DeveloperAiPromptManifest>? _manifestOperation;
  final Map<String, DeveloperAiPromptResources> _resources = {};

  Future<String> resolveLocale(String? requested) async {
    final manifest = await _manifest();
    final normalized = requested?.trim().replaceAll('_', '-').toLowerCase();
    if (normalized == null || normalized.isEmpty) return manifest.defaultLocale;
    for (final locale in manifest.locales) {
      if (locale.toLowerCase() == normalized) return locale;
    }
    final language = normalized.split('-').first;
    for (final locale in manifest.locales) {
      if (locale.toLowerCase().split('-').first == language) return locale;
    }
    return manifest.defaultLocale;
  }

  /// GDevelop 会话使用的严格 locale 入口。
  ///
  /// 输入必须是合法 BCP 47 形状，再按 exact -> base language -> App default
  /// 解析；不会把任意路径或未校验字符串作为资源目录。
  Future<String> resolveSessionLocale(String requested) async {
    final normalized = requested.trim().replaceAll('_', '-');
    if (!RegExp(
      r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$',
    ).hasMatch(normalized)) {
      throw const FormatException('GDevelop AI locale 必须是合法 BCP 47 标识');
    }
    return resolveLocale(normalized);
  }

  Future<DeveloperAiPromptResources> resources({String? locale}) async {
    final resolved = await resolveLocale(locale);
    final cached = _resources[resolved];
    if (cached != null) return cached;
    final manifest = await _manifest();
    const prefix = 'developer.prompt.runtime.';
    final allMessages = manifest.localizationCatalog.resolvedMessages(
      resolved,
      PlaymeshLocalizationBundle.app,
    );
    final messages = <String, String>{
      for (final entry in allMessages.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
    if (messages.isEmpty) {
      throw FormatException('App 语言资源 $resolved 缺少 $prefix 命名空间');
    }
    return _resources[resolved] = DeveloperAiPromptResources(
      locale: resolved,
      messages: Map.unmodifiable(messages),
      appMessages: allMessages,
      includeSourceMetadata: resolved == manifest.defaultLocale,
    );
  }

  Future<List<DeveloperAiPromptTemplate>> list({
    String? locale,
    String surface = 'source',
  }) async {
    final templates = <DeveloperAiPromptTemplate>[];
    for (final descriptor in await descriptors(surface: surface)) {
      templates.add(await read(descriptor.id, locale: locale));
    }
    return List.unmodifiable(templates);
  }

  Future<List<DeveloperAiPromptTemplateDescriptor>> descriptors({
    String surface = 'source',
  }) async {
    _validateSurface(surface);
    return List.unmodifiable(
      (await _manifest()).templates.where(
        (descriptor) => descriptor.surface == surface,
      ),
    );
  }

  Future<List<DeveloperAiPromptTemplateDescriptor>> allDescriptors() async =>
      (await _manifest()).templates;

  Future<Map<String, String>> appMessagesWithPrefix({
    required String locale,
    required String prefix,
  }) async {
    if (prefix.isEmpty) throw const FormatException('本地化 key 前缀不能为空');
    final resources = await this.resources(locale: locale);
    return Map.unmodifiable({
      for (final entry in resources.appMessages.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    });
  }

  Future<DeveloperAiPromptTemplate> read(String id, {String? locale}) async {
    final descriptor = await _descriptor(id);
    final resolvedLocale = await resolveLocale(locale);
    final defaultContent = await _readDefault(descriptor, resolvedLocale);
    final override = await _overrideFile(id, resolvedLocale);
    final customized = await override.exists();
    return DeveloperAiPromptTemplate(
      descriptor: descriptor,
      content: customized ? await override.readAsString() : defaultContent,
      defaultContent: defaultContent,
      customized: customized,
      locale: resolvedLocale,
    );
  }

  Future<DeveloperAiPromptTemplate> save(
    String id,
    String content, {
    String? locale,
  }) async {
    await _descriptor(id);
    final resolvedLocale = await resolveLocale(locale);
    if (content.trim().isEmpty) {
      throw const FormatException('提示模板不能为空');
    }
    if (utf8.encode(content).length > _maxTemplateBytes) {
      throw const FormatException('单个提示模板不能超过 512 KiB');
    }
    final target = await _overrideFile(id, resolvedLocale);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(content, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    return read(id, locale: resolvedLocale);
  }

  Future<DeveloperAiPromptTemplate> reset(String id, {String? locale}) async {
    await _descriptor(id);
    final resolvedLocale = await resolveLocale(locale);
    final file = await _overrideFile(id, resolvedLocale);
    if (await file.exists()) await file.delete();
    return read(id, locale: resolvedLocale);
  }

  Future<DeveloperAiPromptTemplateDescriptor> _descriptor(String id) async {
    for (final descriptor in await allDescriptors()) {
      if (descriptor.id == id) return descriptor;
    }
    throw FormatException('未知 AI 提示模板: $id');
  }

  Future<_DeveloperAiPromptManifest> _manifest() {
    return _manifestOperation ??= _loadManifest();
  }

  Future<_DeveloperAiPromptManifest> _loadManifest() async {
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
    final localizationCatalog = await PlaymeshLocalizationCatalog.load(
      bundle: _bundle,
    );
    final defaultLocale = localizationCatalog.manifest.defaultLocale;
    final locales = localizationCatalog.manifest.enabledLocales
        .map((locale) => locale.id)
        .toList(growable: false);

    final rawTemplates = manifest['templates'];
    if (rawTemplates is! List || rawTemplates.isEmpty) {
      throw const FormatException('AI 提示词清单 templates 必须是非空数组');
    }
    final ids = <String>{};
    final localizedFiles = <String>{};
    final templates = <DeveloperAiPromptTemplateDescriptor>[];
    for (final raw in rawTemplates) {
      if (raw is! Map) throw const FormatException('AI 提示词模板必须是对象');
      final item = Map<String, Object?>.from(raw);
      final id = _requiredManifestString(item, 'id');
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(id)) {
        throw FormatException('AI 提示词模板 id 无效: $id');
      }
      if (!ids.add(id)) throw FormatException('AI 提示词清单包含重复 id: $id');
      final rawFiles = item['files'];
      if (rawFiles is! Map) {
        throw FormatException('AI 提示词模板 $id 的 files 必须是对象');
      }
      final assetPaths = <String, String>{};
      for (final locale in locales) {
        final file = rawFiles[locale];
        if (file is! String ||
            !_isSafeFile(file, '.txt') ||
            !file.startsWith('$locale/')) {
          throw FormatException(
            'AI 提示词模板 $id 的 files.$locale 必须是当前目录内的 .txt 文件',
          );
        }
        if (!localizedFiles.add('$locale:$file')) {
          throw FormatException('AI 提示词清单包含重复文件: $locale:$file');
        }
        assetPaths[locale] = '$promptsRoot/$file';
      }
      templates.add(
        DeveloperAiPromptTemplateDescriptor(
          id: id,
          category: _requiredManifestString(item, 'category'),
          surface: _optionalManifestEnum(
            item,
            'surface',
            fallback: 'source',
            allowed: const {'source', 'gdevelop'},
          ),
          mode: _optionalManifestEnum(
            item,
            'mode',
            fallback: 'shared',
            allowed: const {'shared', 'chat', 'agent'},
          ),
          assetPaths: Map.unmodifiable(assetPaths),
        ),
      );
    }
    final missingReserved = _reservedTemplateIds.difference(ids);
    if (missingReserved.isNotEmpty) {
      throw FormatException('AI 提示词清单缺少保留模板: ${missingReserved.join(', ')}');
    }
    final result = _DeveloperAiPromptManifest(
      defaultLocale: defaultLocale,
      locales: List.unmodifiable(locales),
      localizationCatalog: localizationCatalog,
      templates: List.unmodifiable(templates),
    );
    for (final locale in locales) {
      const prefix = 'developer.prompt.runtime.';
      final allMessages = localizationCatalog.resolvedMessages(
        locale,
        PlaymeshLocalizationBundle.app,
      );
      final messages = <String, String>{
        for (final entry in allMessages.entries)
          if (entry.key.startsWith(prefix))
            entry.key.substring(prefix.length): entry.value,
      };
      if (messages.isEmpty) {
        throw FormatException('App 语言资源 $locale 缺少 $prefix 命名空间');
      }
      _resources[locale] = DeveloperAiPromptResources(
        locale: locale,
        messages: Map.unmodifiable(messages),
        appMessages: allMessages,
        includeSourceMetadata: locale == defaultLocale,
      );
      for (final descriptor in templates) {
        await _readDefault(descriptor, locale);
      }
    }
    return result;
  }

  void _validateSurface(String surface) {
    if (!const {'source', 'gdevelop'}.contains(surface)) {
      throw FormatException('未知 AI 提示词 surface: $surface');
    }
  }

  Future<String> _readDefault(
    DeveloperAiPromptTemplateDescriptor descriptor,
    String locale,
  ) async {
    final assetPath = descriptor.assetPaths[locale];
    if (assetPath == null) {
      throw FormatException('AI 提示词模板 ${descriptor.id} 缺少 $locale 版本');
    }
    final data = await _bundle.load(assetPath);
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

  Future<File> _overrideFile(String id, String locale) async {
    final root = await _root();
    final manifest = await _manifest();
    if (locale == manifest.defaultLocale) {
      return File('${root.path}${Platform.pathSeparator}$id.txt');
    }
    return File(
      '${root.path}${Platform.pathSeparator}$locale'
      '${Platform.pathSeparator}$id.txt',
    );
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

String _optionalManifestEnum(
  Map<String, Object?> json,
  String field, {
  required String fallback,
  required Set<String> allowed,
}) {
  final raw = json[field];
  if (raw == null) return fallback;
  if (raw is! String || !allowed.contains(raw)) {
    throw FormatException('AI 提示词清单 $field 无效');
  }
  return raw;
}

String _requiredManifestString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('AI 提示词清单 $field 必须是非空字符串');
  }
  return value.trim();
}

bool _isSafeFile(String value, String extension) {
  final segments = value.split('/');
  return value.endsWith(extension) &&
      !value.startsWith('/') &&
      !value.contains(r'\') &&
      segments.isNotEmpty &&
      segments.every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}
