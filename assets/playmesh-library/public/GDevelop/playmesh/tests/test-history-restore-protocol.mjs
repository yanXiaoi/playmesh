import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreProtocol.js'
  ),
  'utf8'
);
source = source.replace(/^\/\/ @flow\s*/, '').replace(
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
const protocol = await import(`data:text/javascript;base64,${Buffer.from(
  source
).toString('base64')}`);

const gameId = 'com.playmesh.game.restore001';
const hash = character => character.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const config = {
  schemaVersion: 1,
  gameId,
  revision: 3,
  gameType: 'online',
  updatedAt: timestamp,
};
const readyConfigEvidence = {
  semantics: 'ready',
  status: 'ready',
  revision: 3,
  contentHash: hash('a'),
  config,
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
const version = {
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
  sourceVersion: version,
  projectReference: { contentHash: hash('f'), size: 18 },
  project: { name: 'Target' },
  resources: [resource],
  playmeshProjectConfig: config,
};
const transaction = {
  txId: 'tx-001',
  gameId,
  idempotencyKey: 'restore-001',
  phase: 'PREPARED',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  oldEvidence: {
    history: historyEvidence(7, '1'),
    config: readyConfigEvidence,
  },
  targetEvidence: {
    history: historyEvidence(8, '2'),
    config: readyConfigEvidence,
  },
  createdAt: timestamp,
  updatedAt: timestamp,
  targetSnapshot,
};

assert.throws(
  () => protocol.validatePlaymeshHistoryRestoreSource('ai'),
  error => error.code === 'invalid_source',
  'ordinary restore must not retain the removed AI source compatibility'
);
assert.throws(
  () =>
    protocol.assertPlaymeshHistoryRestoreEnvelope(
      {
        requestId: 'request-ai-turn',
        transaction: {
          ...transaction,
          targetSnapshot: {
            ...targetSnapshot,
            sourceVersion: { ...version, reason: 'ai_turn' },
          },
        },
      },
      gameId
    ),
  undefined,
  'ordinary restore versions must not retain the removed AI turn reason compatibility'
);

const parsed = protocol.assertPlaymeshHistoryRestoreEnvelope(
  { requestId: 'request-1', transaction },
  gameId
);
assert.equal(parsed.transaction.targetSnapshot.sourceVersion.revision, 4);
assert.deepEqual(parsed.transaction.targetSnapshot.projectReference, {
  contentHash: hash('f'),
  size: 18,
});
assert.deepEqual(parsed.transaction.targetSnapshot.resources, [resource]);

assert.throws(() =>
  protocol.assertPlaymeshHistoryRestoreTransaction(
    { ...transaction, targetSnapshot: undefined },
    gameId
  )
);
assert.throws(() =>
  protocol.assertPlaymeshHistoryRestoreTransaction(
    {
      ...transaction,
      restored: {
        version: { ...version, revision: 9 },
        project: targetSnapshot.project,
        resources: targetSnapshot.resources,
        playmeshProjectConfig: config,
      },
    },
    gameId
  )
);
assert.throws(() =>
  protocol.assertPlaymeshHistoryRestoreTransaction(
    {
      ...transaction,
      targetSnapshot: {
        ...targetSnapshot,
        sourceVersion: { ...version, revision: 3 },
      },
    },
    gameId
  )
);
assert.throws(() =>
  protocol.assertPlaymeshHistoryRestoreTransaction(
    {
      ...transaction,
      targetEvidence: {
        ...transaction.targetEvidence,
        history: historyEvidence(9, '2'),
      },
    },
    gameId
  )
);

for (const invalidSize of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, '4']) {
  assert.throws(() =>
    protocol.assertPlaymeshHistoryRestoreResource({
      ...resource,
      size: invalidSize,
    })
  );
  assert.throws(() =>
    protocol.assertPlaymeshHistoryRestoreTransaction(
      {
        ...transaction,
        targetSnapshot: {
          ...targetSnapshot,
          projectReference: {
            ...targetSnapshot.projectReference,
            size: invalidSize,
          },
        },
      },
      gameId
    )
  );
}

const missingConfigTransaction = {
  ...transaction,
  oldEvidence: {
    ...transaction.oldEvidence,
    config: { semantics: 'missing', status: 'missing' },
  },
  targetEvidence: {
    ...transaction.targetEvidence,
    config: { semantics: 'missing', status: 'missing' },
  },
  targetSnapshot: { ...targetSnapshot, playmeshProjectConfig: null },
};
assert.equal(
  protocol.assertPlaymeshHistoryRestoreTransaction(
    missingConfigTransaction,
    gameId
  ).targetSnapshot.playmeshProjectConfig,
  null
);

assert.deepEqual(
  protocol.createPlaymeshHistoryRestorePrepareBody({
    idempotencyKey: 'restore.001',
    baseRevision: 7,
    targetRevision: 4,
    source: 'user',
    currentProject: { name: 'Current' },
    currentResources: [resource],
    clientId: ' client-1 ',
  }),
  {
    idempotencyKey: 'restore.001',
    baseRevision: 7,
    targetRevision: 4,
    source: 'user',
    currentProject: { name: 'Current' },
    currentResources: [resource],
    clientId: 'client-1',
  }
);
assert.equal(
  protocol.buildPlaymeshHistoryRestoreBaseUrl(gameId),
  `/dev/api/gdevelop/projects/${gameId}/history/restore-transactions`
);

process.stdout.write('GDevelop history restore protocol tests passed.\n');
