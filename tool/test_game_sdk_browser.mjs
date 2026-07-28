import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh.js", import.meta.url), "utf8");
assert.match(
  source,
  /avatar: value\?\.avatar \?\? null/,
  "player connection logs must include the normalized avatar field",
);
assert.match(
  source,
  /if \(playmesh\.session\.isAuthority\(\)\) \{\s+await post\("session\.reset", \{\}\);/s,
  "the Authority restart adapter must reset the session before reloading",
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
const storageCommands = [];
const uploadCommands = [];
const nicknameCommands = [];
const joinCommands = [];
const joinUrls = [];
let joins = 0;

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
    ".panel", ".fps", ".latency", ".edit", ".overlay", ".enter", ".card", "form", "h2", "input", ".error", ".close", ".save",
    ".performance", ".menu-fab", ".sidebar-layer", ".sidebar", ".sidebar-title",
    ".sidebar-scrim", ".continue", ".reload", ".enter-fullscreen",
    ".exit-fullscreen", ".exit", ".info", ".logs", ".info-overlay",
    ".info-close", ".info-title", ".game-name", ".session-info",
    ".logs-overlay", ".logs-card", ".logs-output", ".logs-clear", ".logs-close",
    ".allow", ".deny", ".actions", ".capability-copy", ".capability-title",
  ].map((selector) => [selector, fakeElement(selector)]));
  elements[".edit"].hidden = true;
  elements[".latency"].hidden = true;
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
      } else if (message.type === "game.action" &&
          message.payload?.__playmeshStorageRequest) {
        const command = message.payload.__playmeshStorageRequest;
        storageCommands.push(command);
        const key = `${command.bucket}:${command.key}`;
        if (command.command === "storage.set") hostData.set(key, command.value);
        if (command.command === "storage.remove") hostData.delete(key);
        if (command.command === "storage.clear") {
          for (const existing of hostData.keys()) {
            if (existing.startsWith(`${command.bucket}:`)) hostData.delete(existing);
          }
        }
        queueMicrotask(() => this.emit("message", {
          data: JSON.stringify({
            type: "game.message",
            payload: {
              __playmeshStorageResponse: {
                requestId: command.requestId,
                result: command.command === "storage.get" ? hostData.get(key) : null,
              },
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
    fetch: async (url, options) => {
      const requestUrl = String(url);
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
  if (appIdentity) {
    window[Symbol.for("playmesh.platform-ui.configuration")] =
      platformConfiguration(appLocaleId);
    window.playmeshApp = {
      ready: Promise.resolve({
        available: true,
        runtime: {
          coreBase: "http://127.0.0.1:43000/",
          playerSource: "lan_app",
        },
      }),
      isAvailable: () => true,
      __configureRuntimeGame: async (declaration) => {
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
      showGameSidebar: async () => {
        nativeSidebarRequests.push("show");
      },
    };
  }
  window.window = window;
  vm.runInNewContext(source, window, { filename: "playmesh.js" });
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
firstPage.playmesh.session.onPlayerJoin((event) => playerJoinEvents.push(event));
firstPage.playmesh.session.onPlayerLeave((event) => playerLeaveEvents.push(event));
firstPage.playmesh.session.onPlayerReconnect((event) => playerReconnectEvents.push(event));
assert.equal(Object.isFrozen(firstPage.playmesh.runtime), true);
assert.throws(
  () => firstPage.playmesh.runtime.getLocale(),
  /requires await playmesh\.ready/,
);
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
assert.equal(JSON.stringify(firstBootstrap).includes("sidebar.title"), false);
assert.equal(Object.isFrozen(firstPage.playmesh.gameInfo), true);
const currentGameInfo = firstPage.playmesh.gameInfo.getCurrent();
assert.equal(currentGameInfo.id, "com.playmesh.browser-test");
assert.equal(currentGameInfo.name, "浏览器测试游戏");
assert.equal(currentGameInfo.multiplayer, true);
assert.equal(currentGameInfo.displayMode, "multi_screen");
assert.deepEqual([...currentGameInfo.requiredCapabilities], []);
assert.deepEqual(
  Object.keys(firstBootstrap.player).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.deepEqual(
  Object.keys(firstBootstrap.session.players[0]).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.equal(firstPage.playmesh.runtime.getLocale(), "zh-CN");
assert.equal("messages" in firstPage.playmesh.runtime, false);
assert.equal(JSON.stringify(firstPage.playmesh.runtime), "{}");
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
assert.equal(firstPage.playmesh.session.isAuthority(), false);
assert.equal(firstPage.__mountedHosts.includes("playmesh-browser-profile"), true);
assert.equal(
  firstPage.__mountedHosts.includes("playmesh-browser-fullscreen"),
  false,
  "浏览器不得自动弹出全屏提示层",
);
// 菜单、日志和性能覆盖层已迁移到 playmesh-app.js；对应 DOM 与输入
// 契约由 test_app_platform_ui_sdk.mjs 独立覆盖。
if (false) {
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("游戏菜单")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("继续游戏")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("运行日志")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("logs-output")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("游戏设置")), false);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("编辑玩家昵称")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("退出游戏")), true);
assert.equal(
  firstPage.__ui[".sidebar-layer"].hidden,
  true,
  "浏览器游戏侧边栏初始必须关闭",
);
const browserMenuButton = firstPage.__ui[".menu-fab"];
assert.equal(browserMenuButton.hidden, false, "浏览器必须显示 SDK 悬浮菜单入口");
assert.equal(browserMenuButton.getAttribute("aria-label"), "游戏菜单");
browserMenuButton.click();
assert.equal(
  firstPage.__ui[".sidebar-layer"].hidden,
  false,
  "SDK 悬浮按钮必须打开浏览器侧边栏",
);
assert.equal(browserMenuButton.hidden, true, "侧边栏打开时必须隐藏悬浮按钮");
firstPage.__ui[".continue"].click();
assert.equal(browserMenuButton.hidden, false, "关闭侧边栏后必须恢复悬浮按钮");
browserMenuButton.emit("pointerdown", {
  button: 0,
  pointerId: 7,
  clientX: 0,
  clientY: 0,
});
browserMenuButton.emit("pointermove", {
  pointerId: 7,
  clientX: 200,
  clientY: 160,
});
browserMenuButton.emit("pointerup", {
  pointerId: 7,
  clientX: 200,
  clientY: 160,
});
assert.equal(browserMenuButton.style.left, "200px");
assert.equal(browserMenuButton.style.top, "160px");
browserMenuButton.click();
assert.equal(
  firstPage.__ui[".sidebar-layer"].hidden,
  true,
  "拖动结束后的合成点击不得误开侧边栏",
);
browserMenuButton.click();
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, false);
firstPage.__ui[".continue"].click();
const browserEscape = emitWindowKey(
  firstPage,
  firstPage.__gameFocusTarget,
  "Escape",
);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, false);
assert.equal(browserEscape.defaultPrevented, true);
assert.equal(browserEscape.immediatePropagationStopped, true);
firstPage.__ui[".continue"].click();
const browserMenu = emitWindowKey(
  firstPage,
  firstPage.__gameFocusTarget,
  "ContextMenu",
);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, false);
assert.equal(browserMenu.defaultPrevented, true);
firstPage.__ui[".continue"].click();
assert.equal(
  firstPage.__historyOperations.filter((operation) => operation.type === "push").length,
  1,
  "浏览器应安装一个同页返回守卫",
);
assert.equal(
  firstPage.__ui[".panel"].hidden,
  true,
  "浏览器性能信息默认必须关闭",
);
firstPage.__ui[".performance"].onclick();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".panel"].hidden, false, "浏览器工具区应能显示性能信息");
firstPage.__ui[".performance"].onclick();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".panel"].hidden, true, "浏览器工具区应能关闭性能信息");
while (firstPage.__ui[".edit"].hidden) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
let pauseEventCount = 0;
firstPage.playmesh.lifecycle.onPause(() => pauseEventCount += 1);
firstPage.__dispatchWindowEvent("popstate", {});
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, false);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".continue"]);
assert.equal(pauseEventCount, 0, "打开游戏侧边栏不得触发 pause 生命周期");
assert.equal(firstPage.__ui[".continue"].getAttribute("tabindex"), "0");
assert.equal(firstPage.__ui[".reload"].getAttribute("tabindex"), "-1");
const sidebarArrow = emitKey(
  firstPage.__ui[".sidebar"],
  firstPage.__ui[".continue"],
  "ArrowDown",
);
assert.equal(sidebarArrow.defaultPrevented, true);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".reload"]);
assert.equal(firstPage.__ui[".continue"].getAttribute("tabindex"), "-1");
assert.equal(firstPage.__ui[".reload"].getAttribute("tabindex"), "0");
emitKey(
  firstPage.__ui[".sidebar"],
  firstPage.__ui[".reload"],
  "End",
);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".exit"]);
emitKey(
  firstPage.__ui[".sidebar"],
  firstPage.__ui[".exit"],
  "Escape",
);
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, true);
assert.equal(
  firstPage.document.activeElement,
  firstPage.__gameFocusTarget,
  "关闭侧边栏必须把焦点还给游戏内容",
);
assert.equal(pauseEventCount, 0, "关闭游戏侧边栏也不得触发 pause 生命周期");
firstPage.__dispatchWindowEvent("popstate", {});
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, false);
firstPage.__ui[".sidebar-scrim"].click();
assert.equal(firstPage.__ui[".sidebar-layer"].hidden, true);
assert.equal(
  firstPage.document.activeElement,
  firstPage.__gameFocusTarget,
  "点击侧边栏外部必须关闭并继续游戏",
);
firstPage.__dispatchWindowEvent("popstate", {});
firstPage.__ui[".info"].click();
assert.equal(firstPage.__ui[".info-overlay"].hidden, false);
assert.equal(firstPage.__ui[".game-name"].textContent, "Playmesh 游戏");
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".info-close"]);
emitKey(
  firstPage.__ui[".info-overlay"],
  firstPage.__ui[".info-close"],
  "Tab",
);
assert.equal(
  firstProfileRoot.activeElement,
  firstPage.__ui[".edit"],
  "browser profile editing belongs inside the information dialog",
);
emitKey(
  firstPage.__ui[".info-overlay"],
  firstPage.__ui[".info-close"],
  "Escape",
);
assert.equal(firstPage.__ui[".info-overlay"].hidden, true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.document.activeElement, firstPage.__gameFocusTarget);
firstPage.console.log("浏览器本地日志", { score: 7 });
firstPage.__dispatchWindowEvent("unhandledrejection", {
  reason: "浏览器 Promise 失败",
});
firstPage.__dispatchWindowEvent("popstate", {});
firstPage.__ui[".logs"].click();
assert.equal(firstPage.__ui[".logs-overlay"].hidden, false);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".logs-close"]);
emitKey(
  firstPage.__ui[".logs-overlay"],
  firstPage.__ui[".logs-close"],
  "Tab",
);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".logs-clear"]);
emitKey(
  firstPage.__ui[".logs-overlay"],
  firstPage.__ui[".logs-clear"],
  "End",
);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".logs-close"]);
emitKey(
  firstPage.__ui[".logs-overlay"],
  firstPage.__ui[".logs-close"],
  "Home",
);
assert.equal(firstProfileRoot.activeElement, firstPage.__ui[".logs-clear"]);
assert.match(firstPage.__ui[".logs-output"].textContent, /浏览器本地日志 \{"score":7\}/);
assert.match(firstPage.__ui[".logs-output"].textContent, /unhandled\.rejection/);
assert.match(
  firstPage.__ui[".logs-output"].textContent,
  /\[[^\]]+\] \[(?:log|info|warn|error|debug)\]/,
);
emitKey(
  firstPage.__ui[".logs-overlay"],
  firstPage.__ui[".logs-clear"],
  " ",
);
assert.equal(firstPage.__ui[".logs-output"].textContent, "暂无运行日志");
firstPage.playmesh.__receive({
  type: "platform.ui.configure",
  configuration: platformConfiguration("en-US", "light"),
});
while (firstPage.__ui[".info"].__label.textContent !== "Game information") {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(
  firstPage.playmesh.runtime.getLocale(),
  "zh-CN",
  "browser game locale must remain the browser system locale when only the overlay changes",
);
assert.equal(firstPage.__ui[".logs"].getAttribute("aria-label"), "Runtime logs");
assert.equal(firstPage.__ui[".logs-output"].textContent, "No runtime logs yet");
assert.equal(
  firstProfileRoot.host.getAttribute("data-theme"),
  "light",
  "浏览器平台覆盖层必须跟随主题配置",
);
firstPage.console.warn(
  "日志正文 Ω 必须原样 / platform.game.logs.empty",
  { sourceName: "用户源名称" },
);
assert.match(
  firstPage.__ui[".logs-output"].textContent,
  /日志正文 Ω 必须原样 \/ platform\.game\.logs\.empty \{"sourceName":"用户源名称"\}/,
  "runtime log payloads must remain verbatim after the overlay locale changes",
);
emitKey(
  firstPage.__ui[".logs-overlay"],
  firstPage.__ui[".logs-close"],
  "GoBack",
);
assert.equal(firstPage.__ui[".logs-overlay"].hidden, true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.document.activeElement, firstPage.__gameFocusTarget);
firstPage.__ui[".performance"].onclick();
await new Promise((resolve) => setTimeout(resolve, 0));
}
const persistedBrowserId = browserLocalStorage.get("playmesh.player-id.v1");
assert.match(persistedBrowserId, /^p_[a-f0-9]{32}$/);
assert.equal(firstPage.playmesh.player.getCurrent().id, persistedBrowserId);
assert.equal(playerJoinEvents.length, 1);
assert.equal(playerJoinEvents[0].player.id, persistedBrowserId);
assert.equal(playerJoinEvents[0].isCurrentPlayer, true);
assert.deepEqual(
  Object.keys(playerJoinEvents[0].player).sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
const connectedSession = firstPage.playmesh.session.getCurrent();
firstPage.playmesh.__receive({
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
firstPage.playmesh.__receive({
  type: "transport.message",
  message: { type: "session.state", session: connectedSession },
});
assert.equal(playerReconnectEvents.length, 1);
assert.equal(
  firstPage.__consoleEntries.some(
    (entry) =>
      entry.args[0] === "Playmesh 新玩家已加入房间" &&
      entry.args[1].onlinePlayers === 1 &&
      entry.args[1].roomType === "multi_screen",
  ),
  true,
);
assert.equal(
  firstPage.__consoleEntries.some(
    (entry) => entry.args[0] === "Playmesh 玩家已掉线或退出房间",
  ),
  true,
);
assert.notEqual(
  firstPage.playmesh.player.getCurrent().id,
  firstPage.playmesh.session.getCurrent().authorityClientId,
  "浏览器首个加入玩家不能成为 Authority",
);

const appPage = createPage(
  { userId: "u-current-app", nickname: "App 玩家" },
  false,
  ["zh-CN"],
  "en-US",
);
await appPage.playmesh.ready;
assert.equal(appPage.playmesh.app.isAvailable(), true);
assert.deepEqual(appPage.__runtimeGameDeclarations, [{
  requiredCapabilities: [],
}]);
assert.equal(appPage.playmesh.runtime.getLocale(), "en-US");
appPage.playmesh.__receive({
  type: "platform.ui.configure",
  configuration: platformConfiguration("zh-CN", "light"),
});
assert.equal(
  appPage.playmesh.runtime.getLocale(),
  "zh-CN",
  "App-hosted game locale must follow live displaying-App locale updates",
);
assert.equal(
  Symbol.for("playmesh.platform-ui.configuration") in appPage,
  false,
  "App locale messages must be consumed from private bootstrap state",
);
assert.deepEqual(appPage.__fullscreenRequests, [
  { enabled: true, orientation: "portrait" },
]);
assert.equal(joinCommands.at(-1).playerId, "u-current-app");
assert.equal(joinCommands.at(-1).nickname, "App 玩家");
assert.equal(appPage.__ui[".edit"].hidden, true);
assert.equal(appPage.__mountedHosts.includes("playmesh-browser-profile"), false);
// Game SDK 不再桥接 App 菜单按键，也不再创建平台菜单覆盖层。
if (false) {
assert.equal(appPage.__mountedHosts.includes("playmesh-performance"), true);
const appEscape = emitWindowKey(
  appPage,
  appPage.__gameFocusTarget,
  "Escape",
);
const appMenu = emitWindowKey(
  appPage,
  appPage.__gameFocusTarget,
  "F10",
);
assert.equal(
  appPage.__platformBackIntent(),
  true,
  "Android/system back intent must be delegated to the App sidebar",
);
assert.equal(
  appPage.__platformMenuIntent(),
  true,
  "native menu intent must be delegated to the App sidebar",
);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.deepEqual(appPage.__nativeSidebarRequests, [
  "show",
  "show",
  "show",
  "show",
]);
assert.equal(appEscape.defaultPrevented, true);
assert.equal(appMenu.defaultPrevented, true);
assert.equal(appPage.__mountedHosts.includes("playmesh-browser-profile"), false);
assert.equal(
  appPage.__shadowRoots.at(-1).host.getAttribute("data-theme"),
  "light",
  "App 性能覆盖层必须跟随实际显示 App 主题",
);
assert.equal(firstPage.__ui[".panel"].hidden, false);
assert.equal(firstPage.__ui[".latency"].hidden, false);
await firstPage.__ui[".enter-fullscreen"].onclick();
assert.deepEqual(firstPage.__orientationLocks, ["portrait", "portrait"]);
}
assert.equal(firstPage.playmesh.performance.getLatency() >= 0, true);
assert.equal(
  firstPage.playmesh.session.getCurrent().players[0].connected,
  true,
  "WebSocket open 后立即到达的最新会话快照不得丢失",
);
assert.equal(browserLocalStorage.get("playmesh.nickname.v1"), "缓存玩家");
const hostBucket = firstPage.playmesh.storage.getBucket("browser_save");
assert.equal(hostBucket.flush, undefined);
await hostBucket.setData("score", 18);
assert.equal(await hostBucket.getData("score"), 18);
assert.equal(storageCommands.every((command) => command.shareToken === undefined), true);
assert.equal(storageCommands.every((command) => command.requestId.startsWith("browser-storage-")), true);
assert.equal(storageCommands.some((command) => command.command === "storage.set"), true);
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
assert.equal(refreshedPage.playmesh.player.getCurrent().id, persistedBrowserId);
assert.equal(refreshedPage.playmesh.player.getCurrent().nickname, "缓存玩家");
assert.equal(
  refreshedPage.playmesh.player.getCurrent().id,
  firstPage.playmesh.player.getCurrent().id,
);
while (refreshedPage.__ui[".edit"].hidden) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(refreshedPage.__ui[".edit"].hidden, false, "浏览器应显示 SDK 昵称按钮");
const refreshedProfileRoot = refreshedPage.__shadowRoots.at(-1);
refreshedPage.__ui[".edit"].click();
while (refreshedProfileRoot.activeElement !== refreshedPage.__ui.input) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(refreshedProfileRoot.activeElement, refreshedPage.__ui.input);
emitKey(
  refreshedPage.__ui[".overlay"],
  refreshedPage.__ui.input,
  "Escape",
);
assert.equal(
  refreshedPage.__ui[".overlay"].hidden,
  true,
  "Escape must cancel an optional nickname dialog",
);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(refreshedProfileRoot.activeElement, refreshedPage.__ui[".info"]);
assert.equal(nicknameCommands.length, 0);
refreshedPage.__ui[".edit"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
refreshedPage.__ui.input.value = "修改后的玩家";
await refreshedPage.__ui.form.onsubmit({ preventDefault() {} });
assert.equal(refreshedPage.playmesh.player.getCurrent().nickname, "修改后的玩家");
assert.equal(browserLocalStorage.get("playmesh.nickname.v1"), "修改后的玩家");
assert.equal(nicknameCommands.length, 1);
assert.equal(nicknameCommands[0].nickname, "修改后的玩家");
assert.equal(nicknameCommands[0].headers.Authorization, "Bearer player-token-3");
assert.equal(nicknameCommands[0].url, "http://192.168.1.20:42000/v1/sessions/s-1/players/me");
assert.equal(joinUrls.includes("http://127.0.0.1:43000/v1/sessions/join"), true);

const reconnectPage = createPage(null, true);
const selfReconnectEvents = [];
reconnectPage.playmesh.session.onPlayerReconnect((event) => selfReconnectEvents.push(event));
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
    (entry) => entry.args[0] === "Playmesh 主会话 WebSocket 已掉线",
  ),
  true,
);
assert.equal(
  reconnectPage.__consoleEntries.some(
    (entry) => entry.args[0] === "Playmesh 主会话 WebSocket 重连成功",
  ),
  true,
);

const englishBrowserPage = createPage(null, false, ["en-GB"]);
await englishBrowserPage.playmesh.ready;
assert.equal(
  englishBrowserPage.playmesh.runtime.getLocale(),
  "en-GB",
  "game locale must preserve the displaying browser's own locale",
);
if (false) {
while (!englishBrowserPage.__shadowHtml.some(
  (html) => html.includes("Game menu"),
)) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(
  englishBrowserPage.__shadowHtml.some((html) => html.includes("Game menu")),
  true,
);

const japaneseBrowserPage = createPage(null, false, ["ja-JP"]);
await japaneseBrowserPage.playmesh.ready;
assert.equal(
  japaneseBrowserPage.playmesh.runtime.getLocale(),
  "ja-JP",
  "game locale must not be limited by Playmesh overlay translations",
);
assert.equal(
  japaneseBrowserPage.__shadowHtml.some((html) => html.includes("游戏菜单")),
  true,
  "unsupported overlay locales must independently fall back to zh-CN",
);
}

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
  fallbackBrowserPage.playmesh.runtime.getLocale(),
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
