import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const bridgeSource = await readFile(
  new URL(
    '../assets/playmesh-library/public/developer/gdevelop-multiplayer-bridge.js',
    import.meta.url
  ),
  'utf8'
);
assert.doesNotMatch(
  bridgeSource,
  /playmeshGDevelopAuthorityBootstrap|MULTIPLAYER_LIFECYCLE_(?:ONLINE|SOFT_SOLO|RECONNECTING)/,
  'production bridge must not own bootstrap install/dispose or a reconnect lifecycle'
);

const closeControl = {
  click() {
    context.closeClicks += 1;
  },
};
const lobbyRoot = {
  contains(frame) {
    return frame === context.currentLobbyFrame;
  },
  querySelector(selector) {
    return selector === '#lobbies-close-container' ? closeControl : null;
  },
};
const context = vm.createContext({
  AbortController,
  ArrayBuffer,
  Blob,
  DataView,
  Map,
  MessageEvent,
  Promise,
  Set,
  Symbol,
  TextDecoder,
  TextEncoder,
  Uint8Array,
  URL,
  clearInterval,
  clearTimeout,
  console,
  crypto: webcrypto,
  document: {
    getElementById(id) {
      return id === 'lobbies-root-container' ? lobbyRoot : null;
    },
  },
  navigator: { language: 'zh-CN' },
  setInterval,
  setTimeout,
});
context.globalThis = context;
context.closeClicks = 0;
context.currentLobbyFrame = null;

vm.runInContext(bridgeSource, context, {
  filename: 'gdevelop-multiplayer-bridge-soft-leave.js',
});

vm.runInContext(
  `
  const coordinatorSymbol = Symbol.for(
    'playmesh.gdevelop.multiplayer.coordinator.v1'
  );
  const registrySymbol = Symbol.for('playmesh.runtime.backends.v1');
  const coordinator = globalThis[coordinatorSymbol];
  const registry = globalThis[registrySymbol];
  const counters = {
    bootstrapInstall: 0,
    bootstrapDispose: 0,
    sessionStart: 0,
    sessionFinish: 0,
    sessionLeave: 0,
    driverDisconnect: 0,
    channelSubscribe: 0,
    channelUnsubscribe: 0,
    channelClose: 0,
  };

  const sessions = {
    first: {
      id: 'session-soft-leave-a',
      state: 'lobby',
      authorityClientId: 'authority-player',
      minPlayers: 1,
      maxPlayers: 8,
      players: [
        {
          id: 'authority-player',
          nickname: 'Host A',
          role: 'authority',
          connected: true,
          avatar: null,
        },
        {
          id: 'guest-player',
          nickname: 'Guest A',
          role: 'player',
          connected: true,
          avatar: null,
        },
      ],
    },
    second: {
      id: 'session-soft-leave-b',
      state: 'lobby',
      authorityClientId: 'authority-player',
      minPlayers: 1,
      maxPlayers: 8,
      players: [
        {
          id: 'authority-player',
          nickname: 'Host B',
          role: 'authority',
          connected: true,
          avatar: null,
        },
      ],
    },
  };
  let currentSession = sessions.first;
  let currentPlayer = currentSession.players[0];
  const runtimeMain = {
    ready: Promise.resolve(),
    session: {
      isAuthority: () => true,
      getCurrent: () => currentSession,
      start: async () => {
        counters.sessionStart += 1;
      },
      finish: async () => {
        counters.sessionFinish += 1;
      },
      leave: async () => {
        counters.sessionLeave += 1;
      },
    },
    player: { getCurrent: () => currentPlayer },
    driver: {
      disconnect() {
        counters.driverDisconnect += 1;
      },
    },
  };
  globalThis.playmesh = { main: runtimeMain };

  const channel = {
    id: 'persistent-app-owned-binary-channel',
    send: async () => {},
    onMessage: () => {
      counters.channelSubscribe += 1;
      let active = true;
      return () => {
        if (!active) return;
        active = false;
        counters.channelUnsubscribe += 1;
      };
    },
    close: async () => {
      counters.channelClose += 1;
    },
  };

  const bootstrap = Object.freeze({
    protocol: 'playmesh.gdevelop.multiplayer.v1',
    version: 1,
    install() {
      counters.bootstrapInstall += 1;
      return Promise.resolve();
    },
    dispose() {
      counters.bootstrapDispose += 1;
      return Promise.resolve();
    },
    installed: true,
  });
  Object.defineProperty(globalThis, 'playmeshGDevelopAuthorityBootstrap', {
    value: bootstrap,
    configurable: false,
    enumerable: false,
    writable: false,
  });

  const applySession = session => {
    currentSession = session;
    currentPlayer = session ? session.players[0] : null;
    coordinator.updateContext({
      isAuthority: true,
      authorityPeerId: 'authority',
      currentSession,
      currentPlayer,
    });
    if (session) {
      coordinator.applyPlayerNumberSnapshot({
        type: 'playerNumbers.snapshot',
        protocol: 'playmesh.gdevelop.multiplayer.v1',
        version: 1,
        sessionId: session.id,
        epoch: session === sessions.first ? 1 : 2,
        revision: 1,
        assignments: session.players.map((player, index) => ({
          playerId: player.id,
          playerNumber: index + 1,
        })),
        errorCode: null,
      });
    }
  };

  coordinator.attachRuntime(runtimeMain);
  applySession(currentSession);
  coordinator.attachChannel(channel);

  globalThis.__softLeaveHarness = {
    bootstrap,
    channel,
    coordinator,
    runtimeMain,
    facade: registry.negotiate({
      engine: 'gdevelop',
      engineVersion: '5.6.276',
      feature: 'multiplayer',
      minVersion: 1,
      maxVersion: 1,
    }),
    applyFirstSession() {
      applySession(sessions.first);
    },
    applySecondSession() {
      applySession(sessions.second);
    },
    disconnectAppSession() {
      applySession(null);
    },
    currentSessionId() {
      return currentSession && currentSession.id;
    },
    currentSession() {
      return currentSession;
    },
    snapshot() {
      return { ...counters };
    },
  };
  `,
  context,
  { filename: 'soft-leave-harness.js' }
);

