import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const bridgePath = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "developer",
  "gdevelop-multiplayer-bridge.js",
);
const bridgeSource = fs.readFileSync(bridgePath, "utf8");

const bridgeRealm = vm.createContext({
  ArrayBuffer,
  DataView,
  TextDecoder,
  TextEncoder,
  URL,
  Uint8Array,
  clearTimeout,
  console,
  crypto: globalThis.crypto || webcrypto,
  setTimeout,
});
vm.runInContext(bridgeSource, bridgeRealm, { filename: bridgePath });

const registry = bridgeRealm[Symbol.for("playmesh.runtime.backends.v1")];
assert.ok(registry, "bridge must install the private runtime registry");
const multiplayer = vm.runInContext(
  `globalThis[Symbol.for("playmesh.runtime.backends.v1")].negotiate({
    engine: "gdevelop",
    engineVersion: "5.6.276",
    feature: "multiplayer",
    minVersion: 1,
    maxVersion: 1,
  })`,
  bridgeRealm,
);
const attributes = new Map();
const frame = {
  srcdoc: "",
  removeAttribute(name) {
    attributes.delete(name);
  },
  setAttribute(name, value) {
    attributes.set(name, value);
  },
};
multiplayer.configureOfficialLobbyFrame(frame);

assert.equal(attributes.get("sandbox"), "allow-scripts");
assert.equal(attributes.get("referrerpolicy"), "no-referrer");
assert.match(frame.srcdoc, /<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">/);

const cssMatch = frame.srcdoc.match(/<style>([\s\S]*?)<\/style>/);
const scriptMatch = frame.srcdoc.match(/<script>([\s\S]*?)<\/script><\/body>/);
assert.ok(cssMatch, "lobby iframe must contain an inline stylesheet");
assert.ok(scriptMatch, "lobby iframe must contain an inline controller script");
const css = cssMatch[1];
const iframeScript = scriptMatch[1];
new vm.Script(iframeScript, { filename: "gdevelop-lobby-iframe.js" });
assert.doesNotMatch(
  css,
  /userAgent|Android|iPhone|iPad|Windows Phone/i,
  "responsive layout must not branch on user-agent strings",
);

assert.match(
  css,
  /@media\(min-width:800px\) and \(hover:hover\) and \(pointer:fine\)/,
  "desktop layout must be selected by viewport and input capability",
);
assert.match(
  css,
  /@media\(orientation:landscape\) and \(max-height:540px\) and \(pointer:coarse\)/,
  "landscape phone layout must use orientation, viewport height and coarse pointer",
);
assert.match(
  css,
  /@media\(max-width:479px\) and \(orientation:portrait\)/,
  "narrow portrait phones must have an independent layout",
);
assert.match(css, /@media\(hover:none\),\(pointer:coarse\)/);
assert.match(css, /--tap-target:46px/);
assert.match(css, /--tap-target:48px/);
assert.match(css, /button\{min-height:var\(--tap-target\);min-width:0/);
assert.match(css, /env\(safe-area-inset-top\)/);
assert.match(css, /env\(safe-area-inset-right\)/);
assert.match(css, /env\(safe-area-inset-bottom\)/);
assert.match(css, /env\(safe-area-inset-left\)/);
assert.match(css, /grid-template-areas:"hero hero" "status metrics" "players actions"/);
assert.match(css, /grid-template-columns:minmax\(0,1\.25fr\) minmax\(220px,\.75fr\)/);
assert.match(css, /grid-template-areas:"hero" "status" "metrics" "actions" "note" "players" "footer"/);
assert.match(css, /\.player-list\{[^}]*min-width:0[^}]*overflow:auto/);
assert.match(css, /max-height:clamp\(112px,24dvh,234px\)/);
assert.match(css, /button:focus-visible/);
assert.match(css, /@media\(prefers-reduced-motion:reduce\)/);
assert.match(css, /@media\(prefers-contrast:more\)/);
assert.match(css, /@media\(forced-colors:active\)/);

assert.match(
  frame.srcdoc,
  /role="dialog" aria-modal="true" aria-labelledby="heading" aria-describedby="status"/,
);
assert.match(frame.srcdoc, /role="status" aria-live="polite" aria-atomic="true"/);
assert.match(frame.srcdoc, /id="playerList" aria-live="polite"/);
const slotIds = [...frame.srcdoc.matchAll(/id="playerRow(\d+)"/g)].map(
  (match) => Number(match[1]),
);
assert.deepEqual(slotIds, [1, 2, 3, 4, 5, 6, 7, 8]);

function createElement(initiallyHidden) {
  const listeners = new Map();
  const elementAttributes = new Map();
  return {
    attributes: elementAttributes,
    dataset: {},
    disabled: false,
    hidden: initiallyHidden,
    src: "",
    textContent: "",
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    click() {
      const listener = listeners.get("click");
      assert.ok(listener, "clicked lobby control must have a click listener");
      listener();
    },
    setAttribute(name, value) {
      elementAttributes.set(name, value);
    },
  };
}

const elements = new Map();
for (const match of frame.srcdoc.matchAll(/<[^>]+\sid="([^"]+)"[^>]*>/g)) {
  elements.set(match[1], createElement(/\shidden(?:\s|>|=)/.test(match[0])));
}
const posted = [];
const parent = {
  postMessage(message) {
    posted.push(JSON.parse(JSON.stringify(message)));
  },
};
const iframeRealm = vm.createContext({
  document: {
    title: "",
    getElementById(id) {
      return elements.get(id) || null;
    },
  },
  navigator: { language: "zh-CN" },
  parent,
});
iframeRealm.window = iframeRealm;
iframeRealm.addEventListener = (type, listener) => {
  if (type === "message") iframeRealm.__dispatchMessage = listener;
};
vm.runInContext(iframeScript, iframeRealm, {
  filename: "gdevelop-lobby-iframe-runtime.js",
});
assert.equal(posted.length, 1);
assert.equal(posted[0].action, "ready");

