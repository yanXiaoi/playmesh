import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..', '..', '..', '..', '..');
const sourceIndex = process.argv.indexOf('--source');
const sourceRoot =
  sourceIndex === -1 ? null : path.resolve(process.argv[sourceIndex + 1] || '');
if (!sourceRoot) {
  throw new Error(
    'Usage: node test-official-runtime-ui-contracts.mjs --source <patched GDevelop root>'
  );
}

const bridgeSource = await readFile(
  path.join(
    repositoryRoot,
    'assets',
    'playmesh-library',
    'public',
    'developer',
    'gdevelop-multiplayer-bridge.js'
  ),
  'utf8'
);

const transpile = async relativePath => {
  const source = await readFile(path.join(sourceRoot, relativePath), 'utf8');
  return stripTypeScriptTypes(source, {
    mode: 'transform',
    sourceMap: false,
    sourceUrl: relativePath,
  });
};

class FakeElement {
  constructor(document, tagName) {
    this.ownerDocument = document;
    this.tagName = String(tagName).toUpperCase();
    this.style = {};
    this.dataset = {};
    this.attributes = new Map();
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.hidden = false;
    this.textContent = '';
    this.tabIndex = -1;
    this.isConnected = false;
    this.srcdoc = '';
    this.contentWindow =
      this.tagName === 'IFRAME'
        ? {
            postedMessages: [],
            postMessage: (message, targetOrigin) => {
              this.contentWindow.postedMessages.push({ message, targetOrigin });
            },
          }
        : null;
    this._id = '';
  }

  set id(value) {
    this._id = String(value);
  }

  get id() {
    return this._id;
  }

  setAttribute(name, value) {
    this.attributes.set(String(name), String(value));
    if (name === 'id') this.id = value;
  }

  getAttribute(name) {
    return this.attributes.get(String(name)) || null;
  }

  removeAttribute(name) {
    this.attributes.delete(String(name));
  }

  appendChild(child) {
    child.parentNode = this;
    child.isConnected = true;
    this.children.push(child);
    if (child.tagName === 'IFRAME') child.dispatch('load', { target: child });
    return child;
  }

  prepend(child) {
    child.parentNode = this;
    child.isConnected = true;
    this.children.unshift(child);
    return child;
  }

  replaceChild(nextChild, previousChild) {
    const index = this.children.indexOf(previousChild);
    if (index === -1) throw new Error('replaceChild target missing');
    previousChild.parentNode = null;
    previousChild.isConnected = false;
    nextChild.parentNode = this;
    nextChild.isConnected = true;
    this.children[index] = nextChild;
    return previousChild;
  }

  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index === -1) throw new Error('removeChild target missing');
    this.children.splice(index, 1);
    child.parentNode = null;
    child.isConnected = false;
    return child;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  querySelector(selector) {
    if (!selector.startsWith('#')) return null;
    const id = selector.slice(1);
    const visit = element => {
      if (element.id === id) return element;
      for (const child of element.children) {
        const found = visit(child);
        if (found) return found;
      }
      return null;
    };
    return visit(this);
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  dispatch(type, event = {}) {
    for (const listener of this.listeners.get(type) || []) listener(event);
  }

  animate() {
    return { cancel() {} };
  }

  focus() {}
}

class FakeDocument {
  constructor() {
    this.referrer = '';
    this.body = new FakeElement(this, 'body');
    this.documentElement = new FakeElement(this, 'html');
  }

  createElement(tagName) {
    return new FakeElement(this, tagName);
  }

  createTextNode(text) {
    const node = new FakeElement(this, '#text');
    node.textContent = String(text);
    return node;
  }

  getElementById(id) {
    return this.body.querySelector(`#${id}`);
  }
}

const document = new FakeDocument();
const windowListeners = new Map();
const loggerEntries = [];
const runtimeTimeouts = new Set();
const runtimeIntervals = new Set();
const runtimeSetTimeout = (callback, delay, ...args) => {
  const timeoutId = setTimeout(() => {
    runtimeTimeouts.delete(timeoutId);
    callback(...args);
  }, delay);
  timeoutId.unref?.();
  runtimeTimeouts.add(timeoutId);
  return timeoutId;
};
const runtimeClearTimeout = timeoutId => {
  runtimeTimeouts.delete(timeoutId);
  clearTimeout(timeoutId);
};
const runtimeSetInterval = (callback, delay, ...args) => {
  const intervalId = setInterval(callback, delay, ...args);
  intervalId.unref?.();
  runtimeIntervals.add(intervalId);
  return intervalId;
};
const runtimeClearInterval = intervalId => {
  runtimeIntervals.delete(intervalId);
  clearInterval(intervalId);
};
const runtimeSession = {
  id: 'session-official-ui',
  state: 'lobby',
  authorityClientId: 'authority-ui',
  players: [
    {
      id: 'authority-ui',
      nickname: 'Authority UI',
      role: 'authority',
      connected: true,
    },
  ],
  minPlayers: 1,
  maxPlayers: 8,
};
const currentPlayer = runtimeSession.players[0];
let sessionStartCount = 0;
let hostMultiplayerBackend = null;
let hostOfficialPeer = null;
const hostPeerConnections = [];
const hostCompressionMethods = [];
const main = {
  ready: Promise.resolve(),
  gameInfo: {
    getCurrent: () => ({ multiplayer: true }),
  },
  session: {
    isAuthority: () => true,
    getCurrent: () => runtimeSession,
    start: async () => {
      sessionStartCount += 1;
    },
    finish: async () => {},
  },
  player: {
    getCurrent: () => currentPlayer,
  },
};
const domRoot = document.body;
const runtimeGame = {
  isUsingGDevelopDevelopmentEnvironment: () => false,
  isInGameEdition: () => false,
  isPreview: () => true,
  getAdditionalOptions: () => ({ nativeMobileApp: false }),
  getGameData: () => ({ properties: { version: '1.0.0' } }),
  getPlatformInfo: () => ({
    isCordova: false,
    devicePlatform: 'web',
    navigatorPlatform: 'test',
    hasTouch: true,
    supportedCompressionMethods: ['none'],
  }),
  getRenderer: () => ({
    getElectron: () => null,
    getDomElementContainer: () => domRoot,
    getCanvas: () => ({ focus() {} }),
  }),
};
const runtimeScene = { getGame: () => runtimeGame };

