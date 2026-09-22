import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('packages/playmesh_file_system_access/lib/src/webview_download_script.dart', 'utf8');
const script = source.split("r'''")[1].split("''';")[0];

function harness({cancel = false} = {}) {
  const requests = [];
  const urls = new Map();
  const clicks = [];
  const listeners = new Map();
  let context;
  class Anchor {
    constructor(url, download) { this.href = url; this.download = download; }
    hasAttribute(name) { return name === 'download' && this.download !== null; }
    click() { clicks.push(this.href); }
  }
  context = vm.createContext({
    Map, URL, Promise, String, Object, Number, HTMLAnchorElement: Anchor,
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    console: {error() {}},
    document: {addEventListener: (name, callback) => listeners.set(name, callback)},
    fetch: url => {
      const bytes = urls.get(url);
      assert.ok(bytes, 'Blob fetch starts before immediate revokeObjectURL');
      return Promise.resolve(new Response(bytes, {headers: {'Content-Length': String(bytes.length)}}));
    },
    PlaymeshDownloadBridge: {postMessage(raw) {
      const message = JSON.parse(raw);
      requests.push(message);
      queueMicrotask(() => context.__playmeshDownloadRuntime.settle(
        message.id, message.operation === 'open' ? {token: 'selected-file'} : null,
        cancel && message.operation === 'open' ? 'user_cancelled' : null,
      ));
    }},
  });
  context.top = context;
  vm.runInContext(script, context);
  return {context, requests, urls, Anchor, clicks, listeners};
}

{
  const h = harness();
  const bytes = Uint8Array.from({length: 700_003}, (_, i) => i % 251);
  h.urls.set('blob:recording', bytes);
  await h.context.__playmeshDownloadRuntime.download('blob:recording', 'recording.webm');
  assert.equal(h.requests[0].operation, 'open');
  assert.equal(h.requests[0].size, bytes.length);
  const chunks = h.requests.filter(r => r.operation === 'write');
  assert.deepEqual(chunks.map(r => r.sequence), [0, 1, 2]);
  assert.ok(chunks.every(r => Buffer.from(r.data, 'base64').length <= 256 * 1024));
  assert.deepEqual(Buffer.concat(chunks.map(r => Buffer.from(r.data, 'base64'))), Buffer.from(bytes));
  assert.equal(h.requests.at(-1).operation, 'close');
  assert.ok(h.requests.every(r => !('path' in r) && !('cookie' in r)));
}
{
  const h = harness();
  h.urls.set('blob:detached', Uint8Array.from([0, 255, 7]));
  new h.Anchor('blob:detached', 'clip.mp4').click();
  h.urls.delete('blob:detached');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.requests.at(-1).operation, 'close');
  assert.deepEqual(h.clicks, []);
  new h.Anchor('https://example.test/page', null).click();
  assert.deepEqual(h.clicks, ['https://example.test/page']);
  vm.runInContext(script, h.context);
  await h.context.__playmeshDownloadRuntime.download('https://example.test/file', 'file.zip');
  const http = h.requests.at(-1);
  assert.equal(http.operation, 'open');
  assert.equal(http.generated, false);
  assert.equal(http.url, 'https://example.test/file');
  await h.context.__playmeshDownloadRuntime.download('https://example.test/video.mp4', '');
  assert.equal(h.requests.at(-1).name, null, 'An empty download attribute preserves the URL filename fallback');
}
{
  const h = harness({cancel: true});
  h.urls.set('data:test', Uint8Array.from([1, 2, 3]));
  await h.context.__playmeshDownloadRuntime.download('data:test', 'cancel.bin');
  assert.deepEqual(h.requests.map(r => r.operation), ['open']);
}
console.log('WebView download script: bounded chunks, Blob lifetime, native HTTP, cancellation and ordinary navigation passed.');
