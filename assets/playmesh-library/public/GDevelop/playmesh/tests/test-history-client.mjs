import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryClient.js'
  ),
  'utf8'
);
const stripHistoryClientFlowTypes = value =>
  value
    .replace(/^\/\/ @flow\s*/, '')
    .replace(/import type [\s\S]*?;\s*/g, '')
    .replace(
      /type PlaymeshProjectMutationLease =[\s\S]*?const CAPABILITY/,
      'const CAPABILITY'
    )
    .replace(
      /\n  (?:status: number;|requestId: \?string;|operation: \?string;|stage: string;|reason: string;|errorType: string;|code: string;|details: mixed;)/g,
      ''
    )
    .replace(
      /diagnostics:\s*\{\|[\s\S]*?\|\}\s*=\s*\{\}/,
      'diagnostics = {}'
    )
    .replace(/\(value: MixedRecord\)/g, 'value')
    .replace(/\blet project:\s*PlaymeshHistoryJsonObject;/, 'let project;')
    .replace(/\blet rawResponse:\s*mixed;/, 'let rawResponse;')
    .replace(
      /([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*'(?:[^']+)'(?:\s*\|\s*'[^']+')+/g,
      '$1'
    )
    .replace(
      /\b(const|let) ([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*(?:any|mixed|PlaymeshHistoryJsonObject|Map<string, string>|Map<string, number>|Map<string, PreparedPlaymeshHistoryResource>|Set<string>|Array<string>|Array<PreparedPlaymeshHistoryResource>|Array<StoredProjectResource>)\s*=/g,
      '$1 $2 ='
    )
    .replace(
      /([A-Za-z_$][A-Za-z0-9_$]*)(?:\?)?\s*:\s*\??(?:any|mixed|string|number|boolean|Blob|AbortSignal|Response|PlaymeshHistoryError|PlaymeshHistoryReason|PlaymeshHistorySource|PlaymeshHistorySnapshotReason|PlaymeshHistoryJsonValue|PlaymeshHistoryJsonObject|PlaymeshHistoryVersion|PlaymeshHistoryResourceDto|PlaymeshHistoryResourcePreview|PlaymeshHistorySnapshot|PlaymeshHistoryCurrentResponse|PlaymeshHistoryListResponse|PlaymeshHistoryDiff|PlaymeshHistoryRestoreResult|PlaymeshHistoryRequestOptions|PlaymeshHistoryStatusError|PlaymeshHistorySyncOptions|PlaymeshHistoryRestoreOptions|PlaymeshHistoryMaterializeOptions|PlaymeshHistoryMaterializedSnapshot|ExecutePlaymeshHistorySyncOptions|ExecutePlaymeshHistoryRestoreOptions|PreparedPlaymeshHistoryResource|PreparedPlaymeshHistorySnapshot|StoredProjectResource|PlaymeshProjectMutationLease|Map<string, string>|\$ReadOnlyArray<any>|\$ReadOnlyArray<PreparedPlaymeshHistoryResource>|\$ReadOnlyArray<PlaymeshHistoryResourceDto>|\$ReadOnlyArray<StoredProjectResource>)(?=\s*[,)=])/g,
      '$1'
    )
    .replace(
      /}\s*:\s*(?:ExecutePlaymeshHistorySyncOptions|ExecutePlaymeshHistoryRestoreOptions)\)/g,
      '})'
    )
    .replace(
      /resources:\s*Array<PreparedPlaymeshHistoryResource>\s*\)/g,
      'resources)'
    )
    .replace(/\)\s*:\s*\{\|[\s\S]*?\|\}\s*=>/g, ') =>')
    .replace(/\)\s*:\s*\??[A-Za-z_$][A-Za-z0-9_$?<>,\[\]' |]*\s*=>/g, ') =>')
    .replace(/\((await response\.json\(\)): mixed\)/g, '$1')
    .replace(/\((JSON\.parse\([\s\S]*?\)): mixed\)/g, '$1');

