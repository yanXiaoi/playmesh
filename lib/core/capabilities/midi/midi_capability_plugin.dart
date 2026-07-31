import 'dart:async';

import 'package:flutter/foundation.dart';

import '../capability_plugin.dart';
import '../web_permission/capability_web_permission.dart';
import '../web_permission/web_permission_platform_authorizer.dart';

class MidiCapabilityPlugin
    implements CapabilityPlugin, CapabilityWebPermissionPlugin {
  MidiCapabilityPlugin({
    this.webPermissionAuthorizer =
        const DefaultWebPermissionPlatformAuthorizer(),
  });

  static const code = 'device.midi';
  static const webPermissionResource = 'midiSysex';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: 'MIDI',
    description: '允许游戏通过标准 Web MIDI API 请求 MIDI SysEx，并为后续原生 MIDI 能力保留独立适配入口。',
    apiVersion: '1.0.0',
    supportedPlatforms: [CapabilityPlatform.ANDROID],
    methods: [],
    events: [],
  );

  final WebPermissionPlatformAuthorizer webPermissionAuthorizer;
  @override
  late final CapabilityWebPermissionExecutor webPermissionExecutor =
      CapabilityWebPermissionExecutor(
        authorize: (_) => webPermissionAuthorizer.authorize(
          const WebPermissionPlatformRequest(),
        ),
      );

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  List<String> get webPermissionResources => const [webPermissionResource];

  @override
  bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    if (options.isNotEmpty) {
      throw const FormatException('MIDI 能力当前不接受创建参数');
    }
    return _MidiCapabilityInstance();
  }

  @override
  Future<void> dispose() async {}
}

class _MidiCapabilityInstance implements CapabilityInstance {
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) {
    if (_disposed) throw StateError('能力实例已释放');
    throw FormatException('MIDI 能力当前没有可调用的原生方法：$method');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
  }
}