const contextGlobal = {
  TextEncoder,
  TextDecoder,
  Uint8Array,
  ArrayBuffer,
  DataView,
  URL,
  URLSearchParams,
  Promise,
  crypto: globalThis.crypto,
  performance,
  document,
  navigator: { platform: 'test' },
  screen: { width: 1280, height: 720 },
  setTimeout: runtimeSetTimeout,
  clearTimeout: runtimeClearTimeout,
  setInterval: runtimeSetInterval,
  clearInterval: runtimeClearInterval,
  fetch: async () => {
    throw new Error('Playmesh official UI test attempted a cloud fetch');
  },
  WebSocket: class ForbiddenWebSocket {
    constructor() {
      throw new Error('Playmesh official UI test attempted a cloud WebSocket');
    }
  },
  console: Object.fromEntries(
    ['log', 'info', 'warn', 'error', 'debug'].map(level => [
      level,
      (...args) => loggerEntries.push({ level, args }),
    ])
  ),
  addTouchAndClickEventListeners(element, listener) {
    element.addEventListener('click', listener);
    element.addEventListener('touchend', listener);
  },
  addEventListener(type, listener) {
    const listeners = windowListeners.get(type) || [];
    listeners.push(listener);
    windowListeners.set(type, listeners);
  },
  removeEventListener(type, listener) {
    const listeners = windowListeners.get(type) || [];
    windowListeners.set(
      type,
      listeners.filter(candidate => candidate !== listener)
    );
  },
  open() {
    throw new Error('Playmesh official UI test attempted window.open');
  },
  parent: null,
  window: null,
  globalThis: null,
  playmesh: { main },
};
contextGlobal.window = contextGlobal;
contextGlobal.globalThis = contextGlobal;
contextGlobal.parent = contextGlobal;
contextGlobal.gdjs = {
  Logger: class Logger {
    constructor(name) {
      this.name = name;
    }
    info(...args) {
      loggerEntries.push({ level: 'info', args });
    }
    warn(...args) {
      loggerEntries.push({ level: 'warn', args });
    }
    error(...args) {
      loggerEntries.push({ level: 'error', args });
    }
    log(...args) {
      loggerEntries.push({ level: 'log', args });
    }
  },
  PromiseTask: class PromiseTask {
    constructor(promise) {
      this.promise = promise;
    }
  },
  projectData: { properties: { projectUuid: 'official-ui-project' } },
  registerFirstRuntimeSceneLoadedCallback() {},
  registerRuntimeScenePreEventsCallback() {},
  registerRuntimeScenePostEventsCallback() {},
  evtTools: {
    network: {
      retryIfFailed: async (_options, callback) => callback(),
    },
  },
  multiplayerPeerJsHelper: {
    getCurrentId: () => hostOfficialPeer?.id || 'authority',
    getAllPeers: () =>
      hostPeerConnections.filter(connection => connection.open !== false),
    useDefaultBrokerServer() {
      if (hostOfficialPeer || !hostMultiplayerBackend) return;
      hostOfficialPeer = hostMultiplayerBackend.createOfficialPeer();
      hostOfficialPeer.on('connection', connection => {
        hostPeerConnections.push(connection);
      });
    },
    useCustomBrokerServer() {},
    useCustomICECandidate() {},
    setCompressionMethod(method) {
      hostCompressionMethods.push(method);
    },
    connect(peerId) {
      return hostOfficialPeer?.connect(peerId);
    },
    disconnectFromAllPeers() {},
  },
  multiplayerMessageManager: {
    getConnectedPlayers: () => [
      { playerNumber: 1, playerId: 'authority-ui' },
    ],
    handleSavedUpdateMessages() {},
    clearAllMessagesTempData() {},
  },
};

const context = vm.createContext(contextGlobal, {
  name: 'official-gdevelop-runtime-ui-contracts',
});
vm.runInContext(bridgeSource, context, {
  filename: 'gdevelop-multiplayer-bridge.js',
});
const coordinator = context[
  Symbol.for('playmesh.gdevelop.multiplayer.coordinator.v1')
];
coordinator.attachRuntime(main);
context.__testCoordinator = coordinator;
context.__testSessionJson = JSON.stringify(runtimeSession);
context.__testPlayerJson = JSON.stringify(currentPlayer);
vm.runInContext(
  `(() => {
    const currentSession = JSON.parse(__testSessionJson);
    const currentPlayer = JSON.parse(__testPlayerJson);
    __testCoordinator.updateContext({
      isAuthority: true,
      authorityPeerId: 'authority',
      currentSession,
      currentPlayer,
    });
    __testCoordinator.applyPlayerNumberSnapshot({
      type: 'playerNumbers.snapshot',
      protocol: 'playmesh.gdevelop.multiplayer.v1',
      version: 1,
      sessionId: currentSession.id,
      epoch: 1,
      revision: 1,
      assignments: [{ playerId: currentPlayer.id, playerNumber: 1 }],
      errorCode: null,
    });
  })();`,
  context
);

for (const relativePath of [
  'Extensions/PlayerAuthentication/playerauthenticationcomponents.ts',
  'Extensions/PlayerAuthentication/playerauthenticationtools.ts',
  'Extensions/Multiplayer/multiplayercomponents.ts',
  'Extensions/Multiplayer/multiplayertools.ts',
]) {
  vm.runInContext(await transpile(relativePath), context, {
    filename: relativePath,
  });
}

