import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const bridgeSource = fs.readFileSync(
  new URL('../../../developer/gdevelop-multiplayer-bridge.js', import.meta.url),
  'utf8'
);

const REGISTRY_SYMBOL = Symbol.for('playmesh.runtime.backends.v1');
const COORDINATOR_SYMBOL = Symbol.for(
  'playmesh.gdevelop.multiplayer.coordinator.v1'
);
const PROTOCOL = 'playmesh.gdevelop.multiplayer.v1';

const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise(resolve => setTimeout(resolve, 0));
};

function realmValue(page, value) {
  page.context.__fixtureJson = JSON.stringify(value);
  const result = vm.runInContext('JSON.parse(__fixtureJson)', page.context);
  delete page.context.__fixtureJson;
  return result;
}

function once(target, event) {
  return new Promise(resolve => target.on(event, resolve));
}

function startOfficialDisconnectChecker(connection, onDisconnect, setTimeoutImpl) {
  (function disconnectChecker() {
    if (
      connection.peerConnection &&
      (connection.peerConnection.connectionState === 'failed' ||
        connection.peerConnection.connectionState === 'disconnected' ||
        connection.peerConnection.connectionState === 'closed')
    ) {
      onDisconnect(connection.peer);
    } else {
      setTimeoutImpl(disconnectChecker, 1000);
    }
  })();
}

function createFakeTimers() {
  const callbacks = [];
  return {
    schedule(callback, delay) {
      assert.equal(delay, 1000);
      callbacks.push(callback);
    },
    runNext() {
      const callback = callbacks.shift();
      assert.equal(typeof callback, 'function', '存在待执行的官方断线检查定时器');
      callback();
    },
    get pendingCount() {
      return callbacks.length;
    },
  };
}

function createBoundedFakeTimers() {
  let nextId = 1;
  const jobs = new Map();
  return {
    setTimeout(callback, delay) {
      const id = nextId++;
      jobs.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      jobs.delete(id);
    },
    runNextDelay(delay) {
      const entry = [...jobs.entries()].find(([, job]) => job.delay === delay);
      assert.ok(entry, `a ${delay}ms negotiation timer is scheduled`);
      const [id, job] = entry;
      jobs.delete(id);
      job.callback();
    },
    get pendingCount() {
      return jobs.size;
    },
    get delays() {
      return [...jobs.values()].map(job => job.delay);
    },
  };
}

function createDeferredPromise() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function createFrameFixture() {
  const attributes = new Map([['src', 'https://forbidden.example']]);
  const posted = [];
  const contentWindow = {
    postMessage(message, targetOrigin) {
      posted.push({ message, targetOrigin });
    },
  };
  return {
    attributes,
    posted,
    contentWindow,
    frame: {
      contentWindow,
      srcdoc: '',
      setAttribute(name, value) {
        attributes.set(name, value);
      },
      removeAttribute(name) {
        attributes.delete(name);
      },
    },
  };
}

function readFrameCapability(frame) {
  const match = frame.srcdoc.match(/const capability="([0-9a-f]{64})"/);
  assert.ok(match, 'srcdoc contains a 256-bit per-frame capability');
  return match[1];
}

function runConfiguredFrameDocument(frame) {
  const scriptMatch = frame.srcdoc.match(/<script>([\s\S]*)<\/script>/);
  assert.ok(scriptMatch, 'configured srcdoc contains an executable local UI');
  const outbound = [];
  const windowListeners = new Map();
  const elementIds = [
    'card',
    'status',
    'statusPanel',
    'statusLabel',
    'eyebrow',
    'heading',
    'lead',
    'connectionBadge',
    'connectionLabel',
    'metrics',
    'playersLabel',
    'playerSummary',
    'roleLabel',
    'roleSummary',
    'slotLabel',
    'playerMeta',
    'playersPanel',
    'playersHeading',
    'playersA11yHint',
    'actionNote',
    'escHint',
    'escLabel',
    'join',
    'countdown',
    'start',
    'playerReady',
    'joinGame',
    'leave',
    'solo',
    'authenticate',
    ...Array.from({ length: 8 }, (_, index) => [
      `playerRow${index + 1}`,
      `playerAvatar${index + 1}`,
      `playerImage${index + 1}`,
      `playerName${index + 1}`,
      `playerState${index + 1}`,
      `playerCurrent${index + 1}`,
    ]).flat(),
  ];
  const elements = new Map(
    elementIds.map(id => {
      const listeners = new Map();
      return [
        id,
        {
          hidden: id !== 'status',
          disabled: false,
          textContent: '',
          src: '',
          alt: '',
          dataset: {},
          addEventListener(type, listener) {
            listeners.set(type, listener);
          },
          __listeners: listeners,
        },
      ];
    })
  );
  const parentWindow = {
    postMessage(message, targetOrigin) {
      outbound.push({ message, targetOrigin });
    },
  };
  const sandbox = {
    document: {
      getElementById(id) {
        return elements.get(id) || null;
      },
    },
    parent: parentWindow,
    addEventListener(type, listener) {
      windowListeners.set(type, listener);
    },
  };
  sandbox.window = sandbox;
  const context = vm.createContext(sandbox);
  vm.runInContext(scriptMatch[1], context, {
    filename: 'playmesh-gdevelop-local-frame.js',
  });
  return {
    outbound,
    elements,
    click(id) {
      const element = elements.get(id);
      assert.ok(element, `local frame element ${id} exists`);
      assert.equal(element.hidden, false, `local frame action ${id} is visible`);
      const listener = element.__listeners.get('click');
      assert.equal(typeof listener, 'function');
      listener();
    },
    dispatchFromParent(message, source = parentWindow) {
      const listener = windowListeners.get('message');
      assert.equal(typeof listener, 'function');
      context.__parentMessageJson = JSON.stringify(message);
      const clonedMessage = vm.runInContext(
        'JSON.parse(__parentMessageJson)',
        context
      );
      delete context.__parentMessageJson;
      listener({ source, data: clonedMessage, origin: 'null' });
    },
    dispatchKeydown({
      key = 'Escape',
      repeat = false,
      isComposing = false,
    } = {}) {
      const listener = windowListeners.get('keydown');
      assert.equal(typeof listener, 'function');
      const calls = {
        preventDefault: 0,
        stopPropagation: 0,
        stopImmediatePropagation: 0,
      };
      listener({
        key,
        repeat,
        isComposing,
        preventDefault() {
          calls.preventDefault += 1;
        },
        stopPropagation() {
          calls.stopPropagation += 1;
        },
        stopImmediatePropagation() {
          calls.stopImmediatePropagation += 1;
        },
      });
      return calls;
    },
    parentWindow,
  };
}

function localFrameEnvelope(page, { kind, nonce, sequence, action, payload }) {
  const operationActions = new Set([
    'joinCurrentSession',
    'startGameCountdown',
    'startGame',
    'joinGame',
    'leaveLobby',
    'switchToSolo',
  ]);
  const resolvedPayload =
    payload === undefined && operationActions.has(action)
      ? { requestId: `test-${sequence}-${action}` }
      : payload || {};
  return realmValue(page, {
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind,
    nonce,
    sequence,
    action,
    payload: resolvedPayload,
  });
}

function localFrameEvent(page, frameFixture, envelope, origin = 'null') {
  return {
    source: frameFixture.contentWindow,
    data: localFrameEnvelope(page, envelope),
    origin,
  };
}

function attachTestChannel(page, id = `test-channel-${page.playerId}`) {
  const record = { subscribeCount: 0, unsubscribeCount: 0 };
  const channel = {
    id,
    send() {},
    onMessage() {
      record.subscribeCount += 1;
      return () => {
        record.unsubscribeCount += 1;
      };
    },
  };
  page.coordinator.attachChannel(channel);
  return { channel, record };
}

function applyTestPlayerNumberSnapshot(page, currentSession, revision = 1) {
  const authorityId = currentSession.authorityClientId;
  const orderedPlayers = [
    authorityId,
    ...currentSession.players
      .map(player => player.id)
      .filter(playerId => playerId !== authorityId),
  ];
  page.coordinator.applyPlayerNumberSnapshot(
    realmValue(page, {
      type: 'playerNumbers.snapshot',
      protocol: PROTOCOL,
      version: 1,
      sessionId: currentSession.id,
      epoch: 1,
      revision,
      assignments: orderedPlayers.map((playerId, index) => ({
        playerId,
        playerNumber: index + 1,
      })),
      errorCode: null,
    })
  );
}

function createPage({ authority, playerId, sessionData, runtimeGlobals = {} }) {
  const runtimeConsole = { error() {}, warn() {}, info() {}, log() {} };
  const context = vm.createContext({
    console: runtimeConsole,
    TextEncoder,
    TextDecoder,
    Uint8Array,
    DataView,
    Promise,
    Date,
    crypto: webcrypto,
    setTimeout,
    clearTimeout,
    ...runtimeGlobals,
  });
  vm.runInContext(bridgeSource, context, {
    filename: 'gdevelop-multiplayer-bridge.js',
  });

  const page = { context, authority, playerId };
  const session = realmValue(page, sessionData);
  const currentPlayer = session.players.find(player => player.id === playerId);
  const calls = { start: 0, finish: 0 };
  const main = {
    ready: Promise.resolve(),
    session: {
      isAuthority: () => authority,
      getCurrent: () => session,
      start: async () => {
        calls.start += 1;
        return session;
      },
      finish: async () => {
        calls.finish += 1;
        return session;
      },
    },
    player: { getCurrent: () => currentPlayer },
  };

  page.registry = context[REGISTRY_SYMBOL];
  page.coordinator = context[COORDINATOR_SYMBOL];
  page.main = main;
  page.calls = calls;
  page.session = session;
  page.currentPlayer = currentPlayer;

  page.coordinator.attachRuntime(main);
  page.coordinator.updateContext(
    realmValue(page, {
      isAuthority: authority,
      authorityPeerId: 'authority',
      currentSession: sessionData,
      currentPlayer,
    })
  );
  page.testChannel = attachTestChannel(page);
  return page;
}

function createUnattachedPage({
  authority = true,
  playerId = 'host-early',
  sessionData: earlySessionData,
  ready,
  timers = createBoundedFakeTimers(),
}) {
  const context = vm.createContext({
    console: { error() {}, warn() {}, info() {}, log() {} },
    TextEncoder,
    TextDecoder,
    Uint8Array,
    DataView,
    Promise,
    Date,
    crypto: webcrypto,
    setTimeout: timers.setTimeout,
    clearTimeout: timers.clearTimeout,
  });
  vm.runInContext(bridgeSource, context, {
    filename: 'gdevelop-multiplayer-bridge-early.js',
  });
  const page = {
    context,
    authority,
    playerId,
    timers,
    sessionData: earlySessionData,
  };
  const session = realmValue(page, earlySessionData);
  const currentPlayer = session.players.find(player => player.id === playerId);
  const sideEffects = { sessionSubscriptions: 0, channelTouches: 0 };
  const main = {
    ready,
    session: {
      isAuthority: () => authority,
      getCurrent: () => session,
      start: async () => session,
      finish: async () => session,
      onStateChange() {
        sideEffects.sessionSubscriptions += 1;
        return () => {};
      },
    },
    player: { getCurrent: () => currentPlayer },
    channel: {
      join() {
        sideEffects.channelTouches += 1;
      },
    },
  };
  context.playmesh = { main };
  page.main = main;
  page.registry = context[REGISTRY_SYMBOL];
  page.coordinator = context[COORDINATOR_SYMBOL];
  page.session = session;
  page.currentPlayer = currentPlayer;
  page.sideEffects = sideEffects;
  return page;
}

function attachUnattachedPage(
  page,
  currentSession = page.sessionData,
  attachRuntime = true,
  { attachChannel = true, applySnapshot = true } = {}
) {
  if (attachRuntime) page.coordinator.attachRuntime(page.main);
  const currentPlayer = currentSession
    ? currentSession.players.find(player => player.id === page.playerId) || null
    : null;
  page.coordinator.updateContext(
    realmValue(page, {
      isAuthority: page.authority,
      authorityPeerId: 'authority',
      currentSession,
      currentPlayer,
    })
  );
  if (currentSession && attachChannel) {
    page.testChannel = attachTestChannel(page);
  }
  if (currentSession && applySnapshot) {
    applyTestPlayerNumberSnapshot(page, currentSession);
  }
}

function negotiate(page, feature) {
  return page.registry.negotiate(
    realmValue(page, {
      engine: 'gdevelop',
      engineVersion: '5.6.276',
      feature,
      minVersion: 1,
      maxVersion: 1,
    })
  );
}

function createBinaryBus(pages) {
  const records = new Map();
  const channels = new Map();
  const deliveries = [];
  const packets = [];
  for (const page of pages) {
    const record = {
      listener: null,
      sendCount: 0,
      unsubscribeCount: 0,
      closeCount: 0,
    };
    records.set(page.playerId, record);
    const channel = {
      id: '00000000-0000-4000-8000-000000000001',
      send(targetPlayerId, bytes) {
        record.sendCount += 1;
        const targetPage = pages.find(candidate => candidate.playerId === targetPlayerId);
        const targetRecord = records.get(targetPlayerId);
        if (!targetPage || !targetRecord || !targetRecord.listener) {
          return Promise.reject(new Error('target has not joined channel'));
        }
        Promise.resolve().then(() => {
          const senderPlayerId = page.authority ? 'authority' : page.playerId;
          packets.push({
            sourcePlayerId: page.playerId,
            senderPlayerId,
            targetPlayerId,
            bytes: new Uint8Array(bytes),
          });
          deliveries.push({
            sourcePlayerId: page.playerId,
            senderPlayerId,
            targetPlayerId,
          });
          targetRecord.listener(
            bytes,
            realmValue(targetPage, {
              senderPlayerId,
              delivery: 'queued',
            })
          );
        });
        return Promise.resolve();
      },
      onMessage(listener) {
        assert.equal(record.listener, null, 'channel is subscribed once');
        record.listener = listener;
        return () => {
          record.unsubscribeCount += 1;
          record.listener = null;
        };
      },
      async close() {
        record.closeCount += 1;
      },
    };
    channels.set(page.playerId, channel);
    page.coordinator.attachChannel(channel);
  }
  const inject = ({ targetPlayerId, senderPlayerId, bytes, delivery = 'queued' }) => {
    const targetPage = pages.find(candidate => candidate.playerId === targetPlayerId);
    const targetRecord = records.get(targetPlayerId);
    assert.ok(targetPage && targetRecord?.listener, 'raw target is subscribed');
    targetRecord.listener(
      bytes,
      realmValue(targetPage, { senderPlayerId, delivery })
    );
  };
  return { records, channels, deliveries, packets, inject };
}

