import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/game_web/game_invitation.dart';
import '../../core/game_web/game_invitation_inspector.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/network/lan_game_discovery_service.dart';
import '../../models/user_profile.dart';
import '../../ui/playmesh_ui.dart';
import 'game_invitation_scan_flow.dart';
import 'game_join_error_localization.dart';
import 'game_join_error_presentation.dart';
import 'game_join_router.dart';

class JoinGamePage extends StatefulWidget {
  const JoinGamePage({
    super.key,
    this.initialUserId = 'u_local',
    this.initialNickname = playmeshDefaultLocalNickname,
    this.autoScan = false,
    this.discoveryService,
    this.joinCoordinator,
    this.joinRouter = const GameJoinRouter(),
    this.onNicknameChanged,
    this.coreControlBaseUri,
    this.coreControlBaseUriProvider,
    this.scanAndPrepareInvitation = scanAndPrepareGameInvitation,
    this.prepareInvitation = prepareGameInvitation,
  });

  static const routeName = '/join-game';
  static const scanButtonKey = ValueKey('join-scan-button');
  static const submitButtonKey = ValueKey('join-submit-button');
  static const joiningOverlayKey = ValueKey('join-joining-overlay');

  final String initialUserId;
  final String initialNickname;
  final bool autoScan;
  final LanGameDiscoveryService? discoveryService;
  final GameJoinPreparationService? joinCoordinator;
  final GameJoinRouter joinRouter;
  final Future<void> Function(String nickname)? onNicknameChanged;
  final Uri? coreControlBaseUri;
  final GameCoreBaseUriProvider? coreControlBaseUriProvider;
  final GameInvitationScanAndPrepare scanAndPrepareInvitation;
  final GameInvitationPrepare prepareInvitation;

  @override
  State<JoinGamePage> createState() => _JoinGamePageState();
}

