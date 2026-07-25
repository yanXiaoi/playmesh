part of '../../sdk_feature_registry.dart';

const gamePerformanceSdkSource = SdkSourceFragment(
  id: 'game.performance',
  target: SdkSourceTarget.game,
  order: 50,
  typeScript: r'''  function setLatency(value, diagnostics = null) {
    currentLatency = typeof value === "number" && Number.isFinite(value)
      ? Math.max(0, Math.round(value))
      : null;
    latencyDiagnostics = diagnostics;
    emit(latencyListeners, currentLatency);
    void renderPerformanceUi();
    post("performance.latency", {
      latencyMs: currentLatency,
      diagnostics: latencyDiagnostics,
    }).catch(() => {});
  }

  function sendLatencyProbe() {
    if (!bootstrap?.session) return;
    const clientSentAt = Date.now();
    post("performance.ping", {
      probeId: `latency-${clientSentAt}-${++latencyProbeSequence}`,
      clientSentAt,
    }).catch(() => {});
  }

  function startLatencyProbes() {
    if (!bootstrap?.session) return;
    if (latencyTimer) return;
    sendLatencyProbe();
    latencyTimer = global.setInterval(sendLatencyProbe, 3000);
    latencyTimer?.unref?.();
  }

  function stopLatencyProbes() {
    if (latencyTimer) global.clearInterval(latencyTimer);
    latencyTimer = null;
  }

  function handleLatencyPong(payload) {
    const receivedAt = Date.now();
    const sentAt = Number(payload?.clientSentAt);
    if (!Number.isFinite(sentAt) || sentAt > receivedAt) return;
    if (payload.authorityAvailable !== true) {
      setLatency(null, {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: false,
      });
      return;
    }
    const rtt = Math.max(0, receivedAt - sentAt);
    const smoothed = currentLatency == null ? rtt : (currentLatency * 0.75) + (rtt * 0.25);
    setLatency(smoothed, {
      probeId: payload.probeId || null,
      clientSentAt: sentAt,
      serverReceivedAt: payload.serverReceivedAt || null,
      serverSentAt: payload.serverSentAt || null,
      receivedAt,
      authorityAvailable: true,
      rawRttMs: rtt,
    });
  }

  async function ensurePerformanceUi() {
    if (global.__PLAYMESH_BROWSER__ && !appSdk.isAvailable()) {
      return ensureBrowserNicknameUi();
    }
    if (performanceUi) return performanceUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    const host = global.document.createElement("div");
    host.id = "playmesh-performance";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;letter-spacing:0}
      .panel{position:fixed;right:12px;top:12px;z-index:2147483646;display:flex;gap:10px;padding:7px 9px;border:1px solid #ffffff30;border-radius:7px;background:#111827d9;color:#f9fafb;box-shadow:0 3px 12px #0004;font-size:12px;font-weight:700;line-height:1}
      .panel[hidden],.latency[hidden]{display:none}
    </style><div class="panel"><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>`;
    global.document.body.appendChild(host);
    performanceUi = {
      panel: root.querySelector(".panel"),
      fps: root.querySelector(".fps"),
      latency: root.querySelector(".latency"),
    };
    return performanceUi;
  }

  async function renderPerformanceUi() {
    const ui = await ensurePerformanceUi();
    if (!ui) return;
    ui.panel.hidden = !performanceVisible;
    ui.fps.textContent = currentFps == null ? "-- FPS" : `${currentFps} FPS`;
    const multiplayer = Boolean(bootstrap?.session);
    ui.latency.hidden = !multiplayer;
    ui.latency.textContent = currentLatency == null ? "-- ms" : `${currentLatency} ms`;
    if (ui.performanceButton) {
      ui.performanceButton.classList.toggle("active", performanceVisible);
      ui.performanceButton.setAttribute("aria-pressed", String(performanceVisible));
    }
  }

''',
);

class _GamePerformanceFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gamePerformanceSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'performance.fps',
    'performance.ping',
    'performance.pong',
    'performance.latency',
  };

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    switch (command.name) {
      case 'performance.fps':
        final fps = command.payload['fps'];
        if (fps is! num || !fps.isFinite || fps < 0) {
          throw const FormatException('fps 必须是非负有限数值');
        }
        context.emitFps(fps.toDouble());
        return const SdkCommandResult();
      case 'performance.latency':
        final latency = command.payload['latencyMs'];
        if (latency != null &&
            (latency is! num || !latency.isFinite || latency < 0)) {
          throw const FormatException('latencyMs 必须为空或非负有限数值');
        }
        context.emitLatency((latency as num?)?.toDouble());
        return const SdkCommandResult();
      case 'performance.ping':
        final connection = context.connection;
        if (connection == null) {
          throw const FormatException('单机模式不支持 performance.ping');
        }
        connection.submitLatencyProbe(command.payload);
        return const SdkCommandResult();
      case 'performance.pong':
        final connection = context.connection;
        if (connection == null) {
          throw const FormatException('单机模式不支持 performance.pong');
        }
        connection.submitLatencyResult(
          targetPlayerId: sdkRequiredString(command.raw, 'targetPlayerId'),
          probe: command.payload,
        );
        return const SdkCommandResult();
    }
    throw StateError('未注册的性能命令: ${command.name}');
  }
}
