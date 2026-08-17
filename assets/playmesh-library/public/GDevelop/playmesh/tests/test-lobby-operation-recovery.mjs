import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('../../../developer/gdevelop-multiplayer-bridge.js', import.meta.url),
  'utf8'
);
const REGISTRY = Symbol.for('playmesh.runtime.backends.v1');
const COORDINATOR = Symbol.for(
  'playmesh.gdevelop.multiplayer.coordinator.v1'
);
const APP = Symbol.for('playmesh.app.internal.v1');

const realm = (page, value) => {
  page.context.__json = JSON.stringify(value);
  const result = vm.runInContext('JSON.parse(__json)', page.context);
  delete page.context.__json;
  return result;
};

const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise(resolve => setTimeout(resolve, 0));
};

const createPage = ({
  authority,
  state = 'lobby',
  minPlayers = 1,
  timers,
  startImpl,
}) => {
  const playerId = authority ? 'host' : 'guest';
  const session = {
    id: `operation-${playerId}`,
    state,
    authorityClientId: 'host',
    minPlayers,
    maxPlayers: 8,
    players: [
      {
        id: 'host',
        nickname: 'Host',
        role: 'authority',
        connected: true,
        avatar: null,
      },
      ...(authority
        ? []
        : [
            {
              id: 'guest',
              nickname: 'Guest',
              role: 'player',
              connected: true,
              avatar: null,
            },
          ]),
    ],
  };
  let menuCalls = 0;
  const context = vm.createContext({
    console: { error() {}, warn() {}, info() {}, log() {} },
    TextEncoder,
    TextDecoder,
    Uint8Array,
    DataView,
    Promise,
    Date,
    crypto: webcrypto,
    setTimeout: timers?.setTimeout || setTimeout,
    clearTimeout: timers?.clearTimeout || clearTimeout,
  });
  context[APP] = { handleNativeBack: () => (++menuCalls, true) };
  vm.runInContext(source, context, {
    filename: 'gdevelop-multiplayer-bridge.js',
  });
  const page = { context, session, authority, playerId };
  const currentPlayer = session.players.find(player => player.id === playerId);
  const main = {
    ready: Promise.resolve(),
    session: {
      isAuthority: () => authority,
      getCurrent: () => realm(page, session),
      start: () =>
        startImpl ? startImpl() : Promise.resolve(realm(page, session)),
      finish: async () => realm(page, session),
    },
    player: { getCurrent: () => realm(page, currentPlayer) },
  };
  page.coordinator = context[COORDINATOR];
  page.coordinator.attachRuntime(main);
  page.coordinator.updateContext(
    realm(page, {
      isAuthority: authority,
      authorityPeerId: 'authority',
      currentSession: session,
      currentPlayer,
    })
  );
  page.coordinator.applyPlayerNumberSnapshot(
    realm(page, {
      type: 'playerNumbers.snapshot',
      protocol: 'playmesh.gdevelop.multiplayer.v1',
      version: 1,
      sessionId: session.id,
      epoch: 1,
      revision: 1,
      assignments: session.players.map((player, index) => ({
        playerId: player.id,
        playerNumber: index + 1,
      })),
      errorCode: null,
    })
  );
  page.coordinator.attachChannel({
    id: `operation-channel-${playerId}`,
    send: async () => {},
    onMessage: () => () => {},
  });
  page.backend = context[REGISTRY].negotiate(
    realm(page, {
      engine: 'gdevelop',
      engineVersion: '5.6.276',
      feature: 'multiplayer',
      minVersion: 1,
      maxVersion: 1,
    })
  );
  page.menuCalls = () => menuCalls;
  return page;
};

const createFrame = page => {
  const posted = [];
  const contentWindow = {
    postMessage(message) {
      posted.push(JSON.parse(JSON.stringify(message)));
    },
  };
  const frame = {
    contentWindow,
    srcdoc: '',
    setAttribute() {},
    removeAttribute() {},
    remove() {},
  };
  page.backend.configureOfficialLobbyFrame(frame);
  const nonce = frame.srcdoc.match(/const capability="([0-9a-f]{64})"/)[1];
  let sequence = 0;
  const event = (action, payload = {}) => ({
    source: contentWindow,
    data: realm(page, {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      nonce,
      sequence: ++sequence,
      action,
      payload,
    }),
  });
  return { frame, posted, event };
};

const initialiseFrame = (page, frameState) => {
  const ready = page.backend.consumeOfficialLobbyFrameMessage(
    frameState.event('ready')
  );
  assert.equal(ready.data.id, 'lobbiesListenerReady');
  assert.equal(
    page.backend.postOfficialLobbyFrameMessage(
      frameState.frame,
      realm(page, {
        id: 'sessionInformation',
        isCordova: false,
        devicePlatform: '',
        navigatorPlatform: 'test',
        hasTouch: false,
      })
    ),
    true
  );
};