const dispatchWindowMessage = event => {
  for (const listener of windowListeners.get('message') || []) listener(event);
};
const frameCapability = frame => {
  const match = frame.srcdoc.match(/const capability=("[0-9a-f]+")/);
  assert.ok(match, 'local frame srcdoc must contain an opaque capability');
  return JSON.parse(match[1]);
};
const localFrameEvent = ({ frame, kind, sequence, action, payload = {} }) => {
  context.__testFrameEventJson = JSON.stringify({
    protocol: 'playmesh.gdevelop.local-frame.v1',
    version: 1,
    kind,
    nonce: frameCapability(frame),
    sequence,
    action,
    payload,
  });
  const data = vm.runInContext(
    'JSON.parse(__testFrameEventJson)',
    context
  );
  return {
    source: frame.contentWindow,
    origin: 'null',
    data,
  };
};
const waitFor = async (predicate, message) => {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 2000) {
    const value = predicate();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  throw new Error(message);
};

const createLocalLobbyFrameHarness = frame => {
  const scriptMatch = frame.srcdoc.match(/<script>([\s\S]*?)<\/script>/i);
  assert.ok(scriptMatch, 'local lobby frame must contain its offline script');

  const frameDocument = new FakeDocument();
  const elementPattern = /<([a-z][a-z0-9-]*)\b([^>]*\bid="([^"]+)"[^>]*)>/gi;
  for (const match of frame.srcdoc.matchAll(elementPattern)) {
    const element = frameDocument.createElement(match[1]);
    element.id = match[3];
    element.hidden = /\bhidden(?:\s|=|$)/i.test(match[2]);
    element.disabled = /\bdisabled(?:\s|=|$)/i.test(match[2]);
    frameDocument.body.appendChild(element);
  }

  const listeners = new Map();
  const postedMessages = [];
  const parentWindow = {
    postMessage(message, targetOrigin) {
      postedMessages.push({ message, targetOrigin });
    },
  };
  const frameGlobal = {
    document: frameDocument,
    navigator: { language: 'en-US' },
    parent: parentWindow,
    console,
    addEventListener(type, listener) {
      const callbacks = listeners.get(type) || [];
      callbacks.push(listener);
      listeners.set(type, callbacks);
    },
    removeEventListener(type, listener) {
      const callbacks = listeners.get(type) || [];
      listeners.set(
        type,
        callbacks.filter(candidate => candidate !== listener)
      );
    },
  };
  frameGlobal.window = frameGlobal;
  frameGlobal.globalThis = frameGlobal;
  const frameContext = vm.createContext(frameGlobal, {
    name: 'playmesh-local-lobby-frame-ui-contract',
  });
  vm.runInContext(scriptMatch[1], frameContext, {
    filename: 'playmesh-local-lobby-frame.js',
  });

  let parentSequence = 0;
  const dispatchParentEvent = (event, payload) => {
    frameContext.__testParentEnvelopeJson = JSON.stringify({
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      nonce: frameCapability(frame),
      sequence: ++parentSequence,
      event,
      payload,
    });
    const data = vm.runInContext(
      'JSON.parse(__testParentEnvelopeJson)',
      frameContext
    );
    for (const listener of listeners.get('message') || []) {
      listener({ source: parentWindow, data });
    }
  };
  const actions = action =>
    postedMessages
      .map(entry => JSON.parse(JSON.stringify(entry.message)))
      .filter(message => message.action === action);

  return {
    document: frameDocument,
    postedMessages,
    dispatchParentEvent,
    actions,
    click(id) {
      const element = frameDocument.getElementById(id);
      assert.ok(element, `local lobby frame is missing #${id}`);
      if (!element.disabled) element.dispatch('click', { target: element });
    },
  };
};

const parseRealmJson = (runtimeContext, value) => {
  runtimeContext.__testRealmJson = JSON.stringify(value);
  return vm.runInContext('JSON.parse(__testRealmJson)', runtimeContext);
};

