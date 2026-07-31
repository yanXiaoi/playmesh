"use strict";

(() => {
  const launchMarkerKey = "playmesh.preview.launched";
  const previewOrigin = globalThis.location?.origin || "";
  const status = document.getElementById("playmesh-preview-status");

  const setStatus = (message) => {
    if (status) {
      status.textContent = message;
    }
  };

  void (async () => {
    try {
      if (globalThis.sessionStorage.getItem(launchMarkerKey) === "true") {
        setStatus(
          "Playmesh App 已在运行。本次刷新只更新 Cocos 预览资源，不会重启 App 或开发代理。",
        );
        return;
      }
      const previewPageURL = globalThis.sessionStorage.getItem(
        "playmesh.preview.url",
      );
      if (!previewPageURL) {
        throw new Error("缺少原始 Cocos 预览地址，请重新点击预览");
      }

      const runtimeURL = new URL(
        "/playmesh-preview-runtime.json",
        previewOrigin,
      );
      runtimeURL.searchParams.set("playmesh", `${Date.now()}-${Math.random()}`);
      const runtimeResponse = await fetch(runtimeURL.href, {
        method: "GET",
        cache: "no-store",
        credentials: "omit",
      });
      if (!runtimeResponse.ok) {
        if (runtimeResponse.status === 404) {
          throw new Error(
            "Playmesh 扩展运行时配置不存在；请重新初始化或重新加载 Playmesh 项目扩展后重试",
          );
        }
        throw new Error(
          `读取扩展运行时端口失败（HTTP ${runtimeResponse.status}）`,
        );
      }
      const runtime = await runtimeResponse.json();
      if (
        !runtime ||
        !Number.isInteger(runtime.port) ||
        runtime.port < 1 ||
        runtime.port > 65535
      ) {
        throw new Error("扩展未写入有效的自动预览端口");
      }
      const bridgeBaseURL = `http://127.0.0.1:${runtime.port}`;

      const sessionResponse = await fetch(`${bridgeBaseURL}/session`, {
        method: "GET",
        cache: "no-store",
        credentials: "omit",
      });
      if (!sessionResponse.ok) {
        throw new Error(`获取预览 token 失败（HTTP ${sessionResponse.status}）`);
      }
      const session = await sessionResponse.json();
      if (!session || typeof session.token !== "string" || !session.token) {
        throw new Error("扩展未返回有效的预览 token");
      }

      const launchResponse = await fetch(`${bridgeBaseURL}/launch`, {
        method: "POST",
        cache: "no-store",
        credentials: "omit",
        headers: {
          Authorization: `Bearer ${session.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ previewURL: previewPageURL }),
      });
      if (!launchResponse.ok) {
        let message = `启动失败（HTTP ${launchResponse.status}）`;
        try {
          const failure = await launchResponse.json();
          if (failure && typeof failure.message === "string") {
            message = failure.message;
          }
        } catch (_) {
          // 非 JSON 错误仍保留 HTTP 状态。
        }
        throw new Error(message);
      }
      globalThis.sessionStorage.setItem(launchMarkerKey, "true");
      setStatus(
        "启动请求已提交。请在 Cocos Creator 控制台查看资源预检、App 会话和运行日志。",
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStatus(`无法启动 Playmesh App：${message}`);
      console.error("[Playmesh] Cocos 自动预览启动失败", error);
    }
  })();
})();
