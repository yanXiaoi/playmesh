// Host-only Android adapter. Ordinary browsers and Windows use native downloads.
const playmeshWebViewDownloadScript = r'''
(() => {
  const g = globalThis;
  if (g.top !== g || g.__playmeshDownloadRuntime || !g.PlaymeshDownloadBridge) return;
  const pending = new Map();
  let nextId = 0;
  const request = (operation, payload) => new Promise((resolve, reject) => {
    const id = String(++nextId);
    pending.set(id, {resolve, reject});
    g.PlaymeshDownloadBridge.postMessage(JSON.stringify({id, operation, ...payload}));
  });
  const settle = (id, result, error) => {
    const wait = pending.get(id);
    if (!wait) return;
    pending.delete(id);
    if (error) wait.reject(new Error(error)); else wait.resolve(result);
  };
  const download = (url, name) => {
    const generated = /^(blob:|data:)/i.test(url);
    // Start fetching before a typical anchor.click(); revokeObjectURL() pair.
    const source = generated ? fetch(url) : null;
    if (source) source.catch(() => {});
    return (async () => {
      let token = null;
      let reader = null;
      try {
        const response = source ? await source : null;
        if (response && !response.ok) throw new Error('Unable to read download');
        const opened = await request('open', {
          generated, name: name || (generated ? 'download' : null),
          ...(generated ? {
            type: response.headers.get('Content-Type') || '',
            size: response.headers.has('Content-Length') ? Number(response.headers.get('Content-Length')) : null,
          } : {url}),
        });
        if (!generated) return;
        token = opened.token;
        reader = response.body.getReader();
        let sequence = 0;
        while (true) {
          const {done, value} = await reader.read();
          if (done) break;
          for (let offset = 0; offset < value.length; offset += 256 * 1024) {
            const bytes = value.subarray(offset, offset + 256 * 1024);
            let binary = '';
            for (let i = 0; i < bytes.length; i += 8192) {
              binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
            }
            await request('write', {token, sequence: sequence++, data: btoa(binary)});
          }
        }
        await request('close', {token});
        token = null;
      } catch (error) {
        if (token) await request('abort', {token}).catch(() => {});
        if (error.message !== 'user_cancelled') console.error('Download failed:', error.message);
      } finally {
        if (reader) await reader.cancel().catch(() => {});
        else if (source) source.then(r => r.body?.cancel()).catch(() => {});
      }
    })();
  };
  const intercept = anchor => {
    if (!anchor || !anchor.hasAttribute('download')) return false;
    const url = anchor.href;
    if (!/^(https?:|blob:|data:)/i.test(url)) return false;
    download(url, anchor.download);
    return true;
  };
  const click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function() {
    if (!intercept(this)) return click.call(this);
  };
  document.addEventListener('click', event => {
    if (event.defaultPrevented || event.button !== 0) return;
    const anchor = event.composedPath().find(item => item instanceof HTMLAnchorElement);
    if (intercept(anchor)) event.preventDefault();
  });
  Object.defineProperty(g, '__playmeshDownloadRuntime', {
    value: Object.freeze({settle, download}), enumerable: false,
  });
})();
''';
