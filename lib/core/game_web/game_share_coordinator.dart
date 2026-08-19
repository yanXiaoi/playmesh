import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/game_summary.dart';
import '../game_sdk/game_runtime_bridge.dart';
import '../game_sdk/standalone_game_runtime_bridge.dart';
import '../network/lan_game_advertisement.dart';
import '../network/lan_game_discovery_service.dart';
import '../network/lan_game_presence.dart';
import '../relay/relay_tunnel.dart';
import '../storage/game_storage_service.dart';
import 'game_share_link_snapshot.dart';
import 'game_web_gateway.dart';
import 'share_qr_code_encoder.dart';

enum ShareChannelState { absent, starting, active, stopping, disposed }

enum LanPublicationState {
  unpublished,
  publishing,
  published,
  disposing,
  disposed,
}

class GameShareCoordinatorState {
  const GameShareCoordinatorState({
    required this.generation,
    required this.channel,
    required this.publication,
    required this.snapshot,
    required this.relayStatus,
    this.channelFailureCode,
    this.publicationFailureCode,
    this.relayFailureCode,
  });

  final int generation;
  final ShareChannelState channel;
  final LanPublicationState publication;
  final GameShareLinkSnapshot snapshot;
  final RelayConnectionStatus relayStatus;
  final String? channelFailureCode;
  final String? publicationFailureCode;
  final String? relayFailureCode;

  GameShareCoordinatorState copyWith({
    ShareChannelState? channel,
    LanPublicationState? publication,
    GameShareLinkSnapshot? snapshot,
    RelayConnectionStatus? relayStatus,
    String? channelFailureCode,
    bool clearChannelFailure = false,
    String? publicationFailureCode,
    bool clearPublicationFailure = false,
    String? relayFailureCode,
    bool clearRelayFailure = false,
  }) => GameShareCoordinatorState(
    generation: generation,
    channel: channel ?? this.channel,
    publication: publication ?? this.publication,
    snapshot: snapshot ?? this.snapshot,
    relayStatus: relayStatus ?? this.relayStatus,
    channelFailureCode: clearChannelFailure
        ? null
        : channelFailureCode ?? this.channelFailureCode,
    publicationFailureCode: clearPublicationFailure
        ? null
        : publicationFailureCode ?? this.publicationFailureCode,
    relayFailureCode: clearRelayFailure
        ? null
        : relayFailureCode ?? this.relayFailureCode,
  );
}

class GameShareAccess {
  GameShareAccess({
    required this.shareToken,
    required this.storage,
    required this.displayMode,
    required this.currentPresence,
    required this.presenceChanges,
    required this.release,
    this.coreEndpoint,
    this.joinCode,
  });

  final String shareToken;
  final GameStorageService storage;
  final String displayMode;
  final LanGamePresence Function() currentPresence;
  final Stream<LanGamePresence> presenceChanges;
  final Uri? coreEndpoint;
  final String? joinCode;
  final Future<void> Function() release;
  bool _released = false;

  Future<void> close() async {
    if (_released) return;
    _released = true;
    await release();
  }
}

abstract interface class GameShareAccessProvider {
  Future<GameShareAccess> open();
}

class MultiplayerGameShareAccessProvider implements GameShareAccessProvider {
  const MultiplayerGameShareAccessProvider({
    required this.bridge,
    required this.coreEndpoint,
    required this.hostNickname,
  });

  final GameRuntimeBridge bridge;
  final Uri coreEndpoint;
  final String hostNickname;

  @override
  Future<GameShareAccess> open() async {
    final grant = await bridge.connection.openShare();
    return GameShareAccess(
      shareToken: grant.token,
      storage: bridge.storage,
      displayMode: bridge.connection.snapshot.displayMode,
      currentPresence: () => _multiplayerPresence(bridge, hostNickname),
      presenceChanges: bridge.connection.messages
          .where((message) => message['session'] is Map)
          .map((_) => _multiplayerPresence(bridge, hostNickname))
          .distinct(),
      coreEndpoint: coreEndpoint,
      joinCode: bridge.connection.snapshot.joinCode,
      release: bridge.connection.closeShare,
    );
  }
}

