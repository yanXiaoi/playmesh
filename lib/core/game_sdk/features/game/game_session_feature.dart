part of '../../sdk_feature_registry.dart';

const gameSessionSdkSource = SdkSourceFragment(
  id: 'game.session',
  target: SdkSourceTarget.game,
  order: 30,
  typeScript: r'''  function publicPlayer(player) {
    if (!player || typeof player !== "object") return null;
    return {
      id: player.id,
      nickname: player.nickname,
      avatar: typeof player.avatar === "string" ? player.avatar : null,
      role: player.role,
      connected: Boolean(player.connected),
    };
  }

  function publicSession(session) {
    if (!session || typeof session !== "object") return null;
    return {
      ...session,
      players: Array.isArray(session.players)
        ? session.players.map(publicPlayer)
        : [],
    };
  }

  function seedPlayerConnections(session) {
    previouslyConnectedPlayerIds.clear();
    for (const player of session?.players || []) {
      if (player.connected) previouslyConnectedPlayerIds.add(player.id);
    }
  }

  function sessionConnectionLogContext(session, player) {
    const players = session?.players || [];
    return {
      sessionId: session?.id || null,
      gameId: session?.gameId || null,
      roomType: session?.displayMode || "unknown",
      sessionState: session?.state || "unknown",
      onlinePlayers: players.filter((member) => member.connected).length,
      roomPlayers: players.length,
      minPlayers: session?.minPlayers ?? null,
      maxPlayers: session?.maxPlayers ?? null,
      playerId: player?.id || null,
      nickname: player?.nickname || null,
      playerRole: player?.role || null,
      isCurrentPlayer: player?.id === bootstrap?.player?.id,
      isAuthority: player?.id === session?.authorityClientId,
    };
  }

  function emitPlayerConnectionChanges(previousSession, nextSession) {
    if (previousSession?.id !== nextSession?.id) {
      seedPlayerConnections(previousSession?.id === nextSession?.id ? previousSession : null);
    }
    const previousPlayers = new Map((previousSession?.players || []).map((player) => [player.id, player]));
    const nextPlayers = new Map((nextSession?.players || []).map((player) => [player.id, player]));
    for (const player of nextPlayers.values()) {
      const previous = previousPlayers.get(player.id);
      if (player.connected && !previous?.connected) {
        const reconnecting = previouslyConnectedPlayerIds.has(player.id);
        previouslyConnectedPlayerIds.add(player.id);
        global.console?.info?.(
          reconnecting
            ? "Playmesh 玩家已重连"
            : "Playmesh 新玩家已加入房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(reconnecting ? playerReconnectListeners : playerJoinListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      } else if (!player.connected && previous?.connected) {
        global.console?.warn?.(
          "Playmesh 玩家已掉线或退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
    for (const player of previousPlayers.values()) {
      if (player.connected && !nextPlayers.has(player.id)) {
        global.console?.warn?.(
          "Playmesh 玩家已退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player: { ...player, connected: false },
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
  }

  async function dispatchAuthorityAction(transportMessage) {
    if (await dispatchSyncAuthorityAction(transportMessage)) return;
    if (!authorityService) {
      return;
    }
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
    };
    const output = await authorityService(transportMessage.payload, context);
    const results = Array.isArray(output) ? output : [output];
    for (const result of results) {
      if (!result || !Array.isArray(result.targetPlayerIds) || !result.message) {
        continue;
      }
      await post("authority.result", result.message, {
        targetPlayerIds: result.targetPlayerIds,
      });
    }
  }

''',
);

class _GameSessionFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gameSessionSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'game.submitAction',
    'authority.result',
    'session.start',
    'session.finish',
  };

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final connection = context.connection;
    if (connection == null) {
      throw FormatException('单机模式不支持 SDK 命令: ${command.name}');
    }
    switch (command.name) {
      case 'game.submitAction':
        connection.submitAction(command.payload);
        return const SdkCommandResult();
      case 'authority.result':
        final targets = command.raw['targetPlayerIds'];
        if (targets is! List || targets.any((target) => target is! String)) {
          throw const FormatException('targetPlayerIds 必须是字符串数组');
        }
        connection.submitAuthorityResult(
          targetPlayerIds: targets.cast<String>(),
          message: command.payload,
        );
        return const SdkCommandResult();
      case 'session.start':
        return SdkCommandResult((await connection.start()).toJson());
      case 'session.finish':
        return SdkCommandResult((await connection.finish()).toJson());
    }
    throw StateError('未注册的会话命令: ${command.name}');
  }
}
