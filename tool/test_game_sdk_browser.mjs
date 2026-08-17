import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import fs from "node:fs";
import vm from "node:vm";

const appSource = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh-main.js", import.meta.url), "utf8");
const appInternalKey = Symbol.for("playmesh.app.internal.v1");
const mainInternalKey = Symbol.for("playmesh.main.internal.v1");
const receiveMain = (page, message) => page[mainInternalKey].receive(message);
assert.doesNotMatch(source, /class="panel"|performanceButton|querySelector\("\.fps"\)|querySelector\("\.latency"\)/);
assert.match(
  source,
  /avatar: value\?\.avatar \?\? null/,
  "player connection logs must include the normalized avatar field",
);
assert.match(
  source,
  /const multiplayer = main\.gameInfo\.getCurrent\(\)\?\.multiplayer === true;\s+if \(multiplayer && main\.session\.isAuthority\(\)\) \{\s+await post\("session\.reset", \{\}\);/s,
  "restart must reset multiplayer sessions without sending session.reset in solo mode",
);
const localizationManifest = JSON.parse(
  fs.readFileSync(
    new URL("../assets/playmesh-localization/manifest.json", import.meta.url),
    "utf8",
  ),
);
const platformMessages = new Map();
for (const locale of localizationManifest.locales) {
  const appMessages = JSON.parse(
    fs.readFileSync(
      new URL(`../assets/playmesh-localization/${locale.bundles.app}`, import.meta.url),
      "utf8",
    ),
  );
  platformMessages.set(
    locale.id,
    Object.fromEntries(
      Object.entries(appMessages)
        .filter(([key]) => key.startsWith("platform.game."))
        .map(([key, value]) => [key.slice("platform.game.".length), value]),
    ),
  );
}
function platformConfiguration(localeId, theme = "system") {
  const locale = platformMessages.has(localeId)
    ? localeId
    : localizationManifest.defaultLocale;
  return {
    locale,
    messages: structuredClone(platformMessages.get(locale)),
    theme,
  };
}
function platformCatalog() {
  return {
    fallbackLocale: "zh-CN",
    locales: localizationManifest.locales
      .filter((locale) => locale.enabled)
      .map((locale) => platformConfiguration(locale.id)),
  };
}
const hostData = new Map();
const browserLocalStorage = new Map();
const standardStorageRequests = [];
const synchronousStorageRequests = [];
const synchronousStorageLedger = new Map();
const uploadCommands = [];
const nicknameCommands = [];
const joinCommands = [];
const joinUrls = [];
let joins = 0;

function browserBucketRevision(bucket) {
  const values = Object.fromEntries(
    [...hostData.entries()]
      .filter(([key]) => key.startsWith(`${bucket}:`))
      .map(([key, value]) => [key.slice(bucket.length + 1), value]),
  );
  return createHash("sha256").update(JSON.stringify(values)).digest("hex");
}

class BrowserStorageXMLHttpRequest {
  constructor() {
    this.headers = {};
    this.status = 0;
    this.responseText = "";
  }

  open(method, url, asynchronous = true) {
    assert.equal(asynchronous, false);
    this.method = method;
    this.url = url;
  }

  setRequestHeader(name, value) {
    this.headers[name] = value;
  }

  send(body) {
    assert.equal(this.headers["X-Playmesh-Storage-Sync"], "1");
    const encodedBody = this.method === "GET"
      ? Buffer.from(
          new URL(this.url, "http://playmesh.local").searchParams.get("payload"),
          "base64url",
        ).toString("utf8")
      : body;
    assert.equal(this.method === "GET" ? body : null, null);
    assert.equal(
      this.headers["X-Playmesh-Content-Sha256"],
      createHash("sha256").update(encodedBody).digest("hex"),
    );
    const envelope = JSON.parse(encodedBody);
    synchronousStorageRequests.push({
      method: this.method,
      url: this.url,
      envelope,
      body: encodedBody,
    });
    const replay = synchronousStorageLedger.get(envelope.requestId);
    if (replay) {
      this.status = replay.status;
      this.responseText = replay.responseText;
      return;
    }
    const key = `${envelope.bucket}:${envelope.key}`;
    let status = 200;
    let result;
    let error;
    if (this.method === "GET") {
      result = {
        value: hostData.has(key) ? hostData.get(key) : null,
        revision: browserBucketRevision(envelope.bucket),
      };
    } else {
      assert.equal(this.method, "PUT");
      const currentRevision = browserBucketRevision(envelope.bucket);
      if (envelope.expectedRevision !== currentRevision) {
        status = 409;
        error = {
          code: "storage_revision_conflict",
          message: "storage revision conflict",
        };
      } else {
        hostData.set(key, envelope.value);
        result = { revision: browserBucketRevision(envelope.bucket) };
      }
    }
    this.status = status;
    this.responseText = JSON.stringify({
      protocolVersion: "1.0.0",
      requestId: envelope.requestId,
      ...(error ? { error } : { result }),
    });
    synchronousStorageLedger.set(envelope.requestId, {
      status: this.status,
      responseText: this.responseText,
    });
  }
}

function createPage(
  appIdentity = null,
  reconnected = false,
  browserLocales = ["zh-CN"],
  appLocaleId = localizationManifest.defaultLocale,
  navigatorOverride = null,
  uiOptions = {},
) {
  const consoleEntries = [];
  const fullscreenRequests = [];
  const runtimeGameDeclarations = [];
  const nativeSidebarRequests = [];
  const orientationLocks = [];
  const windowListeners = new Map();
  const shadowRoots = [];
  let document = null;
  function fakeElement(selector) {
    const listeners = new Map();
    const attributes = new Map();
    const buttonSelectors = new Set([
      ".edit", ".close", ".save", ".performance", ".menu-fab", ".sidebar-scrim",
      ".continue", ".reload", ".enter-fullscreen", ".exit-fullscreen", ".exit",
      ".info", ".logs", ".info-close", ".logs-clear", ".logs-close",
      ".allow", ".deny",
    ]);
    const tagName = selector === "input"
      ? "INPUT"
      : selector === ".logs-output"
        ? "PRE"
        : buttonSelectors.has(selector)
          ? "BUTTON"
          : "DIV";
    const labelElement = { textContent: "" };
    return {
      hidden: false, textContent: "", value: "", disabled: false,
      scrollTop: 0, scrollHeight: 100, style: {},
      tagName, isContentEditable: false, removed: false,
      focus() {
        if (this.__root) this.__root.activeElement = this;
        if (document) document.activeElement = this.__root?.host || this;
      },
      insertBefore() {}, onclick: null, onsubmit: null,
      classList: { toggle() {} },
      setAttribute(name, value) { attributes.set(name, String(value)); },
      getAttribute(name) { return attributes.get(name) ?? null; },
      querySelector(selector) {
        return selector === "span:last-child" ? labelElement : null;
      },
      __label: labelElement,
      getRootNode() { return this.__root || null; },
      addEventListener(type, listener, options = {}) {
        const registered = options.once
          ? (event) => {
              this.removeEventListener(type, registered);
              listener(event);
            }
          : listener;
        const current = listeners.get(type) || [];
        current.push(registered);
        listeners.set(type, current);
      },
      removeEventListener(type, listener) {
        listeners.set(
          type,
          (listeners.get(type) || []).filter((candidate) => candidate !== listener),
        );
      },
      emit(type, event = {}) {
        event.target ??= this;
        event.currentTarget ??= this;
        event.preventDefault ??= () => {};
        event.stopPropagation ??= () => {};
        for (const listener of [...(listeners.get(type) || [])]) listener(event);
        return event;
      },
      click() {
        const event = {
          target: this,
          currentTarget: this,
          preventDefault() {},
          stopPropagation() {},
        };
        this.onclick?.(event);
        this.emit("click", event);
      },
      remove() { this.removed = true; },
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 48, height: 48 };
      },
      setPointerCapture() {},
      releasePointerCapture() {},
    };
  }
  const elements = Object.fromEntries([
    ".edit", ".overlay", ".enter", ".card", "form", "h2", "input", ".error", ".close", ".save",
    ".menu-fab", ".sidebar-layer", ".sidebar", ".sidebar-title",
    ".sidebar-scrim", ".continue", ".reload", ".enter-fullscreen",
    ".exit-fullscreen", ".exit", ".info", ".logs", ".info-overlay",
    ".info-close", ".info-title", ".game-name", ".session-info",
    ".logs-overlay", ".logs-card", ".logs-output", ".logs-clear", ".logs-close",
    ".allow", ".deny", ".actions", ".capability-copy", ".capability-title",
  ].map((selector) => [selector, fakeElement(selector)]));
  elements[".edit"].hidden = true;
  elements[".overlay"].hidden = true;
  elements[".sidebar-layer"].hidden = true;
  elements[".info-overlay"].hidden = true;
  elements[".logs-overlay"].hidden = true;
  const mountedHosts = [];
  const shadowHtml = [];
  function createShadowRoot(host) {
    const listeners = new Map();
    const root = {
      host,
      activeElement: null,
      set innerHTML(value) { shadowHtml.push(value); },
      get innerHTML() { return shadowHtml.at(-1) || ""; },
      appendChild() {},
      querySelector(selector) {
        const element = elements[selector];
        if (element) element.__root = root;
        return element;
      },
      querySelectorAll() { return []; },
      addEventListener(type, listener) {
        const current = listeners.get(type) || [];
        current.push(listener);
        listeners.set(type, current);
      },
      emit(type, event = {}) {
        event.preventDefault ??= () => {};
        event.stopPropagation ??= () => {};
        for (const listener of [...(listeners.get(type) || [])]) listener(event);
      },
      listenerCount(type) {
        return (listeners.get(type) || []).length;
      },
    };
    shadowRoots.push(root);
    return root;
  }
  document = {
    body: { appendChild(element) { mountedHosts.push(element.id); } },
    fullscreenElement: null,
    activeElement: null,
    addEventListener() {},
    createElement(tagName) {
      const attributes = new Map();
      const element = {
        id: "", className: "", type: "", textContent: "", onclick: null,
        removed: false,
        setAttribute(name, value) { attributes.set(name, String(value)); },
        getAttribute(name) { return attributes.get(name) ?? null; },
        attachShadow: () => createShadowRoot(element),
        remove() { this.removed = true; },
      };
      if (tagName === "button") elements[".later"] = element;
      return element;
    },
  };
  document.documentElement = {
    clientWidth: 800,
    clientHeight: 600,
    async requestFullscreen() {
      document.fullscreenElement = document.documentElement;
    },
  };
  document.exitFullscreen = async () => {
    document.fullscreenElement = null;
  };
  const gameFocusTarget = fakeElement(".game-focus-target");
  gameFocusTarget.focus();
  let currentPlayerId = null;
  let currentNickname = null;
  let historyLength = uiOptions.historyLength ?? 1;
  let historyState = null;
  const historyOperations = [];

  class FakeWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;
    static instances = [];

    constructor(url) {
      this.url = url;
      this.readyState = FakeWebSocket.CONNECTING;
      this.listeners = new Map();
      FakeWebSocket.instances.push(this);
      queueMicrotask(() => {
        if (this.readyState !== FakeWebSocket.CONNECTING) return;
        this.readyState = FakeWebSocket.OPEN;
        this.emit("open", {});
        this.emit("message", {
          data: JSON.stringify({
            type: "session.state",
            session: {
              id: "s-1",
              gameId: "com.playmesh.browser-test",
              joinCode: "ABC123",
              displayMode: "multi_screen",
              state: "lobby",
              authorityClientId: "p-authority",
              players: [
                {
                  id: currentPlayerId,
                  nickname: currentNickname,
                  avatar: null,
                  role: "player",
                  connected: true,
                  source: "lan_html",
                  latencyMs: 14,
                },
              ],
            },
          }),
        });
      });
    }

    addEventListener(type, listener, options = {}) {
      const wrapped = options.once
        ? (event) => {
            this.removeEventListener(type, wrapped);
            listener(event);
          }
        : listener;
      const listeners = this.listeners.get(type) || [];
      listeners.push(wrapped);
      this.listeners.set(type, listeners);
    }

    removeEventListener(type, listener) {
      this.listeners.set(
        type,
        (this.listeners.get(type) || []).filter((candidate) => candidate !== listener),
      );
    }

    emit(type, event) {
      for (const listener of [...(this.listeners.get(type) || [])]) listener(event);
    }

    send(rawMessage) {
      const message = JSON.parse(rawMessage);
      if (message.type === "session.ping") {
        queueMicrotask(() => this.emit("message", {
          data: JSON.stringify({
            type: "session.pong",
            payload: {
              ...message.payload,
              authorityAvailable: true,
              serverReceivedAt: message.payload.clientSentAt,
              serverSentAt: message.payload.clientSentAt,
            },
          }),
        }));
      }
    }

    close(code = 1000, reason = "") {
      if (this.readyState >= FakeWebSocket.CLOSING) return;
      this.readyState = FakeWebSocket.CLOSING;
      queueMicrotask(() => {
        this.readyState = FakeWebSocket.CLOSED;
        this.emit("close", { code, reason });
      });
    }

    disconnect(reason = "network lost") {
      this.close(1006, reason);
    }
  }

  const window = {
    __PLAYMESH_BROWSER__: {
      _playmeshPlatformUi: platformCatalog(),
      coreBase: "http://192.168.1.20:42000/",
      gameId: uiOptions.gameId || "com.playmesh.browser-test",
      gameName: uiOptions.gameName || "浏览器测试游戏",
      tags: uiOptions.tags || ["派对", "本地多人"],
      joinCode: "ABC123",
      shareToken: "game-token",
      bucketEndpoint: "/bucket",
      orientation: "portrait",
      ...(uiOptions.requiredCapabilities
        ? { requiredCapabilities: [...uiOptions.requiredCapabilities] }
        : { requiredCapabilities: [] }),
      ...(uiOptions.availableCapabilities
        ? { availableCapabilities: [...uiOptions.availableCapabilities] }
        : {}),
      ...(uiOptions.capabilityRegistry
        ? { capabilityRegistry: structuredClone(uiOptions.capabilityRegistry) }
        : {}),
    },
    localStorage: {
      getItem: (key) => browserLocalStorage.get(key) ?? null,
      setItem: (key, value) => browserLocalStorage.set(key, value),
    },
    document,
    location: { reload() {} },
    XMLHttpRequest: BrowserStorageXMLHttpRequest,
    fetch: async (url, options) => {
      const requestUrl = String(url);
      if (requestUrl.startsWith("/bucket/_playmesh-json/v1")) {
        const encodedBody = options.body || Buffer.from(
          new URL(requestUrl, "http://playmesh.local").searchParams.get("payload"),
          "base64url",
        ).toString("utf8");
        const envelope = JSON.parse(encodedBody);
        const calculatedDigest = Buffer.from(
          await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(encodedBody)),
        ).toString("hex");
        assert.equal(options.headers["X-Playmesh-Content-Sha256"], calculatedDigest);
        standardStorageRequests.push({ url: requestUrl, options, envelope });
        const key = `${envelope.bucket}:${envelope.key}`;
        let status = 200;
        let result;
        let error;
        if (envelope.operation === "get") {
          result = {
            value: hostData.has(key) ? hostData.get(key) : null,
            revision: browserBucketRevision(envelope.bucket),
          };
        } else if (envelope.operation === "set") {
          const currentRevision = browserBucketRevision(envelope.bucket);
          if (envelope.expectedRevision !== currentRevision) {
            status = 409;
            error = { code: "storage_revision_conflict", message: "revision conflict" };
          } else {
            hostData.set(key, envelope.value);
            result = { revision: browserBucketRevision(envelope.bucket) };
          }
        } else if (envelope.operation === "remove") {
          const currentRevision = browserBucketRevision(envelope.bucket);
          if (envelope.expectedRevision !== currentRevision) {
            status = 409;
            error = { code: "storage_revision_conflict", message: "revision conflict" };
          } else {
            hostData.delete(key);
            result = { revision: browserBucketRevision(envelope.bucket) };
          }
        } else if (envelope.operation === "clear") {
          const currentRevision = browserBucketRevision(envelope.bucket);
          if (envelope.expectedRevision !== currentRevision) {
            status = 409;
            error = { code: "storage_revision_conflict", message: "revision conflict" };
          } else {
            for (const existing of hostData.keys()) {
              if (existing.startsWith(`${envelope.bucket}:`)) hostData.delete(existing);
            }
            result = { revision: browserBucketRevision(envelope.bucket) };
          }
        }
        return {
          ok: status >= 200 && status < 300,
          status,
          json: async () => ({
            protocolVersion: "1.0.0",
            requestId: envelope.requestId,
            ...(error ? { error } : { result }),
          }),
        };
      }
      if (requestUrl.startsWith("/bucket/")) {
        uploadCommands.push({ url, options });
        return {
          ok: true,
          json: async () => ({
            url: "/bucket/browser_save/1770000000000.png",
          }),
        };
      }
      if (requestUrl.endsWith("/players/me")) {
        const command = JSON.parse(options.body);
        nicknameCommands.push({ ...command, url: requestUrl, headers: options.headers });
        currentNickname = command.nickname;
        return {
          ok: true,
          json: async () => ({
            player: {
              id: currentPlayerId, nickname: currentNickname, avatar: null,
              role: "player", connected: true,
              source: "lan_html", latencyMs: 11,
            },
            session: {
              id: "s-1", gameId: "com.playmesh.browser-test",
              joinCode: "ABC123", displayMode: "multi_screen",
              authorityClientId: "p-authority",
              players: [{
                id: currentPlayerId, nickname: currentNickname, avatar: null,
                role: "player", connected: true,
                source: "lan_html", latencyMs: 11,
              }],
            },
          }),
        };
      }
      const joinCommand = JSON.parse(options.body);
      joinUrls.push(requestUrl);
      joinCommands.push(joinCommand);
      assert.deepEqual(
        Object.keys(joinCommand).sort(),
        ["joinCode", "nickname", "playerId", "shareToken", "source"],
      );
      assert.equal(
        joinCommand.nickname,
        appIdentity?.nickname || browserLocalStorage.get("playmesh.nickname.v1"),
      );
      joins += 1;
      const playerId = joinCommand.playerId;
      currentPlayerId = playerId;
      currentNickname = joinCommand.nickname;
      return {
        ok: true,
        json: async () => ({
          webSocketPath: "/v1/sessions/s-1/ws",
          binaryWebSocketPath: "/v1/sessions/s-1/binary",
          credential: {
            token: `player-token-${joins}`,
            player: {
              id: playerId, nickname: currentNickname, avatar: null,
              role: "player", connected: false,
              source: "lan_html", latencyMs: null,
            },
            reconnected,
          },
          session: {
            id: "s-1", gameId: "com.playmesh.browser-test",
            joinCode: "ABC123", displayMode: "multi_screen",
            authorityClientId: "p-authority",
            players: [{
              id: playerId, nickname: currentNickname, avatar: null,
              role: "player", connected: false,
              source: "lan_html", latencyMs: null,
            }],
          },
        }),
      };
    },
    WebSocket: FakeWebSocket,
    crypto: webcrypto,
    TextEncoder,
    TextDecoder,
    history: {
      get length() { return historyLength; },
      get state() { return historyState; },
      replaceState(state, _title, url) {
        historyState = state;
        historyOperations.push({ type: "replace", state, url });
      },
      pushState(state, _title, url) {
        historyState = state;
        historyLength += 1;
        historyOperations.push({ type: "push", state, url });
      },
      back() {
        uiOptions.onHistoryBack?.();
      },
      go(delta) {
        historyOperations.push({ type: "go", delta });
        uiOptions.onHistoryGo?.(delta);
      },
    },
    location: {
      href: "http://127.0.0.1:43000/app/index.html",
      reload() {
        uiOptions.onReload?.();
      },
      replace(url) {
        historyOperations.push({ type: "replace-location", url });
      },
    },
    closed: false,
    close() {
      uiOptions.onClose?.();
    },
    navigator: navigatorOverride || {
      languages: [...browserLocales],
      language: browserLocales[0],
    },
    console: {
      log: (...args) => consoleEntries.push({ level: "log", args }),
      info: (...args) => consoleEntries.push({ level: "info", args }),
      warn: (...args) => consoleEntries.push({ level: "warn", args }),
      error: (...args) => consoleEntries.push({ level: "error", args }),
      debug: (...args) => consoleEntries.push({ level: "debug", args }),
    },
    URL,
    screen: {
      orientation: {
        async lock(orientation) {
          orientationLocks.push(orientation);
        },
      },
    },
    innerWidth: 800,
    innerHeight: 600,
    addEventListener(type, listener) {
      const current = windowListeners.get(type) || [];
      current.push(listener);
      windowListeners.set(type, current);
    },
    queueMicrotask,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  window.window = window;
  if (appIdentity) {
    const publicAppApi = {
      version: "3.3.0",
      ready: Promise.resolve({
        available: true,
        sdkVersion: "3.3.0",
        runtime: {
          coreBase: "http://127.0.0.1:43000/",
          playerSource: "lan_app",
        },
      }),
      isAvailable: () => true,
      runtime: {
        getLocale: () => appLocaleId,
      },
      identity: { getCurrent: () => ({ ...appIdentity }) },
      capabilities: {
        getRegistry: () => [],
        getAvailable: () => [],
        getDeclared: () => [],
      },
      device: {
        getPlatform: () => "android",
        setFullscreen: async (enabled, orientation) => {
          fullscreenRequests.push({ enabled, orientation });
        },
      },
    };
    let privatePlatformConfiguration = platformConfiguration(appLocaleId);
    window[appInternalKey] = {
      publicApi: publicAppApi,
      takePlatformUiConfiguration() {
        const configuration = privatePlatformConfiguration;
        privatePlatformConfiguration = null;
        return configuration;
      },
      configureRuntimeGame: async (declaration) => {
        runtimeGameDeclarations.push(structuredClone(declaration));
        return {
          available: true,
          runtime: {
            coreBase: "http://127.0.0.1:43000/",
            playerSource: "lan_app",
          },
          capabilityRegistry: [],
          device: {
            platform: "android",
            capabilities: [],
            declaredCapabilities: [
              ...(declaration.requiredCapabilities || []),
            ],
          },
        };
      },
      syncAvatar: async () => {},
    };
  } else {
    vm.runInNewContext(appSource, window, { filename: "playmesh-app.js" });
    window[appInternalKey].publicApi.ui.configure({ fallbackUi: false });
  }
  vm.runInNewContext(source, window, { filename: "playmesh-main.js" });
  window.__platformBackIntent = vm.runInNewContext(
    'window[Symbol.for("playmesh.platform-ui.back")]',
    window,
  );
  window.__platformMenuIntent = vm.runInNewContext(
    'window[Symbol.for("playmesh.platform-ui.menu")]',
    window,
  );
  window.__ui = elements;
  window.__mountedHosts = mountedHosts;
  window.__shadowHtml = shadowHtml;
  window.__shadowRoots = shadowRoots;
  window.__gameFocusTarget = gameFocusTarget;
  window.__consoleEntries = consoleEntries;
  window.__fullscreenRequests = fullscreenRequests;
  window.__runtimeGameDeclarations = runtimeGameDeclarations;
  window.__nativeSidebarRequests = nativeSidebarRequests;
  window.__orientationLocks = orientationLocks;
  window.__historyOperations = historyOperations;
  window.__sockets = FakeWebSocket.instances;
  window.__dispatchWindowEvent = (type, event) => {
    for (const listener of windowListeners.get(type) || []) listener(event);
  };
  return window;
}