class StandaloneGameShareAccessProvider implements GameShareAccessProvider {
  const StandaloneGameShareAccessProvider(this.bridge);

  final StandaloneGameRuntimeBridge bridge;

  @override
  Future<GameShareAccess> open() async => GameShareAccess(
    shareToken: _newStandaloneShareToken(),
    storage: await bridge.ensureStorage(),
    displayMode: 'multi_screen',
    currentPresence: () => LanGamePresence.solo(hostNickname: bridge.nickname),
    presenceChanges: const Stream<LanGamePresence>.empty(),
    release: () async {},
  );
}

LanGamePresence _multiplayerPresence(
  GameRuntimeBridge bridge,
  String hostNickname,
) {
  final connection = bridge.connection;
  final snapshot = connection.snapshot;
  return LanGamePresence.multiplayer(
    hostNickname: hostNickname,
    playerCount: snapshot.players.where((player) => player.connected).length,
    maxPlayers: snapshot.maxPlayers,
  );
}

class GameShareGatewayRequest {
  const GameShareGatewayRequest({
    required this.game,
    required this.source,
    required this.access,
  });

  final GameSummary game;
  final GameWebResourceSource source;
  final GameShareAccess access;
}

abstract interface class GameShareGatewayFactory {
  Future<GameWebGateway> start(GameShareGatewayRequest request);
}

class DefaultGameShareGatewayFactory implements GameShareGatewayFactory {
  const DefaultGameShareGatewayFactory();

  @override
  Future<GameWebGateway> start(GameShareGatewayRequest request) {
    final game = request.game;
    final access = request.access;
    return startGameWebGateway(
      source: request.source,
      multiplayer: game.supportsMultiplayer,
      displayMode: access.displayMode,
      orientation: game.orientation,
      controllerOrientation: game.controllerOrientation,
      gameEntryPath: game.entry.gameEntryPath,
      controllerEntryPath: game.entry.controllerEntryPath,
      gameId: game.id,
      gameName: game.name,
      tags: game.tags,
      gameSdkVersion: game.sdkVersion.isEmpty ? null : game.sdkVersion,
      appSdkVersion: game.appSdkVersion.isEmpty ? null : game.appSdkVersion,
      requiredCapabilities: game.capabilities.required.toList(),
      controllerRequiredCapabilities: game.capabilities.controllerRequired
          .toList(),
      coreEndpoint: access.coreEndpoint,
      joinCode: access.joinCode,
      shareToken: access.shareToken,
      storage: access.storage,
    );
  }
}

class GameRelayHostRequest {
  const GameRelayHostRequest({
    required this.serverBaseUri,
    required this.sourceToken,
    required this.hostPath,
    required this.clientPath,
    required this.maxConnectionsPerTunnel,
  });

  final Uri serverBaseUri;
  final String sourceToken;
  final String hostPath;
  final String clientPath;
  final int maxConnectionsPerTunnel;
}

abstract interface class GameRelayHostFactory {
  Future<RelayHostSession> start({
    required GameRelayHostRequest request,
    required Uri authorityWebBaseUri,
    required Uri authorityCoreBaseUri,
    required Uri authorityEntryUri,
  });
}

class DefaultGameRelayHostFactory implements GameRelayHostFactory {
  const DefaultGameRelayHostFactory();

  @override
  Future<RelayHostSession> start({
    required GameRelayHostRequest request,
    required Uri authorityWebBaseUri,
    required Uri authorityCoreBaseUri,
    required Uri authorityEntryUri,
  }) => startRelayHostSession(
    serverBaseUri: request.serverBaseUri,
    sourceToken: request.sourceToken,
    hostPath: request.hostPath,
    clientPath: request.clientPath,
    authorityWebBaseUri: authorityWebBaseUri,
    authorityCoreBaseUri: authorityCoreBaseUri,
    authorityEntryUri: authorityEntryUri,
    maxConnectionsPerTunnel: request.maxConnectionsPerTunnel,
  );
}

