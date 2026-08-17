import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const runtimePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogRuntime.js'
);
let source = await readFile(runtimePath, 'utf8');

const removeFlowTypeDeclarations = value => {
  let result = value;
  const declaration = /^(?:export\s+)?type\s+[A-Za-z_$][A-Za-z0-9_$]*/m;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    let quote = null;
    let escaped = false;
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = match.index;
    for (; end < result.length; end++) {
      const character = result[end];
      if (quote) {
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === "'" || character === '"') {
        quote = character;
        continue;
      }
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        character === ';' &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        end++;
        break;
      }
    }
    result = result.slice(0, match.index) + result.slice(end);
  }
};

const removeFlowVariableAnnotations = value => {
  const declaration =
    /\b(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*:/g;
  let result = value;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    const colon = result.indexOf(':', match.index);
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = colon + 1;
    for (; end < result.length; end++) {
      const character = result[end];
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        (character === '=' || character === ';') &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        break;
      }
    }
    result = result.slice(0, colon) + result.slice(end);
    declaration.lastIndex = colon;
  }
};

const stripCatalogFlowTypes = value => {
  let result = value
    .replace(/^\/\/ @flow\s*/, '')
    .replace(/import type[\s\S]*?;\s*/g, '')
    .replace(/\/\*::[\s\S]*?\*\//g, '')
    .replace(
      /diagnostic\?:\s*\?\{\|[\s\S]*?\|\}(?=\s*\))/,
      'diagnostic'
    );
  result = removeFlowTypeDeclarations(result);
  result = removeFlowVariableAnnotations(result);
  return result
    .replace(/\bnew Promise<[^>]+>/g, 'new Promise')
    .replace(
      /^\s{2}(?:code|retryable|status|requestId|operation|stage|targetUrl|reason):\s*[^;]+;\s*$/gm,
      ''
    )
    .replace(
      /([A-Za-z_$][A-Za-z0-9_$]*)\??\s*:\s*\??(?:mixed|string|number|boolean|void|[A-Z$][A-Za-z0-9_$]*)(?:<[^\n()]*?>)?(?:\s*\|\s*(?:mixed|string|number|boolean|void|[A-Z$][A-Za-z0-9_$]*)(?:<[^\n()]*?>)?)*(?=\s*[,)=])/g,
      '$1'
    )
    .replace(
      /}\s*:\s*(?:\{\|[\s\S]*?\|}|[A-Za-z_$][A-Za-z0-9_$]*(?:<[^\n()]*?>)?)\s*\)/g,
      '})'
    )
    .replace(
      /\)\s*:\s*\??[A-Za-z_$][A-Za-z0-9_$]*(?:<[^;{}]*?>)?(?:\s*\|\s*\??[A-Za-z_$][A-Za-z0-9_$]*(?:<[^;{}]*?>)?)*\s*=>/g,
      ') =>'
    );
};

source = stripCatalogFlowTypes(source);
const remainingFlowType = source.match(
  /import type|export type|^type\s|new Promise<|:\s*(?:mixed|string|number|boolean|void|Promise<|Array<|PlaymeshCatalog|Catalog[A-Z])/m
);
if (remainingFlowType) {
  throw new Error(
    source.slice(
      Math.max(0, remainingFlowType.index - 80),
      remainingFlowType.index + 160
    )
  );
}

const calls = {
  fetch: 0,
  putArtifact: 0,
  removeArtifact: 0,
};
let cachedArtifact = null;
globalThis.__playmeshCatalogCacheMocks = {
  getArtifactCache: async () => cachedArtifact,
  getCatalogCache: async () => null,
  putArtifactCache: async (
    key,
    bytes,
    mediaType,
    contentHash,
    sourceIdentity
  ) => {
    calls.putArtifact++;
    cachedArtifact = { key, bytes, mediaType, contentHash, sourceIdentity };
  },
  putCatalogCache: async () => {},
  removeArtifactCache: async () => {
    calls.removeArtifact++;
    cachedArtifact = null;
  },
  removeCatalogCache: async () => {},
};
globalThis.__playmeshCatalogComputeSha256Hex = async bytes =>
  createHash('sha256').update(Buffer.from(bytes)).digest('hex');
globalThis.__playmeshCatalogSanitizeExternalUrl = value => {
  if (typeof value !== 'string' || !value) return '';
  const url = new URL(value);
  url.username = '';
  url.password = '';
  url.hash = '';
  return url.toString();
};

source = source.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshCatalogCache';/,
  `const {
  getArtifactCache,
  getCatalogCache,
  putArtifactCache,
  putCatalogCache,
  removeArtifactCache,
  removeCatalogCache,
} = globalThis.__playmeshCatalogCacheMocks;`
);
source = source
  .replace(
    "import { sha256Hex as computeSha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';",
    'const computeSha256Hex = globalThis.__playmeshCatalogComputeSha256Hex;'
  )
  .replace(
    "import { sanitizePlaymeshExternalUrl } from './PlaymeshExternalDownloadDiagnostic';",
    'const sanitizePlaymeshExternalUrl = globalThis.__playmeshCatalogSanitizeExternalUrl;'
  );
