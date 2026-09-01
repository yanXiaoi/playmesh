import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = sourceText =>
  import(
    `data:text/javascript;base64,${Buffer.from(sourceText).toString('base64')}`
  );
let projectConfigSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjectConfig/PlaymeshProjectConfigProtocol.js'
  ),
  'utf8'
);
globalThis.__playmeshProjectConfigProtocol = await importSource(
  projectConfigSource.replace(/^\/\/ @flow\s*/, '')
);
let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreProtocol.js'
  ),
  'utf8'
);
source = source.replace(/^\/\/ @flow\s*/, '').replace(
  /import \{[\s\S]*?\} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
  `const {
  assertPlaymeshProjectConfig,
  validatePlaymeshProjectConfigGameId,
} = globalThis.__playmeshProjectConfigProtocol;`
);
const protocol = await importSource(source);

const gameId = 'com.playmesh.game.restore001';
const hash = character => character.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const config = {
  schemaVersion: 2,
  gameId,
  revision: 3,
  gameType: 'online',
  minPlayers: 2,
  maxPlayers: 5,
  tags: [],
  webRuntimeMultithreading: false,
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
  projectFilesHash: hash(character),
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
  projectFilesReference: [
    { path: 'game.json', contentHash: hash('f'), size: 18 },
  ],
  projectFiles: [{ path: 'game.json', content: { name: 'Target' } }],
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
assert.doesNotThrow(
  () =>
    protocol.assertPlaymeshHistoryRestoreEnvelope(
      {
        requestId: 'request-autosave',
        transaction: {
          ...transaction,
          targetSnapshot: {
            ...targetSnapshot,
            sourceVersion: {
              ...version,
              reason: 'autosave',
              source: 'system',
            },
          },
        },
      },
      gameId
    ),
  'autosave revisions must remain restorable through the ordinary history protocol'
);

const parsed = protocol.assertPlaymeshHistoryRestoreEnvelope(
  { requestId: 'request-1', transaction },
  gameId
);
assert.equal(parsed.transaction.targetSnapshot.sourceVersion.revision, 4);
assert.deepEqual(parsed.transaction.targetSnapshot.playmeshProjectConfig, config);
assert.deepEqual(parsed.transaction.targetSnapshot.projectFilesReference, [
  { path: 'game.json', contentHash: hash('f'), size: 18 },
]);
assert.deepEqual(parsed.transaction.targetSnapshot.resources, [resource]);
assert.throws(() =>
  protocol.assertPlaymeshHistoryRestoreEnvelope(
    {
      requestId: 'request-schema-1',
      transaction: {
        ...transaction,
        targetSnapshot: {
          ...targetSnapshot,
          playmeshProjectConfig: {
            schemaVersion: 1,
            gameId,
            revision: 3,
            gameType: 'online',
            updatedAt: timestamp,
          },
        },
      },
    },
    gameId
  )
);

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
        projectFiles: targetSnapshot.projectFiles,
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
          projectFilesReference: [
            {
              ...targetSnapshot.projectFilesReference[0],
              size: invalidSize,
            },
          ],
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
    currentProjectFiles: [
      { path: 'game.json', content: { name: 'Current' } },
    ],
    currentResources: [resource],
    clientId: ' client-1 ',
  }),
  {
    idempotencyKey: 'restore.001',
    baseRevision: 7,
    targetRevision: 4,
    source: 'user',
    currentProjectFiles: [
      { path: 'game.json', content: { name: 'Current' } },
    ],
    currentResources: [resource],
    clientId: 'client-1',
  }
);
assert.equal(
  protocol.buildPlaymeshHistoryRestoreBaseUrl(gameId),
  `/dev/api/gdevelop/projects/${gameId}/history/restore-transactions`
);

process.stdout.write('GDevelop history restore protocol tests passed.\n');
