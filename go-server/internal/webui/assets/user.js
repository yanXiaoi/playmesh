const state = {
  page: 1, size: 12, total: 0, csrfToken: "", user: null,
  captcha: { id: "", kind: "" }, pendingAuth: null, registrationAllowed: true,
  captchaRefreshTimer: null,
  registrationRequiresVerification: false,
  messages: {}, ui: null, view: "home"
};
state.csrfToken = decodeURIComponent(
  document.cookie.split("; ").find((value) => value.startsWith("playmesh_csrf="))?.split("=")[1] || ""
);
const games = document.querySelector("#games");
const filters = document.querySelector("#filters");
const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
})[character]);
const t = (key, fallback, variables = {}) => {
  const template = state.messages[key] || fallback || key;
  return Object.entries(variables).reduce(
    (value, [name, replacement]) => value.replaceAll(`{${name}}`, String(replacement)),
    template
  );
};
function localizeDocument() {
  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = t(element.dataset.i18n);
  });
  for (const [attribute, datasetName] of [
    ["placeholder", "i18nPlaceholder"], ["aria-label", "i18nAria"],
    ["alt", "i18nAlt"], ["title", "i18nTitle"]
  ]) {
    document.querySelectorAll(`[data-${datasetName.replace(/[A-Z]/g, (value) => `-${value.toLowerCase()}`)}]`)
      .forEach((element) => element.setAttribute(
        attribute, t(element.dataset[datasetName])
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
    textNode.nodeValue = t(element.dataset.i18nLabel);
  });
}

function resolveLocale(preferences, available, fallback) {
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

async function loadLocalization(localeOverride) {
  const manifest = state.ui || await fetch(
    "/i18n/manifest", { cache: "no-store" }
  ).then((response) => response.json());
  state.ui = manifest;
  const available = manifest.locales.map((locale) => locale.id);
  const locale = resolveLocale([
    localeOverride,
    localStorage.getItem("playmesh.locale"),
    ...(Array.isArray(navigator.languages) ? navigator.languages : []),
    navigator.language
  ], available, manifest.defaultLocale);
  state.messages = await fetch(
    `/i18n/${encodeURIComponent(locale)}`, { cache: "no-store" }
  ).then((response) => response.json());
  document.documentElement.lang = locale;
  localizeDocument();
  const select = document.querySelector("#locale-select");
  select.replaceChildren(...manifest.locales.map((item) => {
    const option = document.createElement("option");
    option.value = item.id; option.textContent = item.label; option.selected = item.id === locale;
    return option;
  }));
  select.classList.toggle("hidden", !manifest.allowLocaleSwitch);
}
document.querySelector("#locale-select").addEventListener("change", async (event) => {
  localStorage.setItem("playmesh.locale", event.target.value);
  await loadLocalization(event.target.value);
  if (state.view === "home") await loadSourceInfo();
  if (state.view === "games") await loadGames();
  if (state.view === "my") {
    await loadRegistrationState();
    if (state.user) {
      await loadMyGames();
      await loadNotifications();
    }
  }
  if (document.querySelector("#auth-captcha-dialog").open) {
    userCaptcha?.relocalize();
  }
});

async function jsonRequest(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.csrfToken && options.method && options.method !== "GET") {
    headers.set("X-CSRF-Token", state.csrfToken);
  }
  if (options.body && !(options.body instanceof FormData)) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...options, headers });
  const result = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error("request_failed"), { response, result });
  return result;
}

async function copyValue(targetId) {
  const input = document.querySelector(`#${targetId}`);
  if (!input?.value) return;
  try {
    await navigator.clipboard.writeText(input.value);
    window.PlaymeshMessage.success(t("user.source.copied"));
  } catch {
    window.PlaymeshMessage.error(t("error.copy_failed"));
  }
}
function localizedError(error) {
  const code = error?.result?.code || error?.result?.error || "generic";
  return t(`error.${code}`, error?.result?.message || t("error.generic"));
}
document.querySelectorAll("[data-copy-target]").forEach((button) =>
  button.addEventListener("click", () => copyValue(button.dataset.copyTarget)));