function emitKey(container, target, key, options = {}) {
  const event = {
    key,
    keyCode: options.keyCode,
    shiftKey: options.shiftKey === true,
    target,
    defaultPrevented: false,
    propagationStopped: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {
      this.propagationStopped = true;
    },
  };
  container.emit("keydown", event);
  return event;
}

function emitWindowKey(page, target, key, options = {}) {
  const event = {
    key,
    keyCode: options.keyCode,
    repeat: options.repeat === true,
    target,
    defaultPrevented: false,
    propagationStopped: false,
    immediatePropagationStopped: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {
      this.propagationStopped = true;
    },
    stopImmediatePropagation() {
      this.immediatePropagationStopped = true;
    },
  };
  page.__dispatchWindowEvent("keydown", event);
  return event;
}

const firstPage = createPage();
assert.equal(
  "_playmeshPlatformUi" in firstPage.__PLAYMESH_BROWSER__,
  false,
  "private platform UI messages must be consumed during SDK evaluation",
);
const playerJoinEvents = [];
const playerLeaveEvents = [];
const playerReconnectEvents = [];
firstPage.playmesh.main.session.onPlayerJoin((event) => playerJoinEvents.push(event));
firstPage.playmesh.main.session.onPlayerLeave((event) => playerLeaveEvents.push(event));
firstPage.playmesh.main.session.onPlayerReconnect((event) => playerReconnectEvents.push(event));
assert.equal(typeof firstPage.playmesh.app.runtime.getLocale, "function");
assert.equal(firstPage.playmesh.app.runtime.getLocale(), "zh-CN");
while (!firstPage.__ui.form.onsubmit) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(firstPage.__ui[".overlay"].hidden, false, "首次进入应显示昵称输入层");
await new Promise((resolve) => setTimeout(resolve, 0));
const firstProfileRoot = firstPage.__shadowRoots.at(-1);
assert.equal(
  firstProfileRoot.activeElement,
  firstPage.__ui.input,
  "nickname dialog must move focus into its first field",
);
const nicknameTab = emitKey(
  firstPage.__ui[".overlay"],
  firstPage.__ui.input,
  "Tab",
);
assert.equal(nicknameTab.defaultPrevented, true);
assert.equal(
  firstProfileRoot.activeElement,
  firstPage.__ui[".save"],
  "required nickname dialog must trap Tab without exposing its hidden cancel button",
);
emitKey(
  firstPage.__ui[".overlay"],
  firstPage.__ui[".save"],
  "Tab",
  { shiftKey: true },
);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui.input);
emitKey(firstPage.__ui[".overlay"], firstPage.__ui.input, "Backspace");
assert.equal(
  firstPage.__ui[".overlay"].hidden,
  false,
  "editing keys inside the nickname input must not close its dialog",
);
firstPage.__ui.input.value = "缓存玩家";
await firstPage.__ui.form.onsubmit({ preventDefault() {} });
const firstBootstrap = await firstPage.playmesh.ready;
assert.strictEqual(
  firstBootstrap.app,
  await firstPage.playmesh.app.ready,
  "根 ready 的 app 结果必须与 playmesh.app.ready 保持同一引用",
);
assert.deepEqual(Object.keys(firstPage.playmesh).sort(), ["app", "main", "ready"]);
assert.equal(firstBootstrap.main.sdkVersion, "4.1.0");
assert.equal(firstPage.playmesh.app.version, "3.3.0");
assert.equal(firstBootstrap.app.available, false);
assert.equal(JSON.stringify(firstBootstrap).includes("sidebar.title"), false);
assert.equal(Object.isFrozen(firstPage.playmesh.main.gameInfo), true);
const currentGameInfo = firstPage.playmesh.main.gameInfo.getCurrent();
assert.equal(currentGameInfo.id, "com.playmesh.browser-test");
assert.equal(currentGameInfo.name, "浏览器测试游戏");
assert.deepEqual([...currentGameInfo.tags], ["派对", "本地多人"]);
assert.equal(currentGameInfo.multiplayer, true);
assert.equal(currentGameInfo.displayMode, "multi_screen");
assert.deepEqual([...currentGameInfo.requiredCapabilities], []);
assert.deepEqual(
  Object.keys(firstBootstrap.main.player).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.deepEqual(
  Object.keys(firstBootstrap.main.session.players[0]).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.equal(firstPage.playmesh.app.runtime.getLocale(), "zh-CN");
assert.equal("messages" in firstPage.playmesh.app.runtime, false);
assert.equal(JSON.stringify(firstPage.playmesh.app.runtime), "{}");
assert.equal(joins, 1);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(
  firstPage.document.activeElement,
  firstPage.__gameFocusTarget,
  "closing the initial nickname dialog must restore the page focus",
);
while (firstPage.__orientationLocks.length === 0) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.deepEqual(
  firstPage.__orientationLocks,
  ["portrait"],
  "浏览器应无弹窗尽力自动进入全屏并锁定方向",
);
assert.equal(firstPage.playmesh.app.isAvailable(), false);
assert.equal(firstPage.playmesh.app.identity.getCurrent(), null);
assert.equal(firstPage.playmesh.main.session.isAuthority(), false);
assert.equal(firstPage.__mountedHosts.includes("playmesh-browser-nickname-ui"), true);
assert.equal(
  firstPage.__mountedHosts.includes("playmesh-browser-fullscreen"),
  false,
  "浏览器不得自动弹出全屏提示层",
);
// 菜单、日志和性能覆盖层已迁移到 playmesh-app.js；对应 DOM 与输入
// 契约由 test_app_platform_ui_sdk.mjs 独立覆盖。
const persistedBrowserId = browserLocalStorage.get("playmesh.player-id.v1");
assert.match(persistedBrowserId, /^p_[a-f0-9]{32}$/);
assert.equal(firstPage.playmesh.main.player.getCurrent().id, persistedBrowserId);
assert.equal(playerJoinEvents.length, 1);
assert.equal(playerJoinEvents[0].player.id, persistedBrowserId);
assert.equal(playerJoinEvents[0].isCurrentPlayer, true);
assert.deepEqual(
  Object.keys(playerJoinEvents[0].player).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
const connectedSession = firstPage.playmesh.main.session.getCurrent();
receiveMain(firstPage, {
  type: "transport.message",
  message: {
    type: "session.state",
    session: {
      ...connectedSession,
      players: connectedSession.players.map((player) => ({ ...player, connected: false })),
    },
  },
});
assert.equal(playerLeaveEvents.length, 1);
receiveMain(firstPage, {
  type: "transport.message",
  message: { type: "session.state", session: connectedSession },
});
assert.equal(playerReconnectEvents.length, 1);
assert.equal(
  firstPage.__consoleEntries.some(
    (entry) =>
      String(entry.args[0]).includes("Playmesh 新玩家已加入房间") &&
      String(entry.args[0]).includes('"onlinePlayers":1') &&
      String(entry.args[0]).includes('"roomType":"multi_screen"'),
  ),
  true,
);
assert.equal(
  firstPage.__consoleEntries.some(
    (entry) => String(entry.args[0]).includes("Playmesh 玩家已掉线或退出房间"),
  ),
  true,
);
assert.notEqual(
  firstPage.playmesh.main.player.getCurrent().id,
  firstPage.playmesh.main.session.getCurrent().authorityClientId,
  "浏览器首个加入玩家不能成为 Authority",
);

const appPage = createPage(
  { userId: "u-current-app", nickname: "App 玩家" },
  false,
  ["zh-CN"],
  "en-US",
);
const appReadyResult = await appPage.playmesh.app.ready;
const appRootReadyResult = await appPage.playmesh.ready;
assert.strictEqual(
  appRootReadyResult.app,
  appReadyResult,
  "运行时能力配置返回新对象时，根 ready 仍必须复用原 app.ready 结果",
);
assert.equal(appPage.playmesh.app.isAvailable(), true);
assert.deepEqual(appPage.__runtimeGameDeclarations, [{
  requiredCapabilities: [],
}]);
assert.equal(appPage.playmesh.app.runtime.getLocale(), "en-US");
receiveMain(appPage, {
  type: "platform.ui.configure",
  configuration: platformConfiguration("zh-CN", "light"),
});
assert.equal(
  appPage.playmesh.app.runtime.getLocale(),
  "en-US",
  "a test App adapter owns its locale independently from Game SDK UI messages",
);
assert.equal(
  appPage.playmeshApp,
  undefined,
  "App SDK must not expose a second public global",
);
assert.deepEqual(Object.keys(appPage.playmesh.main).filter((key) => key.startsWith("__")), []);
assert.deepEqual(appPage.__fullscreenRequests, [
  { enabled: true, orientation: "portrait" },
]);
assert.equal(joinCommands.at(-1).playerId, "u-current-app");
assert.equal(joinCommands.at(-1).nickname, "App 玩家");
assert.equal(appPage.__ui[".edit"].hidden, true);
assert.equal(appPage.__mountedHosts.includes("playmesh-browser-nickname-ui"), false);
// Game SDK 不再桥接 App 菜单按键，也不再创建平台菜单覆盖层。
assert.equal(firstPage.playmesh.app.performance.getLatency() >= 0, true);
assert.equal(
  firstPage.playmesh.main.session.getCurrent().players[0].connected,
  true,
  "WebSocket open 后立即到达的最新会话快照不得丢失",
);
assert.equal(browserLocalStorage.get("playmesh.nickname.v1"), "缓存玩家");
const hostBucket = firstPage.playmesh.main.storage.getBucket("browser_save");
assert.equal(hostBucket.flush, undefined);
await hostBucket.setData("score", 18);
assert.equal(await hostBucket.getData("score"), 18);
assert.equal(
  standardStorageRequests.every(
    (request) => request.url.startsWith("/bucket/_playmesh-json/v1") &&
      request.options.method === ({ get: "GET", set: "PUT", remove: "DELETE", clear: "DELETE" })[request.envelope.operation] &&
      request.options.credentials === "same-origin" &&
      request.envelope.gameId === "com.playmesh.browser-test" &&
      request.envelope.requestId.startsWith("storage-") &&
      request.envelope.shareToken === undefined,
  ),
  true,
);
assert.deepEqual(
  standardStorageRequests.map((request) => request.envelope.operation),
  ["get", "set", "get"],
);
assert.equal(
  standardStorageRequests.some((request) => request.envelope.operation === "set"),
  true,
);
const browserSyncBucket = firstPage.playmesh.main.storage.getBucket("目录/浏览器存档");
assert.equal(browserSyncBucket.getDataSync("$playmesh.gdevelop.root.v1"), null);
browserSyncBucket.setDataSync("$playmesh.gdevelop.root.v1", { round: 2 });
assert.equal(
  JSON.stringify(browserSyncBucket.getDataSync("$playmesh.gdevelop.root.v1")),
  JSON.stringify({ round: 2 }),
);
assert.deepEqual(
  synchronousStorageRequests.slice(-3).map((request) => request.method),
  ["GET", "PUT", "GET"],
);
const uploadedFile = { name: "avatar.png", size: 4 };
assert.equal(
  await hostBucket.upload(uploadedFile),
  "/bucket/browser_save/1770000000000.png",
);
assert.equal(uploadCommands.length, 1);
assert.equal(
  uploadCommands[0].url,
  "/bucket/browser_save?name=avatar.png",
);
assert.equal(
  uploadCommands[0].options.headers["X-Playmesh-Share-Token"],
  "game-token",
);
assert.equal(uploadCommands[0].options.body, uploadedFile);

const refreshedPage = createPage();
await refreshedPage.playmesh.ready;
assert.equal(joins, 3, "刷新必须使用持久化浏览器身份重新加入");
assert.equal(refreshedPage.playmesh.main.player.getCurrent().id, persistedBrowserId);
assert.equal(refreshedPage.playmesh.main.player.getCurrent().nickname, "缓存玩家");
assert.equal(
  refreshedPage.playmesh.main.player.getCurrent().id,
  firstPage.playmesh.main.player.getCurrent().id,
);
assert.equal(nicknameCommands.length, 0);
await refreshedPage.playmesh.main.player.setNickname("修改后的玩家");
assert.equal(refreshedPage.playmesh.main.player.getCurrent().nickname, "修改后的玩家");
assert.equal(browserLocalStorage.get("playmesh.nickname.v1"), "修改后的玩家");
assert.equal(nicknameCommands.length, 1);
assert.equal(nicknameCommands[0].nickname, "修改后的玩家");
assert.equal(nicknameCommands[0].headers.Authorization, "Bearer player-token-3");
assert.equal(nicknameCommands[0].url, "http://192.168.1.20:42000/v1/sessions/s-1/players/me");
assert.equal(joinUrls.includes("http://127.0.0.1:43000/v1/sessions/join"), true);

const reconnectPage = createPage(null, true);
const selfReconnectEvents = [];
reconnectPage.playmesh.main.session.onPlayerReconnect((event) => selfReconnectEvents.push(event));
await reconnectPage.playmesh.ready;
assert.equal(selfReconnectEvents.length, 1);
assert.equal(selfReconnectEvents[0].isCurrentPlayer, true);
assert.equal(selfReconnectEvents[0].player.id, persistedBrowserId);

const reconnectJoins = joins;
const firstSocket = reconnectPage.__sockets.at(-1);
firstSocket.disconnect();
while (joins < reconnectJoins + 1 || reconnectPage.__sockets.at(-1) === firstSocket) {
  await new Promise((resolve) => setTimeout(resolve, 5));
}
assert.equal(
  reconnectPage.__consoleEntries.some(
    (entry) => String(entry.args[0]).includes("Playmesh 主会话 WebSocket 已掉线"),
  ),
  true,
);
assert.equal(
  reconnectPage.__consoleEntries.some(
    (entry) => String(entry.args[0]).includes("Playmesh 主会话 WebSocket 重连成功"),
  ),
  true,
);

const englishBrowserPage = createPage(null, false, ["en-GB"]);
await englishBrowserPage.playmesh.ready;
assert.equal(
  englishBrowserPage.playmesh.app.runtime.getLocale(),
  "en-GB",
  "game locale must preserve the displaying browser's own locale",
);
const japaneseBrowserPage = createPage(null, false, ["ja-JP"]);
await japaneseBrowserPage.playmesh.ready;
assert.equal(
  japaneseBrowserPage.playmesh.app.runtime.getLocale(),
  "ja-JP",
  "game locale must not be limited by Playmesh overlay translations",
);

const unreadableNavigator = {};
Object.defineProperty(unreadableNavigator, "languages", {
  get() {
    throw new Error("navigator languages unavailable");
  },
});
Object.defineProperty(unreadableNavigator, "language", {
  get() {
    throw new Error("navigator language unavailable");
  },
});
const fallbackBrowserPage = createPage(
  null,
  false,
  ["not-a-locale"],
  localizationManifest.defaultLocale,
  unreadableNavigator,
);
await fallbackBrowserPage.playmesh.ready;
assert.equal(
  fallbackBrowserPage.playmesh.app.runtime.getLocale(),
  "zh",
  "browser navigator read failures must fall back to the public zh locale",
);

const capabilityPage = createPage(
  null,
  false,
  ["zh-CN"],
  localizationManifest.defaultLocale,
  null,
  {
    gameName: "动态游戏 Ω",
    requiredCapabilities: ["developer.custom"],
    availableCapabilities: ["developer.custom"],
    capabilityRegistry: [{
      code: "developer.custom",
      name: "开发者能力 Ω",
      description: "开发者原始说明",
    }],
  },
);
while (
  capabilityPage.__shadowRoots.length === 0 ||
  capabilityPage.__shadowRoots[0].listenerCount("keydown") === 0
) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
const capabilityRoot = capabilityPage.__shadowRoots[0];
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(capabilityRoot.activeElement, capabilityPage.__ui[".deny"]);
assert.equal(
  capabilityPage.__shadowHtml.some((html) => html.includes("动态游戏 Ω")),
  true,
  "dynamic game names must remain verbatim inside the localized shell",
);
assert.equal(
  capabilityPage.__shadowHtml.some((html) => html.includes("开发者能力 Ω")),
  true,
  "developer capability labels must remain verbatim",
);
assert.equal(
  capabilityPage.__shadowHtml.some((html) => html.includes("开发者原始说明")),
  true,
  "developer capability descriptions must remain verbatim",
);
emitKey(
  capabilityRoot,
  capabilityPage.__ui[".deny"],
  "ArrowRight",
);
assert.equal(capabilityRoot.activeElement, capabilityPage.__ui[".allow"]);
emitKey(
  capabilityRoot,
  capabilityPage.__ui[".allow"],
  "Home",
);
assert.equal(capabilityRoot.activeElement, capabilityPage.__ui[".deny"]);
emitKey(
  capabilityRoot,
  capabilityPage.__ui[".deny"],
  "End",
);
assert.equal(capabilityRoot.activeElement, capabilityPage.__ui[".allow"]);
emitKey(
  capabilityRoot,
  capabilityPage.__ui[".allow"],
  "Enter",
);
await capabilityPage.playmesh.ready;
assert.equal(capabilityRoot.host.removed, true);
assert.equal(
  capabilityPage.document.activeElement,
  capabilityPage.__gameFocusTarget,
  "allowing a capability must restore the game page focus",
);

let historyBackCount = 0;
const capabilityBackPage = createPage(
  null,
  false,
  ["zh-CN"],
  localizationManifest.defaultLocale,
  null,
  {
    requiredCapabilities: ["developer.custom"],
    availableCapabilities: ["developer.custom"],
    historyLength: 2,
    onHistoryBack: () => {
      historyBackCount += 1;
    },
  },
);
const capabilityBackResult = capabilityBackPage.playmesh.ready.then(
  () => null,
  (error) => error,
);
while (
  capabilityBackPage.__shadowRoots.length === 0 ||
  capabilityBackPage.__shadowRoots[0].listenerCount("keydown") === 0
) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
const capabilityBackRoot = capabilityBackPage.__shadowRoots[0];
emitKey(
  capabilityBackRoot,
  capabilityBackPage.__ui[".deny"],
  "BrowserBack",
);
const capabilityBackError = await capabilityBackResult;
assert.equal(capabilityBackError?.code, "capability_denied");
assert.equal(capabilityBackRoot.host.removed, true);
assert.equal(
  capabilityBackPage.document.activeElement,
  capabilityBackPage.__gameFocusTarget,
);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(historyBackCount, 1);

const cachedNickname = browserLocalStorage.get("playmesh.nickname.v1");
browserLocalStorage.delete("playmesh.nickname.v1");
const requiredNicknameBackPage = createPage();
const requiredNicknameBackResult = requiredNicknameBackPage.playmesh.ready.then(
  () => null,
  (error) => error,
);
while (!requiredNicknameBackPage.__ui.form.onsubmit) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
emitKey(
  requiredNicknameBackPage.__ui[".overlay"],
  requiredNicknameBackPage.__ui.input,
  "Escape",
);
const requiredNicknameBackError = await requiredNicknameBackResult;
assert.equal(requiredNicknameBackError?.name, "AbortError");
assert.equal(requiredNicknameBackPage.__ui[".overlay"].hidden, true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(
  requiredNicknameBackPage.document.activeElement,
  requiredNicknameBackPage.__gameFocusTarget,
);
browserLocalStorage.set("playmesh.nickname.v1", cachedNickname);

console.log("Game SDK browser identity, fullscreen, logging, and reconnect contract passed");