const runtime = await import(
  `data:text/javascript;base64,${Buffer.from(source, 'utf8').toString('base64')}`
);

globalThis.window = {
  crypto: webcrypto,
  setTimeout,
  clearTimeout,
};

const limits = {
  catalogFileBytes: 1024 * 1024,
  extensionBytes: 1024 * 1024,
  exampleProjectBytes: 1024 * 1024,
  exampleResourceBytes: 1024 * 1024,
  exampleTotalBytes: 4 * 1024 * 1024,
  exampleResourceCount: 32,
  licenseFileBytes: 1024 * 1024,
  licenseFileCount: 8,
  downloadConcurrency: 2,
  requestTimeoutMs: 500,
  retryCount: 0,
};

const responseFor = bytes => ({
  ok: true,
  status: 200,
  headers: {
    get: name => (name === 'content-length' ? String(bytes.byteLength) : null),
  },
  arrayBuffer: async () =>
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
});

const errorResponseFor = ({ status, code, reason, requestId, operation }) => {
  const bytes = new TextEncoder().encode(
    JSON.stringify({
      requestId,
      error: { code, reason, message: 'fixture failure' },
    })
  );
  return {
    ok: false,
    status,
    headers: {
      get: name => {
        const normalized = name.toLowerCase();
        if (normalized === 'content-length') return String(bytes.byteLength);
        if (normalized === 'x-request-id') return requestId;
        if (normalized === 'x-playmesh-operation-id') return operation;
        return null;
      },
    },
    arrayBuffer: async () =>
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
  };
};

const createArtifact = bytes => {
  const commit = 'c'.repeat(40);
  const rootTreeSha = 'd'.repeat(40);
  const sourcePath = 'extensions/reviewed/Fixture.json';
  return {
    id: 'extension:Fixture',
    kind: 'extension',
    repository: 'GDevelopApp/GDevelop-extensions',
    commit,
    rootTreeSha,
    path: sourcePath,
    url: `https://raw.githubusercontent.com/GDevelopApp/GDevelop-extensions/${commit}/${sourcePath}`,
    declaredBytes: bytes.byteLength,
    gitBlobOid: 'e'.repeat(40),
    sha256: createHash('sha256').update(bytes).digest('hex'),
    mediaType: 'application/json',
  };
};

assert.equal(
  runtime.validateCatalogManifest({
    schemaVersion: 1,
    catalogRevision: 'fixture',
    engine: { version: '5.6.276' },
    sources: {
      extensions: {
        repository: 'GDevelopApp/GDevelop-extensions',
        commit: '1'.repeat(40),
        rootTreeSha: '2'.repeat(40),
      },
      examples: {
        repository: 'GDevelopApp/GDevelop-examples',
        commit: '3'.repeat(40),
        rootTreeSha: '4'.repeat(40),
      },
    },
    limits,
    features: {
      extensions: {
        path: 'extensions-index.json',
        bytes: 1,
        sha256: 'a'.repeat(64),
      },
      examples: {
        path: 'examples-index.json',
        bytes: 1,
        sha256: 'b'.repeat(64),
      },
    },
  }).catalogRevision,
  'fixture'
);
assert.throws(
  () =>
    runtime.validateCatalogManifest({
      schemaVersion: 1,
      catalogRevision: 'fixture',
      engine: { version: '6.0.0' },
      limits,
      features: {},
    }),
  /不兼容/
);

const localManifest = {
  schemaVersion: 1,
  catalogRevision: 'same-origin-credentials',
  engine: { version: '5.6.276' },
  sources: {
    extensions: {
      repository: 'GDevelopApp/GDevelop-extensions',
      commit: '1'.repeat(40),
      rootTreeSha: '2'.repeat(40),
    },
    examples: {
      repository: 'GDevelopApp/GDevelop-examples',
      commit: '3'.repeat(40),
      rootTreeSha: '4'.repeat(40),
    },
  },
  limits,
  features: {
    extensions: {
      path: 'extensions-index.json',
      bytes: 1,
      sha256: 'a'.repeat(64),
    },
    examples: {
      path: 'examples-index.json',
      bytes: 1,
      sha256: 'b'.repeat(64),
    },
  },
};
const localManifestBytes = new TextEncoder().encode(
  JSON.stringify(localManifest)
);
globalThis.fetch = async (_url, options) => {
  assert.equal(options.credentials, 'same-origin');
  return responseFor(localManifestBytes);
};
assert.equal(
  (
    await runtime.loadRootCatalogManifest({
      url: 'http://127.0.0.1/gdevelop/playmesh/catalog/catalog-manifest.json',
      cacheKey: 'same-origin-credentials',
    })
  ).catalogRevision,
  'same-origin-credentials'
);

