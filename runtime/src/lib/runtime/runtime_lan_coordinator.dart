import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:http/http.dart' as http;

import '../core/game_web/game_invitation.dart';
import '../core/game_web/game_invitation_inspector.dart';
import '../core/game_web/game_join_coordinator.dart';
import '../core/game_web/game_share_link_snapshot.dart';
import '../core/game_web/local_tunnel_gateway.dart';
import '../core/game_web/share_qr_code_encoder.dart';
import '../core/network/lan_game_advertisement.dart';
import '../core/network/lan_game_discovery_service.dart';
import '../core/network/lan_game_presence.dart';
import '../core/relay/relay_tunnel.dart';
import 'runtime_asset_server.dart';
import 'runtime_lan_host.dart';
import 'runtime_package.dart';
import 'runtime_session.dart';

typedef RuntimeInvitationScanner = Future<String?> Function();
typedef RuntimeRemoteNavigator = Future<void> Function(Uri uri);
typedef RuntimeRemotePreparation =
    Future<void> Function(Uri coreBase, String playerSource);
typedef RuntimeRelayHostStarter =
    Future<RelayHostSession> Function({
      required Uri coreBaseUri,
      required String sessionId,
      required Uri serverBaseUri,
      required String sourceToken,
      required String hostPath,
      required String clientPath,
      required Uri authorityWebBaseUri,
      required Uri authorityCoreBaseUri,
      required Uri authorityEntryUri,
      required int maxConnectionsPerTunnel,
    });

final class RuntimeBundledRelayPresentation {
  const RuntimeBundledRelayPresentation({
    required this.name,
    required this.latencyMilliseconds,
  });

  final String? name;
  final int latencyMilliseconds;
}

/// Runtime 自己持有 LAN/Relay 生命周期，但复用与主 App 相同的协议边界。
final class RuntimeLanCoordinator implements RuntimeLanHost {
  RuntimeLanCoordinator({
    required this.game,
    required this.session,
    required this.server,
    required this.coreControlBaseUri,
    required this.qrAvailable,
    required this.scanQr,
    required this.beforeRemoteNavigation,
    required this.navigate,
    LanGameDiscoveryService? discoveryService,
    GameInvitationInspector? inspector,
    http.Client? relayHttpClient,
    RuntimeRelayHostStarter? relayHostStarter,
    this.discoveryDuration = const Duration(seconds: 2),
  }) : _discovery = discoveryService ?? LanGameDiscoveryService(),
       _ownsDiscovery = discoveryService == null,
       _inspector =
           inspector ??
           DefaultGameInvitationInspector(coreBaseUri: coreControlBaseUri),
       _ownsInspector = inspector == null,
       _relayHttpClient = relayHttpClient ?? http.Client(),
       _ownsRelayHttpClient = relayHttpClient == null,
       _relayHostStarter = relayHostStarter ?? startRelayHostSession {
    _joinCoordinator = GameJoinCoordinator(
      inspector: _inspector,
      discoveredGames: _discovery,
    );
  }

  final RuntimeGameManifest game;
  final RuntimeSessionConnection? session;
  final RuntimeAssetServer server;
  final Uri coreControlBaseUri;
  final bool qrAvailable;
  final RuntimeInvitationScanner scanQr;
  final RuntimeRemotePreparation beforeRemoteNavigation;
  final RuntimeRemoteNavigator navigate;
  final LanGameDiscoveryService _discovery;
  final bool _ownsDiscovery;
  final GameInvitationInspector _inspector;
  final bool _ownsInspector;
  final http.Client _relayHttpClient;
  final bool _ownsRelayHttpClient;
  final RuntimeRelayHostStarter _relayHostStarter;
  final Duration discoveryDuration;
  final ShareQrCodeEncoder _qrEncoder = ShareQrCodeEncoder();
  late final GameJoinCoordinator _joinCoordinator;
  final Set<String> _discoveredInstances = <String>{};
  LanGameDiscoveryLease? _discoveryLease;
  Future<LanGameDiscoveryLease>? _discoveryStartOperation;
  Future<void>? _discoveryReleaseOperation;
  StreamSubscription<LanGameDiscoverySnapshot>? _discoverySubscription;
  LanGameRegistrationLease? _registration;
  StreamSubscription<Map<String, Object?>>? _sessionSubscription;
  LocalTunnelGateway? _webGateway;
  LocalTunnelGateway? _coreGateway;
  RelayClientSession? _relayClientSession;
  RelayHostSession? _relayHostSession;
  RuntimeBundledRelayPresentation? _bundledRelayPresentation;
  Future<void>? _relayConnectOperation;
  int _documentGeneration = 0;
  int _shareGeneration = 0;
  bool _navigationStarted = false;
  bool _remoteMode = false;
  bool _closed = false;

