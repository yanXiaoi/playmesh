import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';

const here = path.dirname(fileURLToPath(import.meta.url));
const clientPath = path.resolve(
  here,
  '..',
  '..',
  '..',
  'developer',
  'gdevelop-editor-instance.js'
);
const source = await readFile(clientPath, 'utf8');

class MemoryStorage {
  constructor(entries = []) {
    this.values = new Map(entries);
  }
  getItem(key) {
    return this.values.has(key) ? this.values.get(key) : null;
  }
  setItem(key, value) {
    this.values.set(key, String(value));
  }
}

class LeaseServer {
  constructor() {
    this.lease = null;
    this.tokenIndex = 0;
    this.lastProtectedInput = null;
  }

  response(status, value = null) {
    return new Response(value === null ? null : JSON.stringify(value), {
      status,
      headers: value === null ? undefined : { 'Content-Type': 'application/json' },
    });
  }

  async fetch(input, init = {}) {
    const url = new URL(typeof input === 'string' ? input : input.url, 'http://app.test');
    if (url.pathname.endsWith('/editor-instance/acquire')) {
      const body = JSON.parse(init.body);
      if (!this.lease) {
        this.lease = this.createLease(body.instanceId, body.pageId);
        return this.response(200, { status: 'acquired', lease: this.lease });
      }
      if (
        body.resumeAfterReload === true &&
        body.instanceId === this.lease.instanceId &&
        body.previousLeaseToken === this.lease.leaseToken
      ) {
        this.lease = this.createLease(body.instanceId, body.pageId);
        return this.response(200, { status: 'resumed', lease: this.lease });
      }
      return this.response(409, { error: { code: 'occupied' } });
    }
    if (url.pathname.endsWith('/editor-instance/release')) {
      const body = JSON.parse(init.body);
      if (this.matches(body)) {
        this.lease = null;
        return this.response(204);
      }
      return this.response(409, { error: { code: 'stale' } });
    }
    if (url.pathname.endsWith('/editor-instance/heartbeat')) {
      return this.response(this.matches(JSON.parse(init.body)) ? 200 : 409, {});
    }
    if (url.pathname.startsWith('/dev/api/gdevelop/')) {
      this.lastProtectedInput = input;
      const headers = new Headers(init.headers);
      const valid = this.lease &&
        headers.get('X-Playmesh-GDevelop-Editor-Instance') === this.lease.instanceId &&
        headers.get('X-Playmesh-GDevelop-Editor-Page') === this.lease.pageId &&
        headers.get('X-Playmesh-GDevelop-Editor-Lease') === this.lease.leaseToken;
      return new Response(null, {
        status: valid ? 200 : 409,
        headers: { 'X-Test-Lease': valid ? 'current' : 'stale' },
      });
    }
    return this.response(200, {});
  }

  createLease(instanceId, pageId) {
    return {
      instanceId,
      pageId,
      leaseToken: `lease_${++this.tokenIndex}`,
      heartbeatIntervalMs: 15000,
    };
  }

  matches(value) {
    return this.lease && value.instanceId === this.lease.instanceId &&
      value.pageId === this.lease.pageId &&
      value.leaseToken === this.lease.leaseToken;
  }
}

const createPage = ({ server, pageId, storage, navigationType = 'navigate' }) => {
  const listeners = new Map();
  const document = {
    body: {},
    documentElement: { innerHTML: '' },
    getElementById: () => null,
  };
  const context = vm.createContext({
    Blob,
    Headers,
    Request,
    Response,
    URL,
    crypto: webcrypto,
    document,
    fetch: server.fetch.bind(server),
    location: {
      href: 'http://app.test/dev/workspace/gdevelop/',
      origin: 'http://app.test',
      reload() {},
    },
    navigator: { language: 'en-US', sendBeacon: () => true },
    performance: { getEntriesByType: () => [{ type: navigationType }] },
    sessionStorage: storage,
    setInterval: () => 1,
    clearInterval() {},
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    __PLAYMESH_GDEVELOP_EDITOR_INSTANCE_BOOTSTRAP__: { pageId },
  });
  vm.runInContext(source, context, { filename: clientPath });
  return { context, document, listeners, storage };
};

const server = new LeaseServer();
const appStorage = new MemoryStorage();
const app = createPage({
  server,
  pageId: 'app_page_00000001',
  storage: appStorage,
});
const firstLease = await app.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.ready;
assert.equal(app.listeners.has('beforeunload'), true);
assert.equal(app.listeners.has('pagehide'), true);
assert.equal(
  (await app.context.fetch('/dev/api/gdevelop/projects/project-a/preview')).status,
  200,
  'the App WebView owns the first editor lease'
);

const browser = createPage({
  server,
  pageId: 'browser_page_00001',
  storage: new MemoryStorage(),
});
await assert.rejects(
  browser.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.ready,
  /occupied/
);
assert.match(browser.document.documentElement.innerHTML, /already open elsewhere/);

const duplicate = createPage({
  server,
  pageId: 'app_page_00000002',
  storage: new MemoryStorage(appStorage.values.entries()),
  navigationType: 'navigate',
});
await assert.rejects(
  duplicate.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.ready,
  /occupied/,
  'a duplicated tab must not use the copied sessionStorage lease'
);

const refreshed = createPage({
  server,
  pageId: 'app_page_00000003',
  storage: new MemoryStorage(appStorage.values.entries()),
  navigationType: 'reload',
});
const refreshedLease =
  await refreshed.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.ready;
assert.notEqual(refreshedLease.leaseToken, firstLease.leaseToken);
assert.equal(
  (await app.context.fetch('/dev/api/gdevelop/projects/project-b/history')).status,
  409,
  'the page replaced by a refresh must lose mutation authority'
);
assert.equal(
  (await refreshed.context.fetch('/dev/api/gdevelop/projects/project-b/history')).status,
  200
);

const stream = new ReadableStream({
  start(controller) {
    controller.enqueue(new Uint8Array([1, 2, 3]));
    controller.close();
  },
});
const streamedRequest = new Request(
  'http://app.test/dev/api/gdevelop/projects/project-b/history/resources/hash',
  { method: 'PUT', body: stream, duplex: 'half' }
);
const streamedResponse = await refreshed.context.fetch(streamedRequest);
assert.equal(streamedResponse.status, 200);
assert.equal(server.lastProtectedInput, streamedRequest);
assert.equal(streamedRequest.bodyUsed, false, 'lease injection must not buffer the body');

assert.equal(
  await refreshed.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.release(),
  true
);
const browserAfterRelease = createPage({
  server,
  pageId: 'browser_page_00002',
  storage: new MemoryStorage(),
});
await browserAfterRelease.context.__PLAYMESH_GDEVELOP_EDITOR_INSTANCE_CLIENT__.ready;

console.log(
  'GDevelop editor single-instance client contract passed: App/browser and '
    + 'duplicate-tab conflicts, refresh recovery, stale-page rejection, '
    + 'stream preservation and explicit release are enforced.'
);