const validBytes = new TextEncoder().encode('{"name":"Fixture"}');
const artifact = createArtifact(validBytes);
assert.match(artifact.sha256, /^[a-f0-9]{64}$/);
assert.throws(
  () => runtime.validateArtifactUrl({ ...artifact, url: 'https://example.invalid/a' }),
  /URL 不匹配/
);
assert.throws(
  () => runtime.validateArtifactUrl({ ...artifact, path: '../Fixture.json' }),
  /越界/
);
assert.throws(
  () => runtime.validateArtifactUrl({ ...artifact, mediaType: 'image/png' }),
  /MIME/
);

globalThis.fetch = async (url, options) => {
  calls.fetch++;
  assert.equal(url, '/dev/api/gdevelop/catalog/artifact');
  assert.equal(options.method, 'POST');
  assert.equal(JSON.parse(options.body).sha256, artifact.sha256);
  return responseFor(validBytes);
};
const downloaded = await runtime.fetchCatalogArtifact({ artifact, limits });
assert.deepEqual(new Uint8Array(downloaded.bytes), validBytes);
assert.match(downloaded.contentHash, /^[a-f0-9]{64}$/);
assert.equal(calls.putArtifact, 1);
assert.equal(cachedArtifact.contentHash, downloaded.contentHash);

globalThis.fetch = async () => {
  calls.fetch++;
  throw new Error('cache should satisfy this request');
};
const fromLastKnownGood = await runtime.fetchCatalogArtifact({ artifact, limits });
assert.equal(fromLastKnownGood.contentHash, downloaded.contentHash);

cachedArtifact = {
  ...cachedArtifact,
  bytes: new Blob([new TextEncoder().encode('{"name":"Corrupt"}')]),
};
globalThis.fetch = async () => {
  calls.fetch++;
  return responseFor(validBytes);
};
const recovered = await runtime.fetchCatalogArtifact({ artifact, limits });
assert.equal(recovered.contentHash, downloaded.contentHash);
assert.equal(calls.removeArtifact, 1);

cachedArtifact = null;
globalThis.fetch = async () => responseFor(new TextEncoder().encode('{}'));
await assert.rejects(
  runtime.fetchCatalogArtifact({ artifact, limits }),
  error => error.code === 'declared_size_mismatch'
);

cachedArtifact = null;
globalThis.fetch = async () => {
  throw new TypeError('offline');
};
await assert.rejects(
  runtime.fetchCatalogArtifact({ artifact, limits }),
  error => error.code === 'gateway_unavailable' && error.retryable === true
);

cachedArtifact = null;
globalThis.fetch = async () =>
  errorResponseFor({
    status: 409,
    code: 'gdevelop_allocation_evidence_mismatch',
    reason: 'resource_manifest_mismatch',
    requestId: 'dev-catalog-fixture',
    operation: 'gdevelop.catalog.artifact.acquire',
  });
await assert.rejects(
  runtime.fetchCatalogArtifact({ artifact, limits }),
  error =>
    error.code === 'gdevelop_allocation_evidence_mismatch' &&
    error.status === 409 &&
    error.requestId === 'dev-catalog-fixture' &&
    error.operation === 'gdevelop.catalog.artifact.acquire' &&
    error.stage === 'artifact_download' &&
    error.reason === 'resource_manifest_mismatch' &&
    error.targetUrl === artifact.url
);

assert.equal(
  runtime.validateCatalogFeatureManifest({
    value: {
      schemaVersion: 1,
      kind: 'extensions',
      catalogRevision: 'fixture',
      engine: { version: '5.6.276' },
      source: {
        repository: 'GDevelopApp/GDevelop-extensions',
        commit: '1'.repeat(40),
        rootTreeSha: '2'.repeat(40),
      },
      index: {
        path: 'extensions-index.json',
        bytes: 1,
        sha256: 'a'.repeat(64),
      },
    },
    feature: 'extensions',
    rootManifest: runtime.validateCatalogManifest({
      schemaVersion: 1,
      catalogRevision: 'fixture',
      engine: { version: '5.6.276' },
      sources: {
        extensions: {
          repository: 'GDevelopApp/GDevelop-extensions',
          commit: '1'.repeat(40),
          rootTreeSha: '2'.repeat(40),
        },
        examples: {
          repository: 'GDevelopApp/GDevelop-examples',
          commit: '3'.repeat(40),
          rootTreeSha: '4'.repeat(40),
        },
      },
      limits,
      features: {
        extensions: { path: 'extensions-manifest.v1.json', bytes: 1, sha256: 'a'.repeat(64) },
        examples: { path: 'examples-manifest.v1.json', bytes: 1, sha256: 'b'.repeat(64) },
      },
    }),
  }).index.path,
  'extensions-index.json'
);

process.stdout.write(
  'GDevelop catalog runtime no-expected-hash/LKG tests passed.\n'
);