async function loadSourceInfo() {
  try {
    const result = await jsonRequest("/api/public/source-info");
    document.querySelector("#public-source-url").value = result.publicURL || "";
    document.querySelector("#source-info-notice").textContent = t("user.source.ready");
  } catch {
    document.querySelector("#source-info-notice").textContent = t("user.source.failed");
  }
  const image = document.querySelector("#source-qr-image");
  image.addEventListener("load", () => image.classList.remove("hidden"), { once: true });
  image.src = "/api/public/source-qrcode";
}

let userCaptcha;
async function loadCaptcha(kind, delay = 0, preserveNotice = false) {
  clearTimeout(state.captchaRefreshTimer);
  state.captchaRefreshTimer = null;
  state.captcha = { id: "", kind };
  userCaptcha.setLoading();
  try {
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    const result = await jsonRequest(
      `/api/user/auth/captcha?purpose=${encodeURIComponent(kind)}`
    );
    state.captcha = { id: result.id, kind };
    userCaptcha.load(result);
  } catch (error) {
    const rateLimited = error?.response?.status === 429;
    const message = rateLimited
      ? t("admin.captcha.rate_limited") : t("admin.captcha.failed");
    userCaptcha.setError(message);
    if (!preserveNotice) window.PlaymeshMessage.error(message);
    if (rateLimited) {
      const seconds = Number(error.response.headers.get("Retry-After")) || 1;
      state.captchaRefreshTimer = setTimeout(() => {
        const dialog = document.querySelector("#auth-captcha-dialog");
        if (dialog.open && state.pendingAuth?.kind === kind) {
          loadCaptcha(kind, 0, preserveNotice);
        }
      }, Math.min(60, Math.max(1, seconds)) * 1000);
    }
  }
}

function closeAuthCaptcha(cancelPending = true) {
  clearTimeout(state.captchaRefreshTimer);
  state.captchaRefreshTimer = null;
  state.captcha = { id: "", kind: "" };
  userCaptcha.clear();
  const dialog = document.querySelector("#auth-captcha-dialog");
  if (dialog.open) dialog.close();
  if (cancelPending) state.pendingAuth = null;
}

userCaptcha = new window.PlaymeshCaptcha(
  document.querySelector("#user-captcha-widget"),
  t,
  {
    refresh: () => loadCaptcha(state.pendingAuth?.kind || "login", 1050),
    close: () => closeAuthCaptcha(),
    confirm: (answer, reset) => verifyUserCaptcha(answer, reset)
  }
);

async function openAuthCaptcha(kind, formElement) {
  state.pendingAuth = {
    kind,
    values: Object.fromEntries(new FormData(formElement).entries())
  };
  const dialog = document.querySelector("#auth-captcha-dialog");
  if (!dialog.open) dialog.showModal();
  await loadCaptcha(kind);
}

document.querySelector("#auth-captcha-dialog").addEventListener("cancel", () => {
  closeAuthCaptcha();
});

async function loadRegistrationState() {
  const result = await jsonRequest("/api/user/config");
  state.registrationAllowed = result.allowUserRegistration;
  state.registrationRequiresVerification = result.requireEmailVerification;
  const notice = document.querySelector("#registration-state");
  notice.textContent = state.registrationAllowed
    ? (result.requireEmailVerification
      ? t("auth.registration_verification")
      : t("auth.registration_immediate"))
    : t("auth.registration_disabled");
  document.querySelector("#register-form button[type=submit]").disabled = !state.registrationAllowed;
}

document.querySelectorAll("[data-auth-tab]").forEach((button) => {
  button.addEventListener("click", () => {
    const kind = button.dataset.authTab;
    document.querySelectorAll("[data-auth-tab]").forEach((item) =>
      item.classList.toggle("active", item === button));
    document.querySelector("#login-form").classList.toggle("hidden", kind !== "login");
    document.querySelector("#register-form").classList.toggle("hidden", kind !== "register");
  });
});

document.querySelector("#login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  openAuthCaptcha("login", event.currentTarget);
});

document.querySelector("#register-form").addEventListener("submit", (event) => {
  event.preventDefault();
  openAuthCaptcha("register", event.currentTarget);
});

