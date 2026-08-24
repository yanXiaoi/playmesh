import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const appLocale = JSON.parse(fs.readFileSync(
  new URL(
    "../assets/playmesh-localization/locales/zh-CN/app.json",
    import.meta.url,
  ),
  "utf8",
));
const platformMessages = Object.fromEntries(
  Object.entries(appLocale)
    .filter(([key]) => key.startsWith("platform.game."))
    .map(([key, value]) => [key.slice("platform.game.".length), value]),
);
const appInternalKey = Symbol.for("playmesh.app.internal.v1");

const selectors = [
  ".menu-fab",
  ".layer",
  ".sidebar",
  ".scrim",
  ".title",
  ".continue",
  ".restart",
  ".share",
  ".join",
  ".logs",
  ".fullscreen",
  ".info",
  ".performance",
  ".exit",
  ".performance-panel",
  ".fps",
  ".latency",
  ".info-layer",
  ".info-title",
  ".game-name",
  ".game-tags-wrap",
  ".game-tags-label",
  ".game-tags",
  ".game-detail",
  ".info-edit",
  ".info-close",
  ".logs-layer",
  ".logs-title",
  ".logs-output",
  ".logs-copy",
  ".logs-clear",
  ".logs-close",
  ".join-layer",
  ".join-title",
  ".join-close",
  ".join-rooms",
  ".join-empty",
  ".join-scan",
  ".join-form",
  ".join-input",
  ".join-submit",
  ".join-error",
];

function createElement(selector, document) {
  const listeners = new Map();
  const attributes = new Map();
  const visibleLabel = { textContent: "" };
  const element = {
    hidden: [
      ".layer",
      ".performance-panel",
      ".latency",
      ".info-layer",
      ".logs-layer",
      ".join-layer",
      ".join-empty",
      ".join-error",
    ].includes(selector),
    tagName: selector.startsWith(".") ? "BUTTON" : "DIV",
    textContent: "",
    style: {},
    dataset: {},
    disabled: false,
    value: "",
    isConnected: true,
    classList: { toggle() {} },
    onclick: null,
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
    getAttribute(name) {
      return attributes.get(name) ?? null;
    },
    querySelector(query) {
      return query === "span:last-child" ? visibleLabel : null;
    },
    closest(query) {
      return query === selector ? element : null;
    },
    addEventListener(type, listener) {
      const current = listeners.get(type) || [];
      current.push(listener);
      listeners.set(type, current);
    },
    emit(type, event = {}) {
      event.target ??= element;
      event.preventDefault ??= () => {};
      event.stopPropagation ??= () => {};
      event.stopImmediatePropagation ??= () => {};
      for (const listener of [...(listeners.get(type) || [])]) listener(event);
      return event;
    },
    click() {
      element.onclick?.({
        target: element,
        preventDefault() {},
        stopPropagation() {},
      });
    },
    focus() {
      document.activeElement = element;
    },
    getBoundingClientRect() {
      return { left: 20, top: 30, width: 42, height: 42 };
    },
    setPointerCapture() {},
    releasePointerCapture() {},
  };
  element.__label = visibleLabel;
  return element;
}