  RuntimeBundledRelayPresentation? get bundledRelayPresentation {
    final relay = _relayHostSession;
    if (relay == null || relay.status == RelayConnectionStatus.disconnected) {
      return null;
    }
    return _bundledRelayPresentation;
  }

  @override
  Future<List<RuntimeLanDiscoveredGame>> discoverGames() async {
    _requireActive();
    final generation = _documentGeneration;
    final alreadyActive = _discoveryLease != null;
    late final LanGameDiscoveryLease lease;
    try {
      lease = await _acquireDiscoveryLease(generation);
      if (!alreadyActive && lease.current.games.isEmpty) {
        await Future<void>.delayed(discoveryDuration);
      }
    } on Object {
      throw const RuntimeLanException('discovery_unavailable', '局域网发现不可用');
    }
    _checkGeneration(generation);
    final snapshot = lease.current;
    if (snapshot.state != LanGameDiscoveryState.ready) {
      throw const RuntimeLanException('discovery_unavailable', '局域网发现不可用');
    }
    final games = _visibleGames(snapshot);
    _applyDiscoverySnapshot(snapshot);
    return [
      for (final item in games)
        RuntimeLanDiscoveredGame(
          instanceId: item.instanceId,
          gameId: item.gameId,
          name: item.name,
          host: item.host,
        ),
    ];
  }

  @override
  Future<RuntimeLanJoinAction> prepareDiscoveredJoin(String instanceId) {
    _requireActive();
    if (!_discoveredInstances.contains(instanceId)) {
      throw const RuntimeLanException('discovery_not_found', '发现的游戏已经失效');
    }
    return _prepareJoin(
      (context) =>
          _joinCoordinator.prepareDiscovered(instanceId, context: context),
    );
  }

  @override
  Future<RuntimeLanJoinAction> prepareInvitationJoin(String invitationUrl) {
    _requireActive();
    return _prepareJoin(
      (context) =>
          _joinCoordinator.prepareLink(invitationUrl, context: context),
    );
  }

  @override
  Future<RuntimeLanJoinAction> prepareQrJoin() async {
    _requireActive();
    if (!qrAvailable) {
      throw const RuntimeLanException(
        'scanner_unavailable',
        '当前 Runtime 未安装扫码模块',
      );
    }
    final raw = await scanQr();
    _requireActive();
    if (raw == null) {
      throw const RuntimeLanException('cancelled', '用户已取消操作');
    }
    return prepareInvitationJoin(raw);
  }

