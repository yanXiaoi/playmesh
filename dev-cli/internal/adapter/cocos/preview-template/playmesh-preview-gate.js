"use strict";

(() => {
  function installSafeCocosReload() {
    if (typeof globalThis.__playmeshCocosReload === "function") {
      return;
    }
    let reloading = false;
    const delay = (milliseconds) =>
      new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds));

    async function requestDevelopmentReload() {
      globalThis.__playmeshDevelopmentRefreshRequested = true;
      const response = await globalThis.fetch(
        "/.playmesh-development/restart",
        {
          method: "POST",
          cache: "no-store",
          credentials: "omit",
        },
      );
      if (!response.ok) {
        throw new Error(`开发刷新控制口返回 HTTP ${response.status}`);
      }
    }

    async function previewResourcesReady(verifyBundleBody) {
      const scripts = Array.from(
        globalThis.document?.querySelectorAll?.("script[src]") || [],
      );
      const candidates = scripts
        .map((script) => script.src)
        .filter(
          (source) =>
            /\/settings\.js(?:\?|$)/.test(source) ||
            /\/import-map(?:\.json|-global)(?:\?|$)/.test(source) ||
            /\/bundled\/index\.js(?:\?|$)/.test(source),
        );
      if (candidates.length < 2) {
        return false;
      }
      for (const source of candidates) {
        const settings = /\/settings\.js(?:\?|$)/.test(source);
        const bundled = /\/bundled\/index\.js(?:\?|$)/.test(source);
        const response = await globalThis.fetch(source, {
          method: bundled && !verifyBundleBody ? "HEAD" : "GET",
          cache: "no-store",
          credentials: "omit",
        });
        if (!response.ok) {
          return false;
        }
        if (settings) {
          const content = await response.text();
          if (!content.includes("_CCSettings")) {
            return false;
          }
        } else if (bundled && verifyBundleBody) {
          const content = await response.arrayBuffer();
          if (content.byteLength === 0) {
            return false;
          }
        }
      }
      return true;
    }

    globalThis.__playmeshCocosReload = (reason = "reload") => {
      if (reason === "disconnect") {
        console.info(
          "[Playmesh] Cocos 预览连接暂时断开，保持当前 App 页面和开发代理，等待重建完成。",
        );
        return;
      }
      if (reloading) {
        return;
      }
      reloading = true;
      console.info(
        "[Playmesh] 已收到 Cocos 刷新信号，等待预览资源稳定后刷新游戏页面。",
      );
      void (async () => {
        const deadline = Date.now() + 20_000;
        let consecutiveReadyChecks = 0;
        while (Date.now() < deadline) {
          try {
            if (
              await previewResourcesReady(consecutiveReadyChecks === 0)
            ) {
              consecutiveReadyChecks += 1;
              if (consecutiveReadyChecks >= 2) {
                console.info(
                  "[Playmesh] Cocos 预览资源已稳定，正在通过 CLI 请求 App 重启开发游戏页面。",
                );
                try {
                  await requestDevelopmentReload();
                } catch (error) {
                  reloading = false;
                  console.error(
                    "[Playmesh] CLI 未能受理 Cocos 刷新请求；当前 App 页面保持不变。",
                    error,
                  );
                }
                return;
              }
            } else {
              consecutiveReadyChecks = 0;
            }
          } catch (_) {
            consecutiveReadyChecks = 0;
          }
          await delay(250);
        }
        reloading = false;
        console.error(
          "[Playmesh] Cocos 预览资源在 20 秒内未恢复，保留当前游戏页面；请查看 Cocos Creator 控制台。",
        );
      })();
    };
  }

  function isPlaymeshAppHost() {
    try {
      if (globalThis.PlaymeshAppBridge?.postMessage) {
        return true;
      }
      if (
        globalThis.chrome?.webview?.postMessage &&
        globalThis.__playmeshHostConsoleCaptureInstalled === true
      ) {
        return true;
      }
      if (globalThis.playmesh?.app?.isAvailable?.() === true) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  if (isPlaymeshAppHost()) {
    installSafeCocosReload();
    return;
  }

  try {
    globalThis.sessionStorage.setItem(
      "playmesh.preview.url",
      globalThis.location.href,
    );
    globalThis.location.replace("/playmesh-preview-handoff.html");
  } catch (error) {
    console.error("[Playmesh] 无法进入自动预览交接页", error);
  }
})();
