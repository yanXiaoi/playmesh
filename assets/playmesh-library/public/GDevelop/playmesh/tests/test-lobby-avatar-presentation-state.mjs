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
const LOCAL_PROTOCOL = 'playmesh.gdevelop.local-frame.v1';
const MULTIPLAYER_PROTOCOL = 'playmesh.gdevelop.multiplayer.v1';

const png = suffix =>
  Uint8Array.from([
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...suffix,
  ]);
const hostPng = png([1]);
const player2Png = png([2]);
const player2ChangedPng = png([22]);
const player3Png = png([3]);

const avatarDataUrl = bytes =>
  `data:image/png;base64,${Buffer.from(bytes).toString('base64')}`;

const assets = new Map([
  ['/bucket/_sys-user-avatars/host.png', hostPng],
  ['/bucket/_sys-user-avatars/player-2.png', player2Png],
  ['/bucket/_sys-user-avatars/player-3.png', player3Png],
]);
const fetches = [];
let slowAvatar = null;

const responseFor = bytes => ({
  ok: true,
  headers: {
    get(name) {
      if (name === 'content-type') return 'image/png';
      if (name === 'content-length') return String(bytes.byteLength);
      return null;
    },
  },
  async arrayBuffer() {
    return bytes.slice().buffer;
  },
});

const fetchAvatar = url => {
  const parsed = new URL(url);
  fetches.push(parsed.pathname);
  if (parsed.pathname === '/bucket/_sys-user-avatars/slow.png') {
    return new Promise(resolve => {
      slowAvatar = { resolve };
    });
  }
  const bytes = assets.get(parsed.pathname);
  return Promise.resolve(bytes ? responseFor(bytes) : { ok: false });
};

const context = vm.createContext({
  console: { error() {}, warn() {}, info() {}, log() {} },
  TextEncoder,
  TextDecoder,
  Uint8Array,
  DataView,
  Promise,
  Date,
  URL,
  Blob,
  AbortController,
  location: { origin: 'https://playmesh.test' },
  crypto: {
    getRandomValues: webcrypto.getRandomValues.bind(webcrypto),
    subtle: {
      async digest(_algorithm, input) {
        const source = new Uint8Array(
          input.buffer,
          input.byteOffset,
          input.byteLength
        );
        const digest = new Uint8Array(32);
        digest.fill(source.at(-1));
        return digest.buffer;
      },
    },
  },
  fetch: fetchAvatar,
  btoa: value => Buffer.from(value, 'binary').toString('base64'),
  createImageBitmap: async () => ({ width: 32, height: 32, close() {} }),
  setTimeout,
  clearTimeout,
});
vm.runInContext(bridgeSource, context, {
  filename: 'gdevelop-multiplayer-bridge.js',
});

const page = { context };
const realm = value => {
  page.context.__avatarFixture = JSON.stringify(value);
  const result = vm.runInContext('JSON.parse(__avatarFixture)', page.context);
  delete page.context.__avatarFixture;
  return result;
};
const clone = value => JSON.parse(JSON.stringify(value));
const settle = async () => {
  for (let index = 0; index < 8; index += 1) {
    await Promise.resolve();
  }
  await new Promise(resolve => setTimeout(resolve, 0));
};

let session = {
  id: 'avatar-session',
  state: 'lobby',
  authorityClientId: 'host',
  minPlayers: 1,
  maxPlayers: 8,
  players: [
    {
      id: 'host',
      nickname: 'Host',
      role: 'authority',
      connected: true,
      avatar: '/bucket/_sys-user-avatars/host.png',
    },
    {
      id: 'player-2',
      nickname: 'Player Two',
      role: 'player',
      connected: true,
      avatar: '/bucket/_sys-user-avatars/player-2.png',
    },
    {
      id: 'player-3',
      nickname: 'Player Three',
      role: 'player',
      connected: true,
      avatar: '/bucket/_sys-user-avatars/player-3.png',
    },
  ],
};