const PMGD_VERSION = 2;
const PMGD_READY_STATE = 5;
const PMGD_READY_ACK = 6;
const PMGD_READY_SNAPSHOT = 7;
const PMGD_PREPARE = 8;
const PMGD_PREPARED = 9;

function decodePmGdPacket(bytes) {
  assert.deepEqual([...bytes.subarray(0, 5)], [0x50, 0x4d, 0x47, 0x44, PMGD_VERSION]);
  return { type: bytes[5], body: bytes.subarray(6) };
}

function encodeReadyStatePacket(ready, token) {
  assert.equal(token.byteLength, 16);
  const bytes = new Uint8Array(23);
  bytes.set([0x50, 0x4d, 0x47, 0x44, PMGD_VERSION, PMGD_READY_STATE]);
  bytes[6] = ready ? 1 : 0;
  bytes.set(token, 7);
  return bytes;
}

function encodePreparedPacket(roundToken, readyToken) {
  assert.equal(roundToken.byteLength, 16);
  assert.equal(readyToken.byteLength, 16);
  const bytes = new Uint8Array(38);
  bytes.set([0x50, 0x4d, 0x47, 0x44, PMGD_VERSION, PMGD_PREPARED]);
  bytes.set(roundToken, 6);
  bytes.set(readyToken, 22);
  return bytes;
}

const earlySessionData = {
  id: 'session-early',
  state: 'lobby',
  authorityClientId: 'host-early',
  minPlayers: 1,
  maxPlayers: 8,
  players: [
    {
      id: 'host-early',
      nickname: 'Early Host',
      role: 'authority',
      connected: true,
    },
  ],
};

// Two official async entry points and both synchronous control constructors
// converge on one SDK-ready/coordinator readiness negotiation. Merely resolving
// main.ready or attaching context is insufficient: the bootstrap-owned channel
// and the current session's stable player-number snapshot must both be ready.
const earlyReady = createDeferredPromise();
let earlyReadyThenCalls = 0;
const earlyReadyThenable = {
  then(onFulfilled, onRejected) {
    earlyReadyThenCalls += 1;
    return earlyReady.promise.then(onFulfilled, onRejected);
  },
};
const earlyPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: earlyReadyThenable,
});
const earlyMultiplayer = negotiate(earlyPage, 'multiplayer');
const earlyAuthentication = negotiate(earlyPage, 'playerAuthentication');
let earlyRequestCompletions = 0;
const earlyMultiplayerRequest = earlyMultiplayer
  .request(
    'checkGameRegistration',
    realmValue(earlyPage, { gameId: 'early-project' })
  )
  .then(result => {
    earlyRequestCompletions += 1;
    return result;
  });
const earlyAuthenticationRequest = earlyAuthentication
  .checkGameRegistration(
    realmValue(earlyPage, { gameId: 'early-project' })
  )
  .then(result => {
    earlyRequestCompletions += 1;
    return result;
  });
const earlyQuickJoinRequest = earlyMultiplayer
  .request(
    'quickJoin',
    realmValue(earlyPage, {
      gameId: 'early-project',
      isPreview: true,
      gameVersion: 'test',
      supportedCompressionMethods: ['none'],
    })
  )
  .then(result => {
    earlyRequestCompletions += 1;
    return result;
  });
const earlyLobbyControl = earlyMultiplayer.createOfficialLobbyControlFacade();
const earlyAuthenticationControl =
  earlyAuthentication.createOfficialAuthenticationControlFacade();
assert.equal(earlyLobbyControl.readyState, 0);
assert.equal(earlyAuthenticationControl.readyState, 0);
const earlyLobbyEvents = [];
const earlyLobbyMessages = [];
const earlyLobbyOpen = new Promise((resolve, reject) => {
  earlyLobbyControl.onmessage = event => {
    earlyLobbyMessages.push(JSON.parse(event.data));
  };
  earlyLobbyControl.onopen = () => {
    earlyLobbyEvents.push('open');
    resolve();
  };
  earlyLobbyControl.onerror = reject;
});
const earlyAuthenticationMessages = [];
const earlyAuthenticationOpen = new Promise((resolve, reject) => {
  earlyAuthenticationControl.onmessage = event => {
    earlyAuthenticationMessages.push(JSON.parse(event.data));
  };
  earlyAuthenticationControl.onopen = () => {
    earlyAuthenticationControl.send(
      JSON.stringify({ action: 'getConnectionId' })
    );
    resolve();
  };
  earlyAuthenticationControl.onerror = reject;
});
earlyLobbyControl.send(
  JSON.stringify({ action: 'getConnectionId' })
);
await flush();
assert.equal(earlyReadyThenCalls, 1, 'concurrent callers share one ready await');
assert.equal(earlyRequestCompletions, 0);
assert.deepEqual(earlyPage.sideEffects, {
  sessionSubscriptions: 0,
  channelTouches: 0,
});

earlyReady.resolve();
await flush();
assert.equal(earlyRequestCompletions, 0);
assert.equal(earlyLobbyControl.readyState, 0);
assert.equal(
  earlyPage.sideEffects.sessionSubscriptions,
  0,
  'the bridge does not perform bootstrap attach/listener work'
);

earlyPage.coordinator.attachRuntime(earlyPage.main);
await flush();
assert.equal(
  earlyRequestCompletions,
  0,
  'attachRuntime alone does not bypass the required context negotiation'
);
attachUnattachedPage(earlyPage, earlyPage.sessionData, false, {
  attachChannel: false,
  applySnapshot: false,
});
await flush();
assert.equal(earlyRequestCompletions, 0);
assert.equal(earlyLobbyControl.readyState, 0);

const earlyChannel = attachTestChannel(earlyPage, 'early-host-channel');
await flush();
assert.equal(earlyRequestCompletions, 0);
assert.equal(earlyLobbyControl.readyState, 0);
assert.equal(earlyChannel.record.subscribeCount, 1);

applyTestPlayerNumberSnapshot(earlyPage, earlyPage.sessionData);
const [
  earlyMultiplayerRegistration,
  earlyAuthenticationRegistration,
  earlyQuickJoin,
] = await Promise.all([
  earlyMultiplayerRequest,
  earlyAuthenticationRequest,
  earlyQuickJoinRequest,
]);
await Promise.all([earlyLobbyOpen, earlyAuthenticationOpen]);
await flush();
assert.deepEqual(JSON.parse(JSON.stringify(earlyMultiplayerRegistration)), {
  registered: true,
});
assert.deepEqual(JSON.parse(JSON.stringify(earlyAuthenticationRegistration)), {
  registered: true,
});
assert.equal(earlyQuickJoin.status, 'join-lobby');
assert.equal(earlyQuickJoin.lobby.id, earlySessionData.id);
assert.equal(earlyReadyThenCalls, 1);
assert.deepEqual(earlyLobbyEvents, ['open']);
assert.equal(earlyLobbyMessages.length, 1);
assert.equal(earlyLobbyMessages[0].type, 'connectionId');
assert.equal(earlyLobbyMessages[0].data.positionInLobby, 1);
assert.equal(earlyAuthenticationMessages.length, 2);
assert.equal(earlyAuthenticationMessages[1].type, 'authenticationResult');
assert.equal(earlyLobbyControl.readyState, 1);
assert.equal(earlyAuthenticationControl.readyState, 1);
const postRequestLobbyControl =
  earlyMultiplayer.createOfficialLobbyControlFacade();
await new Promise((resolve, reject) => {
  postRequestLobbyControl.onopen = resolve;
  postRequestLobbyControl.onerror = reject;
});
assert.equal(
  earlyReadyThenCalls,
  1,
  'a control façade created after async registration reuses negotiated context'
);
assert.deepEqual(earlyPage.sideEffects, {
  sessionSubscriptions: 0,
  channelTouches: 0,
});
earlyLobbyControl.close();
earlyAuthenticationControl.close();
postRequestLobbyControl.close();
earlyPage.coordinator.dispose();

// Guest control creation follows the same readiness lease. A joined session
// without its relay channel or stable player number must keep both quickJoin
// and the buffered getConnectionId frame pending, then open exactly once.
const delayedGuestSessionData = {
  ...earlySessionData,
  id: 'session-delayed-guest',
  authorityClientId: 'host-delayed',
  players: [
    {
      id: 'host-delayed',
      nickname: 'Delayed Host',
      role: 'authority',
      connected: true,
    },
    {
      id: 'guest-delayed',
      nickname: 'Delayed Guest',
      role: 'player',
      connected: true,
    },
  ],
};
const delayedGuestPage = createUnattachedPage({
  authority: false,
  playerId: 'guest-delayed',
  sessionData: delayedGuestSessionData,
  ready: Promise.resolve(),
});
const delayedGuestMultiplayer = negotiate(delayedGuestPage, 'multiplayer');
let delayedGuestQuickJoinCompletions = 0;
const delayedGuestQuickJoin = delayedGuestMultiplayer
  .request(
    'quickJoin',
    realmValue(delayedGuestPage, {
      gameId: 'delayed-guest-project',
      isPreview: true,
      gameVersion: 'test',
      supportedCompressionMethods: ['none'],
    })
  )
  .then(result => {
    delayedGuestQuickJoinCompletions += 1;
    return result;
  });
const delayedGuestControl =
  delayedGuestMultiplayer.createOfficialLobbyControlFacade();
let delayedGuestOpenCount = 0;
const delayedGuestMessages = [];
const delayedGuestOpen = new Promise((resolve, reject) => {
  delayedGuestControl.onmessage = event => {
    delayedGuestMessages.push(JSON.parse(event.data));
  };
  delayedGuestControl.onopen = () => {
    delayedGuestOpenCount += 1;
    resolve();
  };
  delayedGuestControl.onerror = reject;
});
delayedGuestControl.send(JSON.stringify({ action: 'getConnectionId' }));
delayedGuestPage.coordinator.attachRuntime(delayedGuestPage.main);
attachUnattachedPage(
  delayedGuestPage,
  delayedGuestSessionData,
  false,
  { attachChannel: false, applySnapshot: false }
);
await flush();
assert.equal(delayedGuestQuickJoinCompletions, 0);
assert.equal(delayedGuestControl.readyState, 0);

const delayedGuestChannel = attachTestChannel(
  delayedGuestPage,
  'delayed-guest-channel'
);
await flush();
assert.equal(delayedGuestQuickJoinCompletions, 0);
assert.equal(delayedGuestControl.readyState, 0);

applyTestPlayerNumberSnapshot(delayedGuestPage, delayedGuestSessionData);
const delayedGuestQuickJoinResult = await delayedGuestQuickJoin;
await delayedGuestOpen;
await flush();
assert.equal(delayedGuestQuickJoinResult.status, 'join-lobby');
assert.equal(delayedGuestOpenCount, 1);
assert.equal(delayedGuestMessages.length, 1);
assert.equal(delayedGuestMessages[0].type, 'connectionId');
assert.equal(delayedGuestMessages[0].data.positionInLobby, 2);

delayedGuestPage.coordinator.attachChannel(delayedGuestChannel.channel);
applyTestPlayerNumberSnapshot(delayedGuestPage, delayedGuestSessionData, 2);
await flush();
assert.equal(delayedGuestOpenCount, 1);

const switchedGuestSessionData = {
  ...delayedGuestSessionData,
  id: 'session-delayed-guest-next',
};
delayedGuestPage.coordinator.updateContext(
  realmValue(delayedGuestPage, {
    isAuthority: false,
    authorityPeerId: 'authority',
    currentSession: switchedGuestSessionData,
    currentPlayer: switchedGuestSessionData.players[1],
  })
);
applyTestPlayerNumberSnapshot(delayedGuestPage, switchedGuestSessionData);
let switchedQuickJoinCompletions = 0;
const switchedQuickJoin = delayedGuestMultiplayer
  .request(
    'quickJoin',
    realmValue(delayedGuestPage, {
      gameId: 'delayed-guest-project',
      isPreview: true,
      gameVersion: 'test',
      supportedCompressionMethods: ['none'],
    })
  )
  .then(result => {
    switchedQuickJoinCompletions += 1;
    return result;
  });
await flush();
assert.equal(
  switchedQuickJoinCompletions,
  0,
  'a completed negotiation cannot lend the previous session its channel'
);
attachTestChannel(delayedGuestPage, 'delayed-guest-next-channel');
const switchedQuickJoinResult = await switchedQuickJoin;
assert.equal(switchedQuickJoinResult.lobby.id, switchedGuestSessionData.id);
assert.equal(delayedGuestChannel.record.unsubscribeCount, 1);
delayedGuestControl.close();
delayedGuestPage.coordinator.dispose();

// SDK ready rejection is normalized once and propagated through both the
// async operation and deferred socket lifecycle (error before close).
const rejectedReady = createDeferredPromise();
const rejectedReadyPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: rejectedReady.promise,
});
const rejectedReadyMultiplayer = negotiate(rejectedReadyPage, 'multiplayer');
const rejectedReadyAuthentication = negotiate(
  rejectedReadyPage,
  'playerAuthentication'
);
const rejectedReadyRequest = rejectedReadyMultiplayer.request(
  'checkGameRegistration',
  realmValue(rejectedReadyPage, { gameId: 'early-project' })
);
const rejectedReadySocket =
  rejectedReadyAuthentication.createOfficialAuthenticationControlFacade();
