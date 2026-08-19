import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = source =>
  import(
    `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
  );
const readOverlay = relativePath =>
  readFile(
    path.resolve(testDirectory, '../overlays/newIDE/app/src', relativePath),
    'utf8'
  );

globalThis.window = {
  fetch: globalThis.fetch,
  setTimeout: globalThis.setTimeout,
  clearTimeout: globalThis.clearTimeout,
};

let protocolSource = await readOverlay(
  'PlaymeshProjectRekey/PlaymeshProjectRekeyProtocol.js'
);
protocolSource = protocolSource.replace(
  /import \{[\s\S]*?\} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
  `const PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS = 64;
const normalizePlaymeshProjectTags = value => {
  if (!Array.isArray(value)) throw new Error('invalid tags');
  const normalized = [];
  const seen = new Set();
  for (const rawTag of value) {
    if (typeof rawTag !== 'string') throw new Error('invalid tags');
    const tag = rawTag.trim();
    if (!tag || tag.length > 64) throw new Error('invalid tags');
    if (!seen.has(tag)) {
      seen.add(tag);
      normalized.push(tag);
    }
  }
  if (normalized.length > 5) throw new Error('invalid tags');
  return normalized;
};
const validatePlaymeshProjectConfigGameId = value => value;
const validatePlaymeshProjectGameType = value => value;`
);
const protocol = await importSource(transformFlow(protocolSource));
globalThis.__rekeyProtocol = protocol;

let clientSource = await readOverlay(
  'PlaymeshProjectRekey/PlaymeshProjectRekeyClient.js'
);
clientSource = clientSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshProjectRekeyProtocol';/,
  `const {
  PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES,
  assertPlaymeshProjectRekeyBrowserEvidence,
  assertPlaymeshProjectRekeyEnvelope,
  assertPlaymeshProjectRekeyRecoveryEnvelope,
  buildPlaymeshProjectRekeyBaseUrl,
  buildPlaymeshProjectRekeyTransactionUrl,
  createPlaymeshProjectRekeyPrepareBodyForGame,
} = globalThis.__rekeyProtocol;`
);
const clientModule = await importSource(transformFlow(clientSource));

const hash = marker => marker.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const oldGameId = 'com.playmesh.game.old001';
const newGameId = 'com.playmesh.game.new001';
const fileIdentifier = 'file-a';
const historyEvidence = marker => ({
  revision: 1,
  currentContentHash: hash(marker),
  projectFilesHash: hash(marker),
  resourceManifestHash: hash(marker),
});
const configEvidence = gameId => ({
  status: 'ready',
  revision: 1,
  contentHash: hash('a'),
  config: {
    schemaVersion: 2,
    gameId,
    revision: 1,
    gameType: 'online',
    minPlayers: 2,
    maxPlayers: 5,
    tags: ['联机'],
    updatedAt: timestamp,
  },
});
const backendEvidence = (gameId, marker) => ({
  projectMetadataHash: hash('b'),
  rootManifestHash: hash('c'),
  history: historyEvidence(marker),
  config: configEvidence(gameId),
  mainJsonHash: null,
});
const browserTarget = marker => ({
  fileIdentifier,
  projectFilesHash: hash(marker),
});
const browserEvidence = (gameId, marker) => ({
  fileMetadata: { fileIdentifier, gameId },
  packageName: gameId,
  projectFilesHash: hash(marker),
});
const transaction = phase => ({
  txId: 'tx-a',
  idempotencyKey: 'rekey-a',
  oldGameId,
  newGameId,
  phase,
  clientId: 'client-a',
  browserSource: browserTarget('1'),
  browserTarget: browserTarget('2'),
  oldEvidence: backendEvidence(oldGameId, '1'),
  targetEvidence: backendEvidence(newGameId, '1'),
  createdAt: timestamp,
  updatedAt: timestamp,
  expiresAt: null,
  retainedUntil: null,
  browserEvidence:
    phase === 'OLD_CLEANED' ? browserEvidence(newGameId, '2') : null,
  rollbackBrowserEvidence: null,
  cleanupPending: false,
  cleanupError: null,
  conflict:
    phase === 'CONFLICT' ? { reason: 'target_changed' } : null,
});
const envelope = phase => ({
  requestId: `request-${phase}`,
  transaction: transaction(phase),
});
const response = (value, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

const calls = [];
const responses = [];
const fetchImpl = async (url, options) => {
  calls.push({ url, options });
  const next = responses.shift();
  if (!next) throw new Error('Missing fake response.');
  return next;
};
const client = clientModule.createPlaymeshProjectRekeyClient({ fetchImpl });
const expectedOldEvidence = {
  history: historyEvidence('1'),
  config: configEvidence(oldGameId),
};

responses.push(response(envelope('PREPARED'), 201));
await client.prepare({
  oldGameId,
  newGameId,
  idempotencyKey: 'rekey-a',
  expectedOldEvidence,
  browserSource: browserTarget('1'),
  browserTarget: browserTarget('2'),
  clientId: 'client-a',
});
assert.equal(
  calls.at(-1).url,
  `/dev/api/gdevelop/projects/${oldGameId}/rekey-transactions`
);
assert.equal(calls.at(-1).options.credentials, 'same-origin');
assert.equal(calls.at(-1).options.cache, 'no-store');
assert.equal(calls.at(-1).options.redirect, 'error');
assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
  idempotencyKey: 'rekey-a',
  newGameId,
  expectedOldEvidence,
  browserSource: browserTarget('1'),
  browserTarget: browserTarget('2'),
  clientId: 'client-a',
});

for (const [method, suffix, phase] of [
  ['commit', '/commit', 'NEW_PUBLISHED'],
  ['status', '', 'NEW_PUBLISHED'],
  ['abort', '/abort', 'ABORTED'],
]) {
  responses.push(response(envelope(phase)));
  await client[method]({ oldGameId, txId: 'tx-a' });
  assert.equal(
    calls.at(-1).url,
    `/dev/api/gdevelop/projects/${oldGameId}/rekey-transactions/tx-a${suffix}`
  );
}

responses.push(response(envelope('OLD_CLEANED')));
await client.acknowledge({
  oldGameId,
  txId: 'tx-a',
  browserEvidence: browserEvidence(newGameId, '2'),
});
assert.deepEqual(
  JSON.parse(calls.at(-1).options.body),
  browserEvidence(newGameId, '2')
);

const rolledBackTransaction = {
  ...transaction('ROLLED_BACK'),
  rollbackBrowserEvidence: browserEvidence(oldGameId, '1'),
};
responses.push(
  response({ requestId: 'request-rollback', transaction: rolledBackTransaction })
);
await client.rollback({
  oldGameId,
  txId: 'tx-a',
  browserEvidence: browserEvidence(oldGameId, '1'),
});
assert.deepEqual(
  JSON.parse(calls.at(-1).options.body),
  browserEvidence(oldGameId, '1')
);

responses.push(
  response({
    requestId: 'request-recover',
    transaction: transaction('ROLLBACK_REQUESTED'),
    replayedEventTxIds: [],
    cleanupPendingTxIds: ['tx-a'],
  }, 202)
);
const recovery = await client.recover({ oldGameId });
assert.equal(recovery.transaction.phase, 'ROLLBACK_REQUESTED');
assert.equal(calls.at(-1).url.endsWith('/recover'), true);

responses.push(response(envelope('CONFLICT'), 409));
const conflict = await client.commit({ oldGameId, txId: 'tx-a' });
assert.equal(conflict.transaction.phase, 'CONFLICT');

responses.push(
  response(
    {
      requestId: 'request-error',
      error: { code: 'gdevelop_rekey_old_changed', message: 'changed' },
    },
    409
  )
);
await assert.rejects(
  client.prepare({
    oldGameId,
    newGameId,
    idempotencyKey: 'rekey-a',
    expectedOldEvidence,
    browserSource: browserTarget('1'),
    browserTarget: browserTarget('2'),
  }),
  error =>
    error instanceof clientModule.PlaymeshProjectRekeyRequestError &&
    error.code === 'gdevelop_rekey_old_changed' &&
    error.requestId === 'request-error'
);

responses.push(
  response(
    {
      requestId: 'request-error',
      error: {
        code: 'do_not_trust',
        message: 'extra keys are invalid',
        extra: true,
      },
    },
    500
  )
);
await assert.rejects(
  client.status({ oldGameId, txId: 'tx-a' }),
  error => error.code === 'gdevelop_rekey_request_failed'
);

const timeoutClient = clientModule.createPlaymeshProjectRekeyClient({
  timeoutMs: 1,
  fetchImpl: (url, options) =>
    new Promise((resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new Error('abort')));
    }),
});
await assert.rejects(
  timeoutClient.status({ oldGameId, txId: 'tx-a' }),
  error => error.code === 'gdevelop_rekey_timeout'
);

process.stdout.write('GDevelop project rekey client tests passed.\n');