function createPage({
  app = false,
  fallbackUi = true,
  showShareAction = app,
  sessionState = new Map(),
  localState = new Map(),
} = {}) {
  const windowListeners = new Map();
  const mounted = [];
  const commands = [];
  const consoleEntries = [];
  const synchronousAppBuckets = new Map();
  const document = {
    activeElement: null,
    body: {
      isConnected: true,
      tabIndex: -1,
      appendChild(host) {
        mounted.push(host);
      },
      getAttribute() {
        return null;
      },
      setAttribute() {},
      removeAttribute() {},
      focus() {
        document.activeElement = document.body;
      },
    },
    documentElement: {
      isConnected: true,
      clientWidth: 800,
      clientHeight: 600,
    },
    createElement() {
      const hostAttributes = new Map();
      const host = {
        id: "",
        removed: false,
        setAttribute(name, value) {
          hostAttributes.set(name, String(value));
        },
        getAttribute(name) {
          return hostAttributes.get(name) ?? null;
        },
        remove() {
          host.removed = true;
        },
        attachShadow() {
          const elements = Object.fromEntries(
            selectors.map((selector) => [selector, createElement(selector, document)]),
          );
          elements[".sidebar"].tagName = "ASIDE";
          elements[".title"].tagName = "H2";
          elements[".fps"].tagName = "SPAN";
          elements[".latency"].tagName = "SPAN";
          elements[".game-name"].tagName = "P";
          elements[".game-detail"].tagName = "P";
          elements[".logs-output"].tagName = "PRE";
          elements[".join-title"].tagName = "H2";
          elements[".join-rooms"].tagName = "DIV";
          elements[".join-form"].tagName = "FORM";
          elements[".join-input"].tagName = "INPUT";
          const rootListeners = new Map();
          const root = {
            host,
            set innerHTML(value) {
              root.html = value;
            },
            querySelector(selector) {
              if (selector === ".menu-fab" &&
                  !String(root.html || "").includes('class="menu-fab"')) {
                return null;
              }
              const element = elements[selector];
              if (element) {
                element.getRootNode = () => root;
              }
              return element;
            },
            addEventListener(type, listener) {
              const current = rootListeners.get(type) || [];
              current.push(listener);
              rootListeners.set(type, current);
            },
            emit(type, init = {}) {
              const event = {
                defaultPrevented: false,
                propagationStopped: false,
                immediatePropagationStopped: false,
                preventDefault() {
                  event.defaultPrevented = true;
                },
                stopPropagation() {
                  event.propagationStopped = true;
                },
                stopImmediatePropagation() {
                  event.immediatePropagationStopped = true;
                },
                ...init,
              };
              for (const listener of rootListeners.get(type) || []) {
                listener(event);
              }
              return event;
            },
          };
          host.__root = root;
          host.__elements = elements;
          return root;
        },
      };
      return host;
    },
    addEventListener() {},
  };
  const gameFocus = {
    isConnected: true,
    focus() {
      document.activeElement = gameFocus;
    },
  };
  document.activeElement = gameFocus;
  const platformUi = {
    fallbackLocale: "zh-CN",
    actions: {
      share: showShareAction,
      join: showShareAction,
      restart: true,
      logs: true,
      fullscreen: true,
      info: true,
      performance: true,
      exit: true,
    },
    locales: [{
      locale: "zh-CN",
      theme: "dark",
      messages: platformMessages,
    }],
  };
  const window = {
    window: null,
    document,
    innerWidth: 800,
    innerHeight: 600,
    navigator: {
      languages: ["zh-CN"],
      language: "zh-CN",
      userActivation: { isActive: true },
      clipboard: {
        async writeText(value) {
          window.__copiedText = String(value);
        },
      },
    },
    __PLAYMESH_APP_OPTIONS__: { fallbackUi },
    __PLAYMESH_BROWSER__: app ? undefined : {
      _playmeshPlatformUi: platformUi,
    },
    console: {
      debug: (...args) => consoleEntries.push({ level: "debug", args }),
      info: (...args) => consoleEntries.push({ level: "info", args }),
      log: (...args) => consoleEntries.push({ level: "log", args }),
      warn: (...args) => consoleEntries.push({ level: "warn", args }),
      error: (...args) => consoleEntries.push({ level: "error", args }),
    },
    location: {
      reload() {},
      replace() {
        window.__exitCount = (window.__exitCount || 0) + 1;
      },
    },
    sessionStorage: {
      getItem(key) {
        return sessionState.get(String(key)) ?? null;
      },
      setItem(key, value) {
        sessionState.set(String(key), String(value));
      },
      removeItem(key) {
        sessionState.delete(String(key));
      },
    },
    localStorage: {
      getItem(key) {
        return localState.get(String(key)) ?? null;
      },
      setItem(key, value) {
        localState.set(String(key), String(value));
      },
      removeItem(key) {
        localState.delete(String(key));
      },
    },
    history: { length: 1, back() {} },
    queueMicrotask,
    TextEncoder,
    Uint8Array,
    btoa(value) {
      return Buffer.from(value, "binary").toString("base64");
    },
    setTimeout,
    clearTimeout,
    addEventListener(type, listener) {
      const current = windowListeners.get(type) || [];
      current.push(listener);
      windowListeners.set(type, current);
    },
    removeEventListener(type, listener) {
      const current = windowListeners.get(type) || [];
      const index = current.indexOf(listener);
      if (index >= 0) current.splice(index, 1);
    },
  };
  if (app) {
    const appBuckets = new Map();
    window.XMLHttpRequest = class AppStorageXMLHttpRequest {
      constructor() {
        this.headers = {};
        this.status = 0;
        this.responseText = "";
      }

      open(method, url, asynchronous) {
        assert.equal(asynchronous, false);
        this.method = method;
        this.url = url;
      }

      setRequestHeader(name, value) {
        this.headers[name] = value;
      }

      send(body) {
        const encoded = this.method === "GET"
          ? new URL(this.url).searchParams.get("payload")
          : null;
        const raw = this.method === "GET"
          ? Buffer.from(encoded, "base64url").toString("utf8")
          : body;
        const envelope = JSON.parse(raw);
        const values = synchronousAppBuckets.get(envelope.bucket) || new Map();
        let result = null;
        if (envelope.operation === "sync.get") {
          assert.equal(this.method, "GET");
          result = values.has(envelope.key) ? values.get(envelope.key) : null;
        } else {
          assert.equal(envelope.operation, "sync.set");
          assert.equal(this.method, "POST");
          assert.equal(this.headers["Content-Type"], "text/plain;charset=UTF-8");
          values.set(envelope.key, envelope.value);
          synchronousAppBuckets.set(envelope.bucket, values);
        }
        this.status = 200;
        this.responseText = JSON.stringify({
          protocolVersion: "1.0.0",
          requestId: envelope.requestId,
          result,
        });
      }
    };
    window.PlaymeshAppBridge = {
      postMessage(raw) {
        const command = JSON.parse(raw);
        commands.push(command.command);
        queueMicrotask(() => {
          const bucket = command.payload?.bucket;
          const bucketValues = appBuckets.get(bucket) || new Map();
          let result = null;
          if (command.command === "app.storage.get") {
            result = bucketValues.has(command.payload.key)
              ? bucketValues.get(command.payload.key)
              : null;
          } else if (command.command === "app.storage.set") {
            bucketValues.set(command.payload.key, command.payload.value);
            appBuckets.set(bucket, bucketValues);
          } else if (command.command === "app.storage.remove") {
            bucketValues.delete(command.payload.key);
            appBuckets.set(bucket, bucketValues);
          } else if (command.command === "app.storage.clear") {
            appBuckets.set(bucket, new Map());
          } else if (command.command === "app.lan.discover") {
            result = [{
              instanceId: "room-current-game",
              gameId: "com.playmesh.current-game",
              name: "客厅房间",
              host: "192.168.1.23",
            }];
          }
          window[appInternalKey].receive({
            type: "app.command.result",
            requestId: command.requestId,
            result: command.command === "app.bootstrap"
              ? {
                  available: true,
                  sdkVersion: "3.3.0",
                  identity: null,
                  capabilityRegistry: [],
                  device: {
                    platform: "windows",
                    capabilities: [],
                    declaredCapabilities: [],
                  },
                  _playmeshPlatformUi: {
                    ...platformUi.locales[0],
                    actions: platformUi.actions,
                  },
                  _playmeshFullscreen: false,
                  _playmeshAppStorageSync: {
                    endpoint:
                      "http://127.0.0.1:43101/playmesh/app-storage-sync/v1/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  },
                }
              : result,
          });
        });
      },
    };
  }
  window.window = window;
  vm.runInNewContext(source, window, { filename: "playmesh-app.js" });
  const dispatchKey = (key, keyCode, target = gameFocus) => {
    const event = {
      key,
      keyCode,
      target,
      defaultPrevented: false,
      preventDefault() {
        event.defaultPrevented = true;
      },
      stopPropagation() {},
      stopImmediatePropagation() {},
    };
    for (const listener of windowListeners.get("keydown") || []) listener(event);
    return event;
  };
  return {
    window,
    appSdk: window[appInternalKey].publicApi,
    document,
    mounted,
    commands,
    consoleEntries,
    gameFocus,
    dispatchKey,
    localState,
  };
}

const browserPage = createPage();
assert.equal(browserPage.consoleEntries[0].args.length, 1);
assert.equal(
  browserPage.consoleEntries[0].args[0],
  'Playmesh App SDK 注入成功 {"version":"3.3.0"}',
);
assert.equal(browserPage.window.playmesh, undefined);
assert.equal(browserPage.window.playmeshApp, undefined);
assert.deepEqual(
  Object.keys(browserPage.appSdk).filter((key) =>
    key.startsWith("__")),
  [],
);
assert.throws(
  () => browserPage.appSdk.ui.disableSystemMenuTriggers(),
  (error) => error?.code === "app_not_ready",
);
await browserPage.appSdk.ready;
const browserBucket = browserPage.appSdk.storage.getBucket("player_save");
const browserValue = { level: 3, items: ["map", "key"] };
await browserBucket.setData("progress", browserValue);
browserValue.level = 99;
assert.equal(
  JSON.stringify(await browserBucket.getData("progress")),
  JSON.stringify({ level: 3, items: ["map", "key"] }),
);
assert.deepEqual(
  JSON.parse(browserPage.localState.get("player_save")),
  { progress: { level: 3, items: ["map", "key"] } },
);
await browserBucket.removeData("progress");
assert.equal(await browserBucket.getData("progress"), null);
await browserBucket.setData("progress", { level: 4 });
await browserBucket.clearData();
assert.equal(browserPage.localState.has("player_save"), false);
browserBucket.setDataSync("settings", { volume: 0.5 });
assert.equal(
  JSON.stringify(browserBucket.getDataSync("settings")),
  JSON.stringify({ volume: 0.5 }),
);
const browserGDevelopBucket = browserPage.appSdk.storage.getBucket(
  "GDJS/原始/浏览器存档",
);
browserGDevelopBucket.setDataSync("$playmesh.gdevelop.root.v1", { round: 3 });
assert.equal(
  JSON.stringify(
    browserGDevelopBucket.getDataSync("$playmesh.gdevelop.root.v1"),
  ),
  JSON.stringify({ round: 3 }),
);
assert.throws(
  () => browserPage.appSdk.storage.getBucket("bad.bucket").getData("value"),
  /Bucket 名称/,
);
assert.throws(() => browserBucket.getData("bad key"), /key/);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(browserPage.mounted.length, 1);
browserPage.window[appInternalKey].registerRuntimeUi({
  async getInfo() {
    return {
      gameId: "com.playmesh.browser-game",
      gameName: "浏览器游戏",
      tags: ["派对", "本地多人"],
      requiredCapabilities: [],
      joinCode: null,
      multiplayer: false,
      isAuthority: true,
      playerName: null,
      playerCount: null,
      gameSdkVersion: "4.1.0",
      appSdkVersion: "3.3.0",
      platform: "browser",
    };
  },
});
const browserHost = browserPage.mounted[0];
const browserUi = browserHost.__elements;
assert.equal(browserHost.id, "playmesh-app-platform-ui");
assert.equal(
  browserHost.__root.html.includes(
    ".menu-fab{position:fixed;right:0;top:36%;",
  ),
  true,
);
assert.equal(
  browserHost.__root.html.includes("width:42px;height:42px"),
  true,
);
assert.equal(browserUi[".menu-fab"].hidden, false);
assert.equal(browserUi[".menu-fab"].getAttribute("aria-label"), "游戏菜单");
assert.equal(browserUi[".menu-fab"].__label.textContent, "");
assert.equal(
  browserHost.__root.html.includes("grid-template-rows:auto minmax(0,1fr) auto"),
  true,
);
assert.equal(browserHost.__root.html.includes("overscroll-behavior:contain"), true);
assert.equal(browserHost.__root.html.includes("position:absolute;right:0;top:0"), false);

browserPage.window.console.info("结构化日志", {
  score: 7,
  tags: ["alpha", "beta"],
});
const structuredConsoleEntry = browserPage.consoleEntries.at(-1);
assert.equal(structuredConsoleEntry.args.length, 1);
assert.equal(
  structuredConsoleEntry.args[0],
  '结构化日志 {"score":7,"tags":["alpha","beta"]}',
);
await browserPage.appSdk.ui.openRuntimeLogs();
assert.equal(
  browserUi[".logs-output"].textContent.includes(
    'Playmesh App SDK 注入成功 {"version":"3.3.0"}',
  ),
  true,
);
assert.equal(
  browserUi[".logs-output"].textContent.includes(
    '结构化日志 {"score":7,"tags":["alpha","beta"]}',
  ),
  true,
);
await browserUi[".logs-copy"].onclick();
assert.equal(
  browserPage.window.__copiedText.includes(
    '结构化日志 {"score":7,"tags":["alpha","beta"]}',
  ),
  true,
);
assert.equal(browserUi[".logs-copy"].__label.textContent, "已复制");
browserUi[".logs-close"].click();
await browserPage.appSdk.ui.openGameInfo();
assert.equal(browserUi[".game-name"].textContent, "浏览器游戏");
assert.equal(browserUi[".game-tags-wrap"].hidden, false);
assert.equal(browserUi[".game-tags-label"].textContent, "标签");
assert.equal(browserUi[".game-tags"].innerHTML.includes("派对"), true);
assert.equal(browserUi[".game-tags"].innerHTML.includes("本地多人"), true);
assert.equal(
  browserUi[".game-detail"].innerHTML.includes("com.playmesh.browser-game"),
  true,
);
assert.equal(browserUi[".game-detail"].innerHTML.includes("Game ID"), true);
browserUi[".info-close"].click();
browserPage.gameFocus.focus();

const firstEscape = browserPage.dispatchKey("Escape", 27);
await Promise.resolve();
assert.equal(firstEscape.defaultPrevented, true);
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserPage.document.activeElement, browserUi[".continue"]);
assert.equal(browserUi[".scrim"].textContent, "");
assert.equal(browserUi[".share"].__label.textContent, "分享/邀请");
assert.equal(
  browserUi[".performance"].__label.textContent,
  "显示性能信息",
);
assert.equal(
  browserHost.__root.html.includes(
    ".info-hero,.info-grid,.game-name,.info-label,.info-value{cursor:text;user-select:text;-webkit-user-select:text}",
  ),
  true,
);
assert.equal(
  browserHost.__root.html.includes(
    ".layer{position:fixed;inset:0;z-index:2147483646;display:grid;place-items:center;cursor:default",
  ),
  true,
);
assert.equal(
  browserHost.__root.html.includes(
    ".dialog-layer{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;cursor:default",
  ),
  true,
);
for (const type of [
  "auxclick",
  "click",
  "contextmenu",
  "dblclick",
  "mousedown",
  "mousemove",
  "mouseup",
  "pointercancel",
  "pointerdown",
  "pointermove",
  "pointerup",
  "touchcancel",
  "touchend",
  "touchmove",
  "touchstart",
  "wheel",
]) {
  const event = browserHost.__root.emit(type);
  assert.equal(event.propagationStopped, true, `${type} must not reach the game`);
  assert.equal(event.defaultPrevented, false, `${type} must keep SDK UI defaults`);
}
assert.equal(
  browserHost.__root.html.indexOf('class="performance-panel"'),
  browserHost.__root.html.lastIndexOf('class="performance-panel"'),
);
assert.equal(
  browserHost.__root.html.indexOf('class="performance-panel"') >
    browserHost.__root.html.indexOf('class="dialog-layer logs-layer"'),
  true,
);
assert.equal(
  browserHost.__root.html.includes(
    ".performance-panel{position:fixed;left:max(12px,env(safe-area-inset-left));top:max(12px,env(safe-area-inset-top));z-index:2147483647",
  ),
  true,
);

