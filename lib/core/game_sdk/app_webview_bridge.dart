import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sdk_feature_registry.dart';

import '../capabilities/capability_registry.dart';
import '../capabilities/capability_runtime.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/vibration/vibration_capability_plugin.dart';
import '../capabilities/web_permission/capability_web_permission.dart';
import '../platform/app_device_service.dart';
import '../profile/user_profile_store.dart';
import '../../models/game_summary.dart';
import '../../models/user_profile.dart';

class AppWebViewBridge {
  AppWebViewBridge({
    required this.userId,
    required this.nickname,
    this.declaredCapabilities = const [],
    this.acceptRuntimeGameDeclaration = false,
    this.coreBaseUri,
    this.playerSource = 'lan_app',
    this.webPermissionRole = AppWebPermissionRole.authority,
    Map<String, Object?>? platformUiConfiguration,
    this.deviceService = const AppDeviceService(),
    VibrationDriver? vibrationDriver,
    CapabilityRegistry? capabilityRegistry,
    this.onOpenSharePanel,
    bool? showShareAction,
    this.onInputTakeover,
    this.onExitRequested,
  }) : _platformUiConfiguration = _normalizePlatformUiConfiguration(
         platformUiConfiguration,
       ),
       showShareAction = showShareAction ?? onOpenSharePanel != null,
       capabilityRegistry =
           capabilityRegistry ??
           createDefaultCapabilityRegistry(vibrationDriver: vibrationDriver) {
    _capabilityRuntime = CapabilityRuntime(
      registry: this.capabilityRegistry,
      declaredCapabilities: declaredCapabilities,
    );
  }

  final String userId;
  final String nickname;
  final List<String> declaredCapabilities;
  final bool acceptRuntimeGameDeclaration;
  final Uri? coreBaseUri;
  final String playerSource;
  final AppWebPermissionRole webPermissionRole;
  final AppDeviceService deviceService;
  final Future<void> Function()? onOpenSharePanel;
  final bool showShareAction;
  final void Function()? onInputTakeover;
  final Future<void> Function()? onExitRequested;
  final CapabilityRegistry capabilityRegistry;
  Map<String, Object?>? _platformUiConfiguration;
  late CapabilityRuntime _capabilityRuntime;
  late List<String> _runtimeDeclaredCapabilities = List.unmodifiable(
    declaredCapabilities,
  );

  List<String> get runtimeDeclaredCapabilities => _runtimeDeclaredCapabilities;

