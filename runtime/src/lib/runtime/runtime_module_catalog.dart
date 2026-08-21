import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

final class RuntimeModuleDefinition {
  const RuntimeModuleDefinition({
    required this.id,
    required this.platforms,
    required this.capabilities,
    required this.mediaProtocols,
    required this.androidPermissions,
    required this.removableApkEntries,
    required this.postBuildPrunable,
    required this.dependencies,
    required this.alwaysRetained,
  });

  factory RuntimeModuleDefinition.fromJson(Map<String, Object?> value) {
    final id = _requiredModuleString(value, 'id');
    return RuntimeModuleDefinition(
      id: id,
      platforms: _moduleStrings(value, 'platforms'),
      capabilities: _moduleStrings(value, 'capabilities'),
      mediaProtocols: _moduleStrings(value, 'mediaProtocols'),
      androidPermissions: _moduleStrings(value, 'androidPermissions'),
      removableApkEntries: _moduleStrings(value, 'removableApkEntries'),
      postBuildPrunable: value['postBuildPrunable'] == true,
      dependencies: _moduleStrings(value, 'dependencies'),
      alwaysRetained: value['alwaysRetained'] == true,
    );
  }

  final String id;
  final Set<String> platforms;
  final Set<String> capabilities;
  final Set<String> mediaProtocols;
  final Set<String> androidPermissions;
  final Set<String> removableApkEntries;
  final bool postBuildPrunable;
  final Set<String> dependencies;
  final bool alwaysRetained;
}

/// Declarative output consumed by the future main-App exporter. Large native
/// modules are removed as independent APK entries; merged Dart/DEX plugins are
/// reported separately because deleting them from a compiled APK is unsafe.
final class RuntimeModulePruningPlan {
  const RuntimeModulePruningPlan({
    required this.retainedModuleIds,
    required this.removedModuleIds,
    required this.apkEntriesToRemove,
    required this.androidPermissionsToRetain,
    required this.nonPrunableModuleIds,
  });

  final Set<String> retainedModuleIds;
  final Set<String> removedModuleIds;
  final Set<String> apkEntriesToRemove;
  final Set<String> androidPermissionsToRetain;
  final Set<String> nonPrunableModuleIds;
}

/// Runtime-owned record of modules that physically remain in the exported
/// package. The exporter updates this asset while removing independent APK
/// entries, then aligns and signs the resulting APK again.
final class RuntimeModuleCatalog {
  const RuntimeModuleCatalog._({
    required this.installedModuleIds,
    required this.definitions,
  });

  static const assetPath = 'assets/runtime/runtime-modules.json';
  static const _nativeChannel = MethodChannel('playmesh/runtime_modules');

  static Future<RuntimeModuleCatalog> load() async {
    final decoded = jsonDecode(await rootBundle.loadString(assetPath));
    if (decoded is! Map) {
      throw const FormatException('Runtime 模块清单根节点必须是对象');
    }
    final value = Map<String, Object?>.from(decoded);
    if (value['schemaVersion'] != 1) {
      throw const FormatException('Runtime 模块清单版本不受支持');
    }
    final installed = _moduleStrings(value, 'installed');
    final rawModules = value['modules'];
    if (rawModules is! List) {
      throw const FormatException('Runtime modules 必须是数组');
    }
    final definitions = <String, RuntimeModuleDefinition>{};
    final capabilities = <String>{};
    final mediaProtocols = <String>{};
    for (final raw in rawModules) {
      if (raw is! Map) throw const FormatException('Runtime 模块定义必须是对象');
      final definition = RuntimeModuleDefinition.fromJson(
        Map<String, Object?>.from(raw),
      );
      if (definitions.containsKey(definition.id)) {
        throw FormatException('Runtime 模块 ID 重复: ${definition.id}');
      }
      if (definition.platforms.isEmpty ||
          definition.platforms.any(
            (platform) => platform != 'android' && platform != 'windows',
          )) {
        throw FormatException('Runtime 模块 ${definition.id} platforms 无效');
      }
      for (final code in definition.capabilities) {
        if (!capabilities.add(code)) {
          throw FormatException('Runtime 能力模块重复: $code');
        }
      }
      for (final protocol in definition.mediaProtocols) {
        if (!mediaProtocols.add(protocol)) {
          throw FormatException('Runtime 媒体模块重复: $protocol');
        }
      }
      definitions[definition.id] = definition;
    }
    final unknown = installed.difference(definitions.keys.toSet());
    if (unknown.isNotEmpty) {
      throw FormatException('Runtime 包含未定义模块: ${unknown.join(', ')}');
    }
    for (final definition in definitions.values) {
      final missingDependencies = definition.dependencies.difference(
        definitions.keys.toSet(),
      );
      if (missingDependencies.isNotEmpty) {
        throw FormatException(
          'Runtime 模块 ${definition.id} 依赖未定义模块: '
          '${missingDependencies.join(', ')}',
        );
      }
    }
    final verifiedInstalled = await _verifyNativeModules(
      installed,
      definitions,
    );
    return RuntimeModuleCatalog._(
      installedModuleIds: Set.unmodifiable(verifiedInstalled),
      definitions: Map.unmodifiable(definitions),
    );
  }