browserUi[".scrim"].click();
assert.equal(browserUi[".layer"].hidden, true);
assert.equal(browserPage.document.activeElement, browserPage.gameFocus);
await browserPage.appSdk.ui.showGameSidebar();
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserPage.document.activeElement, browserUi[".continue"]);
browserUi[".performance"].click();
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserUi[".performance-panel"].hidden, false);
assert.equal(
  browserUi[".performance"].__label.textContent,
  "关闭性能信息",
);
assert.equal(browserUi[".performance"].getAttribute("aria-pressed"), "true");
browserUi[".performance"].click();
assert.equal(browserUi[".performance-panel"].hidden, true);
assert.equal(
  browserUi[".performance"].__label.textContent,
  "显示性能信息",
);
browserUi[".performance"].click();
await browserUi[".logs"].onclick();
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserUi[".logs-layer"].hidden, false);
const retargetedEscape = browserPage.dispatchKey(
  "Escape",
  27,
  browserHost,
);
assert.equal(retargetedEscape.defaultPrevented, false);
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserUi[".logs-layer"].hidden, false);
const logsEscape = browserHost.__root.emit("keydown", { key: "Escape" });
assert.equal(logsEscape.defaultPrevented, true);
assert.equal(browserUi[".logs-layer"].hidden, true);
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserPage.document.activeElement, browserUi[".logs"]);
browserUi[".info"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserUi[".info-layer"].hidden, false);
browserUi[".info-close"].click();
assert.equal(browserUi[".layer"].hidden, false);
assert.equal(browserPage.document.activeElement, browserUi[".info"]);
browserUi[".continue"].focus();

