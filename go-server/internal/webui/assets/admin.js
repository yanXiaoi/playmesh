const tokenKey = "playmesh.admin.token";
const adminBase = window.location.pathname.replace(/\/+$/, "");
const adminURL = (path) => `${adminBase}${path}`;
let token = sessionStorage.getItem(tokenKey) || "";
let captchaId = "";
let pendingAdminLogin = null;
let adminCaptcha;
let adminCaptchaRefreshTimer = null;
const adminState = {
  page: 1, size: 20, total: 0, games: [],
  userPage: 1, userSize: 20, userTotal: 0, users: []
};
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
    window.PlaymeshMessage.error(at("error.unauthorized"));
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
  const manifest = await fetch(
    adminURL("/i18n/manifest"), { cache: "no-store" }
  ).then((response) => response.json());
  const available = manifest.locales.map((locale) => locale.id);
  const locale = resolveAdminLocale([
    localeOverride,
    localStorage.getItem("playmesh.locale"),
    ...(Array.isArray(navigator.languages) ? navigator.languages : []),
    navigator.language
  ], available, manifest.defaultLocale);
  adminMessages = await fetch(
    adminURL(`/i18n/${encodeURIComponent(locale)}`), { cache: "no-store" }
  )
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
}
document.querySelector("#admin-locale").addEventListener("change", async (event) => {
  localStorage.setItem("playmesh.locale", event.target.value);
  await loadAdminLocalization(event.target.value);
  if (token) {
    loadStats();
    loadAdminGames();
  } else if (document.querySelector("#admin-captcha-dialog").open) {
    adminCaptcha.relocalize();
  }
});

async function loadCaptcha(delay = 0, preserveNotice = false) {
  clearTimeout(adminCaptchaRefreshTimer);
  adminCaptchaRefreshTimer = null;
  captchaId = "";
  adminCaptcha.setLoading();
  if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
  let response;
  try {
    response = await fetch(adminURL("/api/auth/captcha"));
  } catch {
    const message = at("admin.captcha.failed");
    adminCaptcha.setError(message);
    if (!preserveNotice) window.PlaymeshMessage.error(message);
    return;
  }
  if (!response.ok) {
    const message = response.status === 429
      ? at("admin.captcha.rate_limited") : at("admin.captcha.failed");
    adminCaptcha.setError(message);
    if (!preserveNotice) window.PlaymeshMessage.error(message);
    if (response.status === 429) {
      const seconds = Number(response.headers.get("Retry-After")) || 1;
      adminCaptchaRefreshTimer = setTimeout(() => {
        if (document.querySelector("#admin-captcha-dialog").open) {
          loadCaptcha(0, preserveNotice);
        }
      }, Math.min(60, Math.max(1, seconds)) * 1000);
    }
    return;
  }
  const result = await response.json();
  captchaId = result.id;
  adminCaptcha.load(result);
}

function closeAdminCaptcha(cancelPending = true) {
  clearTimeout(adminCaptchaRefreshTimer);
  adminCaptchaRefreshTimer = null;
  captchaId = "";
  adminCaptcha.clear();
  const dialog = document.querySelector("#admin-captcha-dialog");
  if (dialog.open) dialog.close();
  if (cancelPending) pendingAdminLogin = null;
}

adminCaptcha = new window.PlaymeshCaptcha(
  document.querySelector("#admin-captcha-widget"),
  at,
  {
    refresh: () => loadCaptcha(1050),
    close: () => closeAdminCaptcha(),
    confirm: (answer, reset) => verifyAdminCaptcha(answer, reset)
  }
);

document.querySelector("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  pendingAdminLogin = Object.fromEntries(new FormData(event.currentTarget).entries());
  const dialog = document.querySelector("#admin-captcha-dialog");
  if (!dialog.open) dialog.showModal();
  await loadCaptcha();
});

document.querySelector("#admin-captcha-dialog").addEventListener("cancel", () => {
  closeAdminCaptcha();
});

