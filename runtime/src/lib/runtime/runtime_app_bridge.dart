import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_media/app_media_runtime.dart';
import 'app_media/default_app_media_adapters.dart';
import 'capabilities/capability_registry.dart';
import 'capabilities/capability_runtime.dart';
import 'capabilities/default_capability_plugins.dart';
import 'capabilities/web_permission/capability_web_permission.dart';
import 'runtime_display_controller.dart';
import 'runtime_app_local_bucket_store.dart';
import 'runtime_lan_host.dart';
import 'runtime_module_catalog.dart';
import 'runtime_package.dart';
import 'runtime_platform_ui.dart';

typedef RuntimeBridgeSender = Future<void> Function(String message);

final class RuntimeAppBridge {
  static const supportedCommandNames = <String>{
    'app.bootstrap',
    'app.game.configure',
    'app.capabilities.confirm',
    'app.capability.create',
    'app.capability.invoke',
    'app.capability.dispose',
    'app.media.open',
    'app.media.close',
    'app.input.takeover',
    'app.ui.openSharePanel',
    'app.device.fullscreen',
    'app.game.exit',
    'app.identity.syncAvatar',
    'app.identity.updateNickname',
    'app.storage.get',
    'app.storage.set',
    'app.storage.remove',
    'app.storage.clear',
    'app.lan.discover',
    'app.lan.joinDiscovered',
    'app.lan.joinByLink',
    'app.lan.scanQr',
    'app.lan.setPublished',
    'app.lan.getShareLinks',
  };

  factory RuntimeAppBridge({
    required RuntimeGameManifest game,
    required String userId,
    required String nickname,
    required Uri coreBase,
    required RuntimeModuleCatalog modules,
    required RuntimePlatformUiCatalog platformUi,
    required RuntimeDisplayController display,
    required Future<void> Function() onExit,
    Future<String> Function(String nickname)? onNicknameChanged,
    Future<Map<String, Object?>> Function(String nickname)?
    onLocalNicknameUpdate,
    RuntimeLanHost? lanHost,
    Future<void> Function()? onOpenSharePanel,
    void Function()? onInputTakeover,
    RuntimeAppLocalBucketStore? localBucketStore,
    bool autoApproveCapabilities = false,
    http.Client? httpClient,
  }) {
    final mediaRuntime = createDefaultAppMediaRuntime(
      enabledProtocols: modules.mediaProtocols,
    );
    final capabilityRegistry = createDefaultCapabilityRegistry(
      mediaSourceBroker: mediaRuntime,
      enabledCodes: modules.capabilityCodes,
    );
    return RuntimeAppBridge._(
      coreBase,
      game: game,
      userId: userId,
      nickname: nickname,
      modules: modules,
      platformUi: platformUi,
      display: display,
      onExit: onExit,
      onNicknameChanged: onNicknameChanged,
      onLocalNicknameUpdate: onLocalNicknameUpdate,
      lanHost: lanHost,
      onOpenSharePanel: onOpenSharePanel,
      onInputTakeover: onInputTakeover,
      localBucketStore:
          localBucketStore ??
          RuntimeAppLocalBucketStore(gameId: game.id, gameName: game.name),
      autoApproveCapabilities: autoApproveCapabilities,
      mediaRuntime: mediaRuntime,
      capabilityRegistry: capabilityRegistry,
      httpClient: httpClient ?? http.Client(),
      ownsHttpClient: httpClient == null,
    );
  }

  RuntimeAppBridge._(
    this._coreBase, {
    required this.game,
    required this.userId,
    required this.nickname,
    required this.modules,
    required this.platformUi,
    required this.display,
    required this.onExit,
    required this.onNicknameChanged,
    required this.onLocalNicknameUpdate,
    required this.lanHost,
    required this.onOpenSharePanel,
    required this.onInputTakeover,
    required this.localBucketStore,
    required this.autoApproveCapabilities,
    required this.mediaRuntime,
    required this.capabilityRegistry,
    required this._httpClient,
    required this._ownsHttpClient,
  }) : _runtimeDeclaredCapabilities = List.unmodifiable(
         game.requiredCapabilities,
       ),
       _capabilityRuntime = CapabilityRuntime(
         registry: capabilityRegistry,
         declaredCapabilities: game.requiredCapabilities,
       );