const rejectedSocketEvents = [];
rejectedReadySocket.onerror = error =>
  rejectedSocketEvents.push(`error:${error.code}`);
rejectedReadySocket.onclose = () => rejectedSocketEvents.push('close');
await Promise.resolve();
rejectedReady.reject(new Error('sdk initialization failed'));
await assert.rejects(
  rejectedReadyRequest,
  error => error.code === 'PLAYMESH_GDEVELOP_RUNTIME_READY_REJECTED'
);
await flush();
assert.deepEqual(rejectedSocketEvents, [
  'error:PLAYMESH_GDEVELOP_RUNTIME_READY_REJECTED',
  'close',
]);
assert.equal(rejectedReadySocket.readyState, 3);
rejectedReadyPage.coordinator.dispose();

// An unresolved SDK ready Promise is bounded by a fake timer and leaves no
// timer/listener residue after failure.
const timedOutReady = createDeferredPromise();
const readyTimeoutTimers = createBoundedFakeTimers();
const readyTimeoutPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: timedOutReady.promise,
  timers: readyTimeoutTimers,
});
const readyTimeoutRequest = negotiate(readyTimeoutPage, 'multiplayer').request(
  'checkGameRegistration',
  realmValue(readyTimeoutPage, { gameId: 'early-project' })
);
await flush();
assert.deepEqual(readyTimeoutTimers.delays, [15000]);
readyTimeoutTimers.runNextDelay(15000);
await assert.rejects(
  readyTimeoutRequest,
  error => error.code === 'PLAYMESH_GDEVELOP_RUNTIME_READY_TIMEOUT'
);
assert.equal(readyTimeoutTimers.pendingCount, 0);
readyTimeoutPage.coordinator.dispose();

// Ready alone never creates an inactive multiplayer runtime. If bootstrap
// deliberately does not attach, the bounded attach wait fails without channel
// or session-listener side effects.
const attachTimeoutTimers = createBoundedFakeTimers();
const attachTimeoutPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: Promise.resolve(),
  timers: attachTimeoutTimers,
});
const attachTimeoutRequest = negotiate(
  attachTimeoutPage,
  'playerAuthentication'
).checkGameRegistration(
  realmValue(attachTimeoutPage, { gameId: 'early-project' })
);
await flush();
assert.deepEqual(attachTimeoutTimers.delays, [15000]);
attachTimeoutTimers.runNextDelay(15000);
await assert.rejects(
  attachTimeoutRequest,
  error => error.code === 'PLAYMESH_GDEVELOP_COORDINATOR_ATTACH_TIMEOUT'
);
assert.deepEqual(attachTimeoutPage.sideEffects, {
  sessionSubscriptions: 0,
  channelTouches: 0,
});
assert.equal(attachTimeoutTimers.pendingCount, 0);
attachTimeoutPage.coordinator.dispose();

// A completed attach with an explicit null context reports NO_SESSION instead
// of waiting until the attach timeout or falling through to a cloud backend.
const noSessionPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: Promise.resolve(),
});
const noSessionRequest = negotiate(noSessionPage, 'multiplayer').request(
  'checkGameRegistration',
  realmValue(noSessionPage, { gameId: 'early-project' })
);
await flush();
noSessionPage.coordinator.attachRuntime(noSessionPage.main);
noSessionPage.coordinator.updateContext(
  realmValue(noSessionPage, {
    isAuthority: true,
    authorityPeerId: 'authority',
    currentSession: null,
    currentPlayer: null,
  })
);
await assert.rejects(
  noSessionRequest,
  error => error.code === 'PLAYMESH_GDEVELOP_NO_SESSION'
);
noSessionPage.coordinator.dispose();

// Deferred sends are bounded. Disposing an in-flight negotiation rejects the
// request, closes the socket and clears every fake timer deterministically.
const disposedReady = createDeferredPromise();
const disposedTimers = createBoundedFakeTimers();
const disposedPage = createUnattachedPage({
  sessionData: earlySessionData,
  ready: disposedReady.promise,
  timers: disposedTimers,
});
const disposedMultiplayer = negotiate(disposedPage, 'multiplayer');
const disposedAuthentication = negotiate(disposedPage, 'playerAuthentication');
const disposedRequest = disposedMultiplayer.request(
  'checkGameRegistration',
  realmValue(disposedPage, { gameId: 'early-project' })
);
const disposedSocket =
  disposedAuthentication.createOfficialAuthenticationControlFacade();
for (let index = 0; index < 16; index += 1) {
  disposedSocket.send(JSON.stringify({ action: 'getConnectionId' }));
}
assert.throws(
  () => disposedSocket.send(JSON.stringify({ action: 'getConnectionId' })),
  error => error.code === 'PLAYMESH_GDEVELOP_DEFERRED_QUEUE_FULL'
);
const disposedSocketEvents = [];
disposedSocket.onerror = error => disposedSocketEvents.push(`error:${error.code}`);
disposedSocket.onclose = () => disposedSocketEvents.push('close');
await flush();
assert.equal(disposedTimers.pendingCount, 1);
disposedPage.coordinator.dispose();
await assert.rejects(
  disposedRequest,
  error => error.code === 'PLAYMESH_GDEVELOP_NEGOTIATION_DISPOSED'
);
await flush();
assert.deepEqual(disposedSocketEvents, [
  'error:PLAYMESH_GDEVELOP_NEGOTIATION_DISPOSED',
  'close',
]);
assert.equal(disposedSocket.readyState, 3);
assert.equal(disposedTimers.pendingCount, 0);

const sessionData = {
  id: 'session-fixture',
  state: 'running',
  authorityClientId: 'host-1',
  minPlayers: 1,
  maxPlayers: 8,
  players: [
    {
      id: 'host-1',
      nickname: 'Host',
      role: 'authority',
      connected: true,
    },
    {
      id: 'guest-1',
      nickname: 'Guest',
      role: 'player',
      connected: true,
    },
  ],
};

const host = createPage({
  authority: true,
  playerId: 'host-1',
  sessionData,
});
const guest = createPage({
  authority: false,
  playerId: 'guest-1',
  sessionData,
});
const pages = [host, guest];
const bus = createBinaryBus(pages);

for (const page of pages) {
  assert.equal(
    page.context.playmeshGDevelopMultiplayerBridge,
    undefined,
    'the obsolete public monkey-patch bridge is absent'
  );
  assert.equal(Object.isFrozen(page.registry), true);
  assert.equal(Object.isFrozen(page.coordinator), true);
  assert.equal(
    Object.getOwnPropertyDescriptor(page.context, REGISTRY_SYMBOL).enumerable,
    false
  );
  assert.equal(
    Object.getOwnPropertyDescriptor(page.context, COORDINATOR_SYMBOL).enumerable,
    false
  );

  const multiplayer = negotiate(page, 'multiplayer');
  const authentication = negotiate(page, 'playerAuthentication');
  assert.deepEqual(Object.keys(multiplayer).sort(), [
    'configureOfficialLobbyFrame',
    'consumeOfficialLobbyFrameMessage',
    'createOfficialLobbyControlFacade',
    'createOfficialPeer',
    'handleOfficialLobbyFrameMessage',
    'notifyOfficialLobbyFrameClosed',
    'postOfficialLobbyFrameMessage',
    'request',
  ]);
  assert.deepEqual(Object.keys(authentication).sort(), [
    'checkGameRegistration',
    'configureOfficialAuthenticationFrame',
    'consumeOfficialAuthenticationFrameMessage',
    'createOfficialAuthenticationControlFacade',
    'readOfficialIdentity',
    'removeOfficialIdentity',
    'writeOfficialIdentity',
  ]);
  for (const facade of [multiplayer, authentication]) {
    assert.equal(Object.isFrozen(facade), true);
    assert.equal('channel' in facade, false);
    assert.equal('socket' in facade, false);
    assert.equal('authority' in facade, false);
    assert.equal('main' in facade, false);
  }

  assert.throws(
    () =>
      page.registry.negotiate(
        realmValue(page, {
          engine: 'gdevelop',
          engineVersion: '5.6.276',
          feature: 'multiplayer',
          minVersion: 1,
          maxVersion: 1,
          credential: 'forbidden',
        })
      ),
    error => error.code === 'PLAYMESH_GDEVELOP_BACKEND_INCOMPATIBLE'
  );
}

const snapshot = {
  type: 'playerNumbers.snapshot',
  protocol: PROTOCOL,
  version: 1,
  sessionId: sessionData.id,
  epoch: 1,
  revision: 1,
  assignments: [
    { playerId: 'host-1', playerNumber: 1 },
    { playerId: 'guest-1', playerNumber: 2 },
  ],
  errorCode: null,
};
for (const page of pages) {
  page.coordinator.applyPlayerNumberSnapshot(realmValue(page, snapshot));
}

const hostBackend = negotiate(host, 'multiplayer');
const guestBackend = negotiate(guest, 'multiplayer');
const quickJoinPayload = {
  gameId: 'official-project-uuid',
  isPreview: true,
  gameVersion: 'test',
  supportedCompressionMethods: ['none'],
};
const [hostQuickJoin, guestQuickJoin] = await Promise.all([
  hostBackend.request('quickJoin', realmValue(host, quickJoinPayload)),
  guestBackend.request('quickJoin', realmValue(guest, quickJoinPayload)),
]);
assert.equal(hostQuickJoin.status, 'join-game');
assert.equal(guestQuickJoin.status, 'join-game');
assert.equal(hostQuickJoin.lobby.id, sessionData.id);
assert.equal(guestQuickJoin.lobby.id, sessionData.id);
assert.deepEqual(
  JSON.parse(JSON.stringify(hostQuickJoin.lobby)),
  JSON.parse(JSON.stringify(guestQuickJoin.lobby)),
  'host and guest expose the same Playmesh session as one GDevelop lobby'
);
const underfilledSessionData = {
  ...sessionData,
  id: 'underfilled-shared-lobby',
  state: 'lobby',
  minPlayers: 2,
  players: [sessionData.players[0]],
};
const underfilledHost = createPage({
  authority: true,
  playerId: 'host-1',
  sessionData: underfilledSessionData,
});
underfilledHost.coordinator.applyPlayerNumberSnapshot(
  realmValue(underfilledHost, {
    ...snapshot,
    sessionId: underfilledSessionData.id,
    assignments: [{ playerId: 'host-1', playerNumber: 1 }],
  })
);
const underfilledQuickJoin = await negotiate(
  underfilledHost,
  'multiplayer'
).request('quickJoin', realmValue(underfilledHost, quickJoinPayload));
assert.equal(underfilledQuickJoin.status, 'join-lobby');
assert.equal(underfilledQuickJoin.lobby.id, underfilledSessionData.id);
underfilledHost.coordinator.dispose();
const hostPeer = hostBackend.createOfficialPeer();
const guestPeer = guestBackend.createOfficialPeer();
await Promise.all([once(hostPeer, 'open'), once(guestPeer, 'open')]);
assert.equal(hostPeer.id, 'authority');
assert.equal(guestPeer.id, 'guest-1');
assert.throws(
  () => hostBackend.createOfficialPeer({ host: 'forbidden.example' }),
  error => error.code === 'PLAYMESH_GDEVELOP_FORBIDDEN_ARGUMENT'
);

const incomingConnection = new Promise(resolve => {
  hostPeer.on('connection', connection => {
    resolve({ connection, opened: once(connection, 'open') });
  });
});
const guestConnection = guestPeer.connect('authority');
assert.equal(guestConnection.peerConnection.connectionState, 'connecting');
const guestOpened = once(guestConnection, 'open');
const { connection: hostConnection, opened: hostOpened } = await incomingConnection;
await Promise.all([guestOpened, hostOpened]);
assert.equal(guestConnection.peer, 'authority');
assert.equal(hostConnection.peer, 'guest-1');
assert.equal(guestConnection.peerConnection.connectionState, 'connected');
assert.equal(hostConnection.peerConnection.connectionState, 'connected');
assert.deepEqual(Object.keys(hostConnection.peerConnection), ['connectionState']);
assert.equal(Object.getPrototypeOf(hostConnection.peerConnection), null);
assert.equal(Object.isFrozen(hostConnection.peerConnection), true);
assert.equal(
  Object.getOwnPropertyDescriptor(hostConnection, 'peerConnection').writable,
  false
);
assert.throws(
  () => {
    hostConnection.peerConnection = { connectionState: 'failed' };
  },
  TypeError
);
assert.throws(
  () => {
    hostConnection.peerConnection.connectionState = 'failed';
  },
  TypeError
);
assert.throws(
  () => guestPeer.connect('guest-1'),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_TOPOLOGY'
);

const firstMessage = once(hostConnection, 'data');
guestConnection.send(
  realmValue(guest, { messageName: '#move', data: '{"dx":2}' })
);
assert.deepEqual(JSON.parse(JSON.stringify(await firstMessage)), {
  messageName: '#move',
  data: '{"dx":2}',
});

// Game SDK/go-core intentionally exposes an incoming Authority sender as the
// public alias "authority". The runtime seam must resolve that alias back to
// session.authorityClientId before topology validation, then preserve the
// official alias on the GDevelop-facing connection.
const authorityAliasMessage = once(guestConnection, 'data');
hostConnection.send(
  realmValue(host, { messageName: '#authority-alias', data: 'resolved' })
);
assert.deepEqual(JSON.parse(JSON.stringify(await authorityAliasMessage)), {
  messageName: '#authority-alias',
  data: 'resolved',
});
assert.deepEqual(bus.deliveries.at(-1), {
  sourcePlayerId: 'host-1',
  senderPlayerId: 'authority',
  targetPlayerId: 'guest-1',
});
assert.equal(guestConnection.peer, 'authority');

