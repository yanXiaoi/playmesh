import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const gdevelopPolicyRoot = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "GDevelop",
  "playmesh",
);
const webideLock = JSON.parse(
  fs.readFileSync(path.join(gdevelopPolicyRoot, "webide-lock.json"), "utf8"),
);
const sourcePolicyOutputManifest = JSON.parse(
  fs.readFileSync(
    path.join(gdevelopPolicyRoot, "source-policy-output-manifest.json"),
    "utf8",
  ),
);
const lockedGDevelopVersion = webideLock.upstream.tag.replace(/^v/, "");
const multiplayerToolsManifest =
  sourcePolicyOutputManifest.patchedOfficialFiles.find(
    entry => entry.relativePath === "Extensions/Multiplayer/multiplayertools.ts",
  );
assert.ok(
  multiplayerToolsManifest,
  "source-policy manifest must lock the official Multiplayer state machine",
);
const goCoreRoot = path.join(repositoryRoot, "go-core");
const gameSdkSource = fs.readFileSync(
  path.join(
    repositoryRoot,
    "assets",
    "playmesh-library",
    "public",
    "sdk",
    "v1",
    "playmesh-main.js",
  ),
  "utf8",
);
const gdevelopBridgeSource = fs.readFileSync(
  path.join(
    repositoryRoot,
    "assets",
    "playmesh-library",
    "public",
    "developer",
    "gdevelop-multiplayer-bridge.js",
  ),
  "utf8",
);
const gdevelopBootstrapSource = fs.readFileSync(
  path.join(
    repositoryRoot,
    "assets",
    "playmesh-library",
    "public",
    "developer",
    "gdevelop-authority-bootstrap.js",
  ),
  "utf8",
);
const officialGDevelopSourceRoot = path.resolve(
  process.env.PLAYMESH_GDEVELOP_OFFICIAL_SOURCE_ROOT ||
    path.join(
      repositoryRoot,
      "work",
      "gdevelop-webide-build-cache",
      "profiles",
      "default",
      "upstream",
    ),
);
const officialMultiplayerToolsPath = path.join(
  officialGDevelopSourceRoot,
  "Extensions",
  "Multiplayer",
  "multiplayertools.ts",
);
if (!fs.existsSync(officialMultiplayerToolsPath)) {
  throw new Error(
    `缺少锁定的官方 GDevelop ${lockedGDevelopVersion} 源码；请设置 PLAYMESH_GDEVELOP_OFFICIAL_SOURCE_ROOT。`,
  );
}
const officialMultiplayerToolsBytes = fs.readFileSync(
  officialMultiplayerToolsPath,
);
const officialMultiplayerToolsGitBlobSha = createHash("sha1")
  .update(Buffer.from(`blob ${officialMultiplayerToolsBytes.length}\0`, "utf8"))
  .update(officialMultiplayerToolsBytes)
  .digest("hex");
assert.equal(
  officialMultiplayerToolsGitBlobSha,
  multiplayerToolsManifest.upstreamGitBlobSha,
  `E2E 只能执行锁定的官方 GDevelop ${lockedGDevelopVersion} Multiplayer 状态机`,
);
const officialMultiplayerToolsSource = officialMultiplayerToolsBytes.toString(
  "utf8",
);
const mainInternalKey = Symbol.for("playmesh.main.internal.v1");
const appInternalKey = Symbol.for("playmesh.app.internal.v1");
const injectedFailureStage =
  process.env.PLAYMESH_GDEVELOP_E2E_INJECT_FAILURE_STAGE || "";
const cleanupTracePath =
  process.env.PLAYMESH_GDEVELOP_E2E_CLEANUP_TRACE_PATH || "";

function extractOfficialSourceSection(startMarker, endMarker) {
  const start = officialMultiplayerToolsSource.indexOf(startMarker);
  assert.notEqual(start, -1, `官方源码缺少起始锚点：${startMarker}`);
  const end = officialMultiplayerToolsSource.indexOf(endMarker, start);
  assert.notEqual(end, -1, `官方源码缺少结束锚点：${endMarker}`);
  assert.equal(
    officialMultiplayerToolsSource.indexOf(startMarker, start + 1),
    -1,
    `官方源码锚点不唯一：${startMarker}`,
  );
  return officialMultiplayerToolsSource.slice(start, end);
}

const officialHandleLeaveLobbySource = extractOfficialSourceSection(
  "    const handleLeaveLobbyEvent = function () {",
  "    const handleLobbyUpdatedEvent = function",
);
const officialHandleLobbyGameEndedSource = extractOfficialSourceSection(
  "    export const handleLobbyGameEnded = function () {",
  "    const handlePeerIdEvent = function",
).replace("    export const", "    const");
const officialLeaveGameLobbySource = extractOfficialSourceSection(
  "    export const leaveGameLobby = async () => {",
  "  }\n}",
).replace("    export const", "    const");

assert.equal(
  typeof WebSocket,
  "function",
  "真实 E2E 需要带标准 WebSocket 的 Node.js 运行时",
);

function writeCleanupTrace(update) {
  if (!cleanupTracePath) return;
  let current = {};
  try {
    current = JSON.parse(fs.readFileSync(cleanupTracePath, "utf8"));
  } catch (_) {}
  fs.writeFileSync(
    cleanupTracePath,
    `${JSON.stringify({ ...current, ...update }, null, 2)}\n`,
    "utf8",
  );
}

function platformUiConfiguration() {
  const manifest = JSON.parse(
    fs.readFileSync(
      path.join(repositoryRoot, "assets", "playmesh-localization", "manifest.json"),
      "utf8",
    ),
  );
  const locale = manifest.locales.find(
    (candidate) => candidate.id === manifest.defaultLocale,
  );
  const appMessages = JSON.parse(
    fs.readFileSync(
      path.join(
        repositoryRoot,
        "assets",
        "playmesh-localization",
        locale.bundles.app,
      ),
      "utf8",
    ),
  );
  return {
    locale: locale.id,
    theme: "dark",
    messages: Object.fromEntries(
      Object.entries(appMessages)
        .filter(([key]) => key.startsWith("platform.game."))
        .map(([key, value]) => [key.slice("platform.game.".length), value]),
    ),
  };
}

const platformUi = platformUiConfiguration();

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      reject(
        new Error(
          `${command} ${args.join(" ")} 失败: code=${code} signal=${signal}\n${stdout}\n${stderr}`,
        ),
      );
    });
  });
}

async function waitFor(predicate, message, timeoutMs = 8_000) {
  const startedAt = Date.now();
  let lastError = null;
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(
    `${message}${lastError ? `: ${lastError.message || String(lastError)}` : ""}`,
  );
}

async function startGoCore(binaryPath) {
  const child = spawn(binaryPath, ["-addr", "127.0.0.1:0"], {
    cwd: goCoreRoot,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  let stdoutBuffer = "";
  let stderr = "";
  let address = null;
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    for (;;) {
      const newline = stdoutBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = stdoutBuffer.slice(0, newline).trim();
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      try {
        const record = JSON.parse(line);
        if (record.event === "core.started" && typeof record.address === "string") {
          address = record.address;
        }
      } catch (_) {}
    }
  });
  const exited = new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  await waitFor(
    async () => {
      if (address) return address;
      if (child.exitCode !== null) {
        throw new Error(`go-core 提前退出: ${child.exitCode}\n${stderr}`);
      }
      return null;
    },
    "等待 go-core 动态监听地址超时",
    10_000,
  );
  return {
    child,
    baseUrl: `http://${address}/`,
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) return;
      child.kill();
      const stopped = await Promise.race([
        exited.then(() => true),
        new Promise((resolve) => setTimeout(() => resolve(false), 5_000)),
      ]);
      if (!stopped && child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
        await exited;
      }
    },
  };
}

async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const body = await response.json();
  if (!response.ok) {
    const error = new Error(body.error?.message || `HTTP ${response.status}`);
    error.code = body.error?.code;
    throw error;
  }
  return body;
}

