import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}`);

globalThis.window = {
  crypto: webcrypto,
  fetch: async () => {
    throw new Error('fetch dependency must be overridden');
  },
};

const sha256Source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshCrypto/PlaymeshSha256.js'
  ),
  'utf8'
);
globalThis.__playmeshSha256 = await importSource(transformFlow(sha256Source));

let protocolSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreProtocol.js'
  ),
  'utf8'
);
protocolSource = protocolSource.replace(
  /import \{[\s\S]*?\} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
  `const validatePlaymeshProjectConfigGameId = value => {
  if (typeof value !== 'string' || !value) throw new Error('invalid game id');
  return value;
};
const validatePlaymeshProjectGameType = value => {
  if (value !== 'single' && value !== 'online') throw new Error('invalid game type');
  return value;
};`
);
const protocol = await importSource(transformFlow(protocolSource));
globalThis.__historyRestoreProtocol = protocol;

let evidenceSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryEvidence.js'
  ),
  'utf8'
);
evidenceSource = evidenceSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
  `const {
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreResource,
} = globalThis.__historyRestoreProtocol;`
);
evidenceSource = evidenceSource.replace(
  /import \{ sha256Hex \} from '\.\.\/PlaymeshCrypto\/PlaymeshSha256';/,
  'const { sha256Hex } = globalThis.__playmeshSha256;'
);
const evidence = await importSource(transformFlow(evidenceSource));
globalThis.__historyEvidence = evidence;

let materializerSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreMaterializer.js'
  ),
  'utf8'
);
materializerSource = materializerSource
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
    `const {
  buildPlaymeshHistoryResourceUrl,
  validatePlaymeshHistoryRestoreRevision,
} = globalThis.__historyRestoreProtocol;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryEvidence';/,
    `const {
  encodePlaymeshHistoryCanonicalJson,
  hashPlaymeshHistoryBlob,
  hashPlaymeshHistoryBytes,
} = globalThis.__historyEvidence;`
  );
const materializer = await importSource(transformFlow(materializerSource));

const gameId = 'com.playmesh.game.restore-materializer';
const logicalId = 'playmesh-local-resource://资源/sprite.png';
const project = {
  z: 1,
  a: {
    label: '目标 ✓',
    file: logicalId,
  },
};
const canonicalBytes = evidence.encodePlaymeshHistoryCanonicalJson(project);
assert.equal(
  new TextDecoder().decode(canonicalBytes),
  `{"a":{"file":"${logicalId}","label":"目标 ✓"},"z":1}`
);
const projectHash = await evidence.hashPlaymeshHistoryBytes(
  canonicalBytes.buffer
);
const resourceBytes = new Uint8Array([1, 2, 3, 4, 5]);
const resourceHash = await evidence.hashPlaymeshHistoryBytes(
  resourceBytes.buffer
);
const resourceDto = {
  logicalId,
  name: 'sprite.png',
  contentHash: resourceHash,
  mime: 'image/png',
  size: resourceBytes.byteLength,
  metadata: { kind: 'image', width: 16 },
};
const timestamp = '2026-08-05T01:02:03.000Z';
const targetSnapshot = {
  sourceVersion: {
    id: 'version-4',
    gameId,
    revision: 4,
    timestamp,
    reason: 'explicit_save',
    contentHash: 'a'.repeat(64),
    source: 'user',
    contentBytes: canonicalBytes.byteLength,
  },
  projectReference: {
    contentHash: projectHash,
    size: canonicalBytes.byteLength,
  },
  project,
  resources: [resourceDto],
  playmeshProjectConfig: null,
};

const createGdHarness = ({ throwOnUnserialize = false } = {}) => {
  const state = {
    serializedDeleteCount: 0,
    projectDeleteCount: 0,
    unserializeCount: 0,
    serializedValue: null,
  };
  const gd = {
    ProjectHelper: {
      createNewGDJSProject: () => ({
        unserializeFrom: serialized => {
          state.unserializeCount++;
          state.serializedValue = serialized.value;
          if (throwOnUnserialize) throw new Error('invalid project fixture');
        },
        delete: () => {
          state.projectDeleteCount++;
        },
      }),
    },
    Serializer: {
      fromJSObject: value => ({
        value,
        delete: () => {
          state.serializedDeleteCount++;
        },
      }),
    },
  };
  return { gd, state };
};