const channelBeforeLeave = bus.channels.get('guest-1');
const officialDisconnectTimers = createFakeTimers();
const officiallyDisconnectedPeers = [];
startOfficialDisconnectChecker(
  guestConnection,
  peerId => officiallyDisconnectedPeers.push(peerId),
  (callback, delay) => officialDisconnectTimers.schedule(callback, delay)
);
assert.equal(officialDisconnectTimers.pendingCount, 1);
guestConnection.close();
assert.equal(guestConnection.peerConnection.connectionState, 'closed');
officialDisconnectTimers.runNext();
assert.deepEqual(officiallyDisconnectedPeers, ['authority']);
assert.equal(
  officialDisconnectTimers.pendingCount,
  0,
  'closed 状态让官方检查器停止继续排定定时器'
);
await flush();
assert.equal(bus.records.get('guest-1').closeCount, 0);
assert.equal(bus.records.get('guest-1').unsubscribeCount, 0);
assert.throws(
  () =>
    guestConnection.send(
      realmValue(guest, { messageName: '#while-left', data: 'ignored' })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_CONNECTION_CLOSED'
);

const warmIncoming = new Promise(resolve => {
  hostPeer.on('connection', connection => {
    resolve({ connection, opened: once(connection, 'open') });
  });
});
const warmGuestConnection = guestPeer.connect('authority');
const warmGuestOpened = once(warmGuestConnection, 'open');
const { connection: warmHostConnection, opened: warmHostOpened } =
  await warmIncoming;
await Promise.all([warmGuestOpened, warmHostOpened]);
assert.equal(bus.channels.get('guest-1'), channelBeforeLeave);
const warmMessage = once(warmHostConnection, 'data');
warmGuestConnection.send(
  realmValue(guest, { messageName: '#warm', data: 'reused-channel' })
);
assert.equal((await warmMessage).data, 'reused-channel');

for (const page of pages) {
  const backend = negotiate(page, 'multiplayer');
  assert.deepEqual(
    JSON.parse(
      JSON.stringify(
        await backend.request(
          'checkGameRegistration',
          realmValue(page, { gameId: 'official-project-uuid' })
        )
      )
    ),
    { registered: true }
  );
  const lobby = await backend.request(
    'getLobbyById',
    realmValue(page, {
      gameId: 'official-project-uuid',
      lobbyId: sessionData.id,
    })
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(lobby.players)),
    [
      { playerId: 'host-1', status: 'playing', playerNumber: 1 },
      { playerId: 'guest-1', status: 'playing', playerNumber: 2 },
    ],
    'Authority snapshots provide stable official GDevelop player numbers'
  );
  assert.deepEqual(
    JSON.parse(
      JSON.stringify(
        await backend.request(
          'heartbeat',
          realmValue(page, {
            gameId: 'official-project-uuid',
            lobbyId: sessionData.id,
            players: [
              { playerNumber: 1, playerId: 'host-1' },
              { playerNumber: 2, playerId: 'guest-1' },
            ],
          })
        )
      )
    ),
    {}
  );
  await assert.rejects(
    backend.request(
      'getHostMigration',
      realmValue(page, {
        gameId: 'official-project-uuid',
        lobbyId: sessionData.id,
      })
    ),
    error => error.code === 'PLAYMESH_GDEVELOP_UNKNOWN_OPERATION'
  );
  await assert.rejects(
    backend.request(
      'migrateHost',
      realmValue(page, {
        gameId: 'official-project-uuid',
        lobbyId: sessionData.id,
        mode: 'read',
        peerId: '',
      })
    ),
    error => error.code === 'PLAYMESH_GDEVELOP_FIXED_AUTHORITY'
  );
}

const invalidHeartbeatPlayers = [
  [{ playerNumber: 1, playerId: 'host-1', ping: 0 }],
  [{ playerNumber: '1', playerId: 'host-1' }],
  [{ playerNumber: 0, playerId: 'host-1' }],
  [{ playerNumber: 9, playerId: 'host-1' }],
  [{ playerNumber: 1.5, playerId: 'host-1' }],
  [{ playerNumber: 1, playerId: '' }],
  [{ playerNumber: 1, playerId: 'x'.repeat(129) }],
  [
    { playerNumber: 1, playerId: 'host-1' },
    { playerNumber: 2, playerId: 'host-1' },
  ],
  [
    { playerNumber: 1, playerId: 'host-1' },
    { playerNumber: 1, playerId: 'guest-1' },
  ],
  Array.from({ length: 9 }, (_, index) => ({
    playerNumber: (index % 8) + 1,
    playerId: `player-${index}`,
  })),
];
for (const players of invalidHeartbeatPlayers) {
  await assert.rejects(
    guestBackend.request(
      'heartbeat',
      realmValue(guest, {
        gameId: 'official-project-uuid',
        lobbyId: sessionData.id,
        players,
      })
    ),
    error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
  );
}