async function createSession(baseUrl) {
  return requestJson(new URL("v1/sessions", baseUrl), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      gameId: "com.playmesh.gdevelop-e2e",
      displayMode: "multi_screen",
      minPlayers: 1,
      maxPlayers: 8,
      nickname: "E2E Authority",
    }),
  });
}

async function joinSession(baseUrl, joinCode, playerId, nickname) {
  return requestJson(new URL("v1/sessions/join", baseUrl), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      joinCode,
      nickname,
      playerId,
      source: "lan_html",
    }),
  });
}

function coreWebSocketUrl(baseUrl, relativePath, token) {
  const url = new URL(relativePath, baseUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.searchParams.set("token", token);
  return url.toString();
}

function vmValue(context, value) {
  context.__gdevelopE2eFixtureJson = JSON.stringify(value);
  const result = vm.runInContext(
    "JSON.parse(__gdevelopE2eFixtureJson)",
    context,
  );
  delete context.__gdevelopE2eFixtureJson;
  return result;
}

function createLocalFrameFixture() {
  const attributes = new Map([["src", "https://forbidden.example"]]);
  const posted = [];
  const contentWindow = {
    postMessage(message, targetOrigin) {
      posted.push({ message, targetOrigin });
    },
  };
  return {
    attributes,
    posted,
    contentWindow,
    frame: {
      contentWindow,
      srcdoc: "",
      setAttribute(name, value) {
        attributes.set(name, value);
      },
      removeAttribute(name) {
        attributes.delete(name);
      },
    },
  };
}

function readLocalFrameCapability(frame) {
  const match = frame.srcdoc.match(/const capability="([0-9a-f]{64})"/);
  assert.ok(match, "本地大厅 srcdoc 缺少 256-bit capability");
  return match[1];
}

function runLocalLobbyFrameDocument(frame) {
  const scriptMatch = frame.srcdoc.match(/<script>([\s\S]*)<\/script>/);
  assert.ok(scriptMatch, "本地大厅 srcdoc 缺少可执行脚本");
  const outbound = [];
  const windowListeners = new Map();
  const elementIds = [
    "card",
    "status",
    "statusPanel",
    "statusLabel",
    "eyebrow",
    "heading",
    "lead",
    "connectionBadge",
    "connectionLabel",
    "metrics",
    "playersLabel",
    "playerSummary",
    "roleLabel",
    "roleSummary",
    "slotLabel",
    "playerMeta",
    "playersPanel",
    "playersHeading",
    "playersA11yHint",
    "actionNote",
    "escHint",
    "escLabel",
    "join",
    "countdown",
    "start",
    "playerReady",
    "joinGame",
    "leave",
    "solo",
    ...Array.from({ length: 8 }, (_, index) => [
      `playerRow${index + 1}`,
      `playerAvatar${index + 1}`,
      `playerImage${index + 1}`,
      `playerName${index + 1}`,
      `playerState${index + 1}`,
      `playerCurrent${index + 1}`,
    ]).flat(),
  ];
  const elements = new Map(
    elementIds.map((id) => {
      const listeners = new Map();
      return [
        id,
        {
          hidden: id !== "status",
          disabled: false,
          textContent: "",
          src: "",
          alt: "",
          dataset: {},
          addEventListener(type, listener) {
            listeners.set(type, listener);
          },
          __listeners: listeners,
        },
      ];
    }),
  );
  const parentWindow = {
    postMessage(message, targetOrigin) {
      outbound.push({ message, targetOrigin });
    },
  };
  const sandbox = {
    document: {
      title: "",
      getElementById(id) {
        return elements.get(id) || null;
      },
    },
    navigator: { language: platformUi.locale },
    parent: parentWindow,
    addEventListener(type, listener) {
      windowListeners.set(type, listener);
    },
  };
  sandbox.window = sandbox;
  const context = vm.createContext(sandbox);
  vm.runInContext(scriptMatch[1], context, {
    filename: "playmesh-gdevelop-local-lobby-frame.js",
  });
  return {
    outbound,
    elements,
    click(id) {
      const element = elements.get(id);
      assert.ok(element, `本地大厅元素 ${id} 不存在`);
      assert.equal(element.hidden, false, `本地大厅操作 ${id} 当前不可见`);
      assert.equal(element.disabled, false, `本地大厅操作 ${id} 当前不可用`);
      const listener = element.__listeners.get("click");
      assert.equal(typeof listener, "function");
      listener();
    },
    dispatchFromParent(message, source = parentWindow) {
      const listener = windowListeners.get("message");
      assert.equal(typeof listener, "function");
      context.__parentMessageJson = JSON.stringify(message);
      const clonedMessage = vm.runInContext(
        "JSON.parse(__parentMessageJson)",
        context,
      );
      delete context.__parentMessageJson;
      listener({ source, data: clonedMessage, origin: "null" });
    },
    parentWindow,
  };
}

function localFrameEvent(page, fixture, message) {
  return {
    source: fixture.contentWindow,
    origin: "null",
    data: vmValue(page.context, JSON.parse(JSON.stringify(message))),
  };
}

function createPrimaryAdapter({ window, baseUrl, joined, consoleEntries }) {
  let socket = null;
  let sequence = 0;
  let latestSession = joined.session;
  let bootstrapped = false;
  let disposed = false;
  const bufferedMessages = [];
  const sessionCommandCounts = { start: 0, reset: 0, finish: 0 };

  const receive = (message) => {
    if (typeof window.__playmeshE2eReceiveInRealm === "function") {
      return window.__playmeshE2eReceiveInRealm(JSON.stringify(message));
    }
    return window[mainInternalKey].receive(message);
  };
  const respond = (requestId, result) => {
    receive({ type: "command.result", requestId, result });
  };
  const reject = (requestId, error) => {
    receive({
      type: "command.error",
      requestId,
      code: error.code || "e2e_adapter_error",
      error: error.message || String(error),
    });
  };
  const forwardTransport = (message) => {
    if (message.type === "session.state" && message.session) {
      latestSession = message.session;
    }
    if (!bootstrapped) {
      bufferedMessages.push(message);
      return;
    }
    receive({ type: "transport.message", message });
  };
  const sendTransport = (type, payload, targetPlayerIds = []) => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      throw new Error("主 Session WebSocket 尚未连接");
    }
    socket.send(JSON.stringify({
      type,
      sequence: ++sequence,
      targetPlayerIds,
      payload,
    }));
  };
  const connect = async () => {
    socket = new window.WebSocket(
      coreWebSocketUrl(baseUrl, joined.webSocketPath, joined.credential.token),
    );
    socket.addEventListener("message", (event) => {
      forwardTransport(JSON.parse(event.data));
    });
    socket.addEventListener("close", (event) => {
      if (disposed) return;
      receive({
        type: "transport.closed",
        error: event.reason || `close code ${event.code}`,
      });
    });
    await new Promise((resolve, rejectConnection) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener(
        "error",
        () => rejectConnection(new Error("主 Session WebSocket 连接失败")),
        { once: true },
      );
    });
    await waitFor(
      () => latestSession.players.some(
        (player) => player.id === joined.credential.player.id && player.connected,
      ),
      "等待主 Session 连接快照超时",
    );
  };
  const postSessionCommand = async (command, requestId) => {
    const action = command.slice("session.".length);
    sessionCommandCounts[action] += 1;
    const result = await requestJson(
      new URL(`v1/sessions/${encodeURIComponent(joined.session.id)}/${action}`, baseUrl),
      {
        method: "POST",
        headers: { Authorization: `Bearer ${joined.credential.token}` },
      },
    );
    respond(requestId, result);
  };
  const handleCommand = async (raw) => {
    const command = JSON.parse(raw);
    try {
      switch (command.command) {
        case "sdk.ready": {
          await connect();
          const currentPlayer = latestSession.players.find(
            (player) => player.id === joined.credential.player.id,
          ) || joined.credential.player;
          receive({
            type: "sdk.bootstrap",
            requestId: command.requestId,
            sdkVersion: "4.1.0",
            gameInfo: {
              id: latestSession.gameId,
              name: "GDevelop Core E2E",
              tags: ["gdevelop", "e2e"],
              multiplayer: true,
              displayMode: latestSession.displayMode,
              requiredCapabilities: [],
            },
            isAuthority: currentPlayer.id === latestSession.authorityClientId,
            player: currentPlayer,
            session: latestSession,
            binaryTransport: {
              url: coreWebSocketUrl(
                baseUrl,
                joined.binaryWebSocketPath,
                joined.credential.token,
              ),
            },
          });
          bootstrapped = true;
          // Bootstrap 已包含最新快照，避免把连接时的旧快照重复注入。
          bufferedMessages.length = 0;
          break;
        }
        case "game.submitAction":
          sendTransport("game.action", command.payload);
          respond(command.requestId, null);
          break;
        case "authority.result":
          sendTransport(
            "authority.result",
            command.payload,
            command.targetPlayerIds,
          );
          respond(command.requestId, null);
          break;
        case "performance.ping":
          sendTransport("session.ping", command.payload);
          respond(command.requestId, null);
          break;
        case "performance.pong":
          sendTransport(
            "authority.pong",
            command.payload,
            [command.targetPlayerId],
          );
          respond(command.requestId, null);
          break;
        case "session.start":
        case "session.reset":
        case "session.finish":
          await postSessionCommand(command.command, command.requestId);
          break;
        case "lifecycle.complete":
          respond(command.requestId, null);
          break;
        default:
          throw new Error(`E2E adapter 未实现命令: ${command.command}`);
      }
    } catch (error) {
      consoleEntries.push({ level: "error", args: [error] });
      reject(command.requestId, error);
    }
  };
  return {
    postMessage(raw) {
      void handleCommand(raw);
    },
    get socket() {
      return socket;
    },
    get latestSession() {
      return latestSession;
    },
    sessionCommandCounts,
    dispose() {
      disposed = true;
      if (socket && socket.readyState < WebSocket.CLOSING) {
        socket.close(1000, "E2E 页面清理");
      }
    },
  };
}