const players = Array.from({ length: 8 }, (_, index) => ({
  number: index + 1,
  nickname: index === 0 ? "房主" : `加入者 ${index}`,
  connected: true,
  isCurrent: index === 0,
  isAuthority: index === 0,
  readiness: index === 0 ? "ready" : "notReady",
  avatarDataUrl: null,
}));
const sessionInformation = {
  protocol: posted[0].protocol,
  version: posted[0].version,
  kind: posted[0].kind,
  nonce: posted[0].nonce,
  sequence: 1,
  event: "sessionInformation",
  payload: {
    isCordova: false,
    devicePlatform: "test",
    navigatorPlatform: "test",
    hasTouch: true,
    role: "authority",
    sessionId: "layout-contract-session",
    sessionState: "lobby",
    positionInLobby: 1,
    connectedPlayers: 8,
    minPlayers: 1,
    maxPlayers: 8,
    players,
    soloAvailable: true,
    soloUnavailableReason: null,
  },
};
iframeRealm.__messageJson = JSON.stringify(sessionInformation);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  iframeRealm,
);
delete iframeRealm.__messageJson;

assert.equal(elements.get("playersPanel").hidden, false);
assert.equal(elements.get("playerSummary").textContent, "8 / 8");
assert.equal(elements.has("join"), false, "manual join control is not packaged");
assert.equal(
  elements.has("countdown"),
  false,
  "countdown control is not packaged",
);
assert.equal(posted.length, 2);
assert.equal(posted[1].action, "joinCurrentSession");
assert.match(posted[1].payload.requestId, /^op-\d+$/);
assert.equal(elements.get("solo").hidden, false);
for (let number = 1; number <= 8; number += 1) {
  assert.equal(elements.get(`playerRow${number}`).hidden, false);
  assert.equal(
    elements.get(`playerName${number}`).textContent,
    number === 1 ? "房主" : `加入者 ${number - 1}`,
  );
}