class GameShareCoordinator {
  GameShareCoordinator({
    required this.game,
    required this.source,
    required this.accessProvider,
    required this.discoveryService,
    ShareQrCodeEncoder? qrEncoder,
    this.presenceUpdateDebounce = const Duration(milliseconds: 250),
    this._gatewayFactory = const DefaultGameShareGatewayFactory(),
    this._relayFactory = const DefaultGameRelayHostFactory(),
  }) : assert(!presenceUpdateDebounce.isNegative),
       _qrEncoder = qrEncoder ?? ShareQrCodeEncoder(),
       _state = GameShareCoordinatorState(
         generation: 0,
         channel: ShareChannelState.absent,
         publication: LanPublicationState.unpublished,
         snapshot: GameShareLinkSnapshot.empty(0),
         relayStatus: RelayConnectionStatus.disconnected,
       );

  final GameSummary game;
  final GameWebResourceSource source;
  final GameShareAccessProvider accessProvider;
  final LanGameDiscoveryService discoveryService;
  final ShareQrCodeEncoder _qrEncoder;
  final Duration presenceUpdateDebounce;
  final GameShareGatewayFactory _gatewayFactory;
  final GameRelayHostFactory _relayFactory;
  final StreamController<GameShareCoordinatorState> _stateController =
      StreamController<GameShareCoordinatorState>.broadcast();

  GameShareCoordinatorState _state;
  GameShareAccess? _access;
  StreamSubscription<LanGamePresence>? _presenceSubscription;
  GameWebGateway? _gateway;
  LanGameAdvertisement? _advertisement;
  LanGameRegistrationLease? _registration;
  LanGamePresence? _presence;
  LanGamePresence? _publishedPresence;
  LanGamePresence? _queuedPresence;
  Timer? _presenceUpdateTimer;
  Future<void>? _presenceUpdateOperation;
  List<Uri> _lanUrls = const [];
  Uri? _wanUrl;
  RelayHostSession? _relaySession;
  StreamSubscription<RelayConnectionStatus>? _relaySubscription;
  Future<void>? _shareStartOperation;
  Future<void>? _publishOperation;
  Future<void>? _snapshotOperation;
  Future<void>? _relayOperation;
  Future<void>? _closeOperation;
  int _generation = 0;
  int _linkRevision = 0;
  bool _closing = false;

  GameShareCoordinatorState get state => _state;

  Stream<GameShareCoordinatorState> get states => _stateController.stream;

  bool get isClosing => _closing;

  /// 当前分享通道的发现身份；只供宿主的 self-join 门禁使用，不进入 SDK 返回值。
  String? get instanceId => _advertisement?.instanceId;

  Future<void> ensureChannel() {
    _ensureOpen();
    if (_state.channel == ShareChannelState.active) {
      return Future<void>.value();
    }
    final active = _shareStartOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _startChannel().whenComplete(() {
      if (identical(_shareStartOperation, operation)) {
        _shareStartOperation = null;
      }
    });
    _shareStartOperation = operation;
    return operation;
  }

