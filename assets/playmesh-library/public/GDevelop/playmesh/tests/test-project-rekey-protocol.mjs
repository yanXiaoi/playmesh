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

let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjectRekey/PlaymeshProjectRekeyProtocol.js'
  ),
  'utf8'
);
source = source.replace(
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
const validatePlaymeshProjectConfigGameId = value => {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) {
    throw new Error('invalid game id');
  }
  return value;
};
const validatePlaymeshProjectGameType = value => {
  if (value !== 'single' && value !== 'online') throw new Error('invalid game type');
  return value;
};`
);
const protocol = await importSource(transformFlow(source));

const hash = character => character.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const oldGameId = 'com.playmesh.game.old001';
const newGameId = 'com.playmesh.game.new001';
const fileIdentifier = 'file-a';
const historyEvidence = marker => ({
  revision: 1,
  currentContentHash: hash(marker),
  projectJsonHash: hash(marker),
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
  projectJsonHash: hash(marker),
});
const browserEvidence = (gameId, marker) => ({
  fileMetadata: { fileIdentifier, gameId },
  packageName: gameId,
  projectJsonHash: hash(marker),
});
const transaction = phase => ({
  txId: 'tx-a',
  idempotencyKey: 'rekey-a',
  oldGameId,
  newGameId,
  phase,
  clientId: null,
  browserSource: browserTarget('1'),
  browserTarget: browserTarget('2'),
  oldEvidence: backendEvidence(oldGameId, '1'),
  targetEvidence: backendEvidence(newGameId, '1'),
  createdAt: timestamp,
  updatedAt: timestamp,
  expiresAt: null,
  retainedUntil: null,
  browserEvidence:
    phase === 'BROWSER_UPDATED' || phase === 'OLD_CLEANED'
      ? browserEvidence(newGameId, '2')
      : null,
  rollbackBrowserEvidence:
    phase === 'ROLLED_BACK' ? browserEvidence(oldGameId, '1') : null,
  cleanupPending: false,
  cleanupError: null,
  conflict:
    phase === 'CONFLICT'
      ? { reason: 'target_changed', observedAt: timestamp }
      : null,
});

for (const phase of [
  'PREPARED',
  'COMMIT_REQUESTED',
  'NEW_PUBLISHED',
  'BROWSER_UPDATED',
  'ROLLBACK_REQUESTED',
  'OLD_CLEANED',
  'ROLLED_BACK',
  'CONFLICT',
  'ABORTED',
]) {
  assert.equal(
    protocol.assertPlaymeshProjectRekeyTransaction(
      transaction(phase),
      oldGameId
    ).phase,
    phase
  );
}

const prepareBody = protocol.createPlaymeshProjectRekeyPrepareBodyForGame(
  {
    idempotencyKey: 'rekey-a',
    newGameId,
    expectedOldEvidence: {
      history: historyEvidence('1'),
      config: configEvidence(oldGameId),
    },
    browserSource: browserTarget('1'),
    browserTarget: browserTarget('2'),
    clientId: 'client-a',
  },
  oldGameId
);
assert.deepEqual(Object.keys(prepareBody), [
  'idempotencyKey',
  'newGameId',
  'expectedOldEvidence',
  'browserSource',
  'browserTarget',
  'clientId',
]);
assert.equal(
  protocol.buildPlaymeshProjectRekeyTransactionUrl(oldGameId, 'tx-a'),
  `/dev/api/gdevelop/projects/${oldGameId}/rekey-transactions/tx-a`
);

const envelope = protocol.assertPlaymeshProjectRekeyEnvelope(
  { requestId: 'request-a', transaction: transaction('PREPARED') },
  oldGameId
);
assert.equal(envelope.transaction.txId, 'tx-a');
const recovery = protocol.assertPlaymeshProjectRekeyRecoveryEnvelope(
  {
    requestId: 'request-b',
    transaction: transaction('ROLLBACK_REQUESTED'),
    replayedEventTxIds: ['tx-old'],
    cleanupPendingTxIds: ['tx-a'],
  },
  oldGameId
);
assert.deepEqual(recovery.cleanupPendingTxIds, ['tx-a']);

assert.throws(() =>
  protocol.assertPlaymeshProjectRekeyTransaction(
    { ...transaction('PREPARED'), extra: true },
    oldGameId
  )
);
assert.throws(() =>
  protocol.assertPlaymeshProjectRekeyTransaction(
    {
      ...transaction('OLD_CLEANED'),
      browserEvidence: browserEvidence(oldGameId, '2'),
    },
    oldGameId
  )
);
assert.throws(() =>
  protocol.assertPlaymeshProjectRekeyTransaction(
    { ...transaction('CONFLICT'), conflict: null },
    oldGameId
  )
);
assert.throws(() =>
  protocol.createPlaymeshProjectRekeyPrepareBodyForGame(
    { ...prepareBody, unknown: true },
    oldGameId
  )
);

process.stdout.write('GDevelop project rekey protocol tests passed.\n');
