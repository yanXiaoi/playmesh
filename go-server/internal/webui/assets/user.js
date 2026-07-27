const state = {
  page: 1, size: 12, total: 0, csrfToken: "", user: null,
  captcha: { login: "", register: "" }, registrationAllowed: true,
  registrationRequiresVerification: false,
  messages: {}, ui: null
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
const colorScheme = matchMedia("(prefers-color-scheme: dark)");

function applyTheme(mode) {
  const normalized = ["system", "light", "dark"].includes(mode) ? mode : "system";
  document.documentElement.dataset.theme =
    normalized === "system" ? (colorScheme.matches ? "dark" : "light") : normalized;
  const button = document.querySelector("#theme-toggle");
  button.dataset.mode = normalized;
  button.textContent = {
    system: t("theme.system"),
    light: t("theme.light"),
    dark: t("theme.dark")
  }[normalized];
}

colorScheme.addEventListener("change", () => {
  if (document.querySelector("#theme-toggle").dataset.mode === "system") applyTheme("system");
});

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
  const manifest = state.ui || await fetch("/i18n/manifest").then((response) => response.json());
  state.ui = manifest;
  const available = manifest.locales.map((locale) => locale.id);
  const locale = resolveLocale([
    localeOverride,
    localStorage.getItem("playmesh.locale"),
    ...(Array.isArray(navigator.languages) ? navigator.languages : []),
    navigator.language
  ], available, manifest.defaultLocale);
  state.messages = await fetch(`/i18n/${encodeURIComponent(locale)}`).then((response) => response.json());
  document.documentElement.lang = locale;
  localizeDocument();
  const select = document.querySelector("#locale-select");
  select.replaceChildren(...manifest.locales.map((item) => {
    const option = document.createElement("option");
    option.value = item.id; option.textContent = item.label; option.selected = item.id === locale;
    return option;
  }));
  select.classList.toggle("hidden", !manifest.allowLocaleSwitch);
  document.querySelector("#theme-toggle").classList.toggle("hidden", !manifest.allowThemeSwitch);
  applyTheme(localStorage.getItem("playmesh.theme") || manifest.defaultThemeMode);
}
document.querySelector("#locale-select").addEventListener("change", async (event) => {
  localStorage.setItem("playmesh.locale", event.target.value);
  await loadLocalization(event.target.value);
  await Promise.all([loadSourceInfo(), loadRegistrationState(), loadGames()]);
  if (state.user) await loadMyGames();
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
  await navigator.clipboard.writeText(input.value);
  document.querySelector("#source-info-notice").textContent = t("user.source.copied");
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

async function loadCaptcha(kind) {
  const result = await jsonRequest("/api/user/auth/captcha");
  state.captcha[kind] = result.id;
  const form = document.querySelector(`#${kind}-form`);
  form.querySelector(".captcha-image").src = result.image;
  form.querySelector("[name=captchaAnswer]").value = "";
}

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
  document.querySelector("#account-open").classList.toggle("hidden", !state.registrationAllowed && !state.user);
}

document.querySelector("#account-open").addEventListener("click", async () => {
  document.querySelector("#auth-panel").classList.toggle("hidden");
  if (!state.captcha.login) await loadCaptcha("login");
});
document.querySelectorAll("[data-auth-tab]").forEach((button) => {
  button.addEventListener("click", async () => {
    const kind = button.dataset.authTab;
    document.querySelectorAll("[data-auth-tab]").forEach((item) =>
      item.classList.toggle("active", item === button));
    document.querySelector("#login-form").classList.toggle("hidden", kind !== "login");
    document.querySelector("#register-form").classList.toggle("hidden", kind !== "register");
    if (!state.captcha[kind]) await loadCaptcha(kind);
  });
});

document.querySelector("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  try {
    const result = await jsonRequest("/api/user/auth/login", {
      method: "POST", body: JSON.stringify({
        email: form.get("email"), password: form.get("password"),
        captchaId: state.captcha.login, captchaAnswer: form.get("captchaAnswer")
      })
    });
    state.csrfToken = result.csrfToken; state.user = result.user;
    document.querySelector("#auth-panel").classList.add("hidden");
    await showAccount();
  } catch (error) {
    document.querySelector("#auth-notice").textContent = localizedError(error);
    await loadCaptcha("login");
  }
});

document.querySelector("#register-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  try {
    await jsonRequest("/api/user/auth/register", {
      method: "POST", body: JSON.stringify({
        email: form.get("email"), password: form.get("password"),
        confirmPassword: form.get("confirmPassword"),
        captchaId: state.captcha.register, captchaAnswer: form.get("captchaAnswer")
      })
    });
    document.querySelector("#auth-notice").textContent = state.registrationRequiresVerification
      ? t("auth.registration_success_verify") : t("auth.registration_success_login");
    event.currentTarget.reset();
  } catch (error) {
    document.querySelector("#auth-notice").textContent = localizedError(error);
  }
  await loadCaptcha("register");
});