const harness = context.__softLeaveHarness;
const snapshot = () => JSON.parse(JSON.stringify(harness.snapshot()));
const flush = async (turns = 8) => {
  for (let index = 0; index < turns; index += 1) {
    await new Promise(resolve => setTimeout(resolve, 0));
  }
};
const waitFor = async (predicate, label) => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await flush(1);
  }
  assert.fail('Timed out waiting for ' + label);
};
const openLobbySocket = async () => {
  context.__openedSocket = null;
  vm.runInContext(
    '__openedSocket = __softLeaveHarness.facade.createOfficialLobbyControlFacade()',
    context
  );
  const socket = context.__openedSocket;
  await waitFor(() => socket.readyState !== 0, 'lobby control socket');
  return socket;
};
const createLobbyFrame = () => {
  const messages = [];
  const source = { postMessage: message => messages.push(message) };
  const attributes = new Map();
  const frame = {
    contentWindow: source,
    removed: false,
    remove() {
      frame.removed = true;
    },
    removeAttribute(name) {
      attributes.delete(name);
    },
    setAttribute(name, value) {
      attributes.set(name, value);
    },
    srcdoc: '',
  };
  context.currentLobbyFrame = frame;
  context.__frame = frame;
  vm.runInContext(
    '__softLeaveHarness.facade.configureOfficialLobbyFrame(__frame)',
    context
  );
  const match = frame.srcdoc.match(/const capability="([a-f0-9]{64})"/);
  assert.ok(match, 'opaque lobby frame receives a fresh capability');
  return { frame, messages, source, capability: match[1] };
};
const sendFrameAction = (frameState, sequence, action) => {
  context.__frameSource = frameState.source;
  context.__frameCapability = frameState.capability;
  context.__frameSequence = sequence;
  context.__frameAction = action;
  context.__framePayloadJson = JSON.stringify(
    action === 'ready' || action === 'hostMenuToggle'
      ? {}
      : { requestId: `soft-leave-${sequence}-${action}` }
  );
  if (action !== 'ready' && action !== 'hostMenuToggle') {
    context.__officialFrameData = null;
    vm.runInContext(
      `__softLeaveHarness.facade.handleOfficialLobbyFrameMessage({
        source: __frameSource,
        data: {
          protocol: 'playmesh.gdevelop.local-frame.v1',
          version: 1,
          kind: 'lobby',
          nonce: __frameCapability,
          sequence: __frameSequence,
          action: __frameAction,
          payload: JSON.parse(__framePayloadJson),
        },
      }, receivedEvent => {
        __officialFrameData = receivedEvent.data;
      })`,
      context
    );
    return { data: context.__officialFrameData };
  }
  return vm.runInContext(
    `__softLeaveHarness.facade.consumeOfficialLobbyFrameMessage({
      source: __frameSource,
      data: {
        protocol: 'playmesh.gdevelop.local-frame.v1',
        version: 1,
        kind: 'lobby',
        nonce: __frameCapability,
        sequence: __frameSequence,
        action: __frameAction,
        payload: JSON.parse(__framePayloadJson),
      },
    })`,
    context
  );
};
const sendSessionInformation = frameState => {
  context.__frame = frameState.frame;
  return vm.runInContext(
    `__softLeaveHarness.facade.postOfficialLobbyFrameMessage(__frame, {
      id: 'sessionInformation',
      isCordova: false,
      devicePlatform: '',
      navigatorPlatform: 'test',
      hasTouch: false,
    })`,
    context
  );
};
const openLobbyFrame = () => {
  const frameState = createLobbyFrame();
  assert.equal(
    sendFrameAction(frameState, 1, 'ready').data.id,
    'lobbiesListenerReady'
  );
  assert.equal(sendSessionInformation(frameState), true);
  return frameState;
};
const switchFrameToSolo = async frameState => {
  assert.equal(
    sendFrameAction(frameState, 2, 'switchToSolo').data.id,
    'leaveLobby'
  );
  await flush();
};

