const tokenKey = "playmesh.admin.token";
const adminBase = window.location.pathname.replace(/\/+$/, "");
const adminURL = (path) => `${adminBase}${path}`;
let token = sessionStorage.getItem(tokenKey) || "";
let captchaId = "";
let selectedCaptcha = "";
let captchaMode = "";
let captchaRequiredClicks = 0;
let captchaClicks = [];
const adminState = { page: 1, size: 20, total: 0, games: [] };

const api = async (path, options = {}) => {
  const headers = new Headers(options.headers || {});
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body && !(options.body instanceof FormData)) headers.set("Content-Type", "application/json");
  const response = await fetch(adminURL(path), { ...options, headers });
  if (response.status === 401 && token) {
    token = ""; sessionStorage.removeItem(tokenKey); showLogin();
  }
  return response;
};
const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
})[character]);

async function loadCaptcha(delay = 0) {
  if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
  const response = await fetch(adminURL("/api/auth/captcha"));
  const notice = document.querySelector("#login-notice");
  if (!response.ok) {
    notice.textContent = response.status === 429 ? "验证码请求过于频繁，请稍后重试。" : "验证码加载失败";
    return;
  }
  const result = await response.json();
  captchaId = result.id;
  captchaMode = result.mode;
  captchaRequiredClicks = result.requiredClicks || 0;
  captchaClicks = [];
  selectedCaptcha = "";
  const prompt = document.querySelector("#captcha-prompt");
  const input = document.querySelector("#captcha-answer");
  const image = document.querySelector("#captcha-image");
  const promptImage = document.querySelector("#captcha-prompt-image");
  document.querySelector("#captcha-markers").replaceChildren();
  image.src = result.image;
  input.value = "";
  input.classList.toggle("hidden", result.mode === "text");
  if (result.mode === "text") {
    prompt.textContent = `请按提示图顺序点选主图中的 ${captchaRequiredClicks} 个字符`;
    promptImage.src = result.promptImage;
    promptImage.classList.remove("hidden");
  } else {
    prompt.textContent = "请输入图形中的计算结果";
    promptImage.removeAttribute("src");
    promptImage.classList.add("hidden");
  }
}

document.querySelector("#captcha-image").addEventListener("click", (event) => {
  if (captchaMode !== "text") return;
  const image = event.currentTarget;
  const bounds = image.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  if (captchaClicks.length >= captchaRequiredClicks) {
    captchaClicks = [];
    document.querySelector("#captcha-markers").replaceChildren();
  }
  const x = Math.floor((event.clientX - bounds.left) * image.naturalWidth / bounds.width);
  const y = Math.floor((event.clientY - bounds.top) * image.naturalHeight / bounds.height);
  captchaClicks.push([x, y]);
  selectedCaptcha = `click:${captchaClicks.map(([pointX, pointY]) => `${pointX},${pointY}`).join("|")}`;
  const marker = document.createElement("span");
  marker.className = "captcha-marker";
  marker.textContent = String(captchaClicks.length);
  marker.style.left = `${event.clientX - bounds.left}px`;
  marker.style.top = `${event.clientY - bounds.top}px`;
  document.querySelector("#captcha-markers").appendChild(marker);
  document.querySelector("#captcha-prompt").textContent =
    captchaClicks.length === captchaRequiredClicks
      ? "点选完成，可以登录；重新点击将清空并重选"
      : `还需按顺序点选 ${captchaRequiredClicks - captchaClicks.length} 个字符`;
});

document.querySelector("#refresh-captcha").addEventListener("click", () => loadCaptcha(1050));

document.querySelector("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  const notice = document.querySelector("#login-notice");
  const response = await fetch(adminURL("/api/auth/login"), {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      username: form.get("username"), password: form.get("password"),
      captchaId, captchaAnswer: selectedCaptcha || document.querySelector("#captcha-answer").value
    })
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    notice.className = "notice error";
    notice.textContent = result.message || "登录失败";
    await loadCaptcha(1050);
    return;
  }
  token = result.token; sessionStorage.setItem(tokenKey, token);
  showAdmin();
});

function showLogin() {
  document.querySelector("#login-view").classList.remove("hidden");
  document.querySelector("#admin-view").classList.add("hidden");
  loadCaptcha();
}
function showAdmin() {
  document.querySelector("#login-view").classList.add("hidden");
  document.querySelector("#admin-view").classList.remove("hidden");
  loadStats(); loadAdminGames(); loadSettings(); loadRuntimeConfig();
}

