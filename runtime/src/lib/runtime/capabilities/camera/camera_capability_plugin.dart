import 'dart:async';

import 'package:flutter/foundation.dart';

import '../capability_plugin.dart';
import '../web_permission/capability_web_permission.dart';
import '../web_permission/web_permission_platform_authorizer.dart';

class CameraCapabilityPlugin
    implements CapabilityPlugin, CapabilityWebPermissionPlugin {
  CameraCapabilityPlugin({
    this.webPermissionAuthorizer =
        const DefaultWebPermissionPlatformAuthorizer(),
  });

  static const code = 'media.camera';
  static const webPermissionResource = 'camera';
  static const capabilityDescriptor = CapabilityDescriptor(
    code: code,
    name: '摄像头',
    description: '允许游戏通过标准 Web API 访问摄像头，并为后续原生摄像头能力保留独立适配入口。',
    apiVersion: '1.0.0',
    supportedPlatforms: [
      CapabilityPlatform.WINDOWS,
      CapabilityPlatform.ANDROID,
    ],
    methods: [],
    events: [],
  );

  final WebPermissionPlatformAuthorizer webPermissionAuthorizer;
  @override
  late final CapabilityWebPermissionExecutor webPermissionExecutor =
      CapabilityWebPermissionExecutor(
        authorize: (_) => webPermissionAuthorizer.authorize(
          const WebPermissionPlatformRequest(
            androidPermissions: ['android.permission.CAMERA'],
          ),
        ),
      );

  @override
  CapabilityDescriptor get descriptor => capabilityDescriptor;

  @override
  List<String> get webPermissionResources => const [webPermissionResource];

  @override
  bool get isAvailable {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async {
    if (options.isNotEmpty) {
      throw const FormatException('摄像头能力当前不接受创建参数');
    }
    return _CameraCapabilityInstance();
  }

  @override
  Future<void> dispose() async {}
}

class _CameraCapabilityInstance implements CapabilityInstance {
  final StreamController<CapabilityInstanceEvent> _events =
      StreamController.broadcast();
  bool _disposed = false;

  @override
  Stream<CapabilityInstanceEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) {
    if (_disposed) throw StateError('能力实例已释放');
    throw FormatException('摄像头能力当前没有可调用的原生方法：$method');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
  }
}