  Future<RuntimeLanJoinAction> _prepareJoin(
    Future<RemoteGameLaunch> Function(GameJoinContext context) prepare,
  ) async {
    final generation = _documentGeneration;
    try {
      final launch = await prepare(
        GameJoinContext(
          expectedGameId: game.id,
          selfInstanceId: _registration?.instanceId,
          isSelfInvitation: _isSelfInvitation,
          isCancelled: () => !_isCurrent(generation),
        ),
      );
      try {
        _checkGeneration(generation);
      } on Object {
        await launch.close();
        rethrow;
      }
      return RuntimeLanJoinAction(() async {
        try {
          await _navigateRemote(launch, generation);
        } finally {
          await launch.close();
        }
      });
    } on GameJoinException catch (error, stackTrace) {
      throw RuntimeLanException(
        error.code,
        error.message,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'prepare_join'},
      );
    }
  }

  Future<void> _navigateRemote(RemoteGameLaunch launch, int generation) async {
    _checkGeneration(generation);
    if (_navigationStarted) return;
    _navigationStarted = true;
    try {
      final resolvedEntryPath = launch.resolvedEntryPath;
      if (resolvedEntryPath != null &&
          !_isControlledPreparedEntryPath(resolvedEntryPath)) {
        throw const FormatException('Runtime 游戏受控入口地址无效');
      }
      await _sessionSubscription?.cancel();
      _sessionSubscription = null;
      await _releaseDiscoveryLease();
      await _registration?.close();
      _registration = null;
      await _relayClientSession?.close();
      _relayClientSession = null;
      await _webGateway?.close();
      await _coreGateway?.close();
      _webGateway = null;
      _coreGateway = null;
      late final Uri target;
      late final Uri remoteCoreBase;
      late final String playerSource;
      if (launch.usesRelay) {
        final relaySession =
            launch.takeRelayClientSession() ??
            await startRelayClientSession(
              coreBaseUri: coreControlBaseUri,
              invitationUri: launch.entryUri,
            );
        _relayClientSession = relaySession;
        // 预检的 HttpOnly Cookie 属于 Dart HTTP 客户端，不能交给 Runtime
        // WebView。复用同一个 Relay 会话，但仍从本机邀请入口进入，让 WebView
        // 在自己的 Cookie 仓库中完成换票。
        target = relaySession.webGateway.localEntryUri;
        remoteCoreBase = relaySession.coreGateway.localBaseUri;
        playerSource = 'server';
      } else {
        final authorityBase = Uri(
          scheme: 'http',
          host: launch.entryUri.host,
          port: launch.entryUri.hasPort ? launch.entryUri.port : null,
          path: '/',
        );
        final webGateway = await startLocalTunnelGateway(
          targetBaseUri: authorityBase,
        );
        _webGateway = webGateway;
        final coreGateway = await startLocalUpgradeTunnelGateway(
          targetBaseUri: authorityBase,
          path: playmeshCoreTunnelPath,
          headers: {playmeshShareTokenHeader: launch.invitation.inviteToken},
        );
        _coreGateway = coreGateway;
        target = webGateway.localBaseUri.replace(
          path: launch.entryUri.path,
          fragment: launch.entryUri.fragment,
        );
        remoteCoreBase = coreGateway.localBaseUri;
        playerSource = 'lan_app';
      }
      server.revokeSharing();
      await beforeRemoteNavigation(remoteCoreBase, playerSource);
      _remoteMode = true;
      await navigate(target);
    } on Object {
      _navigationStarted = false;
      await _relayClientSession?.close();
      _relayClientSession = null;
      await _webGateway?.close();
      await _coreGateway?.close();
      _webGateway = null;
      _coreGateway = null;
      rethrow;
    }
  }

  @override
  Future<void> setPublished() async {
    _requireAuthority();
    if (_registration == null) {
      final advertisement = LanGameAdvertisement.create(
        gameId: game.id,
        name: game.name,
        inviteToken: server.invitationToken,
        presence: _presence(),
      );
      try {
        _registration = await _discovery.register(
          advertisement: advertisement,
          port: server.port,
        );
      } on Object {
        throw const RuntimeLanException('publish_unavailable', '当前网络无法发布局域网游戏');
      }
      final currentSession = session;
      if (currentSession != null) {
        _sessionSubscription ??= currentSession.messages.listen((_) {
          final registration = _registration;
          if (registration != null) {
            unawaited(
              registration.updatePresence(_presence()).catchError((_) {}),
            );
          }
        });
      }
    }
    await _connectConfiguredRelayBestEffort();
  }

  Future<void> _connectConfiguredRelayBestEffort() async {
    if (session == null || server.game.relayServer == null) return;
    final existing = _relayHostSession;
    if (existing != null &&
        existing.status != RelayConnectionStatus.disconnected) {
      return;
    }
    final active = _relayConnectOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _connectConfiguredRelay().whenComplete(() {
      if (identical(_relayConnectOperation, operation)) {
        _relayConnectOperation = null;
      }
    });
    _relayConnectOperation = operation;
    try {
      await operation;
    } on Object {
      // 内置中转不可用时仍保留已经建立的局域网分享。
    }
  }

  Future<void> _connectConfiguredRelay() async {
    await _relayHostSession?.close();
    _relayHostSession = null;
    _bundledRelayPresentation = null;
    final configured = server.game.relayServer;
    if (configured == null) return;
    try {
      final handshake = await _readRelayDeclaration(configured);
      final declaration = handshake.declaration;
      final token = configured.queryParameters['token'] ?? '';
      final relay = await _relayHostStarter(
        coreBaseUri: coreControlBaseUri,
        sessionId: session!.sessionId,
        serverBaseUri: declaration.publicBaseUrl,
        sourceToken: token,
        hostPath: declaration.hostPath,
        clientPath: declaration.clientPath,
        authorityWebBaseUri: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
        ),
        authorityCoreBaseUri: session!.coreBase,
        authorityEntryUri: server.loopbackInvitationUri,
        maxConnectionsPerTunnel: declaration.maxConnectionsPerTunnel,
      );
      if (relay.status == RelayConnectionStatus.disconnected) {
        await relay.close();
        throw const RuntimeLanException('relay_unavailable', '内置中转服务不可用');
      }
      _relayHostSession = relay;
      _bundledRelayPresentation = RuntimeBundledRelayPresentation(
        name: handshake.name,
        latencyMilliseconds: handshake.latencyMilliseconds,
      );
      return;
    } on Object catch (error, stackTrace) {
      _logRuntimeRelayException(
        'host.connect',
        error,
        stackTrace,
        configured: configured,
      );
    }
    throw const RuntimeLanException('relay_unavailable', '内置中转服务不可用');
  }

  Future<_RuntimeRelayHandshake> _readRelayDeclaration(Uri configured) async {
    final origin = Uri(
      scheme: configured.scheme,
      host: configured.host,
      port: configured.hasPort ? configured.port : null,
    );
    final token = configured.queryParameters['token'] ?? '';
    final stopwatch = Stopwatch()..start();
    late final http.Response response;
    try {
      response = await _relayHttpClient
          .get(
            origin.resolve('/apps/info'),
            headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
    } finally {
      stopwatch.stop();
    }
    if (response.statusCode != 200 || response.bodyBytes.length > 64 * 1024) {
      throw FormatException(
        '中转声明不可用: status=${response.statusCode} '
        'body=${utf8.decode(response.bodyBytes, allowMalformed: true)}',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['supportsGameRelay'] != true) {
      throw const FormatException('游戏源没有启用中转');
    }
    final relay = decoded['relay'];
    if (relay is! Map) throw const FormatException('中转声明无效');
    return _RuntimeRelayHandshake(
      declaration: _RuntimeRelayDeclaration.fromJson(
        Map<String, Object?>.from(relay),
      ),
      name: _safeRelayName(decoded['name']),
      latencyMilliseconds: stopwatch.elapsedMilliseconds,
    );
  }

  @override
  Future<List<RuntimeLanShareLink>> getShareLinks() async {
    _requireAuthority();
    try {
      final urls = await server.shareLinks();
      final snapshot = await buildGameShareLinkSnapshot(
        generation: ++_shareGeneration,
        lanUrls: urls,
        wanUrl: _relayHostSession?.status == RelayConnectionStatus.disconnected
            ? null
            : _relayHostSession?.joinUri,
        encoder: _qrEncoder,
      );
      return [
        for (final link in snapshot.links)
          RuntimeLanShareLink(
            url: link.url,
            type: link.type.name,
            pngBytes: Uint8List.fromList(link.pngBytes),
          ),
      ];
    } on GameShareException catch (error, stackTrace) {
      throw RuntimeLanException(
        error.code,
        error.message,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'get_share_links'},
      );
    } on Object catch (error, stackTrace) {
      _logRuntimeRelayException('share.links', error, stackTrace);
      throw const RuntimeLanException('share_unavailable', '当前分享链接不可用');
    }
  }

  void _logRuntimeRelayException(
    String operation,
    Object error,
    StackTrace stackTrace, {
    Uri? configured,
  }) {
    debugPrint(
      '[Runtime][Relay][error] operation=$operation '
      'configured=$configured error=$error',
    );
    debugPrintStack(
      label: '[Runtime][Relay][stack] operation=$operation',
      stackTrace: stackTrace,
    );
  }

  LanGamePresence _presence() {
    final currentSession = session;
    final nickname =
        currentSession?.currentPlayer['nickname'] as String? ?? '本机玩家';
    if (currentSession == null) {
      return LanGamePresence.solo(hostNickname: nickname);
    }
    final players = currentSession.snapshot['players'];
    final connected = players is List
        ? players
              .where((player) => player is Map && player['connected'] == true)
              .length
        : 1;
    final maximum = currentSession.snapshot['maxPlayers'];
    return LanGamePresence.multiplayer(
      hostNickname: nickname,
      playerCount: connected,
      maxPlayers: maximum is int ? maximum : game.maxPlayers,
    );
  }

  bool _isSelfInvitation(GameInvitation invitation) =>
      !invitation.usesRelay &&
      invitation.entryUri.port == server.port &&
      invitation.inviteToken == server.invitationToken;

  void _requireAuthority() {
    _requireActive();
    if (_remoteMode || (session != null && !session!.isAuthority)) {
      throw const RuntimeLanException('not_authority', '当前页面不是本机房主');
    }
  }

  void _requireActive() {
    if (_closed || _navigationStarted) {
      throw const RuntimeLanException('game_context_unavailable', '当前游戏上下文不可用');
    }
  }

  bool _isCurrent(int generation) =>
      !_closed && !_navigationStarted && generation == _documentGeneration;

  void _checkGeneration(int generation) {
    if (!_isCurrent(generation)) {
      throw const RuntimeLanException('operation_cancelled', '游戏退出，操作已取消');
    }
  }

  @override
  void resetDocument() {
    if (_closed) return;
    _documentGeneration += 1;
    _discoveredInstances.clear();
    _navigationStarted = false;
    unawaited(_releaseDiscoveryLease());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _documentGeneration += 1;
    _discoveredInstances.clear();
    final discoveryStart = _discoveryStartOperation;
    if (discoveryStart != null) {
      try {
        await discoveryStart;
      } on Object {
        // 文档结束会使进行中的发现获取主动失败并回收租约。
      }
    }
    await _releaseDiscoveryLease();
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    await _registration?.close();
    _registration = null;
    await _relayClientSession?.close();
    _relayClientSession = null;
    await _webGateway?.close();
    await _coreGateway?.close();
    _webGateway = null;
    _coreGateway = null;
    await _relayConnectOperation?.catchError((_) {});
    _relayConnectOperation = null;
    await _relayHostSession?.close();
    _relayHostSession = null;
    _bundledRelayPresentation = null;
    if (_ownsRelayHttpClient) _relayHttpClient.close();
    if (_ownsInspector) await _inspector.close();
    if (_ownsDiscovery) await _discovery.dispose();
    _qrEncoder.clear();
  }

  Future<LanGameDiscoveryLease> _acquireDiscoveryLease(int generation) async {
    final release = _discoveryReleaseOperation;
    if (release != null) {
      await release;
      _checkGeneration(generation);
      return _acquireDiscoveryLease(generation);
    }
    final existing = _discoveryLease;
    if (existing != null) return existing;
    final active = _discoveryStartOperation;
    if (active != null) {
      try {
        await active;
      } on Object {
        // 前一文档的获取已取消时，当前文档重新获取。
      }
      _checkGeneration(generation);
      final acquired = _discoveryLease;
      if (acquired != null) return acquired;
      return _acquireDiscoveryLease(generation);
    }
    late final Future<LanGameDiscoveryLease> operation;
    operation = _discovery
        .startDiscovery()
        .then((lease) async {
          if (!_isCurrent(generation)) {
            await lease.close();
            throw const RuntimeLanException(
              'operation_cancelled',
              '游戏退出，操作已取消',
            );
          }
          _discoveryLease = lease;
          _applyDiscoverySnapshot(lease.current);
          _discoverySubscription = lease.snapshots.listen((snapshot) {
            if (_isCurrent(generation)) {
              _applyDiscoverySnapshot(snapshot);
            }
          });
          return lease;
        })
        .whenComplete(() {
          if (identical(_discoveryStartOperation, operation)) {
            _discoveryStartOperation = null;
          }
        });
    _discoveryStartOperation = operation;
    return operation;
  }

  Future<void> _releaseDiscoveryLease() async {
    final active = _discoveryReleaseOperation;
    if (active != null) return active;
    final lease = _discoveryLease;
    _discoveryLease = null;
    final subscription = _discoverySubscription;
    _discoverySubscription = null;
    await subscription?.cancel();
    if (lease == null) return;
    late final Future<void> operation;
    operation = lease.close().whenComplete(() {
      if (identical(_discoveryReleaseOperation, operation)) {
        _discoveryReleaseOperation = null;
      }
    });
    _discoveryReleaseOperation = operation;
    await operation;
  }

  List<DiscoveredLanGame> _visibleGames(LanGameDiscoverySnapshot snapshot) {
    final selfInstance = _registration?.instanceId;
    return snapshot.games
        .where(
          (item) => item.gameId == game.id && item.instanceId != selfInstance,
        )
        .toList(growable: false);
  }

  void _applyDiscoverySnapshot(LanGameDiscoverySnapshot snapshot) {
    final games = _visibleGames(snapshot);
    _discoveredInstances
      ..clear()
      ..addAll(games.map((item) => item.instanceId));
  }
}

