const tokenKey = "playmesh.admin.token";
const adminBase = window.location.pathname.replace(/\/+$/, "");
const adminURL = (path) => `${adminBase}${path}`;
let token = sessionStorage.getItem(tokenKey) || "";
let captchaId = "";
let selectedCaptcha = "";
let captchaMode = "";
let captchaRequiredClicks = 0;
let captchaClicks = [];
let captchaCursor = { x: 0, y: 0 };
const adminState = { page: 1, size: 20, total: 0, games: [] };
let adminMessages = {};
const at = (key, fallback, variables = {}) => {
  const template = adminMessages[key] || fallback || key;
  return Object.entries(variables).reduce(
    (value, [name, replacement]) => value.replaceAll(`{${name}}`, String(replacement)),
    template
  );
};

function localizeAdminDocument() {
  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = at(element.dataset.i18n);
  });
  for (const [attribute, datasetName] of [
    ["placeholder", "i18nPlaceholder"], ["aria-label", "i18nAria"],
    ["alt", "i18nAlt"], ["title", "i18nTitle"]
  ]) {
    document.querySelectorAll(`[data-${datasetName.replace(/[A-Z]/g, (value) => `-${value.toLowerCase()}`)}]`)
      .forEach((element) => element.setAttribute(
        attribute, at(element.dataset[datasetName])
      ));
  }
  document.querySelectorAll("[data-i18n-label]").forEach((element) => {
    let textNode = [...element.childNodes].find(
      (node) => node.nodeType === Node.TEXT_NODE
    );
    if (!textNode) {
      textNode = document.createTextNode("");
      element.prepend(textNode);
    }
    textNode.nodeValue = at(element.dataset.i18nLabel);
  });
}

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
const localizedAdminError = (result = {}) =>
  at(
    `error.${result.code || result.error || "generic"}`,
    result.message || at("error.generic")
  );
const adminColorScheme = matchMedia("(prefers-color-scheme: dark)");

function applyAdminTheme(mode) {
  const normalized = ["system", "light", "dark"].includes(mode) ? mode : "system";
  document.documentElement.dataset.theme =
    normalized === "system" ? (adminColorScheme.matches ? "dark" : "light") : normalized;
  const button = document.querySelector("#admin-theme");
  button.dataset.mode = normalized;
  button.textContent = {
    system: at("theme.system"),
    light: at("theme.light"),
    dark: at("theme.dark")
  }[normalized];
}

adminColorScheme.addEventListener("change", () => {
  if (document.querySelector("#admin-theme").dataset.mode === "system") {
    applyAdminTheme("system");
  }
});

function resolveAdminLocale(preferences, available, fallback) {
  for (const preference of preferences) {
    const normalized = String(preference || "").trim();
    if (!normalized) continue;
    const exact = available.find(
      (candidate) => candidate.toLowerCase() === normalized.toLowerCase()
    );
    if (exact) return exact;
    const primary = normalized.split("-")[0].toLowerCase();
    const primaryMatch = available.find(
      (candidate) => candidate.split("-")[0].toLowerCase() === primary
    );
    if (primaryMatch) return primaryMatch;
  }
  return fallback;
}