function createPage({ baseUrl, joined, label }) {
  const consoleEntries = [];
  const trackedSockets = [];
  const windowListeners = new Map();
  class TrackedWebSocket extends WebSocket {
    constructor(url, protocols) {
      super(url, protocols);
      trackedSockets.push(this);
    }
  }
  const body = {
    isConnected: true,
    tabIndex: -1,
    focus() {},
    getAttribute() {
      return null;
    },
    setAttribute() {},
    removeAttribute() {},
  };
  const appPublicApi = {
    version: "3.3.0",
    ready: Promise.resolve({
      available: true,
      sdkVersion: "3.3.0",
      capabilityRegistry: [],
      device: {
        platform: process.platform === "win32" ? "windows" : "linux",
        capabilities: [],
        declaredCapabilities: [],
      },
    }),
    isAvailable: () => true,
    runtime: { getLocale: () => platformUi.locale },
    identity: {
      getCurrent: () => ({
        userId: joined.credential.player.id,
        nickname: joined.credential.player.nickname,
      }),
    },
    capabilities: {
      getRegistry: () => [],
      getAvailable: () => [],
      getDeclared: () => [],
    },
    device: {
      getPlatform: () => (process.platform === "win32" ? "windows" : "linux"),
      setFullscreen: async () => {},
      onInput: () => () => {},
    },
  };
  let privatePlatformUi = structuredClone(platformUi);
  const window = {
    window: null,
    WebSocket: TrackedWebSocket,
    TextEncoder,
    TextDecoder,
    Uint8Array,
    ArrayBuffer,
    DataView,
    URL,
    URLSearchParams,
    fetch,
    crypto: globalThis.crypto,
    performance,
    structuredClone,
    queueMicrotask,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    btoa(value) {
      return Buffer.from(value, "binary").toString("base64");
    },
    atob(value) {
      return Buffer.from(value, "base64").toString("binary");
    },
    navigator: { languages: [platformUi.locale], language: platformUi.locale },
    document: {
      activeElement: body,
      body,
      documentElement: { isConnected: true },
    },
    console: Object.fromEntries(
      ["log", "info", "warn", "error", "debug"].map((level) => [
        level,
        (...args) => consoleEntries.push({ level, args }),
      ]),
    ),
    addEventListener(type, listener) {
      const listeners = windowListeners.get(type) || [];
      listeners.push(listener);
      windowListeners.set(type, listeners);
    },
  };
  window.window = window;
  window[appInternalKey] = {
    publicApi: appPublicApi,
    takePlatformUiConfiguration() {
      const value = privatePlatformUi;
      privatePlatformUi = null;
      return value;
    },
    restoreGameContentFocus() {},
  };
  const primaryAdapter = createPrimaryAdapter({
    window,
    baseUrl,
    joined,
    consoleEntries,
  });
  window.PlaymeshBridge = primaryAdapter;
  const context = vm.createContext(window, { name: label });
  vm.runInContext(
    "globalThis.__playmeshE2eReceiveInRealm = raw => " +
      "globalThis[Symbol.for('playmesh.main.internal.v1')].receive(JSON.parse(raw));",
    context,
  );
  vm.runInContext(gameSdkSource, context, { filename: "playmesh-main.js" });
  vm.runInContext(gdevelopBridgeSource, context, {
    filename: "gdevelop-multiplayer-bridge.js",
  });
  vm.runInContext(gdevelopBootstrapSource, context, {
    filename: "gdevelop-authority-bootstrap.js",
  });
  const registry = context[Symbol.for("playmesh.runtime.backends.v1")];
  const coordinator = context[
    Symbol.for("playmesh.gdevelop.multiplayer.coordinator.v1")
  ];
  assert.ok(registry, `${label} 缺少私有 GDevelop backend registry`);
  assert.ok(coordinator, `${label} 缺少私有 GDevelop multiplayer coordinator`);
  const multiplayerBackend = registry.negotiate(vmValue(context, {
    engine: "gdevelop",
    engineVersion: lockedGDevelopVersion,
    feature: "multiplayer",
    minVersion: 1,
    maxVersion: 1,
  }));
  return {
    label,
    window,
    context,
    consoleEntries,
    trackedSockets,
    primaryAdapter,
    registry,
    coordinator,
    multiplayerBackend,
    peer: null,
    playerNumber: null,
    binarySockets() {
      return trackedSockets.filter((socket) =>
        new URL(socket.url).pathname.endsWith("/binary")
      );
    },
    async ready() {
      await window.playmesh.ready;
      await window.playmeshGDevelopAuthorityBootstrap.install();
      await waitFor(
        () => window.playmeshGDevelopAuthorityBootstrap.installed,
        `${label} GDevelop bootstrap 初始化超时`,
      );
      const currentSession = window.playmesh.main.session.getCurrent();
      const currentPlayer = window.playmesh.main.player.getCurrent();
      await this.multiplayerBackend.request(
        "checkGameRegistration",
        vmValue(context, { gameId: "gdevelop-e2e-official-project" }),
      );
      try {
        await waitFor(async () => {
          const lobby = await this.multiplayerBackend.request(
            "getLobbyById",
            vmValue(context, {
              gameId: "gdevelop-e2e-official-project",
              lobbyId: currentSession.id,
            }),
          );
          const record = lobby.players.find(
            (player) => player.playerId === currentPlayer.id,
          );
          if (!record) return false;
          this.playerNumber = record.playerNumber;
          return true;
        }, `${label} 稳定玩家编号初始化超时`);
      } catch (error) {
        const diagnostics = consoleEntries.slice(-12).map((entry) => ({
          level: entry.level,
          args: entry.args.map((value) =>
            value instanceof Error ? `${value.name}: ${value.message}` : value
          ),
        }));
        throw new Error(`${error.message}; console=${JSON.stringify(diagnostics)}`);
      }
      this.peer = this.multiplayerBackend.createOfficialPeer();
      await new Promise((resolve) => this.peer.on("open", resolve));
      return this;
    },
    async dispose() {
      await window.playmeshGDevelopAuthorityBootstrap.dispose();
      window[mainInternalKey].receive({
        type: "lifecycle.event",
        event: "exit",
        requestId: `${label}-exit`,
      });
      primaryAdapter.dispose();
    },
  };
}

