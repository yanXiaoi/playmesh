part of '../../sdk_feature_registry.dart';

/// 当前客户端的性能观测完全保存在 App SDK 页面内。
///
/// Game SDK 只通过私有接口提供受控 Session ping/pong 的原始结果；FPS、RTT
/// 平滑、订阅和覆盖层渲染均不经过 Dart Bridge。
const appPerformanceSdkSource = SdkSourceFragment(
  id: 'app.performance',
  target: SdkSourceTarget.app,
  order: 24,
  typeScript: r'''
  let appPerformanceMultiplayer = false;
  let appPerformanceFps = null;
  let appPerformanceFrameCount = 0;
  let appPerformanceWindowStartedAt = null;
  let appPerformanceLatency = null;
  let appPerformanceLatencyDiagnostics = null;
  let appPerformanceLatencyTimer = null;
  let appPerformanceProbeSequence = 0;
  let appPerformanceSendLatencyProbe = null;
  const appPerformanceFpsListeners = new Set();
  const appPerformanceLatencyListeners = new Set();

  function emitAppPerformance(listeners, value) {
    for (const listener of [...listeners]) listener(value);
  }

  function refreshAppPerformanceUi() {
    refreshAppUiPerformance();
  }

  function configureAppRuntimePerformance(context) {
    const multiplayer = context?.multiplayer === true;
    appPerformanceMultiplayer = multiplayer;
    appPerformanceSendLatencyProbe =
      typeof context?.sendLatencyProbe === "function"
        ? context.sendLatencyProbe
        : null;
    if (!multiplayer || !appPerformanceSendLatencyProbe) {
      stopAppRuntimeLatencyProbes();
      resetAppRuntimeLatency();
    } else if (!appPerformanceLatencyTimer) {
      sendAppRuntimeLatencyProbe();
      appPerformanceLatencyTimer = global.setInterval(
        sendAppRuntimeLatencyProbe,
        3000,
      );
      appPerformanceLatencyTimer?.unref?.();
    }
    refreshAppPerformanceUi();
  }

  function sendAppRuntimeLatencyProbe() {
    if (!appPerformanceMultiplayer || !appPerformanceSendLatencyProbe) return;
    const clientSentAt = Date.now();
    const payload = {
      probeId:
        `latency-${clientSentAt}-${++appPerformanceProbeSequence}`,
      clientSentAt,
    };
    try {
      Promise.resolve(appPerformanceSendLatencyProbe(payload)).catch(() => {});
    } catch (_) {
      // 单次探测失败不得中断游戏或本地性能浮层。
    }
  }

  function stopAppRuntimeLatencyProbes() {
    if (appPerformanceLatencyTimer) {
      global.clearInterval(appPerformanceLatencyTimer);
    }
    appPerformanceLatencyTimer = null;
    appPerformanceSendLatencyProbe = null;
  }

  function resetAppRuntimeLatency() {
    appPerformanceLatency = null;
    appPerformanceLatencyDiagnostics = null;
    emitAppPerformance(appPerformanceLatencyListeners, null);
    refreshAppPerformanceUi();
  }

  function recordAppRuntimeLatencyPong(payload) {
    const receivedAt = Date.now();
    const sentAt = Number(payload?.clientSentAt);
    if (!Number.isFinite(sentAt) || sentAt > receivedAt) return;
    if (payload.authorityAvailable !== true) {
      appPerformanceLatency = null;
      appPerformanceLatencyDiagnostics = {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: false,
      };
    } else {
      const rawRttMs = Math.max(0, receivedAt - sentAt);
      const smoothed = appPerformanceLatency == null
        ? rawRttMs
        : (appPerformanceLatency * 0.75) + (rawRttMs * 0.25);
      appPerformanceLatency = Math.max(0, Math.round(smoothed));
      appPerformanceLatencyDiagnostics = {
        probeId: payload.probeId || null,
        clientSentAt: sentAt,
        serverReceivedAt: payload.serverReceivedAt || null,
        serverSentAt: payload.serverSentAt || null,
        receivedAt,
        authorityAvailable: true,
        rawRttMs,
      };
    }
    emitAppPerformance(
      appPerformanceLatencyListeners,
      appPerformanceLatency,
    );
    refreshAppPerformanceUi();
  }

  function reportAppPerformanceFrame(
    timestamp = global.performance?.now?.() || Date.now(),
  ) {
    if (typeof timestamp !== "number" || !Number.isFinite(timestamp)) {
      throw new TypeError("timestamp 必须是有限数值");
    }
    appPerformanceFrameCount += 1;
    appPerformanceWindowStartedAt ??= timestamp;
    const elapsed = timestamp - appPerformanceWindowStartedAt;
    if (elapsed < 1000) return appPerformanceFps;
    appPerformanceFps = Math.max(
      0,
      Math.round((appPerformanceFrameCount * 1000) / elapsed),
    );
    appPerformanceFrameCount = 0;
    appPerformanceWindowStartedAt = timestamp;
    emitAppPerformance(appPerformanceFpsListeners, appPerformanceFps);
    refreshAppPerformanceUi();
    return appPerformanceFps;
  }

  function subscribeAppPerformance(listeners, callback, currentValue) {
    if (typeof callback !== "function") {
      throw new TypeError("callback 必须是函数");
    }
    listeners.add(callback);
    callback(currentValue);
    return function unsubscribe() {
      listeners.delete(callback);
    };
  }

  function appPerformanceSnapshot() {
    return {
      fps: appPerformanceFps,
      latency: appPerformanceLatency,
      multiplayer: appPerformanceMultiplayer,
    };
  }

''',
);