const dispatch = (page, frameState, action, requestId, handler) => {
  let escaped = null;
  try {
    page.backend.handleOfficialLobbyFrameMessage(
      frameState.event(action, { requestId }),
      handler
    );
  } catch (error) {
    escaped = error;
  }
  assert.equal(escaped, null, `${action} failure must not escape to WebView`);
};

const latestFailure = frameState =>
  frameState.posted.filter(message => message.event === 'operationFailed').at(-1);

const authority = createPage({ authority: true, minPlayers: 2 });
const authorityFrame = createFrame(authority);
initialiseFrame(authority, authorityFrame);

// Every official downstream exception is isolated, the exact operation is
// reset, and the same action accepts a fresh requestId immediately.
for (const [index, action] of [
  'joinCurrentSession',
  'leaveLobby',
  'switchToSolo',
].entries()) {
  if (action !== 'joinCurrentSession') {
    // The join below establishes the shared lobby precondition once.
    if (!authorityFrame.posted.some(message => message.event === 'lobbyJoined')) {
      dispatch(authority, authorityFrame, 'joinCurrentSession', 'join-ok', () => {});
      authority.backend.postOfficialLobbyFrameMessage(
        authorityFrame.frame,
        realm(authority, {
          id: 'lobbyJoined',
          lobbyId: authority.session.id,
          playerId: 'host',
          playerToken: 'opaque-test-token',
          connectionId: 'opaque-test-connection',
          positionInLobby: 1,
        })
      );
    }
  }
  dispatch(authority, authorityFrame, action, `failure-${index}-a`, () => {
    throw Object.assign(new Error('secret must not cross the frame'), {
      code: 'INJECTED_CALLBACK_FAILURE',
    });
  });
  assert.equal(latestFailure(authorityFrame).payload.requestId, `failure-${index}-a`);
  assert.equal(JSON.stringify(latestFailure(authorityFrame)).includes('secret'), false);
  dispatch(authority, authorityFrame, action, `failure-${index}-b`, () => {
    throw new Error('retry failure');
  });
  assert.equal(latestFailure(authorityFrame).payload.requestId, `failure-${index}-b`);
}

// Re-establish joined state after the leave/solo failure probes.
dispatch(authority, authorityFrame, 'joinCurrentSession', 'join-final', () => {});
authority.backend.postOfficialLobbyFrameMessage(
  authorityFrame.frame,
  realm(authority, {
    id: 'lobbyJoined',
    lobbyId: authority.session.id,
    playerId: 'host',
    playerToken: 'opaque-test-token-2',
    connectionId: 'opaque-test-connection-2',
    positionInLobby: 1,
  })
);

const lobbySocket = authority.backend.createOfficialLobbyControlFacade();
await new Promise(resolve => {
  lobbySocket.onopen = resolve;
});
dispatch(
  authority,
  authorityFrame,
  'startGameCountdown',
  'start-not-enough-a',
  () =>
    lobbySocket.send(
      JSON.stringify({
        action: 'startGameCountdown',
        connectionType: 'lobby',
      })
    )
);
assert.equal(latestFailure(authorityFrame).payload.code, 'NOT_ENOUGH_PLAYERS');
dispatch(
  authority,
  authorityFrame,
  'startGameCountdown',
  'start-not-enough-b',
  () =>
    lobbySocket.send(
      JSON.stringify({
        action: 'startGameCountdown',
        connectionType: 'lobby',
      })
    )
);
assert.equal(
  latestFailure(authorityFrame).payload.requestId,
  'start-not-enough-b'
);

// A failed business action never blocks the private Escape/menu semantic.
authority.backend.consumeOfficialLobbyFrameMessage(
  authorityFrame.event('hostMenuToggle')
);
assert.equal(authority.menuCalls(), 1);

// The visible Host Start action is the official countdown-preparation action;
// callback failures remain isolated and retryable.
for (const action of ['startGameCountdown']) {
  dispatch(authority, authorityFrame, action, `${action}-callback-a`, () => {
    throw new Error('callback failed');
  });
  dispatch(authority, authorityFrame, action, `${action}-callback-b`, () => {
    throw new Error('callback failed again');
  });
  assert.equal(latestFailure(authorityFrame).payload.requestId, `${action}-callback-b`);
}