async function reconnectBinary(page) {
  const previousSockets = page.binarySockets();
  const previous = previousSockets.at(-1);
  assert.ok(previous, `${page.label} 缺少 Binary WebSocket`);
  const restoredLogCount = page.consoleEntries.filter((entry) =>
    String(entry.args[0]).includes("Playmesh Binary Channel 已恢复")
  ).length;
  previous.close(1000, "E2E Binary 瞬断");
  await waitFor(
    () => page.binarySockets().length > previousSockets.length,
    `${page.label} Binary WebSocket 未重连`,
  );
  await waitFor(
    () =>
      page.consoleEntries.filter((entry) =>
        String(entry.args[0]).includes("Playmesh Binary Channel 已恢复")
      ).length > restoredLogCount,
    `${page.label} Binary Channel 未恢复 JOIN`,
  );
}

function observePeer(page) {
  page.connections = new Map();
  page.connectionErrors = [];
  page.peerMessages = [];
  page.observedConnections = new Set();
  const observeConnection = (connection) => {
    if (page.observedConnections.has(connection)) return connection;
    page.observedConnections.add(connection);
    connection.on("open", () => page.connections.set(connection.peer, connection));
    connection.on("data", (message) => {
      page.peerMessages.push({ sender: connection.peer, message });
    });
    connection.on("error", (error) => {
      page.connectionErrors.push({ peer: connection.peer, error });
    });
    connection.on("close", () => {
      if (page.connections.get(connection.peer) === connection) {
        page.connections.delete(connection.peer);
      }
    });
    return connection;
  };
  page.observeConnection = observeConnection;
  page.peer.on("connection", observeConnection);
}

async function connectPeer(page, targetPeerId) {
  const connection = page.observeConnection(page.peer.connect(targetPeerId));
  await waitFor(
    () => page.connections.get(targetPeerId) === connection,
    `${page.label} 未连接到 ${targetPeerId}`,
  );
  return connection;
}

function sendPeerMessage(page, targetPeerId, messageName, data) {
  const connection = page.connections.get(targetPeerId);
  assert.ok(connection, `${page.label} 缺少到 ${targetPeerId} 的逻辑连接`);
  connection.send(vmValue(page.context, {
    messageName,
    data: JSON.stringify(data),
  }));
}

async function waitForPeerMessage(page, messageName, count = 1) {
  return waitFor(
    () => {
      const messages = page.peerMessages.filter(
        (entry) => entry.message.messageName === messageName,
      );
      return messages.length >= count ? messages : null;
    },
    `${page.label} 未收到 ${messageName}`,
  );
}

async function getLobby(page) {
  const session = page.window.playmesh.main.session.getCurrent();
  return page.multiplayerBackend.request(
    "getLobbyById",
    vmValue(page.context, {
      gameId: "gdevelop-e2e-official-project",
      lobbyId: session.id,
    }),
  );
}

async function requestCompatibilityChannelId(page) {
  const main = page.window.playmesh.main;
  const session = main.session.getCurrent();
  const messages = [];
  const unregister = main.game.onMessage((message) => messages.push(message));
  try {
    await main.game.submitAction(
      vmValue(page.context, {
        type: "channel.request",
        protocol: "playmesh.gdevelop.multiplayer.v1",
        version: 1,
        sessionId: session.id,
      }),
      vmValue(page.context, {
        namespace: "playmesh.gdevelop.multiplayer.v1",
      }),
    );
    const message = await waitFor(
      () =>
        messages.find(
          (candidate) =>
            candidate &&
            candidate.type === "channel.ready" &&
            candidate.sessionId === session.id,
        ),
      `${page.label} 未收到兼容层 channel.ready`,
    );
    assert.equal(message.protocol, "playmesh.gdevelop.multiplayer.v1");
    assert.equal(message.version, 1);
    assert.equal(typeof message.channelId, "string");
    assert.ok(message.channelId.length > 0);
    return message.channelId;
  } finally {
    unregister();
  }
}

async function openOfficialLobbyControl(page) {
  const messages = [];
  const socket = page.multiplayerBackend.createOfficialLobbyControlFacade();
  const sent = [];
  const control = {
    socket,
    messages,
    sent,
    connection: null,
    onMessage: null,
    send(frame) {
      sent.push(structuredClone(frame));
      socket.send(JSON.stringify(frame));
    },
  };
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    messages.push(message);
    return control.onMessage?.(message);
  };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  control.send({ action: "getConnectionId" });
  const connection = await waitFor(
    () => messages.find((message) => message.type === "connectionId"),
    `${page.label} 官方 lobby façade 未返回 connectionId`,
  );
  control.connection = connection;
  return control;
}

function createLiveLobbyUi(page, control) {
  const fixture = createLocalFrameFixture();
  page.multiplayerBackend.configureOfficialLobbyFrame(fixture.frame);
  const capability = readLocalFrameCapability(fixture.frame);
  const document = runLocalLobbyFrameDocument(fixture.frame);
  let outboundCursor = 0;
  let inboundCursor = 0;
  let pumping = false;
  const actions = [];
  const officialCountdownPostResults = [];
  const peerConnections = [];

  const postOfficialFrameMessage = (message) =>
    page.multiplayerBackend.postOfficialLobbyFrameMessage(
      fixture.frame,
      vmValue(page.context, message),
    );

  const handleOfficialFrameEvent = (event) => {
    const data = JSON.parse(JSON.stringify(event.data));
    if (data.id === "lobbiesListenerReady") {
      assert.equal(
        postOfficialFrameMessage({
          id: "sessionInformation",
          isCordova: false,
          devicePlatform: "",
          navigatorPlatform: "Win32",
          hasTouch: false,
        }),
        true,
      );
      return;
    }
    if (data.id === "joinLobby") {
      const session = page.window.playmesh.main.session.getCurrent();
      const player = page.window.playmesh.main.player.getCurrent();
      assert.equal(data.lobbyId, session.id);
      assert.equal(
        postOfficialFrameMessage({
          id: "lobbyJoined",
          lobbyId: session.id,
          playerId: player.id,
          playerToken: `parent-only-${page.label}`,
          connectionId: control.connection.data.connectionId,
          positionInLobby: page.playerNumber,
        }),
        true,
      );
      return;
    }
    if (data.id === "startGameCountdown") {
      control.send({
        action: "startGameCountdown",
        connectionType: "lobby",
      });
      return;
    }
    if (data.id === "joinGame") {
      control.send({ action: "joinGame", connectionType: "lobby" });
      return;
    }
    if (data.id === "leaveLobby") {
      assert.equal(postOfficialFrameMessage({ id: "lobbyLeft" }), true);
      return;
    }
    assert.notEqual(
      data.id,
      "startGame",
      "隐藏准备阶段不得要求 UI 再发送第二次 startGame",
    );
    throw new Error(`${page.label} 未处理的官方大厅事件: ${data.id}`);
  };

  const pump = () => {
    if (pumping) return;
    pumping = true;
    try {
      for (let pass = 0; pass < 32; pass += 1) {
        let progressed = false;
        while (inboundCursor < fixture.posted.length) {
          const entry = fixture.posted[inboundCursor++];
          document.dispatchFromParent(entry.message);
          progressed = true;
        }
        while (outboundCursor < document.outbound.length) {
          const entry = document.outbound[outboundCursor++];
          const message = JSON.parse(JSON.stringify(entry.message));
          actions.push(message);
          page.multiplayerBackend.handleOfficialLobbyFrameMessage(
            localFrameEvent(page, fixture, message),
            handleOfficialFrameEvent,
          );
          progressed = true;
        }
        if (!progressed) return;
      }
      throw new Error(`${page.label} 本地大厅消息泵未收敛`);
    } finally {
      pumping = false;
    }
  };

  const handleControlMessage = (message) => {
    if (message.type === "lobbyUpdated") {
      postOfficialFrameMessage({
        id: "lobbyUpdated",
        positionInLobby: message.data.positionInLobby,
      });
    } else if (message.type === "gameCountdownStarted") {
      officialCountdownPostResults.push(
        postOfficialFrameMessage({ id: "gameCountdownStarted" }),
      );
      if (page.window.playmesh.main.session.isAuthority()) {
        control.send({
          action: "sendPeerId",
          connectionType: "lobby",
          peerId: page.peer.id,
        });
      }
    } else if (
      message.type === "peerId" &&
      !page.window.playmesh.main.session.isAuthority()
    ) {
      const connection = page.observeConnection(
        page.peer.connect(message.data.peerId),
      );
      peerConnections.push(connection);
    }
    pump();
  };

  control.onMessage = handleControlMessage;
  pump();
  return {
    fixture,
    document,
    actions,
    officialCountdownPostResults,
    peerConnections,
    pump,
    click(id) {
      const before = actions.length;
      document.click(id);
      pump();
      return actions.slice(before);
    },
    frameEvents(event) {
      return fixture.posted
        .map((entry) => entry.message)
        .filter((message) => message.event === event);
    },
    close() {
      const closed = page.multiplayerBackend.notifyOfficialLobbyFrameClosed();
      control.onMessage = null;
      return closed;
    },
  };
}