const createBridgeGuestHarness = async ({ session, player }) => {
  const guestDocument = new FakeDocument();
  const guestLogs = [];
  let guestSessionStartCount = 0;
  const guestMain = {
    ready: Promise.resolve(),
    gameInfo: {
      getCurrent: () => ({ multiplayer: true }),
    },
    session: {
      isAuthority: () => false,
      getCurrent: () => session,
      start: async () => {
        guestSessionStartCount += 1;
      },
      finish: async () => {},
    },
    player: {
      getCurrent: () => player,
    },
  };
  const guestGlobal = {
    TextEncoder,
    TextDecoder,
    Uint8Array,
    ArrayBuffer,
    DataView,
    URL,
    URLSearchParams,
    Promise,
    crypto: globalThis.crypto,
    performance,
    document: guestDocument,
    navigator: { platform: 'test', language: 'en-US' },
    setTimeout: runtimeSetTimeout,
    clearTimeout: runtimeClearTimeout,
    setInterval: runtimeSetInterval,
    clearInterval: runtimeClearInterval,
    fetch: async () => {
      throw new Error('Guest bridge harness attempted a fetch');
    },
    console: Object.fromEntries(
      ['log', 'info', 'warn', 'error', 'debug'].map(level => [
        level,
        (...args) => guestLogs.push({ level, args }),
      ])
    ),
    playmesh: { main: guestMain },
    parent: null,
    window: null,
    globalThis: null,
  };
  guestGlobal.window = guestGlobal;
  guestGlobal.globalThis = guestGlobal;
  guestGlobal.parent = guestGlobal;
  const guestContext = vm.createContext(guestGlobal, {
    name: 'playmesh-official-runtime-ui-guest-bridge',
  });
  vm.runInContext(bridgeSource, guestContext, {
    filename: 'gdevelop-multiplayer-bridge.guest.js',
  });
  const guestCoordinator = guestContext[
    Symbol.for('playmesh.gdevelop.multiplayer.coordinator.v1')
  ];
  const guestRegistry = guestContext[Symbol.for('playmesh.runtime.backends.v1')];
  guestCoordinator.attachRuntime(guestMain);
  guestCoordinator.updateContext(
    parseRealmJson(guestContext, {
      isAuthority: false,
      authorityPeerId: 'authority',
      currentSession: session,
      currentPlayer: player,
    })
  );
  guestCoordinator.applyPlayerNumberSnapshot(
    parseRealmJson(guestContext, {
      type: 'playerNumbers.snapshot',
      protocol: 'playmesh.gdevelop.multiplayer.v1',
      version: 1,
      sessionId: session.id,
      epoch: 1,
      revision: 2,
      assignments: [
        { playerId: session.authorityClientId, playerNumber: 1 },
        { playerId: player.id, playerNumber: 2 },
      ],
      errorCode: null,
    })
  );

  let guestChannelListener = null;
  guestCoordinator.attachChannel({
    id: 'official-ui-channel',
    async send(targetPlayerId, bytes) {
      const packet = new Uint8Array(bytes);
      binaryTraffic.push({
        sourcePlayerId: player.id,
        targetPlayerId,
        bytes: packet,
      });
      assert.equal(targetPlayerId, session.authorityClientId);
      assert.equal(
        typeof hostChannelListener,
        'function',
        'Authority channel must be attached before Guest sends'
      );
      await Promise.resolve();
      hostChannelListener(
        packet,
        parseRealmJson(context, {
          senderPlayerId: player.id,
          delivery: 'queued',
        })
      );
    },
    onMessage(listener) {
      guestChannelListener = listener;
      return () => {
        guestChannelListener = null;
      };
    },
  });
  deliverHostPacketToGuest = async bytes => {
    assert.equal(
      typeof guestChannelListener,
      'function',
      'Guest channel must be subscribed before Authority sends'
    );
    await Promise.resolve();
    guestChannelListener(
      new Uint8Array(bytes),
      parseRealmJson(guestContext, {
        senderPlayerId: 'authority',
        delivery: 'queued',
      })
    );
  };

  guestContext.__testGuestRegistry = guestRegistry;
  vm.runInContext(
    `globalThis.__testGuestMultiplayerBackend = __testGuestRegistry.negotiate({
      engine: 'gdevelop',
      engineVersion: '5.6.276',
      feature: 'multiplayer',
      minVersion: 1,
      maxVersion: 1,
    });`,
    guestContext
  );
  const backend = guestContext.__testGuestMultiplayerBackend;
  const peer = backend.createOfficialPeer();
  const controlMessages = [];
  let guestConnection = null;
  let resolveConnectionOpened;
  const connectionOpened = new Promise(resolve => {
    resolveConnectionOpened = resolve;
  });
  const control = backend.createOfficialLobbyControlFacade();
  const controlOpened = new Promise(resolve => {
    control.onopen = resolve;
  });
  control.onmessage = event => {
    const message = JSON.parse(event.data);
    controlMessages.push(message);
    if (message.type === 'peerId' && !guestConnection) {
      guestConnection = peer.connect(message.data.peerId);
      guestConnection.on('open', () => resolveConnectionOpened(guestConnection));
    }
  };
  await controlOpened;

  let frame = null;
  let frameSequence = 0;
  let requestSequence = 0;
  const localEvent = (action, payload) => {
    const data = parseRealmJson(guestContext, {
      protocol: 'playmesh.gdevelop.local-frame.v1',
      version: 1,
      kind: 'lobby',
      nonce: frameCapability(frame),
      sequence: ++frameSequence,
      action,
      payload,
    });
    return { source: frame.contentWindow, data };
  };
  const openLobbyFrame = () => {
    frame = guestDocument.createElement('iframe');
    frameSequence = 0;
    backend.configureOfficialLobbyFrame(frame);
    const listenerReady = backend.consumeOfficialLobbyFrameMessage(
      localEvent('ready', {})
    );
    assert.equal(listenerReady?.data?.id, 'lobbiesListenerReady');
    assert.equal(
      backend.postOfficialLobbyFrameMessage(
        frame,
        parseRealmJson(guestContext, {
          id: 'sessionInformation',
          isCordova: false,
          devicePlatform: 'web',
          navigatorPlatform: 'test',
          hasTouch: true,
        })
      ),
      true
    );
    assert.equal(
      backend.postOfficialLobbyFrameMessage(
        frame,
        parseRealmJson(guestContext, {
          id: 'lobbyJoined',
          lobbyId: session.id,
          playerId: player.id,
          playerToken: 'opaque-guest-token',
          connectionId: `pm-gd-v2-2-${session.id}`,
          positionInLobby: 2,
        })
      ),
      true
    );
    return frame;
  };
  const setReady = ready => {
    const requestId = `guest-ready-${++requestSequence}`;
    const result = backend.consumeOfficialLobbyFrameMessage(
      localEvent('setReady', { requestId, ready })
    );
    assert.equal(result, null, 'setReady is handled by the Playmesh compatibility layer');
    return requestId;
  };
  const closeLobbyFrame = () => {
    assert.equal(backend.notifyOfficialLobbyFrameClosed(), true);
    frame = null;
  };
  const confirmOfficialConnection = () => {
    control.send(
      JSON.stringify({
        action: 'updateConnection',
        connectionType: 'lobby',
        status: 'connected',
        peerId: player.id,
      })
    );
  };
  const updateSession = nextSession => {
    guestCoordinator.updateContext(
      parseRealmJson(guestContext, {
        isAuthority: false,
        authorityPeerId: 'authority',
        currentSession: nextSession,
        currentPlayer: player,
      })
    );
  };

  return {
    backend,
    context: guestContext,
    control,
    controlMessages,
    connectionOpened,
    coordinator: guestCoordinator,
    get frame() {
      return frame;
    },
    get sessionStartCount() {
      return guestSessionStartCount;
    },
    closeLobbyFrame,
    confirmOfficialConnection,
    openLobbyFrame,
    setReady,
    updateSession,
    dispose() {
      deliverHostPacketToGuest = null;
      guestCoordinator.dispose();
    },
  };
};

const registry = context[Symbol.for('playmesh.runtime.backends.v1')];
context.__testRegistry = registry;
vm.runInContext(
  `globalThis.__testPlayerAuthenticationBackend = __testRegistry.negotiate({
    engine: 'gdevelop',
    engineVersion: '5.6.276',
    feature: 'playerAuthentication',
    minVersion: 1,
    maxVersion: 1,
  });`,
  context
);
vm.runInContext(
  `globalThis.__testMultiplayerBackend = __testRegistry.negotiate({
    engine: 'gdevelop',
    engineVersion: '5.6.276',
    feature: 'multiplayer',
    minVersion: 1,
    maxVersion: 1,
  });`,
  context
);
hostMultiplayerBackend = context.__testMultiplayerBackend;
const playerAuthenticationBackend = context.__testPlayerAuthenticationBackend;
const playmeshIdentity = JSON.parse(
  playerAuthenticationBackend.readOfficialIdentity(
    'official-ui-project_authenticatedUser'
  )
);
context.gdjs.playerAuthentication.login({
  runtimeScene,
  userId: playmeshIdentity.userId,
  username: playmeshIdentity.username,
  userToken: playmeshIdentity.userToken,
});