guest.context.__heartbeatGetterCalls = 0;
const heartbeatWithGetter = vm.runInContext(
  `({
    gameId: 'official-project-uuid',
    lobbyId: 'session-fixture',
    players: [{
      playerNumber: 2,
      get playerId() {
        __heartbeatGetterCalls += 1;
        return 'guest-1';
      },
    }],
  })`,
  guest.context
);
await assert.rejects(
  guestBackend.request('heartbeat', heartbeatWithGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);
assert.equal(guest.context.__heartbeatGetterCalls, 0);

guest.context.__heartbeatArrayGetterCalls = 0;
const heartbeatWithArrayGetter = vm.runInContext(
  `(() => {
    const players = [];
    Object.defineProperty(players, '0', {
      enumerable: true,
      get() {
        __heartbeatArrayGetterCalls += 1;
        return { playerNumber: 2, playerId: 'guest-1' };
      },
    });
    players.length = 1;
    return {
      gameId: 'official-project-uuid',
      lobbyId: 'session-fixture',
      players,
    };
  })()`,
  guest.context
);
await assert.rejects(
  guestBackend.request('heartbeat', heartbeatWithArrayGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);
assert.equal(guest.context.__heartbeatArrayGetterCalls, 0);

guest.context.__heartbeatToStringCalls = 0;
const heartbeatWithToString = vm.runInContext(
  `({
    gameId: 'official-project-uuid',
    lobbyId: 'session-fixture',
    players: [{
      playerNumber: 2,
      playerId: {
        toString() {
          __heartbeatToStringCalls += 1;
          return 'guest-1';
        },
      },
    }],
  })`,
  guest.context
);
await assert.rejects(
  guestBackend.request('heartbeat', heartbeatWithToString),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);
assert.equal(guest.context.__heartbeatToStringCalls, 0);

const heartbeatWithNonFiniteNumber = vm.runInContext(
  `({
    gameId: 'official-project-uuid',
    lobbyId: 'session-fixture',
    players: [{ playerNumber: Infinity, playerId: 'guest-1' }],
  })`,
  guest.context
);
await assert.rejects(
  guestBackend.request('heartbeat', heartbeatWithNonFiniteNumber),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);

const heartbeatWithPollution = vm.runInContext(
  `(() => {
    const player = { playerNumber: 2, playerId: 'guest-1' };
    Object.defineProperty(player, '__proto__', {
      value: { polluted: true },
      enumerable: true,
    });
    return {
      gameId: 'official-project-uuid',
      lobbyId: 'session-fixture',
      players: [player],
    };
  })()`,
  guest.context
);
await assert.rejects(
  guestBackend.request('heartbeat', heartbeatWithPollution),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);

guest.context.__migrationGetterCalls = 0;
const migrationWithGetter = vm.runInContext(
  `({
    gameId: 'official-project-uuid',
    lobbyId: 'session-fixture',
    mode: 'write',
    peerId: 'guest-1',
    playersInfo: [{
      playerNumber: 2,
      get playerId() {
        __migrationGetterCalls += 1;
        return 'guest-1';
      },
      ping: 20,
    }],
  })`,
  guest.context
);
await assert.rejects(
  guestBackend.request('migrateHost', migrationWithGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);
assert.equal(guest.context.__migrationGetterCalls, 0);
assert.equal({}.polluted, undefined);

await assert.rejects(
  guestBackend.request(
    'migrateHost',
    realmValue(guest, {
      gameId: 'official-project-uuid',
      lobbyId: sessionData.id,
      mode: 'write',
      peerId: 'guest-1',
      playersInfo: [
        { playerNumber: 1, playerId: 'host-1', ping: 10 },
        { playerNumber: 2, playerId: 'guest-1', ping: 20 },
      ],
    })
  ),
  error => error.code === 'PLAYMESH_GDEVELOP_FIXED_AUTHORITY'
);
await assert.rejects(
  guestBackend.request(
    'migrateHost',
    realmValue(guest, {
      gameId: 'official-project-uuid',
      lobbyId: sessionData.id,
      mode: 'write',
      peerId: 'guest-1',
      playersInfo: [
        { playerNumber: 1, playerId: 'host-1', ping: 10 },
        { playerNumber: 2, playerId: 'host-1', ping: 20 },
      ],
    })
  ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_REQUEST'
);

const lobbyControl = hostBackend.createOfficialLobbyControlFacade();
await new Promise(resolve => {
  lobbyControl.onopen = resolve;
});
lobbyControl.send(
  realmValue(host, {
    action: 'sessionInformation',
    connectionType: 'lobby',
    isCordova: false,
    devicePlatform: '',
    navigatorPlatform: 'Win32',
    hasTouch: false,
    supportedCompressionMethods: ['none'],
  })
);

host.context.__sessionInformationGetterCalls = 0;
const sessionInformationWithGetter = vm.runInContext(
  `({
    action: 'sessionInformation',
    connectionType: 'lobby',
    isCordova: false,
    devicePlatform: '',
    get navigatorPlatform() {
      __sessionInformationGetterCalls += 1;
      return 'Win32';
    },
    hasTouch: false,
    supportedCompressionMethods: ['none'],
  })`,
  host.context
);
assert.throws(
  () => lobbyControl.send(sessionInformationWithGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_FRAME'
);
assert.equal(host.context.__sessionInformationGetterCalls, 0);

host.context.__sessionInformationToStringCalls = 0;
const sessionInformationWithToString = vm.runInContext(
  `({
    action: 'sessionInformation',
    connectionType: 'lobby',
    isCordova: false,
    devicePlatform: {
      toString() {
        __sessionInformationToStringCalls += 1;
        return 'Android';
      },
    },
    navigatorPlatform: 'Win32',
    hasTouch: true,
    supportedCompressionMethods: ['none'],
  })`,
  host.context
);
assert.throws(
  () => lobbyControl.send(sessionInformationWithToString),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_FRAME'
);
assert.equal(host.context.__sessionInformationToStringCalls, 0);

host.context.__sessionInformationArrayGetterCalls = 0;
const sessionInformationWithArrayGetter = vm.runInContext(
  `(() => {
    const supportedCompressionMethods = [];
    Object.defineProperty(supportedCompressionMethods, '0', {
      enumerable: true,
      get() {
        __sessionInformationArrayGetterCalls += 1;
        return 'none';
      },
    });
    supportedCompressionMethods.length = 1;
    return {
      action: 'sessionInformation',
      connectionType: 'lobby',
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'Win32',
      hasTouch: false,
      supportedCompressionMethods,
    };
  })()`,
  host.context
);
assert.throws(
  () => lobbyControl.send(sessionInformationWithArrayGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_FRAME'
);
assert.equal(host.context.__sessionInformationArrayGetterCalls, 0);

const pollutedSessionInformation = vm.runInContext(
  `(() => {
    const frame = {
      action: 'sessionInformation',
      connectionType: 'lobby',
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'Win32',
      hasTouch: false,
      supportedCompressionMethods: ['none'],
    };
    Object.defineProperty(frame, '__proto__', {
      value: { polluted: true },
      enumerable: true,
    });
    return frame;
  })()`,
  host.context
);
assert.throws(
  () => lobbyControl.send(pollutedSessionInformation),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_FRAME'
);

for (const invalidSessionInformation of [
  {
    action: 'sessionInformation',
    connectionType: 'lobby',
    isCordova: false,
    devicePlatform: null,
    navigatorPlatform: 'Win32',
    hasTouch: false,
    supportedCompressionMethods: ['none'],
  },
  {
    action: 'sessionInformation',
    connectionType: 'lobby',
    isCordova: false,
    devicePlatform: '',
    navigatorPlatform: 'Win32',
    hasTouch: false,
    supportedCompressionMethods: ['none'],
    extra: true,
  },
]) {
  assert.throws(
    () => lobbyControl.send(realmValue(host, invalidSessionInformation)),
    error => error.code === 'PLAYMESH_GDEVELOP_INVALID_FRAME'
  );
}
lobbyControl.close();

const guestAuthentication = negotiate(guest, 'playerAuthentication');
const identityKey = 'official-project-uuid_authenticatedUser';
const identity = JSON.parse(guestAuthentication.readOfficialIdentity(identityKey));
assert.equal(identity.userId, 'guest-1');
assert.equal(identity.username, 'Guest');
assert.match(identity.userToken, /^pm-gd-v1-[0-9a-f]{8}$/);
assert.throws(
  () => guestAuthentication.readOfficialIdentity('other-project_authenticatedUser'),
  error => error.code === 'PLAYMESH_GDEVELOP_SCOPE_MISMATCH'
);
guestAuthentication.writeOfficialIdentity(
  identityKey,
  JSON.stringify({ ...identity, username: null })
);
assert.deepEqual(
  JSON.parse(guestAuthentication.readOfficialIdentity(identityKey)),
  { ...identity, username: null }
);
const authenticationControl =
  guestAuthentication.createOfficialAuthenticationControlFacade();
const authenticationMessages = [];
authenticationControl.onmessage = event => {
  authenticationMessages.push(JSON.parse(event.data));
};
await new Promise(resolve => {
  authenticationControl.onopen = resolve;
});
authenticationControl.send(JSON.stringify({ action: 'getConnectionId' }));
await flush();
assert.equal(authenticationMessages.length, 2);
assert.equal(authenticationMessages[1].type, 'authenticationResult');
assert.equal(authenticationMessages[1].data.username, null);
authenticationControl.close();
guestAuthentication.writeOfficialIdentity(
  identityKey,
  realmValue(guest, { ...identity, username: 'x'.repeat(128) })
);
assert.equal(
  JSON.parse(guestAuthentication.readOfficialIdentity(identityKey)).username,
  'x'.repeat(128)
);
assert.throws(
  () =>
    guestAuthentication.writeOfficialIdentity(
      identityKey,
      realmValue(guest, { ...identity, username: 'x'.repeat(129) })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_IDENTITY'
);
assert.throws(
  () =>
    guestAuthentication.writeOfficialIdentity(
      identityKey,
      realmValue(guest, { ...identity, username: false })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_IDENTITY'
);
assert.throws(
  () =>
    guestAuthentication.writeOfficialIdentity(
      identityKey,
      realmValue(guest, { ...identity, username: 'Guest', extra: true })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_IDENTITY'
);
guest.context.__identityGetterCalls = 0;
const identityWithGetter = vm.runInContext(
  `({
    get username() {
      __identityGetterCalls += 1;
      return 'Guest';
    },
    userId: 'guest-1',
    userToken: '${identity.userToken}',
  })`,
  guest.context
);
assert.throws(
  () =>
    guestAuthentication.writeOfficialIdentity(identityKey, identityWithGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_IDENTITY'
);
assert.equal(guest.context.__identityGetterCalls, 0);
guestAuthentication.removeOfficialIdentity(identityKey);
assert.equal(guestAuthentication.readOfficialIdentity(identityKey), null);

// The official lobby is an opaque-origin iframe, so a focused Escape key does
// not bubble to the parent App SDK. It may request exactly the existing host
// menu/back semantic through the already authenticated local-frame channel.
const menuBridgePage = createPage({
  authority: false,
  playerId: 'guest-1',
  sessionData,
});
const menuBridgeBackend = negotiate(menuBridgePage, 'multiplayer');
let hostMenuToggleCalls = 0;
menuBridgePage.context[Symbol.for('playmesh.app.internal.v1')] = Object.freeze({
  handleNativeBack() {
    hostMenuToggleCalls += 1;
    return true;
  },
});
const menuBridgeFrame = createFrameFixture();
menuBridgeBackend.configureOfficialLobbyFrame(menuBridgeFrame.frame);
const menuBridgeDocument = runConfiguredFrameDocument(menuBridgeFrame.frame);
const menuBridgeNonce = readFrameCapability(menuBridgeFrame.frame);
assert.deepEqual(
  JSON.parse(
    JSON.stringify(
      menuBridgeBackend.consumeOfficialLobbyFrameMessage(
        localFrameEvent(menuBridgePage, menuBridgeFrame, {
          kind: 'lobby',
          nonce: menuBridgeNonce,
          sequence: 1,
          action: 'ready',
        })
      )
    )
  ),
  { data: { id: 'lobbiesListenerReady' } }
);

menuBridgeDocument.dispatchKeydown({ repeat: true });
menuBridgeDocument.dispatchKeydown({ isComposing: true });
menuBridgeDocument.dispatchKeydown({ key: 'Enter' });
assert.equal(menuBridgeDocument.outbound.length, 1);

const escapeCalls = menuBridgeDocument.dispatchKeydown();
assert.deepEqual(escapeCalls, {
  preventDefault: 1,
  stopPropagation: 1,
  stopImmediatePropagation: 1,
});
assert.equal(menuBridgeDocument.outbound.length, 2);
assert.equal(menuBridgeDocument.outbound[1].message.action, 'hostMenuToggle');
assert.equal(menuBridgeDocument.outbound[1].message.sequence, 2);
const trustedMenuEvent = localFrameEvent(menuBridgePage, menuBridgeFrame, {
  kind: 'lobby',
  nonce: menuBridgeNonce,
  sequence: 2,
  action: 'hostMenuToggle',
});
assert.equal(
  menuBridgeBackend.consumeOfficialLobbyFrameMessage(trustedMenuEvent),
  null,
  'host menu requests are consumed privately and never reach official GDevelop'
);
assert.equal(hostMenuToggleCalls, 1);
assert.equal(
  menuBridgeBackend.consumeOfficialLobbyFrameMessage(trustedMenuEvent),
  null
);
assert.equal(hostMenuToggleCalls, 1, 'replayed Escape is rejected');
assert.equal(
  menuBridgeBackend.consumeOfficialLobbyFrameMessage({
    ...localFrameEvent(menuBridgePage, menuBridgeFrame, {
      kind: 'lobby',
      nonce: menuBridgeNonce,
      sequence: 4,
      action: 'hostMenuToggle',
    }),
    source: {},
  }),
  null
);
assert.equal(hostMenuToggleCalls, 1, 'a page-forged WindowProxy is rejected');

menuBridgeDocument.dispatchKeydown();
assert.equal(menuBridgeDocument.outbound.at(-1).message.sequence, 3);
assert.equal(
  menuBridgeBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(menuBridgePage, menuBridgeFrame, {
      kind: 'lobby',
      nonce: menuBridgeNonce,
      sequence: 3,
      action: 'hostMenuToggle',
    })
  ),
  null
);
assert.equal(
  hostMenuToggleCalls,
  2,
  'the same trusted semantic toggles an already-open host menu closed'
);

// The local lobby page uses an opaque-origin srcdoc, but origin is never an
// authorization signal. A per-frame capability, exact WindowProxy and strict
// sequence/state validation guard both directions.
const guestLobbyFrame = createFrameFixture();
guestBackend.configureOfficialLobbyFrame(guestLobbyFrame.frame);
const guestLobbyNonce = readFrameCapability(guestLobbyFrame.frame);
const guestLobbyDocument = runConfiguredFrameDocument(guestLobbyFrame.frame);
assert.equal(guestLobbyFrame.attributes.has('src'), false);
assert.equal(guestLobbyFrame.attributes.get('sandbox'), 'allow-scripts');
assert.equal(
  guestLobbyFrame.attributes.get('referrerpolicy'),
  'no-referrer'
);
assert.match(guestLobbyFrame.frame.srcdoc, /Playmesh Lobby/);
assert.match(guestLobbyFrame.frame.srcdoc, /joinCurrentSession/);
assert.match(
  guestLobbyFrame.frame.srcdoc,
  /begin\('startGameCountdown'\)/,
  'the host start button follows the official countdown preparation action'
);
assert.doesNotMatch(guestLobbyFrame.frame.srcdoc, /https?:\/\//);
assert.doesNotMatch(guestLobbyFrame.frame.srcdoc, new RegExp(identity.userToken));
assert.equal(guestLobbyDocument.outbound.length, 1);
assert.equal(guestLobbyDocument.outbound[0].targetOrigin, '*');
assert.deepEqual(
  JSON.parse(JSON.stringify(guestLobbyDocument.outbound[0].message)),
  {
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind: 'lobby',
    nonce: guestLobbyNonce,
    sequence: 1,
    action: 'ready',
    payload: {},
  }
);

const readyResult = guestBackend.consumeOfficialLobbyFrameMessage(
  {
    source: guestLobbyFrame.contentWindow,
    origin: 'null',
    data: realmValue(
      guest,
      JSON.parse(JSON.stringify(guestLobbyDocument.outbound[0].message))
    ),
  }
);
assert.deepEqual(JSON.parse(JSON.stringify(readyResult)), {
  data: { id: 'lobbiesListenerReady' },
});
assert.equal(
  guestBackend.postOfficialLobbyFrameMessage(
    guestLobbyFrame.frame,
    realmValue(guest, {
      id: 'sessionInformation',
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'Win32',
      hasTouch: false,
    })
  ),
  true
);
assert.equal(guestLobbyFrame.posted.length, 1);
assert.equal(guestLobbyFrame.posted[0].targetOrigin, '*');
assert.deepEqual(
  JSON.parse(JSON.stringify(guestLobbyFrame.posted[0].message)),
  {
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind: 'lobby',
    nonce: guestLobbyNonce,
    sequence: 1,
    event: 'sessionInformation',
    payload: {
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'Win32',
      hasTouch: false,
      role: 'guest',
      sessionId: sessionData.id,
      sessionState: 'running',
      positionInLobby: 2,
      connectedPlayers: 2,
      minPlayers: 1,
      maxPlayers: 8,
      players: [
        {
          number: 1,
          nickname: 'Host',
          connected: true,
          isCurrent: false,
          isAuthority: true,
          readiness: 'ready',
          avatarDataUrl: null,
        },
        {
          number: 2,
          nickname: 'Guest',
          connected: true,
          isCurrent: true,
          isAuthority: false,
          readiness: 'notReady',
          avatarDataUrl: null,
        },
      ],
      soloAvailable: true,
      soloUnavailableReason: null,
    },
  }
);
guestLobbyDocument.dispatchFromParent(
  guestLobbyFrame.posted[0].message,
  {}
);
assert.equal(
  guestLobbyDocument.elements.get('join').hidden,
  true,
  'the child frame rejects a sibling parent-message source'
);
guestLobbyDocument.dispatchFromParent({
  ...JSON.parse(JSON.stringify(guestLobbyFrame.posted[0].message)),
  nonce: 'f'.repeat(64),
});
assert.equal(
  guestLobbyDocument.elements.get('join').hidden,
  true,
  'the child frame rejects a wrong parent capability'
);
guestLobbyDocument.dispatchFromParent(guestLobbyFrame.posted[0].message);
assert.equal(guestLobbyDocument.outbound.at(-1).message.sequence, 2);
assert.equal(
  guestLobbyDocument.outbound.at(-1).message.action,
  'joinCurrentSession',
  'sessionInformation automatically joins the one shared Playmesh lobby'
);
assert.equal(guestLobbyDocument.elements.get('join').hidden, true);

const wrongNonce = guestBackend.consumeOfficialLobbyFrameMessage(
  localFrameEvent(guest, guestLobbyFrame, {
    kind: 'lobby',
    nonce: '0'.repeat(64),
    sequence: 2,
    action: 'joinCurrentSession',
  })
);
assert.equal(wrongNonce, null);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 3,
      action: 'joinCurrentSession',
    })
  ),
  null,
  'out-of-order frame messages fail closed without consuming a sequence'
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: guestLobbyFrame.contentWindow,
    origin: 'null',
    data: realmValue(guest, {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 2,
      action: 'joinCurrentSession',
      payload: {},
      extra: true,
    }),
  }),
  null
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 2,
      action: 'joinCurrentSession',
      payload: { extra: true },
    })
  ),
  null
);

let eventDataGetterCalls = 0;
const eventWithDataGetter = { source: guestLobbyFrame.contentWindow };
Object.defineProperty(eventWithDataGetter, 'data', {
  enumerable: true,
  get() {
    eventDataGetterCalls += 1;
    return {};
  },
});
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(eventWithDataGetter),
  null
);
assert.equal(eventDataGetterCalls, 0);

guest.context.__localFrameNonce = guestLobbyNonce;
guest.context.__localFrameGetterCalls = 0;
const frameEnvelopeWithGetter = vm.runInContext(
  `(() => {
    const envelope = {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      sequence: 2,
      action: 'joinCurrentSession',
      payload: {},
    };
    Object.defineProperty(envelope, 'nonce', {
      enumerable: true,
      get() {
        __localFrameGetterCalls += 1;
        return __localFrameNonce;
      },
    });
    return envelope;
  })()`,
  guest.context
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: guestLobbyFrame.contentWindow,
    data: frameEnvelopeWithGetter,
    origin: 'null',
  }),
  null
);
assert.equal(guest.context.__localFrameGetterCalls, 0);

guest.context.__localFrameToStringCalls = 0;
const frameEnvelopeWithToString = vm.runInContext(
  `({
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind: 'lobby',
    nonce: {
      toString() {
        __localFrameToStringCalls += 1;
        return __localFrameNonce;
      },
    },
    sequence: 2,
    action: 'joinCurrentSession',
    payload: {},
  })`,
  guest.context
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: guestLobbyFrame.contentWindow,
    data: frameEnvelopeWithToString,
    origin: 'null',
  }),
  null
);
assert.equal(guest.context.__localFrameToStringCalls, 0);

const pollutedFrameEnvelope = vm.runInContext(
  `(() => {
    const envelope = {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      nonce: __localFrameNonce,
      sequence: 2,
      action: 'joinCurrentSession',
      payload: {},
    };
    Object.defineProperty(envelope, '__proto__', {
      value: { polluted: true },
      enumerable: true,
    });
    return envelope;
  })()`,
  guest.context
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: guestLobbyFrame.contentWindow,
    data: pollutedFrameEnvelope,
    origin: 'null',
  }),
  null
);
assert.equal({}.polluted, undefined);

const joinResult = guestBackend.consumeOfficialLobbyFrameMessage(
  {
    source: guestLobbyFrame.contentWindow,
    origin: 'null',
    data: realmValue(
      guest,
      JSON.parse(JSON.stringify(guestLobbyDocument.outbound.at(-1).message))
    ),
  }
);
assert.deepEqual(JSON.parse(JSON.stringify(joinResult)), {
  data: { id: 'joinLobby', lobbyId: sessionData.id },
});
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 2,
      action: 'joinCurrentSession',
    })
  ),
  null,
  'a replayed frame action is rejected'
);

