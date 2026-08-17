import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const readOverlay = relativePath =>
  readFile(
    path.resolve(testDirectory, '../overlays/newIDE/app/src', relativePath),
    'utf8'
  );

globalThis.window = { crypto: webcrypto };

const storeSource = await readOverlay(
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore.js'
);
assert.doesNotMatch(storeSource, /indexedDB|IDBDatabase|createObjectStore/);
const storeModule = await importSource(transformFlow(storeSource));
globalThis.__rekeyStore = storeModule;

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

const hashJson = value =>
  createHash('sha256').update(JSON.stringify(value)).digest('hex');
const computeEvidence = async project => ({
  projectJsonHash: hashJson(JSON.parse(project.projectJson)),
  resourceManifestHash: hashJson(
    await Promise.all(
      project.resources.map(async resource => ({
        logicalUrl: resource.logicalUrl,
        contentHash: createHash('sha256')
          .update(Buffer.from(await resource.blob.arrayBuffer()))
          .digest('hex'),
      }))
    )
  ),
});
globalThis.__rekeyEvidence = {
  computePlaymeshHistoryBrowserEvidence: computeEvidence,
  assertPlaymeshHistoryBrowserEvidenceMatches(actual, expected) {
    assert.deepEqual(actual, expected);
  },
};

let journalSource = await readOverlay(
  'PlaymeshProjectRekey/PlaymeshProjectRekeyJournal.js'
);
assert.doesNotMatch(journalSource, /indexedDB|IDBDatabase|createObjectStore/);
journalSource = journalSource
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/ProjectsStorage\/PlaymeshLocalStorageProvider\/PlaymeshProjectStore';/,
    `const {
  assertStoredProject,
  getStoredProject,
  putStoredProject,
} = globalThis.__rekeyStore;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshProjectRekeyProtocol';/,
    `const {
  assertPlaymeshProjectRekeyBrowserTarget,
  assertPlaymeshProjectRekeyTransaction,
  validatePlaymeshProjectRekeyToken,
} = globalThis.__rekeyProtocol;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/PlaymeshHistory\/PlaymeshHistoryEvidence';/,
    `const {
  assertPlaymeshHistoryBrowserEvidenceMatches,
  computePlaymeshHistoryBrowserEvidence,
} = globalThis.__rekeyEvidence;`
  )
  .replace(
    /import \{ validatePlaymeshProjectConfigGameId \} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
    'const validatePlaymeshProjectConfigGameId = value => value;'
  );
const journal = await importSource(transformFlow(journalSource));

const oldGameId = 'com.playmesh.game.old001';
const newGameId = 'com.playmesh.game.new001';
const fileIdentifier = 'file-a';
const sourceProject = {
  id: fileIdentifier,
  name: 'Source',
  gameId: oldGameId,
  projectJson: JSON.stringify({ properties: { packageName: oldGameId } }),
  resources: [
    {
      logicalUrl: 'playmesh://hero.png',
      blob: new Blob(['old'], { type: 'image/png' }),
    },
  ],
  savedAt: 1,
};
const targetProject = {
  ...sourceProject,
  name: 'Target',
  gameId: newGameId,
  projectJson: JSON.stringify({ properties: { packageName: newGameId } }),
  savedAt: 2,
};
await storeModule.putStoredProject(sourceProject);
const sourceEvidence = await computeEvidence(sourceProject);
const targetEvidence = await computeEvidence(targetProject);
const hash = marker => marker.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
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
const backendEvidence = gameId => ({
  projectMetadataHash: hash('b'),
  rootManifestHash: hash('c'),
  history: {
    revision: 1,
    currentContentHash: hash('d'),
    projectJsonHash: sourceEvidence.projectJsonHash,
    resourceManifestHash: sourceEvidence.resourceManifestHash,
  },
  config: configEvidence(gameId),
  mainJsonHash: null,
});
const transaction = {
  txId: 'tx-a',
  idempotencyKey: 'rekey-a',
  oldGameId,
  newGameId,
  phase: 'PREPARED',
  clientId: null,
  browserSource: { fileIdentifier, projectJsonHash: sourceEvidence.projectJsonHash },
  browserTarget: { fileIdentifier, projectJsonHash: targetEvidence.projectJsonHash },
  oldEvidence: backendEvidence(oldGameId),
  targetEvidence: backendEvidence(newGameId),
  createdAt: timestamp,
  updatedAt: timestamp,
  expiresAt: null,
  retainedUntil: null,
  browserEvidence: null,
  rollbackBrowserEvidence: null,
  cleanupPending: false,
  cleanupError: null,
  conflict: null,
};

const prepared = await journal.createPlaymeshProjectRekeyJournalRecord({
  transaction,
  sourceProject,
  targetProject,
  now: timestamp,
});
await journal.persistPreparedPlaymeshProjectRekeyJournal(prepared);
let state = await journal.readPlaymeshProjectRekeyBrowserState(fileIdentifier);
assert.equal(state.project.gameId, oldGameId);
assert.equal(state.journal.phase, 'PREPARED_LOCAL');

const targetApplied = await journal.applyPlaymeshProjectRekeyTargetAtomically({
  journal: prepared,
  now: timestamp,
});
state = await journal.readPlaymeshProjectRekeyBrowserState(fileIdentifier);
assert.equal(state.project.gameId, newGameId);
assert.equal(targetApplied.phase, 'TARGET_APPLIED_PENDING_ACK');
assert.equal(
  await journal.classifyPlaymeshProjectRekeyBrowserState(
    state.project,
    state.journal
  ),
  'target'
);

const restored = await journal.restorePlaymeshProjectRekeySourceAtomically({
  journal: targetApplied,
  now: timestamp,
});
state = await journal.readPlaymeshProjectRekeyBrowserState(fileIdentifier);
assert.equal(state.project.gameId, oldGameId);
assert.equal(restored.phase, 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK');

await assert.rejects(
  journal.clearPlaymeshProjectRekeyJournal({
    fileIdentifier,
    txId: 'tx-other',
  })
);
await journal.clearPlaymeshProjectRekeyJournal({
  fileIdentifier,
  txId: transaction.txId,
});
state = await journal.readPlaymeshProjectRekeyBrowserState(fileIdentifier);
assert.equal(state.journal, null);
assert.equal(state.project.gameId, oldGameId);

process.stdout.write(
  'GDevelop rekey App-authority/session-journal tests passed.\n'
);
