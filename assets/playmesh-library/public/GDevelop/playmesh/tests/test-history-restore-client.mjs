import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const dependencyCacheRoot = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/cache/deps'
);
const dependencyCaches = existsSync(dependencyCacheRoot)
  ? await readdir(dependencyCacheRoot)
  : [];
const appPackage = dependencyCaches
  .map(entry => path.join(dependencyCacheRoot, entry, 'package.json'))
  .find(candidate =>
    existsSync(
      path.join(
        path.dirname(candidate),
        'node_modules/@babel/core/package.json'
      )
    )
  );
assert.ok(
  appPackage && existsSync(appPackage),
  'the fixed WebIDE dependency cache is required for the history restore Flow contract'
);
const appRequire = createRequire(appPackage);
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const transformFlow = source =>
  transformSync(source, {
    babelrc: false,
    configFile: false,
    plugins: [[flowStripPlugin, { all: true }]],
    sourceType: 'module',
  }).code;
const importSource = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}`);

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

globalThis.window = {
  fetch: async () => {
    throw new Error('singleton client must not be used');
  },
  setTimeout,
  clearTimeout,
};

let clientSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreClient.js'
  ),
  'utf8'
);
clientSource = clientSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
  `const {
  PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES,
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreEnvelope,
  assertPlaymeshHistoryRestoreRecoveryEnvelope,
  buildPlaymeshHistoryRestoreBaseUrl,
  buildPlaymeshHistoryRestoreTransactionUrl,
  createPlaymeshHistoryRestorePrepareBody,
} = globalThis.__historyRestoreProtocol;`
);
const clientModule = await importSource(transformFlow(clientSource));

const gameId = 'com.playmesh.game.restore-client';
const txId = 'tx-client-1';
const baseUrl = `/dev/api/gdevelop/projects/${gameId}/history/restore-transactions`;
const transactionUrl = `${baseUrl}/${txId}`;
const hash = character => character.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const missingConfig = { semantics: 'missing', status: 'missing' };
const browserEvidence = {
  projectJsonHash: hash('3'),
  resourceManifestHash: hash('4'),
};
const historyEvidence = (revision, character) => ({
  revision,
  currentContentHash: hash(character),
  projectJsonHash: hash(character),
  resourceManifestHash: hash(character),
});
const resource = {
  logicalId: 'playmesh-local-resource://sprite.png',
  name: 'sprite.png',
  contentHash: hash('d'),
  mime: 'image/png',
  size: 4,
  metadata: { kind: 'image' },
};
const sourceVersion = {
  id: 'version-4',
  gameId,
  revision: 4,
  timestamp,
  reason: 'explicit_save',
  contentHash: hash('e'),
  source: 'user',
  contentBytes: 18,
};
const targetSnapshot = {
  sourceVersion,
  projectReference: { contentHash: hash('f'), size: 18 },
  project: { name: 'Target' },
  resources: [resource],
  playmeshProjectConfig: null,
};
const preparedTransaction = {
  txId,
  gameId,
  idempotencyKey: 'restore.client-1',
  phase: 'PREPARED',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  oldEvidence: {
    history: historyEvidence(7, '1'),
    config: missingConfig,
  },
  targetEvidence: {
    history: {
      revision: 8,
      currentContentHash: hash('2'),
      ...browserEvidence,
    },
    config: missingConfig,
  },
  createdAt: timestamp,
  updatedAt: timestamp,
  targetSnapshot,
};
const restored = {
  version: {
    ...sourceVersion,
    id: 'version-8',
    revision: 8,
  },
  project: targetSnapshot.project,
  resources: targetSnapshot.resources,
  playmeshProjectConfig: null,
};
const committedTransaction = {
  ...preparedTransaction,
  phase: 'BACKEND_COMMITTED',
  targetSnapshot: undefined,
  restored,
};
const persistedTransaction = {
  ...committedTransaction,
  phase: 'BROWSER_PERSISTED',
  browserEvidence,
};

const jsonResponse = (status, body, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });

const calls = [];
let responder = async () => {
  throw new Error('response not configured');
};
const restoreClient = clientModule.createPlaymeshHistoryRestoreClient({
  fetchImpl: async (url, options) => {
    calls.push({ url, options });
    return responder(url, options);
  },
  timeoutMs: 1000,
});

responder = async () =>
  jsonResponse(201, {
    requestId: 'request-prepare',
    transaction: preparedTransaction,
  });
const prepared = await restoreClient.prepare({
  gameId,
  idempotencyKey: 'restore.client-1',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  currentProject: { name: 'Current' },
  currentResources: [resource],
  clientId: ' client-1 ',
});
assert.equal(prepared.transaction.phase, 'PREPARED');
assert.equal(calls.at(-1).url, baseUrl);
assert.equal(calls.at(-1).options.method, 'POST');
assert.equal(calls.at(-1).options.credentials, 'same-origin');
assert.equal(calls.at(-1).options.cache, 'no-store');
assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
  idempotencyKey: 'restore.client-1',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  currentProject: { name: 'Current' },
  currentResources: [resource],
  clientId: 'client-1',
});

responder = async () =>
  jsonResponse(409, {
    requestId: 'request-commit-replay',
    transaction: committedTransaction,
  });
const committed = await restoreClient.commit({ gameId, txId });
assert.equal(committed.transaction.phase, 'BACKEND_COMMITTED');
assert.equal(calls.at(-1).url, `${transactionUrl}/commit`);
assert.equal(calls.at(-1).options.body, '{}');

responder = async () =>
  jsonResponse(200, {
    requestId: 'request-status',
    transaction: committedTransaction,
  });
await restoreClient.status({ gameId, txId });
assert.equal(calls.at(-1).url, transactionUrl);
assert.equal(calls.at(-1).options.method, 'GET');
assert.equal('body' in calls.at(-1).options, false);

responder = async () =>
  jsonResponse(409, {
    requestId: 'request-ack-replay',
    transaction: persistedTransaction,
  });
const acknowledged = await restoreClient.acknowledge({
  gameId,
  txId,
  browserEvidence,
});
assert.equal(acknowledged.transaction.phase, 'BROWSER_PERSISTED');
assert.equal(calls.at(-1).url, `${transactionUrl}/ack`);
assert.deepEqual(JSON.parse(calls.at(-1).options.body), browserEvidence);
assert.deepEqual(Object.keys(JSON.parse(calls.at(-1).options.body)).sort(), [
  'projectJsonHash',
  'resourceManifestHash',
]);

responder = async () =>
  jsonResponse(200, {
    requestId: 'request-recover',
    transaction: { ...committedTransaction, targetSnapshot },
    replayedEventTxIds: [txId],
  });
const recovered = await restoreClient.recover({ gameId });
assert.equal(recovered.transaction.phase, 'BACKEND_COMMITTED');
assert.equal(calls.at(-1).url, `${baseUrl}/recover`);
assert.equal(calls.at(-1).options.body, '{}');

responder = async () =>
  jsonResponse(200, {
    requestId: 'request-abort',
    transaction: {
      ...preparedTransaction,
      phase: 'ABORTED',
    },
  });
await restoreClient.abort({ gameId, txId });
assert.equal(calls.at(-1).url, `${transactionUrl}/abort`);
assert.equal(calls.at(-1).options.body, '{}');

responder = async () =>
  jsonResponse(409, {
    error: {
      code: 'gdevelop_restore_transaction_unavailable',
      message: 'not replayable',
    },
  });
await assert.rejects(
  restoreClient.commit({ gameId, txId }),
  error =>
    error instanceof clientModule.PlaymeshHistoryRestoreRequestError &&
    error.code === 'gdevelop_restore_transaction_unavailable' &&
    error.status === 409
);

const oversizedClient = clientModule.createPlaymeshHistoryRestoreClient({
  fetchImpl: async () =>
    jsonResponse(
      200,
      {},
      {
        'Content-Length': String(
          protocol.PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES + 1
        ),
      }
    ),
});
await assert.rejects(
  oversizedClient.status({ gameId, txId }),
  error => error.code === 'response_too_large'
);

const invalidJsonClient = clientModule.createPlaymeshHistoryRestoreClient({
  fetchImpl: async () =>
    new Response('{not-json', {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
});
await assert.rejects(
  invalidJsonClient.status({ gameId, txId }),
  error => error.code === 'invalid_response'
);

const timeoutClient = clientModule.createPlaymeshHistoryRestoreClient({
  fetchImpl: async (_url, options) =>
    new Promise((resolve, reject) => {
      options.signal.addEventListener(
        'abort',
        () => reject(new DOMException('aborted', 'AbortError')),
        { once: true }
      );
    }),
  timeoutMs: 1,
});
await assert.rejects(
  timeoutClient.status({ gameId, txId }),
  error => error.code === 'history_restore_timeout'
);

const cancellationController = new AbortController();
cancellationController.abort();
const cancelledClient = clientModule.createPlaymeshHistoryRestoreClient({
  fetchImpl: async (_url, options) => {
    assert.equal(options.signal.aborted, true);
    throw new DOMException('aborted', 'AbortError');
  },
});
await assert.rejects(
  cancelledClient.status({
    gameId,
    txId,
    signal: cancellationController.signal,
  }),
  error => error.code === 'cancelled'
);

assert.throws(
  () => clientModule.createPlaymeshHistoryRestoreClient({ timeoutMs: 0 }),
  error => error.code === 'invalid_timeout'
);

process.stdout.write('GDevelop history restore client tests passed.\n');
