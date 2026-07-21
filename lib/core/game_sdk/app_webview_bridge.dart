import 'dart:async';
import 'dart:convert';

import 'generated_sdk_versions.dart';

import '../platform/app_device_service.dart';
import '../platform/app_sensor_service.dart';
import '../../models/game_capability_registry.dart';

class AppWebViewBridge {
  AppWebViewBridge({
    required this.userId,
    required this.nickname,
    this.gameName = 'Playmesh 游戏',
    this.declaredCapabilities = const [],
    this.deviceService = const AppDeviceService(),
    AppSensorSource? sensorSource,
    this.onExitRequested,
  }) : _sensorHub = AppSensorHub(source: sensorSource);

  final String userId;
  final String nickname;
  final String gameName;
  final List<String> declaredCapabilities;
  final AppDeviceService deviceService;
  final Future<void> Function()? onExitRequested;
  final AppSensorHub _sensorHub;
  bool _capabilitiesConfirmed = false;

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
        'app.device.haptic' => await _haptic(payload),
        'app.device.fullscreen' => await _fullscreen(payload),
        'app.device.sensor.subscribe' => await _subscribeSensor(payload, send),
        'app.device.sensor.unsubscribe' => await _unsubscribeSensor(payload),
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
    _capabilitiesConfirmed = false;
    return {
      'available': true,
      'sdkVersion': generatedAppSdkVersion,
      'identity': {
        'userId': userId,
        'nickname': nickname,
        'source': 'playmesh_app',
      },
      'game': {'name': gameName, 'requiredCapabilities': declaredCapabilities},
      'capabilityRegistry': gameCapabilityDefinitions
          .map((definition) => definition.toJson())
          .toList(),
      'device': {
        'platform': deviceService.platform,
        'capabilities': [
          ...deviceService.capabilities,
          ..._declaredAvailableSensors.map((type) => type.permission),
        ],
        'declaredCapabilities': declaredCapabilities,
      },
    };
  }

  Object? _confirmCapabilities() {
    _capabilitiesConfirmed = true;
    return null;
  }

  Iterable<AppSensorType> get _declaredAvailableSensors =>
      AppSensorType.values.where(
        (type) =>
            declaredCapabilities.contains(type.permission) &&
            _sensorHub.availableTypes.contains(type),
      );

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

  Future<Object?> _subscribeSensor(
    Map<String, Object?> payload,
    Future<void> Function(String message) send,
  ) async {
    final subscriptionId = _requiredString(payload, 'subscriptionId');
    final type = AppSensorType.fromSdkValue(_requiredString(payload, 'type'));
    if (!declaredCapabilities.contains(type.permission)) {
      throw StateError('当前游戏未在 capabilities.json 声明 ${type.permission}');
    }
    if (!_capabilitiesConfirmed) {
      throw StateError('请先完成本次游戏能力确认');
    }
    final rawFps = payload['fps'];
    if (rawFps is! num ||
        !rawFps.isFinite ||
        rawFps != rawFps.roundToDouble() ||
        rawFps < 1 ||
        rawFps > 120) {
      throw const FormatException('fps 必须是 1 到 120 的整数');
    }
    await _sensorHub.subscribe(
      subscriptionId: subscriptionId,
      type: type,
      fps: rawFps.toInt(),
      onData: (sample) {
        unawaited(
          send(
            jsonEncode({
              'type': 'app.device.data',
              'subscriptionId': subscriptionId,
              'data': sample.toJson(),
            }),
          ),
        );
      },
      onError: (error) {
        unawaited(
          send(
            jsonEncode({
              'type': 'app.device.error',
              'subscriptionId': subscriptionId,
              'error': error.toString(),
            }),
          ),
        );
      },
    );
    return null;
  }

  Future<Object?> _unsubscribeSensor(Map<String, Object?> payload) async {
    await _sensorHub.unsubscribe(_requiredString(payload, 'subscriptionId'));
    return null;
  }

  Object? _requestExit() {
    final callback = onExitRequested;
    if (callback != null) {
      Timer.run(() => unawaited(callback()));
    }
    return null;
  }

  Future<void> resetDeviceSubscriptions() {
    _capabilitiesConfirmed = false;
    return _sensorHub.clear();
  }

  Future<void> close() {
    _capabilitiesConfirmed = false;
    return _sensorHub.clear();
  }
}

String _requiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}