const arrowDown = browserHost.__root.emit("keydown", { key: "ArrowDown" });
assert.equal(arrowDown.defaultPrevented, true);
assert.equal(arrowDown.immediatePropagationStopped, true);
assert.equal(browserPage.document.activeElement, browserUi[".logs"]);
browserHost.__root.emit("keydown", { key: "ArrowRight" });
assert.equal(browserPage.document.activeElement, browserUi[".fullscreen"]);
browserHost.__root.emit("keydown", { key: "ArrowUp" });
assert.equal(browserPage.document.activeElement, browserUi[".restart"]);
browserHost.__root.emit("keydown", { key: "ArrowLeft" });
assert.equal(browserPage.document.activeElement, browserUi[".continue"]);
browserHost.__root.emit("keydown", { key: "ArrowUp" });
assert.equal(browserPage.document.activeElement, browserUi[".continue"]);
browserHost.__root.emit("keydown", { key: "End" });
assert.equal(browserPage.document.activeElement, browserUi[".exit"]);
browserHost.__root.emit("keydown", { key: "ArrowUp" });
assert.equal(browserPage.document.activeElement, browserUi[".performance"]);
browserHost.__root.emit("keydown", { key: "Home" });
assert.equal(browserPage.document.activeElement, browserUi[".continue"]);