source = stripHistoryClientFlowTypes(source)
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/PlaymeshProjectMutation\/PlaymeshProjectMutationCoordinator';/,
    `const assertPlaymeshProjectMutationLease = lease => lease;
const runPlaymeshProjectMutation = async ({ gameId, operation }) =>
  operation({ gameId });`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryEvidence';/,
    `const hashPlaymeshHistoryBlob = async blob => {
  globalThis.__playmeshHistoryHashCount++;
  const digest = await window.crypto.subtle.digest(
    'SHA-256',
    await blob.arrayBuffer()
  );
  return Array.from(new Uint8Array(digest), byte =>
    byte.toString(16).padStart(2, '0')
  ).join('');
};
const createPlaymeshHistoryResourceDto = async resource => {
  const contentHash = await hashPlaymeshHistoryBlob(resource.blob);
  if (resource.contentHash && resource.contentHash !== contentHash) {
    throw new Error('resource_corrupt');
  }
  if (resource.blob.size < 1) throw new Error('invalid resource size');
  return {
    logicalId: resource.logicalUrl,
    ...(resource.name !== undefined ? { name: resource.name } : {}),
    contentHash,
    mime: resource.blob.type || 'application/octet-stream',
    size: resource.blob.size,
    ...(resource.metadata !== undefined ? { metadata: resource.metadata } : {}),
  };
};
const encodePlaymeshHistoryCanonicalJson = value =>
  new TextEncoder().encode(JSON.stringify(value, Object.keys(value || {}).sort()));`
  );
const remainingFlowType = source.match(
  /import type|export type|:\s*(?:mixed|string|number|boolean|Blob|AbortSignal|Promise<|Map<|Array<|\$ReadOnlyArray<|PlaymeshHistory)/
);
if (remainingFlowType) {
  throw new Error(
    source.slice(
      Math.max(0, remainingFlowType.index - 80),
      remainingFlowType.index + 120
    )
  );
}
const gameId = 'com.playmesh.game.ghistory001';
const base = `/dev/api/gdevelop/projects/${gameId}/history`;
const historyVersion = (revision, reason = 'explicit_save') => ({
  id: `${gameId}-${revision}`,
  gameId,
  revision,
  timestamp: `2026-08-05T00:00:0${revision}.000Z`,
  reason,
  contentHash: revision.toString(16).padStart(64, '0'),
  source: 'user',
  contentBytes: 128 + revision,
});
const events = [];
const calls = [];
let presenceCalls = 0;
let phase = 'sync';
let validationCount = 0;
globalThis.__playmeshHistoryHashCount = 0;

globalThis.CustomEvent = class CustomEvent {
  constructor(type, options) {
    this.type = type;
    this.detail = options.detail;
  }
};
globalThis.window = {
  crypto: webcrypto,
  setTimeout,
  clearTimeout,
  dispatchEvent: event => events.push(event),
};
globalThis.URL.createObjectURL = () => 'blob:validated-resource';
globalThis.URL.revokeObjectURL = () => {};
globalThis.global.gd = {
  ProjectHelper: {
    createNewGDJSProject: () => ({
      unserializeFrom: () => {
        validationCount++;
      },
      delete: () => {},
    }),
  },
  Serializer: {
    fromJSObject: value => ({ value, delete: () => {} }),
  },
};

const restoredBytes = new Uint8Array([4, 5, 6, 7]);
const restoredHash = createHash('sha256')
  .update(restoredBytes)
  .digest('hex');
const currentResourceFixtures = Array.from({ length: 9 }, (_, index) => {
  const bytes = new Uint8Array([index + 10, index + 20, index + 30]);
  return {
    bytes,
    logicalId: `playmesh-local-resource://current/resource-${index}`,
    name: `resource-${index}.bin`,
    contentHash: createHash('sha256').update(bytes).digest('hex'),
    mime: 'application/octet-stream',
    size: bytes.byteLength,
  };
});
let activeCurrentResourceRequests = 0;
let maxActiveCurrentResourceRequests = 0;
const jsonResponse = (status, body, responseHeaders = {}) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: {
    get: name => responseHeaders[name.toLowerCase()] || null,
  },
  json: async () => body,
});