class _JoinGamePageState extends State<JoinGamePage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _invitationController = TextEditingController();
  late final LanGameDiscoveryService _discoveryService;
  late final bool _ownsDiscoveryService;
  late final GameJoinPreparationService _joinCoordinator;
  DefaultGameInvitationInspector? _ownedInspector;
  LanGameDiscoveryLease? _discoveryLease;
  StreamSubscription<LanGameDiscoverySnapshot>? _discoverySubscription;
  LanGameDiscoverySnapshot _discoverySnapshot = LanGameDiscoverySnapshot(
    state: LanGameDiscoveryState.scanning,
    games: const [],
  );
  Future<void>? _discoveryOperation;
  Future<void> _discoveryLifecycleOperation = Future<void>.value();
  int _discoveryGeneration = 0;
  bool _lifecycleResumed = true;
  bool _joining = false;
  String? _joinErrorKey;
  String? _joinErrorDiagnostic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final injectedDiscovery = widget.discoveryService;
    _discoveryService = injectedDiscovery ?? LanGameDiscoveryService();
    _ownsDiscoveryService = injectedDiscovery == null;
    final injectedCoordinator = widget.joinCoordinator;
    if (injectedCoordinator == null) {
      final inspector = DefaultGameInvitationInspector(
        coreBaseUri: widget.coreControlBaseUri,
        coreBaseUriProvider: widget.coreControlBaseUriProvider,
      );
      _ownedInspector = inspector;
      _joinCoordinator = GameJoinCoordinator(
        inspector: inspector,
        discoveredGames: _discoveryService,
      );
    } else {
      _joinCoordinator = injectedCoordinator;
    }
    unawaited(_startDiscovery());
    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scannerSupported) _scanInvitation();
      });
    }
  }

  bool get _scannerSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleResumed = false;
    _discoveryGeneration += 1;
    unawaited(_disposeResources());
    _invitationController.dispose();
    super.dispose();
  }

  Future<void> _disposeResources() async {
    try {
      await _discoveryLifecycleOperation;
    } on Object {
      // 生命周期队列中的发现失败已经映射为页面状态。
    }
    await _stopDiscovery();
    await _ownedInspector?.close();
    if (_ownsDiscoveryService) await _discoveryService.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    _lifecycleResumed = resumed;
    if (resumed) {
      _queueDiscoveryLifecycle(() {
        if (!_lifecycleResumed || !mounted) return Future<void>.value();
        return _startDiscovery();
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _queueDiscoveryLifecycle(_stopDiscovery);
    }
  }

  void _queueDiscoveryLifecycle(Future<void> Function() operation) {
    _discoveryLifecycleOperation = _discoveryLifecycleOperation.then(
      (_) => operation(),
      onError: (_) => operation(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_joining,
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(title: Text(context.tr('join.title'))),
            body: PlaymeshBackground(
              child: SafeArea(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    children: [
                      ResponsivePage(
                        maxWidth: 680,
                        child: EntranceAnimation(
                          child: _buildNearbyGamesCard(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      ResponsivePage(
                        maxWidth: 680,
                        child: EntranceAnimation(
                          delay: const Duration(milliseconds: 70),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      const GradientIcon(
                                        icon: Icons.qr_code_scanner_rounded,
                                        size: 56,
                                        iconSize: 28,
                                      ),
                                      const SizedBox(width: 15),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              context.tr('join.host_title'),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(context.tr('join.subtitle')),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_scannerSupported) ...[
                                    const SizedBox(height: 22),
                                    FilledButton.tonalIcon(
                                      key: JoinGamePage.scanButtonKey,
                                      onPressed: _joining
                                          ? null
                                          : _scanInvitation,
                                      icon: const Icon(Icons.qr_code_scanner),
                                      label: Text(context.tr('join.scan')),
                                    ),
                                    Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 18,
                                      ),
                                      child: Row(
                                        children: [
                                          const Expanded(child: Divider()),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                            child: Text(
                                              context.tr('join.manual'),
                                            ),
                                          ),
                                          const Expanded(child: Divider()),
                                        ],
                                      ),
                                    ),
                                  ] else
                                    const SizedBox(height: 22),
                                  TextFormField(
                                    controller: _invitationController,
                                    decoration: InputDecoration(
                                      labelText: context.tr('join.invite_link'),
                                      hintText: context.tr('join.invite_hint'),
                                      helperText: context.tr(
                                        'join.invite_helper',
                                      ),
                                      prefixIcon: const Icon(
                                        Icons.link_rounded,
                                      ),
                                    ),
                                    keyboardType: TextInputType.url,
                                    textInputAction: TextInputAction.go,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    validator: _validateInvitation,
                                    onFieldSubmitted: _joining
                                        ? null
                                        : (_) => _joinFromInput(),
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.icon(
                                    key: JoinGamePage.submitButtonKey,
                                    onPressed: _joining ? null : _joinFromInput,
                                    icon: const Icon(Icons.login),
                                    label: Text(
                                      _joining
                                          ? context.tr('join.joining')
                                          : context.tr('join.submit'),
                                    ),
                                  ),
                                  if (_joinErrorKey != null) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      context.tr(_joinErrorKey!),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                    if (_joinErrorDiagnostic != null) ...[
                                      const SizedBox(height: 10),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          context.tr('join.error_details'),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelMedium,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SelectableText(
                                        _joinErrorDiagnostic!,
                                        key: gameJoinErrorDetailsKey,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(fontFamily: 'monospace'),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_joining)
            Positioned.fill(
              key: JoinGamePage.joiningOverlayKey,
              child: GameInvitationJoiningOverlay(
                label: context.tr('join.joining'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNearbyGamesCard() {
    final snapshot = _discoverySnapshot;
    final colors = Theme.of(context).colorScheme;
    final refreshLabel = context.tr('join.nearby_refresh');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering_rounded, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.tr('join.nearby_title'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (snapshot.state == LanGameDiscoveryState.scanning)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  key: const ValueKey('nearby-refresh'),
                  onPressed:
                      _joining ||
                          snapshot.state == LanGameDiscoveryState.scanning
                      ? null
                      : _restartDiscovery,
                  tooltip: refreshLabel,
                  icon: Icon(
                    Icons.refresh_rounded,
                    semanticLabel: refreshLabel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            switch (snapshot.state) {
              LanGameDiscoveryState.ready when snapshot.games.isNotEmpty =>
                Column(
                  children: [
                    for (final game in snapshot.games)
                      ListTile(
                        key: ValueKey('nearby-game-${game.instanceId}'),
                        contentPadding: EdgeInsets.zero,
                        minVerticalPadding: 12,
                        isThreeLine: true,
                        leading: CircleAvatar(
                          backgroundColor: colors.primaryContainer,
                          foregroundColor: colors.onPrimaryContainer,
                          child: const Icon(Icons.sports_esports_rounded),
                        ),
                        title: Text(
                          game.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 3),
                            Text(
                              context.tr(
                                'join.nearby_host',
                                arguments: {
                                  'nickname': game.presence.hostNickname,
                                },
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              context.tr(
                                'join.nearby_host_ip',
                                arguments: {'host': game.hostAddress},
                              ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                            Text(
                              context.tr(
                                'join.nearby_game_id',
                                arguments: {'gameId': game.gameId},
                              ),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _nearbyPresenceBadge(game),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                        enabled: !_joining,
                        onTap: _joining ? null : () => _joinDiscovered(game),
                      ),
                  ],
                ),
              LanGameDiscoveryState.ready => _nearbyStatus(
                Icons.radar_rounded,
                'join.nearby_empty',
              ),
              LanGameDiscoveryState.scanning => _nearbyStatus(
                Icons.radar_rounded,
                'join.nearby_scanning',
              ),
              LanGameDiscoveryState.permissionDenied => _nearbyFailure(
                Icons.lock_outline_rounded,
                'join.nearby_permission_denied',
              ),
              LanGameDiscoveryState.unsupported => _nearbyFailure(
                Icons.portable_wifi_off_rounded,
                'join.nearby_unsupported',
              ),
              LanGameDiscoveryState.failed => _nearbyFailure(
                Icons.wifi_find_rounded,
                'join.nearby_failed',
              ),
            },
          ],
        ),
      ),
    );
  }

  Widget _nearbyPresenceBadge(DiscoveredLanGame game) {
    final colors = Theme.of(context).colorScheme;
    final presence = game.presence;
    final text = presence.isSolo
        ? context.tr('join.nearby_solo')
        : context.tr(
            'join.nearby_players_short',
            arguments: {
              'current': presence.playerCount!,
              'max': presence.maxPlayers!,
            },
          );
    final semantics = presence.isSolo
        ? context.tr('join.nearby_solo_semantics')
        : context.tr(
            'join.nearby_players_semantics',
            arguments: {
              'current': presence.playerCount!,
              'max': presence.maxPlayers!,
            },
          );
    final background = presence.isSolo
        ? colors.tertiaryContainer
        : colors.primaryContainer;
    final foreground = presence.isSolo
        ? colors.onTertiaryContainer
        : colors.onPrimaryContainer;
    return Semantics(
      label: semantics,
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('nearby-presence-${game.instanceId}'),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  Widget _nearbyStatus(IconData icon, String messageKey) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(child: Text(context.tr(messageKey))),
      ],
    ),
  );

  Widget _nearbyFailure(IconData icon, String messageKey) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 2),
    child: Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: 10),
        Expanded(child: Text(context.tr(messageKey))),
        TextButton(
          onPressed: _joining ? null : _restartDiscovery,
          child: Text(context.tr('join.nearby_retry')),
        ),
      ],
    ),
  );

  Future<void> _startDiscovery() {
    if (!mounted || !_lifecycleResumed || _joining || _discoveryLease != null) {
      return Future<void>.value();
    }
    final active = _discoveryOperation;
    if (active != null) return active;
    final generation = ++_discoveryGeneration;
    late final Future<void> operation;
    operation = _performStartDiscovery(generation).whenComplete(() {
      if (identical(_discoveryOperation, operation)) {
        _discoveryOperation = null;
      }
    });
    _discoveryOperation = operation;
    return operation;
  }

  Future<void> _performStartDiscovery(int generation) async {
    try {
      final lease = await _discoveryService.startDiscovery();
      if (!mounted ||
          generation != _discoveryGeneration ||
          !_lifecycleResumed ||
          _joining) {
        await lease.close();
        return;
      }
      final subscription = lease.snapshots.listen((snapshot) {
        if (!mounted || generation != _discoveryGeneration) return;
        setState(() => _discoverySnapshot = snapshot);
      });
      _discoveryLease = lease;
      _discoverySubscription = subscription;
      setState(() => _discoverySnapshot = lease.current);
    } on Object {
      if (!mounted || generation != _discoveryGeneration) return;
      setState(
        () => _discoverySnapshot = LanGameDiscoverySnapshot(
          state: LanGameDiscoveryState.failed,
          games: const [],
        ),
      );
    }
  }

  Future<void> _stopDiscovery() async {
    _discoveryGeneration += 1;
    final operation = _discoveryOperation;
    if (operation != null) {
      try {
        await operation;
      } on Object {
        // 启动失败已经折叠成公开发现状态；离页清理继续。
      }
    }
    final subscription = _discoverySubscription;
    _discoverySubscription = null;
    await subscription?.cancel();
    final lease = _discoveryLease;
    _discoveryLease = null;
    await lease?.close();
  }

  void _restartDiscovery() {
    if (_joining) return;
    setState(
      () => _discoverySnapshot = LanGameDiscoverySnapshot(
        state: LanGameDiscoveryState.scanning,
        games: const [],
      ),
    );
    unawaited(() async {
      await _stopDiscovery();
      if (mounted) await _startDiscovery();
    }());
  }

  Future<void> _scanInvitation() async {
    await _runJoin(
      () => widget.scanAndPrepareInvitation(
        context,
        coordinator: _joinCoordinator,
        joinContext: const GameJoinContext(),
        onScanned: (raw) => _invitationController.text = raw,
      ),
    );
  }

  String? _validateInvitation(String? value) {
    try {
      GameInvitation.parse(value ?? '');
      return null;
    } on FormatException {
      return context.tr('join.invalid_invite');
    }
  }

  Future<void> _joinFromInput() async {
    if (!_formKey.currentState!.validate()) return;
    await _runJoin(
      () => widget.prepareInvitation(
        _invitationController.text.trim(),
        coordinator: _joinCoordinator,
        joinContext: const GameJoinContext(),
      ),
    );
  }

  Future<void> _joinDiscovered(DiscoveredLanGame game) => _runJoin(
    () => _joinCoordinator.prepareDiscovered(
      game.instanceId,
      context: const GameJoinContext(),
    ),
    retainDiscoveryForPreparation: true,
  );

  Future<void> _runJoin(
    Future<RemoteGameLaunch?> Function() prepare, {
    bool retainDiscoveryForPreparation = false,
  }) async {
    if (_joining) return;
    RemoteGameLaunch? preparedLaunch;
    setState(() {
      _joining = true;
      _joinErrorKey = null;
      _joinErrorDiagnostic = null;
    });
    try {
      if (!retainDiscoveryForPreparation) await _stopDiscovery();
      final launch = await prepare();
      preparedLaunch = launch;
      if (launch == null || !mounted) return;
      if (retainDiscoveryForPreparation) {
        // Coordinator 会在预检后再次核对短期候选；必须等准备完成后再释放
        // browse lease，但远程页面入栈前仍要停止本页发现。
        await _stopDiscovery();
        if (!mounted) return;
      }
      await widget.joinRouter.push(
        context,
        launch: launch,
        userId: widget.initialUserId,
        nickname: widget.initialNickname,
        coreControlBaseUri:
            widget.coreControlBaseUriProvider?.call() ??
            widget.coreControlBaseUri,
        discoveryService: _discoveryService,
        onNicknameChanged: widget.onNicknameChanged,
      );
    } on GameJoinException catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _joinErrorKey = gameJoinErrorLocalizationKey(error);
          _joinErrorDiagnostic = gameJoinErrorDetails(
            error,
            stackTrace: stackTrace,
          );
        });
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _joinErrorKey = 'join.failed';
          _joinErrorDiagnostic = gameJoinErrorDetails(
            error,
            stackTrace: stackTrace,
          );
        });
      }
    } finally {
      await preparedLaunch?.close();
      if (mounted) {
        setState(() => _joining = false);
        if (_lifecycleResumed) unawaited(_startDiscovery());
      }
    }
  }
}
