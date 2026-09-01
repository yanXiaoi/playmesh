import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sdk_feature_registry.dart';

import '../app_media/app_media_runtime.dart';
import '../app_media/default_app_media_adapters.dart';
import '../capabilities/capability_plugin.dart';
import '../capabilities/capability_registry.dart';
import '../capabilities/capability_runtime.dart';
import '../capabilities/default_capability_plugins.dart';
import '../capabilities/vibration/vibration_capability_plugin.dart';
import '../capabilities/web_permission/capability_web_permission.dart';
import '../diagnostics/playmesh_error_diagnostic.dart';
import '../platform/app_device_service.dart';
import '../profile/user_profile_store.dart';
import '../storage/app_local_bucket_store.dart';
import '../storage/app_local_bucket_sync_gateway.dart';
import '../../models/game_summary.dart';
import '../../models/user_profile.dart';

class AppWebViewBridge {
  static const trustedUserActivationLifetime = Duration(seconds: 2);

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
    AppMediaRuntime? mediaRuntime,
    this.lanHost,
    this.onOpenSharePanel,
    bool? showShareAction,
    this.onInputTakeover,
    this.onExitRequested,
    this.onNicknameUpdate,
    this.onNicknameChanged,
    this.profileStore = const UserProfileStore(),
    AppLocalBucketStore? localBucketStore,
    http.Client? httpClient,
  }) : _platformUiConfiguration = _normalizePlatformUiConfiguration(
         platformUiConfiguration,
       ),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       // 保留宿主注入参数名，同时不扩大 Bridge 的公开状态面。
       // ignore: prefer_initializing_formals
       _localBucketStore = localBucketStore,
       showShareAction = showShareAction ?? onOpenSharePanel != null {
    this.mediaRuntime = mediaRuntime ?? createDefaultAppMediaRuntime();
    this.capabilityRegistry =
        capabilityRegistry ??
        createDefaultCapabilityRegistry(
          vibrationDriver: vibrationDriver,
          mediaSourceBroker: this.mediaRuntime,
        );
    _capabilityRuntime = CapabilityRuntime(
      registry: this.capabilityRegistry,
      declaredCapabilities: declaredCapabilities,
    );
  }

  final String userId;
  String nickname;
  final List<String> declaredCapabilities;
  final bool acceptRuntimeGameDeclaration;
  final Uri? coreBaseUri;
  final String playerSource;
  final AppWebPermissionRole webPermissionRole;
  final AppDeviceService deviceService;
  final AppLanHost? lanHost;
  final Future<void> Function()? onOpenSharePanel;
  final bool showShareAction;
  final void Function()? onInputTakeover;
  final Future<void> Function()? onExitRequested;
  final Future<Object?> Function(Map<String, Object?> payload)?
  onNicknameUpdate;
  final Future<void> Function(String nickname)? onNicknameChanged;
  final UserProfileStore profileStore;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final AppLocalBucketStore? _localBucketStore;
  Future<AppLocalBucketSyncGateway>? _localBucketSyncGateway;
  late final CapabilityRegistry capabilityRegistry;
  late final AppMediaRuntime mediaRuntime;
  Map<String, Object?>? _platformUiConfiguration;
  late CapabilityRuntime _capabilityRuntime;
  late List<String> _runtimeDeclaredCapabilities = List.unmodifiable(
    declaredCapabilities,
  );
  DateTime? _trustedUserActivationExpiresAt;
  Future<void> _nicknameUpdateTail = Future<void>.value();

  List<String> get runtimeDeclaredCapabilities => _runtimeDeclaredCapabilities;

  /// Records a native pointer or keyboard activation observed by the host.
  /// The activation is short-lived and consumed by at most one gated command.
  void recordUserActivation() {
    _trustedUserActivationExpiresAt = DateTime.now().add(
      trustedUserActivationLifetime,
    );
  }

  bool _consumeUserActivation() {
    final expiresAt = _trustedUserActivationExpiresAt;
    _trustedUserActivationExpiresAt = null;
    return expiresAt != null && !DateTime.now().isAfter(expiresAt);
  }

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
      final rawRequestId = command['requestId'];
      if (rawRequestId != null &&
          (rawRequestId is! String ||
              rawRequestId.isEmpty ||
              utf8.encode(rawRequestId).length > 256)) {
        throw const SdkCommandException(
          'invalid_argument',
          'requestId 必须是长度不超过 256 字节的非空字符串',
        );
      }
      requestId = rawRequestId as String?;
      final rawPayload = command['payload'];
      if (rawPayload is! Map) {
        throw const SdkCommandException('invalid_argument', 'payload 必须是对象');
      }
      final payload = Map<String, Object?>.from(rawPayload);
      final name = command['command'];
      if (name is! String || name.isEmpty || name.length > 128) {
        throw const FormatException('command 必须是非空字符串');
      }
      final result = await SdkFeatureRegistry.dispatchApp(
        AppSdkCommandContext(
          bootstrap: _bootstrap,
          configureRuntimeGame: _configureRuntimeGame,
          confirmCapabilities: _confirmCapabilities,
          capabilityRuntime: _capabilityRuntime,
          mediaRuntime: mediaRuntime,
          sendAppEvent: (message) => send(_encodeAppBridgeMessage(message)),
          disposeCapability: _disposeCapability,
          setFullscreen: _fullscreen,
          openSharePanel: _openSharePanel,
          consumeUserActivation: _consumeUserActivation,
          lanHost: lanHost,
          takeOverInput: _takeOverInput,
          requestExit: _requestExit,
          syncAvatar: _syncAvatar,
          updateNickname: _updateNickname,
          localBucketStore: _localBucketStore,
        ),
        SdkCommandEnvelope(
          name: name,
          requestId: requestId,
          payload: payload,
          raw: command,
        ),
      );
      final response = result is AppSdkCommandResponse
          ? result
          : AppSdkCommandResponse(result: result);
      await send(
        _encodeAppBridgeMessage({
          'type': 'app.command.result',
          'requestId': requestId,
          'result': response.result,
        }),
      );
      final afterResponse = response.afterResponse;
      if (afterResponse != null) {
        unawaited(Future<void>.sync(afterResponse).catchError((Object _) {}));
      }
    } on Object catch (error) {
      await send(
        _encodeAppBridgeMessage({
          'type': 'app.command.error',
          'requestId': requestId,
          if (error is SdkCommandException) 'code': error.code,
          if (error is CapabilityOperationException) 'code': error.code,
          'error': _publicAppBridgeError(error),
        }),
      );
    }
  }

  Future<Map<String, Object?>> _bootstrap(
    Map<String, Object?> _,
    String sdkVersion,
  ) async {
    final syncGateway = await _ensureLocalBucketSyncGateway();
    final fullscreen = await _readFullscreen();
    return {
      '_playmeshPlatformUi': _platformUiConfiguration == null
          ? null
          : {
              ..._platformUiConfiguration!,
              'actions': {
                'share': showShareAction,
                'join': showShareAction,
                'restart': true,
                'logs': true,
                'fullscreen': true,
                'info': true,
                'performance': true,
                'exit': true,
              },
            },
      '_playmeshFullscreen': fullscreen,
      if (syncGateway != null)
        '_playmeshAppStorageSync': {
          'endpoint': syncGateway.endpoint.toString(),
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

  Future<bool> _readFullscreen() async {
    try {
      return await deviceService.isFullscreen();
    } on Object {
      return false;
    }
  }

  Future<AppLocalBucketSyncGateway?> _ensureLocalBucketSyncGateway() {
    final store = _localBucketStore;
    if (store == null) return Future.value();
    return _localBucketSyncGateway ??= AppLocalBucketSyncGateway.start(store);
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
      await mediaRuntime.reset();
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
    final response = await _httpClient.put(
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

  Future<Object?> _updateNickname(Map<String, Object?> payload) {
    final previous = _nicknameUpdateTail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // 前一项失败不能阻断后续改名。
      }
      return _performNicknameUpdate(payload);
    }();
    _nicknameUpdateTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Object?> _performNicknameUpdate(Map<String, Object?> payload) async {
    final callback = onNicknameUpdate;
    final rawResult = callback == null
        ? await _updateRemoteNickname(payload)
        : await callback(payload);
    if (rawResult is! Map) {
      throw const SdkCommandException('nickname_update_failed', '昵称更新结果无效');
    }
    final result = Map<String, Object?>.from(rawResult);
    final rawSession = result['session'];
    final rawPlayer = result['player'];
    if (rawSession is! Map || rawPlayer is! Map) {
      throw const SdkCommandException('nickname_update_failed', '昵称更新结果缺少玩家资料');
    }
    final session = Map<String, Object?>.from(rawSession);
    final player = Map<String, Object?>.from(rawPlayer);
    final requestedNickname = payload['nickname'];
    final expectedSessionId = payload['sessionId'];
    final playerId = player['id'];
    final updatedNickname = player['nickname'];
    if (session['id'] is! String ||
        (expectedSessionId != null && session['id'] != expectedSessionId) ||
        playerId != userId ||
        requestedNickname is! String ||
        updatedNickname is! String ||
        !_isValidNickname(updatedNickname) ||
        updatedNickname.trim() != requestedNickname.trim()) {
      throw const SdkCommandException('nickname_update_failed', '昵称更新结果无效');
    }
    nickname = updatedNickname.trim();
    return {
      ...result,
      'session': session,
      'player': player,
      'identity': _identityEnvironment(),
    };
  }

  Future<Map<String, Object?>> _updateRemoteNickname(
    Map<String, Object?> payload,
  ) async {
    if (payload.length != 4 ||
        !payload.keys.every(
          const {
            'nickname',
            'sessionId',
            'credentialToken',
            'playerId',
          }.contains,
        )) {
      throw const SdkCommandException('invalid_argument', '远程昵称参数无效');
    }
    final baseUri = coreBaseUri;
    final rawNickname = payload['nickname'];
    final sessionId = payload['sessionId'];
    final credentialToken = payload['credentialToken'];
    final playerId = payload['playerId'];
    if (baseUri == null ||
        rawNickname is! String ||
        !_isValidNickname(rawNickname) ||
        sessionId is! String ||
        sessionId.isEmpty ||
        sessionId.length > 128 ||
        credentialToken is! String ||
        credentialToken.isEmpty ||
        credentialToken.length > 4096 ||
        playerId is! String ||
        playerId != userId) {
      throw const SdkCommandException('invalid_argument', '远程昵称参数无效');
    }
    final previousNickname = nickname;
    final requestedNickname = rawNickname.trim();
    await _persistNickname(requestedNickname);
    nickname = requestedNickname;
    Object? ambiguousError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        return await _commitRemoteNickname(
          baseUri: baseUri,
          sessionId: sessionId,
          credentialToken: credentialToken,
          playerId: playerId,
          nickname: requestedNickname,
        );
      } on _NicknameCommitRejected catch (error) {
        await _restoreNickname(previousNickname);
        throw SdkCommandException('nickname_update_failed', error.message);
      } on Object catch (error) {
        ambiguousError = error;
      }
    }
    try {
      final result = await _readRemoteNicknameState(
        baseUri: baseUri,
        sessionId: sessionId,
        credentialToken: credentialToken,
        playerId: playerId,
      );
      final player = Map<String, Object?>.from(result['player']! as Map);
      final authoritativeNickname = (player['nickname']! as String).trim();
      if (authoritativeNickname == requestedNickname) return result;
      await _persistNickname(authoritativeNickname);
      nickname = authoritativeNickname;
      throw SdkCommandException(
        'nickname_update_failed',
        'Core 未提交昵称更新：${ambiguousError ?? '未知错误'}',
      );
    } on SdkCommandException {
      rethrow;
    } on Object {
      // PATCH 结果不明确且无法读取权威状态时，保留本机意图供重连对账。
      throw const SdkCommandException(
        'nickname_update_pending',
        '昵称已保存在本机，等待与房间重新同步',
      );
    }
  }

  Future<Map<String, Object?>> _commitRemoteNickname({
    required Uri baseUri,
    required String sessionId,
    required String credentialToken,
    required String playerId,
    required String nickname,
  }) async {
    final response = await _httpClient
        .patch(
          baseUri.resolve(
            'v1/sessions/${Uri.encodeComponent(sessionId)}/players/me',
          ),
          headers: {
            'Authorization': 'Bearer $credentialToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'nickname': nickname}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode >= 400 && response.statusCode < 500) {
      throw _NicknameCommitRejected('远程昵称更新失败（HTTP ${response.statusCode}）');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('远程昵称更新结果不明确（HTTP ${response.statusCode}）');
    }
    return _decodeNicknameResult(
      response,
      sessionId: sessionId,
      playerId: playerId,
      nickname: nickname,
    );
  }

  Future<Map<String, Object?>> _readRemoteNicknameState({
    required Uri baseUri,
    required String sessionId,
    required String credentialToken,
    required String playerId,
  }) async {
    final response = await _httpClient
        .get(
          baseUri.resolve('v1/sessions/${Uri.encodeComponent(sessionId)}'),
          headers: {'Authorization': 'Bearer $credentialToken'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('读取 Core 昵称状态失败');
    }
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const FormatException('Core 快照响应过大');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const FormatException('Core 快照响应无效');
    final session = Map<String, Object?>.from(decoded);
    if (session['id'] != sessionId || session['players'] is! List) {
      throw const FormatException('Core 快照身份不匹配');
    }
    Map<String, Object?>? player;
    for (final candidate in session['players']! as List) {
      if (candidate is! Map) continue;
      final normalized = Map<String, Object?>.from(candidate);
      if (normalized['id'] == playerId) {
        player = normalized;
        break;
      }
    }
    final authoritativeNickname = player?['nickname'];
    if (player == null ||
        authoritativeNickname is! String ||
        !_isValidNickname(authoritativeNickname)) {
      throw const FormatException('Core 快照缺少当前玩家');
    }
    return {'session': session, 'player': player};
  }

  Map<String, Object?> _decodeNicknameResult(
    http.Response response, {
    required String sessionId,
    required String playerId,
    required String nickname,
  }) {
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const FormatException('昵称更新响应过大');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const FormatException('昵称更新响应无效');
    final result = Map<String, Object?>.from(decoded);
    final rawSession = result['session'];
    final rawPlayer = result['player'];
    if (rawSession is! Map || rawPlayer is! Map) {
      throw const FormatException('昵称更新响应无效');
    }
    final session = Map<String, Object?>.from(rawSession);
    final player = Map<String, Object?>.from(rawPlayer);
    if (session['id'] != sessionId ||
        player['id'] != playerId ||
        player['nickname'] is! String ||
        (player['nickname']! as String).trim() != nickname) {
      throw const FormatException('昵称更新响应身份不匹配');
    }
    return {'session': session, 'player': player};
  }

  Future<void> _restoreNickname(String value) async {
    try {
      await _persistNickname(value);
    } on Object {
      // 明确失败仍恢复内存身份；持久层在下次保存时修复。
    }
    nickname = value;
  }

  Future<void> _persistNickname(String value) async {
    final callback = onNicknameChanged;
    if (callback != null) {
      await callback(value);
      return;
    }
    final profile = await profileStore.load(
      UserProfile(userId: userId, nickname: nickname),
    );
    if (profile.userId != userId) {
      throw const SdkCommandException('identity_mismatch', '本机身份与当前玩家不一致');
    }
    await profileStore.save(profile.copyWith(nickname: value));
  }

  Map<String, Object?> _identityEnvironment() => {
    'userId': userId,
    'nickname': nickname,
    'source': 'playmesh_app',
  };

  bool _isValidNickname(String value) {
    final normalized = value.trim();
    return normalized.isNotEmpty && normalized.runes.length <= 32;
  }

  Future<void> resetCapabilities() async {
    _trustedUserActivationExpiresAt = null;
    lanHost?.resetDocument();
    final previousRuntime = _capabilityRuntime;
    if (acceptRuntimeGameDeclaration) {
      _runtimeDeclaredCapabilities = List.unmodifiable(declaredCapabilities);
      _capabilityRuntime = CapabilityRuntime(
        registry: capabilityRegistry,
        declaredCapabilities: _runtimeDeclaredCapabilities,
      );
    }
    await previousRuntime.reset();
    await mediaRuntime.reset();
  }

  Future<void> close() async {
    _trustedUserActivationExpiresAt = null;
    lanHost?.resetDocument();
    await _capabilityRuntime.reset();
    await capabilityRegistry.dispose();
    await mediaRuntime.dispose();
    final localBucketSyncGateway = await _localBucketSyncGateway;
    await localBucketSyncGateway?.close();
    if (_ownsHttpClient) _httpClient.close();
  }
}

class _NicknameCommitRejected implements Exception {
  const _NicknameCommitRejected(this.message);

  final String message;
}

const _maxAppBridgeJsonBytes = 4 * 1024 * 1024;

String _encodeAppBridgeMessage(Map<String, Object?> message) {
  final encoded = jsonEncode(message);
  if (utf8.encode(encoded).length > _maxAppBridgeJsonBytes) {
    throw const SdkCommandException('share_links_too_large', '分享链接负载超过 4 MiB');
  }
  return encoded;
}

String _publicAppBridgeError(Object error) {
  if (error is SdkCommandException) {
    return formatPlaymeshDiagnosticError(error);
  }
  if (error is CapabilityOperationException) return error.message;
  final message = error.toString();
  if (utf8.encode(message).length > 1024 ||
      message.contains('inviteToken=') ||
      message.contains('data:image/png;base64,') ||
      RegExp(r'https?://', caseSensitive: false).hasMatch(message)) {
    return 'App SDK 命令执行失败';
  }
  return message;
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