function installOfficialLeaveGameLobby(page, lobbySocket) {
  const counters = {
    disconnectFromAllPeers: 0,
    clearAllMessagesTempData: 0,
  };
  page.window.__playmeshOfficialLobbySocket = lobbySocket;
  page.window.__playmeshOfficialLeaveDependencies = {
    logger: {
      info: (...args) => page.consoleEntries.push({ level: "info", args }),
    },
    disconnectFromAllPeers() {
      counters.disconnectFromAllPeers += 1;
      for (const connection of page.observedConnections) {
        if (!connection.__closed) connection.close();
      }
    },
    clearAllMessagesTempData() {
      counters.clearAllMessagesTempData += 1;
    },
  };
  const harnessSource = `(() => {
    const dependencies = globalThis.__playmeshOfficialLeaveDependencies;
    const logger = dependencies.logger;
    const gdjs = {
      multiplayerPeerJsHelper: {
        disconnectFromAllPeers: dependencies.disconnectFromAllPeers,
      },
      multiplayerMessageManager: {
        clearAllMessagesTempData: dependencies.clearAllMessagesTempData,
      },
      multiplayerTools: {},
    };
    let _websocket = globalThis.__playmeshOfficialLobbySocket;
    let _connectionId = 'official-e2e-connection';
    let playerNumber = 2;
    let hostPeerId = 'authority';
    let _lobbyId = 'official-e2e-lobby';
    let _hasLobbyGameJustEnded = false;
    let _isLobbyGameRunning = true;
    let _isReadyToSendOrReceiveGameUpdateMessages = true;
    let _lobbyHeartbeatIntervalFunction = null;
${officialHandleLeaveLobbySource}
${officialHandleLobbyGameEndedSource}
${officialLeaveGameLobbySource}
    gdjs.multiplayerTools.leaveGameLobby = leaveGameLobby;
    globalThis.gdjs = gdjs;
    globalThis.__playmeshOfficialLeaveSnapshot = () => ({
      websocketReleased: _websocket === null,
      connectionId: _connectionId,
      playerNumber,
      hostPeerId,
      lobbyId: _lobbyId,
      hasLobbyGameJustEnded: _hasLobbyGameJustEnded,
      isLobbyGameRunning: _isLobbyGameRunning,
      isReady: _isReadyToSendOrReceiveGameUpdateMessages,
    });
  })();`;
  vm.runInContext(harnessSource, page.context, {
    filename: `official-gdevelop-${lockedGDevelopVersion}-leave-harness.js`,
  });
  return {
    counters,
    async leave() {
      await vm.runInContext(
        "gdjs.multiplayerTools.leaveGameLobby()",
        page.context,
      );
      return JSON.parse(
        JSON.stringify(
          vm.runInContext(
            "__playmeshOfficialLeaveSnapshot()",
            page.context,
          ),
        ),
      );
    },
  };
}

const temporaryRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), "playmesh-gdevelop-core-e2e-"),
);
const executableName = process.platform === "win32"
  ? "playmesh-go-core-e2e.exe"
  : "playmesh-go-core-e2e";
const binaryPath = path.join(temporaryRoot, executableName);
let core = null;
const pages = [];