  static const trustedUserActivationLifetime = Duration(seconds: 2);
  static const _maxBridgeJsonBytes = 4 * 1024 * 1024;

  final RuntimeGameManifest game;
  final String userId;
  String nickname;
  Uri _coreBase;
  String _playerSource = 'lan_app';
  AppWebPermissionRole _webPermissionRole = AppWebPermissionRole.authority;
  bool _acceptRuntimeGameDeclaration = false;
  List<String> _runtimeDeclaredCapabilities;
  final RuntimeModuleCatalog modules;
  final RuntimePlatformUiCatalog platformUi;
  final RuntimeDisplayController display;
  final Future<void> Function() onExit;
  final Future<String> Function(String nickname)? onNicknameChanged;
  final Future<Map<String, Object?>> Function(String nickname)?
  onLocalNicknameUpdate;
  final RuntimeLanHost? lanHost;
  final Future<void> Function()? onOpenSharePanel;
  final void Function()? onInputTakeover;
  final RuntimeAppLocalBucketStore localBucketStore;
  final bool autoApproveCapabilities;
  final AppMediaRuntime mediaRuntime;
  final CapabilityRegistry capabilityRegistry;
  late CapabilityRuntime _capabilityRuntime;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  Future<void> _nicknameUpdateTail = Future<void>.value();
  DateTime? _trustedUserActivationExpiresAt;
  bool _closed = false;

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
  }) => capabilityRegistry.authorizeWebPermissions(
    resources: resources,
    declaredCapabilities: _runtimeDeclaredCapabilities,
    role: _webPermissionRole,
    sourceUri: sourceUri,
    isUserInitiated: isUserInitiated,
  );

  Future<void> handle(String rawMessage, RuntimeBridgeSender send) async {
    String? requestId;
    try {
      if (utf8.encode(rawMessage).length > _maxBridgeJsonBytes) {
        throw const RuntimeAppSdkException(
          'invalid_argument',
          'App SDK 命令超过 4 MiB',
        );
      }
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) throw const FormatException('App SDK 命令必须是对象');
      final command = Map<String, Object?>.from(decoded);
      final rawRequestId = command['requestId'];
      if (rawRequestId != null &&
          (rawRequestId is! String ||
              rawRequestId.isEmpty ||
              utf8.encode(rawRequestId).length > 256)) {
        throw const RuntimeAppSdkException('invalid_argument', 'requestId 无效');
      }
      requestId = rawRequestId as String?;
      final name = command['command'];
      if (name is! String || name.isEmpty || name.length > 128) {
        throw const FormatException('App SDK command 无效');
      }
      final rawPayload = command['payload'];
      if (rawPayload is! Map) {
        throw const RuntimeAppSdkException('invalid_argument', 'payload 必须是对象');
      }
      final payload = Map<String, Object?>.from(rawPayload);
      final rawSdkVersion = command['sdkVersion'];
      if (rawSdkVersion != null && rawSdkVersion is! String) {
        throw const RuntimeAppSdkException(
          'invalid_argument',
          'sdkVersion 必须是字符串',
        );
      }
      final sdkVersion = rawSdkVersion as String? ?? game.appSdkVersion;
      if (sdkVersion != '3.2.0' && sdkVersion != '3.3.0') {
        throw RuntimeAppSdkException(
          'sdk_unsupported',
          'Runtime 不支持 App SDK $sdkVersion',
        );
      }
      final executed = await _execute(name, payload, sdkVersion, send);
      final response = executed is RuntimeAppCommandResponse
          ? executed
          : RuntimeAppCommandResponse(result: executed);
      await send(
        _encodeBridgeMessage({
          'type': 'app.command.result',
          'requestId': requestId,
          'result': response.result,
        }),
      );
      final afterResponse = response.afterResponse;
      if (afterResponse != null) {
        unawaited(
          Future<void>.sync(afterResponse).catchError((Object error) {
            debugPrint('Runtime 延迟执行 App SDK 命令失败: ${_publicError(error)}');
          }),
        );
      }
    } on Object catch (error) {
      await send(
        _encodeBridgeMessage({
          'type': 'app.command.error',
          'requestId': requestId,
          if (error is RuntimeAppSdkException) 'code': error.code,
          if (error is RuntimeLanException) 'code': error.code,
          'error': _publicError(error),
        }),
      );
    }
  }

  Future<Object?> _execute(
    String name,
    Map<String, Object?> payload,
    String sdkVersion,
    RuntimeBridgeSender send,
  ) async {
    switch (name) {
      case 'app.bootstrap':
        _requirePayload(payload, const {});
        return _environment(sdkVersion);
      case 'app.game.configure':
        return _configureGame(payload);
      case 'app.capabilities.confirm':
        _requirePayload(payload, const {});
        _capabilityRuntime.confirm();
        return null;
      case 'app.capability.create':
        return _capabilityRuntime.create(
          payload,
          (message) => send(_encodeBridgeMessage(message)),
        );
      case 'app.capability.invoke':
        return _capabilityRuntime.invoke(payload);
      case 'app.capability.dispose':
        await _capabilityRuntime.disposeInstance(payload);
        return null;
      case 'app.media.open':
        return mediaRuntime.open(payload);
      case 'app.media.close':
        await mediaRuntime.close(payload);
        return null;
      case 'app.input.takeover':
        _requirePayload(payload, const {});
        onInputTakeover?.call();
        return null;
      case 'app.ui.openSharePanel':
        if (_webPermissionRole != AppWebPermissionRole.authority) {
          throw const RuntimeAppSdkException(
            'not_authority',
            '只有当前 Authority 游戏可以打开分享界面',
          );
        }
        _requireUserActivation(payload, action: '打开分享界面');
        final callback = onOpenSharePanel;
        if (callback == null) {
          throw const RuntimeAppSdkException(
            'ui_unavailable',
            '当前 Runtime 分享界面不可用',
          );
        }
        await callback();
        return null;
      case 'app.device.fullscreen':
        return _setFullscreen(payload);
      case 'app.game.exit':
        _requirePayload(payload, const {});
        Timer.run(() => unawaited(onExit()));
        return null;
      case 'app.identity.syncAvatar':
        return null;
      case 'app.identity.updateNickname':
        return _updateNickname(payload);
      case 'app.storage.get':
        _requirePayload(payload, const {'bucket', 'key'});
        return _readLocalBucket(payload);
      case 'app.storage.set':
        _requirePayload(payload, const {'bucket', 'key', 'value'});
        await _writeLocalBucket(payload);
        return null;
      case 'app.storage.remove':
        _requirePayload(payload, const {'bucket', 'key'});
        await _removeLocalBucketValue(payload);
        return null;
      case 'app.storage.clear':
        _requirePayload(payload, const {'bucket'});
        await _clearLocalBucket(payload);
        return null;
      case 'app.lan.discover':
        _requirePayload(payload, const {});
        final games = await _requireLanHost().discoverGames();
        return [
          for (final game in games)
            {
              'instanceId': game.instanceId,
              'gameId': game.gameId,
              'name': game.name,
              'host': game.host,
            },
        ];
      case 'app.lan.joinDiscovered':
        _requireAllowedPayload(payload, const {'instanceId', 'userActivation'});
        _requireUserActivation(payload, action: '加入游戏');
        final instanceId = payload['instanceId'];
        if (instanceId is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(instanceId)) {
          throw const RuntimeAppSdkException(
            'invalid_argument',
            'instanceId 无效',
          );
        }
        final action = await _requireLanHost().prepareDiscoveredJoin(
          instanceId,
        );
        return RuntimeAppCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.joinByLink':
        _requireAllowedPayload(payload, const {
          'invitationUrl',
          'userActivation',
        });
        _requireUserActivation(payload, action: '加入游戏');
        final invitationUrl = payload['invitationUrl'];
        if (invitationUrl is! String || invitationUrl.trim().isEmpty) {
          throw const RuntimeAppSdkException(
            'invalid_argument',
            'invitationUrl 必须是非空字符串',
          );
        }
        final action = await _requireLanHost().prepareInvitationJoin(
          invitationUrl,
        );
        return RuntimeAppCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.scanQr':
        _requireAllowedPayload(payload, const {'userActivation'});
        _requireUserActivation(payload, action: '扫码加入游戏');
        final action = await _requireLanHost().prepareQrJoin();
        return RuntimeAppCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.setPublished':
        _requirePayload(payload, const {});
        await _requireLanHost().setPublished();
        return null;
      case 'app.lan.getShareLinks':
        _requirePayload(payload, const {});
        final links = await _requireLanHost().getShareLinks();
        return [
          for (final link in links)
            {
              'url': link.url.toString(),
              'type': link.type,
              'img': 'data:image/png;base64,${base64Encode(link.pngBytes)}',
            },
        ];
      default:
        throw RuntimeAppSdkException(
          'command_unsupported',
          'Runtime 尚未实现 App SDK 命令: $name',
        );
    }
  }

  Map<String, Object?> _environment(String sdkVersion) => {
    '_playmeshPlatformUi': platformUiConfiguration,
    '_playmeshAutoApproveCapabilities': autoApproveCapabilities,
    'available': true,
    'sdkVersion': sdkVersion,
    'identity': _identityEnvironment(),
    'runtime': {
      'locale': Platform.localeName.replaceAll('_', '-'),
      'coreBase': _coreBase.toString(),
      'playerSource': _playerSource,
    },
    'capabilityRegistry': [
      for (final plugin in capabilityRegistry.descriptors) plugin.toJson(),
    ],
    'device': _deviceEnvironment(),
  };

  Map<String, Object?> _identityEnvironment() => {
    'userId': userId,
    'nickname': nickname,
    'source': 'playmesh_runtime',
  };

  Map<String, Object?> get platformUiConfiguration =>
      platformUi.appConfiguration(
        locale: Platform.localeName,
        showShareAction:
            onOpenSharePanel != null &&
            _webPermissionRole == AppWebPermissionRole.authority,
      );

  Future<Map<String, Object?>> _configureGame(
    Map<String, Object?> payload,
  ) async {
    final declared = payload['declaredCapabilities'];
    if (declared is! List || declared.any((value) => value is! String)) {
      throw const RuntimeAppSdkException(
        'invalid_argument',
        'declaredCapabilities 必须是字符串数组',
      );
    }
    final requested = declared.cast<String>().toSet();
    final packaged = game.requiredCapabilities.toSet();
    if (!_acceptRuntimeGameDeclaration &&
        (requested.length != packaged.length ||
            !requested.containsAll(packaged))) {
      throw const RuntimeAppSdkException(
        'capability_manifest_mismatch',
        '运行时能力声明与内置 capabilities.json 不一致',
      );
    }
    final normalized = List<String>.unmodifiable(requested);
    if (!_sameStringSet(_runtimeDeclaredCapabilities, normalized)) {
      await _capabilityRuntime.reset();
      await mediaRuntime.reset();
      _runtimeDeclaredCapabilities = normalized;
      _capabilityRuntime = CapabilityRuntime(
        registry: capabilityRegistry,
        declaredCapabilities: _runtimeDeclaredCapabilities,
      );
    }
    return {
      'capabilityRegistry': [
        for (final plugin in capabilityRegistry.descriptors) plugin.toJson(),
      ],
      'device': _deviceEnvironment(),
    };
  }

  Map<String, Object?> _deviceEnvironment() => {
    'platform': Platform.operatingSystem,
    'capabilities': _capabilityRuntime.availableDeclaredCodes.toList(),
    'declaredCapabilities': _runtimeDeclaredCapabilities,
  };

  Future<Map<String, Object?>> _updateRemoteNickname(
    Map<String, Object?> payload,
  ) async {
    _requirePayload(payload, const {
      'nickname',
      'sessionId',
      'credentialToken',
      'playerId',
    });
    if (!_acceptRuntimeGameDeclaration) {
      throw const RuntimeAppSdkException(
        'nickname_update_unavailable',
        '当前页面不支持修改远程玩家昵称',
      );
    }
    final rawNickname = payload['nickname'];
    final sessionId = payload['sessionId'];
    final credentialToken = payload['credentialToken'];
    final playerId = payload['playerId'];
    if (rawNickname is! String ||
        rawNickname.trim().isEmpty ||
        rawNickname.trim().runes.length > 32 ||
        sessionId is! String ||
        sessionId.isEmpty ||
        sessionId.length > 128 ||
        credentialToken is! String ||
        credentialToken.isEmpty ||
        credentialToken.length > 4096 ||
        playerId is! String ||
        playerId.isEmpty ||
        playerId.length > 128) {
      throw const RuntimeAppSdkException('invalid_argument', '远程玩家昵称参数无效');
    }
    final persist = onNicknameChanged;
    if (persist == null) {
      throw const RuntimeAppSdkException(
        'nickname_update_unavailable',
        '当前 Runtime 不支持持久化玩家昵称',
      );
    }
    final previousNickname = nickname;
    final requestedNickname = await persist(rawNickname.trim());
    nickname = requestedNickname;
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final response = await _httpClient
            .patch(
              _coreBase.resolve(
                'v1/sessions/${Uri.encodeComponent(sessionId)}/players/me',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $credentialToken',
              },
              body: jsonEncode({'nickname': requestedNickname}),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode >= 400 && response.statusCode < 500) {
          await _restoreNickname(persist, previousNickname);
          throw const RuntimeAppSdkException(
            'nickname_update_failed',
            '远程房间拒绝了昵称修改',
          );
        }
        final decoded = _decodeRemoteObject(response);
        final committed = decoded == null
            ? null
            : _validatedRemoteUpdate(
                decoded,
                expectedSessionId: sessionId,
                expectedPlayerId: playerId,
                expectedNickname: requestedNickname,
              );
        if (committed != null) {
          return {
            'session': committed.session,
            'player': committed.player,
            'identity': _identityEnvironment(),
          };
        }
        lastError = const FormatException('远程昵称响应无效');
      } on RuntimeAppSdkException {
        rethrow;
      } on Object catch (error) {
        lastError = error;
      }
    }

    try {
      final response = await _httpClient
          .get(
            _coreBase.resolve('v1/sessions/${Uri.encodeComponent(sessionId)}'),
            headers: {'Authorization': 'Bearer $credentialToken'},
          )
          .timeout(const Duration(seconds: 10));
      final snapshot = _decodeRemoteObject(response);
      if (snapshot != null && snapshot['id'] == sessionId) {
        final player = _findRemotePlayer(snapshot, playerId);
        final authoritativeNickname = player?['nickname'];
        if (authoritativeNickname is String &&
            authoritativeNickname.trim().isNotEmpty &&
            authoritativeNickname.runes.length <= 32) {
          if (authoritativeNickname == requestedNickname) {
            return {
              'session': snapshot,
              'player': player,
              'identity': _identityEnvironment(),
            };
          }
          nickname = await persist(authoritativeNickname);
          throw const RuntimeAppSdkException(
            'nickname_update_failed',
            '房间未接受该昵称，已恢复房间中的昵称',
          );
        }
      }
    } on RuntimeAppSdkException {
      rethrow;
    } on Object {
      // PATCH 超时不代表 Core 未提交；GET 也失败时保留本地意图。
    }
    throw RuntimeAppSdkException(
      'nickname_update_pending',
      '昵称已保存在本机，等待与房间重新同步',
      cause: lastError,
    );
  }

  Future<void> _restoreNickname(
    Future<String> Function(String nickname) persist,
    String previousNickname,
  ) async {
    try {
      nickname = await persist(previousNickname);
    } on Object {
      nickname = previousNickname;
    }
  }

  Future<Map<String, Object?>> _updateNickname(Map<String, Object?> payload) {
    final previous = _nicknameUpdateTail;
    final operation = () async {
      await previous;
      return _performNicknameUpdate(payload);
    }();
    _nicknameUpdateTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Object?> _readLocalBucket(Map<String, Object?> payload) async {
    final bucket = payload['bucket'];
    final key = payload['key'];
    if (bucket is! String || key is! String) {
      throw const RuntimeAppSdkException('invalid_argument', 'App Bucket 参数无效');
    }
    try {
      return await localBucketStore.getData(bucket, key);
    } on FormatException catch (error) {
      throw RuntimeAppSdkException('invalid_argument', error.message);
    }
  }

  Future<void> _writeLocalBucket(Map<String, Object?> payload) async {
    final bucket = payload['bucket'];
    final key = payload['key'];
    if (bucket is! String || key is! String) {
      throw const RuntimeAppSdkException('invalid_argument', 'App Bucket 参数无效');
    }
    try {
      await localBucketStore.setData(bucket, key, payload['value']);
    } on FormatException catch (error) {
      throw RuntimeAppSdkException('invalid_argument', error.message);
    }
  }

  Future<void> _removeLocalBucketValue(Map<String, Object?> payload) async {
    final bucket = payload['bucket'];
    final key = payload['key'];
    if (bucket is! String || key is! String) {
      throw const RuntimeAppSdkException('invalid_argument', 'App Bucket 参数无效');
    }
    try {
      await localBucketStore.removeData(bucket, key);
    } on FormatException catch (error) {
      throw RuntimeAppSdkException('invalid_argument', error.message);
    }
  }

  Future<void> _clearLocalBucket(Map<String, Object?> payload) async {
    final bucket = payload['bucket'];
    if (bucket is! String) {
      throw const RuntimeAppSdkException('invalid_argument', 'App Bucket 参数无效');
    }
    try {
      await localBucketStore.clearData(bucket);
    } on FormatException catch (error) {
      throw RuntimeAppSdkException('invalid_argument', error.message);
    }
  }

  Future<Map<String, Object?>> _performNicknameUpdate(
    Map<String, Object?> payload,
  ) async {
    if (_acceptRuntimeGameDeclaration) {
      return _updateRemoteNickname(payload);
    }
    _requirePayload(payload, const {'nickname'});
    final rawNickname = payload['nickname'];
    if (rawNickname is! String ||
        rawNickname.trim().isEmpty ||
        rawNickname.trim().runes.length > 32) {
      throw const RuntimeAppSdkException('invalid_argument', '玩家昵称参数无效');
    }
    final callback = onLocalNicknameUpdate;
    if (callback == null) {
      throw const RuntimeAppSdkException(
        'nickname_update_unavailable',
        '当前 Runtime 不支持修改本机玩家昵称',
      );
    }
    final requestedNickname = rawNickname.trim();
    final result = await callback(requestedNickname);
    final rawSession = result['session'];
    final rawPlayer = result['player'];
    if (rawSession is! Map || rawPlayer is! Map) {
      throw const RuntimeAppSdkException(
        'nickname_update_failed',
        '本机昵称更新结果无效',
      );
    }
    final session = Map<String, Object?>.from(rawSession);
    final player = Map<String, Object?>.from(rawPlayer);
    final committedNickname = player['nickname'];
    final sessionId = session['id'];
    final playerId = player['id'];
    final sessionPlayer = playerId is String
        ? _findRemotePlayer(session, playerId)
        : null;
    if (sessionId is! String ||
        sessionId.isEmpty ||
        playerId is! String ||
        playerId.isEmpty ||
        committedNickname != requestedNickname ||
        sessionPlayer?['nickname'] != requestedNickname) {
      throw const RuntimeAppSdkException(
        'nickname_update_failed',
        '本机昵称更新结果无效',
      );
    }
    nickname = requestedNickname;
    return {
      ...result,
      'session': session,
      'player': player,
      'identity': _identityEnvironment(),
    };
  }

  Future<Object?> _setFullscreen(Map<String, Object?> payload) async {
    final enabled = payload['enabled'];
    if (enabled is! bool) throw const FormatException('enabled 必须是布尔值');
    final orientation = payload['orientation'];
    if (!enabled && orientation != null) {
      throw const FormatException('退出全屏时不能声明 orientation');
    }
    if (orientation != null &&
        orientation != 'portrait' &&
        orientation != 'landscape') {
      throw const FormatException('orientation 必须是 portrait 或 landscape');
    }
    await display.setFullscreen(enabled, orientation: orientation as String?);
    return null;
  }

  RuntimeLanHost _requireLanHost() =>
      lanHost ??
      (throw const RuntimeAppSdkException(
        'game_context_unavailable',
        '当前游戏上下文不可用',
      ));

  void _requireUserActivation(
    Map<String, Object?> payload, {
    required String action,
  }) {
    if (payload['userActivation'] != true || !_consumeUserActivation()) {
      throw RuntimeAppSdkException(
        'user_activation_required',
        '$action 需要当前用户操作',
      );
    }
  }

  Future<void> resetDocument() async {
    _trustedUserActivationExpiresAt = null;
    lanHost?.resetDocument();
    await _capabilityRuntime.reset();
    await mediaRuntime.reset();
  }

  void enterRemoteMode({required Uri coreBase, required String playerSource}) {
    if (coreBase.scheme != 'http' ||
        !coreBase.isAbsolute ||
        coreBase.host.isEmpty ||
        !{'lan_app', 'server'}.contains(playerSource)) {
      throw const RuntimeAppSdkException(
        'game_context_unavailable',
        '远程游戏上下文无效',
      );
    }
    _coreBase = coreBase;
    _playerSource = playerSource;
    _webPermissionRole = AppWebPermissionRole.joiner;
    _acceptRuntimeGameDeclaration = true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _trustedUserActivationExpiresAt = null;
    await _nicknameUpdateTail;
    lanHost?.resetDocument();
    await _capabilityRuntime.reset();
    await capabilityRegistry.dispose();
    await mediaRuntime.dispose();
    await lanHost?.close();
    if (_ownsHttpClient) _httpClient.close();
  }

  String _encodeBridgeMessage(Map<String, Object?> message) {
    final encoded = jsonEncode(message);
    if (utf8.encode(encoded).length > _maxBridgeJsonBytes) {
      throw const RuntimeAppSdkException(
        'response_too_large',
        'App SDK 响应超过 4 MiB',
      );
    }
    return encoded;
  }
}