async function verifyUserCaptcha(answer, reset) {
  const pending = state.pendingAuth;
  if (!pending || !state.captcha.id) return;
  let verified;
  try {
    verified = await jsonRequest(
      `/api/user/auth/captcha/verify?purpose=${encodeURIComponent(pending.kind)}`,
      {
        method: "POST",
        body: JSON.stringify({
          id: state.captcha.id,
          answer
        })
      }
    );
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
    state.captcha.id = "";
    reset?.();
    const rateLimited = error?.response?.status === 429;
    const seconds = rateLimited
      ? Number(error.response.headers.get("Retry-After")) || 1 : 0;
    await loadCaptcha(
      pending.kind,
      rateLimited ? Math.min(60, Math.max(1, seconds)) * 1000 : 1050,
      true
    );
    return;
  }

  closeAuthCaptcha(false);
  try {
    if (pending.kind === "login") {
      const result = await jsonRequest("/api/user/auth/login", {
        method: "POST", body: JSON.stringify({
          email: pending.values.email,
          password: pending.values.password,
          captchaToken: verified.captchaToken
        })
      });
      state.csrfToken = result.csrfToken;
      state.user = result.user;
      document.querySelector("#auth-panel").classList.add("hidden");
      await showAccount();
      window.PlaymeshMessage.success(t("auth.login_success"));
    } else {
      await jsonRequest("/api/user/auth/register", {
        method: "POST", body: JSON.stringify({
          email: pending.values.email,
          password: pending.values.password,
          confirmPassword: pending.values.confirmPassword,
          captchaToken: verified.captchaToken
        })
      });
      window.PlaymeshMessage.success(
        state.registrationRequiresVerification
          ? t("auth.registration_success_verify")
          : t("auth.registration_success_login"),
        4200
      );
      document.querySelector("#register-form").reset();
    }
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error), 4200);
  } finally {
    state.pendingAuth = null;
  }
}

async function showAccount() {
  const user = state.user || await jsonRequest("/api/user/me");
  state.user = user;
  document.querySelector("#my-loading").classList.add("hidden");
  document.querySelector("#auth-panel").classList.add("hidden");
  document.querySelector("#account-panel").classList.remove("hidden");
  document.querySelector("#my-user-email").textContent = user.email;
  document.querySelector("#profile-email").value = user.email;
  document.querySelector("#profile-form").elements.displayName.value = user.displayName;
  try {
    await loadMyGames();
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
  try {
    await loadNotifications();
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
}

async function showSignedOut(kind = "login") {
  document.querySelector("#my-loading").classList.add("hidden");
  document.querySelector("#account-panel").classList.add("hidden");
  document.querySelector("#auth-panel").classList.remove("hidden");
  document.querySelectorAll("[data-auth-tab]").forEach((button) => {
    button.classList.toggle("active", button.dataset.authTab === kind);
  });
  document.querySelector("#login-form").classList.toggle("hidden", kind !== "login");
  document.querySelector("#register-form").classList.toggle("hidden", kind !== "register");
}

document.querySelectorAll("[data-open-dialog]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelector(`#${button.dataset.openDialog}`).showModal();
  });
});
document.querySelectorAll("[data-close-dialog]").forEach((button) => {
  button.addEventListener("click", () => button.closest("dialog").close());
});
document.querySelectorAll(".my-dialog").forEach((dialog) => {
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });
});

document.querySelector("#profile-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  try {
    state.user = await jsonRequest("/api/user/me", {
      method: "PATCH", body: JSON.stringify({ displayName: form.elements.displayName.value })
    });
    document.querySelector("#profile-dialog").close();
    window.PlaymeshMessage.success(t("user.profile_saved"));
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});