async function verifyAdminCaptcha(answer, reset) {
  if (!pendingAdminLogin || !captchaId) return;
  let verified;
  try {
    const verifyResponse = await fetch(adminURL("/api/auth/captcha/verify"), {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: captchaId,
        answer
      })
    });
    verified = await verifyResponse.json().catch(() => ({}));
    if (!verifyResponse.ok) {
      throw Object.assign(new Error("captcha_verification_failed"), {
        response: verifyResponse,
        result: verified
      });
    }
  } catch (error) {
    window.PlaymeshMessage.error(localizedAdminError(error.result));
    reset?.();
    const response = error.response;
    const rateLimited = response?.status === 429;
    const seconds = rateLimited
      ? Number(response.headers.get("Retry-After")) || 1 : 0;
    await loadCaptcha(
      rateLimited ? Math.min(60, Math.max(1, seconds)) * 1000 : 1050,
      true
    );
    return;
  }

  closeAdminCaptcha(false);
  try {
    const response = await fetch(adminURL("/api/auth/login"), {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: pendingAdminLogin.username,
        password: pendingAdminLogin.password,
        captchaToken: verified.captchaToken
      })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw Object.assign(new Error("admin_login_failed"), { result });
    }
    token = result.token;
    sessionStorage.setItem(tokenKey, token);
    pendingAdminLogin = null;
    showAdmin();
    window.PlaymeshMessage.success(at("admin.login.success"));
  } catch (error) {
    window.PlaymeshMessage.error(localizedAdminError(error.result), 4200);
    pendingAdminLogin = null;
  }
}

function showLogin() {
  document.querySelector("#login-view").classList.remove("hidden");
  document.querySelector("#admin-view").classList.add("hidden");
}
function showAdmin() {
  document.querySelector("#login-view").classList.add("hidden");
  document.querySelector("#admin-view").classList.remove("hidden");
  loadStats(); loadUsers(); loadAdminGames(); loadSettings(); loadRuntimeConfig();
}

document.querySelectorAll("[data-section]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-section]").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    document.querySelectorAll(".admin-section").forEach((section) => section.classList.add("hidden"));
    document.querySelector(`#${button.dataset.section}-section`).classList.remove("hidden");
    if (button.dataset.section === "users") loadUsers();
    if (button.dataset.section === "games") loadAdminGames();
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

async function loadUsers() {
  if (!token) return;
  const params = new URLSearchParams({
    page: adminState.userPage,
    size: adminState.userSize,
    status: document.querySelector("#admin-user-status").value,
    search: document.querySelector("#admin-user-search").value
  });
  const response = await api(`/api/admin/users?${params}`);
  if (!response.ok) return;
  const result = await response.json();
  adminState.userTotal = result.total;
  adminState.users = result.data;
  document.querySelector("#user-rows").innerHTML = result.data.map((user) => `
    <tr>
      <td data-label="${escapeHTML(at("admin.users.account"))}">
        <strong>${escapeHTML(user.displayName)}</strong><br>
        <span class="muted">${escapeHTML(user.email)}</span>
      </td>
      <td data-label="${escapeHTML(at("admin.users.status"))}">
        <span class="badge ${user.status === "disabled" ? "rejected" : ""}">
          ${escapeHTML(at(`admin.users.${user.status === "pending_verification" ? "pending" : user.status}`, user.status))}
        </span>
        ${user.disabledReason ? `<br><small class="muted">${escapeHTML(user.disabledReason)}</small>` : ""}
      </td>
      <td data-label="${escapeHTML(at("admin.users.games"))}">
        ${escapeHTML(at("admin.users.game_count", "", {
          total: user.gameCount, published: user.publishedCount
        }))}
      </td>
      <td data-label="${escapeHTML(at("admin.users.created_at"))}">
        ${new Date(user.createdAt).toLocaleString(document.documentElement.lang)}
      </td>
      <td data-label="${escapeHTML(at("common.actions"))}"><div class="row-actions">
        ${user.status === "disabled"
          ? `<button data-user-action="enable" data-id="${user.id}">${escapeHTML(at("admin.users.enable"))}</button>`
          : `<button data-user-action="disable" data-id="${user.id}" class="warn">${escapeHTML(at("admin.users.disable"))}</button>`}
        <button data-user-action="delete" data-id="${user.id}" class="danger">${escapeHTML(at("common.delete"))}</button>
      </div></td>
    </tr>
  `).join("") || `<tr><td colspan="5" class="muted">${escapeHTML(at("admin.users.empty"))}</td></tr>`;
  const pages = Math.max(1, Math.ceil(result.total / adminState.userSize));
  document.querySelector("#admin-user-page").textContent = at("common.page", "", {
    current: adminState.userPage, pages
  });
  document.querySelector("#admin-user-previous").disabled = adminState.userPage <= 1;
  document.querySelector("#admin-user-next").disabled = adminState.userPage >= pages;
}