try {
  await runProcess("go", ["build", "-o", binaryPath, "."], {
    cwd: goCoreRoot,
  });
  core = await startGoCore(binaryPath);
  writeCleanupTrace({
    temporaryRoot,
    binaryPath,
    corePid: core.child.pid,
    baseUrl: core.baseUrl,
    cleanupComplete: false,
  });
  if (injectedFailureStage === "after-core-start") {
    throw new Error("注入失败：go-core 启动后验证清理路径");
  }
  const hostJoin = await createSession(core.baseUrl);
  const host = createPage({
    baseUrl: core.baseUrl,
    joined: hostJoin,
    label: "authority",
  });
  pages.push(host);
  await host.ready();

  const guestOneJoin = await joinSession(
    core.baseUrl,
    hostJoin.session.joinCode,
    "p_gdevelop-e2e-guest-1",
    "E2E Guest 1",
  );
  const guestOne = createPage({
    baseUrl: core.baseUrl,
    joined: guestOneJoin,
    label: "guest-1",
  });
  pages.push(guestOne);
  await guestOne.ready();

  const guestTwoJoin = await joinSession(
    core.baseUrl,
    hostJoin.session.joinCode,
    "p_gdevelop-e2e-guest-2",
    "E2E Guest 2",
  );
  const guestTwo = createPage({
    baseUrl: core.baseUrl,
    joined: guestTwoJoin,
    label: "guest-2",
  });
  pages.push(guestTwo);
  await guestTwo.ready();

  const dormantJoin = await joinSession(
    core.baseUrl,
    hostJoin.session.joinCode,
    "p_gdevelop-e2e-dormant",
    "E2E Dormant Target",
  );

  await waitFor(
    () => host.primaryAdapter.latestSession.players.length === 4,
    "Authority 未收到完整真实会话成员快照",
  );
  for (const page of pages) observePeer(page);

  assert.equal(host.peer.id, "authority");
  assert.equal(guestOne.peer.id, guestOneJoin.credential.player.id);
  assert.equal(host.playerNumber, 1);
  assert.equal(guestOne.playerNumber, 2);
  assert.equal(guestTwo.playerNumber, 3);

  const forgedStartControl = await openOfficialLobbyControl(guestOne);
  let forgedStartError = null;
  forgedStartControl.socket.onerror = error => {
    forgedStartError = error;
  };
  assert.throws(
    () =>
      forgedStartControl.socket.send(
        JSON.stringify({
          action: "startGame",
          connectionType: "lobby",
        }),
      ),
    error => error.code === "PLAYMESH_GDEVELOP_AUTHORITY_ONLY",
    "Guest 不得伪造官方 startGame action",
  );
  await waitFor(
    () => forgedStartError,
    "Guest 伪造开始游戏未进入官方 lobby socket onerror",
  );
  forgedStartControl.socket.close();

  const officialLobbyControls = await Promise.all(
    pages.map(page => openOfficialLobbyControl(page)),
  );
  let hostLobbyUi = createLiveLobbyUi(host, officialLobbyControls[0]);
  let guestOneLobbyUi = createLiveLobbyUi(guestOne, officialLobbyControls[1]);
  let guestTwoLobbyUi = createLiveLobbyUi(guestTwo, officialLobbyControls[2]);
  let liveLobbyUis = [hostLobbyUi, guestOneLobbyUi, guestTwoLobbyUi];
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return liveLobbyUis.every(
        (lobby) => lobby.document.elements.get("leave").hidden === false,
      );
    },
    "本地大厅 UI 未自动加入当前 Playmesh Session",
  );
  assert.equal(
    hostLobbyUi.document.elements.get("playerReady").hidden,
    true,
    "Host 不应显示玩家准备按钮",
  );
  assert.equal(hostLobbyUi.document.elements.get("start").hidden, false);
  assert.equal(
    hostLobbyUi.document.elements.get("start").disabled,
    true,
    "Guest 手动准备前 Host 不得开始游戏",
  );
  assert.equal(
    guestOneLobbyUi.document.elements.get("playerReady").hidden,
    false,
  );
  assert.equal(
    guestTwoLobbyUi.document.elements.get("playerReady").hidden,
    false,
  );

  const guestOneFirstReadyAction = guestOneLobbyUi
    .click("playerReady")
    .find((message) => message.action === "setReady");
  const guestTwoReadyAction = guestTwoLobbyUi
    .click("playerReady")
    .find((message) => message.action === "setReady");
  assert.equal(guestOneFirstReadyAction.payload.ready, true);
  assert.equal(guestTwoReadyAction.payload.ready, true);
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return [
        [guestOneLobbyUi, guestOneFirstReadyAction],
        [guestTwoLobbyUi, guestTwoReadyAction],
      ].every(([lobby, action]) =>
        lobby.frameEvents("operationSucceeded").some(
          (event) => event.payload.action === "setReady" &&
            event.payload.requestId === action.payload.requestId,
        )
      );
    },
    "Guest 手动 Ready 未收到 Authority ACK",
  );
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return liveLobbyUis.every(
        (lobby) =>
          lobby.document.elements.get("playerRow2").dataset.readiness ===
            "ready" &&
          lobby.document.elements.get("playerRow3").dataset.readiness ===
            "ready",
      );
    },
    "Authority readiness snapshot 未同步到全部大厅 UI",
  );

  const retainedLobbySlot = guestOne.playerNumber;
  assert.equal(guestOneLobbyUi.close(), true);
  await waitFor(
    () => {
      hostLobbyUi.pump();
      guestTwoLobbyUi.pump();
      return hostLobbyUi.document.elements.get("playerRow2").dataset.readiness ===
        "notReady";
    },
    "Guest 退出大厅页面后未向 Authority 取消准备",
  );
  assert.equal(
    guestOne.window.playmesh.main.session.getCurrent().state,
    "lobby",
  );
  assert.equal(
    guestOne.primaryAdapter.latestSession.players.find(
      (player) => player.id === guestOneJoin.credential.player.id,
    )?.connected,
    true,
    "退出大厅页面不得移除 Session 成员占位",
  );
  assert.equal(
    (await getLobby(host)).players.find(
      (player) => player.playerId === guestOneJoin.credential.player.id,
    )?.playerNumber,
    retainedLobbySlot,
    "退出大厅页面不得改变稳定玩家编号",
  );

  guestOneLobbyUi = createLiveLobbyUi(guestOne, officialLobbyControls[1]);
  liveLobbyUis = [hostLobbyUi, guestOneLobbyUi, guestTwoLobbyUi];
  await waitFor(
    () => {
      guestOneLobbyUi.pump();
      return !guestOneLobbyUi.document.elements.get("playerReady").hidden;
    },
    "Guest 重新打开大厅页面后未恢复手动准备入口",
  );
  const guestOneSecondReadyAction = guestOneLobbyUi
    .click("playerReady")
    .find((message) => message.action === "setReady");
  assert.equal(guestOneSecondReadyAction.payload.ready, true);
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return guestOneLobbyUi.frameEvents("operationSucceeded").some(
        (event) => event.payload.action === "setReady" &&
          event.payload.requestId === guestOneSecondReadyAction.payload.requestId,
      ) && !hostLobbyUi.document.elements.get("start").disabled;
    },
    "Guest 重新 Ready 后 Host 开始门禁未开放",
  );

  const startActions = hostLobbyUi
    .click("start")
    .filter((message) => message.action === "startGameCountdown");
  assert.equal(startActions.length, 1, "Host 只能提交一次开始意图");
  assert.equal(
    hostLobbyUi.actions.filter((message) => message.action === "startGame")
      .length,
    0,
    "UI 不得在 official preparation 后再次提交 startGame",
  );
  await waitFor(
    () =>
      officialLobbyControls.every(
        (control) =>
          control.messages.filter(
            (message) => message.type === "gameCountdownStarted",
          ).length === 1,
      ),
    "官方隐藏准备阶段未到达 Host/Guests",
  );
  await waitFor(
    () =>
      guestOne.connections.has("authority") &&
      guestTwo.connections.has("authority") &&
      host.connections.has(guestOneJoin.credential.player.id) &&
      host.connections.has(guestTwoJoin.credential.player.id),
    "官方准备阶段未建立 Host/Guest 逻辑连接",
  );
  assert.ok(
    liveLobbyUis.every((lobby) =>
      lobby.officialCountdownPostResults.every((result) => result === false)
    ),
    "隐藏准备不得向 Playmesh 大厅 UI 暴露倒计时事件",
  );
  assert.ok(
    pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "lobby",
    ),
    "PREPARED 门禁完成前 Session 必须保持 lobby",
  );
  assert.equal(host.primaryAdapter.sessionCommandCounts.start, 0);
  assert.ok(
    officialLobbyControls.every(
      (control) =>
        control.messages.filter((message) => message.type === "gameStarted")
          .length === 0,
    ),
    "PREPARED 门禁完成前不得发送 gameStarted",
  );

  officialLobbyControls[1].send({
    action: "updateConnection",
    connectionType: "lobby",
    status: "connected",
    peerId: guestOne.peer.id,
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(host.primaryAdapter.sessionCommandCounts.start, 0);
  assert.ok(
    pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "lobby",
    ),
  );

  officialLobbyControls[2].send({
    action: "updateConnection",
    connectionType: "lobby",
    status: "connected",
    peerId: guestTwo.peer.id,
  });
  await waitFor(
    () => host.primaryAdapter.sessionCommandCounts.start === 1,
    "全部 Guest PREPARED 后未调用唯一一次 main.session.start",
  );
  await waitFor(
    () => pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "running",
    ),
    "真实 Session 未在全部页面进入 running",
  );
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return officialLobbyControls.every(
        (control) =>
          control.messages.filter((message) => message.type === "gameStarted")
            .length === 1,
      );
    },
    "主机或客户端未恰好收到一次 GDevelop gameStarted 事件",
  );
  const retainedRunningConnections = [
    guestOne.connections.get("authority"),
    guestTwo.connections.get("authority"),
  ];
  for (const lobby of liveLobbyUis) assert.equal(lobby.close(), true);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(
    retainedRunningConnections.every(
      (connection) => connection?.peerConnection.connectionState === "connected",
    ),
    "running 清理大厅页面不得关闭已确认的 Guest 连接",
  );
  await waitFor(
    () =>
      host.connections.has(guestOneJoin.credential.player.id) &&
      host.connections.has(guestTwoJoin.credential.player.id),
    "running 清理大厅页面后 Host 连接被错误清除",
  );

  sendPeerMessage(guestOne, "authority", "#guest-real-sender", { value: 1 });
  const fromGuest = await waitForPeerMessage(host, "#guest-real-sender");
  assert.equal(fromGuest[0].sender, guestOneJoin.credential.player.id);

  assert.throws(
    () => guestOne.peer.connect(guestTwoJoin.credential.player.id),
    (error) => error.code === "PLAYMESH_GDEVELOP_INVALID_TOPOLOGY",
    "Guest 不得横向连接另一个 Guest",
  );

  assert.throws(
    () => host.peer.connect(dormantJoin.credential.player.id),
    (error) => error.code === "PLAYMESH_GDEVELOP_PEER_UNAVAILABLE",
    "离线目标必须在建立逻辑连接前被拒绝",
  );
  sendPeerMessage(
    host,
    guestOneJoin.credential.player.id,
    "#authority-best-effort",
    { tick: 7 },
  );
  sendPeerMessage(
    host,
    guestTwoJoin.credential.player.id,
    "#authority-best-effort",
    { tick: 7 },
  );
  await waitForPeerMessage(guestOne, "#authority-best-effort");
  await waitForPeerMessage(guestTwo, "#authority-best-effort");

  const retainedPrimary = guestOne.primaryAdapter.socket;
  const retainedBinary = guestOne.binarySockets().at(-1);
  const guestOneBinaryCount = guestOne.binarySockets().length;
  const retainedPlayerId = guestOne.window.playmesh.main.player.getCurrent().id;
  const retainedPlayerNumber = guestOne.playerNumber;
  const retainedChannelId = await requestCompatibilityChannelId(guestOne);
  const officialLobbyBeforeLeave = officialLobbyControls[1];
  let officialLobbyCloseCount = 0;
  officialLobbyBeforeLeave.socket.onclose = () => {
    officialLobbyCloseCount += 1;
  };
  const officialLeave = installOfficialLeaveGameLobby(
    guestOne,
    officialLobbyBeforeLeave.socket,
  );
  const officialLeaveSnapshot = await officialLeave.leave();
  await waitFor(
    () => !host.connections.has(guestOneJoin.credential.player.id),
    "官方 leaveGameLobby soft leave 后 Authority 仍保留旧逻辑连接",
  );
  await waitFor(
    () => officialLobbyCloseCount === 1,
    "官方 leaveGameLobby 未关闭 lobby 虚拟 WebSocket",
  );
  assert.deepEqual(
    officialLeaveSnapshot,
    {
      websocketReleased: true,
      connectionId: null,
      playerNumber: null,
      hostPeerId: null,
      lobbyId: null,
      hasLobbyGameJustEnded: true,
      isLobbyGameRunning: false,
      isReady: false,
    },
    "必须执行官方 leaveGameLobby 的 lobby/game 全部本地清理",
  );
  assert.equal(officialLeave.counters.disconnectFromAllPeers, 1);
  assert.equal(officialLeave.counters.clearAllMessagesTempData, 1);
  assert.equal(retainedPrimary.readyState, WebSocket.OPEN);
  assert.equal(retainedBinary.readyState, WebSocket.OPEN);
  assert.equal(
    guestOne.window.playmesh.main.session.getCurrent().state,
    "running",
  );

  const officialLobbyAfterLeave = await openOfficialLobbyControl(guestOne);
  assert.equal(
    officialLobbyAfterLeave.messages.filter(
      message => message.type === "gameCountdownStarted",
    ).length,
    0,
    "warm re-entry 不得产生已删除的倒计时事件",
  );
  assert.equal(
    officialLobbyAfterLeave.connection.data.connectionId,
    officialLobbyBeforeLeave.connection.data.connectionId,
    "warm re-entry 必须复用官方 lobby connection identity",
  );
  assert.equal(
    officialLobbyAfterLeave.connection.data.positionInLobby,
    retainedPlayerNumber,
  );
  assert.equal(
    guestOne.window.playmesh.main.player.getCurrent().id,
    retainedPlayerId,
  );
  assert.equal(guestOne.playerNumber, retainedPlayerNumber);
  assert.equal(
    await requestCompatibilityChannelId(guestOne),
    retainedChannelId,
    "warm re-entry 必须复用同一兼容层 Binary Channel",
  );
  await connectPeer(guestOne, "authority");
  await waitFor(
    () => host.connections.has(guestOneJoin.credential.player.id),
    "warm re-entry 后 Authority 未重建逻辑连接",
  );
  assert.equal(guestOne.binarySockets().length, guestOneBinaryCount);
  sendPeerMessage(
    host,
    guestOneJoin.credential.player.id,
    "#after-warm-reentry",
    { fresh: true },
  );
  const warmMessageCountBefore = guestOne.peerMessages.filter(
    (entry) => entry.message.messageName === "#after-warm-reentry",
  ).length;
  await waitForPeerMessage(
    guestOne,
    "#after-warm-reentry",
    warmMessageCountBefore + 1,
  );
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    guestOne.peerMessages.filter(
      (entry) => entry.message.messageName === "#after-warm-reentry",
    ).length,
    warmMessageCountBefore + 1,
    "warm re-entry 不得重复注册 Binary/DataConnection listener",
  );

  await reconnectBinary(guestOne);
  sendPeerMessage(
    guestOne,
    "authority",
    "#after-guest-binary-rejoin",
    { value: 2 },
  );
  const afterGuestReconnect = await waitForPeerMessage(
    host,
    "#after-guest-binary-rejoin",
  );
  assert.equal(afterGuestReconnect[0].sender, guestOneJoin.credential.player.id);

  await reconnectBinary(host);
  sendPeerMessage(
    host,
    guestTwoJoin.credential.player.id,
    "#after-authority-binary-rejoin",
    { value: 3 },
  );
  const afterAuthorityReconnect = await waitForPeerMessage(
    guestTwo,
    "#after-authority-binary-rejoin",
  );
  assert.equal(afterAuthorityReconnect[0].sender, "authority");

  const binarySocketsBeforeReset = pages.map((page) =>
    page.binarySockets().at(-1)
  );
  const playerNumbersBeforeReset = new Map(
    pages.map((page) => [
      page.window.playmesh.main.player.getCurrent().id,
      page.playerNumber,
    ]),
  );
  await requestJson(
    new URL(
      `v1/sessions/${encodeURIComponent(hostJoin.session.id)}/reset`,
      core.baseUrl,
    ),
    {
      method: "POST",
      headers: { Authorization: `Bearer ${hostJoin.credential.token}` },
    },
  );
  await waitFor(
    () => pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "lobby",
    ),
    "reset 后没有广播 lobby Session",
  );
  await waitFor(async () => {
    for (const page of pages) {
      const lobby = await getLobby(page);
      const playerId = page.window.playmesh.main.player.getCurrent().id;
      const record = lobby.players.find((player) => player.playerId === playerId);
      if (!record || record.playerNumber !== playerNumbersBeforeReset.get(playerId)) {
        return false;
      }
    }
    return true;
  }, "reset 后稳定玩家编号未在全部页面恢复");
  for (let index = 0; index < pages.length; index += 1) {
    assert.equal(
      pages[index].binarySockets().at(-1),
      binarySocketsBeforeReset[index],
      `${pages[index].label} reset 不得替换 Binary WebSocket`,
    );
  }

  const oldClosedLobbyMessageCount = officialLobbyBeforeLeave.messages.length;
  const resetLobbyControls = [
    officialLobbyControls[0],
    officialLobbyAfterLeave,
    officialLobbyControls[2],
  ];
  const countdownCountsBeforeResetStart = resetLobbyControls.map(
    (control) =>
      control.messages.filter(
        (message) => message.type === "gameCountdownStarted",
      ).length,
  );
  const gameStartedCountsBeforeResetStart = resetLobbyControls.map(
    (control) =>
      control.messages.filter((message) => message.type === "gameStarted")
        .length,
  );
  hostLobbyUi = createLiveLobbyUi(host, resetLobbyControls[0]);
  guestOneLobbyUi = createLiveLobbyUi(guestOne, resetLobbyControls[1]);
  guestTwoLobbyUi = createLiveLobbyUi(guestTwo, resetLobbyControls[2]);
  liveLobbyUis = [hostLobbyUi, guestOneLobbyUi, guestTwoLobbyUi];
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return liveLobbyUis.every(
        (lobby) => lobby.document.elements.get("leave").hidden === false,
      );
    },
    "reset 后本地大厅 UI 未重新加入当前 Session",
  );
  assert.ok(
    [guestOneLobbyUi, guestTwoLobbyUi].every(
      (lobby) =>
        lobby.actions.filter((message) => message.action === "setReady")
          .length === 0,
    ),
    "reset 后 Guest 不得自动准备",
  );
  const resetGuestReadyActions = [guestOneLobbyUi, guestTwoLobbyUi].map(
    (lobby) =>
      lobby
        .click("playerReady")
        .find((message) => message.action === "setReady"),
  );
  assert.ok(
    resetGuestReadyActions.every((message) => message?.payload.ready === true),
  );
  await waitFor(
    () => {
      liveLobbyUis.forEach((lobby) => lobby.pump());
      return !hostLobbyUi.document.elements.get("start").disabled &&
        resetGuestReadyActions.every((action, index) =>
          [guestOneLobbyUi, guestTwoLobbyUi][index]
            .frameEvents("operationSucceeded")
            .some(
              (event) => event.payload.action === "setReady" &&
                event.payload.requestId === action.payload.requestId,
            )
        );
    },
    "reset 后 Guest 手动准备未通过 Authority ACK/snapshot 门禁",
  );
  assert.equal(host.primaryAdapter.sessionCommandCounts.start, 1);
  assert.ok(
    pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "lobby",
    ),
    "reset 后 Host 再次确认开始前必须保持 lobby",
  );
  const resetStartActions = hostLobbyUi
    .click("start")
    .filter((message) => message.action === "startGameCountdown");
  assert.equal(resetStartActions.length, 1);
  assert.equal(
    hostLobbyUi.actions.filter((message) => message.action === "startGame")
      .length,
    0,
  );
  await waitFor(
    () =>
      resetLobbyControls.every(
        (control, index) =>
          control.messages.filter(
            (message) => message.type === "gameCountdownStarted",
          ).length === countdownCountsBeforeResetStart[index] + 1,
      ),
    "reset 后官方隐藏准备阶段未到达全部玩家",
  );
  await waitFor(
    () =>
      guestOne.connections.get("authority")?.peerConnection.connectionState ===
        "connected" &&
      guestTwo.connections.get("authority")?.peerConnection.connectionState ===
        "connected",
    "reset 后官方准备阶段未保留或恢复 Guest 连接",
  );
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    host.primaryAdapter.sessionCommandCounts.start,
    1,
    "soft-left Guest 尚未重新 updateConnection 时 reset 轮不得开始",
  );
  assert.ok(
    pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "lobby",
    ),
  );
  resetLobbyControls[1].send({
    action: "updateConnection",
    connectionType: "lobby",
    status: "connected",
    peerId: guestOne.peer.id,
  });
  await waitFor(
    () => host.primaryAdapter.sessionCommandCounts.start === 2,
    "reset 后保留连接与重建连接未全部 PREPARED，或未触发唯一一次新的 main.session.start",
  );
  await waitFor(
    () => pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "running",
    ),
    "reset 后 Session 未能在原 Binary Channel 上重新开始",
  );
  await waitFor(
    () =>
      resetLobbyControls.every(
        (control, index) =>
          control.messages.filter((message) => message.type === "gameStarted")
            .length === gameStartedCountsBeforeResetStart[index] + 1,
      ),
    "reset 后 Host/Guests 未各收到恰好一次新的 gameStarted",
  );
  assert.equal(
    officialLobbyBeforeLeave.messages.length,
    oldClosedLobbyMessageCount,
    "soft-left 后已关闭的官方 lobby socket 不得收到未来准备或开始事件",
  );
  for (const lobby of liveLobbyUis) assert.equal(lobby.close(), true);

  const lateJoinResponse = await joinSession(
    core.baseUrl,
    hostJoin.session.joinCode,
    "p_gdevelop-e2e-running-late",
    "E2E Running Late Join",
  );
  const lateJoiner = createPage({
    baseUrl: core.baseUrl,
    joined: lateJoinResponse,
    label: "running-late-join",
  });
  pages.push(lateJoiner);
  await lateJoiner.ready();
  observePeer(lateJoiner);
  assert.equal(lateJoiner.playerNumber, 5);
  assert.equal(
    lateJoiner.window.playmesh.main.session.getCurrent().state,
    "running",
  );
  const lateJoinControl = await openOfficialLobbyControl(lateJoiner);
  const lateJoinLobbyUi = createLiveLobbyUi(lateJoiner, lateJoinControl);
  await waitFor(
    () => {
      lateJoinLobbyUi.pump();
      return lateJoinLobbyUi.actions.filter(
        (message) => message.action === "joinGame",
      ).length === 1;
    },
    "running 中途加入者未由大厅 UI 自动提交 joinGame",
  );
  assert.equal(
    lateJoinLobbyUi.actions.filter((message) => message.action === "setReady")
      .length,
    0,
    "running 中途加入不得经过 Ready 流程",
  );
  await waitFor(
    () =>
      lateJoiner.connections.get("authority")?.peerConnection.connectionState ===
        "connected" &&
      host.connections.has(lateJoinResponse.credential.player.id),
    "running 中途加入者未直连 Authority",
  );
  assert.equal(
    lateJoinControl.messages.filter((message) => message.type === "gameStarted")
      .length,
    0,
    "中途加入连接未经官方 updateConnection 前不得进入游戏",
  );
  lateJoinControl.send({
    action: "updateConnection",
    connectionType: "lobby",
    status: "connected",
    peerId: lateJoiner.peer.id,
  });
  await waitFor(
    () => {
      lateJoinLobbyUi.pump();
      return lateJoinControl.messages.filter(
        (message) => message.type === "gameStarted",
      ).length === 1 && lateJoinLobbyUi.frameEvents("operationSucceeded").some(
        (event) => event.payload.action === "joinGame",
      );
    },
    "running 中途加入者未自动进入已开始的游戏",
  );
  const lateJoinConnection = lateJoiner.connections.get("authority");
  assert.equal(lateJoinLobbyUi.close(), true);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    lateJoinConnection.peerConnection.connectionState,
    "connected",
    "running 中途加入后的大厅清理不得关闭游戏连接",
  );
  await host.multiplayerBackend.request(
    "endGame",
    vmValue(host.context, {
      gameId: "gdevelop-e2e-official-project",
      lobbyId: hostJoin.session.id,
    }),
  );
  await waitFor(
    () => pages.every(
      (page) => page.window.playmesh.main.session.getCurrent().state === "stopped",
    ),
    "finish 后没有广播 stopped Session",
  );

  console.log(
    "GDevelop private facade + real Game SDK/go-core multiplayer E2E passed " +
      "(stable numbers, sender alias, star boundary, target failure, soft leave/" +
      "warm re-entry, manual ready/two-phase start, Binary re-JOIN, reset retention, " +
      "running late join and Authority finish).",
  );

} catch (error) {
  console.error("GDevelop E2E diagnostics", JSON.stringify(
    pages.map((page) => ({
      label: page.label,
      logs: page.consoleEntries.slice(-20).map((entry) => ({
        level: entry.level,
        args: entry.args.map((value) =>
          value instanceof Error ? `${value.name}: ${value.message}` : value
        ),
      })),
      session: page.primaryAdapter.latestSession,
    })),
  ));
  throw error;
} finally {
  for (const page of pages.reverse()) {
    try {
      await page.dispose();
    } catch (_) {}
  }
  try {
    if (core) await core.stop();
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
    writeCleanupTrace({
      cleanupComplete: true,
      temporaryRootExistsAfterCleanup: fs.existsSync(temporaryRoot),
      coreExitCode: core?.child.exitCode ?? null,
      coreSignalCode: core?.child.signalCode ?? null,
    });
  }
}
