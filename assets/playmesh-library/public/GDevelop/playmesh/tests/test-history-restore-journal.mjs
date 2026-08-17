import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
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

const sha256Module = await importSource(
  transformFlow(await readOverlay('PlaymeshCrypto/PlaymeshSha256.js'))
);
globalThis.__playmeshSha256 = sha256Module;

const storeSource = await readOverlay(
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore.js'
);
assert.doesNotMatch(storeSource, /indexedDB|IDBDatabase|createObjectStore/);
const storeModule = await importSource(transformFlow(storeSource));
globalThis.__historyStore = storeModule;

let protocolSource = await readOverlay(
  'PlaymeshHistory/PlaymeshHistoryRestoreProtocol.js'
);
protocolSource = protocolSource.replace(
  /import \{[\s\S]*?\} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
  `const validatePlaymeshProjectConfigGameId = value => {
  if (typeof value !== 'string' || !value) throw new Error('invalid game id');
  return value;
};
const validatePlaymeshProjectGameType = value => value;`
);
const protocolModule = await importSource(transformFlow(protocolSource));
globalThis.__historyProtocol = protocolModule;

let evidenceSource = await readOverlay(
  'PlaymeshHistory/PlaymeshHistoryEvidence.js'
);
evidenceSource = evidenceSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
  `const {
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreResource,
} = globalThis.__historyProtocol;`
);
evidenceSource = evidenceSource.replace(
  /import \{ sha256Hex \} from '\.\.\/PlaymeshCrypto\/PlaymeshSha256';/,
  'const { sha256Hex } = globalThis.__playmeshSha256;'
);
const evidenceModule = await importSource(transformFlow(evidenceSource));
globalThis.__historyEvidence = evidenceModule;

let journalSource = await readOverlay(
  'PlaymeshHistory/PlaymeshHistoryRestoreJournal.js'
);
assert.doesNotMatch(journalSource, /indexedDB|IDBDatabase|createObjectStore/);
journalSource = journalSource
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/ProjectsStorage\/PlaymeshLocalStorageProvider\/PlaymeshProjectStore';/,
    `const {
  assertStoredProject,
  getStoredProject,
  putStoredProject,
} = globalThis.__historyStore;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
    `const {
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreProjectEvidence,
  validatePlaymeshHistoryRestoreIdempotencyKey,
  validatePlaymeshHistoryRestoreRevision,
  validatePlaymeshHistoryRestoreSource,
} = globalThis.__historyProtocol;`
  )
  .replace(
    /import \{ validatePlaymeshProjectConfigGameId \} from '\.\.\/PlaymeshProjectConfig\/PlaymeshProjectConfigProtocol';/,
    `const validatePlaymeshProjectConfigGameId = value => value;`
  )
  .replace(
    /import \{ computePlaymeshHistoryBrowserEvidence \} from '\.\/PlaymeshHistoryEvidence';/,
    'const { computePlaymeshHistoryBrowserEvidence } = globalThis.__historyEvidence;'
  )
  .replace(/export \{[\s\S]*?\} from '\.\/PlaymeshHistoryEvidence';/, '');
const journalModule = await importSource(transformFlow(journalSource));

const gameId = 'com.playmesh.game.restore001';
const existingProject = {
  id: 'file-a',
  name: 'Existing',
  gameId,
  projectJson: JSON.stringify({ properties: { name: 'Existing' } }),
  resources: [
    {
      logicalUrl: 'playmesh-local-resource://old.txt',
      name: 'old.txt',
      blob: new Blob(['old'], { type: 'text/plain' }),
    },
  ],
  savedAt: 1,
};
await storeModule.putStoredProject(existingProject);
const oldBrowserEvidence =
  await evidenceModule.computePlaymeshHistoryBrowserEvidence(existingProject);
const targetProject = {
  ...existingProject,
  name: 'Target',
  projectJson: JSON.stringify({ properties: { name: 'Target' } }),
  resources: [
    {
      logicalUrl: 'playmesh-local-resource://target.txt',
      name: 'target.txt',
      blob: new Blob(['target'], { type: 'text/plain' }),
    },
  ],
  savedAt: 2,
};
const targetBrowserEvidence =
  await evidenceModule.computePlaymeshHistoryBrowserEvidence(targetProject);
const hash = character => character.repeat(64);
const timestamp = '2026-08-05T01:02:03.000Z';
const configEvidence = {
  semantics: 'ready',
  status: 'ready',
  revision: 1,
  contentHash: hash('a'),
  config: {
    schemaVersion: 1,
    gameId,
    revision: 1,
    gameType: 'online',
    updatedAt: timestamp,
  },
};
const transaction = {
  txId: 'tx-a',
  gameId,
  idempotencyKey: 'restore-tx-a',
  phase: 'PREPARED',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  oldEvidence: {
    history: { revision: 7, currentContentHash: hash('1'), ...oldBrowserEvidence },
    config: configEvidence,
  },
  targetEvidence: {
    history: { revision: 8, currentContentHash: hash('2'), ...targetBrowserEvidence },
    config: configEvidence,
  },
  createdAt: timestamp,
  updatedAt: timestamp,
};

const prepared = journalModule.createPlaymeshHistoryRestoreJournalRecord({
  transaction,
  fileIdentifier: existingProject.id,
  oldBrowserEvidence,
  now: timestamp,
});
await journalModule.persistPreparedPlaymeshHistoryRestoreJournal(prepared);
let state = await journalModule.readPlaymeshHistoryRestoreBrowserState({
  gameId,
  fileIdentifier: existingProject.id,
});
assert.equal(state.project.projectJson, existingProject.projectJson);
assert.equal(state.journal.phase, 'PREPARED_LOCAL');

const applied = await journalModule.applyPlaymeshHistoryRestoreAtomically({
  project: targetProject,
  journal: prepared,
  now: timestamp,
});
state = await journalModule.readPlaymeshHistoryRestoreBrowserState({
  gameId,
  fileIdentifier: existingProject.id,
});
assert.equal(applied.phase, 'BROWSER_APPLIED_PENDING_ACK');
assert.equal(state.project.projectJson, targetProject.projectJson);
assert.deepEqual(state.journal.browserEvidence, targetBrowserEvidence);

await assert.rejects(
  journalModule.clearPlaymeshHistoryRestoreJournal({ gameId, txId: 'other' })
);
await journalModule.clearPlaymeshHistoryRestoreJournal({
  gameId,
  txId: transaction.txId,
});
state = await journalModule.readPlaymeshHistoryRestoreBrowserState({
  gameId,
  fileIdentifier: existingProject.id,
});
assert.equal(state.journal, null);
assert.equal(state.project.projectJson, targetProject.projectJson);

process.stdout.write(
  'GDevelop history restore App-authority/session-journal tests passed.\n'
);