document.querySelectorAll("[data-section]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-section]").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    document.querySelectorAll(".admin-section").forEach((section) => section.classList.add("hidden"));
    document.querySelector(`#${button.dataset.section}-section`).classList.remove("hidden");
  });
});

async function loadStats() {
  if (!token) return;
  const response = await api("/api/admin/relay/stats");
  if (!response.ok) return;
  const stats = await response.json();
  const values = [
    ["临时隧道", `${stats.tunnels} / ${stats.maxTunnels}`],
    ["活跃配对", stats.activePairs],
    ["跟踪连接", stats.trackedConnections],
    ["累计传输", formatBytes(stats.bytesHostToClient + stats.bytesClientToHost)]
  ];
  document.querySelector("#stats").innerHTML = values.map(([label, value]) =>
    `<div class="stat"><span class="muted">${label}</span><strong>${value}</strong></div>`).join("");
  document.querySelector("#stats-time").textContent = `更新于 ${new Date(stats.updatedAt).toLocaleTimeString()}`;
}
const formatBytes = (value) => {
  if (value < 1024) return `${value} B`;
  if (value < 1024 ** 2) return `${(value / 1024).toFixed(1)} KiB`;
  if (value < 1024 ** 3) return `${(value / 1024 ** 2).toFixed(1)} MiB`;
  return `${(value / 1024 ** 3).toFixed(2)} GiB`;
};
setInterval(loadStats, 2000);

async function loadAdminGames() {
  if (!token) return;
  const params = new URLSearchParams({
    page: adminState.page, size: adminState.size,
    status: document.querySelector("#admin-status").value,
    search: document.querySelector("#admin-search").value
  });
  const response = await api(`/api/admin/games?${params}`);
  if (!response.ok) return;
  const result = await response.json();
  adminState.total = result.total; adminState.games = result.data;
  document.querySelector("#game-rows").innerHTML = result.data.map((game) => `
    <tr>
      <td data-label="游戏"><strong>${escapeHTML(game.name)}</strong><br><span class="muted">${escapeHTML(game.packageId)} · v${escapeHTML(game.version)}</span></td>
      <td data-label="作者 / 邮箱">${escapeHTML(game.author || "未署名")}<br><span class="muted">${escapeHTML(game.email)}</span></td>
      <td data-label="状态"><span class="badge ${game.status === "pending" ? "pending" : ""}">${statusName(game.status)}</span></td>
      <td data-label="扫描">${escapeHTML(game.scanStatus)}</td>
      <td data-label="上传时间">${new Date(game.createdAt).toLocaleString()}</td>
      <td data-label="操作"><div class="row-actions">
        <button data-action="detail" data-id="${game.id}" class="secondary">详情</button>
        ${game.storedPath === undefined && game.scanStatus === "clean" ? `<button data-action="download" data-id="${game.id}" class="secondary">原包</button>` : ""}
        ${game.status !== "approved" && game.scanStatus === "clean" ? `<button data-action="approve" data-id="${game.id}">通过</button>` : ""}
        ${game.status !== "rejected" ? `<button data-action="reject" data-id="${game.id}" class="warn">拒绝</button>` : ""}
        <button data-action="delete" data-id="${game.id}" class="danger">删除</button>
      </div></td>
    </tr>`).join("") || '<tr><td colspan="6" class="muted">没有符合条件的记录</td></tr>';
  const pages = Math.max(1, Math.ceil(result.total / adminState.size));
  document.querySelector("#admin-page").textContent = `${adminState.page} / ${pages}`;
  document.querySelector("#admin-previous").disabled = adminState.page <= 1;
  document.querySelector("#admin-next").disabled = adminState.page >= pages;
}
const statusName = (status) => ({ pending: "待审核", approved: "已通过", rejected: "已拒绝" })[status] || status;

