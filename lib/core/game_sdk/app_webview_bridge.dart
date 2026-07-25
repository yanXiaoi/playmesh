import 'dart:async';
import 'dart:convert';

import 'generated_sdk_versions.dart';

import '../capabilities/capability_registry.dart';
import '../capabilities/capability_runtime.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/support/motion_sensor_source.dart';
import '../platform/app_device_service.dart';
import '../../models/game_summary.dart';

class AppWebViewBridge {
  AppWebViewBridge({
    required this.userId,
    required this.nickname,
    this.gameName = 'Playmesh 游戏',
    this.declaredCapabilities = const [],
    this.acceptRuntimeGameDeclaration = false,
    this.coreBaseUri,
    this.playerSource = 'lan_app',
    this.deviceService = const AppDeviceService(),
    MotionSensorSource? motionSource,
    CapabilityRegistry? capabilityRegistry,
    this.onExitRequested,
  }) : capabilityRegistry =
           capabilityRegistry ??
           createDefaultCapabilityRegistry(
             motionSource: motionSource,
             deviceService: deviceService,
           ) {
    _capabilityRuntime = CapabilityRuntime(
      registry: this.capabilityRegistry,
      declaredCapabilities: declaredCapabilities,
    );
  }

  final String userId;
  final String nickname;
  final String gameName;
  final List<String> declaredCapabilities;
  final bool acceptRuntimeGameDeclaration;
  final Uri? coreBaseUri;
  final String playerSource;
  final AppDeviceService deviceService;
  final Future<void> Function()? onExitRequested;
  final CapabilityRegistry capabilityRegistry;
  late CapabilityRuntime _capabilityRuntime;
  late String _runtimeGameName = gameName;
  late List<String> _runtimeDeclaredCapabilities = List.unmodifiable(
    declaredCapabilities,
  );

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
        'app.bootstrap' => await _bootstrap(payload),
        'app.capabilities.confirm' => _confirmCapabilities(),
        'app.capability.create' => await _capabilityRuntime.create(
          payload,
          (message) => send(jsonEncode(message)),
        ),
        'app.capability.invoke' => await _capabilityRuntime.invoke(payload),
        'app.capability.dispose' => await _disposeCapability(payload),
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

  Future<Map<String, Object?>> _bootstrap(Map<String, Object?> payload) async {
    if (acceptRuntimeGameDeclaration) {
      final runtimeGameName = payload['gameName'];
      final runtimeCapabilities = payload['declaredCapabilities'];
      if (runtimeGameName is! String || runtimeGameName.trim().isEmpty) {
        throw const FormatException('gameName 必须是非空字符串');
      }
      if (runtimeCapabilities is! List ||
          runtimeCapabilities.any((value) => value is! String)) {
        throw const FormatException('declaredCapabilities 必须是字符串数组');
      }
      final normalizedCapabilities = List<String>.unmodifiable(
        runtimeCapabilities.cast<String>().toSet(),
      );
      if (_runtimeGameName != runtimeGameName.trim() ||
          !_sameCapabilities(
            _runtimeDeclaredCapabilities,
            normalizedCapabilities,
          )) {
        await _capabilityRuntime.reset();
        _runtimeGameName = runtimeGameName.trim();
        _runtimeDeclaredCapabilities = normalizedCapabilities;
        _capabilityRuntime = CapabilityRuntime(
          registry: capabilityRegistry,
          declaredCapabilities: _runtimeDeclaredCapabilities,
        );
      }
    }
    return {
      'available': true,
      'sdkVersion': generatedAppSdkVersion,
      'identity': {
        'userId': userId,
        'nickname': nickname,
        'source': 'playmesh_app',
      },
      'game': {
        'name': _runtimeGameName,
        'requiredCapabilities': _runtimeDeclaredCapabilities,
      },
      'runtime': {
        if (coreBaseUri != null) 'coreBase': coreBaseUri.toString(),
        'playerSource': playerSource,
      },
      'capabilityRegistry': capabilityRegistry.descriptors
          .map((definition) => definition.toJson())
          .toList(),
      'device': {
        'platform': deviceService.platform,
        'capabilities': _capabilityRuntime.availableDeclaredCodes.toList(),
        'declaredCapabilities': _runtimeDeclaredCapabilities,
      },
    };
  }

  Object? _confirmCapabilities() {
    _capabilityRuntime.confirm();
    return null;
  }

  Future<Object?> _fullscreen(Map<String, Object?> payload) async {
    final enabled = payload['enabled'];
    if (enabled is! bool) throw const FormatException('enabled 必须是布尔值');
    final orientationValue = payload['orientation'];
    final orientation = orientationValue == null
        ? null
        : GameOrientation.fromManifestValue(
            orientationValue is String
                ? orientationValue
                : throw const FormatException('orientation 必须是字符串'),
          );
    if (!enabled && orientation != null) {
      throw const FormatException('退出全屏时不能声明 orientation');
    }
    await deviceService.setFullscreen(enabled, orientation: orientation);
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

bool _sameCapabilities(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