let lobbyOpenSettled = false;
const lobbyOpenTask = context.gdjs.multiplayer
  .openLobbiesWindow(runtimeScene)
  .then(() => {
    lobbyOpenSettled = true;
  });
await Promise.resolve();
await Promise.resolve();
assert.equal(
  lobbyOpenSettled,
  false,
  'official lobby UI must wait for the multiplayer channel subscription'
);
assert.equal(
  domRoot.querySelector('#lobbies-iframe'),
  null,
  'official lobby UI must not open before multiplayer negotiation completes'
);
let channelSubscribeCount = 0;
let hostChannelListener = null;
let deliverHostPacketToGuest = null;
const binaryTraffic = [];
coordinator.attachChannel({
  id: 'official-ui-channel',
  async send(targetPlayerId, bytes) {
    const packet = new Uint8Array(bytes);
    binaryTraffic.push({
      sourcePlayerId: 'authority-ui',
      targetPlayerId,
      bytes: packet,
    });
    if (!deliverHostPacketToGuest) {
      throw new Error('Guest channel is not attached');
    }
    await deliverHostPacketToGuest(packet);
  },
  onMessage(listener) {
    channelSubscribeCount += 1;
    hostChannelListener = listener;
    return () => {
      hostChannelListener = null;
    };
  },
});
await lobbyOpenTask;
assert.equal(channelSubscribeCount, 1);
const describeDomIds = root => {
  const ids = [];
  const visit = element => {
    if (element.id) ids.push(element.id);
    element.children.forEach(visit);
  };
  visit(root);
  return ids;
};
const lobbyFrame = await waitFor(
  () => domRoot.querySelector('#lobbies-iframe'),
  `official openLobbiesWindow did not create its iframe; ids=${JSON.stringify(
    describeDomIds(domRoot)
  )}; logs=${JSON.stringify(loggerEntries)}`
);
assert.equal(lobbyFrame.getAttribute('sandbox'), 'allow-scripts');
assert.equal(lobbyFrame.getAttribute('referrerpolicy'), 'no-referrer');
assert.equal(lobbyFrame.getAttribute('src'), null);
assert.doesNotMatch(lobbyFrame.srcdoc, /gd\.games|gdevelop\.io|playerToken|connectionId/);
dispatchWindowMessage(
  localFrameEvent({
    frame: lobbyFrame,
    kind: 'lobby',
    sequence: 1,
    action: 'ready',
  })
);
await waitFor(
  () => lobbyFrame.contentWindow.postedMessages.length === 1,
  'official lobbiesListenerReady did not send sessionInformation'
);
assert.equal(
  lobbyFrame.contentWindow.postedMessages[0].message.event,
  'sessionInformation'
);

// Exercise the actual offline iframe script, not merely its generated HTML.
// Manual readiness has an unknown pre-snapshot state. A guest intent becomes
// ready after the Authority acknowledges it; preparing is a later, hidden
// official peer-handshake phase that starts only after the Host presses Start.
const lobbyUiPlayer = ({
  number,
  nickname,
  isCurrent,
  isAuthority,
  readiness,
}) => ({
  number,
  nickname,
  connected: true,
  isCurrent,
  isAuthority,
  avatarDataUrl: null,
  readiness,
});
const lobbyUiPlayers = ({
  currentPlayerNumber,
  guestReadiness,
}) => [
  lobbyUiPlayer({
    number: 1,
    nickname: 'Authority UI',
    isCurrent: currentPlayerNumber === 1,
    isAuthority: true,
    readiness: 'ready',
  }),
  lobbyUiPlayer({
    number: 2,
    nickname: 'Guest UI',
    isCurrent: currentPlayerNumber === 2,
    isAuthority: false,
    readiness: guestReadiness,
  }),
];
const lobbyUiSessionInformation = ({
  role,
  positionInLobby,
  sessionState = 'lobby',
  guestReadiness = 'unknown',
}) => ({
  isCordova: false,
  devicePlatform: 'web',
  navigatorPlatform: 'test',
  hasTouch: true,
  role,
  sessionId: runtimeSession.id,
  sessionState,
  positionInLobby,
  connectedPlayers: 2,
  minPlayers: 1,
  maxPlayers: 8,
  players: lobbyUiPlayers({
    currentPlayerNumber: positionInLobby,
    guestReadiness,
  }),
  soloAvailable: true,
  soloUnavailableReason: null,
});
const lobbyUiJoined = ({
  role,
  positionInLobby,
  sessionState = 'lobby',
  guestReadiness = 'notReady',
}) => ({
  lobbyId: runtimeSession.id,
  positionInLobby,
  role,
  sessionState,
  connectedPlayers: 2,
  minPlayers: 1,
  maxPlayers: 8,
  players: lobbyUiPlayers({
    currentPlayerNumber: positionInLobby,
    guestReadiness,
  }),
});
const lobbyUiUpdated = ({
  positionInLobby,
  sessionState = 'lobby',
  guestReadiness,
}) => ({
  positionInLobby,
  sessionState,
  connectedPlayers: 2,
  minPlayers: 1,
  maxPlayers: 8,
  players: lobbyUiPlayers({
    currentPlayerNumber: positionInLobby,
    guestReadiness,
  }),
});
const settleLocalFrameOperation = (harness, action) => {
  const request = harness.actions(action).at(-1);
  assert.ok(request, `local lobby frame did not send ${action}`);
  harness.dispatchParentEvent('operationSucceeded', {
    action,
    requestId: request.payload.requestId,
  });
  return request;
};