document.querySelector("#game-rows").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-action]");
  if (!button) return;
  const id = button.dataset.id;
  const game = adminState.games.find((item) => String(item.id) === id);
  if (button.dataset.action === "detail") {
    document.querySelector("#detail-content").textContent = JSON.stringify({
      ...game, scanReport: parseJSON(game.scanReport)
    }, null, 2);
    document.querySelector("#detail-dialog").showModal();
    return;
  }
  if (button.dataset.action === "download") {
    const response = await api(`/api/admin/games/${id}/download`);
    if (!response.ok) return alert("原包不可用");
    const blob = await response.blob();
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob); link.download = `${game.packageId}-${game.version}.zip`;
    link.click(); URL.revokeObjectURL(link.href); return;
  }
  if (button.dataset.action === "delete" && !confirm("确认永久删除该记录和已保存的游戏包？")) return;
  if (button.dataset.action === "reject") {
    const reason = prompt("请输入拒绝原因");
    if (!reason) return;
    await api(`/api/admin/games/${id}`, { method: "PATCH", body: JSON.stringify({ status: "rejected", reason }) });
  } else if (button.dataset.action === "approve") {
    await api(`/api/admin/games/${id}`, { method: "PATCH", body: JSON.stringify({ status: "approved", reason: "" }) });
  } else if (button.dataset.action === "delete") {
    await api(`/api/admin/games/${id}`, { method: "DELETE" });
  }
  loadAdminGames();
});
const parseJSON = (value) => { try { return JSON.parse(value); } catch { return value; } };
document.querySelector("#close-dialog").addEventListener("click", () => document.querySelector("#detail-dialog").close());
document.querySelector("#admin-refresh").addEventListener("click", () => { adminState.page = 1; loadAdminGames(); });
document.querySelector("#admin-status").addEventListener("change", () => { adminState.page = 1; loadAdminGames(); });
let adminSearchTimer;
document.querySelector("#admin-search").addEventListener("input", () => {
  clearTimeout(adminSearchTimer); adminSearchTimer = setTimeout(() => { adminState.page = 1; loadAdminGames(); }, 300);
});
document.querySelector("#admin-previous").addEventListener("click", () => { if (adminState.page > 1) { adminState.page--; loadAdminGames(); } });
document.querySelector("#admin-next").addEventListener("click", () => { if (adminState.page * adminState.size < adminState.total) { adminState.page++; loadAdminGames(); } });

async function loadSettings() {
  if (!token) return;
  const response = await api("/api/admin/settings");
  if (!response.ok) return;
  const value = await response.json();
  const form = document.querySelector("#settings-form");
  form.elements.name.value = value.name || "";
  form.elements.author.value = value.author || "";
  form.elements.homepage.value = value.homepage || "";
  form.elements.supportsGameRelay.checked = value.supportsGameRelay;
}
document.querySelector("#settings-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const response = await api("/api/admin/settings", {
    method: "PUT", body: JSON.stringify({
      name: form.elements.name.value, author: form.elements.author.value,
      homepage: form.elements.homepage.value,
      supportsGameRelay: form.elements.supportsGameRelay.checked
    })
  });
  const notice = document.querySelector("#settings-notice");
  notice.className = response.ok ? "notice ok" : "notice error";
  notice.textContent = response.ok ? "游戏源声明已保存。" : "保存失败，请检查主页地址。";
});

async function loadRuntimeConfig() {
  if (!token) return;
  const response = await api("/api/admin/config");
  if (!response.ok) return;
  const result = await response.json();
  const value = result.config;
  const form = document.querySelector("#config-form");
  form.externalListen.value = value.externalListen;
  form.adminListen.value = value.admin.listen;
  form.showPublicSourceQRCode.checked = value.showPublicSourceQRCode;
  form.captchaMode.value = value.admin.captchaMode;
  form.sessionTTL.value = value.admin.sessionTtlMinutes;
  form.loginInterval.value = value.admin.loginIntervalMilliseconds;
  form.captchaInterval.value = value.admin.captchaIntervalMilliseconds;
  form.databasePath.value = value.storage.databasePath;
  form.gamesDirectory.value = value.storage.gamesDirectory;
  form.quarantineDirectory.value = value.storage.quarantineDirectory;
  form.maxUploadMiB.value = bytesToMiB(value.storage.maxUploadBytes);
  form.maxExpandedMiB.value = bytesToMiB(value.storage.maxExpandedBytes);
  form.maxFileMiB.value = bytesToMiB(value.storage.maxFileBytes);
  form.maxFiles.value = value.storage.maxFiles;
  form.maxRatio.value = value.storage.maxCompressionRatio;
  form.maxConcurrentScans.value = value.storage.maxConcurrentScans;
  form.uploadInterval.value = value.storage.publicUploadIntervalSeconds;
  form.clamScanPath.value = value.scanner.clamScanPath;
  form.scanRequired.checked = value.scanner.required;
  form.scanTimeout.value = value.scanner.timeoutSeconds;
  form.contentRules.value = JSON.stringify(value.scanner.contentRules, null, 2);
  form.relayBaseURL.value = value.relay.publicBaseUrl;
  document.querySelector("#public-page-link").href = value.relay.publicBaseUrl;
  form.tunnelTTL.value = value.relay.tunnelTTLSeconds;
  form.pendingTimeout.value = value.relay.pendingConnectionTimeoutSeconds;
  form.idleTimeout.value = value.relay.idleTimeoutSeconds;
  form.maxTunnels.value = value.relay.maxTunnels;
  form.maxPerTunnel.value = value.relay.maxConnectionsPerTunnel;
  form.maxPerIP.value = value.relay.maxConnectionsPerIP;
  form.supportsRelay.checked = value.supportsGameRelay;
  form.whitelist.value = JSON.stringify(value.authWhitelist, null, 2);
}
const bytesToMiB = (value) => Math.max(1, Math.round(value / 1024 / 1024));
const numeric = (form, name) => Number(form[name].value);

