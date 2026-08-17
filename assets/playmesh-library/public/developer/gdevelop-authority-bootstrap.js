(function installPlaymeshGDevelopAuthorityBootstrap(global) {
  'use strict';

  const PROTOCOL = 'playmesh.gdevelop.multiplayer.v1';
  const PROTOCOL_VERSION = 1;
  const AUTHORITY_NAMESPACE = PROTOCOL;
  const COORDINATOR_SYMBOL = Symbol.for(
    'playmesh.gdevelop.multiplayer.coordinator.v1'
  );
  const DISCOVERY_INTERVAL_MS = 500;
  const RUNTIME_POLL_INTERVAL_MS = 50;
  const MAX_PLAYERS = 8;
  const MAX_PLAYER_ID_LENGTH = 128;
  const MAX_CHANNEL_ID_LENGTH = 256;
  const INACTIVE_WARNING_CODE = 'MULTIPLAYER_RUNTIME_INACTIVE';
  const CONFIGURATION_WARNING_CODE =
    'MULTIPLAYER_CONFIGURATION_REQUIRED';
  const HOST_STATE_WARNING_CODE = 'MULTIPLAYER_HOST_STATE_MISMATCH';

  const existing = global.playmeshGDevelopAuthorityBootstrap;
  if (
    existing &&
    existing.protocol === PROTOCOL &&
    existing.version === PROTOCOL_VERSION &&
    typeof existing.install === 'function'
  ) {
    void existing.install();
    return;
  }

  const isPlainObject = value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  };

  const hasExactKeys = (value, required, optional = []) => {
    if (!isPlainObject(value)) return false;
    const keys = Object.keys(value);
    const allowed = new Set([...required, ...optional]);
    return (
      required.every(key => Object.prototype.hasOwnProperty.call(value, key)) &&
      keys.every(key => allowed.has(key))
    );
  };

  const isBoundedString = (value, maximum) =>
    typeof value === 'string' && value.length > 0 && value.length <= maximum;

  const isSafeInteger = (value, minimum, maximum) =>
    Number.isSafeInteger(value) && value >= minimum && value <= maximum;

  const delay = milliseconds =>
    new Promise(resolve => global.setTimeout(resolve, milliseconds));

  const warn = (message, error) =>
    global.console?.warn?.(message, error || '');

  let generation = 0;
  let installPromise = null;
  let installed = false;
  let main = null;
  let coordinator = null;
  let channel = null;
  let authorityOwnsChannel = false;
  let discoveryTimer = null;
  let unregisterAuthorityService = null;
  let unregisterGameMessage = null;
  let unregisterSessionState = null;
  let joinPromise = null;
  let requestInFlight = false;
  let snapshotRequestInFlight = false;
  let mappingEpochCounter = 0;
  let mapping = null;
  const emittedInactiveWarnings = new Set();

  const authorityPeerId = () => main?.binary?.authorityPlayerId || 'authority';

  const currentContext = () => ({
    isAuthority: Boolean(main && main.session.isAuthority()),
    authorityPeerId: authorityPeerId(),
    currentSession: main ? main.session.getCurrent() : null,
    currentPlayer: main ? main.player.getCurrent() : null,
  });

  const updateCoordinatorContext = () => {
    if (!coordinator) return;
    coordinator.updateContext(currentContext());
  };

  const describeMultiplayerRuntimeActivation = () => {
    let gameInfo = null;
    let session = null;
    try {
      gameInfo = main?.gameInfo?.getCurrent?.() || null;
    } catch (_) {
      // Missing or temporarily unreadable game configuration disables only
      // Playmesh multiplayer. GDevelop local runtime must still start.
    }
    try {
      session = main?.session?.getCurrent?.() || null;
    } catch (_) {
      // Treat a temporarily unreadable host session as unavailable below.
    }
    const behaviorDetected = Boolean(global.gdjs?.multiplayer);
    if (!gameInfo || typeof gameInfo.multiplayer !== 'boolean') {
      return {
        active: false,
        reason: 'game_type_unavailable',
        sessionPresent: Boolean(session),
        behaviorDetected,
      };
    }
    if (gameInfo.multiplayer !== true) {
      return {
        active: false,
        reason: behaviorDetected
          ? 'multiplayer_behavior_requires_online_game'
          : 'game_not_multiplayer',
        sessionPresent: Boolean(session),
        behaviorDetected,
      };
    }
    if (!session) {
      return {
        active: false,
        reason: 'session_unavailable',
        sessionPresent: false,
        behaviorDetected,
      };
    }
    return {
      active: true,
      reason: null,
      sessionPresent: true,
      behaviorDetected,
    };
  };

  const emitInactiveWarningOnce = activation => {
    if (!activation || activation.active || !activation.reason) return;
    if (emittedInactiveWarnings.has(activation.reason)) return;
    emittedInactiveWarnings.add(activation.reason);
    const code =
      activation.reason === 'multiplayer_behavior_requires_online_game'
        ? CONFIGURATION_WARNING_CODE
        : activation.reason === 'host_state_mismatch'
          ? HOST_STATE_WARNING_CODE
          : INACTIVE_WARNING_CODE;
    const warning = {
      code,
      source: 'gdevelop-bootstrap',
      context: {
        activation: activation.reason,
        sessionPresent: activation.sessionPresent,
        behaviorDetected: activation.behaviorDetected,
      },
    };
    try {
      if (coordinator?.emitWarning?.(warning) === true) return;
    } catch (_) {
      // 警告展示能力不能改变预览或发布包的运行结果。
    }
    global.console?.warn?.('Playmesh GDevelop multiplayer warning', warning);
  };

  const isNonBlockingHostStateMismatch = error =>
    [
      'PLAYMESH_GDEVELOP_RUNTIME_ALREADY_ATTACHED',
      'PLAYMESH_GDEVELOP_RUNTIME_MISMATCH',
      'PLAYMESH_GDEVELOP_ROLE_MISMATCH',
    ].includes(error?.code);

  const describeHostStateMismatch = () => {
    let sessionPresent = false;
    try {
      sessionPresent = Boolean(main?.session?.getCurrent?.());
    } catch (_) {
      // The mismatch warning itself must never depend on readable host state.
    }
    return {
      active: false,
      reason: 'host_state_mismatch',
      sessionPresent,
      behaviorDetected: Boolean(global.gdjs?.multiplayer),
    };
  };

  const normalizeSessionPlayers = session => {
    if (
      !session ||
      !isBoundedString(session.id, 128) ||
      !isBoundedString(session.authorityClientId, MAX_PLAYER_ID_LENGTH) ||
      !Array.isArray(session.players)
    ) {
      throw new Error('Playmesh GDevelop 会话快照无效。');
    }
    const players = session.players.map(player => {
      if (
        !player ||
        !isBoundedString(player.id, MAX_PLAYER_ID_LENGTH) ||
        typeof player.connected !== 'boolean'
      ) {
        throw new Error('Playmesh GDevelop 玩家记录无效。');
      }
      return { id: player.id, connected: player.connected };
    });
    if (new Set(players.map(player => player.id)).size !== players.length) {
      throw new Error('Playmesh GDevelop 会话包含重复玩家 ID。');
    }
    return players;
  };

  const createMapping = session => {
    mappingEpochCounter += 1;
    const assignments = new Map([[session.authorityClientId, 1]]);
    const players = normalizeSessionPlayers(session)
      .filter(player => player.id !== session.authorityClientId)
      .sort((left, right) => left.id.localeCompare(right.id));
    let nextNumber = 2;
    let errorCode = null;
    players.forEach(player => {
      if (assignments.has(player.id)) return;
      if (nextNumber > MAX_PLAYERS) {
        errorCode = 'PLAYER_LIMIT_EXCEEDED';
        return;
      }
      assignments.set(player.id, nextNumber);
      nextNumber += 1;
    });
    return {
      sessionId: session.id,
      sessionState: session.state,
      authorityClientId: session.authorityClientId,
      epoch: mappingEpochCounter,
      revision: 1,
      nextNumber,
      assignments,
      errorCode,
    };
  };

  const refreshMapping = session => {
    if (!session) {
      mapping = null;
      return null;
    }
    const shouldReset =
      !mapping ||
      mapping.sessionId !== session.id ||
      mapping.authorityClientId !== session.authorityClientId;
    if (shouldReset) {
      mapping = createMapping(session);
      return mapping;
    }

    const players = normalizeSessionPlayers(session)
      .filter(player => player.id !== session.authorityClientId)
      .sort((left, right) => left.id.localeCompare(right.id));
    let changed = mapping.sessionState !== session.state;
    let nextErrorCode = mapping.errorCode;
    players.forEach(player => {
      if (mapping.assignments.has(player.id)) return;
      if (mapping.nextNumber > MAX_PLAYERS) {
        nextErrorCode = 'PLAYER_LIMIT_EXCEEDED';
        return;
      }
      mapping.assignments.set(player.id, mapping.nextNumber);
      mapping.nextNumber += 1;
      changed = true;
    });
    if (nextErrorCode !== mapping.errorCode) changed = true;
    mapping.errorCode = nextErrorCode;
    mapping.sessionState = session.state;
    if (changed) mapping.revision += 1;
    return mapping;
  };

  const playerNumberSnapshot = session => {
    const current = refreshMapping(session);
    if (!current) return null;
    const assignments = [...current.assignments.entries()]
      .map(([playerId, playerNumber]) => ({ playerId, playerNumber }))
      .sort((left, right) => left.playerNumber - right.playerNumber);
    return {
      type: 'playerNumbers.snapshot',
      protocol: PROTOCOL,
      version: PROTOCOL_VERSION,
      sessionId: current.sessionId,
      epoch: current.epoch,
      revision: current.revision,
      assignments,
      errorCode: current.errorCode,
    };
  };

  const applyAuthoritySnapshot = session => {
    const snapshot = playerNumberSnapshot(session);
    if (snapshot) coordinator.applyPlayerNumberSnapshot(snapshot);
  };

  const attachChannel = nextChannel => {
    if (!nextChannel || typeof nextChannel !== 'object') {
      throw new Error('Playmesh GDevelop Binary Channel 无效。');
    }
    if (channel === nextChannel) {
      updateCoordinatorContext();
      return;
    }
    coordinator.attachChannel(nextChannel);
    channel = nextChannel;
    updateCoordinatorContext();
  };

  const isDiscoveryAction = (action, sessionId) =>
    hasExactKeys(action, ['type', 'protocol', 'version', 'sessionId']) &&
    action.type === 'channel.request' &&
    action.protocol === PROTOCOL &&
    action.version === PROTOCOL_VERSION &&
    action.sessionId === sessionId;

  const isPlayerNumberAction = (action, sessionId) =>
    hasExactKeys(
      action,
      ['type', 'protocol', 'version', 'sessionId'],
      ['knownEpoch', 'knownRevision']
    ) &&
    action.type === 'playerNumbers.request' &&
    action.protocol === PROTOCOL &&
    action.version === PROTOCOL_VERSION &&
    action.sessionId === sessionId &&
    (action.knownEpoch === undefined ||
      isSafeInteger(action.knownEpoch, 0, Number.MAX_SAFE_INTEGER)) &&
    (action.knownRevision === undefined ||
      isSafeInteger(action.knownRevision, 0, Number.MAX_SAFE_INTEGER));

  const isValidServiceContext = context => {
    const session = context && context.session;
    const senderPlayerId = context && context.senderPlayerId;
    if (
      !session ||
      !isBoundedString(session.id, 128) ||
      !isBoundedString(senderPlayerId, MAX_PLAYER_ID_LENGTH) ||
      senderPlayerId === session.authorityClientId ||
      !Array.isArray(session.players)
    ) {
      return false;
    }
    return session.players.some(
      player => player.id === senderPlayerId && player.connected === true
    );
  };

  const serviceMessage = (targetPlayerId, message) => ({
    targetPlayerIds: [targetPlayerId],
    message,
  });

  const startAuthority = async activeGeneration => {
    const createdChannel = await main.binary.createChannel({ mode: 'relay' });
    if (activeGeneration !== generation) {
      await createdChannel.close().catch(() => {});
      return;
    }
    try {
      attachChannel(createdChannel);
      authorityOwnsChannel = true;
      applyAuthoritySnapshot(main.session.getCurrent());
    } catch (error) {
      channel = null;
      await createdChannel.close().catch(() => {});
      throw error;
    }

    unregisterAuthorityService = main.authority.onService(
      (action, context) => {
        if (!isValidServiceContext(context)) return null;
        const serviceSession = context.session;
        const snapshot = playerNumberSnapshot(serviceSession);
        if (!snapshot) return null;
        if (isDiscoveryAction(action, serviceSession.id)) {
          return [
            serviceMessage(context.senderPlayerId, {
              type: 'channel.ready',
              protocol: PROTOCOL,
              version: PROTOCOL_VERSION,
              sessionId: serviceSession.id,
              channelId: createdChannel.id,
            }),
            serviceMessage(context.senderPlayerId, snapshot),
          ];
        }
        if (isPlayerNumberAction(action, serviceSession.id)) {
          return serviceMessage(context.senderPlayerId, snapshot);
        }
        return null;
      },
      { namespace: AUTHORITY_NAMESPACE }
    );
  };

  const isChannelReadyMessage = (message, sessionId) =>
    hasExactKeys(message, [
      'type',
      'protocol',
      'version',
      'sessionId',
      'channelId',
    ]) &&
    message.type === 'channel.ready' &&
    message.protocol === PROTOCOL &&
    message.version === PROTOCOL_VERSION &&
    message.sessionId === sessionId &&
    isBoundedString(message.channelId, MAX_CHANNEL_ID_LENGTH);

  const isPlayerNumberSnapshotMessage = (message, sessionId) => {
    if (
      !hasExactKeys(message, [
        'type',
        'protocol',
        'version',
        'sessionId',
        'epoch',
        'revision',
        'assignments',
        'errorCode',
      ]) ||
      message.type !== 'playerNumbers.snapshot' ||
      message.protocol !== PROTOCOL ||
      message.version !== PROTOCOL_VERSION ||
      message.sessionId !== sessionId ||
      !isSafeInteger(message.epoch, 1, Number.MAX_SAFE_INTEGER) ||
      !isSafeInteger(message.revision, 1, Number.MAX_SAFE_INTEGER) ||
      !Array.isArray(message.assignments) ||
      message.assignments.length < 1 ||
      message.assignments.length > MAX_PLAYERS ||
      (message.errorCode !== null &&
        message.errorCode !== 'PLAYER_LIMIT_EXCEEDED')
    ) {
      return false;
    }
    const playerIds = new Set();
    const numbers = new Set();
    for (const assignment of message.assignments) {
      if (
        !hasExactKeys(assignment, ['playerId', 'playerNumber']) ||
        !isBoundedString(assignment.playerId, MAX_PLAYER_ID_LENGTH) ||
        !isSafeInteger(assignment.playerNumber, 1, MAX_PLAYERS) ||
        playerIds.has(assignment.playerId) ||
        numbers.has(assignment.playerNumber)
      ) {
        return false;
      }
      playerIds.add(assignment.playerId);
      numbers.add(assignment.playerNumber);
    }
    const currentSession = main.session.getCurrent();
    return Boolean(
      currentSession &&
        message.assignments.some(
          assignment =>
            assignment.playerId === currentSession.authorityClientId &&
            assignment.playerNumber === 1
        )
    );
  };

  const requestChannel = () => {
    const session = main.session.getCurrent();
    if (!session || channel || joinPromise || requestInFlight) return;
    requestInFlight = true;
    void main.game
      .submitAction(
        {
          type: 'channel.request',
          protocol: PROTOCOL,
          version: PROTOCOL_VERSION,
          sessionId: session.id,
        },
        { namespace: AUTHORITY_NAMESPACE }
      )
      .catch(error => warn('Playmesh GDevelop channel discovery failed', error))
      .finally(() => {
        requestInFlight = false;
      });
  };

  const requestPlayerNumbers = () => {
    const session = main.session.getCurrent();
    if (!session || snapshotRequestInFlight) return;
    snapshotRequestInFlight = true;
    const knownEpoch = mapping ? mapping.epoch : 0;
    const knownRevision = mapping ? mapping.revision : 0;
    void main.game
      .submitAction(
        {
          type: 'playerNumbers.request',
          protocol: PROTOCOL,
          version: PROTOCOL_VERSION,
          sessionId: session.id,
          knownEpoch,
          knownRevision,
        },
        { namespace: AUTHORITY_NAMESPACE }
      )
      .catch(error => warn('Playmesh GDevelop player-number request failed', error))
      .finally(() => {
        snapshotRequestInFlight = false;
      });
  };

  const startGuest = activeGeneration => {
    unregisterGameMessage = main.game.onMessage(message => {
      if (activeGeneration !== generation) return;
      const currentSession = main.session.getCurrent();
      if (!currentSession) return;
      if (isPlayerNumberSnapshotMessage(message, currentSession.id)) {
        try {
          coordinator.applyPlayerNumberSnapshot(message);
        } catch (error) {
          warn('Playmesh GDevelop player-number snapshot rejected', error);
        }
        return;
      }
      if (
        !isChannelReadyMessage(message, currentSession.id) ||
        channel ||
        joinPromise
      ) {
        return;
      }
      joinPromise = main.binary
        .joinChannel(message.channelId)
        .then(joinedChannel => {
          if (activeGeneration !== generation) return;
          attachChannel(joinedChannel);
          if (discoveryTimer !== null) {
            global.clearInterval(discoveryTimer);
            discoveryTimer = null;
          }
          requestPlayerNumbers();
        })
        .catch(error => warn('Playmesh GDevelop channel join failed', error))
        .finally(() => {
          joinPromise = null;
        });
    });
    discoveryTimer = global.setInterval(requestChannel, DISCOVERY_INTERVAL_MS);
    requestChannel();
    requestPlayerNumbers();
  };

  const handleSessionState = nextSession => {
    if (!main || !coordinator) return;
    try {
      updateCoordinatorContext();
      if (main.session.isAuthority()) {
        applyAuthoritySnapshot(nextSession);
      } else {
        if (!channel) requestChannel();
        requestPlayerNumbers();
      }
    } catch (error) {
      if (isNonBlockingHostStateMismatch(error)) {
        emitInactiveWarningOnce(describeHostStateMismatch());
        void cleanup();
        return;
      }
      warn('Playmesh GDevelop session update rejected', error);
    }
  };

  const waitForRuntime = async activeGeneration => {
    while (activeGeneration === generation) {
      const candidateMain = global.playmesh && global.playmesh.main;
      const candidateCoordinator = global[COORDINATOR_SYMBOL];
      if (
        candidateMain &&
        candidateMain.ready &&
        candidateCoordinator &&
        candidateCoordinator.protocol === PROTOCOL &&
        candidateCoordinator.version === PROTOCOL_VERSION &&
        typeof candidateCoordinator.attachRuntime === 'function' &&
        typeof candidateCoordinator.updateContext === 'function' &&
        typeof candidateCoordinator.attachChannel === 'function' &&
        typeof candidateCoordinator.applyPlayerNumberSnapshot === 'function'
      ) {
        return { candidateMain, candidateCoordinator };
      }
      await delay(RUNTIME_POLL_INTERVAL_MS);
    }
    return null;
  };

  const cleanup = async () => {
    if (discoveryTimer !== null) {
      global.clearInterval(discoveryTimer);
      discoveryTimer = null;
    }
    unregisterAuthorityService?.();
    unregisterAuthorityService = null;
    unregisterGameMessage?.();
    unregisterGameMessage = null;
    unregisterSessionState?.();
    unregisterSessionState = null;
    try {
      coordinator?.detachChannel?.();
      coordinator?.dispose?.();
    } catch (error) {
      warn('Playmesh GDevelop coordinator cleanup failed', error);
    }
    const ownedChannel = authorityOwnsChannel ? channel : null;
    channel = null;
    authorityOwnsChannel = false;
    joinPromise = null;
    requestInFlight = false;
    snapshotRequestInFlight = false;
    mapping = null;
    if (ownedChannel) await ownedChannel.close().catch(() => {});
    coordinator = null;
    main = null;
    installed = false;
  };

  const install = () => {
    if (installed) {
      try {
        updateCoordinatorContext();
        return Promise.resolve();
      } catch (error) {
        if (!isNonBlockingHostStateMismatch(error)) {
          return Promise.reject(error);
        }
        emitInactiveWarningOnce(describeHostStateMismatch());
        return cleanup();
      }
    }
    if (installPromise) return installPromise;
    const activeGeneration = ++generation;
    let operation;
    operation = (async () => {
      const runtime = await waitForRuntime(activeGeneration);
      if (!runtime || activeGeneration !== generation) return;
      main = runtime.candidateMain;
      coordinator = runtime.candidateCoordinator;
      await main.ready;
      if (activeGeneration !== generation) return;
      const activation = describeMultiplayerRuntimeActivation();
      if (!activation.active) {
        emitInactiveWarningOnce(activation);
        main = null;
        coordinator = null;
        return;
      }
      try {
        coordinator.attachRuntime(main);
        updateCoordinatorContext();
      } catch (error) {
        if (!isNonBlockingHostStateMismatch(error)) throw error;
        emitInactiveWarningOnce(describeHostStateMismatch());
        await cleanup();
        return;
      }
      unregisterSessionState = main.session.onStateChange(handleSessionState);
      if (main.session.isAuthority()) {
        await startAuthority(activeGeneration);
      } else {
        startGuest(activeGeneration);
      }
      installed = activeGeneration === generation;
    })()
      .catch(async error => {
        if (activeGeneration === generation) await cleanup();
        throw error;
      })
      .finally(() => {
        if (installPromise === operation) installPromise = null;
      });
    installPromise = operation;
    return installPromise;
  };

  const dispose = async () => {
    generation += 1;
    installPromise = null;
    await cleanup();
  };

  const api = Object.freeze({
    protocol: PROTOCOL,
    version: PROTOCOL_VERSION,
    namespace: AUTHORITY_NAMESPACE,
    install,
    dispose,
    get installed() {
      return installed;
    },
  });

  Object.defineProperty(global, 'playmeshGDevelopAuthorityBootstrap', {
    value: api,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  global.addEventListener?.('pagehide', () => {
    void dispose();
  });
  void install().catch(error =>
    global.console?.error?.('Playmesh GDevelop Authority bootstrap failed', error)
  );
})(globalThis);
