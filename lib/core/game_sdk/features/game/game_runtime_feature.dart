part of '../../sdk_feature_registry.dart';

const gameRuntimeSdkSource = SdkSourceFragment(
  id: 'game.runtime',
  target: SdkSourceTarget.game,
  order: 60,
  typeScript: r'''  function receive(rawMessage) {
    const message = typeof rawMessage === "string" ? JSON.parse(rawMessage) : rawMessage;
    if (!message || typeof message !== "object") return;
    if (message.type === "performance.visibility") {
      performanceVisible = message.visible !== false;
      void renderPerformanceUi();
      return;
    }
    if (message.type === "sdk.bootstrap") {
      const previousSessionId = bootstrap?.session?.id;
      const publicBootstrap = { ...message };
      if (message.binaryTransport?.url) {
        binaryTransportConfig = { url: String(message.binaryTransport.url) };
      }
      delete publicBootstrap.binaryTransport;
      bootstrap = publicBootstrap;
      seedPlayerConnections(bootstrap.session);
      if (previousSessionId !== bootstrap.session?.id) currentSyncSnapshot = null;
      emit(sessionListeners, bootstrap.session);
      emit(lifecycleListeners, { state: "ready" });
      const request = pending.get(message.requestId);
      if (request) global.clearTimeout(request.timer);
      request?.resolve(publicBootstrap);
      pending.delete(message.requestId);
      global.console?.info?.("Playmesh Game SDK 就绪", {
        mode: bootstrap.session ? "multiplayer" : "solo",
      });
      void renderPerformanceUi();
      startLatencyProbes();
      if (bootstrap.session && !bootstrap.isAuthority) {
        void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
      }
      return;
    }
    if (message.type === "command.result" || message.type === "command.error") {
      const request = pending.get(message.requestId);
      if (request) {
        global.clearTimeout(request.timer);
        message.type === "command.result"
          ? request.resolve(message.result)
          : request.reject(new Error(message.error));
        pending.delete(message.requestId);
      }
      return;
    }
    if (message.type === "transport.error" || message.type === "transport.closed") {
      global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      closeBinaryTransport("主会话连接已关闭");
      stopLatencyProbes();
      setLatency(null);
      emit(lifecycleListeners, {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      if (browserConnectionConfig && !runtimeExited) {
        scheduleBrowserReconnect();
      }
      return;
    }
    if (message.type === "lifecycle.event") {
      const event = { state: message.event };
      emit(lifecycleListeners, event);
      const listeners = message.event === "pause"
        ? pauseListeners
        : message.event === "resume"
          ? resumeListeners
          : exitListeners;
      Promise.allSettled([...listeners].map((handler) => handler(event)))
        .then(() => {
          if (message.event === "exit") {
            markRuntimeExited("游戏运行时已退出");
          }
          if (!global.__PLAYMESH_BROWSER__) {
            return post("lifecycle.complete", {
              lifecycleRequestId: message.requestId,
            });
          }
        });
      return;
    }
    if (message.type !== "transport.message") {
      return;
    }
    const transport = message.message;
    if (transport.type === "transport.status") {
      const details = {
        attempt: transport.attempt,
        error: transport.error,
      };
      if (transport.state === "reconnected") {
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", details);
      } else if (transport.state === "reconnecting") {
        global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", details);
      } else {
        global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", details);
      }
    } else if (transport.type === "session.state") {
      emitPlayerConnectionChanges(bootstrap.session, transport.session);
      bootstrap.session = transport.session;
      emit(sessionListeners, transport.session);
      void renderPerformanceUi();
      startLatencyProbes();
    } else if (transport.type === "game.message") {
      const storageResponse = transport.payload?.__playmeshStorageResponse;
      if (storageResponse) {
        settleBrowserStorage(storageResponse);
      } else {
        const snapshot = transport.payload?.__playmeshSyncSnapshot;
        if (snapshot) applySyncSnapshot(snapshot);
        else emit(messageListeners, transport.payload);
      }
    } else if (transport.type === "session.pong") {
      handleLatencyPong(transport.payload);
    } else if (transport.type === "authority.ping") {
      post("performance.pong", transport.payload, {
        targetPlayerId: transport.senderPlayerId,
      }).catch(() => {});
    } else if (transport.type === "authority.action") {
      dispatchAuthorityAction(transport).catch((error) => {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      });
    }
  }

  async function connectBrowser(config) {
    if (config.mode === "solo") {
      bootstrap = {
        type: "sdk.bootstrap",
        sdkVersion: PLAYMESH_SDK_VERSION,
        isAuthority: false,
        player: null,
        session: null,
      };
      emit(lifecycleListeners, { state: "ready" });
      void renderPerformanceUi();
      return bootstrap;
    }
    const appIdentity = appSdk.isAvailable()
      ? appSdk.identity.getCurrent()
      : null;
    const preferredNickname = appIdentity?.nickname || config.nickname;
    const nickname = preferredNickname
      ? validateNickname(preferredNickname, false)
      : await resolveBrowserNickname();
    if (!appIdentity && config.nickname) writeBrowserNickname(nickname);
    const playerId = appIdentity?.userId || resolveBrowserPlayerId();
    browserConnectionConfig = {
      ...config,
      nickname,
      playerId,
    };
    const joined = await joinBrowserWithRetry(browserConnectionConfig);
    applyBrowserJoin(config, joined);
    try {
      await connectBrowserSocket(config, joined);
    } catch (error) {
      global.console?.warn?.("Playmesh 主会话 WebSocket 首次连接失败，将开始重连", {
        error: error?.message || String(error),
      });
      browserReconnectOperation = reconnectBrowserSocket()
        .finally(() => {
          browserReconnectOperation = null;
          if (!runtimeExited &&
              browserConnectionConfig &&
              browserSocket?.readyState !== global.WebSocket.OPEN) {
            scheduleBrowserReconnect();
          }
        });
      await browserReconnectOperation;
    }
    emit(sessionListeners, bootstrap.session);
    emit(lifecycleListeners, { state: "ready" });
    mountBrowserNicknameControl().catch(() => {});
    void renderPerformanceUi();
    startLatencyProbes();
    void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
    return bootstrap;
  }

  function applyBrowserJoin(config, joined) {
    browserCredential = joined.credential;
    const core = new URL(config.coreBase);
    const binarySocketUrl = new URL(joined.binaryWebSocketPath, core);
    binarySocketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    binarySocketUrl.searchParams.set("token", joined.credential.token);
    binaryTransportConfig = { url: binarySocketUrl.toString() };
    if (joined.credential.reconnected) {
      previouslyConnectedPlayerIds.add(joined.credential.player.id);
    }
    // The Core may publish the connected snapshot as soon as the socket opens.
    // Seed bootstrap first so that an early session.state can update it safely.
    bootstrap = {
      type: "sdk.bootstrap",
      sdkVersion: PLAYMESH_SDK_VERSION,
      isAuthority: false,
      player: joined.credential.player,
      session: joined.session,
    };
  }

  async function joinBrowserWithRetry(config) {
    const attempts = 30;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await joinBrowser(config);
      } catch (error) {
        if (!["session_full", "player_connected"].includes(error.code) || attempt === attempts) throw error;
        await new Promise((resolve) => global.setTimeout(resolve, 200));
      }
    }
  }

  async function joinBrowser(config) {
    const response = await fetch(new URL("v1/sessions/join", config.coreBase), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        joinCode: config.joinCode,
        nickname: config.nickname,
        shareToken: config.shareToken,
        playerId: config.playerId,
        source: config.playerSource || (appSdk.isAvailable() ? "lan_app" : "lan_html"),
      }),
    });
    const joined = await response.json();
    if (!response.ok) {
      const error = new Error(joined.error?.message || "加入对局失败");
      error.code = joined.error?.code;
      throw error;
    }
    return joined;
  }

  async function connectBrowserSocket(config, joined) {
    const core = new URL(config.coreBase);
    const socketUrl = new URL(joined.webSocketPath, core);
    socketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    socketUrl.searchParams.set("token", joined.credential.token);
    const socket = new WebSocket(socketUrl);
    browserSocket = socket;
    let opened = false;
    // Subscribe before awaiting open so the initial connected snapshot cannot
    // pass between the open event and listener registration.
    socket.addEventListener("message", (event) => {
      receive({ type: "transport.message", message: JSON.parse(event.data) });
    });
    socket.addEventListener("close", (event) => {
      if (browserSocket !== socket) return;
      browserSocket = null;
      if (opened) {
        receive({
          type: "transport.closed",
          error: event?.reason || (event?.code ? `close code ${event.code}` : undefined),
        });
      }
    });
    try {
      await new Promise((resolve, reject) => {
        socket.addEventListener("open", () => {
          opened = true;
          resolve();
        }, { once: true });
        socket.addEventListener(
          "error",
          () => reject(new Error("无法连接主机会话")),
          { once: true },
        );
        socket.addEventListener(
          "close",
          () => {
            if (!opened) reject(new Error("主会话 WebSocket 在连接完成前关闭"));
          },
          { once: true },
        );
      });
    } catch (error) {
      if (browserSocket === socket) browserSocket = null;
      if (socket.readyState < global.WebSocket.CLOSING) socket.close();
      throw error;
    }
  }

  function scheduleBrowserReconnect() {
    if (runtimeExited || !browserConnectionConfig || browserReconnectOperation) return;
    browserReconnectOperation = reconnectBrowserSocket()
      .finally(() => {
        browserReconnectOperation = null;
        if (!runtimeExited &&
            browserConnectionConfig &&
            browserSocket?.readyState !== global.WebSocket.OPEN) {
          scheduleBrowserReconnect();
        }
      });
    void browserReconnectOperation.catch(() => {});
  }

  async function reconnectBrowserSocket() {
    let attempt = 0;
    while (!runtimeExited && browserConnectionConfig) {
      attempt += 1;
      await waitForReconnect(attempt);
      global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", { attempt });
      try {
        const previousSession = bootstrap?.session;
        const joined = await joinBrowser(browserConnectionConfig);
        applyBrowserJoin(browserConnectionConfig, joined);
        await connectBrowserSocket(browserConnectionConfig, joined);
        emitPlayerConnectionChanges(previousSession, bootstrap.session);
        emit(sessionListeners, bootstrap.session);
        startLatencyProbes();
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", { attempt });
        if (binaryReconnectWanted) {
          void ensureBinarySocket().catch(() => {});
        }
        if (!bootstrap.isAuthority) {
          void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
        }
        return browserSocket;
      } catch (error) {
        if (runtimeExited) break;
        global.console?.warn?.("Playmesh 主会话 WebSocket 重连失败，将继续重试", {
          attempt,
          error: error?.message || String(error),
          retryInMs: reconnectDelay(attempt + 1),
        });
      }
    }
    throw new Error("游戏页面已退出，停止主会话 WebSocket 重连");
  }

  const emptyAppSdk = {
    version: "2.0.0-empty",
    ready: Promise.resolve({
      available: false,
      identity: null,
      device: { platform: "browser", capabilities: [] },
    }),
    isAvailable() { return false; },
    __requestExit() { return Promise.resolve(); },
    __confirmCapabilities() { return Promise.resolve(); },
    identity: { getCurrent() { return null; } },
    capabilities: {
      getRegistry() { return []; },
      getAvailable() { return []; },
      getDeclared() { return []; },
      create() { return Promise.reject(new Error("当前浏览器没有 Playmesh App 能力插件宿主")); },
    },
    device: {
      getPlatform() { return "browser"; },
      setFullscreen() { return Promise.reject(new Error("请使用浏览器 Fullscreen API")); },
      onInput() { return function unsubscribe() {}; },
    },
  };
  const appSdk = global.playmeshApp || emptyAppSdk;

  function normalizeCapabilityList(value) {
    if (!Array.isArray(value)) return [];
    return [...new Set(value.filter((item) => typeof item === "string" && item.length > 0))];
  }

  function capabilityConsentContext(appBootstrap) {
    const browserConfig = global.__PLAYMESH_BROWSER__;
    const declaredForCurrentPage = browserConfig
      ? browserConfig.requiredCapabilities
      : appSdk.isAvailable()
        ? appSdk.capabilities.getDeclared?.()
        : appBootstrap?.device?.declaredCapabilities ??
          appBootstrap?.game?.requiredCapabilities;
    const required = normalizeCapabilityList(declaredForCurrentPage);
    const available = normalizeCapabilityList(
      appSdk.isAvailable()
        ? appBootstrap?.device?.capabilities || appSdk.capabilities.getAvailable()
        : browserConfig?.availableCapabilities,
    );
    const definitions = Array.isArray(browserConfig?.capabilityRegistry)
      ? browserConfig.capabilityRegistry
      : Array.isArray(appBootstrap?.capabilityRegistry)
        ? appBootstrap.capabilityRegistry
        : [];
    return {
      gameName: browserConfig?.gameName || appBootstrap?.game?.name || "当前游戏",
      required,
      available: new Set(available),
      definitions: new Map(definitions.map((definition) => [definition.code, definition])),
    };
  }

  async function requestCapabilityConsent(appBootstrap) {
    const context = capabilityConsentContext(appBootstrap);
    if (context.required.length === 0) return;
    const document = global.document;
    if (!document) throw new Error("当前页面无法显示游戏能力确认");
    if (!document.body) {
      await new Promise((resolve) => document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    capabilityConsentUi?.host.remove();
    const host = document.createElement("div");
    host.id = "playmesh-capability-consent";
    const root = host.attachShadow({ mode: "closed" });
    const rows = context.required.map((capability) => {
      const definition = context.definitions.get(capability);
      const label = definition?.name || capability;
      const description = definition?.description
        ? `<em>${escapeCapabilityHtml(definition.description)}</em>`
        : "";
      const unsupported = context.available.has(capability)
        ? ""
        : '<span class="unsupported">（本平台暂不支持）</span>';
      return `<li><span><strong>${escapeCapabilityHtml(label)}</strong>${description}<small>${escapeCapabilityHtml(capability)}</small></span>${unsupported}</li>`;
    }).join("");
    root.innerHTML = `<style>
      :host{all:initial;font-family:system-ui,"Microsoft YaHei",sans-serif;letter-spacing:0}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;box-sizing:border-box;padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));background:#050b12e8;color:#f8fafc}
      .card{box-sizing:border-box;display:flex;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);width:min(100%,460px);padding:26px;flex-direction:column;overflow:hidden;border:1px solid #ffffff24;border-radius:22px;background:linear-gradient(155deg,#14212d,#101522 65%,#17132a);box-shadow:0 28px 80px #000a}
      .content{min-height:0;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable;-webkit-overflow-scrolling:touch}
      h2{margin:0;font-size:25px;line-height:1.3}p{margin:10px 0 18px;color:#cbd5e1;font-size:14px;line-height:1.7}
      ul{display:grid;gap:10px;margin:0;padding:0;list-style:none}li{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:13px 14px;border:1px solid #ffffff18;border-radius:14px;background:#ffffff0a}
      strong{display:block;font-size:15px}em{display:block;margin-top:4px;color:#cbd5e1;font:normal 12px/1.5 system-ui}small{display:block;margin-top:4px;color:#94a3b8;font-size:11px}.unsupported{flex:none;color:#fbbf24;font-size:12px}
      .actions{display:flex;flex:none;gap:10px;margin-top:18px}.actions button{min-height:46px;flex:1;border-radius:13px;font:700 14px/1 system-ui;cursor:pointer;touch-action:manipulation}
      .deny{border:1px solid #ffffff30;background:#ffffff0b;color:#e2e8f0}.allow{border:0;background:linear-gradient(135deg,#10b981,#7c3aed);color:#fff;box-shadow:0 10px 26px #10b9812d}
      @media (max-height:440px),(max-width:420px){.overlay{padding:10px}.card{max-height:calc(100vh - 20px);max-height:calc(100dvh - 20px);padding:16px;border-radius:17px}h2{font-size:20px}p{margin:6px 0 10px;line-height:1.45}ul{gap:7px}li{padding:9px 10px}.actions{margin-top:10px}.actions button{min-height:42px}}
    </style><div class="overlay" role="dialog" aria-modal="true" aria-labelledby="capability-title"><div class="card"><div class="content"><h2 id="capability-title">${escapeCapabilityHtml(context.gameName)}需要以下能力</h2><p>每次进入游戏都需要重新确认。标记为暂不支持的能力不会阻止游戏继续运行。</p><ul>${rows}</ul></div><div class="actions"><button class="deny" type="button">拒绝并退出</button><button class="allow" type="button">同意并进入</button></div></div></div>`;
    document.body.appendChild(host);
    capabilityConsentUi = { host };
    const decision = await new Promise((resolve) => {
      root.querySelector(".allow").addEventListener("click", () => resolve("allow"), { once: true });
      root.querySelector(".deny").addEventListener("click", () => resolve("deny"), { once: true });
    });
    if (decision === "allow") {
      if (appSdk.isAvailable() && typeof appSdk.__confirmCapabilities === "function") {
        await appSdk.__confirmCapabilities();
      }
      host.remove();
      capabilityConsentUi = null;
      return;
    }
    root.querySelector(".actions").remove();
    root.querySelector("p").textContent = "你已拒绝本次能力请求，游戏不会启动。";
    const error = new Error("用户拒绝了当前游戏的能力请求");
    error.code = "capability_denied";
    if (appSdk.isAvailable() && typeof appSdk.__requestExit === "function") {
      await appSdk.__requestExit().catch(() => {});
    } else if (global.history?.length > 1) {
      global.setTimeout(() => global.history.back(), 0);
    }
    throw error;
  }

  function escapeCapabilityHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

''',
);