async function loadAdminLocalization(localeOverride) {
  const manifest = await fetch(adminURL("/i18n/manifest")).then((response) => response.json());
  const available = manifest.locales.map((locale) => locale.id);
  const locale = resolveAdminLocale([
    localeOverride,
    localStorage.getItem("playmesh.locale"),
    ...(Array.isArray(navigator.languages) ? navigator.languages : []),
    navigator.language
  ], available, manifest.defaultLocale);
  adminMessages = await fetch(adminURL(`/i18n/${encodeURIComponent(locale)}`))
    .then((response) => response.json());
  document.documentElement.lang = locale;
  localizeAdminDocument();
  const select = document.querySelector("#admin-locale");
  select.replaceChildren(...manifest.locales.map((item) => {
    const option = document.createElement("option");
    option.value = item.id; option.textContent = item.label; option.selected = item.id === locale;
    return option;
  }));
  select.classList.toggle("hidden", !manifest.allowLocaleSwitch);
  document.querySelector("#admin-theme").classList.toggle("hidden", !manifest.allowThemeSwitch);
  applyAdminTheme(localStorage.getItem("playmesh.theme") || manifest.defaultThemeMode);
}
document.querySelector("#admin-locale").addEventListener("change", async (event) => {
  localStorage.setItem("playmesh.locale", event.target.value);
  await loadAdminLocalization(event.target.value);
  if (token) {
    loadStats();
    loadAdminGames();
  } else if (captchaMode === "text") {
    document.querySelector("#captcha-prompt").textContent =
      at("admin.captcha.select_prompt", "", { count: captchaRequiredClicks });
  } else if (captchaMode === "math") {
    document.querySelector("#captcha-prompt").textContent = at("admin.captcha.math_prompt");
  }
});
document.querySelector("#admin-theme").addEventListener("click", () => {
  const modes = ["system", "light", "dark"];
  const current = document.querySelector("#admin-theme").dataset.mode || "system";
  const next = modes[(modes.indexOf(current) + 1) % modes.length];
  localStorage.setItem("playmesh.theme", next);
  applyAdminTheme(next);
});
applyAdminTheme(localStorage.getItem("playmesh.theme") || "system");

async function loadCaptcha(delay = 0) {
  if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
  const response = await fetch(adminURL("/api/auth/captcha"));
  const notice = document.querySelector("#login-notice");
  if (!response.ok) {
    notice.textContent = response.status === 429
      ? at("admin.captcha.rate_limited") : at("admin.captcha.failed");
    return;
  }
  const result = await response.json();
  captchaId = result.id;
  captchaMode = result.mode;
  captchaRequiredClicks = result.requiredClicks || 0;
  captchaClicks = [];
  captchaCursor = { x: 0, y: 0 };
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
    prompt.textContent = at("admin.captcha.select_prompt", "", {
      count: captchaRequiredClicks
    });
    promptImage.src = result.promptImage;
    promptImage.classList.remove("hidden");
  } else {
    prompt.textContent = at("admin.captcha.math_prompt");
    promptImage.removeAttribute("src");
    promptImage.classList.add("hidden");
  }
}

function selectCaptchaPoint(image, x, y) {
  const bounds = image.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  if (captchaClicks.length >= captchaRequiredClicks) {
    captchaClicks = [];
    document.querySelector("#captcha-markers").replaceChildren();
  }
  captchaClicks.push([x, y]);
  selectedCaptcha = `click:${captchaClicks.map(([pointX, pointY]) => `${pointX},${pointY}`).join("|")}`;
  const marker = document.createElement("span");
  marker.className = "captcha-marker";
  marker.textContent = String(captchaClicks.length);
  marker.style.left = `${x * bounds.width / image.naturalWidth}px`;
  marker.style.top = `${y * bounds.height / image.naturalHeight}px`;
  document.querySelector("#captcha-markers").appendChild(marker);
  document.querySelector("#captcha-prompt").textContent =
    captchaClicks.length === captchaRequiredClicks
      ? at("admin.captcha.selection_complete")
      : at("admin.captcha.selection_remaining", "", {
        count: captchaRequiredClicks - captchaClicks.length
      });
}

function renderCaptchaCursor(image) {
  const bounds = image.getBoundingClientRect();
  if (!bounds.width || !bounds.height || !image.naturalWidth || !image.naturalHeight) return;
  let marker = document.querySelector(".captcha-cursor");
  if (!marker) {
    marker = document.createElement("span");
    marker.className = "captcha-marker captcha-cursor";
    marker.setAttribute("aria-hidden", "true");
    document.querySelector("#captcha-markers").appendChild(marker);
  }
  marker.style.left = `${captchaCursor.x * bounds.width / image.naturalWidth}px`;
  marker.style.top = `${captchaCursor.y * bounds.height / image.naturalHeight}px`;
}