globalThis.fetch = async (url, options = {}) => {
  calls.push({ url, options });
  const method = options.method || 'GET';
  if (phase === 'error') {
    return jsonResponse(
      409,
      {
        requestId: 'history-request-9',
        error: {
          code: 'gdevelop_revision_conflict',
          message: 'revision changed',
          reason: 'revision changed',
          stage: 'gateway_response',
          type: 'DeveloperGatewayError',
          currentRevision: 9,
        },
      },
      {
        'x-request-id': 'history-request-9',
        'x-playmesh-operation-id': 'gdevelop.history.list',
      }
    );
  }
  if (url === `${base}/current` && method === 'GET') {
    const uncheckedManifest =
      phase === 'materialize-current-unchecked-manifest';
    return jsonResponse(200, {
      capability: uncheckedManifest
        ? 'unvalidated-current-capability'
        : 'gdevelop.history.v2',
      gameId: uncheckedManifest ? 42 : gameId,
      current:
        phase === 'materialize-current' ||
        phase === 'materialize-current-corrupt' ||
        phase === 'materialize-current-resource-error' ||
        uncheckedManifest
          ? {
              version: uncheckedManifest
                ? {
                    ...historyVersion(3),
                    revision: 'unvalidated-revision',
                    reason: 'unvalidated-reason',
                    contentBytes: 'unvalidated-size',
                  }
                : historyVersion(3),
              project: uncheckedManifest
                ? ['official-gdevelop-will-validate-this-project']
                : {
                    properties: { packageName: gameId },
                    resources: currentResourceFixtures.map(resource => ({
                      file: resource.logicalId,
                    })),
                  },
              resources: currentResourceFixtures.map(
                ({ bytes, ...resource }, index) =>
                  uncheckedManifest && index === 0
                    ? {
                        ...resource,
                        size: 'unvalidated-size',
                        mime: 'image/x-playmesh-current-fixture',
                      }
                    : resource
              ),
            }
          : null,
    });
  }
  if (url === `${base}/resources/presence`) {
    presenceCalls++;
    const request = JSON.parse(options.body);
    return jsonResponse(200, {
      gameId,
      missing: presenceCalls === 1 ? [request.resources[0]] : [],
      available: [],
    });
  }
  if (url.startsWith(`${base}/resources/`) && method === 'PUT') {
    const contentHash = url.slice(`${base}/resources/`.length);
    return jsonResponse(200, {
      contentHash,
      size: options.body.size,
      staged: true,
    });
  }
  if (url === `${base}/current` && method === 'PUT') {
    const request = JSON.parse(options.body);
    assert.equal('reason' in request, false);
    assert.equal(request.baseRevision, 0);
    return jsonResponse(200, {
      gameId,
      current: historyVersion(1),
      historyCreated: false,
    });
  }
  if (url === `${base}/snapshots` && method === 'POST') {
    const request = JSON.parse(options.body);
    assert.equal(request.reason, 'explicit_save');
    assert.equal(request.baseRevision, 1);
    return jsonResponse(200, {
      gameId,
      version: historyVersion(2),
      deduplicated: false,
      historyCreated: true,
    });
  }
  if (url.startsWith(`${base}/diff?`)) {
    const beforeHash = '1'.repeat(64);
    const afterHash = '2'.repeat(64);
    const response = {
      gameId,
      fromRevision: 1,
      toRevision: 2,
      changed: true,
      before: '{"revision":1}',
      after: '{"revision":2}',
      summary: {
        addedLines: 1,
        removedLines: 0,
        resources: { added: 0, removed: 0, changed: 0 },
      },
      resourceEvidence: {
        before: [
          {
            logicalId: 'playmesh-local-resource://history/hero-v1.png',
            name: 'hero.png',
            contentHash: beforeHash,
            mime: 'image/png',
            size: 128,
          },
          {
            logicalId: 'playmesh-local-resource://history/data.json',
            contentHash: '3'.repeat(64),
            mime: 'application/json',
            size: 32,
          },
        ],
        after: [
          {
            logicalId: 'playmesh-local-resource://history/hero-v2.png',
            name: 'hero.png',
            contentHash: afterHash,
            mime: 'image/png',
            size: 256,
          },
        ],
      },
    };
    if (phase === 'invalid-diff') delete response.resourceEvidence;
    return jsonResponse(200, response);
  }
  if (url === `${base}/restore` && method === 'POST') {
    const request = JSON.parse(options.body);
    assert.equal(request.baseRevision, 2);
    assert.equal(request.targetRevision, 1);
    return jsonResponse(200, {
      gameId,
      restored: {
        version: historyVersion(3, 'restore'),
        project: {
          properties: { packageName: gameId },
          resources: [{ file: 'playmesh-local-resource://restored' }],
        },
        resources: [
          {
            logicalId: 'playmesh-local-resource://restored',
            name: 'restored.bin',
            contentHash: restoredHash,
            mime: 'application/octet-stream',
            size: restoredBytes.byteLength,
          },
        ],
      },
    });
  }
  if (url === `${base}/resources/${restoredHash}` && method === 'GET') {
    return {
      ok: true,
      status: 200,
      blob: async () =>
        new Blob([
          phase === 'restore-corrupt'
            ? new Uint8Array(restoredBytes.length + 1)
            : restoredBytes,
        ]),
    };
  }
  const currentResource = currentResourceFixtures.find(
    resource => url === `${base}/resources/${resource.contentHash}`
  );
  if (currentResource && method === 'GET') {
    if (
      phase === 'materialize-current-resource-error' &&
      currentResource === currentResourceFixtures[0]
    ) {
      return jsonResponse(503, {
        error: { code: 'current_resource_unavailable' },
      });
    }
    activeCurrentResourceRequests++;
    maxActiveCurrentResourceRequests = Math.max(
      maxActiveCurrentResourceRequests,
      activeCurrentResourceRequests
    );
    await new Promise(resolve => setTimeout(resolve, 5));
    activeCurrentResourceRequests--;
    return {
      ok: true,
      status: 200,
      blob: async () =>
        new Blob([
          phase === 'materialize-current-corrupt' &&
          currentResource === currentResourceFixtures[0]
            ? new Uint8Array(currentResource.bytes.length + 1)
            : currentResource.bytes,
        ]),
    };
  }
  throw new Error(`Unexpected history request: ${method} ${url}`);
};