  final Set<String> installedModuleIds;
  final Map<String, RuntimeModuleDefinition> definitions;

  Iterable<RuntimeModuleDefinition> get installedModules =>
      installedModuleIds.map((id) => definitions[id]!);

  Set<String> get capabilityCodes => Set.unmodifiable({
    for (final module in installedModules) ...module.capabilities,
  });

  Set<String> get mediaProtocols => Set.unmodifiable({
    for (final module in installedModules) ...module.mediaProtocols,
  });

  bool contains(String moduleId) => installedModuleIds.contains(moduleId);

  Set<String> requiredModuleIdsForCapabilities(Iterable<String> codes) {
    final requested = codes.toSet();
    final knownCapabilities = definitions.values
        .expand((definition) => definition.capabilities)
        .toSet();
    final unknown = requested.difference(knownCapabilities);
    if (unknown.isNotEmpty) {
      throw FormatException('游戏声明了 Runtime 不认识的能力: ${unknown.join(', ')}');
    }
    final required = <String>{
      for (final definition in definitions.values)
        if (definition.alwaysRetained ||
            definition.capabilities.any(requested.contains))
          definition.id,
    };
    var changed = true;
    while (changed) {
      changed = false;
      for (final id in required.toList(growable: false)) {
        for (final dependency in definitions[id]!.dependencies) {
          if (required.add(dependency)) changed = true;
        }
      }
    }
    return Set.unmodifiable(required);
  }

  RuntimeModulePruningPlan pruningPlanForCapabilities(Iterable<String> codes) {
    final retained = requiredModuleIdsForCapabilities(codes);
    final removed = installedModuleIds.difference(retained);
    return RuntimeModulePruningPlan(
      retainedModuleIds: retained,
      removedModuleIds: Set.unmodifiable(removed),
      apkEntriesToRemove: Set.unmodifiable({
        for (final id in removed)
          if (definitions[id]!.postBuildPrunable)
            ...definitions[id]!.removableApkEntries,
      }),
      androidPermissionsToRetain: Set.unmodifiable({
        for (final id in retained) ...definitions[id]!.androidPermissions,
      }),
      nonPrunableModuleIds: Set.unmodifiable({
        for (final id in removed)
          if (!definitions[id]!.postBuildPrunable) id,
      }),
    );
  }

  static Future<Set<String>> _verifyNativeModules(
    Set<String> installed,
    Map<String, RuntimeModuleDefinition> definitions,
  ) async {
    if (!Platform.isAndroid) return installed;
    final native = await _nativeChannel.invokeListMethod<String>(
      'installedNativeModules',
    );
    if (native == null) {
      throw const FormatException('Android Runtime 未返回原生模块清单');
    }
    final result = installed.toSet();
    final nativeIds = native.toSet();
    result.removeWhere((id) {
      final definition = definitions[id]!;
      final missing =
          definition.removableApkEntries.isNotEmpty && !nativeIds.contains(id);
      if (missing && definition.alwaysRetained) {
        throw FormatException('Runtime 必需原生模块缺失: $id');
      }
      return missing;
    });
    return result;
  }
}

String _requiredModuleString(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! String || result.trim().isEmpty) {
    throw FormatException('Runtime 模块 $field 必须是非空字符串');
  }
  return result.trim();
}

Set<String> _moduleStrings(Map<String, Object?> value, String field) {
  final raw = value[field];
  if (raw is! List || raw.any((item) => item is! String || item.isEmpty)) {
    throw FormatException('Runtime 模块 $field 必须是字符串数组');
  }
  final result = raw.cast<String>().toSet();
  if (result.length != raw.length) {
    throw FormatException('Runtime 模块 $field 不能重复');
  }
  return Set.unmodifiable(result);
}