const lobbyCredential = 'secret-lobby-credential';
const rawConnectionId = 'secret-raw-connection';
assert.equal(
  guestBackend.postOfficialLobbyFrameMessage(
    guestLobbyFrame.frame,
    realmValue(guest, {
      id: 'lobbyJoined',
      lobbyId: sessionData.id,
      playerId: 'guest-1',
      playerToken: lobbyCredential,
      connectionId: rawConnectionId,
      positionInLobby: 2,
    })
  ),
  true
);
const sanitizedLobbyJoined = JSON.stringify(
  guestLobbyFrame.posted.find(
    entry => entry.message.event === 'lobbyJoined'
  ).message
);
assert.doesNotMatch(sanitizedLobbyJoined, new RegExp(lobbyCredential));
assert.doesNotMatch(sanitizedLobbyJoined, new RegExp(rawConnectionId));
assert.doesNotMatch(sanitizedLobbyJoined, /playerToken|connectionId/);
assert.deepEqual(
  JSON.parse(sanitizedLobbyJoined).payload,
  {
    lobbyId: sessionData.id,
    positionInLobby: 2,
    role: 'guest',
    sessionState: 'running',
    connectedPlayers: 2,
    minPlayers: 1,
    maxPlayers: 8,
    players: [
      {
        number: 1,
        nickname: 'Host',
        connected: true,
        isCurrent: false,
        isAuthority: true,
        readiness: 'ready',
        avatarDataUrl: null,
      },
      {
        number: 2,
        nickname: 'Guest',
        connected: true,
        isCurrent: true,
        isAuthority: false,
        readiness: 'notReady',
        avatarDataUrl: null,
      },
    ],
  }
);
guestLobbyFrame.posted
  .filter(entry => entry.message.sequence >= 2)
  .forEach(entry => guestLobbyDocument.dispatchFromParent(entry.message));
assert.equal(
  guestLobbyDocument.outbound.at(-1).message.action,
  'joinGame',
  'a guest already joined to a running session must enter automatically'
);
assert.equal(guestLobbyDocument.outbound.at(-1).message.sequence, 3);

assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 4,
      action: 'startGameCountdown',
    })
  ),
  null,
  'a guest cannot forge an authority lobby action'
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 4,
      action: 'startGame',
    })
  ),
  null,
  'a guest cannot start the shared Playmesh session'
);
const joinGameResult = guestBackend.consumeOfficialLobbyFrameMessage(
  {
    source: guestLobbyFrame.contentWindow,
    origin: 'null',
    data: realmValue(
      guest,
      JSON.parse(JSON.stringify(guestLobbyDocument.outbound.at(-1).message))
    ),
  }
);
assert.deepEqual(JSON.parse(JSON.stringify(joinGameResult)), {
  data: { id: 'joinGame' },
});
guestLobbyDocument.click('leave');
assert.equal(guestLobbyDocument.outbound.at(-1).message.sequence, 4);
const leaveResult = guestBackend.consumeOfficialLobbyFrameMessage({
  source: guestLobbyFrame.contentWindow,
  origin: 'null',
  data: realmValue(
    guest,
    JSON.parse(JSON.stringify(guestLobbyDocument.outbound.at(-1).message))
  ),
});
assert.deepEqual(JSON.parse(JSON.stringify(leaveResult)), {
  data: { id: 'leaveLobby' },
});
assert.equal(
  guestBackend.postOfficialLobbyFrameMessage(
    guestLobbyFrame.frame,
    realmValue(guest, { id: 'lobbyLeft' })
  ),
  true
);

guest.context.__postGetterCalls = 0;
const postMessageWithGetter = vm.runInContext(
  `({
    id: 'lobbyJoined',
    lobbyId: 'session-fixture',
    playerId: 'guest-1',
    get playerToken() {
      __postGetterCalls += 1;
      return 'forbidden';
    },
    connectionId: 'connection',
    positionInLobby: 2,
  })`,
  guest.context
);
assert.equal(
  guestBackend.postOfficialLobbyFrameMessage(
    guestLobbyFrame.frame,
    postMessageWithGetter
  ),
  false
);
assert.equal(guest.context.__postGetterCalls, 0);

const replacementLobbyFrame = createFrameFixture();
guestBackend.configureOfficialLobbyFrame(replacementLobbyFrame.frame);
const replacementNonce = readFrameCapability(replacementLobbyFrame.frame);
assert.notEqual(replacementNonce, guestLobbyNonce);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, guestLobbyFrame, {
      kind: 'lobby',
      nonce: guestLobbyNonce,
      sequence: 5,
      action: 'ready',
    })
  ),
  null,
  'configuring a replacement invalidates the old frame'
);
assert.equal(
  guestBackend.postOfficialLobbyFrameMessage(
    guestLobbyFrame.frame,
    realmValue(guest, { id: 'lobbyLeft' })
  ),
  false
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: guestLobbyFrame.contentWindow,
    origin: 'null',
    data: localFrameEnvelope(guest, {
      kind: 'lobby',
      nonce: replacementNonce,
      sequence: 1,
      action: 'ready',
    }),
  }),
  null,
  'a sibling null-origin frame cannot borrow the active capability'
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage({
    source: null,
    origin: 'null',
    data: localFrameEnvelope(guest, {
      kind: 'lobby',
      nonce: replacementNonce,
      sequence: 1,
      action: 'ready',
    }),
  }),
  null
);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, replacementLobbyFrame, {
      kind: 'lobby',
      nonce: replacementNonce,
      sequence: 1,
      action: 'ready',
    })
  ).data.id,
  'lobbiesListenerReady'
);
guestBackend.configureOfficialLobbyFrame(replacementLobbyFrame.frame);
const reconfiguredNonce = readFrameCapability(replacementLobbyFrame.frame);
assert.notEqual(reconfiguredNonce, replacementNonce);
assert.equal(
  guestBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(guest, replacementLobbyFrame, {
      kind: 'lobby',
      nonce: replacementNonce,
      sequence: 2,
      action: 'joinCurrentSession',
    })
  ),
  null,
  'reconfiguring the same frame invalidates its previous capability'
);

// The Authority joins the one shared lobby. Its only visible Start action is
// translated to the official countdown-preparation seam.
const lobbySessionData = { ...sessionData, state: 'lobby' };
const lobbyHost = createPage({
  authority: true,
  playerId: 'host-1',
  sessionData: lobbySessionData,
});
lobbyHost.coordinator.applyPlayerNumberSnapshot(
  realmValue(lobbyHost, { ...snapshot, sessionId: lobbySessionData.id })
);
const lobbyHostBackend = negotiate(lobbyHost, 'multiplayer');
const authorityLobbyFrame = createFrameFixture();
lobbyHostBackend.configureOfficialLobbyFrame(authorityLobbyFrame.frame);
const authorityLobbyNonce = readFrameCapability(authorityLobbyFrame.frame);
assert.equal(
  lobbyHostBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(lobbyHost, authorityLobbyFrame, {
      kind: 'lobby',
      nonce: authorityLobbyNonce,
      sequence: 1,
      action: 'ready',
    })
  ).data.id,
  'lobbiesListenerReady'
);
assert.equal(
  lobbyHostBackend.postOfficialLobbyFrameMessage(
    authorityLobbyFrame.frame,
    realmValue(lobbyHost, {
      id: 'sessionInformation',
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'Win32',
      hasTouch: false,
    })
  ),
  true
);
assert.equal(
  lobbyHostBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(lobbyHost, authorityLobbyFrame, {
      kind: 'lobby',
      nonce: authorityLobbyNonce,
      sequence: 2,
      action: 'joinCurrentSession',
    })
  ).data.id,
  'joinLobby'
);
assert.equal(
  lobbyHostBackend.postOfficialLobbyFrameMessage(
    authorityLobbyFrame.frame,
    realmValue(lobbyHost, {
      id: 'lobbyJoined',
      lobbyId: lobbySessionData.id,
      playerId: 'host-1',
      playerToken: 'host-parent-only-credential',
      connectionId: 'host-parent-only-connection',
      positionInLobby: 1,
    })
  ),
  true
);

// A player joining the underlying Playmesh session is surfaced through the
// existing official lobbyUpdated seam. The already-joined host frame receives
// the new stable slot without discovering or creating another room.
const hostRosterControl = lobbyHostBackend.createOfficialLobbyControlFacade();
hostRosterControl.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.type !== 'lobbyUpdated') return;
  lobbyHostBackend.postOfficialLobbyFrameMessage(
    authorityLobbyFrame.frame,
    realmValue(lobbyHost, { id: message.type, ...message.data })
  );
};
await new Promise(resolve => {
  hostRosterControl.onopen = resolve;
});
const latePlayerSession = {
  ...lobbySessionData,
  players: [
    ...lobbySessionData.players,
    {
      id: 'late-player',
      nickname: 'Late Player',
      role: 'player',
      connected: true,
      avatar: null,
    },
  ],
};
lobbyHost.coordinator.updateContext(
  realmValue(lobbyHost, {
    isAuthority: true,
    authorityPeerId: 'authority',
    currentSession: latePlayerSession,
    currentPlayer: latePlayerSession.players.find(
      player => player.id === 'host-1'
    ),
  })
);
lobbyHost.coordinator.applyPlayerNumberSnapshot(
  realmValue(lobbyHost, {
    ...snapshot,
    sessionId: latePlayerSession.id,
    revision: snapshot.revision + 1,
    assignments: [
      ...snapshot.assignments,
      { playerId: 'late-player', playerNumber: 3 },
    ],
  })
);
await flush();
const hostRosterUpdate = [...authorityLobbyFrame.posted]
  .reverse()
  .find(entry => entry.message.event === 'lobbyUpdated');
assert.ok(hostRosterUpdate);
assert.deepEqual(
  JSON.parse(JSON.stringify(hostRosterUpdate.message.payload.players)).map(
    player => [player.number, player.nickname]
  ),
  [
    [1, 'Host'],
    [2, 'Guest'],
    [3, 'Late Player'],
  ]
);
hostRosterControl.close();
assert.deepEqual(
  JSON.parse(JSON.stringify(lobbyHostBackend.consumeOfficialLobbyFrameMessage(
    localFrameEvent(lobbyHost, authorityLobbyFrame, {
      kind: 'lobby',
      nonce: authorityLobbyNonce,
      sequence: 3,
      action: 'startGameCountdown',
    })
  ))),
  { data: { id: 'startGameCountdown' } },
  'the host frame emits the official preparation action exactly once'
);