const main = {
  ready: Promise.resolve(),
  session: {
    isAuthority: () => false,
    getCurrent: () => session,
    start: async () => session,
    finish: async () => session,
  },
  player: { getCurrent: () => session.players[2] },
};
const coordinator = context[COORDINATOR_SYMBOL];
coordinator.attachRuntime(main);

const updateSession = nextSession => {
  session = nextSession;
  coordinator.updateContext(
    realm({
      isAuthority: false,
      authorityPeerId: 'authority',
      currentSession: nextSession,
      currentPlayer:
        nextSession.players.find(player => player.id === 'player-3') || null,
    })
  );
};
updateSession(session);
coordinator.applyPlayerNumberSnapshot(
  realm({
    type: 'playerNumbers.snapshot',
    protocol: MULTIPLAYER_PROTOCOL,
    version: 1,
    sessionId: session.id,
    epoch: 1,
    revision: 1,
    assignments: [
      { playerId: 'host', playerNumber: 1 },
      { playerId: 'player-2', playerNumber: 2 },
      { playerId: 'player-3', playerNumber: 3 },
    ],
    errorCode: null,
  })
);

const backend = context[REGISTRY_SYMBOL].negotiate(
  realm({
    engine: 'gdevelop',
    engineVersion: '5.6.276',
    feature: 'multiplayer',
    minVersion: 1,
    maxVersion: 1,
  })
);

const createFrame = () => {
  const posted = [];
  const contentWindow = {
    postMessage(message, targetOrigin) {
      posted.push({ message, targetOrigin });
    },
  };
  return {
    posted,
    contentWindow,
    frame: {
      contentWindow,
      srcdoc: '',
      setAttribute() {},
      removeAttribute() {},
    },
  };
};

const capabilityOf = frame => {
  const match = frame.frame.srcdoc.match(/const capability="([0-9a-f]{64})"/);
  assert.ok(match, 'local lobby frame has an unguessable capability');
  return match[1];
};

const localAction = (frame, nonce, sequence, action) =>
  backend.consumeOfficialLobbyFrameMessage({
    source: frame.contentWindow,
    data: realm({
      protocol: LOCAL_PROTOCOL,
      version: 1,
      kind: 'lobby',
      nonce,
      sequence,
      action,
      payload:
        action === 'ready' || action === 'hostMenuToggle'
          ? {}
          : { requestId: `avatar-${sequence}-${action}` },
    }),
  });

const postOfficial = (frame, message) => {
  assert.equal(
    backend.postOfficialLobbyFrameMessage(frame.frame, realm(message)),
    true
  );
  const posted = [...frame.posted]
    .reverse()
    .find(entry => entry.message.event === message.id);
  assert.ok(posted, `frame received ${message.id}`);
  return clone(posted.message);
};

const lastEvent = (frame, event) => {
  const match = [...frame.posted]
    .reverse()
    .find(entry => entry.message.event === event);
  assert.ok(match, `frame received ${event}`);
  return clone(match.message);
};

const frame = createFrame();
backend.configureOfficialLobbyFrame(frame.frame);
const nonce = capabilityOf(frame);
assert.deepEqual(clone(localAction(frame, nonce, 1, 'ready')), {
  data: { id: 'lobbiesListenerReady' },
});

const initial = postOfficial(frame, {
  id: 'sessionInformation',
  isCordova: false,
  devicePlatform: '',
  navigatorPlatform: 'Win32',
  hasTouch: false,
});
assert.deepEqual(
  initial.payload.players.map(player => player.avatarDataUrl),
  [null, null, null],
  'the synchronous session snapshot starts with safe placeholders'
);
await settle();
const firstVisual = lastEvent(frame, 'playersVisualUpdated');
assert.deepEqual(
  firstVisual.payload.players.map(player => player.avatarDataUrl),
  [avatarDataUrl(hostPng), avatarDataUrl(player2Png), avatarDataUrl(player3Png)],
  'all three independently verified avatars are presented asynchronously'
);