const lobbyJoined = {
  protocol: posted[0].protocol,
  version: posted[0].version,
  kind: posted[0].kind,
  nonce: posted[0].nonce,
  sequence: 2,
  event: "lobbyJoined",
  payload: {
    lobbyId: "layout-contract-session",
    positionInLobby: 1,
    role: "authority",
    sessionState: "lobby",
    connectedPlayers: 8,
    minPlayers: 1,
    maxPlayers: 8,
    players,
  },
};
iframeRealm.__messageJson = JSON.stringify(lobbyJoined);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  iframeRealm,
);
delete iframeRealm.__messageJson;
assert.equal(elements.get("start").hidden, false);
assert.equal(
  elements.get("start").disabled,
  true,
  "Host Start must remain disabled until every online guest is ready",
);
assert.equal(
  elements.get("playerReady").hidden,
  true,
  "Host must not be shown a separate Ready control",
);
assert.equal(elements.has("countdown"), false);

const readyPlayers = players.map((player) => ({
  ...player,
  readiness: "ready",
}));
const lobbyReady = {
  protocol: posted[0].protocol,
  version: posted[0].version,
  kind: posted[0].kind,
  nonce: posted[0].nonce,
  sequence: 3,
  event: "lobbyUpdated",
  payload: {
    positionInLobby: 1,
    sessionState: "lobby",
    connectedPlayers: 8,
    minPlayers: 1,
    maxPlayers: 8,
    players: readyPlayers,
  },
};
iframeRealm.__messageJson = JSON.stringify(lobbyReady);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  iframeRealm,
);
delete iframeRealm.__messageJson;
assert.equal(
  elements.get("start").disabled,
  false,
  "Host Start must become enabled only after every online guest is ready",
);
elements.get("start").click();
assert.equal(posted.at(-1).action, "startGameCountdown");
assert.deepEqual(
  Object.keys(posted.at(-1).payload).sort(),
  ["requestId"],
  "the single Host Start click must use the official countdown operation",
);
assert.equal(
  posted.some((message) => message.action === "startGame"),
  false,
  "the custom lobby must not bypass the official preparation phase",
);
assert.equal(
  elements.has("countdown"),
  false,
  "the official preparation phase must not expose a numeric countdown UI",
);

const guestElements = new Map();
for (const match of frame.srcdoc.matchAll(/<[^>]+\sid="([^"]+)"[^>]*>/g)) {
  guestElements.set(
    match[1],
    createElement(/\shidden(?:\s|>|=)/.test(match[0])),
  );
}
const guestPosted = [];
const guestParent = {
  postMessage(message) {
    guestPosted.push(JSON.parse(JSON.stringify(message)));
  },
};
const guestRealm = vm.createContext({
  document: {
    title: "",
    getElementById(id) {
      return guestElements.get(id) || null;
    },
  },
  navigator: { language: "zh-CN" },
  parent: guestParent,
});
guestRealm.window = guestRealm;
guestRealm.addEventListener = (type, listener) => {
  if (type === "message") guestRealm.__dispatchMessage = listener;
};
vm.runInContext(iframeScript, guestRealm, {
  filename: "gdevelop-lobby-guest-iframe-runtime.js",
});
assert.equal(guestPosted.length, 1);
assert.equal(guestPosted[0].action, "ready");

