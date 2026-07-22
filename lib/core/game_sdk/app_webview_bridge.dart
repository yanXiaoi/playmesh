import 'dart:async';
import 'dart:convert';

import 'generated_sdk_versions.dart';

import '../capabilities/capability_registry.dart';
import '../capabilities/capability_runtime.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/support/motion_sensor_source.dart';
import '../platform/app_device_service.dart';

class AppWebViewBridge {
  AppWebViewBridge({
    required this.userId,
    required this.nickname,
    this.gameName = 'Playmesh 游戏',
    this.declaredCapabilities = const [],
    this.deviceService = const AppDeviceService(),
    MotionSensorSource? motionSource,
    CapabilityRegistry? capabilityRegistry,
    this.onExitRequested,
  }) : capabilityRegistry =
           capabilityRegistry ??
           createDefaultCapabilityRegistry(motionSource: motionSource) {
    _capabilityRuntime = CapabilityRuntime(
      registry: this.capabilityRegistry,
      declaredCapabilities: declaredCapabilities,
    );
  }

  final String userId;
  final String nickname;
  final String gameName;
  final List<String> declaredCapabilities;
  final AppDeviceService deviceService;
  final Future<void> Function()? onExitRequested;
  final CapabilityRegistry capabilityRegistry;
  late final CapabilityRuntime _capabilityRuntime;

  Future<void> handleJavaScriptMessage(
    String rawMessage,
    Future<void> Function(String message) send,
  ) async {
    String? requestId;
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) {
        throw const FormatException('App SDK 命令必须是对象');
      }
      final command = Map<String, Object?>.from(decoded);
      requestId = command['requestId'] as String?;
      final payload = command['payload'] is Map
          ? Map<String, Object?>.from(command['payload']! as Map)
          : const <String, Object?>{};
      final result = switch (command['command']) {
        'app.bootstrap' => _bootstrap(),
        'app.capabilities.confirm' => _confirmCapabilities(),
        'app.capability.create' => await _capabilityRuntime.create(
          payload,
          (message) => send(jsonEncode(message)),
        ),
        'app.capability.invoke' => await _capabilityRuntime.invoke(payload),
        'app.capability.dispose' => await _disposeCapability(payload),
        'app.device.haptic' => await _haptic(payload),
        'app.device.fullscreen' => await _fullscreen(payload),
        'app.game.exit' => _requestExit(),
        _ => throw FormatException('未知 App SDK 命令：${command['command']}'),
      };
      await send(
        jsonEncode({
          'type': 'app.command.result',
          'requestId': requestId,
          'result': result,
        }),
      );
    } on Object catch (error) {
      await send(
        jsonEncode({
          'type': 'app.command.error',
          'requestId': requestId,
          'error': error.toString(),
        }),
      );
    }
  }

  Future<void> sendInput(
    Map<String, Object?> input,
    Future<void> Function(String message) send,
  ) {
    return send(jsonEncode({'type': 'app.device.input', 'input': input}));
  }

  Map<String, Object?> _bootstrap() {
    return {
      'available': true,
      'sdkVersion': generatedAppSdkVersion,
      'identity': {
        'userId': userId,
        'nickname': nickname,
        'source': 'playmesh_app',
      },
      'game': {'name': gameName, 'requiredCapabilities': declaredCapabilities},
      'capabilityRegistry': capabilityRegistry.descriptors
          .map((definition) => definition.toJson())
          .toList(),
      'device': {
        'platform': deviceService.platform,
        'capabilities': _capabilityRuntime.availableDeclaredCodes.toList(),
        'declaredCapabilities': declaredCapabilities,
      },
    };
  }

  Object? _confirmCapabilities() {
    _capabilityRuntime.confirm();
    return null;
  }

  Future<Object?> _haptic(Map<String, Object?> payload) async {
    final style = payload['style'];
    if (style is! String || style.isEmpty) {
      throw const FormatException('style 必须是非空字符串');
    }
    await deviceService.haptic(style);
    return null;
  }

  Future<Object?> _fullscreen(Map<String, Object?> payload) async {
    final enabled = payload['enabled'];
    if (enabled is! bool) throw const FormatException('enabled 必须是布尔值');
    await deviceService.setFullscreen(enabled);
    return null;
  }

  Future<Object?> _disposeCapability(Map<String, Object?> payload) async {
    await _capabilityRuntime.disposeInstance(payload);
    return null;
  }

  Object? _requestExit() {
    final callback = onExitRequested;
    if (callback != null) {
      Timer.run(() => unawaited(callback()));
    }
    return null;
  }

  Future<void> resetCapabilities() {
    return _capabilityRuntime.reset();
  }

  Future<void> close() async {
    await _capabilityRuntime.reset();
    await capabilityRegistry.dispose();
  }
}
