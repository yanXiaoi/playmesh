"use strict";

const packageName = "playmesh";
const defaultControllerEntry = "controller/index.html";
const defaultAuthorityEntry = "static/js/service/index.js";

function splitList(value) {
  const seen = new Set();
  return String(value || "")
    .split(/[,，\n]/)
    .map((item) => item.trim())
    .filter((item) => {
      if (!item || seen.has(item)) {
        return false;
      }
      seen.add(item);
      return true;
    });
}

module.exports = Editor.Panel.define({
  template: `
    <header>
      <div>
        <h1>Playmesh 项目设置</h1>
        <p>配置会写入当前项目的 Playmesh 清单，并随项目进入版本管理。</p>
      </div>
      <button type="button" data-action="reload">重新加载</button>
    </header>
    <form>
      <section>
        <h2>游戏信息</h2>
        <div class="grid">
          <label class="field">
            <span>项目 ID</span>
            <input data-field="id" readonly>
          </label>
          <label class="field">
            <span>游戏名称</span>
            <input data-field="name" maxlength="80" required>
          </label>
          <label class="field">
            <span>版本</span>
            <input data-field="version" maxlength="64" required>
          </label>
          <label class="field span-2">
            <span>项目备注</span>
            <textarea data-field="remarks" maxlength="500" rows="3"></textarea>
          </label>
          <label class="field span-2">
            <span>标签</span>
            <input data-field="tags" placeholder="例如：cocos, party, action">
            <small>最多 20 项，使用逗号分隔。</small>
          </label>
        </div>
        <div class="readonly-row">
          <span>Game SDK <b data-value="sdk-version">-</b></span>
          <span>App SDK <b data-value="app-sdk-version">-</b></span>
        </div>
      </section>

      <section>
        <h2>运行形态</h2>
        <div class="grid">
          <label class="field">
            <span>游戏方向</span>
            <select data-field="orientation">
              <option value="landscape">横屏</option>
              <option value="portrait">竖屏</option>
              <option value="system" selected>跟随系统</option>
            </select>
          </label>
          <label class="field">
            <span>游戏模式</span>
            <select data-field="mode">
              <option value="solo">单机游戏</option>
              <option value="multiplayer">多人游戏</option>
            </select>
          </label>
          <label class="field multiplayer">
            <span>显示模式</span>
            <select data-field="display-mode">
              <option value="multi_screen">多人多屏</option>
              <option value="single_screen_multiplayer">单屏多人</option>
            </select>
          </label>
          <label class="field controller">
            <span>控制器方向</span>
            <select data-field="controller-orientation">
              <option value="portrait">竖屏</option>
              <option value="landscape">横屏</option>
              <option value="system" selected>跟随系统</option>
            </select>
          </label>
          <label class="field controller span-2">
            <span>控制器 HTML 地址</span>
            <input
              data-field="controller-entry"
              placeholder="controller/index.html"
            >
            <small>相对于游戏 Web 根目录，例如 controls/pad.html。</small>
          </label>
          <label class="field multiplayer">
            <span>最少玩家</span>
            <input data-field="min-players" type="number" min="1" max="32">
          </label>
          <label class="field multiplayer">
            <span>最多玩家</span>
            <input data-field="max-players" type="number" min="1" max="32">
          </label>
          <label class="field multiplayer span-2">
            <span>多人权威服务 JS 地址</span>
            <input
              data-field="authority-entry"
              placeholder="static/js/service/index.js"
            >
            <small>相对于游戏 Web 根目录。</small>
          </label>
        </div>
        <p class="hint" data-value="mode-warning"></p>
      </section>

      <section>
        <div class="section-heading">
          <h2>平台能力</h2>
          <span data-value="capability-count"></span>
        </div>
        <p class="warning" data-value="capability-warning" hidden></p>
        <h3>主画面必需能力</h3>
        <div class="capabilities" data-list="required"></div>
        <div class="controller">
          <h3>控制器必需能力</h3>
          <div class="capabilities" data-list="controller-required"></div>
        </div>
      </section>

      <section>
        <h2>Cocos 集成</h2>
        <div class="grid">
          <label class="field">
            <span>Web 构建平台</span>
            <select data-field="platform">
              <option value="web-mobile">Web Mobile</option>
              <option value="web-desktop">Web Desktop</option>
            </select>
          </label>
          <label class="field">
            <span>预览桥端口</span>
            <input data-field="preview-port" type="number" min="0" max="65535">
            <small>0 表示系统自动分配；修改后重新加载扩展生效。</small>
          </label>
          <label class="check span-2">
            <input data-field="auto-run" type="checkbox">
            <span>Web 构建完成后自动上传并运行到 App</span>
          </label>
        </div>
      </section>

      <footer>
        <p data-value="status" role="status"></p>
        <button type="submit" class="primary">保存项目设置</button>
      </footer>
    </form>
  `,

  style: `
    :host {
      display: block;
      height: 100%;
      overflow: auto;
      color: var(--color-normal-contrast, #d7dcda);
      background: var(--color-normal-fill, #252827);
      font: 13px/1.45 system-ui, sans-serif;
    }
    * { box-sizing: border-box; }
    header {
      position: sticky;
      top: 0;
      z-index: 2;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      padding: 18px 22px;
      border-bottom: 1px solid #ffffff16;
      background: #202322f2;
      backdrop-filter: blur(12px);
    }
    h1, h2, h3, p { margin: 0; }
    h1 { color: #f3f7f4; font-size: 18px; font-weight: 650; }
    header p, .hint, small { color: #909a94; }
    header p { margin-top: 3px; font-size: 12px; }
    form { padding: 18px 22px 28px; }
    section {
      margin-bottom: 16px;
      padding: 18px;
      border: 1px solid #ffffff12;
      border-radius: 8px;
      background: #ffffff06;
    }
    h2 { margin-bottom: 15px; color: #edf4ef; font-size: 14px; }
    h3 { margin: 13px 0 8px; color: #bbc5be; font-size: 12px; }
    .section-heading {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
    }
    .section-heading h2 { margin-bottom: 0; }
    .section-heading span { color: #7f8983; font-size: 11px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 13px 16px;
    }
    .span-2 { grid-column: 1 / -1; }
    .field { display: flex; min-width: 0; flex-direction: column; gap: 6px; }
    .field > span { color: #aeb8b1; font-size: 12px; }
    input, select, textarea, button {
      border: 1px solid #ffffff1f;
      border-radius: 5px;
      color: #e5ebe7;
      background: #181b1a;
      font: inherit;
    }
    input, select, textarea { width: 100%; padding: 7px 9px; }
    textarea { resize: vertical; }
    input:focus, select:focus, textarea:focus {
      border-color: #65bf82;
      outline: 1px solid #65bf8255;
    }
    input[readonly] { color: #7f8983; background: #1e211f; }
    button { cursor: pointer; padding: 7px 12px; }
    button:hover { border-color: #66c486; }
    button.primary {
      border-color: #65bf82;
      color: #112017;
      background: #79d99a;
      font-weight: 650;
    }
    .readonly-row {
      display: flex;
      gap: 20px;
      margin-top: 14px;
      color: #818b85;
      font-size: 11px;
    }
    .readonly-row b { color: #aab4ad; font-weight: 500; }
    .hint, .warning { margin-top: 12px; font-size: 12px; }
    .warning {
      padding: 9px 11px;
      border: 1px solid #d4a44844;
      border-radius: 5px;
      color: #e3bd74;
      background: #d4a44812;
    }
    .capabilities {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
      gap: 8px;
    }
    .capability, .check {
      display: flex;
      align-items: flex-start;
      gap: 8px;
    }
    .capability {
      padding: 9px;
      border: 1px solid #ffffff10;
      border-radius: 5px;
      background: #11141242;
    }
    .capability input, .check input { width: auto; margin-top: 2px; }
    .capability strong { display: block; color: #d9e1dc; font-size: 12px; }
    .capability code { color: #79d99a; font-size: 10px; }
    .capability small { display: block; margin-top: 3px; }
    footer {
      position: sticky;
      bottom: 0;
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 15px;
      padding: 13px 0 0;
      background: linear-gradient(transparent, #252827 35%);
    }
    footer p { flex: 1; color: #9aa49e; }
    footer p.error { color: #ef8e8e; }
    [hidden] { display: none !important; }
    @media (max-width: 620px) {
      .grid { grid-template-columns: 1fr; }
      .span-2 { grid-column: auto; }
    }
  `,

  $: {
    form: "form",
    status: "[data-value='status']",
    reload: "[data-action='reload']",
  },

  methods: {
    field(name) {
      return this.$.form.querySelector(`[data-field="${name}"]`);
    },

    setStatus(message, error = false) {
      this.$.status.textContent = message;
      this.$.status.classList.toggle("error", error);
    },

    updateVisibility() {
      const multiplayer = this.field("mode").value === "multiplayer";
      const controller =
        multiplayer &&
        this.field("display-mode").value ===
          "single_screen_multiplayer";
      if (multiplayer && !this.field("authority-entry").value.trim()) {
        this.field("authority-entry").value = defaultAuthorityEntry;
      }
      if (controller && !this.field("controller-entry").value.trim()) {
        this.field("controller-entry").value = defaultControllerEntry;
      }
      for (const element of this.$.form.querySelectorAll(".multiplayer")) {
        element.hidden = !multiplayer;
      }
      for (const element of this.$.form.querySelectorAll(".controller")) {
        element.hidden = !controller;
      }
      const warnings = [];
      if (multiplayer && !this.field("authority-entry").value.trim()) {
        warnings.push("多人游戏需要 main.json.authority.entry。");
      }
      if (controller && !this.field("controller-entry").value.trim()) {
        warnings.push("单屏多人需要 main.json.entries.controller。");
      }
      this.$.form.querySelector(
        "[data-value='mode-warning']",
      ).textContent = warnings.join(" ");
    },

    renderCapabilities(container, selected, kind) {
      container.replaceChildren();
      for (const option of this.state.capabilityOptions) {
        const label = document.createElement("label");
        label.className = "capability";
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.dataset.capabilityKind = kind;
        checkbox.value = option.code;
        checkbox.checked = selected.has(option.code);
        const content = document.createElement("span");
        const name = document.createElement("strong");
        name.textContent = option.name;
        const code = document.createElement("code");
        code.textContent = option.code;
        content.append(name, code);
        if (option.description) {
          const description = document.createElement("small");
          description.textContent = option.description;
          content.append(description);
        }
        if (option.supportedPlatforms.length > 0) {
          const platforms = document.createElement("small");
          platforms.textContent =
            `支持：${option.supportedPlatforms.join(" / ")}`;
          content.append(platforms);
        }
        label.append(checkbox, content);
        container.append(label);
      }
      if (this.state.capabilityOptions.length === 0) {
        const empty = document.createElement("p");
        empty.className = "hint";
        empty.textContent = "目标 App 没有返回可选择的能力。";
        container.append(empty);
      }
    },

    render(state) {
      this.state = state;
      this.field("id").value = state.manifest.id;
      this.field("name").value = state.manifest.name;
      this.field("version").value = state.manifest.version;
      this.field("remarks").value = state.manifest.remarks;
      this.field("tags").value = state.manifest.tags.join(", ");
      this.field("orientation").value = state.manifest.orientation;
      this.field("mode").value = state.manifest.mode;
      this.field("display-mode").value = state.manifest.displayMode;
      this.field("controller-orientation").value =
        state.manifest.controllerOrientation;
      this.field("controller-entry").value =
        state.manifest.controllerEntry;
      this.field("authority-entry").value =
        state.manifest.authorityEntry;
      this.field("min-players").value = state.manifest.minPlayers;
      this.field("max-players").value = state.manifest.maxPlayers;
      this.field("platform").value = state.integration.platform;
      this.field("preview-port").value =
        state.integration.previewBridgePort;
      this.field("auto-run").checked = state.integration.autoRunAfterBuild;
      this.$.form.querySelector(
        "[data-value='sdk-version']",
      ).textContent = state.manifest.sdkVersion || "-";
      this.$.form.querySelector(
        "[data-value='app-sdk-version']",
      ).textContent = state.manifest.appSdkVersion || "-";
      this.$.form.querySelector(
        "[data-value='capability-count']",
      ).textContent = `${state.capabilityOptions.length} 项`;
      const warning = this.$.form.querySelector(
        "[data-value='capability-warning']",
      );
      warning.hidden = !state.capabilityWarning;
      warning.textContent = state.capabilityWarning
        ? `能力目录暂不可用：${state.capabilityWarning}`
        : "";
      this.renderCapabilities(
        this.$.form.querySelector("[data-list='required']"),
        new Set(state.capabilities.required),
        "required",
      );
      this.renderCapabilities(
        this.$.form.querySelector(
          "[data-list='controller-required']",
        ),
        new Set(state.capabilities.controllerRequired),
        "controllerRequired",
      );
      this.updateVisibility();
    },

    selectedCapabilities(kind) {
      return [
        ...this.$.form.querySelectorAll(
          `input[data-capability-kind="${kind}"]:checked`,
        ),
      ].map((input) => input.value);
    },

    collect() {
      const mode = this.field("mode").value;
      const multiplayer = mode === "multiplayer";
      const displayMode = multiplayer
        ? this.field("display-mode").value
        : "multi_screen";
      const controller =
        multiplayer &&
        displayMode === "single_screen_multiplayer";
      return {
        manifest: {
          name: this.field("name").value,
          version: this.field("version").value,
          remarks: this.field("remarks").value,
          tags: splitList(this.field("tags").value),
          orientation: this.field("orientation").value,
          mode,
          displayMode,
          controllerOrientation: controller
            ? this.field("controller-orientation").value
            : "",
          controllerEntry: controller
            ? this.field("controller-entry").value
            : "",
          authorityEntry: multiplayer
            ? this.field("authority-entry").value
            : "",
          minPlayers: multiplayer
            ? Number(this.field("min-players").value)
            : 1,
          maxPlayers: multiplayer
            ? Number(this.field("max-players").value)
            : 1,
        },
        capabilities: {
          required: this.selectedCapabilities("required"),
          controllerRequired: controller
            ? this.selectedCapabilities("controllerRequired")
            : [],
        },
        integration: {
          platform: this.field("platform").value,
          autoRunAfterBuild: this.field("auto-run").checked,
          previewBridgePort: Number(this.field("preview-port").value || 0),
        },
      };
    },

    async reloadSettings() {
      this.setStatus("正在加载项目设置…");
      try {
        const state = await Editor.Message.request(
          packageName,
          "load-settings",
        );
        this.render(state);
        this.setStatus("项目设置已加载。");
      } catch (error) {
        this.setStatus(
          error instanceof Error ? error.message : String(error),
          true,
        );
      }
    },

    async save() {
      this.setStatus("正在保存…");
      try {
        await Editor.Message.request(
          packageName,
          "save-settings",
          this.collect(),
        );
        await this.reloadSettings();
        this.setStatus("项目设置已保存。下次构建或运行时生效。");
      } catch (error) {
        this.setStatus(
          error instanceof Error ? error.message : String(error),
          true,
        );
      }
    },
  },

  ready() {
    this.$.form.addEventListener("submit", (event) => {
      event.preventDefault();
      void this.save();
    });
    this.$.reload.addEventListener("click", () => {
      void this.reloadSettings();
    });
    this.field("mode").addEventListener("change", () => {
      this.updateVisibility();
    });
    this.field("display-mode").addEventListener("change", () => {
      this.updateVisibility();
    });
    void this.reloadSettings();
  },
});