async function performUserAction(action, id, reason = "") {
  let response;
  if (action === "delete") {
    response = await api(`/api/admin/users/${id}`, { method: "DELETE" });
  } else {
    response = await api(`/api/admin/users/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ disabled: action === "disable", reason })
    });
  }
  if (response.status === 401) return;
  if (!response.ok) {
    const result = await response.json().catch(() => ({}));
    window.PlaymeshMessage.error(localizedAdminError(result));
    return;
  }
  window.PlaymeshMessage.success(at(`admin.users.${action}_success`));
  await loadUsers();
}

document.querySelector("#user-rows").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-user-action]");
  if (!button) return;
  const action = button.dataset.userAction;
  const id = button.dataset.id;
  if (action === "disable") {
    openReasonDialog("admin.users.disable_reason", (reason) =>
      performUserAction(action, id, reason));
    return;
  }
  if (action === "delete" && !confirm(at("admin.users.confirm_delete"))) return;
  try {
    await performUserAction(action, id);
  } catch {
    window.PlaymeshMessage.error(at("error.generic"));
  }
});

document.querySelector("#admin-add-user").addEventListener("click", () => {
  document.querySelector("#create-user-dialog").showModal();
});
document.querySelector("#create-user-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  try {
    const response = await api("/api/admin/users", {
      method: "POST",
      body: JSON.stringify({
        email: form.email.value,
        displayName: form.displayName.value,
        password: form.password.value,
        disabled: form.disabled.checked
      })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      window.PlaymeshMessage.error(localizedAdminError(result));
      return;
    }
    form.reset();
    document.querySelector("#create-user-dialog").close();
    window.PlaymeshMessage.success(at("admin.users.create_success"));
    await loadUsers();
  } catch {
    window.PlaymeshMessage.error(at("error.generic"));
  }
});

document.querySelector("#admin-user-refresh").addEventListener("click", () => {
  adminState.userPage = 1; loadUsers();
});
document.querySelector("#admin-user-status").addEventListener("change", () => {
  adminState.userPage = 1; loadUsers();
});
let adminUserSearchTimer;
document.querySelector("#admin-user-search").addEventListener("input", () => {
  clearTimeout(adminUserSearchTimer);
  adminUserSearchTimer = setTimeout(() => {
    adminState.userPage = 1; loadUsers();
  }, 300);
});
document.querySelector("#admin-user-previous").addEventListener("click", () => {
  if (adminState.userPage > 1) { adminState.userPage--; loadUsers(); }
});
document.querySelector("#admin-user-next").addEventListener("click", () => {
  if (adminState.userPage * adminState.userSize < adminState.userTotal) {
    adminState.userPage++; loadUsers();
  }
});

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
    try {
      const response = await api(`/api/admin/games/${id}/download`);
      if (!response.ok) {
        window.PlaymeshMessage.error(at("admin.games.package_unavailable"));
        return;
      }
      const blob = await response.blob();
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob); link.download = `${game.packageId}-${game.version}.zip`;
      link.click(); URL.revokeObjectURL(link.href);
    } catch {
      window.PlaymeshMessage.error(at("admin.games.package_unavailable"));
    }
    return;
  }
  const action = button.dataset.action;
  if (action === "delete" && !confirm(at("admin.games.confirm_delete"))) return;
  if (["reject", "unpublish", "delete"].includes(action)) {
    openReasonDialog(`admin.games.${action}_reason`, (reason) =>
      performGameAction(action, id, reason));
    return;
  }
  await performGameAction(action, id);
});

async function performGameAction(action, id, reason = "") {
  try {
    let response;
    if (action === "approve" || action === "reject") {
      response = await api(`/api/admin/games/${id}`, {
        method: "PATCH",
        body: JSON.stringify({
          status: action === "approve" ? "approved" : "rejected",
          reason
        })
      });
    } else if (action === "publish" || action === "unpublish") {
      response = await api(`/api/admin/games/${id}/${action}`, {
        method: "POST",
        ...(action === "unpublish" ? { body: JSON.stringify({ reason }) } : {})
      });
    } else if (action === "delete") {
      response = await api(`/api/admin/games/${id}`, {
        method: "DELETE", body: JSON.stringify({ reason })
      });
    }
    if (!response || response.status === 401) return;
    if (!response.ok) {
      const result = await response.json().catch(() => ({}));
      window.PlaymeshMessage.error(localizedAdminError(result));
      return;
    }
    window.PlaymeshMessage.success(at(`admin.games.${action}_success`));
    await loadAdminGames();
    await loadUsers();
  } catch {
    window.PlaymeshMessage.error(at("error.generic"));
  }
}

let pendingReasonAction = null;
function openReasonDialog(titleKey, action) {
  pendingReasonAction = action;
  document.querySelector("#admin-reason-title").textContent = at(titleKey);
  const form = document.querySelector("#admin-reason-form");
  form.reset();
  document.querySelector("#admin-reason-dialog").showModal();
}
document.querySelector("#admin-reason-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const action = pendingReasonAction;
  if (!action) return;
  const reason = event.currentTarget.reason.value.trim();
  if (!reason) return;
  pendingReasonAction = null;
  document.querySelector("#admin-reason-dialog").close();
  await action(reason);
});
document.querySelectorAll("[data-close-admin-dialog]").forEach((button) => {
  button.addEventListener("click", () => {
    pendingReasonAction = null;
    button.closest("dialog").close();
  });
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
  try {
    const response = await api("/api/admin/settings", {
      method: "PUT", body: JSON.stringify({
        name: form.elements.name.value, author: form.elements.author.value,
        homepage: form.elements.homepage.value,
        supportsGameRelay: form.elements.supportsGameRelay.checked
      })
    });
    if (response.status === 401) return;
    window.PlaymeshMessage[response.ok ? "success" : "error"](
      response.ok ? at("admin.settings.saved") : at("admin.settings.save_failed")
    );
  } catch {
    window.PlaymeshMessage.error(at("admin.settings.save_failed"));
  }
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
  form.sessionTTL.value = value.admin.sessionTtlMinutes;
  form.loginInterval.value = value.admin.loginIntervalMilliseconds;
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
  form.maxTunnels.value = value.relay.maxTunnels;
  form.maxPerTunnel.value = value.relay.maxConnectionsPerTunnel;
  form.maxPerIP.value = value.relay.maxConnectionsPerIP;
  form.turnUdpListen.value = value.relay.turnUdpListen;
  form.turnTcpListen.value = value.relay.turnTcpListen;
  form.turnPublicIp.value = value.relay.turnPublicIp;
  form.turnPublicPort.value = value.relay.turnPublicPort;
  form.turnRealm.value = value.relay.turnRealm;
  form.turnMinPort.value = value.relay.turnMinPort;
  form.turnMaxPort.value = value.relay.turnMaxPort;
  form.supportsRelay.checked = value.supportsGameRelay;
  form.whitelist.value = JSON.stringify(value.authWhitelist, null, 2);
}
const bytesToMiB = (value) => Math.max(1, Math.round(value / 1024 / 1024));
const numeric = (form, name) => Number(form[name].value);

document.querySelector("#config-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  let whitelist;
  let contentRules;
  try {
    whitelist = JSON.parse(form.whitelist.value);
    if (!Array.isArray(whitelist)) throw new Error();
  } catch {
    window.PlaymeshMessage.error(at("admin.config.whitelist_invalid"));
    return;
  }
  try {
    contentRules = JSON.parse(form.contentRules.value);
    if (!Array.isArray(contentRules)) throw new Error();
  } catch {
    window.PlaymeshMessage.error(at("admin.config.rules_invalid"));
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
      listen: form.adminListen.value,
      sessionTtlMinutes: numeric(form, "sessionTTL"),
      loginIntervalMilliseconds: numeric(form, "loginInterval")
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
      maxTunnels: numeric(form, "maxTunnels"),
      maxConnectionsPerTunnel: numeric(form, "maxPerTunnel"),
      maxConnectionsPerIP: numeric(form, "maxPerIP"),
      turnUdpListen: form.turnUdpListen.value,
      turnTcpListen: form.turnTcpListen.value,
      turnPublicIp: form.turnPublicIp.value,
      turnPublicPort: numeric(form, "turnPublicPort"),
      turnRealm: form.turnRealm.value,
      turnMinPort: numeric(form, "turnMinPort"),
      turnMaxPort: numeric(form, "turnMaxPort")
    }
  };
  try {
    const response = await api("/api/admin/config", {
      method: "PUT", body: JSON.stringify(payload)
    });
    if (response.status === 401) return;
    const result = await response.json().catch(() => ({}));
    window.PlaymeshMessage[response.ok ? "success" : "error"](
      response.ok ? at("admin.config.saved") : localizedAdminError(result)
    );
  } catch {
    window.PlaymeshMessage.error(at("error.config_save_failed"));
  }
});

document.querySelector("#logout").addEventListener("click", async () => {
  try {
    const response = await api("/api/admin/logout", { method: "POST" });
    if (!response.ok && response.status !== 401) {
      window.PlaymeshMessage.error(at("error.generic"));
      return;
    }
    token = ""; sessionStorage.removeItem(tokenKey); showLogin();
    window.PlaymeshMessage.success(at("admin.logout_success"));
  } catch {
    window.PlaymeshMessage.error(at("error.generic"));
  }
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