async function saveUploadKey(generate) {
  const form = document.querySelector("#key-form");
  const result = await jsonRequest("/api/user/upload-key", {
    method: "PUT", body: JSON.stringify({ key: form.elements.key.value, generate })
  });
  document.querySelector("#created-key").value = result.uploadKey;
  const sourceQRCode = document.querySelector("#private-source-qr");
  sourceQRCode.src = result.sourceQRCode;
  sourceQRCode.classList.remove("hidden");
  document.querySelector("#private-source-qr-empty").classList.add("hidden");
  form.elements.key.value = "";
  window.PlaymeshMessage.success(t("uploads.key_saved"));
}
document.querySelector("#key-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try { await saveUploadKey(false); } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});
document.querySelector("#generate-key").addEventListener("click", async () => {
  try { await saveUploadKey(true); } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});

document.querySelector("#game-upload-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    const result = await jsonRequest("/api/user/games/uploads", {
      method: "POST", body: new FormData(event.currentTarget)
    });
    window.PlaymeshMessage.success(t("uploads.submitted", "", {
      packageId: result.packageId, version: result.version
    }), 4200);
    event.currentTarget.reset();
    await loadMyGames();
  } catch (error) {
    const highest = error.result?.currentHighestVersion;
    const message = highest
      ? t("uploads.error_with_highest", "", {
        message: localizedError(error), version: highest
      })
      : localizedError(error);
    window.PlaymeshMessage.error(message, 4200);
  }
});

async function loadMyGames() {
  const result = await jsonRequest("/api/user/games");
  document.querySelector("#my-game-count").textContent = String(result.data.length);
  document.querySelector("#my-games").innerHTML = result.data.map((game) => {
    const canPublish = game.status === "approved" && !game.published;
    const canUnpublish = game.status === "approved" && game.published;
    const canDelete = !game.published;
    return `<article class="game-card">
      <div class="actions"><span class="badge">${escapeHTML(t(`games.${game.status}`, game.status))}</span>
        <span class="muted">${game.published ? t("games.published") : t("games.unpublished")}</span></div>
      <h3>${escapeHTML(game.name)}</h3>
      <div class="muted">${escapeHTML(game.packageId)} · ${escapeHTML(game.version)}</div>
      <p>${escapeHTML(game.rejectionReason || game.remarks || t("games.no_review_note"))}</p>
      <div class="row-actions">
        ${canPublish ? `<button data-game-action="publish" data-id="${game.id}">${escapeHTML(t("games.publish"))}</button>` : ""}
        ${canUnpublish ? `<button data-game-action="unpublish" data-id="${game.id}" class="secondary">${escapeHTML(t("games.unpublish"))}</button>` : ""}
        ${canDelete ? `<button data-game-action="delete" data-id="${game.id}" class="danger">${escapeHTML(t("common.delete"))}</button>` : ""}
      </div>
    </article>`;
  }).join("") || `<div class="empty">${escapeHTML(t("games.mine_empty"))}</div>`;
}

async function loadNotifications() {
  const result = await jsonRequest("/api/user/notifications");
  document.querySelector("#my-notifications").innerHTML = result.data.map((item) => `
    <article class="notification-item ${item.readAt ? "" : "unread"}">
      <div>
        <strong>${escapeHTML(item.title)}</strong>
        <time>${new Date(item.createdAt).toLocaleString(document.documentElement.lang)}</time>
      </div>
      <p>${escapeHTML(item.message)}</p>
      ${item.readAt ? "" : `<button type="button" class="secondary" data-notification-read="${item.id}">${escapeHTML(t("user.notifications.mark_read"))}</button>`}
    </article>
  `).join("") || `<div class="empty">${escapeHTML(t("user.notifications.empty"))}</div>`;
}
document.querySelector("#my-notifications").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-notification-read]");
  if (!button) return;
  try {
    await jsonRequest(`/api/user/notifications/${button.dataset.notificationRead}/read`, {
      method: "POST"
    });
    await loadNotifications();
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});
document.querySelector("#my-games").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-game-action]");
  if (!button) return;
  const action = button.dataset.gameAction;
  if (action === "delete" && !confirm(t("games.confirm_delete"))) return;
  const path = `/api/user/games/${button.dataset.id}` +
    (action === "delete" ? "" : `/${action}`);
  try {
    await jsonRequest(path, { method: action === "delete" ? "DELETE" : "POST" });
    await loadMyGames();
    window.PlaymeshMessage.success(t(`games.${action}_success`));
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});

document.querySelector("#logout").addEventListener("click", async () => {
  try {
    await jsonRequest("/api/user/auth/logout", { method: "POST" });
    state.user = null; state.csrfToken = "";
    state.captcha = { id: "", kind: "" };
    document.querySelectorAll(".my-dialog[open]").forEach((dialog) => dialog.close());
    await showSignedOut("login");
    window.PlaymeshMessage.success(t("auth.logout_success"));
  } catch (error) {
    window.PlaymeshMessage.error(localizedError(error));
  }
});

