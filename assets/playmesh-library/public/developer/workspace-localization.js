(() => {
  'use strict';

  const endpoint = '/dev/api/localization';
  const allowedThemes = new Set(['system', 'light', 'dark']);
  const allowedEffectiveThemes = new Set(['light', 'dark']);
  const injectedUi = window.__PLAYMESH_APP_UI__;
  const state = {
    localeId: '',
    localeMode: 'system',
    themeMode: allowedThemes.has(injectedUi?.themeMode)
      ? injectedUi.themeMode
      : '',
    effectiveTheme: allowedEffectiveThemes.has(injectedUi?.effectiveTheme)
      ? injectedUi.effectiveTheme
      : '',
    messages: Object.create(null),
    locales: [],
    allowLocaleSwitch: false,
    allowThemeSwitch: injectedUi?.allowThemeSwitch === true,
    refreshing: null,
  };

  function interpolate(template, argumentsValue) {
    let result = String(template);
    for (const [key, value] of Object.entries(argumentsValue || {})) {
      result = result.replaceAll(`{${key}}`, String(value ?? ''));
    }
    return result;
  }

  function t(key, argumentsValue = {}) {
    const template = state.messages[key];
    if (typeof template !== 'string') {
      throw new Error(`missing_localized_message:${key}`);
    }
    return interpolate(template, argumentsValue);
  }

  function applyTheme() {
    document.documentElement.dataset.theme = 'workspace';
    document.documentElement.style.colorScheme = 'dark';
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', '#0c1118');
  }

  function validateSnapshot(snapshot) {
    if (
      !snapshot ||
      snapshot.formatVersion !== '1.0.0' ||
      typeof snapshot.localeId !== 'string' ||
      typeof snapshot.allowLocaleSwitch !== 'boolean' ||
      !allowedThemes.has(snapshot.themeMode) ||
      !allowedEffectiveThemes.has(snapshot.effectiveTheme) ||
      typeof snapshot.allowThemeSwitch !== 'boolean' ||
      !Array.isArray(snapshot.locales) ||
      !snapshot.messages ||
      typeof snapshot.messages !== 'object'
    ) {
      throw new Error('invalid_localization_snapshot');
    }
    for (const locale of snapshot.locales) {
      if (
        !locale ||
        typeof locale.id !== 'string' ||
        typeof locale.label !== 'string'
      ) {
        throw new Error('invalid_localization_locale');
      }
    }
    for (const [key, value] of Object.entries(snapshot.messages)) {
      if (typeof key !== 'string' || typeof value !== 'string') {
        throw new Error('invalid_localization_message');
      }
    }
  }

  function applyElementMessages(root = document) {
    root.querySelectorAll('[data-i18n]').forEach((element) => {
      element.textContent = t(element.dataset.i18n);
    });
    for (const attribute of ['title', 'placeholder', 'aria-label', 'alt']) {
      const dataName = `i18n${attribute
        .split('-')
        .map((part) => part[0].toUpperCase() + part.slice(1))
        .join('')}`;
      root
        .querySelectorAll(`[data-i18n-${attribute}]`)
        .forEach((element) => {
          element.setAttribute(attribute, t(element.dataset[dataName]));
        });
    }
    document.title = t('workspace.title');
    document.documentElement.lang = state.localeId;
  }

  function applySnapshot(snapshot, { force = false } = {}) {
    validateSnapshot(snapshot);
    const changed =
      force ||
      snapshot.localeId !== state.localeId ||
      snapshot.themeMode !== state.themeMode ||
      snapshot.effectiveTheme !== state.effectiveTheme;
    state.localeId = snapshot.localeId;
    state.localeMode = snapshot.localeMode === 'fixed' ? 'fixed' : 'system';
    state.themeMode = snapshot.themeMode;
    state.effectiveTheme = snapshot.effectiveTheme;
    state.messages = Object.assign(Object.create(null), snapshot.messages);
    state.locales = snapshot.locales.slice();
    state.allowLocaleSwitch = snapshot.allowLocaleSwitch;
    state.allowThemeSwitch = snapshot.allowThemeSwitch;
    applyTheme();
    if (!changed) return;
    applyElementMessages();
    document.dispatchEvent(
      new CustomEvent('playmesh-ui-change', {
        detail: {
          theme: state.effectiveTheme,
          themeMode: state.themeMode,
          localeId: state.localeId,
        },
      }),
    );
  }

  async function requestSnapshot(options = {}) {
    const response = await fetch(endpoint, {
      cache: 'no-store',
      credentials: 'same-origin',
      ...options,
      headers: {
        Accept: 'application/json',
        ...(options.headers || {}),
      },
    });
    if (!response.ok) {
      throw new Error(`localization_request_failed:${response.status}`);
    }
    return response.json();
  }

  async function refresh({ force = false } = {}) {
    if (state.refreshing) return state.refreshing;
    state.refreshing = requestSnapshot()
      .then((snapshot) => applySnapshot(snapshot, { force }))
      .finally(() => {
        state.refreshing = null;
      });
    return state.refreshing;
  }

  function reportFailure(error) {
    const target = document.getElementById('message');
    if (!target) return;
    try {
      target.textContent = t('workspace.localization_error', {
        error: error?.message || String(error),
      });
    } catch (_) {
      target.textContent = `localization_error:${error?.message || error}`;
    }
  }

  applyTheme();
  const domReady =
    document.readyState === 'loading'
      ? new Promise((resolve) =>
          document.addEventListener('DOMContentLoaded', resolve, {
            once: true,
          }),
        )
      : Promise.resolve();
  const ready = Promise.all([domReady, requestSnapshot()])
    .then(([, snapshot]) => {
      applySnapshot(snapshot, { force: true });
    })
    .catch((error) => {
      reportFailure(error);
      throw error;
    });

  setInterval(() => {
    if (document.visibilityState === 'visible') {
      refresh().catch(reportFailure);
    }
  }, 1500);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') refresh().catch(reportFailure);
  });
  window.workspaceI18n = Object.freeze({
    ready,
    t,
    refresh,
    applyElementMessages,
    get localeId() {
      return state.localeId;
    },
    get themeMode() {
      return state.themeMode;
    },
    get effectiveTheme() {
      return state.effectiveTheme;
    },
  });
})();
