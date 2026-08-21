import 'dart:async';

import 'package:flutter/foundation.dart';

typedef CapabilityJson = Map<String, Object?>;

/// 能力清单中允许声明的运行平台。
///
/// 枚举名就是跨 App Bridge/HTTP 边界使用的稳定值，不维护第二套映射。
// ignore: constant_identifier_names
enum CapabilityPlatform { WINDOWS, ANDROID, HTML }

CapabilityPlatform? get currentCapabilityPlatform {
  if (kIsWeb) return CapabilityPlatform.HTML;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => CapabilityPlatform.WINDOWS,
    TargetPlatform.android => CapabilityPlatform.ANDROID,
    _ => null,
  };
}

class CapabilityMethodDescriptor {
  const CapabilityMethodDescriptor({
    required this.name,
    required this.description,
    this.requiresUserActivation = false,
    this.argumentsSchema = const {'type': 'object'},
    this.resultSchema = const {'type': 'null'},
  });

  final String name;
  final String description;
  final bool requiresUserActivation;
  final CapabilityJson argumentsSchema;
  final CapabilityJson resultSchema;

  CapabilityJson toJson() => {
    'name': name,
    'description': description,
    'requiresUserActivation': requiresUserActivation,
    'argumentsSchema': argumentsSchema,
    'resultSchema': resultSchema,
  };
}

class CapabilityEventDescriptor {
  const CapabilityEventDescriptor({
    required this.name,
    required this.description,
    this.dataSchema = const {'type': 'object'},
  });

  final String name;
  final String description;
  final CapabilityJson dataSchema;

  CapabilityJson toJson() => {
    'name': name,
    'description': description,
    'dataSchema': dataSchema,
  };
}

class CapabilityDescriptor {
  const CapabilityDescriptor({
    required this.code,
    required this.name,
    required this.description,
    required this.apiVersion,
    required this.supportedPlatforms,
    required this.methods,
    required this.events,
    this.optionsSchema = const {'type': 'object'},
  });

  final String code;
  final String name;
  final String description;
  final String apiVersion;
  final List<CapabilityPlatform> supportedPlatforms;
  final List<CapabilityMethodDescriptor> methods;
  final List<CapabilityEventDescriptor> events;
  final CapabilityJson optionsSchema;

  bool supportsPlatform(CapabilityPlatform platform) =>
      supportedPlatforms.contains(platform);

  CapabilityJson toJson() => {
    'code': code,
    'name': name,
    'description': description,
    'apiVersion': apiVersion,
    'supportedPlatforms': supportedPlatforms
        .map((platform) => platform.name)
        .toList(growable: false),
    'optionsSchema': optionsSchema,
    'methods': methods.map((method) => method.toJson()).toList(),
    'events': events.map((event) => event.toJson()).toList(),
  };
}

class CapabilityInstanceEvent {
  const CapabilityInstanceEvent(this.name, [this.data = const {}]);

  final String name;
  final CapabilityJson data;
}

abstract interface class CapabilityInstance {
  Stream<CapabilityInstanceEvent> get events;

  Future<Object?> invoke(String method, CapabilityJson arguments);

  Future<void> dispose();
}

abstract interface class CapabilityPlugin {
  CapabilityDescriptor get descriptor;

  /// 只允许执行同步、零 I/O 的平台注册判断。
  ///
  /// 硬件、驱动或原生服务是否真正可用，应在 [create] 时由实际创建操作决定，
  /// 失败直接向调用方返回，不能在 App 启动阶段预探测。
  bool get isAvailable;

  Future<CapabilityInstance> create(CapabilityJson options);

  Future<void> dispose();
}