const originalCoordinator = harness.coordinator;
const originalRuntimeMain = harness.runtimeMain;
const originalChannel = harness.channel;
const originalSession = harness.currentSession();
assert.deepEqual(snapshot(), {
  bootstrapInstall: 0,
  bootstrapDispose: 0,
  sessionStart: 0,
  sessionFinish: 0,
  sessionLeave: 0,
  driverDisconnect: 0,
  channelSubscribe: 1,
  channelUnsubscribe: 0,
  channelClose: 0,
});

const firstSocket = await openLobbySocket();
assert.equal(firstSocket.readyState, 1);
const firstPeer = harness.facade.createOfficialPeer();
const firstFrame = openLobbyFrame();
await switchFrameToSolo(firstFrame);
assert.equal(firstSocket.readyState, 3, 'GDevelop lobby socket is closed');
assert.equal(context.closeClicks, 1, 'official close callback owns DOM teardown');
assert.equal(
  sendFrameAction(firstFrame, 3, 'hostMenuToggle'),
  null,
  'dismissed iframe capability is invalidated'
);
assert.strictEqual(harness.coordinator, originalCoordinator);
assert.strictEqual(harness.runtimeMain, originalRuntimeMain);
assert.strictEqual(harness.channel, originalChannel);
assert.strictEqual(harness.currentSession(), originalSession);
assert.deepEqual(snapshot(), {
  bootstrapInstall: 0,
  bootstrapDispose: 0,
  sessionStart: 0,
  sessionFinish: 0,
  sessionLeave: 0,
  driverDisconnect: 0,
  channelSubscribe: 1,
  channelUnsubscribe: 0,
  channelClose: 0,
});

// App-owned session snapshots continue advancing while the lobby UI is absent.
harness.applySecondSession();
assert.equal(harness.currentSessionId(), 'session-soft-leave-b');
const secondSocket = await openLobbySocket();
assert.equal(secondSocket.readyState, 1, 'warm open does not reconnect/install');
const secondPeer = harness.facade.createOfficialPeer();
assert.notStrictEqual(secondPeer, firstPeer, 'GDevelop peer façade is rebuilt');
const secondFrame = openLobbyFrame();
assert.equal(
  secondFrame.messages.at(-1).payload.sessionId,
  'session-soft-leave-b',
  'reopened lobby follows the latest App session snapshot'
);
await switchFrameToSolo(secondFrame);
assert.equal(secondSocket.readyState, 3);

// Repeated opens remain immediate and never duplicate the persistent Binary
// subscription or invoke bootstrap/session/driver teardown.
for (let cycle = 0; cycle < 3; cycle += 1) {
  const socketA = await openLobbySocket();
  const socketB = await openLobbySocket();
  const frame = openLobbyFrame();
  await switchFrameToSolo(frame);
  assert.equal(socketA.readyState, 3);
  assert.equal(socketB.readyState, 3);
}
assert.equal(context.closeClicks, 5);
assert.deepEqual(snapshot(), {
  bootstrapInstall: 0,
  bootstrapDispose: 0,
  sessionStart: 0,
  sessionFinish: 0,
  sessionLeave: 0,
  driverDisconnect: 0,
  channelSubscribe: 1,
  channelUnsubscribe: 0,
  channelClose: 0,
});

// A missing App session closes only this attempted façade with a retryable
// NO_SESSION status. Restoring an App snapshot makes the next official open
// immediately usable without bootstrap.install().
harness.disconnectAppSession();
context.__retrySocket = null;
vm.runInContext(
  '__retrySocket = __softLeaveHarness.facade.createOfficialLobbyControlFacade()',
  context
);
const unavailableSocket = context.__retrySocket;
let unavailableError = null;
unavailableSocket.onerror = error => {
  unavailableError = error;
};
await waitFor(() => unavailableSocket.readyState === 3, 'retryable no-session state');
assert.equal(unavailableError?.code, 'PLAYMESH_GDEVELOP_NO_SESSION');
assert.deepEqual(snapshot(), {
  bootstrapInstall: 0,
  bootstrapDispose: 0,
  sessionStart: 0,
  sessionFinish: 0,
  sessionLeave: 0,
  driverDisconnect: 0,
  channelSubscribe: 1,
  channelUnsubscribe: 0,
  channelClose: 0,
});

harness.applyFirstSession();
const recoveredSocket = await openLobbySocket();
assert.equal(recoveredSocket.readyState, 1);
const recoveredFrame = openLobbyFrame();
assert.equal(
  recoveredFrame.messages.at(-1).payload.sessionId,
  'session-soft-leave-a'
);
recoveredSocket.close();

process.stdout.write(
  'GDevelop soft-leave contract passed: App session/coordinator/channel stay owned and connected; local lobby façade/frame can be rebuilt and retried.\n'
);