const authorityUi = createLocalLobbyFrameHarness(lobbyFrame);
assert.equal(authorityUi.actions('ready').length, 1);
authorityUi.dispatchParentEvent(
  'sessionInformation',
  lobbyUiSessionInformation({
    role: 'authority',
    positionInLobby: 1,
  })
);
const authorityJoin = authorityUi.actions('joinCurrentSession').at(-1);
assert.ok(authorityJoin, 'Authority iframe must join the shared lobby');
authorityUi.dispatchParentEvent(
  'lobbyJoined',
  lobbyUiJoined({
    role: 'authority',
    positionInLobby: 1,
    guestReadiness: 'unknown',
  })
);
authorityUi.dispatchParentEvent('operationSucceeded', {
  action: 'joinCurrentSession',
  requestId: authorityJoin.payload.requestId,
});
const authorityStartButton = authorityUi.document.getElementById('start');
const authorityReadyButton = authorityUi.document.getElementById('playerReady');
assert.ok(authorityStartButton);
assert.ok(authorityReadyButton);
assert.equal(authorityReadyButton.hidden, true, 'Host must not show Ready');
assert.equal(
  authorityStartButton.disabled,
  true,
  'Host Start must stay disabled while an online guest is not ready'
);
authorityUi.click('start');
assert.equal(
  authorityUi.actions('startGameCountdown').length,
  0,
  'Disabled Host Start must not request official preparation'
);
authorityUi.dispatchParentEvent(
  'lobbyUpdated',
  lobbyUiUpdated({ positionInLobby: 1, guestReadiness: 'notReady' })
);
assert.equal(
  authorityStartButton.disabled,
  true,
  'An authoritative notReady snapshot must keep Host Start disabled'
);
authorityUi.dispatchParentEvent(
  'lobbyUpdated',
  lobbyUiUpdated({ positionInLobby: 1, guestReadiness: 'ready' })
);
assert.equal(
  authorityStartButton.disabled,
  false,
  'Host Start may enable only after every online guest is authoritatively ready'
);
authorityUi.click('start');
const authorityCountdownIntent = authorityUi.actions('startGameCountdown').at(-1);
assert.ok(
  authorityCountdownIntent,
  'The one visible Host Start control must begin the official preparation phase'
);
assert.equal(
  authorityUi.actions('startGame').length,
  0,
  'The iframe must not request the running transition before official preparation is accepted'
);
authorityUi.dispatchParentEvent(
  'lobbyUpdated',
  lobbyUiUpdated({
    positionInLobby: 1,
    guestReadiness: 'preparing',
  })
);
assert.equal(
  authorityStartButton.disabled,
  true,
  'The hidden official preparation round must keep repeated Start disabled'
);
assert.equal(
  authorityUi.document.getElementById('countdown'),
  null,
  'The Playmesh lobby must not expose a numeric countdown control'
);
authorityUi.dispatchParentEvent('operationSucceeded', {
  action: 'startGameCountdown',
  requestId: authorityCountdownIntent.payload.requestId,
});
assert.equal(
  authorityUi.actions('startGame').length,
  0,
  'The iframe must send only one countdown intent; the bridge records it while the official runtime owns sendPeerId'
);

const guestUi = createLocalLobbyFrameHarness(lobbyFrame);
guestUi.dispatchParentEvent(
  'sessionInformation',
  lobbyUiSessionInformation({
    role: 'guest',
    positionInLobby: 2,
    guestReadiness: 'notReady',
  })
);
const guestJoin = guestUi.actions('joinCurrentSession').at(-1);
assert.ok(guestJoin, 'Guest iframe must join the shared lobby');
guestUi.dispatchParentEvent(
  'lobbyJoined',
  lobbyUiJoined({
    role: 'guest',
    positionInLobby: 2,
    guestReadiness: 'notReady',
  })
);
guestUi.dispatchParentEvent('operationSucceeded', {
  action: 'joinCurrentSession',
  requestId: guestJoin.payload.requestId,
});
const guestReadyButton = guestUi.document.getElementById('playerReady');
assert.ok(guestReadyButton);
assert.equal(guestReadyButton.hidden, false);
assert.equal(guestReadyButton.dataset.readiness, 'notReady');
assert.equal(
  guestUi.actions('setReady').length,
  0,
  'Opening or joining the lobby must never opt a guest into readiness'
);
guestUi.click('playerReady');
const readyIntent = guestUi.actions('setReady').at(-1);
assert.deepEqual(Object.keys(readyIntent.payload).sort(), [
  'ready',
  'requestId',
]);
assert.equal(readyIntent.payload.ready, true);
assert.equal(typeof readyIntent.payload.requestId, 'string');
assert.notEqual(
  guestReadyButton.dataset.readiness,
  'ready',
  'A local click must not claim readiness before the Authority ACK'
);
assert.equal(guestReadyButton.disabled, true);
assert.equal(guestReadyButton.getAttribute('aria-busy'), 'true');
guestUi.dispatchParentEvent('operationSucceeded', {
  action: 'setReady',
  requestId: readyIntent.payload.requestId,
});
guestUi.dispatchParentEvent(
  'lobbyUpdated',
  lobbyUiUpdated({ positionInLobby: 2, guestReadiness: 'ready' })
);
assert.equal(guestReadyButton.dataset.readiness, 'ready');
assert.equal(guestReadyButton.disabled, false);
assert.equal(guestReadyButton.getAttribute('aria-busy'), 'false');
assert.equal(guestReadyButton.textContent, 'Cancel ready');
guestUi.click('playerReady');
const cancelReadyIntent = guestUi.actions('setReady').at(-1);
assert.notEqual(cancelReadyIntent.payload.requestId, readyIntent.payload.requestId);
assert.deepEqual(Object.keys(cancelReadyIntent.payload).sort(), [
  'ready',
  'requestId',
]);
assert.equal(cancelReadyIntent.payload.ready, false);
guestUi.dispatchParentEvent('operationSucceeded', {
  action: 'setReady',
  requestId: cancelReadyIntent.payload.requestId,
});
guestUi.dispatchParentEvent('lobbyLeft', {});
assert.equal(
  guestReadyButton.hidden,
  true,
  'Leaving the lobby must close the manual Ready control'
);

