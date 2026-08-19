(() => {
  'use strict';

  const global = globalThis;
  if (global.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__) return;
  const bootstrap = global.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_BOOTSTRAP__;
  if (!bootstrap || typeof bootstrap.pageId !== 'string') return;

  const apiRoot = '/dev/api/gdevelop/editor-instance';
  const instanceKey = 'playmesh.gdevelop.editor.instance.v1';
  const leaseKey = 'playmesh.gdevelop.editor.lease.v1';
  const nativeFetch = global.fetch.bind(global);
  const storage = global.sessionStorage;
  const randomId = prefix => {
    const uuid = global.crypto && typeof global.crypto.randomUUID === 'function'
      ? global.crypto.randomUUID()
      : `${Date.now().toString(36)}_${Math.random().toString(36).slice(2)}_${Math.random().toString(36).slice(2)}`;
    return `${prefix}_${uuid.replace(/[^A-Za-z0-9_-]/g, '_')}`;
  };
  const instanceId = storage.getItem(instanceKey) || randomId('editor');
  storage.setItem(instanceKey, instanceId);
  const previousLeaseToken = storage.getItem(leaseKey);
  const navigation = global.performance &&
      typeof global.performance.getEntriesByType === 'function'
    ? global.performance.getEntriesByType('navigation')[0]
    : null;
  const resumeAfterReload = navigation && navigation.type === 'reload';

  let activeLease = null;
  let heartbeatTimer = null;
  let blocked = false;

  const jsonRequest = (path, body, options = {}) => nativeFetch(`${apiRoot}/${path}`, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    keepalive: options.keepalive === true,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  const localizedText = () => {
    const locale = String(
      global.__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__?.localeId ||
      global.navigator?.language ||
      'en'
    ).toLowerCase();
    return locale.startsWith('zh')
      ? {
          title: 'GDevelop 编辑器已在其他窗口中打开',
          detail: 'PlayMesh 同一时间只允许一个 GDevelop 编辑器实例。请返回已经打开的 App 页面或浏览器标签；关闭它后可在此重试。',
          retry: '重试',
        }
      : {
          title: 'GDevelop is already open elsewhere',
          detail: 'PlayMesh allows one GDevelop editor instance at a time. Return to the existing App page or browser tab, or close it before retrying here.',
          retry: 'Retry',
        };
  };

  const showOccupied = () => {
    if (blocked) return;
    blocked = true;
    if (heartbeatTimer !== null) global.clearInterval(heartbeatTimer);
    const render = () => {
      const text = localizedText();
      global.document.documentElement.innerHTML = `
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>${text.title}</title></head>
        <body style="margin:0;background:#1f1f29;color:#f5f3ff;font-family:system-ui,sans-serif;display:grid;min-height:100vh;place-items:center">
          <main style="max-width:560px;padding:32px;text-align:center">
            <h1 style="font-size:24px;margin:0 0 16px">${text.title}</h1>
            <p style="line-height:1.65;color:#cac6d8;margin:0 0 24px">${text.detail}</p>
            <button id="playmesh-editor-retry" style="border:0;border-radius:8px;padding:11px 22px;background:#6c43e0;color:white;font:inherit;cursor:pointer">${text.retry}</button>
          </main>
        </body>`;
      global.document.getElementById('playmesh-editor-retry')
        ?.addEventListener('click', () => global.location.reload());
    };
    if (global.document.body) render();
    else global.addEventListener('DOMContentLoaded', render, { once: true });
  };

  const acquire = async () => {
    const response = await jsonRequest('acquire', {
      instanceId,
      pageId: bootstrap.pageId,
      previousLeaseToken,
      resumeAfterReload: Boolean(resumeAfterReload),
    });
    if (response.status === 409) {
      showOccupied();
      throw new Error('playmesh_gdevelop_editor_occupied');
    }
    if (!response.ok) throw new Error(`playmesh_gdevelop_editor_acquire_${response.status}`);
    const payload = await response.json();
    activeLease = payload.lease;
    storage.setItem(leaseKey, activeLease.leaseToken);
    heartbeatTimer = global.setInterval(() => {
      if (!activeLease || blocked) return;
      jsonRequest('heartbeat', activeLease)
        .then(response => {
          if (response.status === 409 || response.status === 401) showOccupied();
        })
        .catch(() => {
          // A transient network error does not transfer ownership. The bounded
          // Gateway TTL remains the authority for crash recovery.
        });
    }, activeLease.heartbeatIntervalMs);
    return activeLease;
  };

  const ready = acquire().catch(error => {
    if (!blocked) showOccupied();
    throw error;
  });

  const isProtectedGDevelopApi = input => {
    try {
      const value = typeof input === 'string' || input instanceof URL
        ? input
        : input.url;
      const url = new URL(value, global.location.href);
      const isGDevelopApi =
        url.pathname.startsWith('/dev/api/gdevelop/') &&
        !url.pathname.startsWith(`${apiRoot}/`);
      const isSharedApprovalApi =
        url.pathname === '/dev/api/ai-approvals' ||
        url.pathname.startsWith('/dev/api/ai-approvals/') ||
        url.pathname === '/dev/api/ai-approval-grants' ||
        url.pathname.startsWith('/dev/api/ai-approval-grants/');
      return url.origin === global.location.origin &&
        (isGDevelopApi || isSharedApprovalApi);
    } catch (_) {
      return false;
    }
  };

  global.fetch = async (input, init = undefined) => {
    if (!isProtectedGDevelopApi(input)) return nativeFetch(input, init);
    const lease = await ready;
    const inheritedHeaders = init?.headers ||
      (typeof Request !== 'undefined' && input instanceof Request
        ? input.headers
        : undefined);
    const headers = new Headers(inheritedHeaders);
    headers.set('X-Playmesh-GDevelop-Editor-Instance', lease.instanceId);
    headers.set('X-Playmesh-GDevelop-Editor-Page', lease.pageId);
    headers.set('X-Playmesh-GDevelop-Editor-Lease', lease.leaseToken);
    return nativeFetch(input, { ...init, headers });
  };

  const release = ({ beacon = false } = {}) => {
    if (!activeLease) return Promise.resolve(false);
    const lease = activeLease;
    activeLease = null;
    if (heartbeatTimer !== null) global.clearInterval(heartbeatTimer);
    heartbeatTimer = null;
    if (beacon && global.navigator && typeof global.navigator.sendBeacon === 'function') {
      const sent = global.navigator.sendBeacon(
        `${apiRoot}/release`,
        new Blob([JSON.stringify(lease)], { type: 'application/json' })
      );
      return Promise.resolve(sent);
    }
    return jsonRequest('release', lease, { keepalive: true })
      .then(response => response.ok)
      .catch(() => false);
  };

  global.addEventListener('beforeunload', () => {
    void release({ beacon: true });
  });
  global.addEventListener('pagehide', event => {
    if (!event.persisted) void release({ beacon: true });
  });
  global.__playmeshReleaseGDevelopEditorInstance = release;
  global.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__ = Object.freeze({
    instanceId,
    pageId: bootstrap.pageId,
    ready,
    release,
  });
})();