// Authentication is initiated inside the sandbox, while the official result
// (including credential) is returned only to the parent GDevelop handler.
guestAuthentication.writeOfficialIdentity(
  identityKey,
  realmValue(guest, { ...identity, username: null })
);
const authenticationFrame = createFrameFixture();
guestAuthentication.configureOfficialAuthenticationFrame(
  authenticationFrame.frame
);
const authenticationNonce = readFrameCapability(authenticationFrame.frame);
const authenticationDocument = runConfiguredFrameDocument(
  authenticationFrame.frame
);
assert.match(authenticationFrame.frame.srcdoc, /authenticate/);
assert.doesNotMatch(authenticationFrame.frame.srcdoc, /https?:\/\//);
assert.doesNotMatch(
  authenticationFrame.frame.srcdoc,
  new RegExp(identity.userToken)
);
assert.equal(authenticationFrame.posted.length, 0);
assert.equal(authenticationDocument.outbound.length, 0);
authenticationDocument.click('authenticate');
assert.deepEqual(
  JSON.parse(JSON.stringify(authenticationDocument.outbound[0].message)),
  {
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind: 'authentication',
    nonce: authenticationNonce,
    sequence: 1,
    action: 'authenticate',
    payload: {},
  }
);
assert.equal(
  guestAuthentication.consumeOfficialAuthenticationFrameMessage({
    source: {},
    origin: 'null',
    data: localFrameEnvelope(guest, {
      kind: 'authentication',
      nonce: authenticationNonce,
      sequence: 1,
      action: 'authenticate',
    }),
  }),
  null
);
assert.equal(
  guestAuthentication.consumeOfficialAuthenticationFrameMessage({
    source: authenticationFrame.contentWindow,
    origin: 'null',
    data: realmValue(guest, {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'authentication',
      nonce: authenticationNonce,
      sequence: 1,
      action: 'authenticate',
      payload: {},
      extra: true,
    }),
  }),
  null
);
const authenticationResult =
  guestAuthentication.consumeOfficialAuthenticationFrameMessage(
    {
      source: authenticationFrame.contentWindow,
      origin: 'null',
      data: realmValue(
        guest,
        JSON.parse(
          JSON.stringify(authenticationDocument.outbound[0].message)
        )
      ),
    }
  );
assert.deepEqual(JSON.parse(JSON.stringify(authenticationResult)), {
  data: {
    id: 'authenticationResult',
    body: {
      userId: 'guest-1',
      username: null,
      token: identity.userToken,
    },
  },
});
assert.equal(
  guestAuthentication.consumeOfficialAuthenticationFrameMessage(
    localFrameEvent(guest, authenticationFrame, {
      kind: 'authentication',
      nonce: authenticationNonce,
      sequence: 1,
      action: 'authenticate',
    })
  ),
  null,
  'authentication frame messages cannot be replayed'
);
assert.equal(
  authenticationFrame.posted.length,
  0,
  'authentication credential is never posted into the iframe'
);

const previousAuthenticationFrame = authenticationFrame;
const replacementAuthenticationFrame = createFrameFixture();
guestAuthentication.configureOfficialAuthenticationFrame(
  replacementAuthenticationFrame.frame
);
assert.equal(
  guestAuthentication.consumeOfficialAuthenticationFrameMessage(
    localFrameEvent(guest, previousAuthenticationFrame, {
      kind: 'authentication',
      nonce: authenticationNonce,
      sequence: 2,
      action: 'authenticate',
    })
  ),
  null,
  'a new authentication frame invalidates the previous frame'
);

// Crypto is mandatory: if the runtime cannot mint an unpredictable capability,
// the local page fails closed and never falls back to a cloud URL.
const noCryptoContext = vm.createContext({
  console: { error() {}, warn() {}, info() {}, log() {} },
  TextEncoder,
  TextDecoder,
  Uint8Array,
  DataView,
  Promise,
  Date,
  setTimeout,
  clearTimeout,
});
vm.runInContext(bridgeSource, noCryptoContext, {
  filename: 'gdevelop-multiplayer-bridge-no-crypto.js',
});
noCryptoContext.__negotiateRequest = JSON.stringify({
  engine: 'gdevelop',
  engineVersion: '5.6.276',
  feature: 'multiplayer',
  minVersion: 1,
  maxVersion: 1,
});
const noCryptoBackend = noCryptoContext[REGISTRY_SYMBOL].negotiate(
  vm.runInContext('JSON.parse(__negotiateRequest)', noCryptoContext)
);
const noCryptoFrame = createFrameFixture();
assert.throws(
  () => noCryptoBackend.configureOfficialLobbyFrame(noCryptoFrame.frame),
  error => error.code === 'PLAYMESH_GDEVELOP_CRYPTO_UNAVAILABLE'
);
assert.equal(
  noCryptoFrame.attributes.has('src'),
  false,
  'crypto failure cannot leave a cloud navigation fallback behind'
);

// 浏览器运行时把既有 coordinator sink 接到一次性、非阻塞的本地提示层；
// 同一页面按 activation 去重，关闭后不会改变游戏流程或再次弹出。
const warningUiLogs = [];
const warningUiChildren = [];
const createWarningUiElement = tagName => {
  const listeners = new Map();
  const element = {
    tagName,
    style: {},
    children: [],
    textContent: '',
    setAttribute() {},
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    append(...children) {
      element.children.push(...children);
    },
    remove() {
      const index = warningUiChildren.indexOf(element);
      if (index >= 0) warningUiChildren.splice(index, 1);
    },
    __listeners: listeners,
  };
  return element;
};
const warningUiContext = vm.createContext({
  console: {
    error() {},
    info() {},
    log() {},
    warn(...args) {
      warningUiLogs.push(args);
    },
  },
  document: {
    documentElement: { lang: 'zh-CN' },
    body: {
      appendChild(element) {
        warningUiChildren.push(element);
      },
    },
    createElement: createWarningUiElement,
    addEventListener() {},
  },
  location: {
    origin: 'http://127.0.0.1:16666',
    pathname: '/preview/index.html',
    search: '?game-id=warning-test',
  },
  TextEncoder,
  TextDecoder,
  Uint8Array,
  DataView,
  Promise,
  Date,
  crypto: webcrypto,
  setTimeout,
  clearTimeout,
});
vm.runInContext(bridgeSource, warningUiContext, {
  filename: 'gdevelop-multiplayer-bridge-warning-ui.js',
});
const warningUiCoordinator = warningUiContext[COORDINATOR_SYMBOL];
const warningUiPage = { context: warningUiContext };
const warningUiCases = [
  ['MULTIPLAYER_RUNTIME_INACTIVE', 'game_not_multiplayer'],
  ['MULTIPLAYER_RUNTIME_INACTIVE', 'game_type_unavailable'],
  [
    'MULTIPLAYER_CONFIGURATION_REQUIRED',
    'multiplayer_behavior_requires_online_game',
  ],
  ['MULTIPLAYER_RUNTIME_INACTIVE', 'session_unavailable'],
  ['MULTIPLAYER_HOST_STATE_MISMATCH', 'host_state_mismatch'],
];
for (const [code, activation] of warningUiCases) {
  assert.equal(
    warningUiCoordinator.emitWarning(
      realmValue(warningUiPage, {
        code,
        source: 'gdevelop-bootstrap',
        context: {
          activation,
          sessionPresent: activation !== 'session_unavailable',
          behaviorDetected:
            activation === 'multiplayer_behavior_requires_online_game',
        },
      })
    ),
    true
  );
}
assert.equal(warningUiLogs.length, 5);
assert.equal(warningUiChildren.length, 5);
assert.match(warningUiChildren[0].children[0].textContent, /本地逻辑会继续运行/);
warningUiCoordinator.emitWarning(
  realmValue(warningUiPage, {
    code: 'MULTIPLAYER_RUNTIME_INACTIVE',
    source: 'gdevelop-bootstrap',
    context: {
      activation: 'game_not_multiplayer',
      sessionPresent: true,
      behaviorDetected: false,
    },
  })
);
assert.equal(warningUiLogs.length, 5);
assert.equal(warningUiChildren.length, 5);
warningUiChildren[0].children[1].__listeners.get('click')();
assert.equal(warningUiChildren.length, 4);

// Bootstrap warnings use the existing coordinator only. The sink is optional,
// receives a frozen allowlisted DTO, and can never break runtime installation.
const inactiveWarning = {
  code: 'MULTIPLAYER_RUNTIME_INACTIVE',
  source: 'gdevelop-bootstrap',
  context: {
    activation: 'game_not_multiplayer',
    sessionPresent: true,
    behaviorDetected: false,
  },
};
assert.equal(
  guest.coordinator.emitWarning(realmValue(guest, inactiveWarning)),
  false,
  'an unbound warning sink is a safe no-op'
);
const receivedWarnings = [];
assert.equal(
  guest.coordinator.setWarningSink(warning => receivedWarnings.push(warning)),
  true
);
assert.equal(
  guest.coordinator.emitWarning(realmValue(guest, inactiveWarning)),
  true
);
assert.deepEqual(
  JSON.parse(JSON.stringify(receivedWarnings)),
  [inactiveWarning]
);
assert.equal(Object.isFrozen(receivedWarnings[0]), true);
assert.equal(Object.isFrozen(receivedWarnings[0].context), true);
assert.throws(
  () =>
    guest.coordinator.emitWarning(
      realmValue(guest, { ...inactiveWarning, extra: true })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_WARNING'
);
assert.throws(
  () =>
    guest.coordinator.emitWarning(
      realmValue(guest, {
        ...inactiveWarning,
        context: { ...inactiveWarning.context, activation: 'enabled' },
      })
    ),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_WARNING'
);
guest.context.__warningGetterCalls = 0;
const warningWithGetter = vm.runInContext(
  `({
    code: 'MULTIPLAYER_RUNTIME_INACTIVE',
    source: 'gdevelop-bootstrap',
    get context() {
      __warningGetterCalls += 1;
      return {
        activation: 'game_not_multiplayer',
        sessionPresent: true,
        behaviorDetected: false,
      };
    },
  })`,
  guest.context
);
assert.throws(
  () => guest.coordinator.emitWarning(warningWithGetter),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_WARNING'
);
assert.equal(guest.context.__warningGetterCalls, 0);
guest.coordinator.setWarningSink(() => {
  throw new Error('host UI unavailable');
});
assert.equal(
  guest.coordinator.emitWarning(realmValue(guest, inactiveWarning)),
  false,
  'a failing host sink is contained'
);
assert.equal(guest.coordinator.setWarningSink(null), true);
assert.throws(
  () => guest.coordinator.setWarningSink('console'),
  error => error.code === 'PLAYMESH_GDEVELOP_INVALID_WARNING_SINK'
);

// The official countdown action is carried by a private, versioned Binary
// control packet. It is independent from the PeerJS data connection and never
// changes the Playmesh session state by itself.
const countdownSessionData = {
  id: 'session-countdown',
  state: 'lobby',
  authorityClientId: 'countdown-host',
  minPlayers: 2,
  maxPlayers: 8,
  players: [
    {
      id: 'countdown-host',
      nickname: 'Countdown Host',
      role: 'authority',
      connected: true,
    },
    {
      id: 'countdown-guest',
      nickname: 'Countdown Guest',
      role: 'player',
      connected: true,
    },
  ],
};
const countdownHostTimers = createBoundedFakeTimers();
const countdownGuestTimers = createBoundedFakeTimers();
const countdownHost = createPage({
  authority: true,
  playerId: 'countdown-host',
  sessionData: countdownSessionData,
  runtimeGlobals: {
    setTimeout: countdownHostTimers.setTimeout,
    clearTimeout: countdownHostTimers.clearTimeout,
  },
});
const countdownGuest = createPage({
  authority: false,
  playerId: 'countdown-guest',
  sessionData: countdownSessionData,
  runtimeGlobals: {
    setTimeout: countdownGuestTimers.setTimeout,
    clearTimeout: countdownGuestTimers.clearTimeout,
  },
});
const countdownPages = [countdownHost, countdownGuest];
const countdownBus = createBinaryBus(countdownPages);

const applyCountdownSnapshot = (page, epoch, revision = 1) =>
  page.coordinator.applyPlayerNumberSnapshot(
    realmValue(page, {
      type: 'playerNumbers.snapshot',
      protocol: PROTOCOL,
      version: 1,
      sessionId: countdownSessionData.id,
      epoch,
      revision,
      assignments: [
        { playerId: 'countdown-host', playerNumber: 1 },
        { playerId: 'countdown-guest', playerNumber: 2 },
      ],
      errorCode: null,
    })
  );
for (const page of countdownPages) applyCountdownSnapshot(page, 1);

const countdownHostBackend = negotiate(countdownHost, 'multiplayer');
const countdownGuestBackend = negotiate(countdownGuest, 'multiplayer');
const countdownHostControl = countdownHostBackend.createOfficialLobbyControlFacade();
const countdownGuestControl =
  countdownGuestBackend.createOfficialLobbyControlFacade();
const countdownHostEvents = [];
const countdownGuestEvents = [];
const countdownHostActions = [];
const countdownGuestConnections = [];
const countdownHostConnections = [];
let rejectNextCountdownGuestPeerId = true;
let countdownGuestControlErrors = 0;
const countdownHostPeer = countdownHostBackend.createOfficialPeer();
const countdownGuestPeer = countdownGuestBackend.createOfficialPeer();
countdownHostPeer.on('connection', connection => {
  countdownHostConnections.push(connection);
});
countdownHostControl.onmessage = event => {
  const message = JSON.parse(event.data);
  countdownHostEvents.push(message);
  if (message.type === 'gameCountdownStarted') {
    countdownHostActions.push('sendPeerId');
    countdownHostControl.send(
      realmValue(countdownHost, {
        action: 'sendPeerId',
        connectionType: 'lobby',
        peerId: 'authority',
      })
    );
  }
};
countdownGuestControl.onmessage = event => {
  const message = JSON.parse(event.data);
  countdownGuestEvents.push(message);
  if (message.type === 'peerId') {
    if (rejectNextCountdownGuestPeerId) {
      rejectNextCountdownGuestPeerId = false;
      return Promise.reject(
        new Error('official peerId handler rejected after partial entry')
      );
    }
    countdownGuestConnections.push(
      countdownGuestPeer.connect(message.data.peerId)
    );
  }
};
countdownGuestControl.onerror = () => {
  countdownGuestControlErrors += 1;
};
await Promise.all([
  new Promise(resolve => {
    countdownHostControl.onopen = resolve;
  }),
  new Promise(resolve => {
    countdownGuestControl.onopen = resolve;
  }),
  once(countdownHostPeer, 'open'),
  once(countdownGuestPeer, 'open'),
]);

const initializeCountdownLobbyFrame = (page, backend, positionInLobby) => {
  const fixture = createFrameFixture();
  backend.configureOfficialLobbyFrame(fixture.frame);
  const nonce = readFrameCapability(fixture.frame);
  assert.equal(
    backend.consumeOfficialLobbyFrameMessage(
      localFrameEvent(page, fixture, {
        kind: 'lobby',
        nonce,
        sequence: 1,
        action: 'ready',
      })
    ).data.id,
    'lobbiesListenerReady'
  );
  assert.equal(
    backend.postOfficialLobbyFrameMessage(
      fixture.frame,
      realmValue(page, {
        id: 'sessionInformation',
        isCordova: false,
        devicePlatform: '',
        navigatorPlatform: 'Win32',
        hasTouch: false,
      })
    ),
    true
  );
  assert.equal(
    backend.consumeOfficialLobbyFrameMessage(
      localFrameEvent(page, fixture, {
        kind: 'lobby',
        nonce,
        sequence: 2,
        action: 'joinCurrentSession',
      })
    ).data.id,
    'joinLobby'
  );
  assert.equal(
    backend.postOfficialLobbyFrameMessage(
      fixture.frame,
      realmValue(page, {
        id: 'lobbyJoined',
        lobbyId: countdownSessionData.id,
        playerId: page.playerId,
        playerToken: `parent-only-${page.playerId}`,
        connectionId: `connection-${page.playerId}`,
        positionInLobby,
      })
    ),
    true
  );
  return { fixture, nonce, nextSequence: 3 };
};

const requestCountdownGuestReady = (lobby, requestId) => {
  const sequence = lobby.nextSequence++;
  assert.equal(
    countdownGuestBackend.consumeOfficialLobbyFrameMessage(
      localFrameEvent(countdownGuest, lobby.fixture, {
        kind: 'lobby',
        nonce: lobby.nonce,
        sequence,
        action: 'setReady',
        payload: { requestId, ready: true },
      })
    ),
    null
  );
};

const countdownHostLobby = initializeCountdownLobbyFrame(
  countdownHost,
  countdownHostBackend,
  1
);
let countdownGuestLobby = initializeCountdownLobbyFrame(
  countdownGuest,
  countdownGuestBackend,
  2
);

// Guest readiness is a manual intent acknowledged by Authority. A stale
// cancellation token cannot clear it, while leaving the lobby page does send
// UNREADY without removing the player from the Playmesh session.
requestCountdownGuestReady(countdownGuestLobby, 'guest-ready-first');
await flush();
const firstReadyPacketRecord = countdownBus.packets.find(record => {
  const packet = decodePmGdPacket(record.bytes);
  return record.sourcePlayerId === 'countdown-guest' && packet.type === PMGD_READY_STATE;
});
assert.ok(firstReadyPacketRecord);
const firstReadyPacket = decodePmGdPacket(firstReadyPacketRecord.bytes);
assert.equal(firstReadyPacket.body[0], 1);
const firstReadyToken = firstReadyPacket.body.slice(1);
const staleReadyToken = new Uint8Array(16).fill(0xa5);
assert.notDeepEqual([...staleReadyToken], [...firstReadyToken]);
countdownBus.inject({
  targetPlayerId: 'countdown-host',
  senderPlayerId: 'countdown-guest',
  bytes: encodeReadyStatePacket(false, staleReadyToken),
});
await flush();
const staleReadyAck = [...countdownBus.packets]
  .reverse()
  .map(record => ({ record, packet: decodePmGdPacket(record.bytes) }))
  .find(
    entry =>
      entry.record.sourcePlayerId === 'countdown-host' &&
      entry.record.targetPlayerId === 'countdown-guest' &&
      entry.packet.type === PMGD_READY_ACK
  );
assert.ok(staleReadyAck);
assert.equal(staleReadyAck.packet.body[0], 1);
assert.deepEqual([...staleReadyAck.packet.body.slice(1)], [...firstReadyToken]);

const readyPacketCountBeforeClose = countdownBus.packets.filter(
  record => decodePmGdPacket(record.bytes).type === PMGD_READY_STATE
).length;
assert.equal(countdownGuestBackend.notifyOfficialLobbyFrameClosed(), true);
await flush();
const readyPacketsAfterClose = countdownBus.packets.filter(
  record => decodePmGdPacket(record.bytes).type === PMGD_READY_STATE
);
assert.equal(readyPacketsAfterClose.length, readyPacketCountBeforeClose + 1);
assert.equal(decodePmGdPacket(readyPacketsAfterClose.at(-1).bytes).body[0], 0);
assert.equal(countdownGuest.calls.finish, 0);
assert.equal(countdownGuest.session.players.length, 2);

countdownGuestLobby = initializeCountdownLobbyFrame(
  countdownGuest,
  countdownGuestBackend,
  2
);
requestCountdownGuestReady(countdownGuestLobby, 'guest-ready-second');
await flush();

const countdownEvents = events =>
  events.filter(event => event.type === 'gameCountdownStarted');

const startCountdownRound = requestId => {
  const sequence = countdownHostLobby.nextSequence++;
  return countdownHostBackend.handleOfficialLobbyFrameMessage(
    localFrameEvent(countdownHost, countdownHostLobby.fixture, {
      kind: 'lobby',
      nonce: countdownHostLobby.nonce,
      sequence,
      action: 'startGameCountdown',
      payload: { requestId },
    }),
    officialEvent => {
      assert.equal(officialEvent.data.id, 'startGameCountdown');
      countdownHostControl.send(
        realmValue(countdownHost, {
          action: officialEvent.data.id,
          connectionType: 'lobby',
        })
      );
    }
  );
};

// A peerId handler that has already entered official code and then rejects is
// observed once, never auto-replayed. The next explicit Host start round is a
// safe reconciliation boundary and can deliver a fresh peer announcement.
assert.equal(startCountdownRound('host-start-peer-reject'), true);
for (let index = 0; index < 4; index += 1) await flush();
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'peerId').length,
  1
);
assert.equal(countdownGuestConnections.length, 0);
assert.equal(countdownGuestControlErrors, 1);
await flush();
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'peerId').length,
  1,
  'a rejected observed delivery is not automatically replayed'
);
countdownHostTimers.runNextDelay(12000);
await flush();
assert.equal(countdownHost.calls.start, 0);