const guestPlayers = [
  {
    number: 1,
    nickname: "房主",
    connected: true,
    isCurrent: false,
    isAuthority: true,
    readiness: "ready",
    avatarDataUrl: null,
  },
  {
    number: 2,
    nickname: "加入者 1",
    connected: true,
    isCurrent: true,
    isAuthority: false,
    readiness: "notReady",
    avatarDataUrl: null,
  },
];
const guestSessionInformation = {
  protocol: guestPosted[0].protocol,
  version: guestPosted[0].version,
  kind: guestPosted[0].kind,
  nonce: guestPosted[0].nonce,
  sequence: 1,
  event: "sessionInformation",
  payload: {
    isCordova: false,
    devicePlatform: "test",
    navigatorPlatform: "test",
    hasTouch: true,
    role: "guest",
    sessionId: "layout-contract-session",
    sessionState: "lobby",
    positionInLobby: 2,
    connectedPlayers: 2,
    minPlayers: 1,
    maxPlayers: 8,
    players: guestPlayers,
    soloAvailable: true,
    soloUnavailableReason: null,
  },
};
guestRealm.__messageJson = JSON.stringify(guestSessionInformation);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  guestRealm,
);
delete guestRealm.__messageJson;
assert.equal(guestPosted[1].action, "joinCurrentSession");

const guestLobbyJoined = {
  protocol: guestPosted[0].protocol,
  version: guestPosted[0].version,
  kind: guestPosted[0].kind,
  nonce: guestPosted[0].nonce,
  sequence: 2,
  event: "lobbyJoined",
  payload: {
    lobbyId: "layout-contract-session",
    positionInLobby: 2,
    role: "guest",
    sessionState: "lobby",
    connectedPlayers: 2,
    minPlayers: 1,
    maxPlayers: 8,
    players: guestPlayers,
  },
};
guestRealm.__messageJson = JSON.stringify(guestLobbyJoined);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  guestRealm,
);
delete guestRealm.__messageJson;
assert.equal(guestElements.get("start").hidden, true);
assert.equal(
  guestElements.get("playerReady").hidden,
  false,
  "a lobby guest must be shown the manual Ready control",
);
assert.equal(guestElements.get("playerReady").dataset.readiness, "notReady");
guestElements.get("playerReady").click();
const setReadyMessage = guestPosted.at(-1);
assert.equal(setReadyMessage.action, "setReady");
assert.deepEqual(Object.keys(setReadyMessage.payload).sort(), ["ready", "requestId"]);
assert.equal(setReadyMessage.payload.ready, true);
assert.equal(guestElements.get("playerReady").disabled, true);
assert.equal(guestElements.get("playerReady").attributes.get("aria-busy"), "true");

const readyOperationSucceeded = {
  protocol: guestPosted[0].protocol,
  version: guestPosted[0].version,
  kind: guestPosted[0].kind,
  nonce: guestPosted[0].nonce,
  sequence: 3,
  event: "operationSucceeded",
  payload: {
    action: "setReady",
    requestId: setReadyMessage.payload.requestId,
  },
};
guestRealm.__messageJson = JSON.stringify(readyOperationSucceeded);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  guestRealm,
);
delete guestRealm.__messageJson;

const guestReadyPlayers = guestPlayers.map((player) =>
  player.number === 2 ? { ...player, readiness: "ready" } : player,
);
const guestReadyUpdate = {
  protocol: guestPosted[0].protocol,
  version: guestPosted[0].version,
  kind: guestPosted[0].kind,
  nonce: guestPosted[0].nonce,
  sequence: 4,
  event: "lobbyUpdated",
  payload: {
    positionInLobby: 2,
    sessionState: "lobby",
    connectedPlayers: 2,
    minPlayers: 1,
    maxPlayers: 8,
    players: guestReadyPlayers,
  },
};
guestRealm.__messageJson = JSON.stringify(guestReadyUpdate);
vm.runInContext(
  "__dispatchMessage({ source: parent, data: JSON.parse(__messageJson) })",
  guestRealm,
);
delete guestRealm.__messageJson;
assert.equal(guestElements.get("playerReady").hidden, false);
assert.equal(guestElements.get("playerReady").dataset.readiness, "ready");
assert.equal(guestElements.get("playerReady").textContent, "取消准备");
assert.equal(guestElements.get("playerReady").attributes.get("aria-busy"), "false");

console.log("GDevelop multiplayer lobby responsive layout contract passed.");