assert.deepEqual(clone(localAction(frame, nonce, 2, 'joinCurrentSession')), {
  data: { id: 'joinLobby', lobbyId: session.id },
});
const joined = postOfficial(frame, {
  id: 'lobbyJoined',
  lobbyId: session.id,
  playerId: 'player-3',
  playerToken: 'opaque-player-token',
  connectionId: 'opaque-connection-id',
  positionInLobby: 3,
});
assert.deepEqual(
  joined.payload.players.map(player => player.avatarDataUrl),
  firstVisual.payload.players.map(player => player.avatarDataUrl),
  'lobbyJoined reuses the authoritative verified presentations instead of nulls'
);
await settle();

// A profile path can arrive after the lobby is already visible (for example
// after the host finishes the App SDK avatar commit). The coordinator update
// itself must refresh the active frame; no later official lobby message is
// required to kick the fetch pipeline.
session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'player-3' ? { ...player, avatar: null } : player
  ),
};
updateSession(session);
await settle();
assert.equal(
  lastEvent(frame, 'playersVisualUpdated').payload.players.find(
    player => player.number === 3
  ).avatarDataUrl,
  null
);
const player3FetchesBeforeRestore = fetches.filter(
  path => path === '/bucket/_sys-user-avatars/player-3.png'
).length;
session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'player-3'
      ? { ...player, avatar: '/bucket/_sys-user-avatars/player-3.png' }
      : player
  ),
};
updateSession(session);
await settle();
assert.equal(
  fetches.filter(
    path => path === '/bucket/_sys-user-avatars/player-3.png'
  ).length,
  player3FetchesBeforeRestore + 1,
  'the newly published avatar source is verified exactly once'
);
assert.equal(
  lastEvent(frame, 'playersVisualUpdated').payload.players.find(
    player => player.number === 3
  ).avatarDataUrl,
  avatarDataUrl(player3Png)
);

assets.set('/bucket/_sys-user-avatars/player-2.png', player2ChangedPng);
session = {
  ...session,
  authorityClientId: 'player-2',
  players: session.players.map(player =>
    player.id === 'host'
      ? { ...player, nickname: 'Former Host', connected: false }
      : player
  ),
};
updateSession(session);
const migrated = postOfficial(frame, {
  id: 'lobbyUpdated',
  positionInLobby: 3,
});
assert.deepEqual(
  migrated.payload.players.map(player => ({
    number: player.number,
    nickname: player.nickname,
    connected: player.connected,
    isAuthority: player.isAuthority,
    avatarDataUrl: player.avatarDataUrl,
  })),
  [
    {
      number: 1,
      nickname: 'Former Host',
      connected: false,
      isAuthority: false,
      avatarDataUrl: avatarDataUrl(hostPng),
    },
    {
      number: 2,
      nickname: 'Player Two',
      connected: true,
      isAuthority: true,
      avatarDataUrl: avatarDataUrl(player2Png),
    },
    {
      number: 3,
      nickname: 'Player Three',
      connected: true,
      isAuthority: false,
      avatarDataUrl: avatarDataUrl(player3Png),
    },
  ],
  'ordinary state fields update without erasing any verified avatar'
);
await settle();
assert.equal(
  lastEvent(frame, 'playersVisualUpdated').payload.players[1].avatarDataUrl,
  avatarDataUrl(player2ChangedPng),
  'same-path content digest changes are refetched and replace only that avatar'
);

session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'player-3'
      ? {
          ...player,
          avatar: '/bucket/_sys-user-avatars/missing.png',
        }
      : player
  ),
};
updateSession(session);
const failedPlayer = postOfficial(frame, {
  id: 'lobbyUpdated',
  positionInLobby: 3,
});
assert.deepEqual(
  failedPlayer.payload.players.map(player => player.avatarDataUrl),
  [avatarDataUrl(hostPng), avatarDataUrl(player2ChangedPng), null],
  'a changed path falls back only for that player while verification is pending'
);
await settle();
assert.deepEqual(
  lastEvent(frame, 'playersVisualUpdated').payload.players
    .slice(0, 2)
    .map(player => player.avatarDataUrl),
  [avatarDataUrl(hostPng), avatarDataUrl(player2ChangedPng)],
  'one failed avatar fetch cannot clear other players presentations'
);