document.querySelector("#captcha-image").addEventListener("click", (event) => {
  if (captchaMode !== "text") return;
  const image = event.currentTarget;
  const bounds = image.getBoundingClientRect();
  const x = Math.floor((event.clientX - bounds.left) * image.naturalWidth / bounds.width);
  const y = Math.floor((event.clientY - bounds.top) * image.naturalHeight / bounds.height);
  selectCaptchaPoint(image, x, y);
});

document.querySelector("#captcha-image").addEventListener("keydown", (event) => {
  if (captchaMode !== "text") return;
  const image = event.currentTarget;
  if (!captchaCursor.x && !captchaCursor.y) {
    captchaCursor = {
      x: Math.floor(image.naturalWidth / 2),
      y: Math.floor(image.naturalHeight / 2)
    };
  }
  const step = event.shiftKey ? 2 : 10;
  if (event.key === "ArrowLeft") captchaCursor.x -= step;
  else if (event.key === "ArrowRight") captchaCursor.x += step;
  else if (event.key === "ArrowUp") captchaCursor.y -= step;
  else if (event.key === "ArrowDown") captchaCursor.y += step;
  else if (event.key === "Enter" || event.key === " ") {
    selectCaptchaPoint(image, captchaCursor.x, captchaCursor.y);
  } else {
    return;
  }
  event.preventDefault();
  captchaCursor.x = Math.max(0, Math.min(image.naturalWidth - 1, captchaCursor.x));
  captchaCursor.y = Math.max(0, Math.min(image.naturalHeight - 1, captchaCursor.y));
  renderCaptchaCursor(image);
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
    notice.textContent = localizedAdminError(result);
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
    [at("admin.stats.tunnels"), `${stats.tunnels} / ${stats.maxTunnels}`],
    [at("admin.stats.active_pairs"), stats.activePairs],
    [at("admin.stats.connections"), stats.trackedConnections],
    [at("admin.stats.bytes"), formatBytes(stats.bytesHostToClient + stats.bytesClientToHost)]
  ];
  document.querySelector("#stats").innerHTML = values.map(([label, value]) =>
    `<div class="stat"><span class="muted">${label}</span><strong>${value}</strong></div>`).join("");
  document.querySelector("#stats-time").textContent = at("admin.stats.updated", "", {
    time: new Date(stats.updatedAt).toLocaleTimeString(document.documentElement.lang)
  });
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
      <td data-label="${escapeHTML(at("admin.games.game"))}"><strong>${escapeHTML(game.name)}</strong><br><span class="muted">${escapeHTML(game.packageId)} · v${escapeHTML(game.version)}</span></td>
      <td data-label="${escapeHTML(at("admin.games.publisher_account"))}">${escapeHTML(game.author || at("catalog.unsigned"))}<br><span class="muted">${escapeHTML(game.email)}</span></td>
      <td data-label="${escapeHTML(at("games.status"))}"><span class="badge ${game.status === "pending" ? "pending" : ""}">${escapeHTML(statusName(game.status))} · ${escapeHTML(game.published ? at("games.published") : at("games.unpublished"))}</span></td>
      <td data-label="${escapeHTML(at("admin.games.scan"))}">${escapeHTML(at(`scan.${game.scanStatus}`, game.scanStatus))}</td>
      <td data-label="${escapeHTML(at("admin.games.uploaded_at"))}">${new Date(game.createdAt).toLocaleString(document.documentElement.lang)}</td>
      <td data-label="${escapeHTML(at("common.actions"))}"><div class="row-actions">
        <button data-action="detail" data-id="${game.id}" class="secondary">${escapeHTML(at("common.details"))}</button>
        ${game.status !== "deleting" && game.storedPath === undefined && game.scanStatus === "clean" ? `<button data-action="download" data-id="${game.id}" class="secondary">${escapeHTML(at("admin.games.package"))}</button>` : ""}
        ${game.status === "pending" && game.scanStatus === "clean" ? `<button data-action="approve" data-id="${game.id}">${escapeHTML(at("admin.games.approve"))}</button>` : ""}
        ${game.status === "pending" ? `<button data-action="reject" data-id="${game.id}" class="warn">${escapeHTML(at("admin.games.reject"))}</button>` : ""}
        ${game.status === "approved" && !game.published ? `<button data-action="publish" data-id="${game.id}">${escapeHTML(at("games.publish"))}</button>` : ""}
        ${game.status === "approved" && game.published ? `<button data-action="unpublish" data-id="${game.id}" class="secondary">${escapeHTML(at("games.unpublish"))}</button>` : ""}
        ${!game.published && game.status !== "deleting" ? `<button data-action="delete" data-id="${game.id}" class="danger">${escapeHTML(at("common.delete"))}</button>` : ""}
      </div></td>
    </tr>`).join("") || `<tr><td colspan="6" class="muted">${escapeHTML(at("admin.games.empty"))}</td></tr>`;
  const pages = Math.max(1, Math.ceil(result.total / adminState.size));
  document.querySelector("#admin-page").textContent = at("common.page", "", {
    current: adminState.page, pages
  });
  document.querySelector("#admin-previous").disabled = adminState.page <= 1;
  document.querySelector("#admin-next").disabled = adminState.page >= pages;
}
const statusName = (status) => at(`games.${status}`, status);

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
    if (!response.ok) return alert(at("admin.games.package_unavailable"));
    const blob = await response.blob();
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob); link.download = `${game.packageId}-${game.version}.zip`;
    link.click(); URL.revokeObjectURL(link.href); return;
  }
  if (button.dataset.action === "delete" && !confirm(at("admin.games.confirm_delete"))) return;
  if (button.dataset.action === "reject") {
    const reason = prompt(at("admin.games.reject_reason"));
    if (!reason) return;
    await api(`/api/admin/games/${id}`, { method: "PATCH", body: JSON.stringify({ status: "rejected", reason }) });
  } else if (button.dataset.action === "approve") {
    await api(`/api/admin/games/${id}`, { method: "PATCH", body: JSON.stringify({ status: "approved", reason: "" }) });
  } else if (button.dataset.action === "publish" || button.dataset.action === "unpublish") {
    await api(`/api/admin/games/${id}/${button.dataset.action}`, { method: "POST" });
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
  notice.textContent = response.ok
    ? at("admin.settings.saved") : at("admin.settings.save_failed");
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
  form.allowUserRegistration.checked = value.allowUserRegistration;
  form.requireEmailVerification.checked = value.requireEmailVerification;
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
    notice.textContent = at("admin.config.whitelist_invalid");
    return;
  }
  try {
    contentRules = JSON.parse(form.contentRules.value);
    if (!Array.isArray(contentRules)) throw new Error();
  } catch {
    notice.className = "notice error";
    notice.textContent = at("admin.config.rules_invalid");
    return;
  }
  const payload = {
    externalListen: form.externalListen.value,
    supportsGameRelay: form.supportsRelay.checked,
    showPublicSourceQRCode: form.showPublicSourceQRCode.checked,
    allowUserRegistration: form.allowUserRegistration.checked,
    requireEmailVerification: form.requireEmailVerification.checked,
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
  notice.textContent = response.ok
    ? at("admin.config.saved") : localizedAdminError(result);
});

document.querySelector("#logout").addEventListener("click", async () => {
  await api("/api/admin/logout", { method: "POST" });
  token = ""; sessionStorage.removeItem(tokenKey); showLogin();
});

async function initializeAdmin() {
  try {
    await loadAdminLocalization();
    if (token) showAdmin(); else showLogin();
  } finally {
    window.__playmeshRevealUI?.();
  }
}
initializeAdmin();