async function loadGames() {
  games.innerHTML = `<div class="empty">${escapeHTML(t("catalog.loading"))}</div>`;
  const form = new FormData(filters);
  const params = new URLSearchParams({
    page: state.page, size: state.size, name: form.get("name") || ""
  });
  const result = await jsonRequest(`/api/public/games?${params}`);
  state.total = result.total;
  document.querySelector("#game-count").textContent = String(result.total);
  games.innerHTML = result.data.map((game) => `<article class="game-card">
    <div class="game-card-head">
      <span class="game-initial" aria-hidden="true">${escapeHTML(String(game.name || "P").trim().charAt(0).toUpperCase() || "P")}</span>
      <div class="game-card-title">
        <h3>${escapeHTML(game.name)}</h3>
        <span class="game-id">${escapeHTML(game.id)}</span>
      </div>
      <span class="version-tag">v${escapeHTML(game.version)}</span>
    </div>
    <p>${escapeHTML(game.remarks || t("catalog.no_description"))}</p>
    <div class="game-card-footer">
      <span class="publisher">${escapeHTML(t("catalog.publisher", "", {
        publisher: game.author || t("catalog.unsigned")
      }))}</span>
      <a class="button game-download" href="${escapeHTML(game.downloadUrl)}">${escapeHTML(t("catalog.download"))}</a>
    </div>
  </article>`).join("") || `<div class="empty">${escapeHTML(t("catalog.empty"))}</div>`;
  const pages = Math.max(1, Math.ceil(state.total / state.size));
  document.querySelector("#page-label").textContent = t("common.page", "", {
    current: state.page, pages
  });
  document.querySelector("#previous").disabled = state.page <= 1;
  document.querySelector("#next").disabled = state.page >= pages;
}
let filterTimer;
filters.addEventListener("input", () => {
  clearTimeout(filterTimer);
  filterTimer = setTimeout(() => { state.page = 1; loadGames(); }, 250);
});
document.querySelector("#previous").addEventListener("click", () => {
  if (state.page > 1) { state.page--; loadGames(); }
});
document.querySelector("#next").addEventListener("click", () => {
  if (state.page * state.size < state.total) { state.page++; loadGames(); }
});

function applyUserView() {
  state.view = location.pathname === "/games"
    ? "games"
    : ["/my", "/login", "/register"].includes(location.pathname) ? "my" : "home";
  document.querySelector("#user-home-view").classList.toggle("hidden", state.view !== "home");
  document.querySelector("#user-games-view").classList.toggle("hidden", state.view !== "games");
  document.querySelector("#user-my-view").classList.toggle("hidden", state.view !== "my");
  document.querySelectorAll("[data-user-view]").forEach((link) => {
    const active = link.dataset.userView === state.view;
    link.classList.toggle("active", active);
    if (active) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
}

function showEmailVerificationResult() {
  const url = new URL(window.location.href);
  const result = url.searchParams.get("emailVerification");
  if (!result) return;
  url.searchParams.delete("emailVerification");
  window.history.replaceState(
    null, "", `${url.pathname}${url.search}${url.hash}`
  );
  if (result === "success") {
    window.PlaymeshMessage.success(t("auth.email_verification_success"), 5000);
  } else {
    window.PlaymeshMessage.error(t("auth.email_verification_failed"), 5000);
  }
}

async function initialize() {
  try {
    applyUserView();
    await loadLocalization();
    showEmailVerificationResult();
    if (state.view === "home") await loadSourceInfo();
    if (state.view === "games") await loadGames();
    if (state.view === "my") {
      try {
        await loadRegistrationState();
      } catch (error) {
        window.PlaymeshMessage.error(localizedError(error));
      }
      try {
        state.user = await jsonRequest("/api/user/me");
      } catch {
        await showSignedOut(location.pathname === "/register" ? "register" : "login");
        return;
      }
      await showAccount();
    }
  } finally {
    window.__playmeshRevealUI?.();
  }
}
initialize();