browserUi[".continue"].click();
assert.equal(browserUi[".layer"].hidden, true);
assert.equal(browserPage.document.activeElement, browserPage.gameFocus);
assert.equal(await browserPage.appSdk.ui.showGameSidebar(), true);
assert.equal(browserUi[".layer"].hidden, false);

browserUi[".menu-fab"].emit("pointerdown", {
  pointerId: 1,
  button: 0,
  clientX: 20,
  clientY: 30,
});
browserUi[".menu-fab"].emit("pointermove", {
  pointerId: 1,
  clientX: 170,
  clientY: 210,
});
browserUi[".menu-fab"].emit("pointerup", { pointerId: 1 });
assert.equal(browserUi[".menu-fab"].style.left, "170px");
assert.equal(browserUi[".menu-fab"].style.top, "210px");
browserUi[".menu-fab"].emit("pointerdown", {
  pointerId: 2,
  button: 0,
  clientX: 20,
  clientY: 30,
});
browserUi[".menu-fab"].emit("pointermove", {
  pointerId: 2,
  clientX: -100,
  clientY: -100,
});
browserUi[".menu-fab"].emit("pointerup", { pointerId: 2 });
assert.equal(browserUi[".menu-fab"].style.left, "-21px");
assert.equal(browserUi[".menu-fab"].style.top, "-21px");

const restartSession = new Map();
const restartPage = createPage({ sessionState: restartSession });
await restartPage.appSdk.ready;
await restartPage.appSdk.ui.showGameSidebar();
restartPage.mounted[0].__elements[".restart"].click();
assert.equal(
  restartPage.mounted[0].__elements[".layer"].hidden,
  true,
);
assert.equal(restartSession.has("playmesh.app.ui.reopenAfterRestart"), false);
const reloadedPage = createPage({ sessionState: restartSession });
await reloadedPage.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(reloadedPage.mounted[0].__elements[".layer"].hidden, true);