  Future<void> _startChannel() async {
    final generation = _generation;
    _update(
      _state.copyWith(
        channel: ShareChannelState.starting,
        clearChannelFailure: true,
      ),
    );
    GameShareAccess? access;
    GameWebGateway? gateway;
    StreamSubscription<LanGamePresence>? presenceSubscription;
    try {
      access = await accessProvider.open();
      _checkGeneration(generation);
      final presence = _validatedPresence(access.currentPresence());
      gateway = await _gatewayFactory.start(
        GameShareGatewayRequest(game: game, source: source, access: access),
      );
      _checkGeneration(generation);
      final lanUrls = List<Uri>.unmodifiable(await gateway.shareLinks());
      _checkGeneration(generation);
      final advertisement = LanGameAdvertisement.create(
        gameId: game.id,
        name: game.name,
        inviteToken: gateway.invitationToken,
        presence: presence,
      );
      final snapshot = await buildGameShareLinkSnapshot(
        generation: generation,
        lanUrls: lanUrls,
        wanUrl: null,
        encoder: _qrEncoder,
      );
      _checkGeneration(generation);
      final activeAccess = access;
      presenceSubscription = activeAccess.presenceChanges.listen(
        (value) => _handlePresenceChange(generation, activeAccess, value),
        onError: (_) {
          // 会话消息错误由现有连接链路处理，不能使分享生命周期产生未处理异步错误。
        },
      );
      _access = access;
      _presenceSubscription = presenceSubscription;
      _gateway = gateway;
      _advertisement = advertisement;
      _presence = presence;
      _lanUrls = lanUrls;
      _linkRevision += 1;
      _update(
        _state.copyWith(
          channel: ShareChannelState.active,
          snapshot: snapshot,
          clearChannelFailure: true,
        ),
      );
      presenceSubscription = null;
      access = null;
      gateway = null;
      try {
        _handlePresenceChange(
          generation,
          activeAccess,
          activeAccess.currentPresence(),
        );
      } on Object {
        // 订阅建立后的补读只用于弥合 read/listen 窗口；失败时保留首个有效状态。
      }
    } on GameShareException {
      _update(
        _state.copyWith(
          channel: ShareChannelState.absent,
          channelFailureCode: 'share_unavailable',
        ),
      );
      rethrow;
    } on _GameShareCancelled {
      rethrow;
    } on Object {
      _update(
        _state.copyWith(
          channel: ShareChannelState.absent,
          channelFailureCode: 'share_unavailable',
        ),
      );
      throw const GameShareException('share_unavailable', '无法建立分享通道');
    } finally {
      await _bestEffort(presenceSubscription?.cancel);
      await _bestEffort(gateway?.close);
      await _bestEffort(access?.close);
    }
  }

  LanGamePresence _validatedPresence(LanGamePresence presence) {
    presence.validated();
    if (presence.isSolo == game.supportsMultiplayer) {
      throw const FormatException('局域网分享模式与当前游戏不一致');
    }
    return presence;
  }

  void _handlePresenceChange(
    int generation,
    GameShareAccess access,
    LanGamePresence value,
  ) {
    if (_closing || generation != _generation || !identical(_access, access)) {
      return;
    }
    late final LanGamePresence presence;
    try {
      presence = _validatedPresence(value);
    } on Object {
      // 会话的无效瞬时投影不能覆盖最后一个已验证的公开状态。
      return;
    }
    if (presence == _presence) return;
    _presence = presence;
    final advertisement = _advertisement;
    if (advertisement != null) {
      _advertisement = advertisement.withPresence(presence);
    }
    _queuedPresence = presence;
    if (_registration == null &&
        _state.publication != LanPublicationState.publishing) {
      return;
    }
    _presenceUpdateTimer?.cancel();
    _presenceUpdateTimer = Timer(presenceUpdateDebounce, () {
      _presenceUpdateTimer = null;
      if (_closing || generation != _generation) return;
      _queuedPresence = _presence;
      _startPresenceUpdate(generation);
    });
  }