document.querySelector("#config-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const notice = document.querySelector("#config-notice");
  let whitelist;
  let contentRules;
  try {
    whitelist = JSON.parse(form.whitelist.value);
    if (!Array.isArray(whitelist)) throw new Error();
  } catch {
    notice.className = "notice error";
    notice.textContent = "鉴权白名单必须是 JSON 数组。";
    return;
  }
  try {
    contentRules = JSON.parse(form.contentRules.value);
    if (!Array.isArray(contentRules)) throw new Error();
  } catch {
    notice.className = "notice error";
    notice.textContent = "活动内容扫描规则必须是 JSON 数组。";
    return;
  }
  const payload = {
    externalListen: form.externalListen.value,
    supportsGameRelay: form.supportsRelay.checked,
    showPublicSourceQRCode: form.showPublicSourceQRCode.checked,
    authWhitelist: whitelist,
    admin: {
      listen: form.adminListen.value, captchaMode: form.captchaMode.value,
      sessionTtlMinutes: numeric(form, "sessionTTL"),
      loginIntervalMilliseconds: numeric(form, "loginInterval"),
      captchaIntervalMilliseconds: numeric(form, "captchaInterval")
    },
    storage: {
      databasePath: form.databasePath.value, gamesDirectory: form.gamesDirectory.value,
      quarantineDirectory: form.quarantineDirectory.value,
      maxUploadBytes: numeric(form, "maxUploadMiB") * 1024 * 1024,
      maxExpandedBytes: numeric(form, "maxExpandedMiB") * 1024 * 1024,
      maxFileBytes: numeric(form, "maxFileMiB") * 1024 * 1024,
      maxFiles: numeric(form, "maxFiles"), maxCompressionRatio: numeric(form, "maxRatio"),
      maxConcurrentScans: numeric(form, "maxConcurrentScans"),
      publicUploadIntervalSeconds: numeric(form, "uploadInterval")
    },
    scanner: {
      clamScanPath: form.clamScanPath.value, required: form.scanRequired.checked,
      timeoutSeconds: numeric(form, "scanTimeout"), contentRules
    },
    relay: {
      publicBaseUrl: form.relayBaseURL.value,
      tunnelTTLSeconds: numeric(form, "tunnelTTL"),
      pendingConnectionTimeoutSeconds: numeric(form, "pendingTimeout"),
      idleTimeoutSeconds: numeric(form, "idleTimeout"),
      maxTunnels: numeric(form, "maxTunnels"),
      maxConnectionsPerTunnel: numeric(form, "maxPerTunnel"),
      maxConnectionsPerIP: numeric(form, "maxPerIP")
    }
  };
  const response = await api("/api/admin/config", {
    method: "PUT", body: JSON.stringify(payload)
  });
  const result = await response.json().catch(() => ({}));
  notice.className = response.ok ? "notice ok" : "notice error";
  notice.textContent = result.message || (response.ok ? "运行配置已保存。" : "运行配置保存失败。");
});

document.querySelector("#logout").addEventListener("click", async () => {
  await api("/api/admin/logout", { method: "POST" });
  token = ""; sessionStorage.removeItem(tokenKey); showLogin();
});

if (token) showAdmin(); else showLogin();