const history = await import(`data:text/javascript;base64,${Buffer.from(
  source
).toString('base64')}`);

assert.throws(
  () =>
    history.syncPlaymeshHistory({
      gameId,
      snapshot: {
        project: { properties: { packageName: gameId } },
        resources: [],
      },
      source: 'ai',
      reason: null,
    }),
  error => error.code === 'invalid_history_source',
  'ordinary history must not retain the removed AI source compatibility'
);
assert.throws(
  () =>
    history.syncPlaymeshHistory({
      gameId,
      snapshot: {
        project: { properties: { packageName: gameId } },
        resources: [],
      },
      source: 'user',
      reason: 'ai_turn',
    }),
  error => error.code === 'invalid_history_reason',
  'ordinary history must not retain the removed AI turn reason compatibility'
);

const sharedLogicalUrl = 'playmesh-local-resource://shared/sprite.png';
const sharedBlob = new Blob([new Uint8Array([9, 8, 7])], {
  type: 'image/png',
});
const canonicalAliases = await history.preparePlaymeshHistorySnapshot({
  project: {
    properties: { packageName: gameId },
    resources: [
      { name: 'Primary', file: sharedLogicalUrl },
      { name: 'Alias', file: sharedLogicalUrl },
    ],
  },
  resources: [
    { logicalUrl: sharedLogicalUrl, name: 'Primary', blob: sharedBlob },
    {
      logicalUrl: sharedLogicalUrl,
      name: 'Alias',
      blob: new Blob([new Uint8Array([9, 8, 7])], { type: 'image/png' }),
    },
  ],
});
assert.equal(
  canonicalAliases.resources.length,
  1,
  'byte-identical aliases sharing one logicalId must produce one manifest pin'
);
assert.equal(canonicalAliases.resources[0].name, 'Alias');
await assert.rejects(
  history.preparePlaymeshHistorySnapshot({
    project: { properties: { packageName: gameId } },
    resources: [
      { logicalUrl: sharedLogicalUrl, blob: sharedBlob },
      {
        logicalUrl: sharedLogicalUrl,
        blob: new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' }),
      },
    ],
  }),
  error =>
    error.code === 'resource_logical_id_conflict' &&
    error.operation === 'gdevelop.history.snapshot.prepare' &&
    error.reason === 'resource_logical_id_conflict'
);