const menuEventPage = createPage();
await menuEventPage.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
const menuEventUi = menuEventPage.mounted[0].__elements;
const menuEvents = [];
const stopMenuOpen = menuEventPage.appSdk.ui.onGameMenuOpen(() => {
  menuEvents.push("open");
});
const stopMenuClose = menuEventPage.appSdk.ui.onGameMenuClose(() => {
  menuEvents.push("close");
});
const stopFailingOpen = menuEventPage.appSdk.ui.onGameMenuOpen(() => {
  throw new Error("menu open listener failed");
});
assert.throws(
  () => menuEventPage.appSdk.ui.onGameMenuOpen(null),
  /callback 必须是函数/,
);
assert.throws(
  () => menuEventPage.appSdk.ui.onGameMenuClose("invalid"),
  /callback 必须是函数/,
);
menuEventPage.dispatchKey("Escape", 27);
await Promise.resolve();
assert.deepEqual(menuEvents, ["open"]);
assert.equal(
  menuEventPage.consoleEntries.some((entry) =>
    entry.level === "warn" &&
    entry.args[0].startsWith("Playmesh 游戏菜单打开 回调执行失败")
  ),
  true,
);
assert.equal(await menuEventPage.appSdk.ui.showGameSidebar(), true);
assert.deepEqual(menuEvents, ["open"]);
menuEventUi[".scrim"].click();
assert.deepEqual(menuEvents, ["open", "close"]);
stopFailingOpen();
stopFailingOpen();
assert.equal(await menuEventPage.appSdk.ui.showGameSidebar(), true);
assert.deepEqual(menuEvents, ["open", "close", "open"]);
menuEventUi[".continue"].click();
assert.deepEqual(menuEvents, ["open", "close", "open", "close"]);
stopMenuOpen();
stopMenuOpen();
assert.equal(await menuEventPage.appSdk.ui.showGameSidebar(), true);
assert.deepEqual(menuEvents, ["open", "close", "open", "close"]);
menuEventPage.appSdk.ui.configure({ fallbackUi: false });
assert.deepEqual(menuEvents, ["open", "close", "open", "close", "close"]);
stopMenuClose();
stopMenuClose();

const systemMenuPage = createPage();
await systemMenuPage.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
const systemMenuInternal = systemMenuPage.window[appInternalKey];
const systemMenuUi = systemMenuPage.mounted[0].__elements;
assert.equal(
  systemMenuPage.appSdk.ui.setSystemMenuTriggersEnabled,
  undefined,
);
assert.throws(
  () => systemMenuPage.appSdk.ui.disableSystemMenuTriggers(true),
  (error) => error?.code === "invalid_argument",
);
const escapeAfterInvalidArgument = systemMenuPage.dispatchKey("Escape", 27);
await Promise.resolve();
assert.equal(escapeAfterInvalidArgument.defaultPrevented, true);
assert.equal(systemMenuUi[".layer"].hidden, false);
systemMenuUi[".continue"].click();
assert.equal(
  systemMenuPage.appSdk.ui.disableSystemMenuTriggers(),
  undefined,
);
assert.equal(
  systemMenuPage.appSdk.ui.disableSystemMenuTriggers(),
  undefined,
);
assert.equal(
  systemMenuPage.appSdk.ui.configure({}).fallbackUi,
  true,
);
for (const [key, keyCode] of [
  ["Escape", 27],
  ["BrowserBack", 166],
]) {
  assert.equal(
    systemMenuPage.dispatchKey(key, keyCode).defaultPrevented,
    false,
  );
}
for (const [key, keyCode] of [
  ["F10", 121],
  ["ContextMenu", 93],
  ["Menu", 82],
]) {
  assert.equal(systemMenuPage.dispatchKey(key, keyCode).defaultPrevented, false);
}
assert.equal(systemMenuUi[".layer"].hidden, true);
assert.equal(systemMenuInternal.handleNativeBack(), false);

assert.equal(await systemMenuPage.appSdk.ui.showGameSidebar(), true);
assert.equal(systemMenuInternal.handleNativeBack(), true);
await Promise.resolve();
assert.equal(systemMenuUi[".layer"].hidden, true);

assert.equal(await systemMenuPage.appSdk.ui.openRuntimeLogs(), true);
assert.equal(systemMenuUi[".logs-layer"].hidden, false);
assert.equal(systemMenuInternal.handleNativeBack(), true);
assert.equal(systemMenuUi[".logs-layer"].hidden, true);

systemMenuInternal.registerRuntimeUi({
  async getInfo() {
    return {
      gameId: "com.playmesh.system-menu-test",
      gameName: "系统菜单测试",
      tags: [],
      requiredCapabilities: [],
      joinCode: null,
      multiplayer: false,
      isAuthority: true,
      playerName: null,
      playerCount: null,
      gameSdkVersion: "4.1.0",
      appSdkVersion: "3.3.0",
      platform: "browser",
    };
  },
});
assert.equal(await systemMenuPage.appSdk.ui.openGameInfo(), true);
assert.equal(systemMenuUi[".info-layer"].hidden, false);
assert.equal(systemMenuInternal.handleNativeBack(), true);
assert.equal(systemMenuUi[".info-layer"].hidden, true);

