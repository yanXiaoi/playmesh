part of '../../sdk_feature_registry.dart';

const appUiSdkSource = SdkSourceFragment(
  id: 'app.ui',
  target: SdkSourceTarget.app,
  order: 25,
  typeScript: r'''
  let appUiReturnFocus = null;
  let appUiFocusCapturePending = false;
  let appFallbackUi = null;
  let appUiConfiguration = null;
  let appUiRuntimeAdapter = null;
  let appUiKeyboardInstalled = false;
  let appUiTogglePending = false;
  let appUiConsoleCaptureInstalled = false;
  let appUiPerformanceVisible = false;
  let appUiRenderTimer = null;
  const appUiConsoleLogs = [];
  const APP_UI_LOG_LIMIT = 500;
  const initialAppUiOptions =
    global.__PLAYMESH_APP_OPTIONS__ &&
    typeof global.__PLAYMESH_APP_OPTIONS__ === "object"
      ? global.__PLAYMESH_APP_OPTIONS__
      : {};
  const appUiOptions = {
    fallbackUi: initialAppUiOptions.fallbackUi !== false,
    floatingButton: initialAppUiOptions.floatingButton !== false,
  };

  function appUiError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function configureAppUi(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("Playmesh App SDK 配置必须是对象");
    }
    for (const key of ["fallbackUi", "floatingButton"]) {
      if (options[key] !== undefined && typeof options[key] !== "boolean") {
        throw new TypeError(`${key} 必须是布尔值`);
      }
    }
    const previousFloatingButton = appUiOptions.floatingButton;
    if (options.fallbackUi !== undefined) {
      appUiOptions.fallbackUi = options.fallbackUi;
    }
    if (options.floatingButton !== undefined) {
      appUiOptions.floatingButton = options.floatingButton;
    }
    if (!appUiOptions.fallbackUi) {
      if (appUiRenderTimer !== null) {
        global.clearTimeout?.(appUiRenderTimer);
        appUiRenderTimer = null;
      }
      appFallbackUi?.host?.remove?.();
      appFallbackUi = null;
    } else {
      if (appFallbackUi &&
          previousFloatingButton !== appUiOptions.floatingButton) {
        appFallbackUi.host?.remove?.();
        appFallbackUi = null;
      }
      scheduleAppFallbackUi();
    }
    return {
      fallbackUi: appUiOptions.fallbackUi,
      floatingButton: appUiOptions.floatingButton,
    };
  }

  function initializeBrowserAppUi() {
    if (!global.__PLAYMESH_BROWSER__) return false;
    configureAppUi({ fallbackUi: true, floatingButton: false });
    return true;
  }

  function scheduleAppFallbackUi() {
    if (!appUiOptions.fallbackUi || appFallbackUi ||
        appUiRenderTimer !== null) {
      return;
    }
    if (typeof global.setTimeout !== "function") {
      void ensureAppFallbackUi();
      return;
    }
    appUiRenderTimer = global.setTimeout(() => {
      appUiRenderTimer = null;
      if (appUiOptions.fallbackUi) void ensureAppFallbackUi();
    }, 0);
  }

  function captureAppUiReturnFocus() {
    const documentObject = global.document;
    const activeElement = documentObject?.activeElement;
    appUiReturnFocus =
      activeElement &&
      activeElement !== documentObject?.body &&
      activeElement !== documentObject?.documentElement &&
      activeElement.isConnected !== false &&
      typeof activeElement.focus === "function"
        ? activeElement
        : null;
    appUiFocusCapturePending = true;
  }

  function clearAppUiReturnFocus() {
    appUiReturnFocus = null;
    appUiFocusCapturePending = false;
  }

  function restoreAppUiReturnFocus() {
    if (!appUiFocusCapturePending) return;
    appUiFocusCapturePending = false;
    const documentObject = global.document;
    const returnFocus = appUiReturnFocus;
    appUiReturnFocus = null;
    if (
      returnFocus &&
      returnFocus.isConnected !== false &&
      typeof returnFocus.focus === "function"
    ) {
      try {
        returnFocus.focus({ preventScroll: true });
        if (documentObject?.activeElement === returnFocus) return;
      } catch (_) {
        // 平台 UI 未消费时继续交给游戏文档处理。
      }
    }
    const gameDocumentTarget =
      documentObject?.body || documentObject?.documentElement;
    if (!gameDocumentTarget || typeof gameDocumentTarget.focus !== "function") {
      return;
    }
    const previousTabIndex = gameDocumentTarget.getAttribute?.("tabindex");
    try {
      if (gameDocumentTarget.tabIndex < 0) {
        gameDocumentTarget.setAttribute?.("tabindex", "-1");
      }
      gameDocumentTarget.focus({ preventScroll: true });
    } catch (_) {
      // 页面卸载期间游戏文档可能已经无法恢复焦点。
    } finally {
      if (previousTabIndex == null) {
        gameDocumentTarget.removeAttribute?.("tabindex");
      } else {
        gameDocumentTarget.setAttribute?.("tabindex", previousTabIndex);
      }
    }
  }

  function appUiText(key) {
    const messages = appUiConfiguration?.messages;
    const value = messages && typeof messages[key] === "string"
      ? messages[key]
      : null;
    if (!value) {
      throw new Error(`平台 UI 本地化消息不可用: ${key}`);
    }
    return value;
  }

  function resolveAppUiConfiguration(configuration) {
    if (!configuration || typeof configuration !== "object") return null;
    if (!Array.isArray(configuration.locales)) return configuration;
    const locales = configuration.locales.filter(
      (item) => item && typeof item === "object" &&
        typeof item.locale === "string",
    );
    let browserLocales = [];
    try {
      browserLocales = [
        ...(Array.isArray(global.navigator?.languages)
          ? global.navigator.languages
          : []),
        global.navigator?.language,
      ];
    } catch (_) {
      // 受限浏览器上下文可能禁止访问 navigator。
    }
    const candidates = [
      ...browserLocales,
      configuration.fallbackLocale,
    ].filter((value) => typeof value === "string" && value);
    let selected = null;
    for (const candidate of candidates) {
      const normalized = candidate.toLowerCase();
      selected =
        locales.find((item) => item.locale.toLowerCase() === normalized) ||
        locales.find((item) =>
          item.locale.toLowerCase().split("-")[0] ===
          normalized.split("-")[0]
        );
      if (selected) break;
    }
    selected ||= locales[0] || null;
    if (!selected) return null;
    const theme = selected.theme === "system"
      ? global.matchMedia?.("(prefers-color-scheme: light)")?.matches
        ? "light"
        : "dark"
      : selected.theme;
    return {
      ...selected,
      theme,
      actions: configuration.actions || selected.actions,
    };
  }

  function appUiActionEnabled(name, fallback = true) {
    const configured = appUiConfiguration?.actions?.[name];
    return typeof configured === "boolean" ? configured : fallback;
  }

  function escapeAppUiHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function formatAppUiConsoleValue(value) {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack || value.message;
    if (typeof value === "bigint") return value.toString();
    try {
      const encoded = JSON.stringify(value);
      return encoded === undefined ? String(value) : encoded;
    } catch (_) {
      return String(value);
    }
  }

  function installAppUiConsoleCapture() {
    if (appUiConsoleCaptureInstalled || !global.console) return;
    appUiConsoleCaptureInstalled = true;
    for (const level of ["debug", "info", "log", "warn", "error"]) {
      const original = global.console[level];
      if (typeof original !== "function") continue;
      global.console[level] = function (...args) {
        const message = args.map(formatAppUiConsoleValue).join(" ");
        appUiConsoleLogs.push({
          timestamp: Date.now(),
          level,
          message,
        });
        if (appUiConsoleLogs.length > APP_UI_LOG_LIMIT) {
          appUiConsoleLogs.splice(
            0,
            appUiConsoleLogs.length - APP_UI_LOG_LIMIT,
          );
        }
        if (appFallbackUi?.logsLayer &&
            !appFallbackUi.logsLayer.hidden) {
          renderAppUiLogs();
        }
        return original.call(this, message);
      };
    }
  }

  function renderAppUiLogs() {
    const output = appFallbackUi?.logsOutput;
    if (!output) return;
    output.textContent = appUiConsoleLogs.length
      ? appUiConsoleLogs.map((entry) => {
          const time = new Date(entry.timestamp).toLocaleTimeString();
          return `[${time}] [${entry.level.toUpperCase()}] ${entry.message}`;
        }).join("\n")
      : appUiText("logs.empty");
    output.scrollTop = output.scrollHeight;
  }

  function registerAppUiRuntimeAdapter(adapter) {
    appUiRuntimeAdapter =
      adapter && typeof adapter === "object" ? adapter : null;
    refreshAppFallbackUi();
    refreshAppUiPerformance();
  }

  async function appUiGameInfo() {
    if (typeof appUiRuntimeAdapter?.getInfo !== "function") return null;
    const runtimeInfo = await appUiRuntimeAdapter.getInfo();
    if (!runtimeInfo?.gameId || !runtimeInfo?.gameName) return null;
    const capabilities = runtimeInfo.requiredCapabilities || [];
    const tags = Array.isArray(runtimeInfo.tags)
      ? [...new Set(runtimeInfo.tags
          .map((tag) => String(tag || "").trim())
          .filter(Boolean))]
      : [];
    const role = runtimeInfo.multiplayer === true
      ? runtimeInfo.isAuthority === true
        ? appUiText("info.role_authority")
        : appUiText("info.role_player")
      : appUiText("info.role_solo");
    const gameId = runtimeInfo.gameId;
    const rows = [
      gameId
        ? {
            label: appUiText("info.game_id"),
            value: gameId,
            code: true,
            wide: true,
          }
        : null,
      { label: appUiText("info.role"), value: role },
      runtimeInfo.joinCode
        ? {
            label: appUiText("info.join_code_label"),
            value: runtimeInfo.joinCode,
            code: true,
          }
        : null,
      runtimeInfo.playerName
        ? {
            label: appUiText("info.player"),
            value: runtimeInfo.playerName,
          }
        : null,
      Number.isFinite(runtimeInfo.playerCount)
        ? {
            label: appUiText("info.players"),
            value: String(runtimeInfo.playerCount),
          }
        : null,
      {
        label: appUiText("info.platform"),
        value: runtimeInfo.platform,
      },
      runtimeInfo.gameSdkVersion
        ? {
            label: appUiText("info.game_sdk"),
            value: runtimeInfo.gameSdkVersion,
          }
        : null,
      {
        label: appUiText("info.app_sdk"),
        value: runtimeInfo.appSdkVersion,
      },
      {
        label: appUiText("info.capabilities"),
        value: Array.isArray(capabilities) && capabilities.length
          ? capabilities.join(" · ")
          : appUiText("info.none"),
        wide: true,
      },
    ].filter(Boolean);
    return {
      gameName: runtimeInfo.gameName,
      tags,
      rows,
      canEditNickname:
        runtimeInfo.canEditNickname === true &&
        Boolean(runtimeInfo.playerName) &&
        typeof appUiRuntimeAdapter?.editNickname === "function",
    };
  }

  function refreshAppUiPerformance() {
    const ui = appFallbackUi;
    if (!ui?.performancePanel) return;
    const metrics = appPerformanceSnapshot();
    ui.performancePanel.hidden = !appUiPerformanceVisible;
    ui.performanceButton?.setAttribute?.(
      "aria-pressed",
      String(appUiPerformanceVisible),
    );
    setAppUiControlLabel(
      ui.performanceButton,
      appUiPerformanceVisible
        ? "sidebar.performance_hide"
        : "sidebar.performance",
    );
    ui.fps.textContent =
      typeof metrics.fps === "number" ? `${Math.round(metrics.fps)} FPS` : "-- FPS";
    ui.latency.hidden = metrics.multiplayer !== true;
    ui.latency.textContent =
      typeof metrics.latency === "number"
        ? `${Math.round(metrics.latency)} ms`
        : "-- ms";
  }

  function setAppUiPerformanceVisible(visible) {
    appUiPerformanceVisible = visible === true;
    refreshAppUiPerformance();
    return appUiPerformanceVisible;
  }

  async function restartAppUiGame() {
    hideAppGameSidebar(false);
    try {
      if (appUiRuntimeAdapter?.reload) await appUiRuntimeAdapter.reload();
      else global.location?.reload?.();
    } catch (error) {
      global.console?.warn?.("Playmesh 重新开始游戏失败", error);
    }
  }

  async function openAppUiRuntimeLogs() {
    if (!appUiOptions.fallbackUi) return false;
    const ui = await ensureAppFallbackUi();
    if (!ui) return false;
    renderAppUiLogs();
    ui.logsLayer.hidden = false;
    ui.logsClose.focus?.({ preventScroll: true });
    return true;
  }

  async function copyAppUiRuntimeLogs() {
    const text = appFallbackUi?.logsOutput?.textContent || "";
    if (global.navigator?.clipboard?.writeText) {
      await global.navigator.clipboard.writeText(text);
      return true;
    }
    const copyField = global.document?.createElement?.("textarea");
    if (!copyField || !global.document?.body) return false;
    copyField.value = text;
    copyField.setAttribute?.("readonly", "");
    copyField.style.position = "fixed";
    copyField.style.opacity = "0";
    global.document.body.appendChild(copyField);
    copyField.select?.();
    const copied = global.document.execCommand?.("copy") === true;
    copyField.remove?.();
    return copied;
  }

  async function openAppUiGameInfo() {
    if (!appUiOptions.fallbackUi) return false;
    const ui = await ensureAppFallbackUi();
    if (!ui) return false;
    const info = await appUiGameInfo();
    if (!info) return false;
    ui.gameName.textContent = info.gameName;
    ui.gameTags.innerHTML = info.tags.map((tag) => `
      <span class="game-tag" role="listitem">
        <span class="game-tag-mark" aria-hidden="true">#</span>${escapeAppUiHtml(tag)}
      </span>
    `).join("");
    ui.gameTagsWrap.hidden = info.tags.length === 0;
    ui.gameTags.setAttribute(
      "aria-label",
      appUiText("info.tags"),
    );
    ui.gameTagsLabel.textContent = appUiText("info.tags");
    ui.gameDetail.innerHTML = info.rows.map((row) => `
      <div class="info-item${row.wide ? " wide" : ""}">
        <dt class="info-label">${escapeAppUiHtml(row.label)}</dt>
        <dd class="info-value${row.code ? " code" : ""}">${escapeAppUiHtml(row.value)}</dd>
      </div>
    `).join("");
    ui.infoEdit.hidden = !info.canEditNickname;
    ui.infoLayer.hidden = false;
    ui.infoClose.focus?.({ preventScroll: true });
    return true;
  }

  function installAppMenuButtonDrag(ui) {
    const button = ui?.menuButton;
    if (!button?.addEventListener) return;
    const dragThreshold = 5;
    const offscreenFraction = 0.5;
    let activePointerId = null;
    let startX = 0;
    let startY = 0;
    let startLeft = 0;
    let startTop = 0;
    let moved = false;
    let hasCustomPosition = false;
    let suppressNextClick = false;

    const viewportSize = () => ({
      width: global.visualViewport?.width ||
        global.innerWidth ||
        global.document?.documentElement?.clientWidth ||
        0,
      height: global.visualViewport?.height ||
        global.innerHeight ||
        global.document?.documentElement?.clientHeight ||
        0,
    });
    const moveTo = (left, top) => {
      const rect = button.getBoundingClientRect();
      const viewport = viewportSize();
      const minLeft = -rect.width * offscreenFraction;
      const minTop = -rect.height * offscreenFraction;
      const maxLeft = viewport.width - rect.width * (1 - offscreenFraction);
      const maxTop = viewport.height - rect.height * (1 - offscreenFraction);
      button.style.left =
        `${Math.round(Math.min(Math.max(minLeft, left), maxLeft))}px`;
      button.style.top =
        `${Math.round(Math.min(Math.max(minTop, top), maxTop))}px`;
      button.style.right = "auto";
      button.style.bottom = "auto";
      button.classList?.toggle?.("detached", true);
      hasCustomPosition = true;
    };
    const finish = (event) => {
      if (activePointerId === null ||
          (event?.pointerId !== undefined &&
            event.pointerId !== activePointerId)) {
        return;
      }
      button.releasePointerCapture?.(activePointerId);
      button.classList?.toggle?.("dragging", false);
      activePointerId = null;
      if (moved) {
        suppressNextClick = true;
        global.setTimeout?.(() => {
          suppressNextClick = false;
        }, 0);
      }
    };
    button.addEventListener("pointerdown", (event) => {
      if (event?.button !== undefined && event.button !== 0) return;
      const rect = button.getBoundingClientRect();
      activePointerId = event?.pointerId ?? 0;
      startX = event?.clientX ?? 0;
      startY = event?.clientY ?? 0;
      startLeft = rect.left;
      startTop = rect.top;
      moved = false;
      button.classList?.toggle?.("dragging", true);
      button.setPointerCapture?.(activePointerId);
    });
    button.addEventListener("pointermove", (event) => {
      if (activePointerId === null ||
          (event?.pointerId !== undefined &&
            event.pointerId !== activePointerId)) {
        return;
      }
      const deltaX = (event?.clientX ?? startX) - startX;
      const deltaY = (event?.clientY ?? startY) - startY;
      if (!moved && Math.hypot(deltaX, deltaY) < dragThreshold) return;
      moved = true;
      event?.preventDefault?.();
      moveTo(startLeft + deltaX, startTop + deltaY);
    });
    button.addEventListener("pointerup", finish);
    button.addEventListener("pointercancel", finish);
    button.addEventListener("click", (event) => {
      if (!suppressNextClick) return;
      suppressNextClick = false;
      event?.preventDefault?.();
      event?.stopImmediatePropagation?.();
    }, true);
    global.addEventListener?.("resize", () => {
      if (!hasCustomPosition) return;
      const rect = button.getBoundingClientRect();
      moveTo(rect.left, rect.top);
    });
  }

  async function ensureAppFallbackUi() {
    if (!appUiOptions.fallbackUi) return null;
    if (appFallbackUi) return appFallbackUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener(
        "DOMContentLoaded",
        resolve,
        { once: true },
      ));
    }
    if (!appUiOptions.fallbackUi || appFallbackUi) return appFallbackUi;
    const host = global.document.createElement("div");
    host.id = "playmesh-app-platform-ui";
    host.setAttribute?.("lang", appUiConfiguration?.locale || "zh-CN");
    host.setAttribute?.("data-theme", appUiConfiguration?.theme || "dark");
    const root = host.attachShadow({ mode: "closed" });
    const menuButtonMarkup =
      global.__PLAYMESH_BROWSER__ && appUiOptions.floatingButton
        ? `<button class="menu-fab" type="button"><span class="menu-mark" aria-hidden="true">P</span></button>`
        : "";
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#111827f2;--pm-surface-strong:#172033;--pm-hover:#26334a;--pm-text:#f8fafc;--pm-muted:#a8b4c7;--pm-border:#60708a40;--pm-divider:#ffffff14;--pm-overlay:#050a14a8;--pm-focus:#67e8f9;--pm-focus-ring:#67e8f94d;--pm-accent:#2dd4bf;--pm-accent-strong:#0f9f8d;--pm-error:#fda4af;--pm-log:#090f1c;--pm-shadow:#0008;font-family:system-ui,"Microsoft YaHei",sans-serif;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#f8fafcf5;--pm-surface-strong:#fff;--pm-hover:#e8eef7;--pm-text:#172033;--pm-muted:#5d6b80;--pm-border:#9aabc238;--pm-divider:#24324a14;--pm-overlay:#17203366;--pm-focus:#087f8c;--pm-focus-ring:#087f8c3d;--pm-accent:#0f9f8d;--pm-accent-strong:#087f6d;--pm-error:#b4233f;--pm-log:#edf2f7;--pm-shadow:#17203330;color-scheme:light}
      button{box-sizing:border-box;font:inherit}.menu-fab{position:fixed;right:0;top:36%;z-index:2147483645;display:grid;place-items:center;width:42px;height:42px;padding:0;border:1px solid #92e6d5;border-radius:13px 0 0 13px;background:#087f6d;color:#fff;box-shadow:0 6px 18px #001b1752,0 2px 6px #001b1738;cursor:grab;isolation:isolate;touch-action:none;user-select:none;-webkit-user-select:none;transition:transform .16s ease,box-shadow .16s ease,border-radius .16s ease}.menu-fab.detached{border-radius:13px}
      .menu-fab::before{content:"";position:absolute;inset:-2px;z-index:-1;border:1px solid #36cbb266;border-radius:16px 0 0 16px;animation:menu-breathe 2.8s ease-in-out infinite;pointer-events:none}.menu-fab.detached::before{border-radius:16px}.menu-fab.detached:hover{transform:translateY(-2px)}.menu-fab:active{transform:scale(.96)}.menu-fab.dragging{cursor:grabbing;transform:none;transition:none}.menu-fab:focus-visible,.dialog button:focus-visible,.logs-output:focus-visible{outline:2px solid var(--pm-focus);outline-offset:2px}.action:focus-visible{outline:0;background:var(--pm-hover);box-shadow:inset 0 0 0 2px var(--pm-focus-ring)}
      .menu-mark{position:relative;display:block;width:22px;transform:translateX(-2px);font:900 20px/1 system-ui}.menu-mark::after{content:"";position:absolute;left:15px;top:3px;width:7px;height:2px;border-radius:2px;background:currentColor;box-shadow:0 5px currentColor,0 10px currentColor}
      .layer{position:fixed;inset:0;z-index:2147483646;display:grid;place-items:center;padding:max(18px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(18px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left));color:var(--pm-text)}.scrim{position:absolute;inset:0;width:100%;height:100%;background:radial-gradient(circle at 50% 42%,#21304a52 0,transparent 48%),var(--pm-overlay);backdrop-filter:blur(12px) saturate(1.08);-webkit-backdrop-filter:blur(12px) saturate(1.08)}.sidebar{box-sizing:border-box;position:relative;display:grid;grid-template-rows:auto minmax(0,1fr) auto;width:min(100%,480px);max-height:min(720px,calc(100dvh - 36px));overflow:hidden;padding:10px;border:0;border-radius:22px;background:linear-gradient(145deg,var(--pm-surface-strong),var(--pm-surface));box-shadow:0 24px 72px var(--pm-shadow),0 1px 0 #ffffff0f inset;animation:menu-arrive .18s cubic-bezier(.2,.8,.2,1)}.head{display:flex;align-items:center;gap:12px;padding:8px 10px 16px;border-bottom:1px solid var(--pm-divider)}.brand{display:grid;place-items:center;width:36px;height:36px;border-radius:12px;background:var(--pm-accent-strong);color:#fff;font:850 18px/1 system-ui}.title{margin:0;color:var(--pm-text);font-size:19px;line-height:1.25;font-weight:780;letter-spacing:.01em}.actions-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px;min-height:0;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable;-webkit-overflow-scrolling:touch;padding:10px 0}.action{display:flex;align-items:center;gap:11px;width:100%;min-height:52px;padding:9px 12px;border:0;border-radius:11px;background:transparent;color:var(--pm-text);font:650 14px/1.25 system-ui,"Microsoft YaHei",sans-serif;text-align:left;cursor:pointer;transition:background .14s ease,box-shadow .14s ease}.action:hover{background:var(--pm-hover)}.action.continue{background:#2dd4bf14;color:var(--pm-accent)}.action.exit{min-height:48px;color:var(--pm-error);background:transparent}.icon{display:grid;place-items:center;flex:0 0 24px;width:24px;color:inherit;font:800 18px/1 system-ui}.foot{padding-top:6px;border-top:1px solid var(--pm-divider)}
      .dialog-layer{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:16px;background:var(--pm-overlay);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}.dialog{box-sizing:border-box;width:min(100%,720px);max-height:calc(100dvh - 32px);overflow:auto;padding:20px;border:0;border-radius:18px;background:var(--pm-surface);color:var(--pm-text);box-shadow:0 20px 60px var(--pm-shadow)}.dialog h2{margin:0 0 16px;font-size:20px}.dialog p{color:var(--pm-muted);line-height:1.6}.dialog-actions{display:flex;justify-content:flex-end;gap:6px;margin-top:14px}.dialog button{height:40px;padding:0 14px;border:0;border-radius:10px;background:transparent;color:var(--pm-text);cursor:pointer}.dialog button:hover{background:var(--pm-hover)}.info-hero{display:flex;align-items:center;gap:13px;margin-bottom:14px;padding:14px;border:0;border-radius:14px;background:#2dd4bf0d}.info-mark{display:grid;place-items:center;flex:0 0 38px;width:38px;height:38px;border-radius:12px;background:var(--pm-accent-strong);color:#fff;font:800 20px/1 ui-monospace,monospace}.game-name{min-width:0;margin:0!important;color:var(--pm-text)!important;font-size:17px;font-weight:750;overflow-wrap:anywhere}.info-hero,.info-grid,.game-name,.info-label,.info-value{cursor:text;user-select:text;-webkit-user-select:text}.info-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1px;margin:0;overflow:hidden;border:0;border-radius:14px;background:var(--pm-divider)}.info-item{min-width:0;padding:12px 13px;background:var(--pm-surface-strong)}.info-item.wide{grid-column:1/-1}.info-label{display:block;margin:0 0 5px;color:var(--pm-muted);font-size:11px;font-weight:700;letter-spacing:.05em}.info-value{display:block;margin:0;color:var(--pm-text);font:650 13px/1.45 system-ui,"Microsoft YaHei",sans-serif;overflow-wrap:anywhere}.info-value.code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;letter-spacing:.01em}.logs-output{box-sizing:border-box;height:min(58dvh,480px);margin:0;padding:12px;overflow:auto;border:0;border-radius:12px;background:var(--pm-log);color:var(--pm-text);cursor:text;user-select:text;-webkit-user-select:text;white-space:pre-wrap;word-break:break-word;font:12px/1.55 ui-monospace,SFMono-Regular,Consolas,monospace}.performance-panel{position:fixed;left:max(12px,env(safe-area-inset-left));top:max(12px,env(safe-area-inset-top));z-index:2147483647;display:flex;gap:10px;padding:0;border:0;background:transparent;color:#fff;text-shadow:0 1px 3px #000,0 0 8px #000;font:750 12px/1 ui-monospace,SFMono-Regular,Consolas,monospace;pointer-events:none}
      .game-tags-wrap{display:flex;align-items:center;gap:10px;min-width:0;margin:0 0 14px}.game-tags-label{flex:0 0 auto;color:var(--pm-muted);font-size:12px;font-weight:750}.game-tags{display:flex;flex:1 1 auto;gap:7px;min-width:0;overflow-x:auto;overscroll-behavior-x:contain;padding:1px 1px 5px;scrollbar-width:thin;-webkit-overflow-scrolling:touch}.game-tag{display:inline-flex;align-items:center;flex:0 0 auto;gap:5px;max-width:260px;padding:6px 10px;border:1px solid var(--pm-border);border-radius:999px;background:#2dd4bf12;color:var(--pm-text);font:650 12px/1.2 system-ui,"Microsoft YaHei",sans-serif;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.game-tag-mark{color:var(--pm-accent);font:800 12px/1 ui-monospace,monospace}
      [hidden]{display:none!important}@keyframes menu-breathe{0%,100%{opacity:.35;transform:scale(.96)}50%{opacity:.85;transform:scale(1.04)}}@keyframes menu-arrive{from{opacity:0;transform:translateY(10px) scale(.98)}to{opacity:1;transform:none}}@media(prefers-reduced-motion:reduce){.menu-fab,.action{transition:none}.menu-fab::before{animation:none;opacity:.55}.sidebar{animation:none}}@media(max-width:440px){.sidebar{border-radius:18px}.actions-list,.info-grid{grid-template-columns:1fr}.action{min-height:50px}}
    </style>
    ${menuButtonMarkup}
    <div class="layer" hidden><div class="scrim" aria-hidden="true"></div><aside class="sidebar" role="dialog" aria-modal="true"><header class="head"><span class="brand" aria-hidden="true">P</span><h2 class="title"></h2></header><nav class="actions-list">
      <button class="action continue" data-action="continue" type="button"><span class="icon" aria-hidden="true">▶</span><span></span></button>
      <button class="action restart" data-action="restart" type="button"><span class="icon" aria-hidden="true">↻</span><span></span></button>
      <button class="action share" data-action="share" type="button"><span class="icon" aria-hidden="true">▦</span><span></span></button>
      <button class="action logs" data-action="logs" type="button"><span class="icon" aria-hidden="true">≡</span><span></span></button>
      <button class="action enter-fullscreen" data-action="enter-fullscreen" type="button"><span class="icon" aria-hidden="true">⛶</span><span></span></button>
      <button class="action exit-fullscreen" data-action="exit-fullscreen" type="button"><span class="icon" aria-hidden="true">⊡</span><span></span></button>
      <button class="action info" data-action="info" type="button"><span class="icon" aria-hidden="true">ⓘ</span><span></span></button>
      <button class="action performance" data-action="performance" type="button" aria-pressed="false"><span class="icon" aria-hidden="true">◴</span><span></span></button>
    </nav><footer class="foot"><button class="action exit" data-action="exit" type="button"><span class="icon" aria-hidden="true">↩</span><span></span></button></footer></aside></div>
    <div class="dialog-layer info-layer" role="dialog" aria-modal="true" hidden><section class="dialog"><h2 class="info-title"></h2><div class="info-hero"><span class="info-mark" aria-hidden="true">i</span><p class="game-name"></p></div><div class="game-tags-wrap" hidden><span class="game-tags-label"></span><div class="game-tags" role="list"></div></div><dl class="game-detail info-grid"></dl><div class="dialog-actions"><button class="info-edit" type="button" hidden></button><button class="info-close" type="button"></button></div></section></div>
    <div class="dialog-layer logs-layer" role="dialog" aria-modal="true" hidden><section class="dialog"><h2 class="logs-title"></h2><pre class="logs-output" tabindex="0"></pre><div class="dialog-actions"><button class="logs-copy" type="button"></button><button class="logs-clear" type="button"></button><button class="logs-close" type="button"></button></div></section></div>
    <div class="performance-panel" hidden><span class="fps">-- FPS</span><span class="latency" hidden>-- ms</span></div>`;
    global.document.body.appendChild(host);
    const query = (selector) => root.querySelector(selector);
    appFallbackUi = {
      host,
      root,
      menuButton: query(".menu-fab"),
      layer: query(".layer"),
      sidebar: query(".sidebar"),
      scrim: query(".scrim"),
      title: query(".title"),
      continueButton: query(".continue"),
      restart: query(".restart"),
      share: query(".share"),
      logs: query(".logs"),
      enterFullscreen: query(".enter-fullscreen"),
      exitFullscreen: query(".exit-fullscreen"),
      info: query(".info"),
      performanceButton: query(".performance"),
      exit: query(".exit"),
      performancePanel: query(".performance-panel"),
      fps: query(".fps"),
      latency: query(".latency"),
      infoLayer: query(".info-layer"),
      infoTitle: query(".info-title"),
      gameName: query(".game-name"),
      gameTagsWrap: query(".game-tags-wrap"),
      gameTagsLabel: query(".game-tags-label"),
      gameTags: query(".game-tags"),
      gameDetail: query(".game-detail"),
      infoEdit: query(".info-edit"),
      infoClose: query(".info-close"),
      logsLayer: query(".logs-layer"),
      logsTitle: query(".logs-title"),
      logsOutput: query(".logs-output"),
      logsCopy: query(".logs-copy"),
      logsClear: query(".logs-clear"),
      logsClose: query(".logs-close"),
    };
    const ui = appFallbackUi;
    if (ui.menuButton) {
      ui.menuButton.onclick = () => showAppGameSidebar();
    }
    ui.continueButton.onclick = () => hideAppGameSidebar();
    ui.scrim.onclick = () => hideAppGameSidebar();
    ui.restart.onclick = () => void restartAppUiGame();
    ui.share.onclick = () => {
      void openAppSharePanel().catch((error) => {
        global.console?.warn?.("Playmesh 分享界面未能打开", error);
      });
    };
    ui.logs.onclick = () => void openAppUiRuntimeLogs();
    ui.enterFullscreen.onclick = () => {
      void setAppUiFullscreen(true);
    };
    ui.exitFullscreen.onclick = () => {
      void setAppUiFullscreen(false);
    };
    ui.info.onclick = () => void openAppUiGameInfo();
    ui.performanceButton.onclick = () => {
      setAppUiPerformanceVisible(!appUiPerformanceVisible);
    };
    ui.exit.onclick = () => {
      hideAppGameSidebar(false);
      void exitAppUiGame();
    };
    ui.infoClose.onclick = () => {
      ui.infoLayer.hidden = true;
      if (!ui.layer.hidden) {
        ui.info.focus?.({ preventScroll: true });
      } else {
        restoreAppUiReturnFocus();
      }
    };
    ui.infoEdit.onclick = async () => {
      ui.infoLayer.hidden = true;
      try {
        await appUiRuntimeAdapter?.editNickname?.();
      } catch (error) {
        global.console?.warn?.("Playmesh 浏览器昵称修改失败", error);
      }
      if (!ui.layer.hidden) void openAppUiGameInfo();
      else restoreAppUiReturnFocus();
    };
    ui.logsClear.onclick = () => {
      appUiConsoleLogs.length = 0;
      renderAppUiLogs();
    };
    ui.logsCopy.onclick = async () => {
      try {
        const copied = await copyAppUiRuntimeLogs();
        if (!copied) throw new Error("当前环境不支持复制");
        setAppUiControlLabel(ui.logsCopy, "logs.copied");
        global.setTimeout?.(() => {
          setAppUiControlLabel(ui.logsCopy, "logs.copy");
        }, 1200);
      } catch (error) {
        global.console?.warn?.("Playmesh 运行日志复制失败", error);
      }
    };
    ui.logsClose.onclick = () => {
      ui.logsLayer.hidden = true;
      if (!ui.layer.hidden) {
        ui.logs.focus?.({ preventScroll: true });
      } else {
        restoreAppUiReturnFocus();
      }
    };
    const sidebarControls = () => [
      ui.continueButton,
      ui.restart,
      ui.share,
      ui.logs,
      ui.enterFullscreen,
      ui.exitFullscreen,
      ui.info,
      ui.performanceButton,
      ui.exit,
    ].filter((control) =>
      control &&
      !control.hidden &&
      !control.disabled
    );
    const moveSidebarFocus = (direction) => {
      const controls = sidebarControls();
      if (controls.length === 0) return false;
      const activeElement = root.activeElement || global.document?.activeElement;
      const activeIndex = controls.indexOf(activeElement);
      const exitIndex = controls.indexOf(ui.exit);
      const gridLength = exitIndex < 0 ? controls.length : exitIndex;
      const columns =
        global.matchMedia?.("(max-width: 440px)")?.matches === true ||
        (Number.isFinite(global.innerWidth) && global.innerWidth <= 440)
          ? 1
          : 2;
      let nextIndex = activeIndex < 0 ? 0 : activeIndex;
      if (direction === "first") {
        nextIndex = 0;
      } else if (direction === "last") {
        nextIndex = controls.length - 1;
      } else if (activeIndex === exitIndex && exitIndex >= 0) {
        if (direction === "up" && gridLength > 0) {
          nextIndex = gridLength - 1;
        }
      } else if (activeIndex >= 0 && activeIndex < gridLength) {
        const column = activeIndex % columns;
        if (direction === "left" && column > 0) {
          nextIndex = activeIndex - 1;
        } else if (
          direction === "right" &&
          column < columns - 1 &&
          activeIndex + 1 < gridLength
        ) {
          nextIndex = activeIndex + 1;
        } else if (direction === "up" && activeIndex - columns >= 0) {
          nextIndex = activeIndex - columns;
        } else if (direction === "down") {
          nextIndex = activeIndex + columns < gridLength
            ? activeIndex + columns
            : exitIndex >= 0
              ? exitIndex
              : activeIndex;
        }
      }
      controls[nextIndex].focus?.({ preventScroll: true });
      return true;
    };
    root.addEventListener("keydown", (event) => {
      if (!ui.layer.hidden && ui.logsLayer.hidden && ui.infoLayer.hidden) {
        let direction = null;
        if (event.key === "ArrowDown") direction = "down";
        else if (event.key === "ArrowUp") direction = "up";
        else if (event.key === "ArrowLeft") direction = "left";
        else if (event.key === "ArrowRight") direction = "right";
        else if (event.key === "Home") direction = "first";
        else if (event.key === "End") direction = "last";
        if (direction !== null && moveSidebarFocus(direction)) {
          event.preventDefault?.();
          event.stopPropagation?.();
          event.stopImmediatePropagation?.();
          return;
        }
      }
      if (event.key !== "Escape" && event.key !== "BrowserBack" &&
          event.key !== "GoBack") {
        return;
      }
      event.preventDefault?.();
      event.stopPropagation?.();
      if (!ui.logsLayer.hidden) ui.logsClose.onclick();
      else if (!ui.infoLayer.hidden) ui.infoClose.onclick();
      else if (!ui.layer.hidden) hideAppGameSidebar();
    });
    installAppMenuButtonDrag(ui);
    refreshAppFallbackUi();
    refreshAppUiPerformance();
    return ui;
  }

  function setAppUiControlLabel(element, key, updateVisibleText = true) {
    if (!element) return;
    const label = appUiText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    if (!updateVisibleText) return;
    const visibleText = element.querySelector?.("span:last-child");
    if (visibleText) visibleText.textContent = label;
    else if (element.tagName === "BUTTON") element.textContent = label;
  }

  function refreshAppFallbackUi() {
    const ui = appFallbackUi;
    if (!ui) return;
    ui.host.setAttribute?.("lang", appUiConfiguration?.locale || "zh-CN");
    ui.host.setAttribute?.("data-theme", appUiConfiguration?.theme || "dark");
    ui.title.textContent = appUiText("sidebar.title");
    setAppUiControlLabel(ui.menuButton, "sidebar.title", false);
    setAppUiControlLabel(ui.continueButton, "sidebar.continue");
    setAppUiControlLabel(ui.restart, "sidebar.restart");
    setAppUiControlLabel(ui.share, "sidebar.share");
    setAppUiControlLabel(ui.logs, "sidebar.logs");
    setAppUiControlLabel(
      ui.enterFullscreen,
      "sidebar.enter_fullscreen",
    );
    setAppUiControlLabel(
      ui.exitFullscreen,
      "sidebar.exit_fullscreen",
    );
    setAppUiControlLabel(ui.info, "sidebar.info");
    setAppUiControlLabel(
      ui.performanceButton,
      "sidebar.performance",
    );
    setAppUiControlLabel(ui.exit, "sidebar.exit");
    ui.share.hidden = !appUiActionEnabled("share", false);
    ui.restart.hidden = !appUiActionEnabled("restart");
    ui.logs.hidden = !appUiActionEnabled("logs");
    ui.enterFullscreen.hidden = !appUiActionEnabled("fullscreen");
    ui.exitFullscreen.hidden = !appUiActionEnabled("fullscreen");
    ui.info.hidden =
      !appUiActionEnabled("info") ||
      typeof appUiRuntimeAdapter?.getInfo !== "function";
    ui.performanceButton.hidden = !appUiActionEnabled("performance");
    ui.exit.hidden = !appUiActionEnabled("exit");
    const browser = bootstrap?.available !== true;
    if (ui.menuButton) {
      ui.menuButton.hidden =
        !browser ||
        !appUiOptions.floatingButton ||
        !ui.layer.hidden;
    }
    ui.infoTitle.textContent = appUiText("info.title");
    ui.logsTitle.textContent = appUiText("logs.title");
    setAppUiControlLabel(ui.logsCopy, "logs.copy");
    setAppUiControlLabel(ui.infoEdit, "nickname.edit_action");
    setAppUiControlLabel(ui.infoClose, "common.close");
    setAppUiControlLabel(ui.logsClear, "common.clear");
    setAppUiControlLabel(ui.logsClose, "common.close");
  }

  async function showAppGameSidebar() {
    if (!appUiOptions.fallbackUi) return false;
    captureAppUiReturnFocus();
    const ui = await ensureAppFallbackUi();
    if (!ui) {
      clearAppUiReturnFocus();
      return false;
    }
    ui.infoLayer.hidden = true;
    ui.logsLayer.hidden = true;
    ui.layer.hidden = false;
    if (ui.menuButton) ui.menuButton.hidden = true;
    ui.continueButton.focus?.({ preventScroll: true });
    return true;
  }

  function hideAppGameSidebar(restoreFocus = true) {
    const ui = appFallbackUi;
    if (!ui) return Promise.resolve(false);
    ui.layer.hidden = true;
    refreshAppFallbackUi();
    if (restoreFocus) restoreAppUiReturnFocus();
    return Promise.resolve(true);
  }

  function toggleAppGameSidebar() {
    if (appFallbackUi && !appFallbackUi.layer.hidden) {
      return hideAppGameSidebar();
    }
    return showAppGameSidebar();
  }

  function handleAppUiNativeBack() {
    if (!appUiOptions.fallbackUi) return false;
    const ui = appFallbackUi;
    if (!ui) {
      void showAppGameSidebar();
      return true;
    }
    if (!ui.logsLayer.hidden) ui.logsClose.onclick();
    else if (!ui.infoLayer.hidden) ui.infoClose.onclick();
    else if (!ui.layer.hidden) void hideAppGameSidebar();
    else void showAppGameSidebar();
    return true;
  }

  function openAppSharePanel() {
    if (!global.navigator?.userActivation?.isActive) {
      return Promise.reject(appUiError(
        "user_activation_required",
        "打开分享界面需要当前用户操作",
      ));
    }
    if (bootstrap?.available !== true) {
      return Promise.reject(appUiError(
        "ui_unavailable",
        "当前浏览器不提供 Authority 分享功能",
      ));
    }
    captureAppUiReturnFocus();
    return request("app.ui.openSharePanel", { userActivation: true })
      .catch((error) => {
        clearAppUiReturnFocus();
        throw error;
      });
  }

  async function setAppUiFullscreen(enabled) {
    try {
      if (bootstrap?.available === true) {
        await publicAppApi.device.setFullscreen(enabled);
      } else if (enabled) {
        await global.document?.documentElement?.requestFullscreen?.();
      } else if (global.document?.fullscreenElement) {
        await global.document.exitFullscreen?.();
      }
    } catch (error) {
      global.console?.warn?.("Playmesh 全屏切换失败", error);
    }
  }

  async function exitAppUiGame() {
    if (bootstrap?.available === true) {
      return request("app.game.exit");
    }
    try {
      if (global.history?.length > 1) {
        global.history.back();
        return;
      }
      global.close?.();
      global.setTimeout?.(() => {
        if (!global.closed) global.location?.replace?.("about:blank");
      }, 0);
    } catch (error) {
      global.console?.warn?.("浏览器无法退出当前游戏", error);
    }
  }

  function isAppUiOwnedKeyboardEvent(event) {
    const hostId = "playmesh-app-platform-ui";
    const target = event?.target;
    if (target?.id === hostId ||
        target?.getRootNode?.()?.host?.id === hostId) {
      return true;
    }
    const path = event?.composedPath?.();
    return Array.isArray(path) &&
      path.some((node) => node?.id === hostId);
  }

  function isAppUiEditableTarget(target) {
    if (!target || typeof target !== "object") return false;
    const tag = String(target.tagName || "").toUpperCase();
    return target.isContentEditable === true ||
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT";
  }

  function installAppUiKeyboardInterception() {
    if (appUiKeyboardInstalled || !global.addEventListener) return;
    appUiKeyboardInstalled = true;
    global.addEventListener("keydown", (event) => {
      if (event?.defaultPrevented ||
          event?.repeat ||
          isAppUiOwnedKeyboardEvent(event) ||
          isAppUiEditableTarget(event?.target)) {
        return;
      }
      const key = event?.key;
      const code = event?.keyCode;
      const menu =
        key === "F10" ||
        key === "ContextMenu" ||
        key === "Menu" ||
        code === 82 ||
        code === 121 ||
        code === 93;
      const back =
        key === "Escape" ||
        key === "Back" ||
        key === "BrowserBack" ||
        key === "GoBack" ||
        key === "XF86Back" ||
        code === 27 ||
        code === 4 ||
        code === 166 ||
        code === 461 ||
        code === 10009;
      if (!menu && !back) return;
      if (!appUiOptions.fallbackUi) return;
      event.preventDefault?.();
      event.stopPropagation?.();
      event.stopImmediatePropagation?.();
      if (!appUiConfiguration?.messages) {
        // 原生 bootstrap 返回前先记录切换意图，避免 UI 为抢首键引入硬编码文案。
        appUiTogglePending = !appUiTogglePending;
        return;
      }
      void toggleAppGameSidebar();
    }, true);
  }

  function initializeAppPlatformUi(configuration) {
    appUiConfiguration = resolveAppUiConfiguration(configuration);
    updateAppRuntimeLocale(appUiConfiguration);
    installAppUiConsoleCapture();
    installAppUiKeyboardInterception();
    if (appUiOptions.fallbackUi) scheduleAppFallbackUi();
    refreshAppFallbackUi();
    if (appUiTogglePending && appUiConfiguration?.messages) {
      appUiTogglePending = false;
      void toggleAppGameSidebar();
    }
  }

''',
);

final class _AppUiFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appUiSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.input.takeover',
    'app.ui.openSharePanel',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) {
    switch (command.name) {
      case 'app.input.takeover':
        return Future<Object?>.value(context.takeOverInput());
      case 'app.ui.openSharePanel':
        if (command.payload['userActivation'] != true) {
          throw const SdkCommandException(
            'user_activation_required',
            '打开分享界面需要当前用户操作',
          );
        }
        return context.openSharePanel();
    }
    throw StateError('未注册的 App 平台 UI 命令: ${command.name}');
  }
}