const resources = await Promise.all(
  Array.from({ length: 2050 }, async (_, index) => {
    const bytes = new Uint8Array(4);
    new DataView(bytes.buffer).setUint32(0, index);
    return {
      logicalUrl: `playmesh-local-resource://${index}`,
      name: `r${index}`,
      contentHash: createHash('sha256')
        .update(bytes)
        .digest('hex'),
      blob: new Blob([bytes]),
    };
  })
);

const currentResult = await history.syncPlaymeshHistory({
  gameId,
  snapshot: { project: { properties: { packageName: gameId } }, resources },
  source: 'user',
  reason: null,
});
assert.equal(currentResult.current.revision, 1);
assert.equal(presenceCalls, 2);
assert.equal(
  calls.filter(
    call => call.options.method === 'PUT' && call.url.includes('/resources/')
  ).length,
  1,
  'only presence-missing Blob is uploaded'
);

await history.syncPlaymeshHistory({
  gameId,
  snapshot: { project: { properties: { packageName: gameId } }, resources: [] },
  source: 'user',
  reason: 'explicit_save',
});
const diff = await history.getPlaymeshHistoryDiff(gameId, 1, 2);
assert.equal(diff.changed, true);
const beforePreview = history.getPlaymeshHistoryResourcePreview(
  diff,
  'before',
  'playmesh-local-resource://history/hero-v1.png'
);
assert.deepEqual(
  {
    side: beforePreview.side,
    revision: beforePreview.revision,
    kind: beforePreview.kind,
    mime: beforePreview.mime,
  },
  { side: 'before', revision: 1, kind: 'image', mime: 'image/png' }
);
assert.equal(
  beforePreview.url,
  `${base}/revisions/1/resources/${'1'.repeat(
    64
  )}?logicalId=playmesh-local-resource%3A%2F%2Fhistory%2Fhero-v1.png`
);
assert.equal(beforePreview.url.startsWith('/dev/api/'), true);
assert.equal(beforePreview.url.includes('blob:'), false);
assert.equal(beforePreview.url.includes('http://'), false);
assert.equal(
  history.getPlaymeshHistoryResourcePreview(
    diff,
    'before',
    'playmesh-local-resource://history/data.json'
  ),
  null,
  'non-whitelisted MIME must never become an inline preview URL'
);
assert.equal(
  history.getPlaymeshHistoryResourcePreview(
    diff,
    'after',
    'playmesh-local-resource://history/hero-v1.png'
  ),
  null,
  'a resource from the other revision must not be reused as current evidence'
);
phase = 'invalid-diff';
await assert.rejects(
  history.getPlaymeshHistoryDiff(gameId, 1, 2),
  error => error.code === 'invalid_response',
  'diff responses without revision-bound resource evidence must be rejected'
);
phase = 'sync';

const restored = await history.restorePlaymeshHistory({
  gameId,
  targetRevision: 1,
  source: 'user',
  currentSnapshot: {
    project: { properties: { packageName: gameId } },
    resources: [],
  },
});
assert.equal(restored.version.revision, 3);
assert.equal(restored.resources[0].contentHash, restoredHash);
assert.equal(validationCount, 1);