final class RuntimeAppCommandResponse {
  const RuntimeAppCommandResponse({this.result, this.afterResponse});

  final Object? result;
  final Future<void> Function()? afterResponse;
}

final class RuntimeAppSdkException implements Exception {
  const RuntimeAppSdkException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

String _publicError(Object error) {
  if (error case RuntimeAppSdkException(:final message)) return message;
  if (error case RuntimeLanException(:final message)) return message;
  final message = error.toString();
  if (utf8.encode(message).length > 1024 ||
      message.contains('inviteToken=') ||
      message.contains('data:image/png;base64,') ||
      RegExp(r'https?://', caseSensitive: false).hasMatch(message)) {
    return 'App SDK 命令执行失败';
  }
  return message;
}

void _requirePayload(Map<String, Object?> payload, Set<String> expectedKeys) {
  if (payload.length != expectedKeys.length ||
      !payload.keys.every(expectedKeys.contains)) {
    throw const RuntimeAppSdkException('invalid_argument', 'App SDK 命令参数无效');
  }
}

void _requireAllowedPayload(
  Map<String, Object?> payload,
  Set<String> allowedKeys,
) {
  if (!payload.keys.every(allowedKeys.contains)) {
    throw const RuntimeAppSdkException('invalid_argument', 'App SDK 命令参数无效');
  }
}

bool _sameStringSet(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

Map<String, Object?>? _decodeRemoteObject(http.Response response) {
  if (response.statusCode < 200 ||
      response.statusCode >= 300 ||
      response.bodyBytes.length > 1024 * 1024) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on Object {
    return null;
  }
}

({Map<String, Object?> session, Map<String, Object?> player})?
_validatedRemoteUpdate(
  Map<String, Object?> payload, {
  required String expectedSessionId,
  required String expectedPlayerId,
  required String expectedNickname,
}) {
  final rawSession = payload['session'];
  final rawPlayer = payload['player'];
  if (rawSession is! Map || rawPlayer is! Map) return null;
  final session = Map<String, Object?>.from(rawSession);
  final player = Map<String, Object?>.from(rawPlayer);
  if (session['id'] != expectedSessionId ||
      player['id'] != expectedPlayerId ||
      player['nickname'] != expectedNickname ||
      _findRemotePlayer(session, expectedPlayerId)?['nickname'] !=
          expectedNickname) {
    return null;
  }
  return (session: session, player: player);
}

Map<String, Object?>? _findRemotePlayer(
  Map<String, Object?> session,
  String playerId,
) {
  final players = session['players'];
  if (players is! List) return null;
  for (final candidate in players) {
    if (candidate is Map && candidate['id'] == playerId) {
      return Map<String, Object?>.from(candidate);
    }
  }
  return null;
}