async function showAccount() {
  const user = state.user || await jsonRequest("/api/user/me");
  state.user = user;
  document.querySelector("#account-open").classList.add("hidden");
  document.querySelector("#account-panel").classList.remove("hidden");
  document.querySelector("#profile-email").value = user.email;
  document.querySelector("#profile-form").elements.displayName.value = user.displayName;
  await loadMyGames();
}

document.querySelector("#profile-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  state.user = await jsonRequest("/api/user/me", {
    method: "PATCH", body: JSON.stringify({ displayName: form.elements.displayName.value })
  });
});

async function saveUploadKey(generate) {
  const form = document.querySelector("#key-form");
  const result = await jsonRequest("/api/user/upload-key", {
    method: "PUT", body: JSON.stringify({ key: form.elements.key.value, generate })
  });
  document.querySelector("#created-key").value = result.uploadKey;
  form.elements.key.value = "";
}
document.querySelector("#key-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try { await saveUploadKey(false); } catch (error) { alert(localizedError(error)); }
});
document.querySelector("#generate-key").addEventListener("click", async () => {
  try { await saveUploadKey(true); } catch (error) { alert(localizedError(error)); }
});

document.querySelector("#game-upload-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const notice = document.querySelector("#upload-notice");
  try {
    const result = await jsonRequest("/api/user/games/uploads", {
      method: "POST", body: new FormData(event.currentTarget)
    });
    notice.textContent = t("uploads.submitted", "", {
      packageId: result.packageId, version: result.version
    });
    event.currentTarget.reset();
    await loadMyGames();
  } catch (error) {
    const highest = error.result?.currentHighestVersion;
    notice.textContent = highest
      ? t("uploads.error_with_highest", "", {
        message: localizedError(error), version: highest
      })
      : localizedError(error);
  }
});

async function loadMyGames() {
  const result = await jsonRequest("/api/user/games");
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
document.querySelector("#my-games").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-game-action]");
  if (!button) return;
  const action = button.dataset.gameAction;
  if (action === "delete" && !confirm(t("games.confirm_delete"))) return;
  const path = `/api/user/games/${button.dataset.id}` +
    (action === "delete" ? "" : `/${action}`);
  try {
    await jsonRequest(path, { method: action === "delete" ? "DELETE" : "POST" });
    await loadMyGames(); await loadGames();
  } catch (error) { alert(localizedError(error)); }
});

document.querySelector("#logout").addEventListener("click", async () => {
  await jsonRequest("/api/user/auth/logout", { method: "POST" });
  state.user = null; state.csrfToken = "";
  document.querySelector("#account-panel").classList.add("hidden");
  document.querySelector("#account-open").classList.toggle("hidden", !state.registrationAllowed);
});

async function loadGames() {
  games.innerHTML = `<div class="empty">${escapeHTML(t("catalog.loading"))}</div>`;
  const form = new FormData(filters);
  const params = new URLSearchParams({
    page: state.page, size: state.size, name: form.get("name") || ""
  });
  const result = await jsonRequest(`/api/public/games?${params}`);
  state.total = result.total;
  games.innerHTML = result.data.map((game) => `<article class="game-card">
    <div class="actions"><span class="badge">${escapeHTML(t("games.published"))}</span><span class="muted">v${escapeHTML(game.version)}</span></div>
    <h3>${escapeHTML(game.name)}</h3><div class="muted">${escapeHTML(game.id)}</div>
    <p>${escapeHTML(game.remarks || t("catalog.no_description"))}</p>
    <div class="meta"><span>${escapeHTML(t("catalog.publisher", "", {
      publisher: game.author || t("catalog.unsigned")
    }))}</span></div>
    <a class="button" href="${escapeHTML(game.downloadUrl)}">${escapeHTML(t("catalog.download"))}</a>
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

document.querySelector("#theme-toggle").addEventListener("click", () => {
  const modes = ["system", "light", "dark"];
  const current = document.querySelector("#theme-toggle").dataset.mode || "system";
  const next = modes[(modes.indexOf(current) + 1) % modes.length];
  localStorage.setItem("playmesh.theme", next);
  applyTheme(next);
});
applyTheme(localStorage.getItem("playmesh.theme") || "system");

async function initialize() {
  try {
    await loadLocalization();
    await Promise.all([loadSourceInfo(), loadRegistrationState(), loadGames()]);
    jsonRequest("/api/user/me").then((user) => {
      state.user = user;
      showAccount();
    }).catch(() => {});
    if (location.pathname === "/login" || location.pathname === "/register") {
      document.querySelector("#auth-panel").classList.remove("hidden");
      const kind = location.pathname === "/register" ? "register" : "login";
      document.querySelectorAll("[data-auth-tab]").forEach((button) => {
        const active = button.dataset.authTab === kind;
        button.classList.toggle("active", active);
      });
      document.querySelector("#login-form").classList.toggle("hidden", kind !== "login");
      document.querySelector("#register-form").classList.toggle("hidden", kind !== "register");
      loadCaptcha(kind);
    }
  } finally {
    window.__playmeshRevealUI?.();
  }
}
initialize();
