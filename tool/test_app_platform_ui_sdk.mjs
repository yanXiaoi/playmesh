import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);

const selectors = [
  ".menu-fab",
  ".layer",
  ".sidebar",
  ".scrim",
  ".title",
  ".continue",
  ".restart",
  ".share",
  ".logs",
  ".enter-fullscreen",
  ".exit-fullscreen",
  ".info",
  ".performance",
  ".exit",
  ".performance-panel",
  ".fps",
  ".latency",
  ".info-layer",
  ".info-title",
  ".game-name",
  ".game-detail",
  ".info-close",
  ".logs-layer",
  ".logs-title",
  ".logs-output",
  ".logs-copy",
  ".logs-clear",
  ".logs-close",
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
    ].includes(selector),
    tagName: selector.startsWith(".") ? "BUTTON" : "DIV",
    textContent: "",
    style: {},
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
  sessionState = new Map(),
} = {}) {
  const windowListeners = new Map();
  const mounted = [];
  const commands = [];
  const consoleEntries = [];
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
      share: app,
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
      messages: {
        "sidebar.title": "游戏菜单",
        "sidebar.continue": "继续游戏",
        "sidebar.restart": "重新开始",
        "sidebar.share": "分享/邀请",
        "sidebar.logs": "运行日志",
        "sidebar.enter_fullscreen": "进入全屏",
        "sidebar.exit_fullscreen": "退出全屏",
        "sidebar.info": "游戏信息",
        "sidebar.performance": "显示性能信息",
        "sidebar.performance_hide": "关闭性能信息",
        "sidebar.exit": "退出游戏",
        "info.title": "游戏信息",
        "info.game_id": "Game ID",
        "info.role": "运行角色",
        "info.role_solo": "单机",
        "info.platform": "运行平台",
        "info.app_sdk": "App SDK",
        "info.capabilities": "声明能力",
        "info.none": "无",
        "logs.title": "运行日志",
        "logs.empty": "暂无运行日志",
        "logs.copy": "复制全部",
        "logs.copied": "已复制",
        "common.close": "关闭",
        "common.clear": "清空",
      },
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
    location: { reload() {}, replace() {} },
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
    history: { length: 1, back() {} },
    queueMicrotask,
    setTimeout,
    clearTimeout,
    addEventListener(type, listener) {
      const current = windowListeners.get(type) || [];
      current.push(listener);
      windowListeners.set(type, current);
    },
  };
  if (app) {
    window.PlaymeshAppBridge = {
      postMessage(raw) {
        const command = JSON.parse(raw);
        commands.push(command.command);
        queueMicrotask(() => {
          window.playmeshApp.__receive({
            type: "app.command.result",
            requestId: command.requestId,
            result: command.command === "app.bootstrap"
              ? {
                  available: true,
                  sdkVersion: "3.0.0",
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
                }
              : null,
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
    document,
    mounted,
    commands,
    consoleEntries,
    gameFocus,
    dispatchKey,
  };
}

const browserPage = createPage();
assert.equal(browserPage.consoleEntries[0].args.length, 1);
assert.equal(
  browserPage.consoleEntries[0].args[0],
  'Playmesh App SDK 注入成功 {"version":"3.0.0"}',
);
await browserPage.window.playmeshApp.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(browserPage.mounted.length, 1);
browserPage.window.playmeshApp.__registerRuntimeUi({
  async getInfo() {
    return {
      gameId: "com.playmesh.browser-game",
      gameName: "浏览器游戏",
      requiredCapabilities: [],
      joinCode: null,
      multiplayer: false,
      isAuthority: true,
      playerName: null,
      playerCount: null,
      gameSdkVersion: "3.0.0",
      appSdkVersion: "3.0.0",
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
await browserPage.window.playmeshApp.ui.openRuntimeLogs();
assert.equal(
  browserUi[".logs-output"].textContent.includes(
    'Playmesh App SDK 注入成功 {"version":"3.0.0"}',
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
await browserPage.window.playmeshApp.ui.openGameInfo();
assert.equal(browserUi[".game-name"].textContent, "浏览器游戏");
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
    ".performance-panel{position:fixed;right:max(12px,env(safe-area-inset-right));top:max(12px,env(safe-area-inset-top));z-index:2147483647",
  ),
  true,
);

browserUi[".scrim"].click();
assert.equal(browserUi[".layer"].hidden, true);
assert.equal(browserPage.document.activeElement, browserPage.gameFocus);
await browserPage.window.playmeshApp.ui.showGameSidebar();
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
assert.equal(browserPage.document.activeElement, browserUi[".enter-fullscreen"]);
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
assert.equal(await browserPage.window.playmeshApp.ui.showGameSidebar(), true);
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
await restartPage.window.playmeshApp.ready;
await restartPage.window.playmeshApp.ui.showGameSidebar();
restartPage.mounted[0].__elements[".restart"].click();
assert.equal(
  restartPage.mounted[0].__elements[".layer"].hidden,
  true,
);
assert.equal(restartSession.has("playmesh.app.ui.reopenAfterRestart"), false);
const reloadedPage = createPage({ sessionState: restartSession });
await reloadedPage.window.playmeshApp.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(reloadedPage.mounted[0].__elements[".layer"].hidden, true);

const disabledPage = createPage({ fallbackUi: false });
await disabledPage.window.playmeshApp.ready;
assert.equal(disabledPage.mounted.length, 0);
assert.equal(await disabledPage.window.playmeshApp.ui.showGameSidebar(), false);
assert.equal(disabledPage.dispatchKey("Escape", 27).defaultPrevented, false);

const browserWithoutFloatingButton = createPage();
assert.equal(
  browserWithoutFloatingButton.window.playmeshApp.ui.initializeBrowser(),
  true,
);
await browserWithoutFloatingButton.window.playmeshApp.ready;
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(browserWithoutFloatingButton.mounted.length, 1);
assert.equal(
  browserWithoutFloatingButton.mounted[0].__root.html.includes(
    'class="menu-fab"',
  ),
  false,
);
assert.equal(
  await browserWithoutFloatingButton.window.playmeshApp.ui.showGameSidebar(),
  true,
);

const appPage = createPage({ app: true });
const earlyEscape = appPage.dispatchKey("Escape", 27);
await Promise.resolve();
assert.equal(earlyEscape.defaultPrevented, true);
assert.equal(appPage.mounted[0].__elements[".layer"].hidden, false);
await appPage.window.playmeshApp.ready;
await Promise.resolve();
assert.equal(appPage.commands.includes("app.input.takeover"), true);
assert.equal(appPage.window.playmeshApp.ui.initializeBrowser(), false);
const appUi = appPage.mounted[0].__elements;
appUi[".continue"].focus();
appPage.mounted[0].__root.emit("keydown", { key: "ArrowDown" });
assert.equal(appPage.document.activeElement, appUi[".share"]);
appPage.mounted[0].__root.emit("keydown", { key: "ArrowRight" });
assert.equal(appPage.document.activeElement, appUi[".logs"]);
assert.equal(
  appPage.mounted[0].__root.html.includes('class="menu-fab"'),
  false,
);
assert.equal(appPage.commands.includes("app.ui.gameSidebar.show"), false);
assert.equal(appPage.window.playmeshApp.hideGameSidebar, undefined);
assert.equal(appPage.window.playmeshApp.onMenuRequest, undefined);
appPage.mounted[0].__elements[".share"].click();
assert.equal(appPage.mounted[0].__elements[".layer"].hidden, false);
await Promise.resolve();
assert.equal(appPage.commands.includes("app.ui.openSharePanel"), true);

const androidMenuPage = createPage();
await androidMenuPage.window.playmeshApp.ready;
assert.equal(androidMenuPage.dispatchKey("Menu", 82).defaultPrevented, true);
await Promise.resolve();
assert.equal(androidMenuPage.mounted[0].__elements[".layer"].hidden, false);
androidMenuPage.mounted[0].__elements[".continue"].click();
assert.equal(androidMenuPage.dispatchKey("Back", 4).defaultPrevented, true);
await Promise.resolve();
assert.equal(androidMenuPage.mounted[0].__elements[".layer"].hidden, false);

console.log("Playmesh App SDK fallback UI, first-key, and draggable button contract passed");