  void _startPresenceUpdate(int generation) {
    if (_closing ||
        generation != _generation ||
        _presenceUpdateOperation != null ||
        _queuedPresence == null ||
        _registration == null ||
        _presenceUpdateTimer != null) {
      return;
    }
    late final Future<void> operation;
    operation = _performPresenceUpdates(generation).whenComplete(() {
      if (identical(_presenceUpdateOperation, operation)) {
        _presenceUpdateOperation = null;
      }
      if (!_closing &&
          generation == _generation &&
          _queuedPresence != null &&
          _registration != null &&
          _presenceUpdateTimer == null) {
        _startPresenceUpdate(generation);
      }
    });
    _presenceUpdateOperation = operation;
    unawaited(
      operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<void> _performPresenceUpdates(int generation) async {
    if (_closing || generation != _generation) return;
    final registration = _registration;
    final target = _queuedPresence;
    if (registration == null || target == null) return;
    _queuedPresence = null;
    if (target == _publishedPresence) return;
    try {
      await registration.updatePresence(target);
    } on Object {
      if (_closing || generation != _generation) return;
      if (identical(_registration, registration)) {
        _registration = null;
        _publishedPresence = null;
        await _bestEffort(registration.close);
        if (_closing || generation != _generation) return;
        _update(
          _state.copyWith(
            publication: LanPublicationState.unpublished,
            publicationFailureCode: 'discovery_unavailable',
          ),
        );
      }
      return;
    }
    if (_closing || generation != _generation) return;
    if (!identical(_registration, registration)) return;
    _publishedPresence = target;
  }

  Future<void> setPublished() {
    _ensureOpen();
    final active = _publishOperation;
    if (active != null) return active;
    final presenceUpdate = _presenceUpdateOperation;
    if (_state.publication == LanPublicationState.published) {
      if (presenceUpdate == null) return Future<void>.value();
      late final Future<void> operation;
      operation = presenceUpdate
          .then((_) async {
            _ensureOpen();
            if (_state.publication == LanPublicationState.published) return;
            await _publish();
          })
          .whenComplete(() {
            if (identical(_publishOperation, operation)) {
              _publishOperation = null;
            }
          });
      _publishOperation = operation;
      return operation;
    }
    late final Future<void> operation;
    operation = _publish().whenComplete(() {
      if (identical(_publishOperation, operation)) {
        _publishOperation = null;
      }
    });
    _publishOperation = operation;
    return operation;
  }

  Future<void> _publish() async {
    final generation = _generation;
    await ensureChannel();
    _checkGeneration(generation);
    final gateway = _gateway;
    final advertisement = _advertisement;
    if (gateway == null || advertisement == null || _lanUrls.isEmpty) {
      _update(
        _state.copyWith(
          publication: LanPublicationState.unpublished,
          publicationFailureCode: 'discovery_unavailable',
        ),
      );
      throw const GameShareException('discovery_unavailable', '附近发现当前不可用');
    }
    _update(
      _state.copyWith(
        publication: LanPublicationState.publishing,
        clearPublicationFailure: true,
      ),
    );
    LanGameRegistrationLease? registration;
    try {
      registration = await discoveryService.register(
        advertisement: advertisement,
        port: gateway.port,
      );
      _checkGeneration(generation);
      _registration = registration;
      _publishedPresence = advertisement.presence;
      if (_queuedPresence == _publishedPresence) {
        _queuedPresence = null;
      }
      registration = null;
      _update(
        _state.copyWith(
          publication: LanPublicationState.published,
          clearPublicationFailure: true,
        ),
      );
      _startPresenceUpdate(generation);
    } on _GameShareCancelled {
      rethrow;
    } on Object {
      _publishedPresence = null;
      if (_closing || generation != _generation) {
        throw const _GameShareCancelled();
      }
      _update(
        _state.copyWith(
          publication: LanPublicationState.unpublished,
          publicationFailureCode: 'discovery_unavailable',
        ),
      );
      throw const GameShareException('discovery_unavailable', '附近发现当前不可用');
    } finally {
      await _bestEffort(registration?.close);
    }
  }

  Future<GameShareLinkSnapshot> currentLinkSnapshot() async {
    _ensureOpen();
    final generation = _generation;
    final startOperation = _shareStartOperation;
    if (startOperation != null) await startOperation;
    _checkGeneration(generation);
    final revision = _linkRevision;
    final snapshotOperation = _snapshotOperation;
    if (snapshotOperation != null) await snapshotOperation;
    if (_closing || generation != _generation || revision != _linkRevision) {
      throw const GameShareException('operation_cancelled', '分享链接读取已取消');
    }
    return _state.snapshot;
  }

  Future<void> connectRelay(GameRelayHostRequest request) {
    _ensureOpen();
    final active = _relayOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _connectRelay(request).whenComplete(() {
      if (identical(_relayOperation, operation)) _relayOperation = null;
    });
    _relayOperation = operation;
    return operation;
  }

  Future<void> _connectRelay(GameRelayHostRequest request) async {
    final generation = _generation;
    await ensureChannel();
    _checkGeneration(generation);
    await _disconnectRelayInternal(clearFailure: true);
    _checkGeneration(generation);
    final gateway = _gateway;
    final access = _access;
    final coreEndpoint = access?.coreEndpoint;
    if (gateway == null || coreEndpoint == null) {
      throw const GameShareException('share_unavailable', '当前分享不能连接 Relay');
    }
    _update(
      _state.copyWith(
        relayStatus: RelayConnectionStatus.connecting,
        clearRelayFailure: true,
      ),
    );
    RelayHostSession? session;
    StreamSubscription<RelayConnectionStatus>? subscription;
    var latestStatus = RelayConnectionStatus.disconnected;
    var committed = false;
    try {
      session = await _relayFactory.start(
        request: request,
        authorityWebBaseUri: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: gateway.port,
        ),
        authorityCoreBaseUri: coreEndpoint,
        authorityEntryUri: gateway.loopbackInvitationUri,
      );
      _checkGeneration(generation);
      final activeSession = session;
      latestStatus = activeSession.status;
      if (latestStatus == RelayConnectionStatus.disconnected) {
        throw const GameShareException('share_unavailable', 'Relay 会话在建立后已经断开');
      }
      final joinUri = activeSession.joinUri;
      subscription = activeSession.statuses.listen((status) {
        latestStatus = status;
        if (committed) {
          unawaited(_handleRelayStatus(activeSession, status));
        }
      });
      final revision = ++_linkRevision;
      final snapshot = await buildGameShareLinkSnapshot(
        generation: generation,
        lanUrls: _lanUrls,
        wanUrl: joinUri,
        encoder: _qrEncoder,
      );
      if (_closing || generation != _generation || revision != _linkRevision) {
        throw const _GameShareCancelled();
      }
      if (latestStatus == RelayConnectionStatus.disconnected ||
          activeSession.status == RelayConnectionStatus.disconnected) {
        throw const GameShareException(
          'share_unavailable',
          'Relay 会话在分享链接生成期间断开',
        );
      }
      _relaySession = activeSession;
      _relaySubscription = subscription;
      _wanUrl = joinUri;
      session = null;
      subscription = null;
      committed = true;
      _update(
        _state.copyWith(
          snapshot: snapshot,
          relayStatus: latestStatus,
          clearRelayFailure: true,
        ),
      );
    } on _GameShareCancelled {
      rethrow;
    } on Object {
      _update(
        _state.copyWith(
          relayStatus: RelayConnectionStatus.disconnected,
          relayFailureCode: 'relay_unavailable',
        ),
      );
      throw const GameShareException('share_unavailable', 'Relay 连接失败');
    } finally {
      if (!committed) {
        _qrEncoder.retain([..._lanUrls, ?_wanUrl]);
      }
      await _bestEffort(subscription?.cancel);
      await _bestEffort(session?.close);
    }
  }

  Future<void> _handleRelayStatus(
    RelayHostSession session,
    RelayConnectionStatus status,
  ) async {
    if (_closing || !identical(_relaySession, session)) return;
    if (status != RelayConnectionStatus.disconnected) {
      _update(_state.copyWith(relayStatus: status));
      return;
    }
    await _disconnectRelayInternal(clearFailure: false);
  }

  Future<void> disconnectRelay() {
    _ensureOpen();
    return _disconnectRelayInternal(clearFailure: true);
  }

  Future<void> _disconnectRelayInternal({required bool clearFailure}) async {
    final subscription = _relaySubscription;
    _relaySubscription = null;
    final session = _relaySession;
    _relaySession = null;
    final hadWan = _wanUrl != null;
    _wanUrl = null;
    await _bestEffort(subscription?.cancel);
    await _bestEffort(session?.close);
    if (hadWan && !_closing) {
      try {
        await _rebuildSnapshot(_generation);
      } on Object {
        // 断开时即使快照转换失败，也必须保持 WAN 已移除。
      }
    }
    if (!_closing) {
      _update(
        _state.copyWith(
          relayStatus: RelayConnectionStatus.disconnected,
          clearRelayFailure: clearFailure,
        ),
      );
    }
  }

  Future<void> _rebuildSnapshot(int generation) {
    final revision = ++_linkRevision;
    final previous = _snapshotOperation;
    late final Future<void> operation;
    operation = (previous ?? Future<void>.value())
        .then(
          (_) => _performSnapshotBuild(generation, revision),
          onError: (_) => _performSnapshotBuild(generation, revision),
        )
        .whenComplete(() {
          if (identical(_snapshotOperation, operation)) {
            _snapshotOperation = null;
          }
        });
    _snapshotOperation = operation;
    return operation;
  }

  Future<void> _performSnapshotBuild(int generation, int revision) async {
    final snapshot = await buildGameShareLinkSnapshot(
      generation: generation,
      lanUrls: _lanUrls,
      wanUrl: _wanUrl,
      encoder: _qrEncoder,
    );
    if (_closing || generation != _generation || revision != _linkRevision) {
      throw const _GameShareCancelled();
    }
    _update(_state.copyWith(snapshot: snapshot));
  }

  Future<void> close() {
    final active = _closeOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _performClose().whenComplete(() async {
      if (!_stateController.isClosed) await _stateController.close();
    });
    _closeOperation = operation;
    return operation;
  }

  Future<void> _performClose() async {
    if (_state.channel == ShareChannelState.disposed) return;
    _closing = true;
    _generation += 1;
    _linkRevision += 1;
    _presenceUpdateTimer?.cancel();
    _presenceUpdateTimer = null;
    _queuedPresence = null;
    final presenceSubscription = _presenceSubscription;
    _presenceSubscription = null;
    _lanUrls = const [];
    _wanUrl = null;
    _qrEncoder.clear();
    _update(
      GameShareCoordinatorState(
        generation: _generation,
        channel: ShareChannelState.stopping,
        publication: LanPublicationState.disposing,
        snapshot: GameShareLinkSnapshot.empty(_generation),
        relayStatus: RelayConnectionStatus.disconnected,
      ),
    );

    await _bestEffort(presenceSubscription?.cancel);
    await _bestEffortFuture(_publishOperation);
    await _bestEffortFuture(_presenceUpdateOperation);
    final registration = _registration;
    _registration = null;
    _publishedPresence = null;
    await _bestEffort(registration?.close);

    await _bestEffortFuture(_relayOperation);
    await _disconnectRelayInternal(clearFailure: false);

    await _bestEffortFuture(_shareStartOperation);
    await _bestEffortFuture(_snapshotOperation);
    final gateway = _gateway;
    _gateway = null;
    final access = _access;
    _access = null;
    _advertisement = null;
    _presence = null;
    await _bestEffort(gateway?.close);
    await _bestEffort(access?.close);

    _update(
      GameShareCoordinatorState(
        generation: _generation,
        channel: ShareChannelState.disposed,
        publication: LanPublicationState.disposed,
        snapshot: GameShareLinkSnapshot.empty(_generation),
        relayStatus: RelayConnectionStatus.disconnected,
      ),
    );
  }

  void _checkGeneration(int generation) {
    if (_closing || generation != _generation) {
      throw const _GameShareCancelled();
    }
  }

  void _ensureOpen() {
    if (_closing || _state.channel == ShareChannelState.disposed) {
      throw const GameShareException('game_context_unavailable', '当前游戏正在退出');
    }
  }

  void _update(GameShareCoordinatorState value) {
    _state = value;
    if (!_stateController.isClosed) _stateController.add(value);
  }
}

class _GameShareCancelled implements Exception {
  const _GameShareCancelled();
}

Future<void> _bestEffort(Future<void> Function()? operation) async {
  if (operation == null) return;
  try {
    await operation();
  } on Object {
    // 生命周期清理必须继续，且这里不能输出可能携带邀请凭据的原始异常。
  }
}

Future<void> _bestEffortFuture(Future<void>? operation) async {
  if (operation == null) return;
  try {
    await operation;
  } on Object {
    // 同上，前序失败不能阻断后续资源回收。
  }
}

String _newStandaloneShareToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
