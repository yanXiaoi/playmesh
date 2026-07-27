(() => {
  const captchaConstructors = {
    text: "Click",
    slide: "Slide",
    rotate: "Rotate"
  };

  class CaptchaController {
    constructor(root, translate, callbacks = {}) {
      this.root = root;
      this.t = translate;
      this.callbacks = callbacks;
      this.instance = null;
      this.mode = "";
      this.data = null;
      this.busy = false;
    }

    destroyComponent() {
      this.instance?.destroy();
      this.instance = null;
      this.root.replaceChildren();
    }

    setLoading() {
      this.busy = false;
      this.mode = "";
      this.data = null;
      this.destroyComponent();
      this.root.setAttribute("aria-busy", "true");
      const loading = document.createElement("div");
      loading.className = "captcha-host-state";
      const spinner = document.createElement("span");
      spinner.className = "captcha-host-spinner";
      spinner.setAttribute("aria-hidden", "true");
      const label = document.createElement("span");
      label.textContent = this.t("admin.captcha.loading");
      loading.append(spinner, label);
      this.root.appendChild(loading);
    }

    setError(message) {
      this.busy = false;
      this.mode = "";
      this.data = null;
      this.destroyComponent();
      this.root.removeAttribute("aria-busy");
      const error = document.createElement("div");
      error.className = "captcha-host-state is-error";
      error.textContent = message;
      this.root.appendChild(error);
    }

    configFor(result) {
      if (result.mode === "text") {
        return {
          width: Number(result.imageWidth) || 320,
          height: Number(result.imageHeight) || 200,
          thumbWidth: 120,
          thumbHeight: 44,
          title: this.t("admin.captcha.select_prompt", "", {
            count: result.requiredClicks || 0
          }),
          buttonText: this.t("auth.captcha_continue")
        };
      }
      if (result.mode === "slide") {
        return {
          width: Number(result.imageWidth) || 320,
          height: Number(result.imageHeight) || 200,
          title: this.t("admin.captcha.slide_prompt")
        };
      }
      const size = Number(result.imageWidth) || 200;
      return {
        width: size,
        height: Number(result.imageHeight) || size,
        size,
        title: this.t("admin.captcha.rotate_prompt")
      };
    }

    componentData(result) {
      if (result.mode === "text") {
        return { image: result.image, thumb: result.promptImage };
      }
      if (result.mode === "slide") {
        return {
          image: result.image,
          thumb: result.pieceImage,
          thumbX: Number(result.pieceX) || 0,
          thumbY: Number(result.pieceY) || 0,
          thumbWidth: Number(result.pieceWidth) || 0,
          thumbHeight: Number(result.pieceHeight) || 0
        };
      }
      return {
        image: result.image,
        thumb: result.pieceImage,
        angle: 0,
        thumbSize: Number(result.pieceWidth || result.pieceHeight) || 0
      };
    }

    load(result) {
      const constructorName = captchaConstructors[result.mode];
      const Captcha = window.GoCaptcha?.[constructorName];
      if (!Captcha) {
        this.setError(this.t("admin.captcha.failed"));
        return;
      }

      this.destroyComponent();
      this.root.removeAttribute("aria-busy");
      this.mode = result.mode;
      this.data = result;
      this.busy = false;
      this.instance = new Captcha(this.configFor(result));
      this.instance.mount(this.root);
      this.instance.setEvents({
        refresh: () => {
          if (!this.busy) this.callbacks.refresh?.();
        },
        close: () => {
          if (!this.busy) this.callbacks.close?.();
        },
        confirm: (value, reset) => {
          let answer = "";
          if (result.mode === "text") {
            answer = `click:${value.map(
              (point) => `${Math.round(point.x)},${Math.round(point.y)}`
            ).join("|")}`;
          } else if (result.mode === "slide") {
            answer = `slide:${Math.round(value.x)},${Math.round(value.y)}`;
          } else {
            answer = `rotate:${Math.round(value)}`;
          }
          this.submit(answer, reset);
        }
      });
      this.instance.setData(this.componentData(result));
    }

    async submit(answer, reset) {
      if (this.busy || !answer) return;
      this.busy = true;
      try {
        await this.callbacks.confirm?.(answer, reset);
      } finally {
        this.busy = false;
      }
    }

    relocalize() {
      if (this.data) this.load(this.data);
    }

    clear() {
      this.instance?.clear();
      this.busy = false;
    }
  }

  const messageIcons = {
    success: "✓",
    error: "!",
    warning: "!",
    info: "i"
  };

  function messageContainer() {
    let container = document.querySelector("[data-playmesh-message-stack]");
    if (container) {
      if (!container.matches(":popover-open")) container.showPopover();
      return container;
    }
    container = document.createElement("div");
    container.dataset.playmeshMessageStack = "true";
    container.className = "message-stack";
    container.setAttribute("popover", "manual");
    container.setAttribute("aria-live", "polite");
    container.setAttribute("aria-atomic", "false");
    document.body.appendChild(container);
    container.showPopover();
    return container;
  }

  function showMessage(type, message, duration = 3200) {
    const text = String(message || "").trim();
    if (!text) return { close() {} };
    const element = document.createElement("div");
    element.className = `floating-message is-${type}`;
    element.setAttribute("role", type === "error" ? "alert" : "status");
    const icon = document.createElement("span");
    icon.className = "floating-message-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = messageIcons[type] || messageIcons.info;
    const content = document.createElement("span");
    content.className = "floating-message-content";
    content.textContent = text;
    element.append(icon, content);
    messageContainer().appendChild(element);
    requestAnimationFrame(() => element.classList.add("is-visible"));

    let timer;
    const close = () => {
      clearTimeout(timer);
      if (!element.isConnected || element.classList.contains("is-leaving")) return;
      element.classList.add("is-leaving");
      element.classList.remove("is-visible");
      setTimeout(() => {
        const container = element.parentElement;
        element.remove();
        if (container && !container.children.length) {
          container.hidePopover();
          container.remove();
        }
      }, 180);
    };
    timer = setTimeout(close, Math.max(1200, Number(duration) || 3200));
    return { close };
  }

  window.PlaymeshCaptcha = CaptchaController;
  window.PlaymeshMessage = Object.freeze({
    success: (message, duration) => showMessage("success", message, duration),
    error: (message, duration) => showMessage("error", message, duration),
    warning: (message, duration) => showMessage("warning", message, duration),
    info: (message, duration) => showMessage("info", message, duration)
  });
})();