phase = 'materialize-current';
const currentOpenHashCount = globalThis.__playmeshHistoryHashCount;
const materializedCurrent = await history.loadPlaymeshHistoryCurrentProject(
  gameId
);
assert.equal(materializedCurrent.version.revision, 3);
assert.deepEqual(
  materializedCurrent.resources.map(resource => resource.contentHash),
  currentResourceFixtures.map(resource => resource.contentHash),
  'bounded parallel downloads must preserve manifest order'
);
assert.deepEqual(
  materializedCurrent.resources.map(resource => ({
    logicalId: resource.logicalUrl,
    name: resource.name,
    size: resource.blob.size,
    mime: resource.blob.type,
  })),
  currentResourceFixtures.map(resource => ({
    logicalId: resource.logicalId,
    name: resource.name,
    size: resource.size,
    mime: resource.mime,
  })),
  'parallel materialization must retain logical identity, size and MIME'
);
assert.equal(
  maxActiveCurrentResourceRequests,
  4,
  'current resources must use the fixed four-request concurrency bound'
);
assert.equal(
  validationCount,
  1,
  'current open delegates its single fresh-project unserialize to official MainFrame'
);
assert.equal(
  globalThis.__playmeshHistoryHashCount,
  currentOpenHashCount,
  'current open must not re-hash resources before official GDevelop loading'
);
phase = 'materialize-current-corrupt';
const uncheckedCurrent = await history.loadPlaymeshHistoryCurrentProject(
  gameId
);
assert.equal(
  uncheckedCurrent.resources[0].blob.size,
  currentResourceFixtures[0].size + 1,
  'current bytes are passed through without PlayMesh content validation'
);
assert.equal(
  globalThis.__playmeshHistoryHashCount,
  currentOpenHashCount,
  'unchecked current resources must remain outside PlayMesh hashing'
);

phase = 'materialize-current-unchecked-manifest';
const uncheckedManifestCurrent = await history.loadPlaymeshHistoryCurrentProject(
  gameId
);
assert.equal(
  uncheckedManifestCurrent.version.reason,
  'unvalidated-reason',
  'normal current open must not gate on history version semantics'
);
assert.equal(
  Array.isArray(uncheckedManifestCurrent.project),
  true,
  'normal current open must pass project schema handling to official GDevelop'
);
assert.equal(
  uncheckedManifestCurrent.resources[0].blob.type,
  'image/x-playmesh-current-fixture',
  'current Blob MIME must come from the manifest rather than HTTP Content-Type'
);
assert.equal(
  globalThis.__playmeshHistoryHashCount,
  currentOpenHashCount,
  'unchecked current manifest fields must not trigger PlayMesh hashing'
);

phase = 'materialize-current-resource-error';
const failedCurrentCallOffset = calls.length;
await assert.rejects(
  history.loadPlaymeshHistoryCurrentProject(gameId),
  error => error.code === 'current_resource_unavailable' && error.status === 503,
  'one failed current resource GET must reject the whole normal open'
);
assert.equal(
  calls
    .slice(failedCurrentCallOffset)
    .filter(call => call.url.startsWith(`${base}/resources/`)).length,
  4,
  'a failed worker must stop the queue after the already in-flight requests'
);

phase = 'restore-corrupt';
await assert.rejects(
  history.materializePlaymeshHistorySnapshot({
    gameId,
    snapshot: {
      version: historyVersion(4, 'restore'),
      project: {
        properties: { packageName: gameId },
        resources: [{ file: 'playmesh-local-resource://restored' }],
      },
      resources: [
        {
          logicalId: 'playmesh-local-resource://restored',
          name: 'restored.bin',
          contentHash: restoredHash,
          mime: 'application/octet-stream',
          size: restoredBytes.byteLength,
        },
      ],
    },
  }),
  error => error.code === 'resource_corrupt',
  'history restore must retain strict size/hash validation'
);

phase = 'error';
await assert.rejects(
  history.listPlaymeshHistory(gameId),
  error =>
    error.code === 'gdevelop_revision_conflict' &&
    error.message === 'revision changed' &&
    error.reason === 'revision changed' &&
    error.stage === 'gateway_response' &&
    error.errorType === 'DeveloperGatewayError' &&
    error.status === 409 &&
    error.requestId === 'history-request-9' &&
    error.operation === 'gdevelop.history.list' &&
    error.details.error.currentRevision === 9
);
assert.equal(events.every(event => !('projectId' in event.detail)), true);

process.stdout.write('GDevelop history client tests passed.\n');