const runningLateGuestUi = createLocalLobbyFrameHarness(lobbyFrame);
runningLateGuestUi.dispatchParentEvent(
  'sessionInformation',
  lobbyUiSessionInformation({
    role: 'guest',
    positionInLobby: 2,
    sessionState: 'running',
    guestReadiness: 'notReady',
  })
);
const runningLateJoin = runningLateGuestUi.actions('joinCurrentSession').at(-1);
assert.ok(runningLateJoin);
runningLateGuestUi.dispatchParentEvent(
  'lobbyJoined',
  lobbyUiJoined({
    role: 'guest',
    positionInLobby: 2,
    sessionState: 'running',
    guestReadiness: 'notReady',
  })
);
assert.equal(
  runningLateGuestUi.document.getElementById('playerReady').hidden,
  true,
  'A running late join must not expose the lobby Ready control'
);
assert.equal(runningLateGuestUi.actions('setReady').length, 0);
assert.equal(
  runningLateGuestUi.actions('joinGame').length,
  1,
  'A running late join must retain the existing automatic joinGame path'
);

const authTask = context.gdjs.playerAuthentication.openAuthenticationWindow(
  runtimeScene
);
const authFrame = await waitFor(
  () => {
    const authenticationRoot = domRoot.querySelector('#authentication-root-container');
    if (!authenticationRoot) return null;
    const frames = [];
    const visit = element => {
      if (element.tagName === 'IFRAME') frames.push(element);
      element.children.forEach(visit);
    };
    visit(authenticationRoot);
    return frames[0] || null;
  },
  'official web authentication did not create its local iframe'
);
assert.equal(authFrame.getAttribute('sandbox'), 'allow-scripts');
assert.equal(authFrame.getAttribute('src'), null);
assert.doesNotMatch(
  authFrame.srcdoc,
  new RegExp(
    `gd\\.games|gdevelop\\.io|${playmeshIdentity.userToken.replace(
      /[.*+?^${}()|[\]\\]/g,
      '\\$&'
    )}`
  )
);
dispatchWindowMessage(
  localFrameEvent({
    frame: authFrame,
    kind: 'authentication',
    sequence: 1,
    action: 'authenticate',
  })
);
const authenticationResult = await Promise.race([
  authTask.promise,
  new Promise((_, reject) =>
    setTimeout(
      () => reject(new Error('official web authentication Promise timed out')),
      2000
    )
  ),
]);
assert.deepEqual(JSON.parse(JSON.stringify(authenticationResult)), {
  status: 'logged',
});
assert.equal(context.gdjs.playerAuthentication.getUserId(), 'authority-ui');
assert.equal(context.gdjs.playerAuthentication.getUsername(), 'Authority UI');
assert.equal(sessionStartCount, 0);

// Add a real Guest bridge page to the Authority official runtime. The local
// iframe remains a single-button UI, while PMGD v2 carries manual readiness
// and the untouched official peer preparation frames over the linked channel.
const guestPlayer = {
  id: 'guest-ui',
  nickname: 'Guest UI',
  role: 'player',
  connected: true,
};
runtimeSession.players.push(guestPlayer);
runtimeSession.minPlayers = 2;
const guestBridge = await createBridgeGuestHarness({
  session: runtimeSession,
  player: guestPlayer,
});
context.__testSessionJson = JSON.stringify(runtimeSession);
vm.runInContext(
  `(() => {
    const currentSession = JSON.parse(__testSessionJson);
    __testCoordinator.updateContext({
      isAuthority: true,
      authorityPeerId: 'authority',
      currentSession,
      currentPlayer: JSON.parse(__testPlayerJson),
    });
    __testCoordinator.applyPlayerNumberSnapshot({
      type: 'playerNumbers.snapshot',
      protocol: 'playmesh.gdevelop.multiplayer.v1',
      version: 1,
      sessionId: currentSession.id,
      epoch: 1,
      revision: 2,
      assignments: [
        { playerId: 'authority-ui', playerNumber: 1 },
        { playerId: 'guest-ui', playerNumber: 2 },
      ],
      errorCode: null,
    });
  })();`,
  context
);

const packetType = entry => entry.bytes[5];
const traffic = (sourcePlayerId, type) =>
  binaryTraffic.filter(
    entry => entry.sourcePlayerId === sourcePlayerId && packetType(entry) === type
  );

// Joining the page is not readiness. Closing a ready lobby page before the
// game starts sends an authoritative not-ready transition but keeps the
// player in the Playmesh session and in stable slot #2.
guestBridge.openLobbyFrame();
assert.equal(
  traffic(guestPlayer.id, 5).length,
  0,
  'Opening the Guest lobby page must not auto-ready the player'
);
const firstReadyRequestId = guestBridge.setReady(true);
await waitFor(
  () =>
    guestBridge.frame.contentWindow.postedMessages.some(
      entry =>
        entry.message.event === 'operationSucceeded' &&
        entry.message.payload.action === 'setReady' &&
        entry.message.payload.requestId === firstReadyRequestId
    ),
  'Authority did not acknowledge the Guest manual Ready intent'
);
assert.equal(traffic(guestPlayer.id, 5).at(-1).bytes[6], 1);
const readyStatePacketsBeforeClose = traffic(guestPlayer.id, 5).length;
const readyAckPacketsBeforeClose = traffic('authority-ui', 6).length;
guestBridge.closeLobbyFrame();
await waitFor(
  () =>
    traffic(guestPlayer.id, 5).length > readyStatePacketsBeforeClose &&
    traffic('authority-ui', 6).length > readyAckPacketsBeforeClose,
  'Closing a non-running Guest lobby page did not cancel readiness'
);
assert.equal(
  traffic(guestPlayer.id, 5).at(-1).bytes[6],
  0,
  'Lobby page close must send notReady to Authority'
);
assert.equal(runtimeSession.players[1], guestPlayer);
assert.equal(runtimeSession.players[1].connected, true);