const guest = createPage({ authority: false, state: 'running' });
const guestFrame = createFrame(guest);
initialiseFrame(guest, guestFrame);
dispatch(guest, guestFrame, 'joinCurrentSession', 'guest-join', () => {});
guest.backend.postOfficialLobbyFrameMessage(
  guestFrame.frame,
  realm(guest, {
    id: 'lobbyJoined',
    lobbyId: guest.session.id,
    playerId: 'guest',
    playerToken: 'guest-token',
    connectionId: 'guest-connection',
    positionInLobby: 2,
  })
);
dispatch(guest, guestFrame, 'joinGame', 'join-game-a', () => {
  throw new Error('peer callback failed');
});
dispatch(guest, guestFrame, 'joinGame', 'join-game-b', () => {
  throw new Error('peer callback failed again');
});
assert.equal(latestFailure(guestFrame).payload.requestId, 'join-game-b');

// After the observed official countdown handler sends the Host peer id,
// session.start is invoked behind a Promise boundary so both a synchronous
// throw and an asynchronous rejection settle the matching request without an
// unhandled exception, and the next request can retry.
let startAttempt = 0;
const startPage = createPage({
  authority: true,
  startImpl: () => {
    startAttempt += 1;
    if (startAttempt === 1) {
      throw Object.assign(new Error('synchronous start failure'), {
        code: 'INJECTED_START_SYNC',
      });
    }
    return Promise.reject(
      Object.assign(new Error('asynchronous start failure'), {
        code: 'INJECTED_START_ASYNC',
      })
    );
  },
});
const startFrame = createFrame(startPage);
initialiseFrame(startPage, startFrame);
dispatch(startPage, startFrame, 'joinCurrentSession', 'start-join', () => {});
startPage.backend.postOfficialLobbyFrameMessage(
  startFrame.frame,
  realm(startPage, {
    id: 'lobbyJoined',
    lobbyId: startPage.session.id,
    playerId: 'host',
    playerToken: 'start-token',
    connectionId: 'start-connection',
    positionInLobby: 1,
  })
);
startPage.coordinator.attachChannel({
  id: 'start-channel',
  send: async () => {},
  onMessage: () => () => {},
});
const startSocket = startPage.backend.createOfficialLobbyControlFacade();
startSocket.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.type === 'gameCountdownStarted') {
    startSocket.send(
      JSON.stringify({
        action: 'sendPeerId',
        connectionType: 'lobby',
        peerId: 'authority',
      })
    );
  }
};
await new Promise(resolve => {
  startSocket.onopen = resolve;
});
for (const requestId of ['start-sync', 'start-async']) {
  dispatch(startPage, startFrame, 'startGameCountdown', requestId, () =>
    startSocket.send(
      JSON.stringify({
        action: 'startGameCountdown',
        connectionType: 'lobby',
      })
    )
  );
  await flush();
  assert.equal(latestFailure(startFrame).payload.requestId, requestId);
}
assert.equal(startAttempt, 2);

// Parent-owned timeout settles and rolls back a hung operation. A retry with a
// new requestId is then accepted; replacement frames invalidate old timers.
const timeoutJobs = new Map();
let nextTimer = 1;
const timeoutPage = createPage({
  authority: true,
  timers: {
    setTimeout(callback, delay) {
      const id = nextTimer++;
      timeoutJobs.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timeoutJobs.delete(id);
    },
  },
});
const timeoutFrame = createFrame(timeoutPage);
initialiseFrame(timeoutPage, timeoutFrame);
dispatch(timeoutPage, timeoutFrame, 'joinCurrentSession', 'hung-join', () => {});
const timeout = [...timeoutJobs.entries()].find(([, job]) => job.delay === 12000);
assert.ok(timeout, 'a bounded parent operation timeout is scheduled');
timeoutJobs.delete(timeout[0]);
timeout[1].callback();
assert.equal(latestFailure(timeoutFrame).payload.code, 'OPERATION_TIMEOUT');
dispatch(timeoutPage, timeoutFrame, 'joinCurrentSession', 'hung-join-retry', () => {
  throw new Error('retry reached the official handler');
});
assert.equal(latestFailure(timeoutFrame).payload.requestId, 'hung-join-retry');
const oldPostedCount = timeoutFrame.posted.length;
const replacement = createFrame(timeoutPage);
assert.notEqual(replacement.frame.srcdoc, timeoutFrame.frame.srcdoc);
for (const [, job] of [...timeoutJobs]) {
  if (job.delay === 12000) job.callback();
}
assert.equal(timeoutFrame.posted.length, oldPostedCount);

assert.match(source, /operationSucceeded/);
assert.match(source, /operationFailed/);
assert.match(source, /pending\.delete\(payload\.action\)/);
assert.match(source, /received=envelope\.sequence/);

lobbySocket.close();
startSocket.close();
authority.coordinator.dispose();
guest.coordinator.dispose();
startPage.coordinator.dispose();
timeoutPage.coordinator.dispose();
await flush();

console.log('GDevelop lobby operation recovery tests passed.');