bool _isControlledPreparedEntryPath(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      value.trim() == value &&
      uri.scheme.isEmpty &&
      uri.authority.isEmpty &&
      uri.path.startsWith('/') &&
      uri.path.length > 1 &&
      !value.contains('?') &&
      !value.contains('#');
}

String? _safeRelayName(Object? value) {
  if (value is! String || _unsafeRelayNameCharacters.hasMatch(value)) {
    return null;
  }
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.runes.length > 80) return null;
  return normalized;
}

final _unsafeRelayNameCharacters = RegExp(
  r'[\u0000-\u001F\u007F\u202A-\u202E\u2066-\u2069]',
);

final class _RuntimeRelayHandshake {
  const _RuntimeRelayHandshake({
    required this.declaration,
    required this.name,
    required this.latencyMilliseconds,
  });

  final _RuntimeRelayDeclaration declaration;
  final String? name;
  final int latencyMilliseconds;
}

final class _RuntimeRelayDeclaration {
  const _RuntimeRelayDeclaration({
    required this.publicBaseUrl,
    required this.hostPath,
    required this.clientPath,
    required this.maxConnectionsPerTunnel,
  });

  factory _RuntimeRelayDeclaration.fromJson(Map<String, Object?> json) {
    final protocol = json['protocolVersion'];
    final transport = json['transport'];
    final publicBaseUrl = Uri.tryParse(json['publicBaseUrl'] as String? ?? '');
    final hostPath = json['hostPath'];
    final clientPath = json['clientPath'];
    final maximum = json['maxConnectionsPerTunnel'];
    if (protocol != relayProtocolVersion ||
        transport != 'playmesh-webrtc-datachannel' ||
        publicBaseUrl == null ||
        !{'http', 'https'}.contains(publicBaseUrl.scheme) ||
        publicBaseUrl.host.isEmpty ||
        publicBaseUrl.userInfo.isNotEmpty ||
        publicBaseUrl.query.isNotEmpty ||
        publicBaseUrl.fragment.isNotEmpty ||
        hostPath is! String ||
        !hostPath.startsWith('/') ||
        clientPath is! String ||
        !clientPath.startsWith('/') ||
        maximum is! int ||
        maximum < 1) {
      throw const FormatException('中转声明无效');
    }
    return _RuntimeRelayDeclaration(
      publicBaseUrl: publicBaseUrl,
      hostPath: hostPath,
      clientPath: clientPath,
      maxConnectionsPerTunnel: maximum,
    );
  }

  final Uri publicBaseUrl;
  final String hostPath;
  final String clientPath;
  final int maxConnectionsPerTunnel;
}