systemMenuInternal.configurePlatformUi({
  locale: "zh-CN",
  theme: "dark",
  messages: platformMessages,
});
assert.equal(
  systemMenuPage.dispatchKey("Escape", 27).defaultPrevented,
  false,
);

const freshSystemMenuPage = createPage();
await freshSystemMenuPage.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
let fallbackBackCalls = 0;
const stopFallbackBack = freshSystemMenuPage.appSdk.ui.onBack(() => {
  fallbackBackCalls += 1;
  return false;
});
assert.equal(
  freshSystemMenuPage.dispatchKey("Escape", 27).defaultPrevented,
  true,
);
await Promise.resolve();
assert.equal(fallbackBackCalls, 0);
stopFallbackBack();

const disabledPage = createPage({ fallbackUi: false });
await disabledPage.appSdk.ready;
assert.equal(disabledPage.mounted.length, 0);
assert.equal(await disabledPage.appSdk.ui.showGameSidebar(), false);
let blockedBackCalls = 0;
const stopBlockedBack = disabledPage.appSdk.ui.onBack(() => {
  blockedBackCalls += 1;
  return false;
});
assert.equal(disabledPage.dispatchKey("Escape", 27).defaultPrevented, true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(blockedBackCalls, 1);
assert.equal(disabledPage.window.__exitCount || 0, 0);
assert.equal(disabledPage.window[appInternalKey].handleNativeBack(), true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(blockedBackCalls, 2);
assert.equal(disabledPage.window.__exitCount || 0, 0);
stopBlockedBack();
stopBlockedBack();
assert.equal(disabledPage.dispatchKey("Escape", 27).defaultPrevented, true);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(disabledPage.window.__exitCount, 1);

const allowedBackPage = createPage({ fallbackUi: false });
await allowedBackPage.appSdk.ready;
allowedBackPage.appSdk.ui.onBack(() => true);
assert.equal(allowedBackPage.window[appInternalKey].handleNativeBack(), true);
await new Promise((resolve) => setTimeout(resolve, 0));
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(allowedBackPage.window.__exitCount, 1);

const browserWithoutFloatingButton = createPage({ showShareAction: true });
assert.equal(
  browserWithoutFloatingButton.appSdk.ui.initializeBrowser(),
  true,
);
await browserWithoutFloatingButton.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(browserWithoutFloatingButton.mounted.length, 1);
assert.equal(
  browserWithoutFloatingButton.mounted[0].__root.html.includes(
    'class="menu-fab"',
  ),
  false,
);
assert.equal(
  await browserWithoutFloatingButton.appSdk.ui.showGameSidebar(),
  true,
);
const browserJoinUi = browserWithoutFloatingButton.mounted[0].__elements;
assert.equal(
  browserJoinUi[".join"].hidden,
  true,
  "普通浏览器即使收到主机动作配置也不得显示加入入口",
);
browserJoinUi[".join"].click();
await Promise.resolve();
assert.equal(browserJoinUi[".join-layer"].hidden, true);
assert.equal(
  browserWithoutFloatingButton.commands.some((command) =>
    command.startsWith("app.lan.")),
  false,
  "普通浏览器不得触发 WebView 专用加入流程",
);

const joinerPage = createPage({ app: true, showShareAction: false });
await joinerPage.appSdk.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
const joinerUi = joinerPage.mounted[0].__elements;
assert.equal(joinerUi[".share"].hidden, true);
assert.equal(
  joinerUi[".join"].hidden,
  true,
  "加入端 WebView 必须与分享邀请一起隐藏加入入口",
);
joinerUi[".join"].click();
await Promise.resolve();
assert.equal(joinerUi[".join-layer"].hidden, true);

const appPage = createPage({ app: true });
const earlyEscape = appPage.dispatchKey("Escape", 27);
await Promise.resolve();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(earlyEscape.defaultPrevented, true);
assert.equal(appPage.mounted[0].__elements[".layer"].hidden, false);
await appPage.appSdk.ready;
const appBucket = appPage.appSdk.storage.getBucket("player_save");
appBucket.setDataSync("sync_progress", { level: 4 });
assert.equal(
  JSON.stringify(appBucket.getDataSync("sync_progress")),
  JSON.stringify({ level: 4 }),
);
const appGDevelopBucket = appPage.appSdk.storage.getBucket("GDJS/本机/存档");
appGDevelopBucket.setDataSync("$playmesh.gdevelop.root.v1", { level: 7 });
assert.equal(
  JSON.stringify(appGDevelopBucket.getDataSync("$playmesh.gdevelop.root.v1")),
  JSON.stringify({ level: 7 }),
);
await appBucket.setData("progress", { level: 5 });
assert.equal(
  JSON.stringify(await appBucket.getData("progress")),
  JSON.stringify({ level: 5 }),
);
await appBucket.removeData("progress");
assert.equal(await appBucket.getData("progress"), null);
await appBucket.setData("progress", { level: 6 });
await appBucket.clearData();
assert.equal(await appBucket.getData("progress"), null);
assert.deepEqual(
  appPage.commands.filter((command) => command.startsWith("app.storage.")),
  [
    "app.storage.set",
    "app.storage.get",
    "app.storage.remove",
    "app.storage.get",
    "app.storage.set",
    "app.storage.clear",
    "app.storage.get",
  ],
);
assert.equal(appPage.commands.includes("app.input.takeover"), true);
assert.equal(appPage.appSdk.ui.initializeBrowser(), false);
const appUi = appPage.mounted[0].__elements;
appUi[".continue"].focus();
appPage.mounted[0].__root.emit("keydown", { key: "ArrowDown" });
assert.equal(appPage.document.activeElement, appUi[".share"]);
appPage.mounted[0].__root.emit("keydown", { key: "ArrowRight" });
assert.equal(appPage.document.activeElement, appUi[".join"]);
assert.equal(
  appPage.mounted[0].__root.html.includes('class="menu-fab"'),
  false,
);
assert.equal(appPage.commands.includes("app.ui.gameSidebar.show"), false);
assert.equal(appPage.appSdk.hideGameSidebar, undefined);
assert.equal(appPage.appSdk.onMenuRequest, undefined);
appPage.mounted[0].__elements[".share"].click();
assert.equal(appPage.mounted[0].__elements[".layer"].hidden, false);
await Promise.resolve();
assert.equal(appPage.commands.includes("app.ui.openSharePanel"), true);
assert.equal(appUi[".join"].__label.textContent, "加入游戏");
assert.equal(
  appPage.mounted[0].__root.html.indexOf('class="action share"') <
    appPage.mounted[0].__root.html.indexOf('class="action join"'),
  true,
);
appUi[".join"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(appUi[".join-layer"].hidden, false);
assert.equal(appUi[".join-title"].textContent, "加入游戏");
assert.equal(appUi[".join-close"].textContent, "×");
assert.equal(appUi[".join-empty"].textContent, "暂无房间");
assert.equal(appUi[".join-scan"].__label.textContent, "扫码加入");
assert.equal(appUi[".join-input"].getAttribute("placeholder"), "输入邀请链接");
assert.equal(appUi[".join-submit"].__label.textContent, "加入");
assert.equal(appUi[".join-rooms"].innerHTML.includes("客厅房间"), true);
assert.equal(appUi[".join-rooms"].innerHTML.includes("192.168.1.23"), true);
const joinMarkup = appPage.mounted[0].__root.html.split(
  'class="dialog-layer join-layer"',
)[1].split('class="performance-panel"')[0];
assert.equal(joinMarkup.includes("<p"), false, "加入弹窗不得增加解释段落");
appUi[".join-rooms"].onclick({
  target: {
    dataset: { instanceId: "room-current-game" },
    closest(selector) {
      return selector === ".join-room" ? this : null;
    },
  },
});
await Promise.resolve();
assert.equal(appPage.commands.includes("app.lan.joinDiscovered"), true);
appUi[".join-close"].click();
appUi[".join"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
appUi[".join-scan"].click();
await Promise.resolve();
assert.equal(appPage.commands.includes("app.lan.scanQr"), true);
appUi[".join-close"].click();
appUi[".join"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
appUi[".join-input"].value = "http://192.168.1.23/invite";
appUi[".join-form"].onsubmit({ preventDefault() {} });
await Promise.resolve();
assert.equal(appPage.commands.includes("app.lan.joinByLink"), true);
appUi[".join-close"].click();
assert.equal(appUi[".join-layer"].hidden, true);
assert.equal(
  appPage.mounted[0].__root.html.includes('class="action enter-fullscreen"'),
  false,
);
assert.equal(
  appPage.mounted[0].__root.html.includes('class="action exit-fullscreen"'),
  false,
);
assert.equal(appUi[".fullscreen"].__label.textContent, "进入全屏");
appUi[".fullscreen"].click();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(appPage.commands.includes("app.device.fullscreen"), true);
assert.equal(appUi[".fullscreen"].__label.textContent, "退出全屏");

const androidMenuPage = createPage();
await androidMenuPage.appSdk.ready;
assert.equal(androidMenuPage.dispatchKey("Menu", 82).defaultPrevented, true);
await Promise.resolve();
assert.equal(androidMenuPage.mounted[0].__elements[".layer"].hidden, false);
androidMenuPage.mounted[0].__elements[".continue"].click();
assert.equal(androidMenuPage.dispatchKey("Back", 4).defaultPrevented, true);
await Promise.resolve();
assert.equal(androidMenuPage.mounted[0].__elements[".layer"].hidden, false);

console.log("Playmesh App SDK fallback UI, first-key, and draggable button contract passed");
