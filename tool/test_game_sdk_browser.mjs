import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh.js", import.meta.url), "utf8");
const hostData = new Map();
const browserLocalStorage = new Map();
const storageCommands = [];
const nicknameCommands = [];
const joinCommands = [];
let joins = 0;

function createPage(appIdentity = null, reconnected = false) {
  const elements = Object.fromEntries([
    ".panel", ".fps", ".latency", ".edit", ".overlay", ".enter", ".card", "form", "h2", "input", ".error", ".close", ".save",
    ".performance", ".expand", ".tools", ".collapse", ".reload", ".enter-fullscreen", ".exit-fullscreen", ".more", ".menu", ".info", ".logs", ".info-overlay", ".info-close", ".info-title", ".game-name", ".session-info",
  ].map((selector) => [selector, {
    hidden: false, textContent: "", value: "", disabled: false,
    focus() {}, insertBefore() {}, onclick: null, onsubmit: null,
    classList: { toggle() {} }, setAttribute() {},
  }]));
  elements[".edit"].hidden = true;
  elements[".latency"].hidden = true;
  elements[".overlay"].hidden = true;
  elements[".expand"].hidden = true;
  elements[".menu"].hidden = true;
  elements[".info-overlay"].hidden = true;
  const mountedHosts = [];
  const shadowHtml = [];
  const shadowRoot = {
    set innerHTML(value) { shadowHtml.push(value); },
    get innerHTML() { return shadowHtml.at(-1) || ""; },
    appendChild() {},
    querySelector(selector) {
      return elements[selector];
    },
  };
  const document = {
    body: { appendChild(element) { mountedHosts.push(element.id); } },
    fullscreenElement: null,
    addEventListener() {},
    createElement(tagName) {
      const element = {
        id: "", className: "", type: "", textContent: "", onclick: null,
        attachShadow: () => shadowRoot,
      };
      if (tagName === "button") elements[".later"] = element;
      return element;
    },
  };
  document.documentElement = {
    async requestFullscreen() {
      document.fullscreenElement = document.documentElement;
    },
  };
  document.exitFullscreen = async () => {
    document.fullscreenElement = null;
  };
  let currentPlayerId = null;
  let currentNickname = null;

  class FakeWebSocket {
    constructor() {
      this.listeners = new Map();
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
      if (type === "open") {
        queueMicrotask(() => {
          listener();
          this.listeners.get("message")?.({
            data: JSON.stringify({
              type: "session.state",
              session: {
                id: "s-1",
                joinCode: "ABC123",
                authorityClientId: "p-authority",
                players: [
                  { id: currentPlayerId, nickname: currentNickname, role: "player", connected: true },
                ],
              },
            }),
          });
        });
      }
    }

    send(rawMessage) {
      const message = JSON.parse(rawMessage);
      if (message.type === "session.ping") {
        queueMicrotask(() => this.listeners.get("message")?.({
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
  }

  const window = {
    __PLAYMESH_BROWSER__: {
      joinEndpoint: "/api/join",
      coreBase: "http://192.168.1.20:42000/",
      joinCode: "ABC123",
      shareToken: "game-token",
      storageEndpoint: "/api/storage",
      nicknameEndpoint: "/api/player/nickname",
    },
    localStorage: {
      getItem: (key) => browserLocalStorage.get(key) ?? null,
      setItem: (key, value) => browserLocalStorage.set(key, value),
    },
    document,
    location: { reload() {} },
    fetch: async (url, options) => {
      if (url === "/api/storage") {
        const command = JSON.parse(options.body);
        storageCommands.push(command);
        const key = `${command.bucket}:${command.key}`;
        if (command.command === "storage.set") hostData.set(key, command.value);
        if (command.command === "storage.remove") hostData.delete(key);
        if (command.command === "storage.clear") {
          for (const existing of hostData.keys()) {
            if (existing.startsWith(`${command.bucket}:`)) hostData.delete(existing);
          }
        }
        return {
          ok: true,
          json: async () => ({
            result: command.command === "storage.get" ? hostData.get(key) : null,
          }),
        };
      }
      if (url === "/api/player/nickname") {
        const command = JSON.parse(options.body);
        nicknameCommands.push(command);
        currentNickname = command.nickname;
        return {
          ok: true,
          json: async () => ({
            player: { id: currentPlayerId, nickname: currentNickname, role: "player" },
            session: {
              id: "s-1", joinCode: "ABC123", authorityClientId: "p-authority",
              players: [{ id: currentPlayerId, nickname: currentNickname, role: "player" }],
            },
          }),
        };
      }
      const joinCommand = JSON.parse(options.body);
      joinCommands.push(joinCommand);
      assert.deepEqual(
        Object.keys(joinCommand).sort(),
        ["nickname", "playerId", "shareToken"],
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
          credential: {
            token: `player-token-${joins}`,
            player: { id: playerId, nickname: currentNickname, role: "player" },
            reconnected,
          },
          session: {
            id: "s-1", joinCode: "ABC123", authorityClientId: "p-authority",
            players: [{ id: playerId, nickname: currentNickname, role: "player", connected: false }],
          },
        }),
      };
    },
    WebSocket: FakeWebSocket,
    URL,
    addEventListener() {},
    queueMicrotask,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  if (appIdentity) {
    window.playmeshApp = {
      ready: Promise.resolve({ available: true }),
      isAvailable: () => true,
      identity: { getCurrent: () => ({ ...appIdentity }) },
      device: {
        getPlatform: () => "android",
        getCapabilities: () => ["fullscreen", "haptics"],
      },
    };
  }
  window.window = window;
  vm.runInNewContext(source, window, { filename: "playmesh.js" });
  window.__ui = elements;
  window.__mountedHosts = mountedHosts;
  window.__shadowHtml = shadowHtml;
  return window;
}

const firstPage = createPage();
const playerJoinEvents = [];
const playerLeaveEvents = [];
const playerReconnectEvents = [];
firstPage.playmesh.session.onPlayerJoin((event) => playerJoinEvents.push(event));
firstPage.playmesh.session.onPlayerLeave((event) => playerLeaveEvents.push(event));
firstPage.playmesh.session.onPlayerReconnect((event) => playerReconnectEvents.push(event));
while (!firstPage.__ui[".enter"].onclick) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(joins, 0, "全屏前不应加入对局");
while (!firstPage.__ui.form.onsubmit) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
assert.equal(firstPage.__ui[".overlay"].hidden, false, "首次进入应显示昵称输入层");
firstPage.__ui.input.value = "缓存玩家";
await firstPage.__ui.form.onsubmit({ preventDefault() {} });
await firstPage.playmesh.ready;
assert.equal(joins, 1);
assert.equal(firstPage.playmesh.app.isAvailable(), false);
assert.equal(firstPage.playmesh.app.identity.getCurrent(), null);
assert.equal(firstPage.playmesh.session.isAuthority(), false);
assert.equal(firstPage.__mountedHosts.includes("playmesh-browser-profile"), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("更多游戏操作")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("运行日志")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("游戏设置")), true);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("返回游戏")), false);
assert.equal(firstPage.__shadowHtml.some((html) => html.includes("退出游戏")), false);
firstPage.__ui[".performance"].onclick();
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(firstPage.__ui[".panel"].hidden, true, "浏览器工具区应能切换性能信息");
firstPage.__ui[".collapse"].onclick();
assert.equal(firstPage.__ui[".tools"].hidden, true);
assert.equal(firstPage.__ui[".expand"].hidden, false);
firstPage.__ui[".expand"].onclick();
firstPage.__ui[".more"].onclick();
assert.equal(firstPage.__ui[".menu"].hidden, false);
firstPage.__ui[".info"].onclick();
assert.equal(firstPage.__ui[".info-overlay"].hidden, false);
assert.equal(firstPage.__ui[".game-name"].textContent, "Playmesh 游戏");
firstPage.__ui[".performance"].onclick();
await new Promise((resolve) => setTimeout(resolve, 0));
const persistedBrowserId = browserLocalStorage.get("playmesh.player-id.v1");
assert.match(persistedBrowserId, /^p_[a-f0-9]{32}$/);
assert.equal(firstPage.playmesh.player.getCurrent().id, persistedBrowserId);
assert.equal(playerJoinEvents.length, 1);
assert.equal(playerJoinEvents[0].player.id, persistedBrowserId);
assert.equal(playerJoinEvents[0].isCurrentPlayer, true);
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
assert.notEqual(
  firstPage.playmesh.player.getCurrent().id,
  firstPage.playmesh.session.getCurrent().authorityClientId,
  "浏览器首个加入玩家不能成为 Authority",
);

const appPage = createPage({ userId: "u-current-app", nickname: "App 玩家" });
await appPage.playmesh.ready;
assert.equal(appPage.playmesh.app.isAvailable(), true);
assert.equal(joinCommands.at(-1).playerId, "u-current-app");
assert.equal(joinCommands.at(-1).nickname, "App 玩家");
assert.equal(appPage.__ui[".edit"].hidden, true);
assert.equal(appPage.__mountedHosts.includes("playmesh-browser-profile"), false);
assert.equal(appPage.__mountedHosts.includes("playmesh-performance"), true);
assert.equal(firstPage.__ui[".panel"].hidden, false);
assert.equal(firstPage.__ui[".latency"].hidden, false);
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
assert.equal(storageCommands.every((command) => command.shareToken === "game-token"), true);
assert.equal(storageCommands.some((command) => command.command === "storage.set"), true);

const refreshedPage = createPage();
while (!refreshedPage.__ui[".enter"].onclick) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
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
refreshedPage.__ui[".edit"].onclick();
await Promise.resolve();
refreshedPage.__ui.input.value = "修改后的玩家";
await refreshedPage.__ui.form.onsubmit({ preventDefault() {} });
assert.equal(refreshedPage.playmesh.player.getCurrent().nickname, "修改后的玩家");
assert.equal(browserLocalStorage.get("playmesh.nickname.v1"), "修改后的玩家");
assert.equal(nicknameCommands.length, 1);
assert.equal(nicknameCommands[0].playerToken, "player-token-3");
assert.equal(nicknameCommands[0].shareToken, "game-token");

const reconnectPage = createPage(null, true);
const selfReconnectEvents = [];
reconnectPage.playmesh.session.onPlayerReconnect((event) => selfReconnectEvents.push(event));
await reconnectPage.playmesh.ready;
assert.equal(selfReconnectEvents.length, 1);
assert.equal(selfReconnectEvents[0].isCurrentPlayer, true);
assert.equal(selfReconnectEvents[0].player.id, persistedBrowserId);

console.log("Game SDK browser persistent identity and nickname contract passed");
