(function installPlaymeshGDevelopRuntimeBackends(global) {
  'use strict';

  const REGISTRY_SYMBOL = Symbol.for('playmesh.runtime.backends.v1');
  const COORDINATOR_SYMBOL = Symbol.for(
    'playmesh.gdevelop.multiplayer.coordinator.v1'
  );
  const ENGINE = 'gdevelop';
  const ENGINE_VERSION = '5.6.276';
  const FEATURE_VERSION = 1;
  const PROTOCOL = 'playmesh.gdevelop.multiplayer.v1';
  const PROTOCOL_VERSION = 1;
  const LOCAL_FRAME_PROTOCOL = 'playmesh.gdevelop.local-frame.v1';
  const LOCAL_FRAME_VERSION = 1;
  const AUTHORITY_PEER_ID = 'authority';
  const MAX_PLAYERS = 8;
  const MAX_PLAYER_ID_BYTES = 128;
  const MAX_MESSAGE_NAME_BYTES = 256;
  const MAX_PACKET_BYTES = 1024 * 1024;
  const MAX_CONTROL_FRAME_BYTES = 16 * 1024;
  const MAX_AVATAR_BYTES = 512 * 1024;
  const MAX_AVATAR_DIMENSION = 512;
  const MAX_AVATAR_PIXELS = 256 * 1024;
  const RUNTIME_READY_TIMEOUT_MS = 15000;
  const COORDINATOR_ATTACH_TIMEOUT_MS = 15000;
  const RUNTIME_DISCOVERY_INTERVAL_MS = 25;
  const MAX_DEFERRED_CONTROL_SENDS = 16;
  const LOBBY_OPERATION_TIMEOUT_MS = 12000;
  const MAX_LOBBY_REQUEST_ID_BYTES = 64;
  const CONTROL_DELIVERY_ATTEMPTS = 3;
  const PACKET_HEADER_BYTES = 6;
  const PACKET_MAGIC = [0x50, 0x4d, 0x47, 0x44]; // PMGD
  // PMGD v2 deliberately has no compatibility path for the old direct-start
  // protocol. Readiness is part of the transport contract now.
  const PACKET_VERSION = 2;
  const PACKET_CONNECT = 1;
  const PACKET_ACCEPT = 2;
  const PACKET_CLOSE = 3;
  const PACKET_DATA = 4;
  const PACKET_READY_STATE = 5;
  const PACKET_READY_ACK = 6;
  const PACKET_READY_SNAPSHOT = 7;
  const PACKET_PREPARE = 8;
  const PACKET_PREPARED = 9;
  const READINESS_TOKEN_BYTES = 16;
  const DATA_STRING = 0;
  const DATA_BYTES = 1;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder('utf-8', { fatal: true });

  const isPlainObject = value => {
    try {
      if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
      const prototype = Object.getPrototypeOf(value);
      return prototype === Object.prototype || prototype === null;
    } catch (_) {
      return false;
    }
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

  const isBoundedString = (value, maxBytes, allowEmpty = false) =>
    typeof value === 'string' &&
    (allowEmpty || value.length > 0) &&
    encoder.encode(value).byteLength <= maxBytes;

  const isSafeInteger = (value, min, max) =>
    Number.isSafeInteger(value) && value >= min && value <= max;

  // 外部 DTO 只读取自有数据属性，避免 getter 或隐式字符串转换执行调用方代码。
  const readExactDataRecord = (value, required, optional = []) => {
    if (!isPlainObject(value)) return null;
    try {
      const keys = Reflect.ownKeys(value);
      const allowed = new Set([...required, ...optional]);
      if (
        keys.some(key => typeof key !== 'string' || !allowed.has(key)) ||
        required.some(key => !keys.includes(key))
      ) {
        return null;
      }
      const record = Object.create(null);
      for (const key of keys) {
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (!descriptor || !descriptor.enumerable || !('value' in descriptor)) {
          return null;
        }
        record[key] = descriptor.value;
      }
      return record;
    } catch (_) {
      return null;
    }
  };

  const readOwnDataValue = (value, key) => {
    if (!isPlainObject(value)) return null;
    try {
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!descriptor || !descriptor.enumerable || !('value' in descriptor)) {
        return null;
      }
      return { value: descriptor.value };
    } catch (_) {
      return null;
    }
  };

  const readDenseDataArray = (value, maxLength) => {
    if (!Array.isArray(value)) return null;
    try {
      const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
      if (
        !lengthDescriptor ||
        !('value' in lengthDescriptor) ||
        !isSafeInteger(lengthDescriptor.value, 0, maxLength)
      ) {
        return null;
      }
      const length = lengthDescriptor.value;
      const keys = Reflect.ownKeys(value);
      if (
        keys.length !== length + 1 ||
        keys.some((key, index) =>
          index < length ? key !== String(index) : key !== 'length'
        )
      ) {
        return null;
      }
      const values = [];
      for (let index = 0; index < length; index += 1) {
        const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
        if (!descriptor || !descriptor.enumerable || !('value' in descriptor)) {
          return null;
        }
        values.push(descriptor.value);
      }
      return values;
    } catch (_) {
      return null;
    }
  };

  const cloneJson = value => JSON.parse(JSON.stringify(value));

  const defer = callback => {
    Promise.resolve().then(() => {
      try {
        callback();
      } catch (error) {
        global.console?.error?.('Playmesh GDevelop callback failed', error);
      }
    });
  };

  const fail = (code, message) => {
    const error = new Error(message);
    error.code = code;
    throw error;
  };

  const runtimeFailure = (code, message, cause) => {
    const error = new Error(message);
    error.code = code;
    if (cause !== undefined) error.cause = cause;
    return error;
  };

  const validatePlayerId = value => {
    if (!isBoundedString(value, MAX_PLAYER_ID_BYTES)) {
      fail('PLAYMESH_GDEVELOP_INVALID_PLAYER_ID', 'GDevelop 玩家 ID 无效。');
    }
    return value;
  };

  const validateRuntimeMain = main => {
    if (
      !main ||
      typeof main !== 'object' ||
      !main.ready ||
      !main.session ||
      typeof main.session.isAuthority !== 'function' ||
      typeof main.session.getCurrent !== 'function' ||
      typeof main.session.start !== 'function' ||
      typeof main.session.finish !== 'function' ||
      !main.player ||
      typeof main.player.getCurrent !== 'function'
    ) {
      fail(
        'PLAYMESH_GDEVELOP_INCOMPATIBLE_SDK',
        'Playmesh Game SDK 不支持 GDevelop 5.6.276 运行后端。'
      );
    }
  };

  const normalizePlayer = value => {
    if (!isPlainObject(value)) {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', '会话玩家记录无效。');
    }
    const id = validatePlayerId(value.id);
    if (!isBoundedString(value.nickname, 128)) {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', '会话玩家昵称无效。');
    }
    if (
      value.role !== 'authority' &&
      value.role !== 'authority_player' &&
      value.role !== 'player'
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', '会话玩家角色无效。');
    }
    if (typeof value.connected !== 'boolean') {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', '会话玩家连接状态无效。');
    }
    const avatar =
      value.avatar === null || value.avatar === undefined
        ? null
        : isBoundedString(value.avatar, 512)
          ? value.avatar
          : null;
    return Object.freeze({
      id,
      nickname: value.nickname,
      role: value.role,
      connected: value.connected,
      avatar,
    });
  };

  const normalizeSession = value => {
    if (
      !isPlainObject(value) ||
      !isBoundedString(value.id, 128) ||
      !['lobby', 'running', 'paused', 'stopped'].includes(value.state) ||
      !isBoundedString(value.authorityClientId, MAX_PLAYER_ID_BYTES) ||
      !Array.isArray(value.players) ||
      value.players.length > 64 ||
      !isSafeInteger(value.minPlayers, 1, MAX_PLAYERS) ||
      (value.maxPlayers !== undefined &&
        !isSafeInteger(value.maxPlayers, 1, 64))
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', 'Playmesh 会话快照无效。');
    }
    const players = value.players.map(normalizePlayer);
    if (new Set(players.map(player => player.id)).size !== players.length) {
      fail('PLAYMESH_GDEVELOP_INVALID_SESSION', '会话玩家 ID 重复。');
    }
    return Object.freeze({
      id: value.id,
      state: value.state,
      authorityClientId: value.authorityClientId,
      players: Object.freeze(players),
      minPlayers: value.minPlayers,
      maxPlayers: value.maxPlayers || MAX_PLAYERS,
    });
  };

  const normalizeCurrentPlayer = value => {
    if (value === null || value === undefined) return null;
    return normalizePlayer(value);
  };

  const emptyPlayerNumbers = () => ({
    sessionId: null,
    epoch: 0,
    revision: 0,
    assignments: new Map(),
    errorCode: null,
  });

  let main = null;
  let session = null;
  let currentPlayer = null;
  let authority = false;
  let authorityPeerId = AUTHORITY_PEER_ID;
  let channel = null;
  let channelSessionId = null;
  let unsubscribeChannel = null;
  let playerNumbers = emptyPlayerNumbers();
  let peer = null;
  let peerOpen = false;
  let identityRemoved = false;
  let identityOverride = null;
  let officialGameId = null;
  let officialIdentityKey = null;
  const connections = new Map();
  const pendingPackets = [];
  const lobbySockets = new Set();
  const authSockets = new Set();
  const localFrameStates = new Set();
  const localFrameByElement = new WeakMap();
  const activeLocalFrameByKind = {
    lobby: null,
    authentication: null,
  };
  let warningSink = null;
  let coordinatorContextRevision = 0;
  let runtimeNegotiation = null;
  let runtimeNegotiationGeneration = 0;
  const coordinatorNegotiationWaiters = new Set();
  const deferredControlSockets = new Set();
  let acceptPeerPackets = true;
  let activeOfficialLobbyOperation = null;
  const officialLobbyEventOperations = new WeakMap();
  // Only Authority treats this map as truth. Guests keep just their own
  // intent/ack state and can never author another player's readiness.
  const authorityReadyTokens = new Map();
  const remoteReadinessByNumber = new Map();
  let pendingReadySnapshot = null;
  let guestReadyToken = null;
  let guestReadiness = 'notReady';
  let guestReadyRequest = null;
  let guestPreparation = null;
  let startRound = null;

  const LOBBY_ACTIONS = Object.freeze([
    'joinCurrentSession',
    'startGameCountdown',
    'setReady',
    'startGame',
    'joinGame',
    'leaveLobby',
    'switchToSolo',
  ]);

  const publicLobbyFailure = error => {
    let internalCode = '';
    try {
      const descriptor =
        error && typeof error === 'object'
          ? Object.getOwnPropertyDescriptor(error, 'code')
          : null;
      if (
        descriptor &&
        'value' in descriptor &&
        typeof descriptor.value === 'string'
      ) {
        internalCode = descriptor.value;
      }
    } catch (_) {}
    const known = {
      PLAYMESH_GDEVELOP_NOT_ENOUGH_PLAYERS: [
        'NOT_ENOUGH_PLAYERS',
        'players_below_minimum',
        true,
      ],
      PLAYMESH_GDEVELOP_PLAYERS_NOT_READY: [
        'PLAYERS_NOT_READY',
        'players_not_ready',
        true,
      ],
      PLAYMESH_GDEVELOP_AUTHORITY_ONLY: [
        'ACTION_NOT_ALLOWED',
        'authority_required',
        false,
      ],
      PLAYMESH_GDEVELOP_GUEST_ONLY: [
        'ACTION_NOT_ALLOWED',
        'guest_required',
        false,
      ],
      PLAYMESH_GDEVELOP_CHANNEL_NOT_READY: [
        'CONNECTION_UNAVAILABLE',
        'multiplayer_channel_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_PLAYER_NUMBER_NOT_READY: [
        'PLAYER_STATE_PENDING',
        'player_number_pending',
        true,
      ],
      PLAYMESH_GDEVELOP_NO_SESSION: [
        'SESSION_UNAVAILABLE',
        'session_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_SOCKET_CLOSED: [
        'CONNECTION_UNAVAILABLE',
        'lobby_connection_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_CONNECTION_CLOSED: [
        'CONNECTION_UNAVAILABLE',
        'lobby_connection_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_BOOTSTRAP_UNAVAILABLE: [
        'SESSION_UNAVAILABLE',
        'multiplayer_runtime_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_RUNTIME_READY_TIMEOUT: [
        'SESSION_UNAVAILABLE',
        'multiplayer_runtime_unavailable',
        true,
      ],
      PLAYMESH_GDEVELOP_OPERATION_TIMEOUT: [
        'OPERATION_TIMEOUT',
        'operation_timed_out',
        true,
      ],
      PLAYMESH_GDEVELOP_OPERATION_IN_PROGRESS: [
        'OPERATION_IN_PROGRESS',
        'operation_in_progress',
        true,
      ],
      PLAYMESH_GDEVELOP_INVALID_STATE: [
        'INVALID_STATE',
        'lobby_state_changed',
        true,
      ],
    };
    const mapped = known[internalCode] || [
      'OPERATION_FAILED',
      'operation_failed',
      true,
    ];
    return Object.freeze({
      code: mapped[0],
      reason: mapped[1],
      retryable: mapped[2],
    });
  };

  const rollbackLobbyOperation = operation => {
    const state = operation?.state;
    if (!state || !state.active) return;
    if (operation.action === 'joinCurrentSession') state.joinRequested = false;
    else if (operation.action === 'startGameCountdown') {
      state.countdownRequested = false;
    }
    else if (operation.action === 'startGame') state.startRequested = false;
    else if (operation.action === 'joinGame') {
      state.joinGameRequested = false;
    } else if (operation.action === 'leaveLobby') state.leaveRequested = false;
    else if (operation.action === 'switchToSolo') state.soloRequested = false;
  };

  const settleLobbyOperation = (operation, failure = null) => {
    if (!operation || operation.settled) return false;
    operation.settled = true;
    if (operation.timer !== null) global.clearTimeout(operation.timer);
    try {
      operation.onSettled?.(failure);
    } catch (_) {}
    const { state, action, requestId } = operation;
    if (state?.pendingOperations?.get(action) === operation) {
      state.pendingOperations.delete(action);
    }
    if (failure) rollbackLobbyOperation(operation);
    if (!state?.active || activeLocalFrameByKind.lobby !== state) return false;
    if (!failure) {
      return postLocalFrameEnvelope(state, 'operationSucceeded', {
        action,
        requestId,
      });
    }
    const safeFailure = publicLobbyFailure(failure);
    return postLocalFrameEnvelope(state, 'operationFailed', {
      action,
      requestId,
      code: safeFailure.code,
      reason: safeFailure.reason,
      retryable: safeFailure.retryable,
    });
  };

  const beginLobbyOperation = (state, action, requestId) => {
    const existing = state.pendingOperations.get(action);
    if (existing && !existing.settled) return null;
    const operation = {
      state,
      action,
      requestId,
      settled: false,
      timer: null,
      onSettled: null,
    };
    operation.timer = global.setTimeout(() => {
      settleLobbyOperation(
        operation,
        Object.assign(new Error('Lobby operation timed out.'), {
          code: 'PLAYMESH_GDEVELOP_OPERATION_TIMEOUT',
        })
      );
    }, LOBBY_OPERATION_TIMEOUT_MS);
    operation.timer?.unref?.();
    state.pendingOperations.set(action, operation);
    return operation;
  };

  const currentLobbyOperation = action => {
    if (
      activeOfficialLobbyOperation &&
      (!action || activeOfficialLobbyOperation.action === action)
    ) {
      return activeOfficialLobbyOperation;
    }
    const state = activeLocalFrameByKind.lobby;
    return state?.pendingOperations?.get(action) || null;
  };

  const failCurrentLobbyOperation = (error, action = null) => {
    const operation = currentLobbyOperation(action);
    if (operation) settleLobbyOperation(operation, error);
  };

  const currentActualPlayerId = () => {
    if (authority) return session ? session.authorityClientId : authorityPeerId;
    return currentPlayer ? currentPlayer.id : null;
  };

  const currentOfficialPeerId = () =>
    authority ? authorityPeerId : currentActualPlayerId();

  const actualToOfficialPeerId = playerId =>
    session &&
    (playerId === session.authorityClientId || playerId === authorityPeerId)
      ? authorityPeerId
      : playerId;

  const officialToActualPlayerId = peerId => {
    validatePlayerId(peerId);
    if (peerId === authorityPeerId) {
      return session ? session.authorityClientId : authorityPeerId;
    }
    return peerId;
  };

  const playerNumberForActualId = playerId =>
    playerNumbers.assignments.get(playerId) || null;

  const currentPlayerNumber = () => {
    const actualId = currentActualPlayerId();
    if (!actualId) return null;
    return playerNumberForActualId(actualId);
  };

  const sessionPlayerByActualId = playerId => {
    if (!session) return null;
    if (playerId === session.authorityClientId) {
      return (
        session.players.find(player => player.id === playerId) ||
        Object.freeze({
          id: playerId,
          nickname: 'Host',
          role: 'authority',
          connected: true,
        })
      );
    }
    return session.players.find(player => player.id === playerId) || null;
  };

  const validatePeerTopology = remoteActualId => {
    if (!session) {
      fail('PLAYMESH_GDEVELOP_NO_SESSION', '当前没有 GDevelop 多人会话。');
    }
    const remote = sessionPlayerByActualId(remoteActualId);
    if (
      !remote ||
      !remote.connected ||
      !playerNumberForActualId(remoteActualId) ||
      !currentPlayerNumber()
    ) {
      fail('PLAYMESH_GDEVELOP_PEER_UNAVAILABLE', '目标 GDevelop 玩家不可用。');
    }
    if (authority) {
      if (remoteActualId === session.authorityClientId) {
        fail('PLAYMESH_GDEVELOP_INVALID_TOPOLOGY', 'Authority 不能连接自身。');
      }
    } else if (remoteActualId !== session.authorityClientId) {
      fail(
        'PLAYMESH_GDEVELOP_INVALID_TOPOLOGY',
        'GDevelop Guest 只能连接固定 Authority。'
      );
    }
  };

  const encodePacket = (type, body) => {
    const bodyBytes = body || new Uint8Array(0);
    if (!(bodyBytes instanceof Uint8Array)) {
      fail('PLAYMESH_GDEVELOP_INVALID_PACKET', 'GDevelop Binary 包体无效。');
    }
    if (PACKET_HEADER_BYTES + bodyBytes.byteLength > MAX_PACKET_BYTES) {
      fail('PLAYMESH_GDEVELOP_PACKET_TOO_LARGE', 'GDevelop Binary 包过大。');
    }
    const bytes = new Uint8Array(PACKET_HEADER_BYTES + bodyBytes.byteLength);
    bytes.set(PACKET_MAGIC, 0);
    bytes[4] = PACKET_VERSION;
    bytes[5] = type;
    bytes.set(bodyBytes, PACKET_HEADER_BYTES);
    return bytes;
  };

  const encodeDataPacket = value => {
    if (!hasExactKeys(value, ['messageName', 'data'])) {
      fail('PLAYMESH_GDEVELOP_INVALID_MESSAGE', 'GDevelop Peer 消息结构无效。');
    }
    const nameBytes = encoder.encode(value.messageName);
    if (
      !value.messageName ||
      nameBytes.byteLength > MAX_MESSAGE_NAME_BYTES
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_MESSAGE', 'GDevelop 消息名无效。');
    }
    let kind;
    let dataBytes;
    if (typeof value.data === 'string') {
      kind = DATA_STRING;
      dataBytes = encoder.encode(value.data);
    } else if (value.data instanceof Uint8Array) {
      kind = DATA_BYTES;
      dataBytes = value.data;
    } else {
      fail('PLAYMESH_GDEVELOP_INVALID_MESSAGE', 'GDevelop 消息数据类型无效。');
    }
    const body = new Uint8Array(3 + nameBytes.byteLength + dataBytes.byteLength);
    const view = new DataView(body.buffer);
    view.setUint16(0, nameBytes.byteLength, false);
    body[2] = kind;
    body.set(nameBytes, 3);
    body.set(dataBytes, 3 + nameBytes.byteLength);
    return encodePacket(PACKET_DATA, body);
  };

  const createReadinessToken = () => {
    if (!global.crypto || typeof global.crypto.getRandomValues !== 'function') {
      fail(
        'PLAYMESH_GDEVELOP_CRYPTO_UNAVAILABLE',
        '浏览器缺少安全随机数能力，不能创建 GDevelop 准备轮次。'
      );
    }
    const token = new Uint8Array(READINESS_TOKEN_BYTES);
    try {
      global.crypto.getRandomValues(token);
    } catch (_) {
      fail(
        'PLAYMESH_GDEVELOP_CRYPTO_UNAVAILABLE',
        '无法生成 GDevelop 准备轮次凭据。'
      );
    }
    return token;
  };

  const tokenKey = token =>
    Array.from(token, byte => byte.toString(16).padStart(2, '0')).join('');

  const sameToken = (left, right) =>
    left instanceof Uint8Array &&
    right instanceof Uint8Array &&
    left.byteLength === READINESS_TOKEN_BYTES &&
    right.byteLength === READINESS_TOKEN_BYTES &&
    left.every((byte, index) => byte === right[index]);

  const encodeReadyStatePacket = (type, ready, token) => {
    if (
      (type !== PACKET_READY_STATE && type !== PACKET_READY_ACK) ||
      typeof ready !== 'boolean' ||
      !(token instanceof Uint8Array) ||
      token.byteLength !== READINESS_TOKEN_BYTES
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_PACKET', 'GDevelop 准备状态包无效。');
    }
    const body = new Uint8Array(1 + READINESS_TOKEN_BYTES);
    body[0] = ready ? 1 : 0;
    body.set(token, 1);
    return encodePacket(type, body);
  };

  const encodeReadySnapshotPacket = (knownMask, readyMask, preparingMask) => {
    if (
      !isSafeInteger(playerNumbers.epoch, 1, 0xffffffff) ||
      !isSafeInteger(playerNumbers.revision, 1, 0xffffffff) ||
      !isSafeInteger(knownMask, 0, 0xff) ||
      !isSafeInteger(readyMask, 0, 0xff) ||
      !isSafeInteger(preparingMask, 0, 0xff) ||
      (readyMask & ~knownMask) !== 0 ||
      (preparingMask & ~knownMask) !== 0 ||
      (readyMask & preparingMask) !== 0
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_PACKET', 'GDevelop 准备快照无效。');
    }
    const body = new Uint8Array(11);
    const view = new DataView(body.buffer);
    view.setUint32(0, playerNumbers.epoch, false);
    view.setUint32(4, playerNumbers.revision, false);
    body[8] = knownMask;
    body[9] = readyMask;
    body[10] = preparingMask;
    return encodePacket(PACKET_READY_SNAPSHOT, body);
  };

  const encodePreparationPacket = (type, roundToken, readyToken) => {
    if (
      (type !== PACKET_PREPARE && type !== PACKET_PREPARED) ||
      !(roundToken instanceof Uint8Array) ||
      !(readyToken instanceof Uint8Array) ||
      roundToken.byteLength !== READINESS_TOKEN_BYTES ||
      readyToken.byteLength !== READINESS_TOKEN_BYTES
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_PACKET', 'GDevelop 开始轮次包无效。');
    }
    const body = new Uint8Array(READINESS_TOKEN_BYTES * 2);
    body.set(roundToken, 0);
    body.set(readyToken, READINESS_TOKEN_BYTES);
    return encodePacket(type, body);
  };

  const decodePacket = bytes => {
    if (!(bytes instanceof Uint8Array) || bytes.byteLength < PACKET_HEADER_BYTES) {
      return null;
    }
    if (
      bytes.byteLength > MAX_PACKET_BYTES ||
      PACKET_MAGIC.some((value, index) => bytes[index] !== value) ||
      bytes[4] !== PACKET_VERSION
    ) {
      return null;
    }
    const type = bytes[5];
    if (
      ![
        PACKET_CONNECT,
        PACKET_ACCEPT,
        PACKET_CLOSE,
        PACKET_DATA,
        PACKET_READY_STATE,
        PACKET_READY_ACK,
        PACKET_READY_SNAPSHOT,
        PACKET_PREPARE,
        PACKET_PREPARED,
      ].includes(type)
    ) {
      return null;
    }
    const body = bytes.subarray(PACKET_HEADER_BYTES);
    if (
      type === PACKET_CONNECT ||
      type === PACKET_ACCEPT ||
      type === PACKET_CLOSE
    ) {
      return body.byteLength === 0 ? { type } : null;
    }
    if (type === PACKET_READY_STATE || type === PACKET_READY_ACK) {
      if (
        body.byteLength !== 1 + READINESS_TOKEN_BYTES ||
        (body[0] !== 0 && body[0] !== 1)
      ) {
        return null;
      }
      return {
        type,
        ready: body[0] === 1,
        token: new Uint8Array(body.subarray(1)),
      };
    }
    if (type === PACKET_READY_SNAPSHOT) {
      if (
        body.byteLength !== 11 ||
        (body[9] & ~body[8]) !== 0 ||
        (body[10] & ~body[8]) !== 0 ||
        (body[9] & body[10]) !== 0
      ) {
        return null;
      }
      const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
      return {
        type,
        epoch: view.getUint32(0, false),
        revision: view.getUint32(4, false),
        knownMask: body[8],
        readyMask: body[9],
        preparingMask: body[10],
      };
    }
    if (type === PACKET_PREPARE || type === PACKET_PREPARED) {
      if (body.byteLength !== READINESS_TOKEN_BYTES * 2) return null;
      return {
        type,
        roundToken: new Uint8Array(body.subarray(0, READINESS_TOKEN_BYTES)),
        readyToken: new Uint8Array(body.subarray(READINESS_TOKEN_BYTES)),
      };
    }
    if (body.byteLength < 3) return null;
    const nameLength = new DataView(
      body.buffer,
      body.byteOffset,
      body.byteLength
    ).getUint16(0, false);
    if (
      nameLength < 1 ||
      nameLength > MAX_MESSAGE_NAME_BYTES ||
      3 + nameLength > body.byteLength ||
      (body[2] !== DATA_STRING && body[2] !== DATA_BYTES)
    ) {
      return null;
    }
    try {
      const messageName = decoder.decode(body.subarray(3, 3 + nameLength));
      const payload = body.subarray(3 + nameLength);
      return {
        type,
        message: {
          messageName,
          data:
            body[2] === DATA_STRING
              ? decoder.decode(payload)
              : new Uint8Array(payload),
        },
      };
    } catch (_) {
      return null;
    }
  };

  const sendBinary = (remoteOfficialId, bytes) => {
    if (!channel) {
      return Promise.reject(
        Object.assign(new Error('GDevelop Binary Channel 尚未就绪。'), {
          code: 'PLAYMESH_GDEVELOP_CHANNEL_NOT_READY',
        })
      );
    }
    const target = officialToActualPlayerId(remoteOfficialId);
    validatePeerTopology(target);
    try {
      return Promise.resolve(channel.send(target, bytes));
    } catch (error) {
      return Promise.reject(error);
    }
  };

  const eventSet = names => {
    const result = Object.create(null);
    names.forEach(name => {
      result[name] = new Set();
    });
    return result;
  };

  const emitListeners = (listeners, name, value) => {
    const callbacks = listeners[name];
    if (!callbacks) return;
    [...callbacks].forEach(callback => {
      try {
        callback(value);
      } catch (error) {
        global.console?.error?.('Playmesh GDevelop listener failed', error);
      }
    });
  };

  const emitPeerEvent = (name, value) => {
    if (!peer) return;
    emitListeners(peer.__listeners, name, value);
  };

  const deliverSocketPayload = (socket, payload, attemptsLeft) =>
    socket.__emitSettled(payload).then(delivered => {
      if (delivered) return true;
      if (attemptsLeft > 1) {
        return deliverSocketPayload(socket, payload, attemptsLeft - 1);
      }
      throw runtimeFailure(
        'PLAYMESH_GDEVELOP_CONNECTION_NOT_READY',
        'GDevelop 官方控制事件暂不可投递。'
      );
    });

  const notifyLobbySocketGameStarted = socket => {
    if (!session || session.state !== 'running' || socket.__state.gameStarted) {
      return;
    }
    if (socket.__state.gameStartedPending) return;
    const deliveryGeneration = socket.__state.gameStartedGeneration;
    if (!authority) {
      const hostConnection = connections.get(authorityPeerId);
      if (
        !hostConnection ||
        !hostConnection.__open ||
        hostConnection.__closed ||
        !hostConnection.__officialReady
      ) {
        return;
      }
    }
    socket.__state.gameStartedPending = true;
    void deliverSocketPayload(
      socket,
      { type: 'gameStarted', data: { heartbeatInterval: 30000 } },
      CONTROL_DELIVERY_ATTEMPTS
    ).then(
      () => {
        if (
          socket.__state.gameStartedGeneration !== deliveryGeneration ||
          session?.state !== 'running'
        ) {
          socket.__state.gameStartedPending = false;
          return;
        }
        socket.__state.gameStartedPending = false;
        socket.__state.gameStarted = true;
      },
      error => {
        if (socket.__state.gameStartedGeneration !== deliveryGeneration) return;
        socket.__state.gameStartedPending = false;
        socket.__fail(error);
      }
    );
  };

  const notifyGuestGameStarted = () => {
    if (authority) return;
    lobbySockets.forEach(notifyLobbySocketGameStarted);
  };

  const createConnection = (remoteOfficialId, incoming) => {
    const remoteActualId = officialToActualPlayerId(remoteOfficialId);
    validatePeerTopology(remoteActualId);
    const normalizedRemote = actualToOfficialPeerId(remoteActualId);
    const existing = connections.get(normalizedRemote);
    if (existing && !existing.__closed) return existing;
    const listeners = eventSet([
      'open',
      'data',
      'error',
      'close',
      'iceStateChanged',
    ]);
    let opened = false;
    let closed = false;
    let officialReady = false;

    // GDevelop 的官方断线检查器只需要 connectionState；不向上层泄漏底层传输句柄。
    const peerConnectionFacade = Object.create(null);
    Object.defineProperty(peerConnectionFacade, 'connectionState', {
      enumerable: true,
      get: () => (closed ? 'closed' : opened ? 'connected' : 'connecting'),
    });
    Object.freeze(peerConnectionFacade);

    const connection = {
      peer: normalizedRemote,
      on(event, handler) {
        if (!Object.prototype.hasOwnProperty.call(listeners, event)) {
          fail('PLAYMESH_GDEVELOP_INVALID_EVENT', '不支持的 DataConnection 事件。');
        }
        if (typeof handler !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'DataConnection handler 无效。');
        }
        listeners[event].add(handler);
        if (event === 'open' && opened && !closed) defer(() => handler());
      },
      send(data) {
        if (!opened || closed) {
          fail('PLAYMESH_GDEVELOP_CONNECTION_CLOSED', 'GDevelop 逻辑连接未打开。');
        }
        const bytes = encodeDataPacket(data);
        void sendBinary(normalizedRemote, bytes).catch(error => {
          emitListeners(listeners, 'error', error);
        });
      },
      close() {
        closeConnection(connection, true);
      },
    };
    Object.defineProperties(connection, {
      peerConnection: {
        value: peerConnectionFacade,
        enumerable: true,
      },
      __listeners: { value: listeners },
      __open: { get: () => opened },
      __closed: { get: () => closed },
      __officialReady: { get: () => officialReady },
      __markOpen: {
        value: () => {
          if (opened || closed) return;
          opened = true;
          emitListeners(listeners, 'open');
          notifyGuestGameStarted();
        },
      },
      __markOfficialReady: {
        value: () => {
          if (!opened || closed) return false;
          officialReady = true;
          return true;
        },
      },
      __markClosed: {
        value: () => {
          if (closed) return false;
          closed = true;
          opened = false;
          if (connections.get(normalizedRemote) === connection) {
            connections.delete(normalizedRemote);
          }
          emitListeners(listeners, 'close');
          return true;
        },
      },
      __incoming: { value: incoming },
    });
    Object.seal(connection);
    connections.set(normalizedRemote, connection);
    return connection;
  };

  function closeConnection(connection, notifyRemote) {
    if (!connection || !connection.__markClosed()) return;
    if (notifyRemote && channel) {
      void sendBinary(
        connection.peer,
        encodePacket(PACKET_CLOSE)
      ).catch(() => {});
    }
  }

  const activeGuestLobbyFrame = () => {
    const state = activeLocalFrameByKind.lobby;
    return Boolean(
      !authority &&
        session?.state === 'lobby' &&
        state?.active &&
        state.joined &&
        state.sessionId === session.id
    );
  };

  const readinessForActualPlayerId = playerId => {
    if (!session || !playerId) return 'unknown';
    if (playerId === session.authorityClientId) return 'ready';
    if (authority) {
      if (!playerNumbers.assignments.has(playerId)) return 'unknown';
      const readyToken = authorityReadyTokens.get(playerId);
      if (!readyToken) return 'notReady';
      if (
        startRound?.expected?.has(playerId) &&
        !startRound.prepared.has(playerId)
      ) {
        return 'preparing';
      }
      return 'ready';
    }
    if (playerId === currentActualPlayerId()) return guestReadiness;
    const number = playerNumberForActualId(playerId);
    return remoteReadinessByNumber.get(number) || 'unknown';
  };

  const notifyLocalReadinessChanged = () => {
    const state = activeLocalFrameByKind.lobby;
    if (state?.active && state.sessionId === session?.id) {
      postLocalFramePlayerVisuals(state);
    }
  };

  const currentAuthorityReadySnapshot = () => {
    let knownMask = 0;
    let readyMask = 0;
    let preparingMask = 0;
    if (!authority || !session) return { knownMask, readyMask, preparingMask };
    session.players.forEach(player => {
      const number = playerNumberForActualId(player.id);
      if (!isSafeInteger(number, 1, MAX_PLAYERS)) return;
      const bit = 1 << (number - 1);
      knownMask |= bit;
      const readiness = readinessForActualPlayerId(player.id);
      if (readiness === 'ready') readyMask |= bit;
      else if (readiness === 'preparing') preparingMask |= bit;
    });
    return { knownMask, readyMask, preparingMask };
  };

  const broadcastAuthorityReadySnapshot = () => {
    if (!authority || !session || !channel) return;
    let packet;
    try {
      const snapshot = currentAuthorityReadySnapshot();
      packet = encodeReadySnapshotPacket(
        snapshot.knownMask,
        snapshot.readyMask,
        snapshot.preparingMask
      );
    } catch (_) {
      return;
    }
    session.players.forEach(player => {
      if (
        !player.connected ||
        player.id === session.authorityClientId ||
        !playerNumberForActualId(player.id)
      ) {
        return;
      }
      void sendBinary(actualToOfficialPeerId(player.id), packet).catch(() => {});
    });
    notifyLocalReadinessChanged();
  };

  const applyReadySnapshot = packet => {
    if (authority) return;
    if (
      packet.epoch !== playerNumbers.epoch ||
      packet.revision !== playerNumbers.revision
    ) {
      pendingReadySnapshot = packet;
      return;
    }
    pendingReadySnapshot = null;
    remoteReadinessByNumber.clear();
    for (let number = 1; number <= MAX_PLAYERS; number += 1) {
      const bit = 1 << (number - 1);
      if ((packet.knownMask & bit) === 0) continue;
      remoteReadinessByNumber.set(
        number,
        (packet.preparingMask & bit) !== 0
          ? 'preparing'
          : (packet.readyMask & bit) !== 0
            ? 'ready'
            : 'notReady'
      );
    }
    notifyLocalReadinessChanged();
  };

  const sendGuestReadyState = (ready, token) =>
    sendBinary(
      authorityPeerId,
      encodeReadyStatePacket(PACKET_READY_STATE, ready, token)
    );

  const resetGuestPeerPreparation = () => {
    const hostConnection = connections.get(authorityPeerId);
    if (hostConnection) closeConnection(hostConnection, true);
    lobbySockets.forEach(socket => {
      socket.__state.authorityPeerGeneration += 1;
      socket.__state.authorityPeerAnnouncement = null;
      socket.__state.authorityPeerAnnounced = false;
    });
  };

  const discardGuestPreparation = () => {
    const preparation = guestPreparation;
    guestPreparation = null;
    if (preparation?.timer !== null && preparation?.timer !== undefined) {
      global.clearTimeout(preparation.timer);
    }
  };

  const clearGuestReadiness = (
    notifyAuthority = true,
    teardownPeer = true
  ) => {
    if (authority || !guestReadyToken) {
      guestReadiness = 'notReady';
      guestReadyToken = null;
      guestReadyRequest = null;
      discardGuestPreparation();
      return;
    }
    const token = guestReadyToken;
    guestReadiness = 'notReady';
    guestReadyToken = null;
    guestReadyRequest = null;
    discardGuestPreparation();
    if (teardownPeer) resetGuestPeerPreparation();
    notifyLocalReadinessChanged();
    if (notifyAuthority && session?.state === 'lobby' && channel) {
      void sendGuestReadyState(false, token).catch(() => {});
    }
  };

  const requestGuestIntentReady = (ready, operation) => {
    if (
      authority ||
      !operation ||
      !session ||
      session.state !== 'lobby' ||
      !activeGuestLobbyFrame()
    ) {
      const error = runtimeFailure(
        'PLAYMESH_GDEVELOP_INVALID_STATE',
        '当前状态不能修改准备状态。'
      );
      settleLobbyOperation(operation, error);
      return;
    }
    if (guestReadyRequest) {
      settleLobbyOperation(
        operation,
        runtimeFailure(
          'PLAYMESH_GDEVELOP_OPERATION_IN_PROGRESS',
          '准备状态正在确认。'
        )
      );
      return;
    }
    if (ready === (guestReadiness === 'ready')) {
      settleLobbyOperation(operation);
      return;
    }
    const previousToken = guestReadyToken;
    const token = ready ? createReadinessToken() : previousToken;
    if (!token) {
      guestReadiness = 'notReady';
      settleLobbyOperation(operation);
      return;
    }
    if (ready) guestReadyToken = token;
    const request = { ready, token, operation, previousToken };
    guestReadyRequest = request;
    void sendGuestReadyState(ready, token).catch(error => {
      if (guestReadyRequest !== request) return;
      guestReadyRequest = null;
      if (ready) guestReadyToken = previousToken;
      settleLobbyOperation(operation, error);
    });
  };

  const connectedGuestIds = () =>
    session
      ? session.players
          .filter(
            player =>
              player.connected && player.id !== session.authorityClientId
          )
          .map(player => player.id)
          .sort()
      : [];

  const sameFrozenParticipants = round => {
    if (
      !round ||
      !session ||
      session.state !== 'lobby' ||
      playerNumbers.epoch !== round.playerNumberEpoch ||
      playerNumbers.revision !== round.playerNumberRevision
    ) {
      return false;
    }
    const current = connectedGuestIds();
    const expected = [...round.expected.keys()].sort();
    if (
      current.length !== expected.length ||
      current.some((playerId, index) => playerId !== expected[index])
    ) {
      return false;
    }
    return expected.every(
      playerId =>
        sameToken(
          authorityReadyTokens.get(playerId),
          round.expected.get(playerId)
        ) &&
        playerNumberForActualId(playerId) === round.playerNumbers.get(playerId)
    );
  };

  const cancelStartRound = error => {
    const round = startRound;
    if (!round) return;
    startRound = null;
    if (!round.settled) {
      round.settled = true;
      round.reject?.(error);
    }
    broadcastAuthorityReadySnapshot();
  };

  const completeStartPreparationIfReady = () => {
    const round = startRound;
    if (!round || round.settled || !sameFrozenParticipants(round)) return false;
    if ([...round.expected.keys()].some(playerId => !round.prepared.has(playerId))) {
      return false;
    }
    round.preflightComplete = true;
    round.settled = true;
    round.resolve?.();
    broadcastAuthorityReadySnapshot();
    return true;
  };

  const invokePreparedStartIfReady = round => {
    if (
      !round ||
      startRound !== round ||
      !round.preflightComplete ||
      !round.startIntentReceived ||
      round.startInvoked ||
      !sameFrozenParticipants(round)
    ) {
      return false;
    }
    round.startInvoked = true;
    void Promise.resolve()
      .then(() => {
        if (
          startRound !== round ||
          !sameFrozenParticipants(round) ||
          [...round.expected.keys()].some(
            playerId => !round.prepared.has(playerId)
          )
        ) {
          throw runtimeFailure(
            'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
            'GDevelop 开始前最终准备复核失败。'
          );
        }
        return main.session.start();
      })
      .then(() => {
        if (startRound === round) settleLobbyOperation(round.operation);
      })
      .catch(error => {
        if (startRound !== round) return;
        settleLobbyOperation(round.operation, error);
        cancelStartRound(error);
      });
    return true;
  };

  const beginStartRound = operation => {
    if (!authority || !session || session.state !== 'lobby') {
      throw runtimeFailure(
        'PLAYMESH_GDEVELOP_INVALID_STATE',
        '当前会话不能开始准备。'
      );
    }
    if (startRound) {
      throw runtimeFailure(
        'PLAYMESH_GDEVELOP_OPERATION_IN_PROGRESS',
        '已有 GDevelop 开始准备轮次。'
      );
    }
    const expected = new Map();
    const frozenPlayerNumbers = new Map();
    for (const playerId of connectedGuestIds()) {
      const token = authorityReadyTokens.get(playerId);
      const playerNumber = playerNumberForActualId(playerId);
      if (!token || !isSafeInteger(playerNumber, 2, MAX_PLAYERS)) {
        throw runtimeFailure(
          'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
          '仍有在线玩家尚未准备。'
        );
      }
      expected.set(playerId, new Uint8Array(token));
      frozenPlayerNumbers.set(playerId, playerNumber);
    }
    const round = {
      token: createReadinessToken(),
      expected,
      playerNumbers: frozenPlayerNumbers,
      playerNumberEpoch: playerNumbers.epoch,
      playerNumberRevision: playerNumbers.revision,
      prepared: new Set(),
      packetsDispatched: false,
      preflightComplete: false,
      startIntentReceived: true,
      startInvoked: false,
      settled: false,
      operation,
      resolve: null,
      reject: null,
    };
    startRound = round;
    operation.onSettled = failure => {
      if (failure && startRound === round) cancelStartRound(failure);
    };
    broadcastAuthorityReadySnapshot();
    return new Promise((resolve, reject) => {
      round.resolve = resolve;
      round.reject = reject;
    });
  };

  const dispatchStartPreparation = () => {
    const round = startRound;
    if (!round || round.packetsDispatched || round.settled) return;
    round.packetsDispatched = true;
    const sends = [...round.expected.entries()].map(([playerId, readyToken]) =>
      sendBinary(
        actualToOfficialPeerId(playerId),
        encodePreparationPacket(PACKET_PREPARE, round.token, readyToken)
      )
    );
    if (sends.length === 0) {
      completeStartPreparationIfReady();
      return;
    }
    void Promise.all(sends).catch(error => {
      if (startRound !== round) return;
      settleLobbyOperation(round.operation, error);
      cancelStartRound(error);
    });
  };

  const handleReadyStatePacket = (packet, senderActualId, senderOfficialId) => {
    if (!authority || session?.state !== 'lobby') return;
    const current = authorityReadyTokens.get(senderActualId);
    if (packet.ready) {
      if (
        startRound?.expected.has(senderActualId) &&
        (!current || !sameToken(current, packet.token))
      ) {
        const error = runtimeFailure(
          'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
          '玩家准备代次在开始阶段发生变化。'
        );
        settleLobbyOperation(startRound.operation, error);
        cancelStartRound(error);
      }
      authorityReadyTokens.set(senderActualId, new Uint8Array(packet.token));
    } else if (current && !sameToken(current, packet.token)) {
      void sendBinary(
        senderOfficialId,
        encodeReadyStatePacket(PACKET_READY_ACK, true, current)
      ).catch(() => {});
      broadcastAuthorityReadySnapshot();
      return;
    } else {
      authorityReadyTokens.delete(senderActualId);
      if (startRound?.expected.has(senderActualId)) {
        const error = runtimeFailure(
          'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
          '玩家在开始阶段取消了准备。'
        );
        settleLobbyOperation(startRound.operation, error);
        cancelStartRound(error);
      }
    }
    void sendBinary(
      senderOfficialId,
      encodeReadyStatePacket(PACKET_READY_ACK, packet.ready, packet.token)
    ).catch(() => {});
    broadcastAuthorityReadySnapshot();
  };

  const handleReadyAckPacket = packet => {
    const request = guestReadyRequest;
    if (
      authority ||
      !request ||
      packet.ready !== request.ready ||
      !sameToken(packet.token, request.token)
    ) {
      return;
    }
    guestReadyRequest = null;
    const operation = request.operation;
    if (packet.ready) {
      guestReadiness = 'ready';
    } else {
      guestReadiness = 'notReady';
      guestReadyToken = null;
      discardGuestPreparation();
      resetGuestPeerPreparation();
    }
    notifyLocalReadinessChanged();
    settleLobbyOperation(operation);
  };

  const handlePreparePacket = packet => {
    const replacingPreparation =
      guestReadiness === 'preparing' &&
      guestPreparation &&
      guestReadyToken &&
      sameToken(packet.readyToken, guestReadyToken);
    if (
      authority ||
      session?.state !== 'lobby' ||
      (guestReadiness !== 'ready' && !replacingPreparation) ||
      !guestReadyToken ||
      !sameToken(packet.readyToken, guestReadyToken) ||
      !activeGuestLobbyFrame()
    ) {
      return;
    }
    if (
      guestPreparation &&
      sameToken(guestPreparation.roundToken, packet.roundToken)
    ) {
      return;
    }
    if (guestPreparation) {
      const hostConnection = connections.get(authorityPeerId);
      if (!hostConnection?.__officialReady) resetGuestPeerPreparation();
    }
    discardGuestPreparation();
    guestReadiness = 'preparing';
    const preparation = {
      roundToken: new Uint8Array(packet.roundToken),
      readyToken: new Uint8Array(packet.readyToken),
      timer: null,
    };
    guestPreparation = preparation;
    preparation.timer = global.setTimeout(() => {
      if (guestPreparation !== preparation) return;
      resetGuestPeerPreparation();
      discardGuestPreparation();
      if (
        session?.state === 'lobby' &&
        guestReadyToken &&
        sameToken(preparation.readyToken, guestReadyToken) &&
        activeGuestLobbyFrame()
      ) {
        guestReadiness = 'ready';
      } else {
        guestReadiness = 'notReady';
      }
      notifyLocalReadinessChanged();
    }, LOBBY_OPERATION_TIMEOUT_MS);
    notifyLocalReadinessChanged();
    const sockets = [...lobbySockets];
    if (sockets.length === 0) {
      discardGuestPreparation();
      guestReadiness = 'ready';
      notifyLocalReadinessChanged();
      return;
    }
    const deliveries = sockets.map(socket =>
      deliverSocketPayload(
        socket,
        {
          type: 'gameCountdownStarted',
          data: { compressionMethod: socket.__state.compressionMethod },
        },
        CONTROL_DELIVERY_ATTEMPTS
      )
        .catch(error => {
          socket.__fail(error);
          throw error;
        })
        .then(() => emitAuthorityPeerAndMaybeStart(socket))
    );
    void Promise.all(deliveries).then(
      () => {
        if (guestPreparation !== preparation) return;
        const hostConnection = connections.get(authorityPeerId);
        if (hostConnection?.__officialReady) sendGuestPrepared();
      },
      () => {
        if (guestPreparation !== preparation) return;
        resetGuestPeerPreparation();
        discardGuestPreparation();
        guestReadiness = 'ready';
        notifyLocalReadinessChanged();
      }
    );
  };

  const sendGuestPrepared = () => {
    const preparation = guestPreparation;
    const hostConnection = connections.get(authorityPeerId);
    if (
      authority ||
      session?.state !== 'lobby' ||
      !preparation ||
      !guestReadyToken ||
      !sameToken(preparation.readyToken, guestReadyToken) ||
      !activeGuestLobbyFrame() ||
      !hostConnection?.__officialReady
    ) {
      return false;
    }
    void sendBinary(
      authorityPeerId,
      encodePreparationPacket(
        PACKET_PREPARED,
        preparation.roundToken,
        preparation.readyToken
      )
    ).then(
      () => {
        if (guestPreparation !== preparation) return;
        discardGuestPreparation();
        guestReadiness = 'ready';
        notifyLocalReadinessChanged();
      },
      () => {}
    );
    return true;
  };

  const handlePreparedPacket = (packet, senderActualId) => {
    const round = startRound;
    if (
      !authority ||
      !round ||
      round.settled ||
      !sameToken(packet.roundToken, round.token) ||
      !round.expected.has(senderActualId) ||
      !sameToken(packet.readyToken, round.expected.get(senderActualId)) ||
      !sameToken(authorityReadyTokens.get(senderActualId), packet.readyToken)
    ) {
      return;
    }
    const connection = connections.get(actualToOfficialPeerId(senderActualId));
    if (!connection || !connection.__open || connection.__closed) return;
    round.prepared.add(senderActualId);
    completeStartPreparationIfReady();
  };

  const handlePacket = (bytes, context) => {
    if (
      !hasExactKeys(context, ['senderPlayerId', 'delivery']) ||
      !isBoundedString(context.senderPlayerId, MAX_PLAYER_ID_BYTES) ||
      (context.delivery !== 'queued' && context.delivery !== 'latest')
    ) {
      return;
    }
    const packet = decodePacket(bytes);
    if (!packet || !session) return;
    const senderActualId = officialToActualPlayerId(context.senderPlayerId);
    const sender = sessionPlayerByActualId(senderActualId);
    if (!sender || !sender.connected) return;
    const senderOfficialId = actualToOfficialPeerId(senderActualId);
    try {
      validatePeerTopology(senderActualId);
    } catch (_) {
      return;
    }
    if (packet.type === PACKET_READY_STATE) {
      handleReadyStatePacket(packet, senderActualId, senderOfficialId);
      return;
    }
    if (
      packet.type === PACKET_READY_ACK &&
      senderActualId === session.authorityClientId
    ) {
      handleReadyAckPacket(packet);
      return;
    }
    if (
      packet.type === PACKET_READY_SNAPSHOT &&
      senderActualId === session.authorityClientId
    ) {
      applyReadySnapshot(packet);
      return;
    }
    if (
      packet.type === PACKET_PREPARE &&
      senderActualId === session.authorityClientId
    ) {
      handlePreparePacket(packet);
      return;
    }
    if (packet.type === PACKET_PREPARED) {
      handlePreparedPacket(packet, senderActualId);
      return;
    }
    if (!peer) {
      if (!acceptPeerPackets) return;
      if (pendingPackets.length < 32) pendingPackets.push({ bytes, context });
      return;
    }
    if (packet.type === PACKET_CONNECT) {
      const connection = createConnection(senderOfficialId, true);
      emitPeerEvent('connection', connection);
      defer(() => connection.__markOpen());
      void sendBinary(senderOfficialId, encodePacket(PACKET_ACCEPT)).catch(error => {
        emitListeners(connection.__listeners, 'error', error);
      });
      return;
    }
    const connection = connections.get(senderOfficialId);
    if (!connection || connection.__closed) return;
    if (packet.type === PACKET_ACCEPT) {
      connection.__markOpen();
    } else if (packet.type === PACKET_CLOSE) {
      closeConnection(connection, false);
    } else if (packet.type === PACKET_DATA && connection.__open) {
      emitListeners(connection.__listeners, 'data', packet.message);
    }
  };

  function createOfficialPeer() {
    if (arguments.length) {
      fail(
        'PLAYMESH_GDEVELOP_FORBIDDEN_ARGUMENT',
        'GDevelop Peer façade 不接受 PeerJS 配置。'
      );
    }
    acceptPeerPackets = true;
    if (peer) return peer;
    const listeners = eventSet([
      'open',
      'error',
      'connection',
      'close',
      'disconnected',
    ]);
    const value = {
      get id() {
        return currentOfficialPeerId() || '';
      },
      on(event, handler) {
        if (!Object.prototype.hasOwnProperty.call(listeners, event)) {
          fail('PLAYMESH_GDEVELOP_INVALID_EVENT', '不支持的 Peer 事件。');
        }
        if (typeof handler !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'Peer handler 无效。');
        }
        listeners[event].add(handler);
        if (event === 'open' && peerOpen) defer(() => handler());
      },
      connect(remoteOfficialId) {
        const connection = createConnection(remoteOfficialId, false);
        void sendBinary(remoteOfficialId, encodePacket(PACKET_CONNECT)).catch(error => {
          emitListeners(connection.__listeners, 'error', error);
        });
        return connection;
      },
      reconnect() {
        if (!peerOpen) {
          peerOpen = true;
          defer(() => emitListeners(listeners, 'open'));
        }
      },
    };
    Object.defineProperty(value, '__listeners', { value: listeners });
    peer = Object.freeze(value);
    peerOpen = true;
    defer(() => emitListeners(listeners, 'open'));
    const queued = pendingPackets.splice(0);
    queued.forEach(item => handlePacket(item.bytes, item.context));
    return peer;
  }

  const validatePlayerNumberSnapshot = value => {
    if (
      !hasExactKeys(
        value,
        ['type', 'protocol', 'version', 'sessionId', 'epoch', 'revision', 'assignments'],
        ['errorCode']
      ) ||
      value.type !== 'playerNumbers.snapshot' ||
      value.protocol !== PROTOCOL ||
      value.version !== PROTOCOL_VERSION ||
      !session ||
      value.sessionId !== session.id ||
      !isSafeInteger(value.epoch, 1, Number.MAX_SAFE_INTEGER) ||
      !isSafeInteger(value.revision, 1, Number.MAX_SAFE_INTEGER) ||
      !Array.isArray(value.assignments) ||
      value.assignments.length < 1 ||
      value.assignments.length > MAX_PLAYERS ||
      (value.errorCode !== undefined &&
        value.errorCode !== null &&
        value.errorCode !== 'PLAYER_LIMIT_EXCEEDED')
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_PLAYER_NUMBERS', '稳定玩家编号快照无效。');
    }
    const assignments = new Map();
    const numbers = new Set();
    value.assignments.forEach(entry => {
      if (
        !hasExactKeys(entry, ['playerId', 'playerNumber']) ||
        !isBoundedString(entry.playerId, MAX_PLAYER_ID_BYTES) ||
        !isSafeInteger(entry.playerNumber, 1, MAX_PLAYERS) ||
        assignments.has(entry.playerId) ||
        numbers.has(entry.playerNumber)
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_PLAYER_NUMBERS', '玩家编号映射无效。');
      }
      assignments.set(entry.playerId, entry.playerNumber);
      numbers.add(entry.playerNumber);
    });
    if (assignments.get(session.authorityClientId) !== 1) {
      fail(
        'PLAYMESH_GDEVELOP_INVALID_PLAYER_NUMBERS',
        '固定 Authority 必须使用玩家编号 1。'
      );
    }
    return {
      sessionId: value.sessionId,
      epoch: value.epoch,
      revision: value.revision,
      assignments,
      errorCode: value.errorCode || null,
    };
  };

  const applyPlayerNumberSnapshot = value => {
    const next = validatePlayerNumberSnapshot(value);
    if (
      next.epoch < playerNumbers.epoch ||
      (next.epoch === playerNumbers.epoch &&
        next.revision <= playerNumbers.revision)
    ) {
      return false;
    }
    playerNumbers = next;
    if (
      pendingReadySnapshot &&
      pendingReadySnapshot.epoch === next.epoch &&
      pendingReadySnapshot.revision === next.revision
    ) {
      applyReadySnapshot(pendingReadySnapshot);
    }
    if (authority) broadcastAuthorityReadySnapshot();
    notifyCoordinatorNegotiationWaiters();
    localFrameStates.forEach(state => {
      if (state.kind === 'lobby') refreshLocalFramePlayerAvatars(state);
    });
    notifyLobbySessionChanged();
    return true;
  };

  const connectedPlayerCount = () => {
    if (!session) return 0;
    const ids = new Set(
      session.players.filter(player => player.connected).map(player => player.id)
    );
    ids.add(session.authorityClientId);
    return ids.size;
  };

  const buildLobby = () => {
    if (!session) {
      fail('PLAYMESH_GDEVELOP_NO_SESSION', '当前没有 GDevelop 多人会话。');
    }
    const players = [];
    playerNumbers.assignments.forEach((playerNumber, playerId) => {
      const record = sessionPlayerByActualId(playerId);
      if (!record) return;
      players.push({
        playerId,
        status:
          session.state === 'running'
            ? record.connected
              ? 'playing'
              : 'left'
            : record.connected
              ? 'connected'
              : 'waiting',
        playerNumber,
      });
    });
    players.sort((left, right) => left.playerNumber - right.playerNumber);
    return {
      id: session.id,
      minPlayers: session.minPlayers,
      maxPlayers: Math.min(session.maxPlayers, MAX_PLAYERS),
      canJoinAfterStart: true,
      players,
      status:
        session.state === 'running' || session.state === 'paused'
          ? 'playing'
          : 'waiting',
    };
  };

  const validateGameId = gameId => {
    if (!isBoundedString(gameId, 160)) {
      fail('PLAYMESH_GDEVELOP_INVALID_GAME_ID', 'GDevelop gameId 无效。');
    }
    if (officialGameId === null) {
      officialGameId = gameId;
    } else if (officialGameId !== gameId) {
      fail('PLAYMESH_GDEVELOP_SCOPE_MISMATCH', 'GDevelop gameId 与当前游戏不匹配。');
    }
  };

  const validateLobbyId = lobbyId => {
    if (!session || lobbyId !== session.id) {
      fail('PLAYMESH_GDEVELOP_SCOPE_MISMATCH', 'GDevelop lobbyId 与当前会话不匹配。');
    }
  };

  const isValidPlayersInfo = (playersInfo, includePing) => {
    const values = readDenseDataArray(playersInfo, MAX_PLAYERS);
    if (!values) return false;
    const playerIds = new Set();
    const playerNumbersSeen = new Set();
    return values.every(playerInfo => {
      const record = readExactDataRecord(
        playerInfo,
        includePing
          ? ['playerNumber', 'playerId', 'ping']
          : ['playerNumber', 'playerId']
      );
      if (
        !record ||
        !isSafeInteger(record.playerNumber, 1, MAX_PLAYERS) ||
        !isBoundedString(record.playerId, MAX_PLAYER_ID_BYTES) ||
        (includePing &&
          (typeof record.ping !== 'number' ||
            !Number.isFinite(record.ping) ||
            record.ping < 0 ||
            record.ping > 600000)) ||
        playerIds.has(record.playerId) ||
        playerNumbersSeen.has(record.playerNumber)
      ) {
        return false;
      }
      playerIds.add(record.playerId);
      playerNumbersSeen.add(record.playerNumber);
      return true;
    });
  };

  const isValidMigrationPlayersInfo = playersInfo =>
    isValidPlayersInfo(playersInfo, true);

  const currentMultiplayerRuntimeReadiness = candidateMain => {
    if (
      !candidateMain ||
      main !== candidateMain ||
      !session ||
      !channel ||
      channelSessionId !== session.id ||
      typeof unsubscribeChannel !== 'function' ||
      playerNumbers.sessionId !== session.id
    ) {
      return null;
    }
    const playerId = currentActualPlayerId();
    const playerNumber = currentPlayerNumber();
    if (!playerId || !playerNumber) return null;
    return Object.freeze({
      main: candidateMain,
      sessionId: session.id,
      channel,
      playerId,
      playerNumber,
    });
  };

  // GDevelop 会在首帧并发发起 lobby/auth 请求，而 bootstrap 需要先等待
  // Game SDK ready 再 attach 现有 coordinator。这里只做一次共享、有界等待：
  // 不主动 attach、不订阅 SDK，也不触碰 channel/go-core。
  const notifyCoordinatorNegotiationWaiters = () => {
    [...coordinatorNegotiationWaiters].forEach(waiter => {
      try {
        waiter();
      } catch (_) {
        // waiter 自己负责把错误收敛到 negotiation Promise。
      }
    });
  };

  const finishNegotiationWait = (record, timer, abortListener) => {
    if (timer !== null) {
      record.timers.delete(timer);
      global.clearTimeout(timer);
    }
    if (abortListener) record.abortListeners.delete(abortListener);
  };

  const waitNegotiationDelay = (record, delayMs) =>
    new Promise((resolve, reject) => {
      if (record.cancelled) {
        reject(record.cancelError);
        return;
      }
      let settled = false;
      let timer = null;
      const settle = (callback, value) => {
        if (settled) return;
        settled = true;
        finishNegotiationWait(record, timer, abortListener);
        callback(value);
      };
      const abortListener = error => settle(reject, error);
      record.abortListeners.add(abortListener);
      timer = global.setTimeout(() => settle(resolve), delayMs);
      record.timers.add(timer);
    });

  const waitNegotiationPromise = (
    record,
    promise,
    timeoutMs,
    timeoutError
  ) =>
    new Promise((resolve, reject) => {
      if (record.cancelled) {
        reject(record.cancelError);
        return;
      }
      let settled = false;
      let timer = null;
      const settle = (callback, value) => {
        if (settled) return;
        settled = true;
        finishNegotiationWait(record, timer, abortListener);
        callback(value);
      };
      const abortListener = error => settle(reject, error);
      record.abortListeners.add(abortListener);
      timer = global.setTimeout(() => settle(reject, timeoutError), timeoutMs);
      record.timers.add(timer);
      Promise.resolve(promise).then(
        value => settle(resolve, value),
        error => settle(reject, error)
      );
    });

  const discoverRuntimeMain = async record => {
    const attempts = Math.ceil(
      RUNTIME_READY_TIMEOUT_MS / RUNTIME_DISCOVERY_INTERVAL_MS
    );
    for (let attempt = 0; attempt <= attempts; attempt += 1) {
      const candidate = global.playmesh && global.playmesh.main;
      if (candidate && candidate.ready) return candidate;
      if (attempt === attempts) break;
      await waitNegotiationDelay(record, RUNTIME_DISCOVERY_INTERVAL_MS);
    }
    throw runtimeFailure(
      'PLAYMESH_GDEVELOP_RUNTIME_READY_TIMEOUT',
      '等待 Playmesh Game SDK ready 超时。'
    );
  };

  const waitForCoordinatorContext = (record, candidateMain) =>
    new Promise((resolve, reject) => {
      if (record.cancelled) {
        reject(record.cancelError);
        return;
      }
      let settled = false;
      let timer = null;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        coordinatorNegotiationWaiters.delete(inspect);
        finishNegotiationWait(record, timer, abortListener);
        callback(value);
      };
      const inspect = () => {
        if (main && main !== candidateMain) {
          finish(
            reject,
            runtimeFailure(
              'PLAYMESH_GDEVELOP_RUNTIME_MISMATCH',
              'GDevelop coordinator 绑定了不同的 Game SDK 实例。'
            )
          );
          return;
        }
        if (main === candidateMain && coordinatorContextRevision > 0) {
          if (!session) {
            finish(
              reject,
              runtimeFailure(
                'PLAYMESH_GDEVELOP_NO_SESSION',
                'Playmesh Game SDK ready，但当前没有 GDevelop 多人会话。'
              )
            );
            return;
          }
          if (currentMultiplayerRuntimeReadiness(candidateMain)) {
            finish(resolve, candidateMain);
          }
        }
      };
      const abortListener = error => finish(reject, error);
      record.abortListeners.add(abortListener);
      coordinatorNegotiationWaiters.add(inspect);
      timer = global.setTimeout(
        () =>
          finish(
            reject,
            runtimeFailure(
              'PLAYMESH_GDEVELOP_COORDINATOR_ATTACH_TIMEOUT',
              '等待现有 GDevelop coordinator attach/context 超时。'
            )
          ),
        COORDINATOR_ATTACH_TIMEOUT_MS
      );
      record.timers.add(timer);
      inspect();
    });

  const abortRuntimeNegotiation = error => {
    const record = runtimeNegotiation;
    if (!record || record.completed || record.cancelled) return;
    record.cancelled = true;
    record.cancelError = error;
    [...record.abortListeners].forEach(listener => listener(error));
    record.abortListeners.clear();
    [...record.timers].forEach(timer => global.clearTimeout(timer));
    record.timers.clear();
    if (runtimeNegotiation === record) runtimeNegotiation = null;
  };

  const ensureRuntimeNegotiated = () => {
    if (currentMultiplayerRuntimeReadiness(main)) {
      return Promise.resolve(main);
    }
    if (runtimeNegotiation && !runtimeNegotiation.completed) {
      return runtimeNegotiation.promise;
    }
    // 已成功的 negotiation 只对当时的 session/channel/player-number
    // 组合有效。当前 readiness 不完整时绝不复用旧的成功结果。
    if (runtimeNegotiation?.completed) runtimeNegotiation = null;
    const record = {
      generation: ++runtimeNegotiationGeneration,
      promise: null,
      timers: new Set(),
      abortListeners: new Set(),
      cancelled: false,
      cancelError: null,
      completed: false,
    };
    const operation = (async () => {
      const candidateMain = await discoverRuntimeMain(record);
      const readyTimeoutError = runtimeFailure(
        'PLAYMESH_GDEVELOP_RUNTIME_READY_TIMEOUT',
        '等待 Playmesh Game SDK ready 超时。'
      );
      try {
        await waitNegotiationPromise(
          record,
          candidateMain.ready,
          RUNTIME_READY_TIMEOUT_MS,
          readyTimeoutError
        );
      } catch (error) {
        if (
          error === readyTimeoutError ||
          (error === record.cancelError &&
            error?.code === 'PLAYMESH_GDEVELOP_NEGOTIATION_DISPOSED')
        ) {
          throw error;
        }
        throw runtimeFailure(
          'PLAYMESH_GDEVELOP_RUNTIME_READY_REJECTED',
          'Playmesh Game SDK ready 失败。',
          error
        );
      }
      validateRuntimeMain(candidateMain);
      return waitForCoordinatorContext(record, candidateMain);
    })();
    record.promise = operation;
    runtimeNegotiation = record;
    void operation.then(
      () => {
        record.completed = true;
        [...record.timers].forEach(timer => global.clearTimeout(timer));
        record.timers.clear();
        record.abortListeners.clear();
      },
      () => {
        if (runtimeNegotiation === record) runtimeNegotiation = null;
        [...record.timers].forEach(timer => global.clearTimeout(timer));
        record.timers.clear();
        record.abortListeners.clear();
      }
    );
    return operation;
  };

  const multiplayerRequest = async (operation, payload) => {
    if (
      ![
        'checkGameRegistration',
        'quickJoin',
        'getLobbyById',
        'heartbeat',
        'endGame',
        'migrateHost',
      ].includes(operation)
    ) {
      fail('PLAYMESH_GDEVELOP_UNKNOWN_OPERATION', '未知的 GDevelop lobby 操作。');
    }
    await ensureMultiplayerRuntimeOnline();
    if (!main || !session) {
      fail('PLAYMESH_GDEVELOP_NO_SESSION', 'GDevelop 多人后端尚未就绪。');
    }
    if (operation === 'checkGameRegistration') {
      if (!hasExactKeys(payload, ['gameId'])) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', '注册检查请求无效。');
      }
      validateGameId(payload.gameId);
      return Object.freeze({ registered: true });
    }
    if (operation === 'quickJoin') {
      if (
        !hasExactKeys(payload, [
          'gameId',
          'isPreview',
          'gameVersion',
          'supportedCompressionMethods',
        ]) ||
        typeof payload.isPreview !== 'boolean' ||
        !isBoundedString(payload.gameVersion, 64, true) ||
        !Array.isArray(payload.supportedCompressionMethods) ||
        payload.supportedCompressionMethods.length > 4 ||
        payload.supportedCompressionMethods.some(
          method => !['none', 'cs:gzip', 'cs:deflate'].includes(method)
        )
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', 'quickJoin 请求无效。');
      }
      validateGameId(payload.gameId);
      const lobby = buildLobby();
      // Playmesh already owns the one shared membership set for this game
      // session. Expose that session as the single official GDevelop lobby for
      // every participant instead of asking each client to discover/create a
      // second room. The game's Authority still enforces minPlayers on start.
      if (session.state === 'lobby') {
        return Object.freeze({ status: 'join-lobby', lobby });
      }
      return Object.freeze({ status: 'join-game', lobby });
    }
    if (operation === 'getLobbyById') {
      if (!hasExactKeys(payload, ['gameId', 'lobbyId'])) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', '大厅查询请求无效。');
      }
      validateGameId(payload.gameId);
      validateLobbyId(payload.lobbyId);
      return Object.freeze(buildLobby());
    }
    if (operation === 'heartbeat') {
      const request = readExactDataRecord(payload, [
        'gameId',
        'lobbyId',
        'players',
      ]);
      if (!request || !isValidPlayersInfo(request.players, false)) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', '大厅心跳请求无效。');
      }
      validateGameId(request.gameId);
      validateLobbyId(request.lobbyId);
      return Object.freeze({});
    }
    if (operation === 'endGame') {
      if (!hasExactKeys(payload, ['gameId', 'lobbyId'])) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', '结束游戏请求无效。');
      }
      validateGameId(payload.gameId);
      validateLobbyId(payload.lobbyId);
      if (!authority) {
        fail('PLAYMESH_GDEVELOP_AUTHORITY_ONLY', '只有固定 Authority 可以结束游戏。');
      }
      await main.session.finish();
      return Object.freeze({});
    }
    if (operation === 'migrateHost') {
      const modeProperty = readOwnDataValue(payload, 'mode');
      const isRead = modeProperty?.value === 'read';
      const isWrite = modeProperty?.value === 'write';
      const request =
        isRead || isWrite
          ? readExactDataRecord(
              payload,
              isRead
                ? ['gameId', 'lobbyId', 'mode', 'peerId']
                : [
                    'gameId',
                    'lobbyId',
                    'mode',
                    'peerId',
                    'playersInfo',
                  ]
            )
          : null;
      if (
        !request ||
        (isWrite &&
          !isValidMigrationPlayersInfo(request.playersInfo)) ||
        !isBoundedString(request.peerId, MAX_PLAYER_ID_BYTES, true)
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', 'host migration 请求无效。');
      }
      validateGameId(request.gameId);
      validateLobbyId(request.lobbyId);
    }
    fail(
      'PLAYMESH_GDEVELOP_FIXED_AUTHORITY',
      'Playmesh GDevelop 使用固定 Authority，不支持 host migration。'
    );
  };

  const makeControlSocket = (kind, onFrame) => {
    let readyState = 0;
    let onopen = null;
    let onmessage = null;
    let onclose = null;
    let onerror = null;
    const state = {
      kind,
      gameStarted: false,
      gameStartedPending: false,
      gameStartedGeneration: 0,
      authorityPeerAnnounced: false,
      authorityPeerAnnouncement: null,
      authorityPeerGeneration: 0,
      compressionMethod: 'none',
      operation: kind === 'lobby' ? activeOfficialLobbyOperation : null,
    };
    const reportFailure = error => {
      if (readyState >= 2) return;
      if (kind === 'lobby') {
        const operation = state.operation || activeOfficialLobbyOperation;
        if (operation) settleLobbyOperation(operation, error);
      }
      if (!onerror) return;
      defer(() => {
        try {
          onerror(error);
        } catch (_) {}
      });
    };
    const socket = {
      get readyState() {
        return readyState;
      },
      get onopen() {
        return onopen;
      },
      set onopen(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onopen 无效。');
        }
        onopen = value;
      },
      get onmessage() {
        return onmessage;
      },
      set onmessage(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onmessage 无效。');
        }
        onmessage = value;
      },
      get onclose() {
        return onclose;
      },
      set onclose(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onclose 无效。');
        }
        onclose = value;
      },
      get onerror() {
        return onerror;
      },
      set onerror(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onerror 无效。');
        }
        onerror = value;
      },
      send(value) {
        try {
          if (kind === 'lobby' && activeOfficialLobbyOperation) {
            state.operation = activeOfficialLobbyOperation;
          }
          if (readyState !== 1) {
            fail('PLAYMESH_GDEVELOP_SOCKET_CLOSED', 'GDevelop 控制 socket 未打开。');
          }
          let frame = value;
          if (typeof value === 'string') {
            if (encoder.encode(value).byteLength > MAX_CONTROL_FRAME_BYTES) {
              fail('PLAYMESH_GDEVELOP_FRAME_TOO_LARGE', 'GDevelop 控制帧过大。');
            }
            try {
              frame = JSON.parse(value);
            } catch (_) {
              fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'GDevelop 控制帧不是有效 JSON。');
            }
          }
          onFrame(socket, frame);
        } catch (error) {
          const isolated = Boolean(
            kind === 'lobby' &&
              (activeOfficialLobbyOperation || state.operation)
          );
          reportFailure(error);
          if (!isolated) throw error;
        }
      },
      close() {
        if (readyState >= 2) return;
        if (kind === 'lobby' && activeOfficialLobbyOperation) {
          state.operation = activeOfficialLobbyOperation;
        }
        readyState = 2;
        state.gameStartedGeneration += 1;
        state.gameStarted = false;
        state.gameStartedPending = false;
        state.authorityPeerGeneration += 1;
        state.authorityPeerAnnouncement = null;
        state.authorityPeerAnnounced = false;
        if (kind === 'lobby') lobbySockets.delete(socket);
        else authSockets.delete(socket);
        readyState = 3;
        if (onclose) {
          defer(() => {
            try {
              onclose();
            } catch (error) {
              reportFailure(error);
            }
          });
        }
      },
    };
    Object.defineProperties(socket, {
      __state: { value: state },
      __emit: {
        value: payload => {
          if (readyState !== 1 || !onmessage) return false;
          const operation =
            kind === 'lobby' && payload?.type === 'gameStarted'
              ? currentLobbyOperation('joinGame') ||
                currentLobbyOperation('startGame') ||
                currentLobbyOperation('startGameCountdown')
              : null;
          const data = JSON.stringify(payload);
          defer(() => {
            if (readyState !== 1 || !onmessage) return;
            try {
              const result = onmessage({ data });
              if (result && typeof result.then === 'function') {
                void Promise.resolve(result).then(
                  () => {
                    if (operation) settleLobbyOperation(operation);
                  },
                  reportFailure
                );
              } else if (operation) {
                settleLobbyOperation(operation);
              }
            } catch (error) {
              reportFailure(error);
            }
          });
          return true;
        },
      },
      __emitSettled: {
        value: payload =>
          new Promise((resolve, reject) => {
            if (readyState !== 1 || !onmessage) {
              resolve(false);
              return;
            }
            const operation =
              kind === 'lobby' && payload?.type === 'gameStarted'
                ? currentLobbyOperation('joinGame') ||
                  currentLobbyOperation('startGame') ||
                  currentLobbyOperation('startGameCountdown')
                : null;
            const data = JSON.stringify(payload);
            defer(() => {
              if (readyState !== 1 || !onmessage) {
                resolve(false);
                return;
              }
              let result;
              try {
                result = onmessage({ data });
              } catch (error) {
                reject(error);
                return;
              }
              Promise.resolve(result).then(
                () => {
                  if (operation) settleLobbyOperation(operation);
                  resolve(true);
                },
                reject
              );
            });
          }),
      },
      __fail: {
        value: reportFailure,
      },
    });
    Object.seal(socket);
    defer(() => {
      if (readyState !== 0) return;
      readyState = 1;
      if (onopen) {
        try {
          const result = onopen();
          if (result && typeof result.then === 'function') {
            void Promise.resolve(result).catch(reportFailure);
          }
        } catch (error) {
          reportFailure(error);
        }
      }
    });
    return socket;
  };

  const makeDeferredControlSocket = (kind, onFrame) => {
    let readyState = 0;
    let onopen = null;
    let onmessage = null;
    let onclose = null;
    let onerror = null;
    let actualSocket = null;
    const initialOperation =
      kind === 'lobby' ? activeOfficialLobbyOperation : null;
    const queuedSends = [];
    const closeLocally = error => {
      if (readyState >= 2) return;
      readyState = 2;
      queuedSends.length = 0;
      deferredControlSockets.delete(socket);
      if (error) {
        if (initialOperation) settleLobbyOperation(initialOperation, error);
        else failCurrentLobbyOperation(error);
      }
      if (error && onerror) {
        defer(() => {
          try {
            onerror(error);
          } catch (_) {}
        });
      }
      readyState = 3;
      if (onclose) {
        defer(() => {
          try {
            onclose();
          } catch (callbackError) {
            failCurrentLobbyOperation(callbackError);
          }
        });
      }
    };
    const socket = {
      get readyState() {
        return readyState;
      },
      get onopen() {
        return onopen;
      },
      set onopen(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onopen 无效。');
        }
        onopen = value;
      },
      get onmessage() {
        return onmessage;
      },
      set onmessage(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onmessage 无效。');
        }
        onmessage = value;
      },
      get onclose() {
        return onclose;
      },
      set onclose(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onclose 无效。');
        }
        onclose = value;
      },
      get onerror() {
        return onerror;
      },
      set onerror(value) {
        if (value !== null && typeof value !== 'function') {
          fail('PLAYMESH_GDEVELOP_INVALID_HANDLER', 'socket.onerror 无效。');
        }
        onerror = value;
      },
      send(value) {
        if (readyState === 1 && actualSocket) {
          try {
            actualSocket.send(value);
          } catch (error) {
            failCurrentLobbyOperation(error);
            if (onerror) {
              try {
                onerror(error);
              } catch (_) {}
            }
          }
          return;
        }
        if (readyState !== 0) {
          fail('PLAYMESH_GDEVELOP_SOCKET_CLOSED', 'GDevelop 控制 socket 未打开。');
        }
        if (typeof value !== 'string') {
          fail(
            'PLAYMESH_GDEVELOP_INVALID_FRAME',
            '延迟控制 socket 只缓冲官方 JSON 字符串帧。'
          );
        }
        if (encoder.encode(value).byteLength > MAX_CONTROL_FRAME_BYTES) {
          fail('PLAYMESH_GDEVELOP_FRAME_TOO_LARGE', 'GDevelop 控制帧过大。');
        }
        if (queuedSends.length >= MAX_DEFERRED_CONTROL_SENDS) {
          fail(
            'PLAYMESH_GDEVELOP_DEFERRED_QUEUE_FULL',
            'GDevelop 延迟控制帧缓冲已满。'
          );
        }
        queuedSends.push(value);
      },
      close() {
        if (readyState >= 2) return;
        if (actualSocket) {
          readyState = 2;
          actualSocket.close();
          return;
        }
        closeLocally();
      },
    };
    Object.defineProperties(socket, {
      __kind: { value: kind },
      __abort: {
        value: error => {
          if (actualSocket) {
            try {
              actualSocket.close();
            } catch (_) {
              // closeLocally 仍会完成 façade 生命周期。
            }
          }
          closeLocally(error);
        },
      },
    });
    Object.seal(socket);
    deferredControlSockets.add(socket);
    void ensureMultiplayerRuntimeOnline().then(
      () => {
        if (readyState !== 0) return;
        actualSocket = makeControlSocket(kind, onFrame);
        if (kind === 'lobby' && initialOperation) {
          actualSocket.__state.operation = initialOperation;
        }
        if (kind === 'lobby') lobbySockets.add(actualSocket);
        else authSockets.add(actualSocket);
        actualSocket.onmessage = event => {
          if (readyState === 1 && onmessage) onmessage(event);
        };
        actualSocket.onerror = error => {
          if (readyState === 1 && onerror) onerror(error);
        };
        actualSocket.onclose = () => {
          if (readyState === 3) return;
          readyState = 3;
          deferredControlSockets.delete(socket);
          if (onclose) onclose();
        };
        actualSocket.onopen = () => {
          if (readyState !== 0) {
            actualSocket.close();
            return;
          }
          readyState = 1;
          deferredControlSockets.delete(socket);
          if (onopen) onopen();
          const buffered = queuedSends.splice(0);
          for (const value of buffered) {
            if (readyState !== 1) break;
            try {
              actualSocket.send(value);
            } catch (error) {
              if (onerror) onerror(error);
              socket.close();
              break;
            }
          }
        };
      },
      error => closeLocally(error)
    );
    return socket;
  };

  const chooseCompressionMethod = methods => {
    if (
      methods.includes('cs:gzip') &&
      typeof global.CompressionStream === 'function' &&
      typeof global.DecompressionStream === 'function'
    ) {
      return 'cs:gzip';
    }
    if (
      methods.includes('cs:deflate') &&
      typeof global.CompressionStream === 'function' &&
      typeof global.DecompressionStream === 'function'
    ) {
      return 'cs:deflate';
    }
    return 'none';
  };

  const emitLobbyConnectionId = socket => {
    if (!session) return;
    const number = currentPlayerNumber();
    if (!number) {
      socket.__fail(
        Object.assign(new Error('稳定玩家编号尚未就绪。'), {
          code: 'PLAYMESH_GDEVELOP_PLAYER_NUMBER_NOT_READY',
        })
      );
      return;
    }
    socket.__emit({
      type: 'connectionId',
      data: {
        connectionId: `pm-gd-v1-${number}-${session.id}`.slice(0, 180),
        positionInLobby: number,
        validIceServers: [],
      },
    });
  };

  const emitAuthorityPeerAndMaybeStart = socket => {
    if (socket.__state.authorityPeerAnnounced) {
      if (session?.state === 'running') notifyGuestGameStarted();
      return Promise.resolve(true);
    }
    if (socket.__state.authorityPeerAnnouncement) {
      return socket.__state.authorityPeerAnnouncement;
    }
    const announcementGeneration = socket.__state.authorityPeerGeneration;
    const announcement = deliverSocketPayload(
      socket,
      {
        type: 'peerId',
        data: {
          peerId: authorityPeerId,
          compressionMethod: socket.__state.compressionMethod,
        },
      },
      CONTROL_DELIVERY_ATTEMPTS
    ).then(
      () => {
        if (
          socket.__state.authorityPeerGeneration !== announcementGeneration
        ) {
          socket.__state.authorityPeerAnnouncement = null;
          return false;
        }
        socket.__state.authorityPeerAnnouncement = null;
        socket.__state.authorityPeerAnnounced = true;
        notifyGuestGameStarted();
        return true;
      },
      error => {
        if (
          socket.__state.authorityPeerGeneration !== announcementGeneration
        ) {
          return false;
        }
        socket.__state.authorityPeerAnnouncement = null;
        socket.__fail(error);
        throw error;
      }
    );
    socket.__state.authorityPeerAnnouncement = announcement;
    return announcement;
  };

  const handleLobbyFrame = (socket, frame) => {
    const actionProperty = readOwnDataValue(frame, 'action');
    if (!actionProperty || !isBoundedString(actionProperty.value, 64)) {
      fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'GDevelop lobby 控制帧无效。');
    }
    const action = actionProperty.value;
    if (action === 'getConnectionId') {
      if (!hasExactKeys(frame, ['action'])) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'getConnectionId 控制帧无效。');
      }
      emitLobbyConnectionId(socket);
      return;
    }
    if (action === 'heartbeat') {
      if (
        !hasExactKeys(frame, ['action', 'connectionType']) ||
        frame.connectionType !== 'lobby'
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'heartbeat 控制帧无效。');
      }
      return;
    }
    if (action === 'sessionInformation') {
      const information = readExactDataRecord(frame, [
        'action',
        'connectionType',
        'isCordova',
        'devicePlatform',
        'navigatorPlatform',
        'hasTouch',
        'supportedCompressionMethods',
      ]);
      const supportedCompressionMethods = information
        ? readDenseDataArray(information.supportedCompressionMethods, 4)
        : null;
      if (
        !information ||
        information.connectionType !== 'lobby' ||
        typeof information.isCordova !== 'boolean' ||
        typeof information.hasTouch !== 'boolean' ||
        !isBoundedString(information.devicePlatform, 128, true) ||
        !isBoundedString(information.navigatorPlatform, 128, true) ||
        !supportedCompressionMethods ||
        supportedCompressionMethods.some(
          method => !['none', 'cs:gzip', 'cs:deflate'].includes(method)
        )
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'sessionInformation 控制帧无效。');
      }
      socket.__state.compressionMethod = chooseCompressionMethod(
        supportedCompressionMethods
      );
      return;
    }
    if (action === 'startGameCountdown') {
      if (
        !hasExactKeys(frame, ['action', 'connectionType']) ||
        frame.connectionType !== 'lobby'
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', `${action} 控制帧无效。`);
      }
      if (!authority || currentPlayerNumber() !== 1) {
        fail('PLAYMESH_GDEVELOP_AUTHORITY_ONLY', '只有固定 Authority 可以开始准备。');
      }
      if (!session || session.state !== 'lobby') {
        fail('PLAYMESH_GDEVELOP_INVALID_STATE', '当前会话不能开始准备。');
      }
      if (connectedPlayerCount() < session.minPlayers) {
        fail('PLAYMESH_GDEVELOP_NOT_ENOUGH_PLAYERS', '未达到开始游戏所需玩家数。');
      }
      const operation = currentLobbyOperation('startGameCountdown');
      if (!operation) {
        fail('PLAYMESH_GDEVELOP_INVALID_STATE', '缺少 GDevelop 开始准备操作。');
      }
      const preflight = beginStartRound(operation);
      const round = startRound;
      void preflight.then(
        () => invokePreparedStartIfReady(round),
        error => settleLobbyOperation(operation, error)
      );
      void deliverSocketPayload(
        socket,
        {
          type: 'gameCountdownStarted',
          data: { compressionMethod: socket.__state.compressionMethod },
        },
        CONTROL_DELIVERY_ATTEMPTS
      ).catch(error => {
        if (startRound !== round) return;
        settleLobbyOperation(operation, error);
        cancelStartRound(error);
        socket.__fail(error);
      });
      return;
    }
    if (action === 'startGame' || action === 'joinGame') {
      if (
        !hasExactKeys(frame, ['action', 'connectionType']) ||
        frame.connectionType !== 'lobby'
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', `${action} 控制帧无效。`);
      }
      if (action === 'joinGame') {
        if (authority) {
          fail('PLAYMESH_GDEVELOP_GUEST_ONLY', 'Authority 不能执行 joinGame。');
        }
        if (!session || session.state !== 'running') {
          fail('PLAYMESH_GDEVELOP_INVALID_STATE', '只有运行中的对局可以执行 joinGame。');
        }
        void emitAuthorityPeerAndMaybeStart(socket).catch(() => {});
        return;
      }
      if (!authority || currentPlayerNumber() !== 1) {
        fail('PLAYMESH_GDEVELOP_AUTHORITY_ONLY', '只有固定 Authority 可以开始游戏。');
      }
      if (!session || session.state !== 'lobby') {
        fail('PLAYMESH_GDEVELOP_INVALID_STATE', '当前会话不能开始游戏。');
      }
      if (connectedPlayerCount() < session.minPlayers) {
        fail('PLAYMESH_GDEVELOP_NOT_ENOUGH_PLAYERS', '未达到开始游戏所需玩家数。');
      }
      if (!startRound || !sameFrozenParticipants(startRound)) {
        fail(
          'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
          'GDevelop 官方准备阶段尚未完成。'
        );
      }
      startRound.startIntentReceived = true;
      invokePreparedStartIfReady(startRound);
      return;
    }
    if (action === 'sendPeerId') {
      if (
        !hasExactKeys(frame, ['action', 'connectionType', 'peerId']) ||
        frame.connectionType !== 'lobby' ||
        frame.peerId !== currentOfficialPeerId() ||
        !authority ||
        currentPlayerNumber() !== 1
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'sendPeerId 控制帧无效。');
      }
      dispatchStartPreparation();
      return;
    }
    if (action === 'updateConnection') {
      if (
        !hasExactKeys(frame, [
          'action',
          'connectionType',
          'status',
          'peerId',
        ]) ||
        frame.connectionType !== 'lobby' ||
        frame.status !== 'connected' ||
        frame.peerId !== currentOfficialPeerId()
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'updateConnection 控制帧无效。');
      }
      if (!authority) {
        const hostConnection = connections.get(authorityPeerId);
        if (!hostConnection || !hostConnection.__markOfficialReady()) {
          fail(
            'PLAYMESH_GDEVELOP_CONNECTION_NOT_READY',
            'GDevelop 官方连接尚未确认。'
          );
        }
        sendGuestPrepared();
      }
      notifyGuestGameStarted();
      return;
    }
    fail('PLAYMESH_GDEVELOP_UNKNOWN_FRAME', '未知的 GDevelop lobby 控制帧。');
  };

  function createOfficialLobbyControlFacade() {
    if (arguments.length) {
      fail(
        'PLAYMESH_GDEVELOP_FORBIDDEN_ARGUMENT',
        'GDevelop lobby façade 不接受 URL 或 token。'
      );
    }
    if (currentMultiplayerRuntimeReadiness(main)) {
      const socket = makeControlSocket('lobby', handleLobbyFrame);
      lobbySockets.add(socket);
      // The official GDevelop runtime can recreate its lobby socket while the
      // shared Playmesh session is already running. State transitions are not
      // replayed by the SDK, so reconcile the newly opened socket with the
      // current authoritative state after the caller has installed handlers.
      defer(() => notifyLobbySocketGameStarted(socket));
      return socket;
    }
    return makeDeferredControlSocket('lobby', handleLobbyFrame);
  }

  const clearLocalFrameAvatarState = state => {
    if (!state) return;
    state.avatarAbortControllers?.forEach(controller => controller.abort());
    state.avatarAbortControllers?.clear();
    state.avatarCache?.clear();
    state.avatarDigests?.clear();
    state.avatarPresentations?.clear();
    state.avatarSources?.clear();
    state.avatarRequestVersions?.clear();
  };

  const invalidateLocalFrameState = state => {
    if (!state || !state.active) return;
    if (
      state.kind === 'lobby' &&
      !authority &&
      session?.state === 'lobby' &&
      state.sessionId === session.id
    ) {
      clearGuestReadiness(true);
    }
    state.active = false;
    state.pendingOperations?.forEach(operation => {
      operation.settled = true;
      if (operation.timer !== null) global.clearTimeout(operation.timer);
    });
    state.pendingOperations?.clear();
    clearLocalFrameAvatarState(state);
    localFrameStates.delete(state);
    if (localFrameByElement.get(state.frame) === state) {
      localFrameByElement.delete(state.frame);
    }
    if (activeLocalFrameByKind[state.kind] === state) {
      activeLocalFrameByKind[state.kind] = null;
    }
  };

  const invalidateAllLocalFrames = () => {
    [...localFrameStates].forEach(invalidateLocalFrameState);
  };

  const ensureMultiplayerRuntimeOnline = async () => {
    const runtime = await ensureRuntimeNegotiated();
    if (!currentMultiplayerRuntimeReadiness(runtime)) {
      if (runtimeNegotiation?.completed) runtimeNegotiation = null;
      throw runtimeFailure(
        'PLAYMESH_GDEVELOP_CHANNEL_NOT_READY',
        'GDevelop 多人 session/channel/player-number readiness 已变化。'
      );
    }
    return runtime;
  };

  const connectedSessionPlayerCount = () =>
    session
      ? session.players.reduce(
          (count, player) => count + (player.connected ? 1 : 0),
          0
        )
      : 0;

  // Only public presentation fields cross into the opaque lobby frame. The
  // stable number replaces internal playerId, and the sandbox receives only
  // a verified data URL rather than the source path.
  const localLobbyPlayerSummaries = (avatarPresentations = null) => {
    if (!session) return Object.freeze([]);
    const currentId = currentActualPlayerId();
    return Object.freeze(
      session.players
        .map(player => ({
          number: playerNumberForActualId(player.id),
          nickname: player.nickname,
          connected: player.connected,
          isCurrent: player.id === currentId,
          isAuthority: player.id === session.authorityClientId,
          readiness: readinessForActualPlayerId(player.id),
          avatarDataUrl:
            avatarPresentations?.get(playerNumberForActualId(player.id))
              ?.dataUrl || null,
        }))
        .filter(player => isSafeInteger(player.number, 1, MAX_PLAYERS))
        .sort((left, right) => left.number - right.number)
        .map(player => Object.freeze(player))
    );
  };

  // The official close control owns removal of both the lobby DOM and its
  // window message callback. Keep that lifecycle instead of removing the
  // sandbox iframe directly from the compatibility layer.
  const resolveOfficialLobbyCloseControl = state => {
    try {
      const root = global.document?.getElementById?.(
        'lobbies-root-container'
      );
      if (
        !root ||
        typeof root.contains !== 'function' ||
        !root.contains(state.frame) ||
        typeof root.querySelector !== 'function'
      ) {
        return null;
      }
      const closeControl = root.querySelector('#lobbies-close-container');
      return closeControl && typeof closeControl.click === 'function'
        ? closeControl
        : null;
    } catch (_) {
      return null;
    }
  };

  const releaseOfficialMultiplayerFacadeForSoloMode = state => {
    const closeControl = resolveOfficialLobbyCloseControl(state);
    [...lobbySockets].forEach(socket => socket.close());
    [...deferredControlSockets].forEach(socket => {
      if (socket.__kind === 'lobby') socket.__abort();
    });
    connections.forEach(connection => closeConnection(connection, true));
    connections.clear();
    peer = null;
    peerOpen = false;
    acceptPeerPackets = false;
    pendingPackets.length = 0;
    invalidateLocalFrameState(state);
    try {
      // The official close callback removes both the iframe and GDevelop's
      // window-message listener. No Playmesh session/channel lifecycle is
      // involved; App remains the sole owner of those resources.
      if (closeControl) closeControl.click();
      else state.frame?.remove?.();
    } catch (error) {
      global.console?.error?.(
        'Playmesh GDevelop local lobby cleanup failed',
        error
      );
    }
  };

  const createFrameCapability = () => {
    if (
      !global.crypto ||
      typeof global.crypto.getRandomValues !== 'function'
    ) {
      fail(
        'PLAYMESH_GDEVELOP_CRYPTO_UNAVAILABLE',
        '浏览器缺少安全随机数能力，不能创建 GDevelop 本地安全页面。'
      );
    }
    const bytes = new Uint8Array(32);
    try {
      global.crypto.getRandomValues(bytes);
    } catch (_) {
      fail(
        'PLAYMESH_GDEVELOP_CRYPTO_UNAVAILABLE',
        '无法生成 GDevelop 本地页面安全凭据。'
      );
    }
    return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join(
      ''
    );
  };

  // srcdoc 是 opaque-origin 沙箱。它只能持有单帧 capability，不接收玩家
  // token、connectionId 或任何底层传输句柄；父端仍以 WindowProxy 精确绑定。
  const createLobbyFrameScript = capability => `(()=>{'use strict';
const protocol=${JSON.stringify(LOCAL_FRAME_PROTOCOL)};
const version=${LOCAL_FRAME_VERSION};
const kind='lobby';
const capability=${JSON.stringify(capability)};
let sent=0,received=0,requestSequence=0,ready=false,joined=false,joinRequested=false,autoJoinAttempted=false,soloRequested=false,soloAvailable=false,role='guest',sessionState=null,currentReadiness='unknown',connectedPlayers=0,minimumPlayers=1,players=[];
const pending=new Map();
const completed=new Set();
const byId=id=>document.getElementById(id);
const locale=String((globalThis.navigator&&globalThis.navigator.language)||'zh-CN').toLowerCase();
const zh=locale.startsWith('zh');
const rt=zh?{readyGame:'准备',cancelReady:'取消准备',preparing:'连接准备中',readyState:'已准备',notReady:'未准备',unknownReady:'等待状态',playersNotReady:'仍有在线玩家尚未准备。'}:{readyGame:'Ready',cancelReady:'Cancel ready',preparing:'Preparing connection',readyState:'Ready',notReady:'Not ready',unknownReady:'Waiting for status',playersNotReady:'An online player is not ready yet.'};
const t=zh?{title:'Playmesh 大厅',eyebrow:'PLAYMESH · 配对控制台',heading:'多人对局',lead:'查看玩家状态，准备开始游戏。',connecting:'连接中',connected:'已连接',workingState:'处理中',offline:'已离开',currentStatus:'当前状态',loading:'正在连接当前 Playmesh 对局…',sessionReady:'已连接到对局',joined:'已加入当前对局',updated:'对局状态已更新',left:'已离开对局。你可以重新加入或进入单人模式。',working:'正在处理，请稍候…',switchingSolo:'正在退出 GDevelop 多人大厅并切换到单人模式…',players:'在线玩家',playerList:'当前玩家',connectionState:'连接状态',current:'当前',online:'已连接',disconnected:'已离线',player:'玩家',role:'我的角色',slot:'玩家编号',host:'房主',guest:'玩家',slotPending:'待分配',join:'加入当前对局',start:'开始游戏',joinGame:'进入游戏',leave:'离开对局',solo:'退出大厅并进入单人模式',soloUnavailable:'当前运行环境不能切换到单人模式。',esc:'打开游戏菜单',failed:'操作失败，请重试。',notEnough:'当前玩家数不足，等玩家加入后可再次准备。',unavailable:'多人连接暂不可用，请重试。',timeout:'操作超时，请重试。',notAllowed:'当前角色不能执行此操作。',stateChanged:'大厅状态已变化，请重试。'}:{title:'Playmesh lobby',eyebrow:'PLAYMESH · MATCH CONSOLE',heading:'Multiplayer lobby',lead:'Check player status and get ready to play.',connecting:'Connecting',connected:'Connected',workingState:'Working',offline:'Left lobby',currentStatus:'Current status',loading:'Connecting to the current Playmesh session…',sessionReady:'Connected to session',joined:'Joined the current lobby',updated:'Lobby status updated',left:'You left the lobby. Rejoin or continue in solo mode.',working:'Working…',switchingSolo:'Leaving the GDevelop multiplayer lobby and switching to solo mode…',players:'Players online',playerList:'Current players',connectionState:'Connection status',current:'You',online:'Connected',disconnected:'Disconnected',player:'Player',role:'My role',slot:'Player number',host:'Host',guest:'Player',slotPending:'Pending',join:'Join this lobby',start:'Start game',joinGame:'Enter game',leave:'Leave lobby',solo:'Leave lobby and play solo',soloUnavailable:'Solo mode is unavailable in this runtime.',esc:'Open game menu',failed:'Operation failed. Try again.',notEnough:'Not enough players yet. Try again after another player joins.',unavailable:'The multiplayer connection is unavailable. Try again.',timeout:'The operation timed out. Try again.',notAllowed:'Your role cannot perform this operation.',stateChanged:'The lobby state changed. Try again.'};
const exact=(value,keys)=>{if(!value||typeof value!=='object'||Array.isArray(value))return null;const prototype=Object.getPrototypeOf(value);if(prototype!==Object.prototype&&prototype!==null)return null;const own=Reflect.ownKeys(value);if(own.length!==keys.length||own.some(key=>typeof key!=='string'||!keys.includes(key)))return null;const copy=Object.create(null);for(const key of keys){const descriptor=Object.getOwnPropertyDescriptor(value,key);if(!descriptor||!descriptor.enumerable||!('value'in descriptor))return null;copy[key]=descriptor.value}return copy};
const readPlayers=value=>{if(!Array.isArray(value)||value.length>8)return null;const numbers=new Set(),result=[];for(const entry of value){const player=exact(entry,['number','nickname','connected','isCurrent','isAuthority','readiness','avatarDataUrl']);const avatarDataUrl=player&&player.avatarDataUrl;if(!player||!Number.isSafeInteger(player.number)||player.number<1||player.number>8||numbers.has(player.number)||typeof player.nickname!=='string'||!player.nickname||player.nickname.length>128||typeof player.connected!=='boolean'||typeof player.isCurrent!=='boolean'||typeof player.isAuthority!=='boolean'||!['unknown','notReady','preparing','ready'].includes(player.readiness)||(avatarDataUrl!==null&&(typeof avatarDataUrl!=='string'||avatarDataUrl.length>720000||!/^data:image\\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(avatarDataUrl))))return null;numbers.add(player.number);result.push(player)}return result};
const send=(action,payload)=>{sent+=1;parent.postMessage({protocol,version,kind,nonce:capability,sequence:sent,action,payload},'*')};
const setTone=(tone,label)=>{byId('statusPanel').dataset.tone=tone;byId('connectionBadge').dataset.tone=tone;byId('connectionLabel').textContent=label};
const setStatus=(message,tone,label)=>{byId('status').textContent=message;setTone(tone,label)};
const setMetrics=payload=>{connectedPlayers=payload.connectedPlayers;minimumPlayers=payload.minPlayers;byId('metrics').hidden=false;byId('playerSummary').textContent=payload.connectedPlayers+' / '+payload.maxPlayers;byId('roleSummary').textContent=role==='authority'?t.host:t.guest;byId('playerMeta').textContent=Number.isSafeInteger(payload.positionInLobby)?'#'+payload.positionInLobby:t.slotPending};
const setPlayers=value=>{players=value;const current=players.find(player=>player.isCurrent);currentReadiness=current?current.readiness:'unknown';byId('playersPanel').hidden=players.length===0;for(let number=1;number<=8;number+=1){const player=players.find(entry=>entry.number===number),row=byId('playerRow'+number);row.hidden=!player;if(!player)continue;const name=player.nickname||t.player+' '+number,image=byId('playerImage'+number),avatar=byId('playerAvatar'+number);row.dataset.connected=String(player.connected);row.dataset.readiness=player.readiness;avatar.textContent=name.trim().slice(0,1).toUpperCase()||String(number);avatar.hidden=Boolean(player.avatarDataUrl);image.hidden=!player.avatarDataUrl;image.src=player.avatarDataUrl||'';image.alt=player.avatarDataUrl?name:'';byId('playerName'+number).textContent=name;const readinessLabel=player.readiness==='ready'?rt.readyState:player.readiness==='preparing'?rt.preparing:player.readiness==='notReady'?rt.notReady:rt.unknownReady;byId('playerState'+number).textContent=(player.isAuthority?t.host+' · ':'')+(player.connected?t.online:t.disconnected)+(player.connected&&!player.isAuthority?' · '+readinessLabel:'');byId('playerCurrent'+number).hidden=!player.isCurrent;byId('playerCurrent'+number).textContent=t.current}};
const actionButtons={startGameCountdown:'start',setReady:'playerReady',joinGame:'joinGame',leaveLobby:'leave',switchToSolo:'solo'};
const render=()=>{const visibleConnected=players.filter(player=>player.connected),allGuestsReady=connectedPlayers>=minimumPlayers&&visibleConnected.length===connectedPlayers&&visibleConnected.every(player=>player.isAuthority||player.readiness==='ready');byId('start').hidden=!joined||role!=='authority'||sessionState!=='lobby'||soloRequested||completed.has('startGame');byId('start').disabled=pending.has('startGameCountdown')||pending.has('startGame')||!allGuestsReady;byId('playerReady').hidden=!joined||role!=='guest'||sessionState!=='lobby'||soloRequested;byId('playerReady').dataset.readiness=currentReadiness;byId('playerReady').textContent=currentReadiness==='ready'?rt.cancelReady:rt.readyGame;byId('joinGame').hidden=!joined||role!=='guest'||sessionState!=='running'||soloRequested||pending.has('joinGame')||completed.has('joinGame');byId('leave').hidden=soloRequested||(!joined&&!joinRequested);byId('solo').hidden=!ready;for(const action of Object.keys(actionButtons)){const button=byId(actionButtons[action]);const busy=pending.has(action);if(action!=='startGameCountdown')button.disabled=busy||(action==='setReady'&&currentReadiness==='preparing')||(action==='switchToSolo'&&!soloAvailable);if(typeof button.setAttribute==='function')button.setAttribute('aria-busy',String(busy))}byId('actionNote').hidden=soloAvailable||!ready;byId('actionNote').textContent=soloAvailable?'':t.soloUnavailable};
const applyText=()=>{document.title=t.title;byId('eyebrow').textContent=t.eyebrow;byId('heading').textContent=t.heading;byId('lead').textContent=t.lead;byId('statusLabel').textContent=t.currentStatus;byId('playersLabel').textContent=t.players;byId('playersHeading').textContent=t.playerList;byId('playersA11yHint').textContent=t.connectionState;byId('roleLabel').textContent=t.role;byId('slotLabel').textContent=t.slot;byId('start').textContent=t.start;byId('playerReady').textContent=rt.readyGame;byId('joinGame').textContent=t.joinGame;byId('leave').textContent=t.leave;byId('solo').textContent=t.solo;byId('escLabel').textContent=t.esc};
const begin=(action,extra={})=>{if(pending.has(action))return;if(action==='switchToSolo'&&!soloAvailable)return;const requestId='op-'+String(++requestSequence);pending.set(action,requestId);if(action==='joinCurrentSession')joinRequested=true;if(action==='switchToSolo')soloRequested=true;setStatus(action==='switchToSolo'?t.switchingSolo:t.working,'working',t.workingState);render();send(action,{requestId,...extra})};
const maybeJoinRunningGame=()=>{if(joined&&role==='guest'&&sessionState==='running'&&!autoJoinAttempted&&!pending.has('joinGame')&&!completed.has('joinGame')){autoJoinAttempted=true;begin('joinGame')}};
const failureMessage=payload=>payload.code==='NOT_ENOUGH_PLAYERS'?t.notEnough:payload.code==='PLAYERS_NOT_READY'?rt.playersNotReady:payload.code==='OPERATION_TIMEOUT'?t.timeout:payload.code==='ACTION_NOT_ALLOWED'?t.notAllowed:payload.code==='INVALID_STATE'?t.stateChanged:payload.code==='CONNECTION_UNAVAILABLE'||payload.code==='SESSION_UNAVAILABLE'||payload.code==='PLAYER_STATE_PENDING'?t.unavailable:t.failed;
applyText();setStatus(t.loading,'connecting',t.connecting);
window.addEventListener('keydown',event=>{if(event.key!=='Escape'||event.repeat||event.isComposing)return;event.preventDefault();event.stopPropagation();event.stopImmediatePropagation();send('hostMenuToggle',{})},true);
byId('start').addEventListener('click',()=>begin('startGameCountdown'));byId('playerReady').addEventListener('click',()=>begin('setReady',{ready:currentReadiness!=='ready'}));byId('joinGame').addEventListener('click',()=>begin('joinGame'));byId('leave').addEventListener('click',()=>begin('leaveLobby'));byId('solo').addEventListener('click',()=>begin('switchToSolo'));
window.addEventListener('message',event=>{if(event.source!==parent)return;const envelope=exact(event.data,['protocol','version','kind','nonce','sequence','event','payload']);if(!envelope||envelope.protocol!==protocol||envelope.version!==version||envelope.kind!==kind||envelope.nonce!==capability||!Number.isSafeInteger(envelope.sequence)||envelope.sequence!==received+1||typeof envelope.event!=='string')return;received=envelope.sequence;let payload=null,nextPlayers=null;if(envelope.event==='sessionInformation'){payload=exact(envelope.payload,['isCordova','devicePlatform','navigatorPlatform','hasTouch','role','sessionId','sessionState','positionInLobby','connectedPlayers','minPlayers','maxPlayers','players','soloAvailable','soloUnavailableReason']);nextPlayers=payload&&readPlayers(payload.players);if(!payload||!nextPlayers||typeof payload.soloAvailable!=='boolean')return;ready=true;role=payload.role;sessionState=payload.sessionState;soloAvailable=payload.soloAvailable;setMetrics(payload);setPlayers(nextPlayers);setStatus(t.sessionReady+' · '+payload.sessionId,'ready',t.connected);if(sessionState!=='stopped'&&!joined&&!joinRequested)begin('joinCurrentSession')}else if(envelope.event==='lobbyJoined'){payload=exact(envelope.payload,['lobbyId','positionInLobby','role','sessionState','connectedPlayers','minPlayers','maxPlayers','players']);nextPlayers=payload&&readPlayers(payload.players);if(!payload||!nextPlayers)return;joined=true;joinRequested=false;role=payload.role;sessionState=payload.sessionState;if(sessionState!=='running')autoJoinAttempted=false;setMetrics(payload);setPlayers(nextPlayers);setStatus(t.joined+' · #'+payload.positionInLobby,'ready',t.connected);maybeJoinRunningGame()}else if(envelope.event==='lobbyUpdated'){payload=exact(envelope.payload,['positionInLobby','sessionState','connectedPlayers','minPlayers','maxPlayers','players']);nextPlayers=payload&&readPlayers(payload.players);if(!payload||!nextPlayers)return;sessionState=payload.sessionState;if(sessionState!=='running')autoJoinAttempted=false;setMetrics(payload);setPlayers(nextPlayers);setStatus(t.updated+' · #'+payload.positionInLobby,'ready',t.connected);maybeJoinRunningGame()}else if(envelope.event==='playersVisualUpdated'){payload=exact(envelope.payload,['players']);nextPlayers=payload&&readPlayers(payload.players);if(!payload||!nextPlayers)return;setPlayers(nextPlayers)}else if(envelope.event==='lobbyLeft'){payload=exact(envelope.payload,[]);if(!payload)return;joined=false;joinRequested=false;autoJoinAttempted=false;soloRequested=false;currentReadiness='notReady';completed.clear();pending.clear();setStatus(t.left,'offline',t.offline)}else if(envelope.event==='operationSucceeded'){payload=exact(envelope.payload,['action','requestId']);if(!payload||pending.get(payload.action)!==payload.requestId)return;pending.delete(payload.action);if(payload.action==='startGameCountdown'||payload.action==='startGame'||payload.action==='joinGame')completed.add(payload.action)}else if(envelope.event==='operationFailed'){payload=exact(envelope.payload,['action','requestId','code','reason','retryable']);if(!payload||typeof payload.code!=='string'||typeof payload.reason!=='string'||typeof payload.retryable!=='boolean'||pending.get(payload.action)!==payload.requestId)return;pending.delete(payload.action);if(payload.action==='joinCurrentSession')joinRequested=false;if(payload.action==='switchToSolo')soloRequested=false;setStatus(failureMessage(payload),'error',t.connected)}else{return}render()},true);
send('ready',{});
})();`;

  const createAuthenticationFrameScript = capability => `(()=>{'use strict';
const protocol=${JSON.stringify(LOCAL_FRAME_PROTOCOL)};
const version=${LOCAL_FRAME_VERSION};
const kind='authentication';
const capability=${JSON.stringify(capability)};
let sent=0;
const byId=id=>document.getElementById(id);
const locale=String((globalThis.navigator&&globalThis.navigator.language)||'zh-CN').toLowerCase();
const zh=locale.startsWith('zh');
const t=zh?{title:'Playmesh 玩家',eyebrow:'PLAYMESH · 玩家身份',heading:'Playmesh 玩家身份',lead:'使用当前 Playmesh 玩家身份登录。',currentStatus:'当前状态',ready:'可以登录',working:'正在确认 Playmesh 身份…',authenticate:'使用 Playmesh 身份登录'}:{title:'Playmesh player',eyebrow:'PLAYMESH · PLAYER IDENTITY',heading:'Playmesh player identity',lead:'Sign in with the current Playmesh player identity.',currentStatus:'Current status',ready:'Ready to sign in',working:'Confirming your Playmesh identity…',authenticate:'Sign in with Playmesh'};
const send=()=>{sent+=1;parent.postMessage({protocol,version,kind,nonce:capability,sequence:sent,action:'authenticate',payload:{}},'*')};
document.title=t.title;byId('eyebrow').textContent=t.eyebrow;byId('heading').textContent=t.heading;byId('lead').textContent=t.lead;byId('statusLabel').textContent=t.currentStatus;byId('status').textContent=t.ready;byId('connectionBadge').dataset.tone='ready';byId('connectionLabel').textContent=t.ready;const button=byId('authenticate');button.textContent=t.authenticate;button.hidden=false;button.addEventListener('click',()=>{if(button.disabled)return;button.disabled=true;byId('statusPanel').dataset.tone='working';byId('connectionBadge').dataset.tone='working';byId('connectionLabel').textContent=t.working;byId('status').textContent=t.working;send()});
})();`;

  const createLocalFrameDocument = (kind, capability) => {
    const isLobby = kind === 'lobby';
    const title = isLobby ? 'Playmesh Lobby' : 'Playmesh Player';
    const heading = isLobby ? '多人对局' : 'Playmesh 玩家身份';
    const initialStatus = isLobby
      ? '正在连接当前 Playmesh 对局…'
      : '使用当前 Playmesh 玩家身份登录。';
    const playerSlots = isLobby
      ? Array.from(
          { length: MAX_PLAYERS },
          (_, index) =>
            `<li class="player" id="playerRow${index + 1}" hidden><span class="avatar"><span id="playerAvatar${index + 1}" aria-hidden="true">${index + 1}</span><img id="playerImage${index + 1}" alt="" hidden></span><span class="player-copy"><strong id="playerName${index + 1}">玩家 ${index + 1}</strong><small id="playerState${index + 1}">等待加入</small></span><span class="current-tag" id="playerCurrent${index + 1}" hidden>当前</span></li>`
        ).join('')
      : '';
    const actions = isLobby
      ? "<button type=\"button\" id=\"start\" hidden>开始游戏</button><button type=\"button\" id=\"playerReady\" hidden>准备</button><button type=\"button\" id=\"joinGame\" hidden>进入游戏</button><button type=\"button\" class=\"secondary\" id=\"leave\" hidden>离开对局</button><button type=\"button\" class=\"solo\" id=\"solo\" hidden>退出大厅并进入单人模式</button>"
      : "<button type=\"button\" id=\"authenticate\" hidden>使用 Playmesh 身份登录</button>";
    const frameScript = isLobby
      ? createLobbyFrameScript(capability)
      : createAuthenticationFrameScript(capability);
    return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'none'; base-uri 'none'"><title>${title}</title><style>
:root{color-scheme:dark;--ink:#0b0b12;--panel:#161622;--text:#f7f5ff;--purple:#7657f6;--mint:#50e3c2;--amber:#ffca5c;--muted:#aaa8bc;--line:#303044;--frame-pad:clamp(10px,3vw,28px);--card-pad:clamp(18px,3vw,28px);--column-gap:clamp(14px,2.4vw,22px);--tap-target:46px}
*{box-sizing:border-box}
html,body{width:100%;height:100%;margin:0;overflow:hidden;background:var(--ink);color:var(--text);font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
button{font:inherit}
main{width:100%;height:100%;height:100dvh;display:grid;place-items:center;overflow:auto;padding:max(var(--frame-pad),env(safe-area-inset-top)) max(var(--frame-pad),env(safe-area-inset-right)) max(var(--frame-pad),env(safe-area-inset-bottom)) max(var(--frame-pad),env(safe-area-inset-left))}
.card{width:min(100%,680px);max-height:100%;min-width:0;overflow:auto;overscroll-behavior:contain;padding:var(--card-pad);border:1px solid var(--line);border-radius:22px;background:var(--panel);box-shadow:0 18px 54px rgba(0,0,0,.42);scrollbar-gutter:stable}
.card:has(#escHint:not([hidden])){display:grid;grid-template-areas:"hero" "status" "metrics" "actions" "note" "players" "footer"}
.hero{grid-area:hero;display:grid;grid-template-columns:54px minmax(0,1fr);gap:16px;align-items:center}
.mesh-mark{position:relative;width:52px;height:52px;border:1px solid #3b3b51;border-radius:16px;background:#101019}
.mesh-mark:before,.mesh-mark:after{content:"";position:absolute;left:14px;top:25px;width:25px;height:1px;background:#716ae2;transform-origin:left center}
.mesh-mark:before{transform:rotate(-38deg)}
.mesh-mark:after{transform:rotate(38deg)}
.node{position:absolute;width:9px;height:9px;border:2px solid var(--mint);border-radius:50%;background:var(--ink)}
.node-a{left:10px;top:21px}.node-b{right:8px;top:8px}.node-c{right:8px;bottom:8px}
.node-a:after{content:"";position:absolute;inset:-6px;border:1px solid rgba(80,227,194,.55);border-radius:50%;animation:mesh-pulse 1.8s ease-out infinite}
.brand-line{display:flex;align-items:center;justify-content:space-between;gap:12px}
.eyebrow{color:#c6c2d8;font:700 11px/1.2 ui-monospace,"Cascadia Mono",monospace;letter-spacing:.12em;text-transform:uppercase}
.connection{display:inline-flex;align-items:center;gap:7px;min-height:28px;padding:4px 9px;border:1px solid #34524d;border-radius:999px;color:#9ff2df;background:#10231f;font-size:12px;font-weight:700;white-space:nowrap}
.connection-dot{width:7px;height:7px;border-radius:50%;background:currentColor;box-shadow:0 0 0 3px rgba(80,227,194,.12)}
.connection[data-tone="working"]{border-color:#66562d;color:var(--amber);background:#241e0f}
.connection[data-tone="offline"],.connection[data-tone="error"]{border-color:#504f5f;color:#c4c1d0;background:#20202b}
h1{margin:7px 0 0;font:800 clamp(26px,6vw,38px)/1.08 ui-rounded,"SF Pro Rounded","Segoe UI",system-ui,sans-serif;letter-spacing:-.035em}
.lead{margin:7px 0 0;color:var(--muted);font-size:14px}
.status-panel{grid-area:status;margin-top:22px;padding:15px 16px;border:1px solid var(--line);border-left:3px solid var(--mint);border-radius:13px;background:#101019;text-align:left}
.status-panel[data-tone="working"]{border-left-color:var(--amber)}
.status-panel[data-tone="error"]{border-left-color:#ff7b8b}
.status-label{display:block;margin-bottom:4px;color:#8f8ca3;font:700 10px/1.2 ui-monospace,"Cascadia Mono",monospace;letter-spacing:.13em;text-transform:uppercase}
#status{margin:0;color:var(--text);font-weight:650;overflow-wrap:anywhere}
.metrics{grid-area:metrics;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1px;margin:14px 0 0;padding:0;overflow:hidden;border:1px solid var(--line);border-radius:12px;background:var(--line)}
.metrics[hidden]{display:none}
.metric{min-width:0;padding:10px 12px;background:#1b1b29;text-align:left}
.metric dt{color:#8f8ca3;font-size:11px}.metric dd{margin:3px 0 0;color:var(--text);font-weight:750;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.players-panel{grid-area:players;min-width:0;margin-top:14px}
.players-head{display:flex;align-items:center;justify-content:space-between;margin:0 2px 8px;color:#aaa8bc;font-size:12px;font-weight:700}
.player-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;max-height:232px;min-width:0;margin:0;padding:0;overflow:auto;overscroll-behavior:contain;list-style:none;scrollbar-color:#4d4b63 transparent}
.player{display:grid;grid-template-columns:36px minmax(0,1fr) auto;gap:10px;align-items:center;min-width:0;padding:9px 10px;border:1px solid #2c2c3c;border-radius:11px;background:#11111a}
.player[data-connected="false"]{opacity:.56}
.avatar{display:grid;place-items:center;width:36px;height:36px;overflow:hidden;border:1px solid #6259b4;border-radius:11px;background:#292348;color:#d9d3ff;font:800 13px/1 ui-rounded,"SF Pro Rounded",system-ui,sans-serif}.avatar img{width:100%;height:100%;object-fit:cover}
.player:nth-child(3n+2) .avatar{border-color:#317665;background:#16392f;color:#a7f4df}.player:nth-child(3n) .avatar{border-color:#75612d;background:#3a3017;color:#ffe09a}
.player-copy{min-width:0;text-align:left}.player-copy strong,.player-copy small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.player-copy strong{font-size:13px}.player-copy small{margin-top:2px;color:#8f8ca3;font-size:11px}
.current-tag{padding:3px 6px;border:1px solid #51468f;border-radius:999px;color:#cfc8ff;background:#292348;font-size:9px;font-weight:800;letter-spacing:.05em;text-transform:uppercase}
.actions{grid-area:actions;display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:18px}
button{min-height:var(--tap-target);min-width:0;padding:10px 15px;border:1px solid transparent;border-radius:12px;background:var(--purple);color:white;font-weight:750;overflow-wrap:anywhere;cursor:pointer;transition:transform .14s ease,background-color .14s ease,border-color .14s ease}
button:hover:not(:disabled){background:#866df8;transform:translateY(-1px)}
button:active:not(:disabled){transform:translateY(0)}
button:focus-visible{outline:3px solid var(--amber);outline-offset:3px}
button.secondary{border-color:#48475c;background:#222230;color:#efedf8}
button.secondary:hover:not(:disabled){background:#2b2a3b;border-color:#66647d}
button.solo{grid-column:1/-1;border-color:#65572f;background:#211d14;color:#ffe09a}
button.solo:hover:not(:disabled){background:#2b2517;border-color:#917a3b}
button:disabled{cursor:not-allowed;opacity:.48;transform:none}
button[hidden]{display:none!important}
.action-note{grid-area:note;margin:9px 2px 0;color:#c6a95c;font-size:12px;text-align:left}
.action-note[hidden]{display:none}
.footer{grid-area:footer;display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:18px;padding-top:14px;border-top:1px solid var(--line);color:#89869b;font-size:11px}
.footer kbd{display:inline-grid;place-items:center;min-width:25px;height:22px;margin-right:6px;padding:0 6px;border:1px solid #4a495a;border-bottom-width:2px;border-radius:6px;background:#20202c;color:#d8d5e4;font:700 11px/1 ui-monospace,"Cascadia Mono",monospace}
[hidden]{display:none!important}
@keyframes mesh-pulse{0%{transform:scale(.65);opacity:.9}75%,100%{transform:scale(1.8);opacity:0}}
@media(hover:none),(pointer:coarse){:root{--tap-target:48px}button:hover:not(:disabled){transform:none}}
@media(min-width:800px) and (hover:hover) and (pointer:fine){.card:has(#escHint:not([hidden])){width:min(100%,880px);grid-template-areas:"hero hero" "status metrics" "players actions" "players note" "footer footer";grid-template-columns:minmax(0,1fr) minmax(252px,280px);column-gap:var(--column-gap);align-items:start}.card:has(#escHint:not([hidden])) .metrics{grid-template-columns:1fr;margin-top:22px}.card:has(#escHint:not([hidden])) .metric{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;align-items:center;padding:9px 12px}.card:has(#escHint:not([hidden])) .metric dd{margin:0}.card:has(#escHint:not([hidden])) .actions{grid-template-columns:1fr;margin-top:14px}.card:has(#escHint:not([hidden])) .actions button,.card:has(#escHint:not([hidden])) .actions .solo{grid-column:1}.card:has(#escHint:not([hidden])) .player-list{max-height:252px}}
@media(orientation:landscape) and (max-height:540px) and (pointer:coarse){:root{--frame-pad:8px;--card-pad:12px;--column-gap:14px}.card:has(#escHint:not([hidden])){width:min(100%,920px);grid-template-areas:"hero hero" "status metrics" "players actions" "players note" "footer footer";grid-template-columns:minmax(0,1.25fr) minmax(220px,.75fr);column-gap:var(--column-gap);align-items:start;border-radius:16px}.card:has(#escHint:not([hidden])) .hero{grid-template-columns:44px minmax(0,1fr);gap:12px}.card:has(#escHint:not([hidden])) .mesh-mark{width:44px;height:44px;border-radius:13px}.card:has(#escHint:not([hidden])) .mesh-mark:before,.card:has(#escHint:not([hidden])) .mesh-mark:after{left:11px;top:21px;width:23px}.card:has(#escHint:not([hidden])) .node-a{left:7px;top:17px}.card:has(#escHint:not([hidden])) .node-b{right:5px;top:5px}.card:has(#escHint:not([hidden])) .node-c{right:5px;bottom:5px}.card:has(#escHint:not([hidden])) h1{margin-top:4px;font-size:25px}.card:has(#escHint:not([hidden])) .lead{display:none}.card:has(#escHint:not([hidden])) .status-panel{margin-top:10px;padding:9px 12px}.card:has(#escHint:not([hidden])) .metrics{margin-top:10px}.card:has(#escHint:not([hidden])) .metric{padding:7px 8px}.card:has(#escHint:not([hidden])) .players-panel{margin-top:9px}.card:has(#escHint:not([hidden])) .player-list{max-height:142px}.card:has(#escHint:not([hidden])) .player{padding:7px 8px}.card:has(#escHint:not([hidden])) .actions{margin-top:10px;gap:8px}.card:has(#escHint:not([hidden])) .footer{margin-top:9px;padding-top:8px}}
@media(max-width:479px) and (orientation:portrait){:root{--frame-pad:8px;--card-pad:16px}.card{border-radius:17px}.hero{grid-template-columns:44px minmax(0,1fr);gap:12px}.mesh-mark{width:44px;height:44px;border-radius:13px}.mesh-mark:before,.mesh-mark:after{left:11px;top:21px;width:23px}.node-a{left:7px;top:17px}.node-b{right:5px;top:5px}.node-c{right:5px;bottom:5px}.brand-line{align-items:flex-start;flex-direction:column;gap:5px}h1{font-size:clamp(25px,9vw,32px)}.status-panel{margin-top:15px}.player-list{grid-template-columns:1fr;max-height:clamp(112px,24dvh,234px)}.actions{grid-template-columns:1fr}.actions button,.actions .solo{grid-column:1}.footer{align-items:flex-start;flex-direction:column}}
@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation:none!important;scroll-behavior:auto!important;transition:none!important}}
@media(prefers-contrast:more){:root{--line:#77758a}.card,.status-panel,.metrics,button{border-width:2px}.muted{color:#d8d5e4}}
@media(forced-colors:active){.card,.status-panel,.metrics,.player,button,.connection{forced-color-adjust:auto}.connection-dot,.node{box-shadow:none}.mesh-mark:before,.mesh-mark:after{background:CanvasText}}
</style></head><body><main><section class="card" id="card" role="dialog" aria-modal="true" aria-labelledby="heading" aria-describedby="status"><header class="hero"><div class="mesh-mark" aria-hidden="true"><i class="node node-a"></i><i class="node node-b"></i><i class="node node-c"></i></div><div><div class="brand-line"><span class="eyebrow" id="eyebrow">PLAYMESH · 配对控制台</span><span class="connection" id="connectionBadge" data-tone="connecting"><i class="connection-dot" aria-hidden="true"></i><span id="connectionLabel">连接中</span></span></div><h1 id="heading">${heading}</h1><p class="lead" id="lead">查看玩家状态，准备开始游戏。</p></div></header><div class="status-panel" id="statusPanel" data-tone="connecting" role="status" aria-live="polite" aria-atomic="true"><span class="status-label" id="statusLabel">当前状态</span><p id="status">${initialStatus}</p></div><dl class="metrics" id="metrics" hidden><div class="metric"><dt id="playersLabel">在线玩家</dt><dd id="playerSummary">—</dd></div><div class="metric"><dt id="roleLabel">我的角色</dt><dd id="roleSummary">—</dd></div><div class="metric"><dt id="slotLabel">玩家编号</dt><dd id="playerMeta">—</dd></div></dl><section class="players-panel" id="playersPanel" hidden aria-labelledby="playersHeading"><div class="players-head"><span id="playersHeading">当前玩家</span><span id="playersA11yHint">连接状态</span></div><ul class="player-list" id="playerList" aria-live="polite">${playerSlots}</ul></section><div class="actions" id="actions">${actions}</div><p class="action-note" id="actionNote" hidden></p><footer class="footer"><span id="escHint"${isLobby ? '' : ' hidden'}><kbd>Esc</kbd><span id="escLabel">打开游戏菜单</span></span><span>Playmesh · GDevelop ${ENGINE_VERSION}</span></footer></section></main><script>${frameScript}</script></body></html>`;
  };

  const configureFrame = (frame, kind) => {
    if (
      !frame ||
      typeof frame !== 'object' ||
      typeof frame.setAttribute !== 'function' ||
      typeof frame.removeAttribute !== 'function' ||
      (kind !== 'lobby' && kind !== 'authentication')
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_FRAME_ELEMENT', 'GDevelop iframe 无效。');
    }
    // 先断开任何导航口子；即使安全随机数不可用，也绝不退回官方云页面。
    frame.removeAttribute('src');
    frame.setAttribute('referrerpolicy', 'no-referrer');
    frame.setAttribute('sandbox', 'allow-scripts');
    const capability = createFrameCapability();
    invalidateLocalFrameState(activeLocalFrameByKind[kind]);
    invalidateLocalFrameState(localFrameByElement.get(frame));
    const state = {
      active: true,
      frame,
      kind,
      capability,
      receivedSequence: 0,
      sentSequence: 0,
      readyReceived: false,
      sessionInformationSent: false,
      sessionId: null,
      joinRequested: false,
      joined: false,
      leaveRequested: false,
      joinGameRequested: false,
      countdownRequested: false,
      startRequested: false,
      soloRequested: false,
      pendingOperations: new Map(),
      avatarCache: new Map(),
      avatarDigests: new Map(),
      avatarPresentations: new Map(),
      avatarSources: new Map(),
      avatarRequestVersions: new Map(),
      avatarAbortControllers: new Set(),
      positionInLobby: null,
    };
    localFrameStates.add(state);
    localFrameByElement.set(frame, state);
    activeLocalFrameByKind[kind] = state;
    try {
      frame.srcdoc = createLocalFrameDocument(kind, capability);
    } catch (error) {
      invalidateLocalFrameState(state);
      throw error;
    }
  };

  const readLocalMessageEvent = event => {
    if (!event || typeof event !== 'object') return null;
    try {
      const sourceDescriptor = Object.getOwnPropertyDescriptor(event, 'source');
      const dataDescriptor = Object.getOwnPropertyDescriptor(event, 'data');
      if (sourceDescriptor || dataDescriptor) {
        if (
          !sourceDescriptor ||
          !dataDescriptor ||
          !('value' in sourceDescriptor) ||
          !('value' in dataDescriptor)
        ) {
          return null;
        }
        return { source: sourceDescriptor.value, data: dataDescriptor.value };
      }
      if (
        typeof global.MessageEvent === 'function' &&
        event instanceof global.MessageEvent
      ) {
        return { source: event.source, data: event.data };
      }
    } catch (_) {
      return null;
    }
    return null;
  };

  const activeLocalFrameStateForEvent = (event, kind) => {
    const messageEvent = readLocalMessageEvent(event);
    const state = activeLocalFrameByKind[kind];
    if (!messageEvent || !messageEvent.source || !state || !state.active) {
      return null;
    }
    try {
      if (state.frame.contentWindow !== messageEvent.source) return null;
    } catch (_) {
      return null;
    }
    return { state, data: messageEvent.data };
  };

  const readLocalFrameEnvelope = (event, kind) => {
    const matched = activeLocalFrameStateForEvent(event, kind);
    if (!matched) return null;
    const envelope = readExactDataRecord(matched.data, [
      'protocol',
      'version',
      'kind',
      'nonce',
      'sequence',
      'action',
      'payload',
    ]);
    if (
      !envelope ||
      envelope.protocol !== LOCAL_FRAME_PROTOCOL ||
      envelope.version !== LOCAL_FRAME_VERSION ||
      envelope.kind !== kind ||
      envelope.nonce !== matched.state.capability ||
      !isSafeInteger(envelope.sequence, 1, Number.MAX_SAFE_INTEGER) ||
      envelope.sequence !== matched.state.receivedSequence + 1 ||
      !isBoundedString(envelope.action, 64)
    ) {
      return null;
    }
    return { state: matched.state, envelope };
  };

  const makeOfficialFrameEvent = data =>
    Object.freeze({ data: Object.freeze(data) });

  const toggleHostGameMenu = () => {
    try {
      const appRuntime = global[
        Symbol.for('playmesh.app.internal.v1')
      ];
      return appRuntime?.handleNativeBack?.() === true;
    } catch (_) {
      return false;
    }
  };

  const consumeOfficialLobbyFrameMessage = event => {
    const received = readLocalFrameEnvelope(event, 'lobby');
    if (!received) return null;
    const { state, envelope } = received;
    let officialData;
    if (envelope.action === 'ready') {
      const payload = readExactDataRecord(envelope.payload, []);
      if (!payload) return null;
      if (state.readyReceived || envelope.sequence !== 1) return null;
      state.readyReceived = true;
      officialData = { id: 'lobbiesListenerReady' };
    } else if (envelope.action === 'hostMenuToggle') {
      const payload = readExactDataRecord(envelope.payload, []);
      if (!payload) return null;
      // The sandboxed lobby iframe owns native keyboard focus, so Escape does
      // not bubble to the parent App SDK. Reuse the existing per-frame
      // capability/WindowProxy/sequence boundary and invoke only the App
      // runtime's menu/back semantic; this never becomes an official GDevelop
      // lobby event or a general-purpose host command bridge.
      if (!state.readyReceived) return null;
      state.receivedSequence = envelope.sequence;
      toggleHostGameMenu();
      return null;
    } else {
      const payload = readExactDataRecord(
        envelope.payload,
        envelope.action === 'setReady' ? ['requestId', 'ready'] : ['requestId']
      );
      if (
        !payload ||
        !isBoundedString(payload.requestId, MAX_LOBBY_REQUEST_ID_BYTES) ||
        !/^[A-Za-z0-9._~-]+$/.test(payload.requestId) ||
        (envelope.action === 'setReady' && typeof payload.ready !== 'boolean') ||
        !LOBBY_ACTIONS.includes(envelope.action)
      ) {
        return null;
      }
      state.receivedSequence = envelope.sequence;
      const reject = (code, reason, retryable = true) => {
        const operation = beginLobbyOperation(
          state,
          envelope.action,
          payload.requestId
        );
        if (!operation) {
          postLocalFrameEnvelope(state, 'operationFailed', {
            action: envelope.action,
            requestId: payload.requestId,
            code: 'OPERATION_IN_PROGRESS',
            reason: 'operation_in_progress',
            retryable: true,
          });
          return null;
        }
        settleLobbyOperation(
          operation,
          Object.assign(new Error(reason), {
            code,
            publicLobbyFailure: { code, reason, retryable },
          })
        );
        return null;
      };
      if (
        !state.readyReceived ||
        !state.sessionInformationSent ||
        !session ||
        state.sessionId !== session.id
      ) {
        return reject('PLAYMESH_GDEVELOP_NO_SESSION', 'session_unavailable');
      }
      if (
        state.leaveRequested &&
        envelope.action !== 'leaveLobby' &&
        envelope.action !== 'switchToSolo'
      ) {
        return reject(
          'PLAYMESH_GDEVELOP_OPERATION_IN_PROGRESS',
          'leave_in_progress'
        );
      }
      const operation = beginLobbyOperation(
        state,
        envelope.action,
        payload.requestId
      );
      if (!operation) {
        postLocalFrameEnvelope(state, 'operationFailed', {
          action: envelope.action,
          requestId: payload.requestId,
          code: 'OPERATION_IN_PROGRESS',
          reason: 'operation_in_progress',
          retryable: true,
        });
        return null;
      }
      const failPrecondition = (code, message) => {
        settleLobbyOperation(
          operation,
          Object.assign(new Error(message), { code })
        );
        return null;
      };
      if (envelope.action === 'joinCurrentSession') {
        if (
          state.joinRequested ||
          state.joined ||
          session.state === 'stopped'
        ) {
          return failPrecondition(
            'PLAYMESH_GDEVELOP_INVALID_STATE',
            '当前状态不能加入大厅。'
          );
        }
        state.joinRequested = true;
        officialData = { id: 'joinLobby', lobbyId: session.id };
      } else if (envelope.action === 'setReady') {
        if (
          !state.joined ||
          authority ||
          session.state !== 'lobby' ||
          state.positionInLobby === 1
        ) {
          return failPrecondition(
            authority
              ? 'PLAYMESH_GDEVELOP_AUTHORITY_ONLY'
              : 'PLAYMESH_GDEVELOP_INVALID_STATE',
            '当前状态不能修改准备状态。'
          );
        }
        requestGuestIntentReady(payload.ready, operation);
        return null;
      } else if (envelope.action === 'startGameCountdown') {
        if (
          !state.joined ||
          !authority ||
          session.state !== 'lobby' ||
          state.positionInLobby !== 1 ||
          state.countdownRequested
        ) {
          return failPrecondition(
            authority
              ? 'PLAYMESH_GDEVELOP_INVALID_STATE'
              : 'PLAYMESH_GDEVELOP_AUTHORITY_ONLY',
            '当前状态不能开始准备。'
          );
        }
        state.countdownRequested = true;
        officialData = { id: 'startGameCountdown' };
      } else if (envelope.action === 'startGame') {
        if (
          !state.joined ||
          !authority ||
          session.state !== 'lobby' ||
          state.positionInLobby !== 1
        ) {
          return failPrecondition(
            authority
              ? 'PLAYMESH_GDEVELOP_INVALID_STATE'
              : 'PLAYMESH_GDEVELOP_AUTHORITY_ONLY',
            '当前状态不能开始游戏。'
          );
        }
        state.startRequested = true;
        officialData = { id: 'startGame' };
      } else if (envelope.action === 'joinGame') {
        if (
          !state.joined ||
          authority ||
          session.state !== 'running'
        ) {
          return failPrecondition(
            authority
              ? 'PLAYMESH_GDEVELOP_GUEST_ONLY'
              : 'PLAYMESH_GDEVELOP_INVALID_STATE',
            '当前状态不能进入游戏。'
          );
        }
        state.joinGameRequested = true;
        officialData = { id: 'joinGame' };
      } else if (envelope.action === 'leaveLobby') {
        if (!state.joined && !state.joinRequested) {
          return failPrecondition(
            'PLAYMESH_GDEVELOP_INVALID_STATE',
            '当前未加入大厅。'
          );
        }
        if (!authority && session.state === 'lobby') clearGuestReadiness(true);
        state.leaveRequested = true;
        officialData = { id: 'leaveLobby' };
      } else if (envelope.action === 'switchToSolo') {
        state.soloRequested = true;
        // Reuse the official local leave event so GDevelop clears its current
        // lobby state. Playmesh session membership and transport stay intact.
        officialData = { id: 'leaveLobby' };
      } else {
        return failPrecondition(
          'PLAYMESH_GDEVELOP_UNKNOWN_OPERATION',
          '未知大厅操作。'
        );
      }
      const officialEvent = makeOfficialFrameEvent(officialData);
      officialLobbyEventOperations.set(officialEvent, operation);
      return officialEvent;
    }
    state.receivedSequence = envelope.sequence;
    return makeOfficialFrameEvent(officialData);
  };

  const handleOfficialLobbyFrameMessage = (event, handler) => {
    const officialEvent = consumeOfficialLobbyFrameMessage(event);
    if (!officialEvent) return false;
    if (typeof handler !== 'function') return false;
    const operation = officialLobbyEventOperations.get(officialEvent) || null;
    const previousOperation = activeOfficialLobbyOperation;
    activeOfficialLobbyOperation = operation;
    const finishDispatch = () => {
      if (!operation || operation.settled) return;
      if (operation.action === 'switchToSolo') {
        settleLobbyOperation(operation);
        defer(() => releaseOfficialMultiplayerFacadeForSoloMode(operation.state));
      }
    };
    try {
      const result = handler(officialEvent);
      if (result && typeof result.then === 'function') {
        void Promise.resolve(result).then(finishDispatch, error => {
          settleLobbyOperation(operation, error);
        });
      } else {
        finishDispatch();
      }
    } catch (error) {
      settleLobbyOperation(operation, error);
    } finally {
      activeOfficialLobbyOperation = previousOperation;
    }
    return true;
  };

  const postLocalFrameEnvelope = (state, event, payload) => {
    if (!state || !state.active || activeLocalFrameByKind[state.kind] !== state) {
      return false;
    }
    let target;
    try {
      target = state.frame.contentWindow;
    } catch (_) {
      return false;
    }
    if (!target || typeof target.postMessage !== 'function') return false;
    const sequence = state.sentSequence + 1;
    const envelope = Object.freeze({
      protocol: LOCAL_FRAME_PROTOCOL,
      version: LOCAL_FRAME_VERSION,
      kind: state.kind,
      nonce: state.capability,
      sequence,
      event,
      payload: Object.freeze(payload),
    });
    try {
      // opaque-origin srcdoc 无法使用普通 origin；安全性来自精确 WindowProxy、
      // 256-bit capability 和单调序列，且这里从不发送 credential。
      target.postMessage(envelope, '*');
      state.sentSequence = sequence;
      return true;
    } catch (_) {
      return false;
    }
  };

  const resolveSafeAvatarUrl = value => {
    if (
      !isBoundedString(value, 512) ||
      !/^\/bucket\/_sys-user-avatars\/[A-Za-z0-9._~-]+\.(?:png|jpe?g|webp)$/i.test(
        value
      ) ||
      value.includes('..') ||
      value.includes('%') ||
      value.includes('?') ||
      value.includes('#') ||
      !global.location?.origin ||
      typeof global.URL !== 'function'
    ) {
      return null;
    }
    try {
      const url = new global.URL(value, global.location.origin);
      if (
        url.origin !== global.location.origin ||
        url.pathname !== value ||
        url.search ||
        url.hash ||
        url.username ||
        url.password
      ) {
        return null;
      }
      return url.href;
    } catch (_) {
      return null;
    }
  };

  const sniffAvatarMime = bytes => {
    if (
      bytes.length >= 8 &&
      bytes[0] === 0x89 &&
      bytes[1] === 0x50 &&
      bytes[2] === 0x4e &&
      bytes[3] === 0x47 &&
      bytes[4] === 0x0d &&
      bytes[5] === 0x0a &&
      bytes[6] === 0x1a &&
      bytes[7] === 0x0a
    ) {
      return 'image/png';
    }
    if (
      bytes.length >= 3 &&
      bytes[0] === 0xff &&
      bytes[1] === 0xd8 &&
      bytes[2] === 0xff
    ) {
      return 'image/jpeg';
    }
    if (
      bytes.length >= 12 &&
      bytes[0] === 0x52 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x46 &&
      bytes[8] === 0x57 &&
      bytes[9] === 0x45 &&
      bytes[10] === 0x42 &&
      bytes[11] === 0x50
    ) {
      return 'image/webp';
    }
    return null;
  };

  const readBoundedAvatarBytes = async response => {
    const declaredLength = Number(response.headers?.get?.('content-length'));
    if (
      Number.isFinite(declaredLength) &&
      (declaredLength <= 0 || declaredLength > MAX_AVATAR_BYTES)
    ) {
      return null;
    }
    const reader = response.body?.getReader?.();
    if (!reader) {
      const buffer = await response.arrayBuffer();
      return buffer.byteLength > 0 && buffer.byteLength <= MAX_AVATAR_BYTES
        ? new Uint8Array(buffer)
        : null;
    }
    const chunks = [];
    let total = 0;
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      const chunk = next.value;
      if (!(chunk instanceof Uint8Array)) {
        await reader.cancel().catch(() => {});
        return null;
      }
      total += chunk.byteLength;
      if (total > MAX_AVATAR_BYTES) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(chunk);
    }
    if (total === 0) return null;
    const bytes = new Uint8Array(total);
    let offset = 0;
    chunks.forEach(chunk => {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    });
    return bytes;
  };

  const encodeAvatarDataUrl = (mime, bytes) => {
    if (typeof global.btoa !== 'function') return null;
    let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
    }
    return `data:${mime};base64,${global.btoa(binary)}`;
  };

  const decodeAvatarDimensions = async (mime, bytes) => {
    const blob = new global.Blob([bytes], { type: mime });
    if (typeof global.createImageBitmap === 'function') {
      const bitmap = await global.createImageBitmap(blob);
      try {
        return { width: bitmap.width, height: bitmap.height };
      } finally {
        bitmap.close?.();
      }
    }
    if (
      typeof global.Image !== 'function' ||
      typeof global.URL?.createObjectURL !== 'function' ||
      typeof global.URL?.revokeObjectURL !== 'function'
    ) {
      return null;
    }
    const objectUrl = global.URL.createObjectURL(blob);
    const image = new global.Image();
    try {
      return await new Promise((resolve, reject) => {
        let settled = false;
        const settle = callback => value => {
          if (settled) return;
          settled = true;
          callback(value);
        };
        image.onload = settle(() =>
          resolve({
            width: image.naturalWidth || image.width,
            height: image.naturalHeight || image.height,
          })
        );
        image.onerror = settle(() => reject(new Error('avatar_decode_failed')));
        image.src = objectUrl;
        if (typeof image.decode === 'function') {
          void image.decode().then(image.onload, image.onerror);
        }
      });
    } finally {
      image.onload = null;
      image.onerror = null;
      image.src = '';
      global.URL.revokeObjectURL(objectUrl);
    }
  };

  const loadVerifiedAvatar = (state, sourcePath) => {
    const safeUrl = resolveSafeAvatarUrl(sourcePath);
    if (
      !safeUrl ||
      typeof global.fetch !== 'function' ||
      typeof global.Blob !== 'function' ||
      !global.crypto?.subtle
    ) {
      return Promise.resolve(null);
    }
    const pending = state.avatarCache.get(safeUrl);
    if (pending) return pending;
    const controller =
      typeof global.AbortController === 'function'
        ? new global.AbortController()
        : null;
    if (controller) state.avatarAbortControllers.add(controller);
    const operation = (async () => {
      try {
        const response = await global.fetch(safeUrl, {
          method: 'GET',
          credentials: 'same-origin',
          cache: 'no-store',
          redirect: 'error',
          referrerPolicy: 'no-referrer',
          signal: controller?.signal,
        });
        if (!response || response.ok !== true) return null;
        const declaredMime = String(
          response.headers?.get?.('content-type') || ''
        )
          .split(';', 1)[0]
          .trim()
          .toLowerCase();
        if (!['image/png', 'image/jpeg', 'image/webp'].includes(declaredMime)) {
          return null;
        }
        const bytes = await readBoundedAvatarBytes(response);
        if (!bytes || sniffAvatarMime(bytes) !== declaredMime) return null;
        const dimensions = await decodeAvatarDimensions(declaredMime, bytes);
        if (
          !dimensions ||
          !isSafeInteger(dimensions.width, 1, MAX_AVATAR_DIMENSION) ||
          !isSafeInteger(dimensions.height, 1, MAX_AVATAR_DIMENSION) ||
          dimensions.width * dimensions.height > MAX_AVATAR_PIXELS
        ) {
          return null;
        }
        const digestBytes = new Uint8Array(
          await global.crypto.subtle.digest('SHA-256', bytes)
        );
        const digest = Array.from(digestBytes, byte =>
          byte.toString(16).padStart(2, '0')
        ).join('');
        const dataUrl = encodeAvatarDataUrl(declaredMime, bytes);
        return dataUrl ? Object.freeze({ digest, dataUrl }) : null;
      } catch (_) {
        return null;
      } finally {
        if (controller) state.avatarAbortControllers.delete(controller);
      }
    })();
    state.avatarCache.set(safeUrl, operation);
    void operation.finally(() => {
      if (state.avatarCache.get(safeUrl) === operation) {
        state.avatarCache.delete(safeUrl);
      }
    });
    return operation;
  };

  const postLocalFramePlayerVisuals = state =>
    postLocalFrameEnvelope(state, 'playersVisualUpdated', {
      players: localLobbyPlayerSummaries(state.avatarPresentations),
    });

  // Reconcile the authoritative presentation map synchronously before a
  // lobby snapshot is emitted. Unrelated state updates keep verified avatars;
  // a changed/removed source invalidates only its stable player number.
  const reconcileLocalFrameAvatarSources = state => {
    if (!state.active || !session || state.sessionId !== session.id) return false;
    const activeNumbers = new Set();
    let presentationRemoved = false;
    session.players.forEach(player => {
      const number = playerNumberForActualId(player.id);
      if (!isSafeInteger(number, 1, MAX_PLAYERS)) return;
      activeNumbers.add(number);
      const sourcePath = player.avatar || null;
      const previousSource = state.avatarSources.get(number) || null;
      if (previousSource === sourcePath) return;
      state.avatarSources.set(number, sourcePath);
      state.avatarRequestVersions.set(
        number,
        (state.avatarRequestVersions.get(number) || 0) + 1
      );
      state.avatarDigests.delete(number);
      if (state.avatarPresentations.delete(number)) presentationRemoved = true;
    });
    [...state.avatarSources.keys()].forEach(number => {
      if (activeNumbers.has(number)) return;
      state.avatarSources.delete(number);
      state.avatarRequestVersions.delete(number);
      state.avatarDigests.delete(number);
      if (state.avatarPresentations.delete(number)) presentationRemoved = true;
    });
    return presentationRemoved;
  };

  const refreshLocalFramePlayerAvatars = state => {
    if (!state.active || !session || state.sessionId !== session.id) return;
    const sessionId = session.id;
    const candidates = [];
    const presentationRemoved = reconcileLocalFrameAvatarSources(state);

    session.players.forEach(player => {
      const number = playerNumberForActualId(player.id);
      if (!isSafeInteger(number, 1, MAX_PLAYERS)) return;
      const sourcePath = player.avatar || null;
      const requestVersion = (state.avatarRequestVersions.get(number) || 0) + 1;
      state.avatarRequestVersions.set(number, requestVersion);
      if (sourcePath) candidates.push({ number, sourcePath, requestVersion });
    });

    if (presentationRemoved) postLocalFramePlayerVisuals(state);

    candidates.forEach(candidate => {
      void loadVerifiedAvatar(state, candidate.sourcePath).then(presentation => {
        if (
          !state.active ||
          !session ||
          session.id !== sessionId ||
          state.sessionId !== sessionId ||
          state.avatarSources.get(candidate.number) !== candidate.sourcePath ||
          state.avatarRequestVersions.get(candidate.number) !==
            candidate.requestVersion
        ) {
          return;
        }
        const previousDigest = state.avatarDigests.get(candidate.number) || null;
        const nextDigest = presentation?.digest || null;
        if (!presentation) {
          state.avatarDigests.delete(candidate.number);
          if (state.avatarPresentations.delete(candidate.number)) {
            postLocalFramePlayerVisuals(state);
          }
          return;
        }
        state.avatarDigests.set(candidate.number, nextDigest);
        state.avatarPresentations.set(candidate.number, presentation);
        if (previousDigest !== nextDigest) postLocalFramePlayerVisuals(state);
      });
    });
  };

  const postOfficialLobbyFrameMessage = (frame, message) => {
    const state = localFrameByElement.get(frame);
    if (
      !state ||
      !state.active ||
      state.kind !== 'lobby' ||
      activeLocalFrameByKind.lobby !== state
    ) {
      return false;
    }
    const idProperty = readOwnDataValue(message, 'id');
    if (!idProperty || !isBoundedString(idProperty.value, 64)) return false;
    const id = idProperty.value;
    let payload;
    if (id === 'sessionInformation') {
      const record = readExactDataRecord(message, [
        'id',
        'isCordova',
        'devicePlatform',
        'navigatorPlatform',
        'hasTouch',
      ]);
      if (
        !record ||
        !state.readyReceived ||
        state.sessionInformationSent ||
        typeof record.isCordova !== 'boolean' ||
        typeof record.hasTouch !== 'boolean' ||
        !isBoundedString(record.devicePlatform, 128, true) ||
        !isBoundedString(record.navigatorPlatform, 128, true) ||
        !session
      ) {
        return false;
      }
      state.sessionInformationSent = true;
      state.sessionId = session.id;
      reconcileLocalFrameAvatarSources(state);
      payload = {
        isCordova: record.isCordova,
        devicePlatform: record.devicePlatform,
        navigatorPlatform: record.navigatorPlatform,
        hasTouch: record.hasTouch,
        role: authority ? 'authority' : 'guest',
        sessionId: session.id,
        sessionState: session.state,
        positionInLobby: currentPlayerNumber(),
        connectedPlayers: connectedSessionPlayerCount(),
        minPlayers: session.minPlayers,
        maxPlayers: session.maxPlayers,
        players: localLobbyPlayerSummaries(state.avatarPresentations),
        soloAvailable: true,
        soloUnavailableReason: null,
      };
    } else if (id === 'lobbyJoined') {
      const record = readExactDataRecord(message, [
        'id',
        'lobbyId',
        'playerId',
        'playerToken',
        'connectionId',
        'positionInLobby',
      ]);
      if (
        !record ||
        !state.sessionInformationSent ||
        !session ||
        state.sessionId !== session.id ||
        record.lobbyId !== session.id ||
        !isBoundedString(record.playerId, MAX_PLAYER_ID_BYTES) ||
        record.playerId !== currentActualPlayerId() ||
        !isBoundedString(record.playerToken, 512) ||
        !isBoundedString(record.connectionId, 256) ||
        !isSafeInteger(record.positionInLobby, 1, MAX_PLAYERS) ||
        record.positionInLobby !== currentPlayerNumber()
      ) {
        return false;
      }
      state.joinRequested = false;
      state.joined = true;
      state.leaveRequested = false;
      state.positionInLobby = record.positionInLobby;
      reconcileLocalFrameAvatarSources(state);
      payload = {
        lobbyId: record.lobbyId,
        positionInLobby: record.positionInLobby,
        role: authority ? 'authority' : 'guest',
        sessionState: session.state,
        connectedPlayers: connectedSessionPlayerCount(),
        minPlayers: session.minPlayers,
        maxPlayers: session.maxPlayers,
        players: localLobbyPlayerSummaries(state.avatarPresentations),
      };
    } else if (id === 'lobbyUpdated') {
      const record = readExactDataRecord(message, ['id', 'positionInLobby']);
      if (
        !record ||
        !state.joined ||
        !session ||
        state.sessionId !== session.id ||
        !isSafeInteger(record.positionInLobby, 1, MAX_PLAYERS) ||
        record.positionInLobby !== currentPlayerNumber()
      ) {
        return false;
      }
      state.positionInLobby = record.positionInLobby;
      reconcileLocalFrameAvatarSources(state);
      payload = {
        positionInLobby: record.positionInLobby,
        sessionState: session.state,
        connectedPlayers: connectedSessionPlayerCount(),
        minPlayers: session.minPlayers,
        maxPlayers: session.maxPlayers,
        players: localLobbyPlayerSummaries(state.avatarPresentations),
      };
    } else if (id === 'lobbyLeft') {
      if (
        !readExactDataRecord(message, ['id']) ||
        (!state.joined && !state.joinRequested)
      ) {
        return false;
      }
      state.joinRequested = false;
      state.joined = false;
      state.leaveRequested = false;
      state.joinGameRequested = false;
      state.countdownRequested = false;
      state.startRequested = false;
      state.positionInLobby = null;
      payload = {};
    } else {
      return false;
    }
    const posted = postLocalFrameEnvelope(state, id, payload);
    if (id === 'lobbyJoined') {
      settleLobbyOperation(
        state.pendingOperations.get('joinCurrentSession') || null
      );
    } else if (id === 'lobbyLeft') {
      const leaveOperation = state.pendingOperations.get('leaveLobby') || null;
      const soloOperation = state.pendingOperations.get('switchToSolo') || null;
      const joinOperation =
        state.pendingOperations.get('joinCurrentSession') || null;
      if (leaveOperation) settleLobbyOperation(leaveOperation);
      if (soloOperation) settleLobbyOperation(soloOperation);
      if (joinOperation) {
        settleLobbyOperation(
          joinOperation,
          Object.assign(new Error('Lobby connection closed.'), {
            code: 'PLAYMESH_GDEVELOP_SOCKET_CLOSED',
          })
        );
      }
    }
    if (
      posted &&
      (id === 'sessionInformation' ||
        id === 'lobbyJoined' ||
        id === 'lobbyUpdated')
    ) {
      refreshLocalFramePlayerAvatars(state);
    }
    return posted;
  };

  const opaqueIdentityToken = playerId => {
    const input = `${session ? session.id : ''}|${playerId}`;
    let hash = 2166136261;
    for (let index = 0; index < input.length; index += 1) {
      hash ^= input.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return `pm-gd-v1-${(hash >>> 0).toString(16).padStart(8, '0')}`;
  };

  const hostIdentity = () => {
    const playerId = currentActualPlayerId();
    if (!playerId) return null;
    const playerRecord = sessionPlayerByActualId(playerId);
    return {
      username: (currentPlayer?.nickname || playerRecord?.nickname || 'Host').slice(
        0,
        32
      ),
      userId: playerId,
      userToken: opaqueIdentityToken(playerId),
    };
  };

  const validateIdentityKey = key => {
    const suffix = '_authenticatedUser';
    if (
      !isBoundedString(key, 192) ||
      !key.endsWith(suffix) ||
      !isBoundedString(key.slice(0, -suffix.length), 160)
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_IDENTITY_KEY', 'GDevelop 身份存储 key 无效。');
    }
    if (officialIdentityKey === null) {
      officialIdentityKey = key;
    } else if (officialIdentityKey !== key) {
      fail('PLAYMESH_GDEVELOP_SCOPE_MISMATCH', 'GDevelop 身份存储 key 越权。');
    }
  };

  const normalizeIdentityValue = value => {
    let record = value;
    if (typeof value === 'string') {
      if (encoder.encode(value).byteLength > 2048) {
        fail('PLAYMESH_GDEVELOP_INVALID_IDENTITY', 'GDevelop 身份记录过大。');
      }
      try {
        record = JSON.parse(value);
      } catch (_) {
        fail('PLAYMESH_GDEVELOP_INVALID_IDENTITY', 'GDevelop 身份记录无效。');
      }
    }
    const identity = readExactDataRecord(record, [
      'username',
      'userId',
      'userToken',
    ]);
    if (
      !identity ||
      (identity.username !== null &&
        !isBoundedString(identity.username, 128)) ||
      !isBoundedString(identity.userId, MAX_PLAYER_ID_BYTES) ||
      !isBoundedString(identity.userToken, 256)
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_IDENTITY', 'GDevelop 身份记录无效。');
    }
    const expected = hostIdentity();
    if (
      !expected ||
      identity.userId !== expected.userId ||
      identity.userToken !== expected.userToken
    ) {
      fail('PLAYMESH_GDEVELOP_SCOPE_MISMATCH', 'GDevelop 身份记录不属于当前玩家。');
    }
    return {
      username: identity.username,
      userId: identity.userId,
      userToken: identity.userToken,
    };
  };

  const handleAuthenticationFrame = (socket, frame) => {
    if (!hasExactKeys(frame, ['action']) || frame.action !== 'getConnectionId') {
      fail('PLAYMESH_GDEVELOP_INVALID_FRAME', 'GDevelop 身份控制帧无效。');
    }
    const identity = identityRemoved ? null : identityOverride || hostIdentity();
    if (!identity) {
      fail('PLAYMESH_GDEVELOP_IDENTITY_UNAVAILABLE', '当前 Playmesh 玩家身份不可用。');
    }
    socket.__emit({
      type: 'connectionId',
      data: { connectionId: `pm-gd-auth-v1-${currentPlayerNumber() || 1}` },
    });
    defer(() => {
      socket.__emit({
        type: 'authenticationResult',
        data: {
          userId: identity.userId,
          username: identity.username,
          token: identity.userToken,
        },
      });
    });
  };

  const consumeOfficialAuthenticationFrameMessage = event => {
    const received = readLocalFrameEnvelope(event, 'authentication');
    if (!received) return null;
    const { state, envelope } = received;
    if (
      envelope.sequence !== 1 ||
      envelope.action !== 'authenticate' ||
      !readExactDataRecord(envelope.payload, [])
    ) {
      return null;
    }
    // “退出官方身份”只清理 GDevelop 本地登录态；再次点击登录仍可从
    // Playmesh 当前玩家恢复身份。credential 仅进入父端官方处理器。
    const identity = identityOverride || hostIdentity();
    if (
      !identity ||
      (identity.username !== null &&
        !isBoundedString(identity.username, 128)) ||
      !isBoundedString(identity.userId, MAX_PLAYER_ID_BYTES) ||
      !isBoundedString(identity.userToken, 256)
    ) {
      return null;
    }
    state.receivedSequence = envelope.sequence;
    return makeOfficialFrameEvent({
      id: 'authenticationResult',
      body: Object.freeze({
        userId: identity.userId,
        username: identity.username,
        token: identity.userToken,
      }),
    });
  };

  const playerAuthenticationFacade = Object.freeze({
    readOfficialIdentity(key) {
      validateIdentityKey(key);
      if (identityRemoved) return null;
      const identity = identityOverride || hostIdentity();
      return identity ? JSON.stringify(identity) : null;
    },
    writeOfficialIdentity(key, value) {
      validateIdentityKey(key);
      identityOverride = normalizeIdentityValue(value);
      identityRemoved = false;
    },
    removeOfficialIdentity(key) {
      validateIdentityKey(key);
      identityOverride = null;
      identityRemoved = true;
    },
    async checkGameRegistration(payload) {
      if (!hasExactKeys(payload, ['gameId'])) {
        fail('PLAYMESH_GDEVELOP_INVALID_REQUEST', '身份注册检查请求无效。');
      }
      await ensureMultiplayerRuntimeOnline();
      if (!main || !session) {
        fail('PLAYMESH_GDEVELOP_NO_SESSION', 'GDevelop 身份后端尚未就绪。');
      }
      validateGameId(payload.gameId);
      return Object.freeze({ registered: true });
    },
    createOfficialAuthenticationControlFacade() {
      if (arguments.length) {
        fail(
          'PLAYMESH_GDEVELOP_FORBIDDEN_ARGUMENT',
          '身份控制 façade 不接受 URL 或 credential。'
        );
      }
      if (currentMultiplayerRuntimeReadiness(main)) {
        const socket = makeControlSocket(
          'authentication',
          handleAuthenticationFrame
        );
        authSockets.add(socket);
        return socket;
      }
      return makeDeferredControlSocket(
        'authentication',
        handleAuthenticationFrame
      );
    },
    configureOfficialAuthenticationFrame(frame) {
      configureFrame(frame, 'authentication');
    },
    consumeOfficialAuthenticationFrameMessage,
  });

  const multiplayerFacade = Object.freeze({
    createOfficialPeer,
    request: multiplayerRequest,
    createOfficialLobbyControlFacade,
    configureOfficialLobbyFrame(frame) {
      configureFrame(frame, 'lobby');
    },
    consumeOfficialLobbyFrameMessage,
    handleOfficialLobbyFrameMessage,
    postOfficialLobbyFrameMessage,
    notifyOfficialLobbyFrameClosed() {
      const state = activeLocalFrameByKind.lobby;
      if (!state?.active) return false;
      // Official gameStarted also removes the lobby container. Running is not
      // an unready transition; every other close is.
      if (!authority && session?.state === 'lobby') clearGuestReadiness(true);
      invalidateLocalFrameState(state);
      return true;
    },
  });

  function notifyLobbySessionChanged(previousState) {
    if (!session) return;
    const position = currentPlayerNumber();
    lobbySockets.forEach(socket => {
      if (position) {
        socket.__emit({ type: 'lobbyUpdated', data: { positionInLobby: position } });
      }
      if (
        session.state === 'running' &&
        previousState !== 'running' &&
        !socket.__state.gameStarted
      ) {
        if (authority) {
          notifyLobbySocketGameStarted(socket);
        } else {
          void emitAuthorityPeerAndMaybeStart(socket).catch(() => {});
        }
      }
    });
  }

  const setWarningSink = nextSink => {
    if (nextSink !== null && typeof nextSink !== 'function') {
      fail(
        'PLAYMESH_GDEVELOP_INVALID_WARNING_SINK',
        'GDevelop 运行警告接收器必须是函数或 null。'
      );
    }
    warningSink = nextSink;
    return true;
  };

  const warningPresentationMessages = Object.freeze({
    'zh-CN': Object.freeze({
      title: 'Playmesh 多人同步未启用',
      dismiss: '关闭',
      game_not_multiplayer:
        '当前游戏未启用多人模式；本地逻辑会继续运行，但不会进行多人同步。',
      game_type_unavailable:
        '当前游戏类型配置暂不可用；本地逻辑会继续运行，但不会进行多人同步。',
      multiplayer_behavior_requires_online_game:
        '检测到 GDevelop 多人对象或行为，请先把项目设置为在线游戏。',
      session_unavailable:
        '当前 Playmesh 对局尚不可用；本地逻辑会继续运行，待对局可用后再同步。',
      host_state_mismatch:
        'Playmesh 宿主多人状态与游戏不一致；本地逻辑会继续运行，本次不连接多人服务。',
    }),
    en: Object.freeze({
      title: 'Playmesh multiplayer sync is inactive',
      dismiss: 'Dismiss',
      game_not_multiplayer:
        'This game is not in multiplayer mode. Local logic continues without multiplayer synchronization.',
      game_type_unavailable:
        'The game type configuration is unavailable. Local logic continues without multiplayer synchronization.',
      multiplayer_behavior_requires_online_game:
        'A GDevelop multiplayer object or behavior was detected. Set the project to an online game first.',
      session_unavailable:
        'The Playmesh session is not available yet. Local logic continues and synchronization can resume later.',
      host_state_mismatch:
        'The Playmesh host multiplayer state does not match the game. Local logic continues without a multiplayer connection.',
    }),
  });
  const presentedWarningReasons = new Set();

  const resolveWarningPresentationMessages = () => {
    let locale = '';
    try {
      locale = global.playmesh?.app?.runtime?.getLocale?.() || '';
    } catch (_) {}
    if (!locale) locale = global.document?.documentElement?.lang || '';
    if (!locale) locale = global.navigator?.language || '';
    return String(locale).toLowerCase().startsWith('zh')
      ? warningPresentationMessages['zh-CN']
      : warningPresentationMessages.en;
  };

  const warningPageIdentity = () => {
    const location = global.location;
    return location
      ? `${location.origin || ''}${location.pathname || ''}${
          location.search || ''
        }`
      : 'document';
  };

  const appendRuntimeWarningToast = warning => {
    const document = global.document;
    if (!document?.body || typeof document.createElement !== 'function') {
      return false;
    }
    const messages = resolveWarningPresentationMessages();
    const toast = document.createElement('div');
    toast.setAttribute('role', 'alert');
    toast.setAttribute('data-playmesh-gdevelop-warning', warning.context.activation);
    Object.assign(toast.style, {
      position: 'fixed',
      left: '50%',
      bottom: '24px',
      transform: 'translateX(-50%)',
      zIndex: '2147483647',
      display: 'flex',
      alignItems: 'center',
      gap: '12px',
      maxWidth: 'min(680px, calc(100vw - 32px))',
      padding: '12px 14px',
      border: '1px solid #f2b84b',
      borderRadius: '8px',
      background: '#24242f',
      color: '#ffffff',
      boxShadow: '0 8px 28px rgba(0, 0, 0, 0.4)',
      font: '14px/1.45 system-ui, sans-serif',
    });
    const message = document.createElement('span');
    const reasonMessage = messages[warning.context.activation];
    message.textContent = `${messages.title}：${reasonMessage}`;
    const dismiss = document.createElement('button');
    dismiss.type = 'button';
    dismiss.textContent = messages.dismiss;
    Object.assign(dismiss.style, {
      flex: '0 0 auto',
      border: '0',
      borderRadius: '6px',
      padding: '6px 10px',
      background: '#f2b84b',
      color: '#201b12',
      cursor: 'pointer',
      font: 'inherit',
    });
    dismiss.addEventListener('click', () => toast.remove());
    toast.append(message, dismiss);
    document.body.appendChild(toast);
    return true;
  };

  const presentRuntimeWarning = warning => {
    const reason = warning.context.activation;
    const dedupeKey = `${warningPageIdentity()}\n${reason}`;
    if (presentedWarningReasons.has(dedupeKey)) return;
    presentedWarningReasons.add(dedupeKey);
    global.console?.warn?.('Playmesh GDevelop multiplayer warning', {
      code: warning.code,
      activation: reason,
      sessionPresent: warning.context.sessionPresent,
      behaviorDetected: warning.context.behaviorDetected,
    });
    if (appendRuntimeWarningToast(warning)) return;
    global.document?.addEventListener?.(
      'DOMContentLoaded',
      () => appendRuntimeWarningToast(warning),
      { once: true }
    );
  };

  const emitWarning = warning => {
    const record = readExactDataRecord(warning, ['code', 'source', 'context']);
    const context = record
      ? readExactDataRecord(record.context, [
          'activation',
          'sessionPresent',
          'behaviorDetected',
        ])
      : null;
    if (
      !record ||
      !context ||
      ![
        'MULTIPLAYER_RUNTIME_INACTIVE',
        'MULTIPLAYER_CONFIGURATION_REQUIRED',
        'MULTIPLAYER_HOST_STATE_MISMATCH',
      ].includes(record.code) ||
      record.source !== 'gdevelop-bootstrap' ||
      ![
        'game_not_multiplayer',
        'game_type_unavailable',
        'multiplayer_behavior_requires_online_game',
        'session_unavailable',
        'host_state_mismatch',
      ].includes(context.activation) ||
      typeof context.sessionPresent !== 'boolean' ||
      typeof context.behaviorDetected !== 'boolean'
    ) {
      fail('PLAYMESH_GDEVELOP_INVALID_WARNING', 'GDevelop 运行警告结构无效。');
    }
    if (!warningSink) return false;
    const safeWarning = Object.freeze({
      code: record.code,
      source: record.source,
      context: Object.freeze({
        activation: context.activation,
        sessionPresent: context.sessionPresent,
        behaviorDetected: context.behaviorDetected,
      }),
    });
    try {
      const result = warningSink(safeWarning);
      if (result && typeof result.then === 'function') {
        Promise.resolve(result).catch(() => {});
      }
      return true;
    } catch (_) {
      return false;
    }
  };

  const coordinator = Object.freeze({
    protocol: PROTOCOL,
    version: PROTOCOL_VERSION,
    setWarningSink,
    emitWarning,
    attachRuntime(nextMain) {
      validateRuntimeMain(nextMain);
      if (main && main !== nextMain) {
        fail(
          'PLAYMESH_GDEVELOP_RUNTIME_ALREADY_ATTACHED',
          'GDevelop coordinator 已绑定另一运行时。'
        );
      }
      main = nextMain;
      notifyCoordinatorNegotiationWaiters();
    },
    updateContext(context) {
      if (
        !hasExactKeys(context, [
          'isAuthority',
          'authorityPeerId',
          'currentSession',
          'currentPlayer',
        ]) ||
        typeof context.isAuthority !== 'boolean' ||
        !isBoundedString(context.authorityPeerId, MAX_PLAYER_ID_BYTES)
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_CONTEXT', 'GDevelop coordinator 上下文无效。');
      }
      const previousSession = session;
      const previousSessionId = previousSession?.id || null;
      const previousState = session?.state || null;
      const nextSession = context.currentSession
        ? normalizeSession(context.currentSession)
        : null;
      const nextPlayer = normalizeCurrentPlayer(context.currentPlayer);
      if (
        nextSession &&
        context.isAuthority !== Boolean(main?.session?.isAuthority?.())
      ) {
        fail('PLAYMESH_GDEVELOP_ROLE_MISMATCH', 'GDevelop Authority 角色不匹配。');
      }
      authority = context.isAuthority;
      authorityPeerId = context.authorityPeerId;
      session = nextSession;
      currentPlayer = nextPlayer;
      coordinatorContextRevision += 1;
      if (!session || session.id !== previousSessionId) {
        if (startRound) {
          const error = runtimeFailure(
            'PLAYMESH_GDEVELOP_INVALID_STATE',
            'GDevelop 会话在准备阶段发生变化。'
          );
          settleLobbyOperation(startRound.operation, error);
          cancelStartRound(error);
        }
        authorityReadyTokens.clear();
        remoteReadinessByNumber.clear();
        pendingReadySnapshot = null;
        clearGuestReadiness(false, session?.state !== 'running');
        playerNumbers = emptyPlayerNumbers();
        connections.forEach(connection => closeConnection(connection, false));
        localFrameStates.forEach(state => {
          if (state.kind === 'lobby') clearLocalFrameAvatarState(state);
        });
      } else {
        if (authority) {
          let readinessChanged = false;
          [...authorityReadyTokens.keys()].forEach(playerId => {
            const previousRecord = previousSession?.players.find(
              player => player.id === playerId
            );
            const nextRecord = session.players.find(player => player.id === playerId);
            if (
              !previousRecord?.connected ||
              !nextRecord?.connected ||
              !playerNumbers.assignments.has(playerId)
            ) {
              authorityReadyTokens.delete(playerId);
              readinessChanged = true;
            }
          });
          if (startRound && !sameFrozenParticipants(startRound)) {
            const error = runtimeFailure(
              'PLAYMESH_GDEVELOP_PLAYERS_NOT_READY',
              '在线玩家集合在准备阶段发生变化。'
            );
            settleLobbyOperation(startRound.operation, error);
            cancelStartRound(error);
          }
          if (readinessChanged) broadcastAuthorityReadySnapshot();
        }
        localFrameStates.forEach(state => {
          if (state.kind === 'lobby') refreshLocalFramePlayerAvatars(state);
        });
        if (
          session.state === 'lobby' &&
          previousState &&
          previousState !== 'lobby'
        ) {
          lobbySockets.forEach(socket => {
            socket.__state.gameStartedGeneration += 1;
            socket.__state.gameStarted = false;
            socket.__state.gameStartedPending = false;
            socket.__state.authorityPeerGeneration += 1;
            socket.__state.authorityPeerAnnouncement = null;
            socket.__state.authorityPeerAnnounced = false;
          });
        }
      }
      notifyCoordinatorNegotiationWaiters();
      notifyLobbySessionChanged(previousState);
      if (session?.state !== 'lobby') {
        startRound = null;
        authorityReadyTokens.clear();
        remoteReadinessByNumber.clear();
        pendingReadySnapshot = null;
        clearGuestReadiness(false, session?.state !== 'running');
      }
    },
    applyPlayerNumberSnapshot,
    attachChannel(nextChannel) {
      if (
        !nextChannel ||
        typeof nextChannel !== 'object' ||
        !isBoundedString(nextChannel.id, 256) ||
        typeof nextChannel.send !== 'function' ||
        typeof nextChannel.onMessage !== 'function'
      ) {
        fail('PLAYMESH_GDEVELOP_INVALID_CHANNEL', 'GDevelop Binary Channel 无效。');
      }
      if (channel === nextChannel) return;
      if (channel) {
        authorityReadyTokens.clear();
        remoteReadinessByNumber.clear();
        pendingReadySnapshot = null;
        clearGuestReadiness(false);
      }
      if (unsubscribeChannel) unsubscribeChannel();
      unsubscribeChannel = null;
      channel = nextChannel;
      channelSessionId = session?.id || null;
      const unsubscribe = nextChannel.onMessage(handlePacket);
      if (typeof unsubscribe !== 'function') {
        channel = null;
        channelSessionId = null;
        fail('PLAYMESH_GDEVELOP_INVALID_CHANNEL', 'Binary Channel 订阅契约无效。');
      }
      unsubscribeChannel = unsubscribe;
      notifyCoordinatorNegotiationWaiters();
    },
    detachChannel() {
      if (startRound) {
        const error = runtimeFailure(
          'PLAYMESH_GDEVELOP_CHANNEL_NOT_READY',
          'GDevelop Binary Channel 已断开。'
        );
        settleLobbyOperation(startRound.operation, error);
        cancelStartRound(error);
      }
      authorityReadyTokens.clear();
      remoteReadinessByNumber.clear();
      pendingReadySnapshot = null;
      clearGuestReadiness(false);
      if (unsubscribeChannel) unsubscribeChannel();
      unsubscribeChannel = null;
      channel = null;
      channelSessionId = null;
      notifyCoordinatorNegotiationWaiters();
    },
    dispose() {
      const disposedError = runtimeFailure(
        'PLAYMESH_GDEVELOP_NEGOTIATION_DISPOSED',
        'GDevelop 运行协商已随 coordinator 释放。'
      );
      abortRuntimeNegotiation(disposedError);
      [...deferredControlSockets].forEach(socket => socket.__abort(disposedError));
      deferredControlSockets.clear();
      if (unsubscribeChannel) unsubscribeChannel();
      unsubscribeChannel = null;
      channel = null;
      channelSessionId = null;
      connections.forEach(connection => closeConnection(connection, false));
      connections.clear();
      lobbySockets.forEach(socket => socket.close());
      authSockets.forEach(socket => socket.close());
      lobbySockets.clear();
      authSockets.clear();
      invalidateAllLocalFrames();
      pendingPackets.length = 0;
      if (startRound) {
        cancelStartRound(
          runtimeFailure(
            'PLAYMESH_GDEVELOP_NEGOTIATION_DISPOSED',
            'GDevelop coordinator 已释放。'
          )
        );
      }
      authorityReadyTokens.clear();
      remoteReadinessByNumber.clear();
      pendingReadySnapshot = null;
      guestReadyToken = null;
      guestReadyRequest = null;
      discardGuestPreparation();
      guestReadiness = 'notReady';
      startRound = null;
      acceptPeerPackets = true;
      if (peer) emitPeerEvent('close');
      peer = null;
      peerOpen = false;
      playerNumbers = emptyPlayerNumbers();
      session = null;
      currentPlayer = null;
      authority = false;
      main = null;
      coordinatorContextRevision = 0;
      runtimeNegotiation = null;
      runtimeNegotiationGeneration += 1;
      identityOverride = null;
      identityRemoved = false;
      officialGameId = null;
      officialIdentityKey = null;
      warningSink = null;
    },
  });

  const registry = Object.freeze({
    protocol: 'playmesh.runtime.backends.v1',
    version: 1,
    negotiate(request) {
      if (
        !hasExactKeys(request, [
          'engine',
          'engineVersion',
          'feature',
          'minVersion',
          'maxVersion',
        ]) ||
        request.engine !== ENGINE ||
        request.engineVersion !== ENGINE_VERSION ||
        request.minVersion !== FEATURE_VERSION ||
        request.maxVersion !== FEATURE_VERSION
      ) {
        fail(
          'PLAYMESH_GDEVELOP_BACKEND_INCOMPATIBLE',
          'Playmesh GDevelop 私有运行后端版本不兼容。'
        );
      }
      if (request.feature === 'multiplayer') return multiplayerFacade;
      if (request.feature === 'playerAuthentication') {
        return playerAuthenticationFacade;
      }
      fail('PLAYMESH_GDEVELOP_BACKEND_UNKNOWN', '未知的 GDevelop 私有运行后端。');
    },
  });

  const existingRegistry = global[REGISTRY_SYMBOL];
  if (existingRegistry && existingRegistry !== registry) {
    if (
      existingRegistry.protocol !== registry.protocol ||
      existingRegistry.version !== registry.version ||
      typeof existingRegistry.negotiate !== 'function'
    ) {
      fail(
        'PLAYMESH_GDEVELOP_REGISTRY_CONFLICT',
        'Playmesh 私有运行后端 registry 冲突。'
      );
    }
  } else if (!existingRegistry) {
    Object.defineProperty(global, REGISTRY_SYMBOL, {
      value: registry,
      enumerable: false,
      configurable: false,
      writable: false,
    });
  }

  const existingCoordinator = global[COORDINATOR_SYMBOL];
  if (existingCoordinator && existingCoordinator !== coordinator) {
    if (
      existingCoordinator.protocol !== PROTOCOL ||
      existingCoordinator.version !== PROTOCOL_VERSION
    ) {
      fail(
        'PLAYMESH_GDEVELOP_COORDINATOR_CONFLICT',
        'Playmesh GDevelop coordinator 冲突。'
      );
    }
  } else if (!existingCoordinator) {
    Object.defineProperty(global, COORDINATOR_SYMBOL, {
      value: coordinator,
      enumerable: false,
      configurable: false,
      writable: false,
    });
  }
  // 仅浏览器游戏页安装默认展示层；Authority/无 DOM 运行时仍保持可选 sink。
  if (
    global[COORDINATOR_SYMBOL] === coordinator &&
    global.document &&
    typeof global.document.createElement === 'function'
  ) {
    setWarningSink(presentRuntimeWarning);
  }
})(globalThis);