// Round one follows the official preparation phase but never receives the
// guest's updateConnection. A roster revision invalidates the frozen barrier;
// both sides time out back to a replayable lobby without reopening the frame.
assert.equal(startCountdownRound('host-start-round-1'), true);
for (let index = 0; index < 4; index += 1) await flush();
assert.equal(countdownHost.calls.start, 0);
assert.equal(countdownEvents(countdownHostEvents).length, 2);
assert.equal(countdownEvents(countdownGuestEvents).length, 2);
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'peerId').length,
  2
);
assert.equal(countdownGuestConnections.length, 1);
assert.equal(
  countdownGuestConnections[0].peerConnection.connectionState,
  'connected'
);
applyCountdownSnapshot(countdownHost, 1, 2);
applyCountdownSnapshot(countdownGuest, 1, 2);
countdownHostTimers.runNextDelay(12000);
countdownGuestTimers.runNextDelay(12000);
await flush();
assert.equal(countdownHost.calls.start, 0);
assert.equal(
  countdownGuestConnections[0].peerConnection.connectionState,
  'closed',
  'a timed-out preparation cannot poison the next round with an announced peer'
);

// Round two reuses the same manual ready intent. A forged PREPARED with a
// stale round token is ignored; only the official updateConnection confirmation
// releases PREPARED and invokes the Playmesh start exactly once.
assert.equal(startCountdownRound('host-start-round-2'), true);
for (let index = 0; index < 5; index += 1) await flush();
assert.equal(countdownGuestConnections.length, 2);
const activeGuestConnection = countdownGuestConnections.at(-1);
assert.equal(activeGuestConnection.peerConnection.connectionState, 'connected');
const activePrepareRecord = [...countdownBus.packets]
  .reverse()
  .find(record => decodePmGdPacket(record.bytes).type === PMGD_PREPARE);
assert.ok(activePrepareRecord);
const activePrepare = decodePmGdPacket(activePrepareRecord.bytes);
const activeReadyToken = activePrepare.body.slice(16, 32);
const staleRoundToken = new Uint8Array(16).fill(0x5a);
assert.notDeepEqual([...staleRoundToken], [...activePrepare.body.slice(0, 16)]);
countdownBus.inject({
  targetPlayerId: 'countdown-host',
  senderPlayerId: 'countdown-guest',
  bytes: encodePreparedPacket(staleRoundToken, activeReadyToken),
});
await flush();
assert.equal(countdownHost.calls.start, 0);
countdownGuestControl.send(
  realmValue(countdownGuest, {
    action: 'updateConnection',
    connectionType: 'lobby',
    status: 'connected',
    peerId: 'countdown-guest',
  })
);
for (let index = 0; index < 5; index += 1) await flush();
assert.equal(countdownHost.calls.start, 1);
assert.deepEqual(countdownHostActions, [
  'sendPeerId',
  'sendPeerId',
  'sendPeerId',
]);
assert.equal(countdownEvents(countdownHostEvents).length, 3);
assert.equal(countdownEvents(countdownGuestEvents).length, 3);
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'peerId').length,
  3
);
assert.ok(
  countdownHostLobby.fixture.posted.some(
    entry =>
      entry.message.event === 'operationSucceeded' &&
      entry.message.payload.requestId === 'host-start-round-2'
  )
);
const observedPacketTypes = new Set(
  countdownBus.packets.map(record => decodePmGdPacket(record.bytes).type)
);
for (const type of [
  PMGD_READY_STATE,
  PMGD_READY_ACK,
  PMGD_READY_SNAPSHOT,
  PMGD_PREPARE,
  PMGD_PREPARED,
]) {
  assert.equal(observedPacketTypes.has(type), true);
}

const runningCountdownSession = {
  ...countdownSessionData,
  state: 'running',
};
const readyPacketCountBeforeRunning = countdownBus.packets.filter(
  record => decodePmGdPacket(record.bytes).type === PMGD_READY_STATE
).length;
countdownHost.coordinator.updateContext(
  realmValue(countdownHost, {
    isAuthority: true,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[0],
  })
);
countdownGuest.coordinator.updateContext(
  realmValue(countdownGuest, {
    isAuthority: false,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[1],
  })
);
for (let index = 0; index < 4; index += 1) await flush();
assert.equal(
  countdownHostEvents.filter(event => event.type === 'gameStarted').length,
  1
);
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'gameStarted').length,
  1,
  'a peer announced during preparation must still receive running gameStarted'
);
assert.equal(
  countdownGuestEvents.filter(event => event.type === 'peerId').length,
  3,
  'running reconciliation reuses the fulfilled preparation peer announcement'
);
assert.equal(
  activeGuestConnection.peerConnection.connectionState,
  'connected',
  'running readiness cleanup must retain the official-ready connection'
);
assert.equal(
  countdownHostConnections.at(-1).peerConnection.connectionState,
  'connected'
);
assert.equal(
  countdownBus.packets.filter(
    record => decodePmGdPacket(record.bytes).type === PMGD_READY_STATE
  ).length,
  readyPacketCountBeforeRunning,
  'entering running clears readiness metadata without emitting UNREADY'
);
assert.equal(countdownGuestBackend.notifyOfficialLobbyFrameClosed(), true);
await flush();
assert.equal(activeGuestConnection.peerConnection.connectionState, 'connected');
assert.equal(
  countdownBus.packets.filter(
    record => decodePmGdPacket(record.bytes).type === PMGD_READY_STATE
  ).length,
  readyPacketCountBeforeRunning,
  'removing the official lobby frame in running never cancels readiness or peer'
);

// Delivery is committed only after the official async handler fulfills. A
// handler that partially executes and rejects is never auto-replayed; an
// explicit running-state reconciliation retries once and then remains exactly-once.
countdownHostControl.close();
const lateRunningHostControl =
  countdownHostBackend.createOfficialLobbyControlFacade();
const lateRunningHostEvents = [];
let lateRunningHostGameStartedCalls = 0;
let lateRunningHostErrors = 0;
lateRunningHostControl.onmessage = event => {
  const message = JSON.parse(event.data);
  lateRunningHostEvents.push(message);
  if (message.type === 'gameStarted') {
    lateRunningHostGameStartedCalls += 1;
    if (lateRunningHostGameStartedCalls === 1) {
      return Promise.reject(new Error('official host handler rejected after entry'));
    }
  }
};
lateRunningHostControl.onerror = () => {
  lateRunningHostErrors += 1;
};
await new Promise(resolve => {
  lateRunningHostControl.onopen = resolve;
});
await flush();
await flush();
assert.equal(lateRunningHostGameStartedCalls, 1);
assert.equal(lateRunningHostErrors, 1);
countdownHost.coordinator.updateContext(
  realmValue(countdownHost, {
    isAuthority: true,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[0],
  })
);
await flush();
assert.equal(
  lateRunningHostGameStartedCalls,
  1,
  'same-running context updates never replay a partially executed handler'
);
assert.equal(lateRunningHostErrors, 1);
lateRunningHostControl.close();
const recoveredRunningHostControl =
  countdownHostBackend.createOfficialLobbyControlFacade();
let recoveredRunningHostGameStartedCalls = 0;
recoveredRunningHostControl.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.type === 'gameStarted') recoveredRunningHostGameStartedCalls += 1;
};
await new Promise(resolve => {
  recoveredRunningHostControl.onopen = resolve;
});
await flush();
assert.equal(
  recoveredRunningHostGameStartedCalls,
  1,
  'recreating the official socket explicitly reconciles current running state'
);
countdownHost.coordinator.updateContext(
  realmValue(countdownHost, {
    isAuthority: true,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[0],
  })
);
await flush();
assert.equal(recoveredRunningHostGameStartedCalls, 1);
recoveredRunningHostControl.close();
countdownGuestControl.close();
const lateRunningGuestControl =
  countdownGuestBackend.createOfficialLobbyControlFacade();
const lateRunningGuestEvents = [];
let lateRunningGuestGameStartedCalls = 0;
let lateRunningGuestErrors = 0;
lateRunningGuestControl.onmessage = event => {
  const message = JSON.parse(event.data);
  lateRunningGuestEvents.push(message);
  if (message.type === 'gameStarted') {
    lateRunningGuestGameStartedCalls += 1;
    if (lateRunningGuestGameStartedCalls === 1) {
      return Promise.reject(new Error('official guest handler rejected after entry'));
    }
  }
};
lateRunningGuestControl.onerror = () => {
  lateRunningGuestErrors += 1;
};
await new Promise(resolve => {
  lateRunningGuestControl.onopen = resolve;
});
await flush();
await flush();
assert.equal(lateRunningGuestGameStartedCalls, 1);
assert.equal(lateRunningGuestErrors, 1);
assert.equal(
  lateRunningGuestEvents.filter(event => event.type === 'gameStarted').length,
  1
);
countdownGuest.coordinator.updateContext(
  realmValue(countdownGuest, {
    isAuthority: false,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[1],
  })
);
for (let index = 0; index < 3; index += 1) await flush();
assert.equal(
  lateRunningGuestGameStartedCalls,
  1,
  'same-running context updates never replay a rejected gameStarted handler'
);
assert.equal(lateRunningGuestErrors, 1);
assert.equal(
  lateRunningGuestEvents.filter(event => event.type === 'gameStarted').length,
  1
);
lateRunningGuestControl.close();
const recoveredRunningGuestControl =
  countdownGuestBackend.createOfficialLobbyControlFacade();
const recoveredRunningGuestEvents = [];
recoveredRunningGuestControl.onmessage = event => {
  recoveredRunningGuestEvents.push(JSON.parse(event.data));
};
await new Promise(resolve => {
  recoveredRunningGuestControl.onopen = resolve;
});
for (let index = 0; index < 3; index += 1) await flush();
assert.equal(
  recoveredRunningGuestEvents.filter(event => event.type === 'gameStarted').length,
  1
);
countdownGuest.coordinator.updateContext(
  realmValue(countdownGuest, {
    isAuthority: false,
    authorityPeerId: 'authority',
    currentSession: runningCountdownSession,
    currentPlayer: runningCountdownSession.players[1],
  })
);
await flush();
assert.equal(
  recoveredRunningGuestEvents.filter(event => event.type === 'gameStarted').length,
  1
);
recoveredRunningGuestControl.close();
for (const page of countdownPages) page.coordinator.dispose();
assert.equal(countdownBus.records.get('countdown-host').unsubscribeCount, 1);
assert.equal(countdownBus.records.get('countdown-guest').unsubscribeCount, 1);

lobbyHost.coordinator.dispose();

for (const page of pages) page.coordinator.dispose();
assert.equal(bus.records.get('host-1').unsubscribeCount, 1);
assert.equal(bus.records.get('guest-1').unsubscribeCount, 1);
assert.equal(bus.records.get('host-1').closeCount, 0);
assert.equal(bus.records.get('guest-1').closeCount, 0);
assert.equal(host.calls.finish, 0, 'logical leave never finishes Playmesh session');
assert.equal(guest.calls.finish, 0, 'logical leave never finishes Playmesh session');

console.log('GDevelop Playmesh private multiplayer seam tests passed.');
