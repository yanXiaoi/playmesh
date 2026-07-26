const state = { status: "approved", page: 1, size: 12, total: 0 };
const games = document.querySelector("#games");
const filters = document.querySelector("#filters");
const notice = document.querySelector("#upload-notice");

const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
})[character]);

async function copyValue(targetId) {
  const input = document.querySelector(`#${targetId}`);
  if (!input?.value) return;
  try {
    await navigator.clipboard.writeText(input.value);
  } catch {
    input.focus();
    input.select();
    document.execCommand("copy");
    input.setSelectionRange(0, 0);
  }
  const sourceNotice = document.querySelector("#source-info-notice");
  sourceNotice.className = "notice ok";
  sourceNotice.textContent = "已复制，可在 Playmesh App 中手动添加。";
}

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.addEventListener("click", () => copyValue(button.dataset.copyTarget));
});

async function loadSourceInfo() {
  document.querySelector("#current-source-url").value = window.location.origin;
  const sourceNotice = document.querySelector("#source-info-notice");
  const response = await fetch("/api/public/source-info", { cache: "no-store" });
  if (!response.ok) {
    sourceNotice.className = "notice error";
    sourceNotice.textContent = "游戏源连接信息暂时无法读取。";
    return;
  }
  const result = await response.json();
  document.querySelector("#configured-source-url").value =
    result.publicBaseUrl || window.location.origin;
  document.querySelector("#published-source-token").value =
    result.publishedToken || "";
  sourceNotice.className = "notice";
  sourceNotice.textContent =
    "当前访问地址适合本网络手动添加；跨网络部署请优先使用配置公开地址。";
}

async function loadSourceQRCode() {
  const response = await fetch("/api/public/source-qrcode");
  if (!response.ok) return;
  const blob = await response.blob();
  const dataURL = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => resolve(reader.result), { once: true });
    reader.addEventListener("error", () => reject(reader.error), { once: true });
    reader.readAsDataURL(blob);
  });
  const image = document.querySelector("#source-qr-image");
  image.src = dataURL;
  document.querySelector("#source-qr-panel").classList.remove("hidden");
}

async function loadGames() {
  games.innerHTML = '<div class="empty">正在读取游戏目录…</div>';
  const data = new FormData(filters);
  const params = new URLSearchParams({
    status: state.status, page: state.page, size: state.size,
    id: data.get("id"), name: data.get("name"), author: data.get("author"),
    sort: data.get("sort"), order: data.get("order")
  });
  if (data.get("from")) params.set("from", String(new Date(data.get("from")).getTime()));
  if (data.get("to")) params.set("to", String(new Date(data.get("to")).getTime() + 86400000 - 1));
  const response = await fetch(`/api/public/games?${params}`);
  if (!response.ok) {
    games.innerHTML = '<div class="empty">目录暂时无法读取，请稍后重试。</div>';
    return;
  }
  const result = await response.json();
  state.total = result.total;
  if (!result.data.length) {
    games.innerHTML = '<div class="empty">当前筛选条件下没有游戏包。</div>';
  } else {
    games.innerHTML = result.data.map((game) => {
      const approved = game.status === "approved";
      const action = approved
        ? `<a class="button" href="${escapeHTML(game.downloadUrl)}">下载游戏包</a>`
        : '<span class="muted">审核完成后开放下载</span>';
      return `<article class="game-card">
        <div class="actions">
          <span class="badge ${approved ? "" : "pending"}">${approved ? "已通过" : "待审核"}</span>
          <span class="muted">v${escapeHTML(game.version)}</span>
        </div>
        <div><h3>${escapeHTML(game.name)}</h3><div class="muted">${escapeHTML(game.id)}</div></div>
        <p>${escapeHTML(game.remarks || "作者暂未填写游戏简介。")}</p>
        <div class="meta">
          <span>作者 ${escapeHTML(game.author || "未署名")}</span>
          <span>${new Date(game.createdAt).toLocaleString()}</span>
        </div>
        <div class="actions">${action}</div>
      </article>`;
    }).join("");
  }
  const pages = Math.max(1, Math.ceil(state.total / state.size));
  document.querySelector("#page-label").textContent = `${state.page} / ${pages}`;
  document.querySelector("#previous").disabled = state.page <= 1;
  document.querySelector("#next").disabled = state.page >= pages;
}

document.querySelectorAll("[data-status]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-status]").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    state.status = button.dataset.status;
    state.page = 1;
    loadGames();
  });
});

let filterTimer;
filters.addEventListener("input", () => {
  clearTimeout(filterTimer);
  filterTimer = setTimeout(() => { state.page = 1; loadGames(); }, 280);
});
document.querySelector("#previous").addEventListener("click", () => {
  if (state.page > 1) { state.page--; loadGames(); }
});
document.querySelector("#next").addEventListener("click", () => {
  if (state.page * state.size < state.total) { state.page++; loadGames(); }
});

document.querySelector("#upload-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const button = form.querySelector("button");
  button.disabled = true;
  notice.className = "notice";
  notice.textContent = "正在隔离文件并执行安全扫描，请勿关闭页面…";
  try {
    const response = await fetch("/api/public/upload", {
      method: "POST", body: new FormData(form)
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.message || "上传失败");
    notice.className = "notice ok";
    notice.textContent = result.message;
    form.reset();
    state.status = "pending";
    document.querySelectorAll("[data-status]").forEach((item) =>
      item.classList.toggle("active", item.dataset.status === "pending"));
    await loadGames();
  } catch (error) {
    notice.className = "notice error";
    notice.textContent = error.message;
  } finally {
    button.disabled = false;
  }
});

loadGames();
loadSourceInfo();
loadSourceQRCode();