const createdObjectUrls = [];
const revokedObjectUrls = [];
const urlApi = {
  createObjectURL: blob => {
    assert.equal(blob.type, 'image/png');
    const value = `blob:playmesh-history-${createdObjectUrls.length}`;
    createdObjectUrls.push(value);
    return value;
  },
  revokeObjectURL: value => revokedObjectUrls.push(value),
};
const fetchCalls = [];
const fetchImpl = async (url, options) => {
  fetchCalls.push({ url, options });
  return new Response(resourceBytes, {
    status: 200,
    headers: { 'Content-Type': 'application/octet-stream' },
  });
};
const gdHarness = createGdHarness();
const signal = new AbortController().signal;
const result = await materializer.materializePlaymeshHistoryTarget({
  gameId,
  targetRevision: 4,
  targetSnapshot,
  signal,
  fetchImpl,
  gd: gdHarness.gd,
  urlApi,
});
assert.equal(fetchCalls.length, 1);
assert.equal(
  fetchCalls[0].url,
  `/dev/api/gdevelop/projects/${gameId}/history/resources/${resourceHash}`
);
assert.equal(fetchCalls[0].options.signal, signal);
assert.equal(result.project, project);
assert.equal(result.project.a.file, logicalId);
assert.equal(result.resources.length, 1);
assert.equal(result.resources[0].logicalUrl, logicalId);
assert.equal(result.resources[0].name, 'sprite.png');
assert.equal(result.resources[0].blob.type, 'image/png');
assert.equal(result.resources[0].contentHash, resourceHash);
assert.deepEqual(result.resources[0].metadata, resourceDto.metadata);
assert.equal(gdHarness.state.serializedValue.a.file, createdObjectUrls[0]);
assert.equal(gdHarness.state.unserializeCount, 1);
assert.equal(gdHarness.state.serializedDeleteCount, 1);
assert.equal(gdHarness.state.projectDeleteCount, 1);
assert.deepEqual(revokedObjectUrls, createdObjectUrls);

let wrongProjectFetches = 0;
await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 4,
    targetSnapshot: {
      ...targetSnapshot,
      projectReference: {
        ...targetSnapshot.projectReference,
        contentHash: 'b'.repeat(64),
      },
    },
    fetchImpl: async () => {
      wrongProjectFetches++;
      throw new Error('must not fetch');
    },
    gd: createGdHarness().gd,
    urlApi,
  }),
  error => error.code === 'target_project_reference_mismatch'
);
assert.equal(wrongProjectFetches, 0);

let corruptGdCreates = 0;
const corruptGd = {
  ProjectHelper: {
    createNewGDJSProject: () => {
      corruptGdCreates++;
      throw new Error('must not deserialize');
    },
  },
  Serializer: {},
};
await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 4,
    targetSnapshot: {
      ...targetSnapshot,
      resources: [{ ...resourceDto, size: resourceDto.size + 1 }],
    },
    fetchImpl,
    gd: corruptGd,
    urlApi,
  }),
  error => error.code === 'resource_corrupt'
);
assert.equal(corruptGdCreates, 0);

await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 4,
    targetSnapshot: {
      ...targetSnapshot,
      resources: [{ ...resourceDto, contentHash: 'c'.repeat(64) }],
    },
    fetchImpl,
    gd: corruptGd,
    urlApi,
  }),
  error => error.code === 'resource_corrupt'
);
assert.equal(corruptGdCreates, 0);

await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 4,
    targetSnapshot,
    fetchImpl: async () => new Response('', { status: 503 }),
    gd: corruptGd,
    urlApi,
  }),
  error => error.code === 'resource_download_failed'
);

const failingGdHarness = createGdHarness({ throwOnUnserialize: true });
const failingCreatedUrls = [];
const failingRevokedUrls = [];
await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 4,
    targetSnapshot,
    fetchImpl,
    gd: failingGdHarness.gd,
    urlApi: {
      createObjectURL: () => {
        const value = `blob:failing-${failingCreatedUrls.length}`;
        failingCreatedUrls.push(value);
        return value;
      },
      revokeObjectURL: value => failingRevokedUrls.push(value),
    },
  }),
  error =>
    error.code === 'invalid_target_project' &&
    error.message.includes('invalid project fixture')
);
assert.equal(failingGdHarness.state.serializedDeleteCount, 1);
assert.equal(failingGdHarness.state.projectDeleteCount, 1);
assert.deepEqual(failingRevokedUrls, failingCreatedUrls);

await assert.rejects(
  materializer.materializePlaymeshHistoryTarget({
    gameId,
    targetRevision: 3,
    targetSnapshot,
    fetchImpl,
    gd: gdHarness.gd,
    urlApi,
  }),
  error => error.code === 'target_revision_mismatch'
);

assert.throws(
  () =>
    materializer.validatePlaymeshHistoryTargetProject(project, [], {
      gd: {},
      urlApi,
    }),
  error => error.code === 'gdevelop_runtime_unavailable'
);

process.stdout.write('GDevelop history restore materializer tests passed.\n');