session = {
  ...session,
  players: session.players.filter(player => player.id !== 'player-2'),
};
updateSession(session);
const departed = postOfficial(frame, {
  id: 'lobbyUpdated',
  positionInLobby: 3,
});
assert.deepEqual(
  departed.payload.players.map(player => player.number),
  [1, 3],
  'a departed player is removed without disturbing stable numbers'
);

session = {
  ...session,
  players: [
    session.players[0],
    {
      id: 'player-2',
      nickname: 'Player Two Reconnected',
      role: 'authority',
      connected: true,
      avatar: '/bucket/_sys-user-avatars/player-2.png',
    },
    session.players[1],
  ],
};
updateSession(session);
const reconnected = postOfficial(frame, {
  id: 'lobbyUpdated',
  positionInLobby: 3,
});
assert.equal(
  reconnected.payload.players.find(player => player.number === 2).avatarDataUrl,
  null,
  'a reconnected player does not inherit a presentation removed on departure'
);
await settle();
assert.equal(
  lastEvent(frame, 'playersVisualUpdated').payload.players.find(
    player => player.number === 2
  ).avatarDataUrl,
  avatarDataUrl(player2ChangedPng),
  'the reconnected stable player number receives a newly verified presentation'
);

session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'host'
      ? { ...player, avatar: '/bucket/_sys-user-avatars/slow.png' }
      : player
  ),
};
updateSession(session);
postOfficial(frame, { id: 'lobbyUpdated', positionInLobby: 3 });
assert.ok(slowAvatar, 'a slow avatar verification is in flight');
const oldFrameMessageCount = frame.posted.length;
const replacement = createFrame();
backend.configureOfficialLobbyFrame(replacement.frame);
slowAvatar.resolve(responseFor(hostPng));
await settle();
assert.equal(
  frame.posted.length,
  oldFrameMessageCount,
  'destroying/replacing a frame aborts its authority map and suppresses stale writes'
);

const forgedAvatar = `data:image/png;base64,${Buffer.from('forged').toString(
  'base64'
)}`;
session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'host'
      ? { ...player, avatar: '/bucket/_sys-user-avatars/host.png' }
      : player.id === 'player-3'
        ? { ...player, avatar: forgedAvatar }
        : player
  ),
};
updateSession(session);
const replacementNonce = capabilityOf(replacement);
localAction(replacement, replacementNonce, 1, 'ready');
const fetchCountBeforeForged = fetches.length;
postOfficial(replacement, {
  id: 'sessionInformation',
  isCordova: false,
  devicePlatform: '',
  navigatorPlatform: 'Win32',
  hasTouch: false,
});
await settle();
const forgedVisual = lastEvent(replacement, 'playersVisualUpdated');
assert.equal(
  forgedVisual.payload.players.find(player => player.number === 3).avatarDataUrl,
  null,
  'an untrusted data URL is never accepted as an avatar presentation'
);
assert.equal(
  fetches.slice(fetchCountBeforeForged).includes(forgedAvatar),
  false,
  'the forged data URL is not fetched either'
);

localAction(replacement, replacementNonce, 2, 'joinCurrentSession');
postOfficial(replacement, {
  id: 'lobbyJoined',
  lobbyId: session.id,
  playerId: 'player-3',
  playerToken: 'replacement-player-token',
  connectionId: 'replacement-connection-id',
  positionInLobby: 3,
});
await settle();
slowAvatar = null;
session = {
  ...session,
  players: session.players.map(player =>
    player.id === 'host'
      ? { ...player, avatar: '/bucket/_sys-user-avatars/slow.png' }
      : player
  ),
};
updateSession(session);
postOfficial(replacement, { id: 'lobbyUpdated', positionInLobby: 3 });
assert.ok(slowAvatar, 'the current frame has a session-scoped avatar request');
const beforeSessionChange = replacement.posted.length;
const nextSession = { ...session, id: 'next-avatar-session' };
updateSession(nextSession);
slowAvatar.resolve(responseFor(hostPng));
await settle();
assert.equal(
  replacement.posted.length,
  beforeSessionChange,
  'changing session clears its presentation map and rejects old async writes'
);

console.log('GDevelop lobby avatar presentation state contract passed.');