guestBridge.openLobbyFrame();
const finalReadyRequestId = guestBridge.setReady(true);
await waitFor(
  () =>
    guestBridge.frame.contentWindow.postedMessages.some(
      entry =>
        entry.message.event === 'operationSucceeded' &&
        entry.message.payload.action === 'setReady' &&
        entry.message.payload.requestId === finalReadyRequestId
    ),
  'Authority did not acknowledge the Guest Ready intent after lobby re-entry'
);

dispatchWindowMessage(
  localFrameEvent({
    frame: lobbyFrame,
    kind: 'lobby',
    sequence: 2,
    action: 'joinCurrentSession',
    payload: { requestId: 'authority-two-phase-join' },
  })
);
await waitFor(
  () =>
    lobbyFrame.contentWindow.postedMessages.some(
      entry => entry.message.event === 'lobbyJoined'
    ),
  'Authority did not join the shared Playmesh lobby'
);

let connectionErrorCount = 0;
const originalDisplayConnectionError =
  context.gdjs.multiplayerComponents.displayConnectionErrorNotification;
context.gdjs.multiplayerComponents.displayConnectionErrorNotification =
  (...args) => {
    connectionErrorCount += 1;
    return originalDisplayConnectionError(...args);
  };
const countdownRequestId = 'authority-two-phase-start';
const visibleCountdownEventsBeforeStart =
  lobbyFrame.contentWindow.postedMessages.filter(
    entry => entry.message.event === 'gameCountdownStarted'
  ).length;
const countdownOperationSucceeded = () =>
  lobbyFrame.contentWindow.postedMessages.some(
    entry =>
      entry.message.event === 'operationSucceeded' &&
      entry.message.payload.action === 'startGameCountdown' &&
      entry.message.payload.requestId === countdownRequestId
  );
const hostCompressionCountBeforeStart = hostCompressionMethods.length;
dispatchWindowMessage(
  localFrameEvent({
    frame: lobbyFrame,
    kind: 'lobby',
    sequence: 3,
    action: 'startGameCountdown',
    payload: { requestId: countdownRequestId },
  })
);
await waitFor(
  () => hostCompressionMethods.length === hostCompressionCountBeforeStart + 1,
  'Host Start did not reach the official gameCountdownStarted handler'
);
assert.equal(
  lobbyFrame.contentWindow.postedMessages.filter(
    entry => entry.message.event === 'gameCountdownStarted'
  ).length,
  visibleCountdownEventsBeforeStart,
  'The internal official preparation event must not create a visible countdown in the local iframe'
);
await waitFor(
  () => traffic('authority-ui', 8).length === 1,
  'Official sendPeerId did not dispatch one PREPARE packet to the ready Guest'
);
await waitFor(
  () =>
    guestBridge.controlMessages.some(message => message.type === 'peerId'),
  'Guest did not receive the official host peerId during preparation'
);
const guestConnection = await Promise.race([
  guestBridge.connectionOpened,
  new Promise((_, reject) =>
    setTimeout(
      () => reject(new Error('Guest official peer connection timed out')),
      2000
    )
  ),
]);
assert.ok(guestConnection);
assert.equal(
  guestBridge.controlMessages.filter(
    message => message.type === 'gameCountdownStarted'
  ).length,
  1,
  'Guest must enter the hidden official preparation phase exactly once'
);
assert.equal(
  sessionStartCount,
  0,
  'Authority must not start the session before Guest updateConnection/PREPARED'
);
assert.equal(
  countdownOperationSucceeded(),
  false,
  'The Host countdown operation must remain pending until peer preparation succeeds'
);
assert.equal(traffic(guestPlayer.id, 9).length, 0);

guestBridge.confirmOfficialConnection();
await waitFor(
  () => traffic(guestPlayer.id, 9).length === 1,
  'Guest official updateConnection did not emit one PREPARED packet'
);
await waitFor(
  () => sessionStartCount === 1,
  'Authority did not start after every frozen ready participant was PREPARED'
);
const prepareIndex = binaryTraffic.findIndex(
  entry => entry.sourcePlayerId === 'authority-ui' && packetType(entry) === 8
);
const connectIndex = binaryTraffic.findIndex(
  entry => entry.sourcePlayerId === guestPlayer.id && packetType(entry) === 1
);
const preparedIndex = binaryTraffic.findIndex(
  entry => entry.sourcePlayerId === guestPlayer.id && packetType(entry) === 9
);
assert.ok(
  prepareIndex >= 0 && connectIndex > prepareIndex && preparedIndex > connectIndex,
  'The transport order must be PREPARE -> Guest peer CONNECT -> PREPARED'
);
assert.equal(sessionStartCount, 1);
assert.equal(guestBridge.sessionStartCount, 0);

runtimeSession.state = 'running';
context.__testSessionJson = JSON.stringify(runtimeSession);
vm.runInContext(
  `(() => {
    const currentSession = JSON.parse(__testSessionJson);
    __testCoordinator.updateContext({
      isAuthority: true,
      authorityPeerId: 'authority',
      currentSession,
      currentPlayer: JSON.parse(__testPlayerJson),
    });
  })();`,
  context
);
guestBridge.updateSession(runtimeSession);
await waitFor(
  () =>
    connectionErrorCount > 0 ||
    context.gdjs.multiplayer.isLobbyGameRunning(),
  'Prepared Authority start did not settle in the official state machine'
);
assert.equal(
  connectionErrorCount,
  0,
  'The complete official peer preparation must not report a connection error'
);
assert.equal(
  context.gdjs.multiplayer.isCurrentPlayerHost(),
  true,
  'Authority must be initialized as the official GDevelop host'
);
assert.equal(context.gdjs.multiplayer.getCurrentPlayerNumber(), 1);
assert.equal(context.gdjs.multiplayer.isLobbyGameRunning(), true);
guestBridge.dispose();

assert.equal(
  loggerEntries.some(entry =>
    entry.args.some(value => String(value).includes('cloud'))
  ),
  false
);

for (const timeoutId of runtimeTimeouts) clearTimeout(timeoutId);
for (const intervalId of runtimeIntervals) clearInterval(intervalId);

process.stdout.write(
  'Official GDevelop local UI + authentication + manual-ready two-phase start contracts passed.\n'
);