  Future<bool> authorizeWebPermissions(
    Iterable<String> resources, {
    Uri? sourceUri,
    bool? isUserInitiated,
  }) {
    return capabilityRegistry.authorizeWebPermissions(
      resources: resources,
      declaredCapabilities: _runtimeDeclaredCapabilities,
      role: webPermissionRole,
      sourceUri: sourceUri,
      isUserInitiated: isUserInitiated,
    );
  }

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
      final name = command['command'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('command 必须是非空字符串');
      }
      final result = await SdkFeatureRegistry.dispatchApp(
        AppSdkCommandContext(
          bootstrap: _bootstrap,
          configureRuntimeGame: _configureRuntimeGame,
          confirmCapabilities: _confirmCapabilities,
          capabilityRuntime: _capabilityRuntime,
          sendCapabilityEvent: (message) => send(jsonEncode(message)),
          disposeCapability: _disposeCapability,
          setFullscreen: _fullscreen,
          openSharePanel: _openSharePanel,
          takeOverInput: _takeOverInput,
          requestExit: _requestExit,
          syncAvatar: _syncAvatar,
        ),
        SdkCommandEnvelope(
          name: name,
          requestId: requestId,
          payload: payload,
          raw: command,
        ),
      );
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
          if (error is SdkCommandException) 'code': error.code,
          'error': error.toString(),
        }),
      );
    }
  }

  Future<Map<String, Object?>> _bootstrap(
    Map<String, Object?> _,
    String sdkVersion,
  ) async {
    return {
      '_playmeshPlatformUi': _platformUiConfiguration == null
          ? null
          : {
              ..._platformUiConfiguration!,
              'actions': {
                'share': showShareAction,
                'restart': true,
                'logs': true,
                'fullscreen': true,
                'info': true,
                'performance': true,
                'exit': true,
              },
            },
      'available': true,
      'sdkVersion': sdkVersion,
      'identity': {
        'userId': userId,
        'nickname': nickname,
        'source': 'playmesh_app',
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

  Future<Map<String, Object?>> _configureRuntimeGame(
    Map<String, Object?> payload,
  ) async {
    if (!acceptRuntimeGameDeclaration) {
      throw const FormatException('当前入口不接受运行时游戏声明');
    }
    final runtimeCapabilities = payload['declaredCapabilities'];
    if (runtimeCapabilities is! List ||
        runtimeCapabilities.any((value) => value is! String)) {
      throw const FormatException('declaredCapabilities 必须是字符串数组');
    }
    final normalizedCapabilities = List<String>.unmodifiable(
      runtimeCapabilities.cast<String>().toSet(),
    );
    if (!_sameCapabilities(
      _runtimeDeclaredCapabilities,
      normalizedCapabilities,
    )) {
      await _capabilityRuntime.reset();
      _runtimeDeclaredCapabilities = normalizedCapabilities;
      _capabilityRuntime = CapabilityRuntime(
        registry: capabilityRegistry,
        declaredCapabilities: _runtimeDeclaredCapabilities,
      );
    }
    return {
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

  void setPlatformUiConfiguration(Map<String, Object?>? configuration) {
    _platformUiConfiguration = _normalizePlatformUiConfiguration(configuration);
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

  Future<Object?> _openSharePanel() async {
    final callback = onOpenSharePanel;
    if (callback == null) {
      throw const SdkCommandException('ui_unavailable', '当前平台分享界面不可用');
    }
    await callback();
    return null;
  }

  Object? _takeOverInput() {
    onInputTakeover?.call();
    return null;
  }

  Object? _requestExit() {
    final callback = onExitRequested;
    if (callback != null) {
      Timer.run(() => unawaited(callback()));
    }
    return null;
  }

  Future<Object?> _syncAvatar(Map<String, Object?> payload) async {
    final baseUri = coreBaseUri;
    if (baseUri == null || playerSource != 'lan_app') return null;
    final sessionId = payload['sessionId'];
    final credentialToken = payload['credentialToken'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        credentialToken is! String ||
        credentialToken.isEmpty) {
      throw const FormatException('头像同步会话凭据无效');
    }
    final profile = await const UserProfileStore().load(
      UserProfile(userId: userId, nickname: nickname),
    );
    final bytes = profile.avatarBytes;
    final digest = profile.avatarSha256;
    if (profile.userId != userId || bytes == null || digest == null) {
      return null;
    }
    final response = await http.put(
      baseUri.resolve('v1/sessions/$sessionId/avatar'),
      headers: {
        'Authorization': 'Bearer $credentialToken',
        'Content-Type': 'image/png',
        'X-Playmesh-Avatar-Sha256': digest,
      },
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('头像同步失败（HTTP ${response.statusCode}）');
    }
    return null;
  }

  Future<void> resetCapabilities() {
    final previousRuntime = _capabilityRuntime;
    if (acceptRuntimeGameDeclaration) {
      _runtimeDeclaredCapabilities = List.unmodifiable(declaredCapabilities);
      _capabilityRuntime = CapabilityRuntime(
        registry: capabilityRegistry,
        declaredCapabilities: _runtimeDeclaredCapabilities,
      );
    }
    return previousRuntime.reset();
  }

  Future<void> close() async {
    await _capabilityRuntime.reset();
    await capabilityRegistry.dispose();
  }
}

Map<String, Object?>? _normalizePlatformUiConfiguration(
  Map<String, Object?>? configuration,
) {
  if (configuration == null) return null;
  final locale = configuration['locale'];
  final theme = configuration['theme'];
  final rawMessages = configuration['messages'];
  if (locale is! String ||
      !RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$').hasMatch(locale) ||
      theme is! String ||
      !const {'system', 'light', 'dark'}.contains(theme) ||
      rawMessages is! Map) {
    throw ArgumentError.value(
      configuration,
      'configuration',
      'Invalid platform UI configuration',
    );
  }
  final messages = <String, String>{};
  for (final entry in rawMessages.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(key) ||
        value is! String) {
      throw ArgumentError.value(
        configuration,
        'configuration',
        'Invalid platform UI messages',
      );
    }
    messages[key] = value;
  }
  if (messages.isEmpty) {
    throw ArgumentError.value(
      configuration,
      'configuration',
      'Platform UI messages must not be empty',
    );
  }
  return Map.unmodifiable({
    'locale': locale,
    'messages': Map.unmodifiable(messages),
    'theme': theme,
  });
}

bool _sameCapabilities(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
