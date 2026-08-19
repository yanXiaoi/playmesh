import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}`);

globalThis.window = { crypto: webcrypto };
let coordinatorSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjectRekey/PlaymeshProjectRekeyCoordinator.js'
  ),
  'utf8'
);
coordinatorSource = coordinatorSource.replace(
  /import(?: type)?[\s\S]*? from '[^']+';\r?\n/g,
  ''
);
coordinatorSource = `
const mirrorPreparedProject = async () => {};
const getPlaymeshHistoryCurrent = async () => { throw new Error('unused'); };
const hashPlaymeshHistoryBytes = async () => '0'.repeat(64);
const hashPlaymeshHistoryJson = async () => '0'.repeat(64);
class PlaymeshProjectConfigClient { read() { throw new Error('unused'); } }
const runPlaymeshProjectMutation = ({ operation }) => operation();
const playmeshProjectRekeyClient = {};
const createPlaymeshProjectRekeyJournalRecord = async () => { throw new Error('unused'); };
const persistPreparedPlaymeshProjectRekeyJournal = async () => { throw new Error('unused'); };
const applyPlaymeshProjectRekeyTargetAtomically = async () => { throw new Error('unused'); };
const restorePlaymeshProjectRekeySourceAtomically = async () => { throw new Error('unused'); };
const readPlaymeshProjectRekeyBrowserState = async () => { throw new Error('unused'); };
const classifyPlaymeshProjectRekeyBrowserState = async () => 'third';
const createPlaymeshProjectRekeyBrowserEvidence = () => { throw new Error('unused'); };
const clearPlaymeshProjectRekeyJournal = async () => {};
${coordinatorSource}`;
const coordinator = await importSource(transformFlow(coordinatorSource));

const oldGameId = 'com.playmesh.game.old001';
const newGameId = 'com.playmesh.game.new001';
const fileIdentifier = 'file-a';
const timestamp = '2026-08-05T01:02:03.000Z';
const hashJson = value =>
  createHash('sha256')
    .update(JSON.stringify(value))
    .digest('hex');
const sourceJson = { properties: { name: 'Source', packageName: oldGameId } };
const targetJson = { properties: { name: 'Target', packageName: newGameId } };
const sourceProjectFiles = [{ path: 'game.json', content: sourceJson }];
const targetProjectFiles = [{ path: 'game.json', content: targetJson }];
const sourceHash = hashJson(sourceProjectFiles);
const targetHash = hashJson(targetProjectFiles);
const resourceHash = hashJson([]);
const sourceStored = {
  id: fileIdentifier,
  name: 'Source',
  gameId: oldGameId,
  projectFiles: sourceProjectFiles,
  resources: [],
  savedAt: 1,
};
const targetStored = {
  id: fileIdentifier,
  name: 'Target',
  gameId: newGameId,
  projectFiles: targetProjectFiles,
  resources: [],
  savedAt: 2,
};
const sourcePrepared = {
  fileMetadata: {
    fileIdentifier,
    name: 'Source',
    gameId: oldGameId,
    lastModifiedDate: 1,
  },
  snapshot: { projectFiles: sourceProjectFiles, resources: [] },
  storedProject: sourceStored,
};
const targetPrepared = {
  fileMetadata: {
    fileIdentifier,
    name: 'Target',
    gameId: newGameId,
    lastModifiedDate: 2,
  },
  snapshot: { projectFiles: targetProjectFiles, resources: [] },
  storedProject: targetStored,
};
const historyEvidence = marker => ({
  revision: 1,
  currentContentHash: marker.repeat(64),
  projectFilesHash: sourceHash,
  resourceManifestHash: resourceHash,
});
const configEvidence = gameId => ({
  status: 'ready',
  revision: 1,
  contentHash: 'a'.repeat(64),
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
  projectMetadataHash: 'b'.repeat(64),
  rootManifestHash: 'c'.repeat(64),
  history: historyEvidence(marker),
  config: configEvidence(gameId),
  mainJsonHash: null,
});

const makeTransaction = (phase, overrides = {}) => ({
  txId: 'tx-a',
  idempotencyKey: 'rekey-fixed',
  oldGameId,
  newGameId,
  phase,
  clientId: 'client-fixed',
  browserSource: { fileIdentifier, projectFilesHash: sourceHash },
  browserTarget: { fileIdentifier, projectFilesHash: targetHash },
  oldEvidence: backendEvidence(oldGameId, 'd'),
  targetEvidence: backendEvidence(newGameId, 'e'),
  createdAt: timestamp,
  updatedAt: timestamp,
  expiresAt: null,
  retainedUntil: null,
  browserEvidence: null,
  rollbackBrowserEvidence: null,
  cleanupPending: false,
  cleanupError: null,
  conflict: phase === 'CONFLICT' ? { reason: 'target_changed' } : null,
  ...overrides,
});

const makeHarness = ({
  initialTransaction = makeTransaction('PREPARED'),
  initialProject = sourceStored,
  initialJournal = null,
} = {}) => {
  const state = {
    project: structuredClone(initialProject),
    journal: initialJournal ? structuredClone(initialJournal) : null,
    transaction: structuredClone(initialTransaction),
    calls: [],
    prepareFailures: 0,
    commitResponseLoss: false,
    acknowledgeResponseLoss: false,
    rollbackResponseLoss: false,
    recoverResponseLoss: false,
    persistJournalFailure: false,
    applyTargetFailure: false,
    restoreSourceFailure: false,
  };
  const transition = phase => {
    state.transaction = makeTransaction(phase, {
      cleanupPending: state.transaction.cleanupPending,
      cleanupError: state.transaction.cleanupError,
      browserEvidence:
        phase === 'OLD_CLEANED'
          ? {
              fileMetadata: { fileIdentifier, gameId: newGameId },
              packageName: newGameId,
              projectFilesHash: targetHash,
            }
          : null,
      rollbackBrowserEvidence:
        phase === 'ROLLED_BACK'
          ? {
              fileMetadata: { fileIdentifier, gameId: oldGameId },
              packageName: oldGameId,
              projectFilesHash: sourceHash,
            }
          : null,
    });
    return { requestId: `request-${phase}`, transaction: state.transaction };
  };
  const dependencies = {
    client: {
      async prepare(input) {
        state.calls.push(['prepare', input]);
        if (state.prepareFailures > 0) {
          state.prepareFailures--;
          throw new Error('prepare response lost');
        }
        return transition('PREPARED');
      },
      async commit() {
        state.calls.push(['commit']);
        const result = transition('NEW_PUBLISHED');
        if (state.commitResponseLoss) {
          state.commitResponseLoss = false;
          throw new Error('commit response lost');
        }
        return result;
      },
      async status() {
        state.calls.push(['status']);
        return { requestId: 'request-status', transaction: state.transaction };
      },
      async acknowledge() {
        state.calls.push(['acknowledge']);
        const result = transition('OLD_CLEANED');
        if (state.acknowledgeResponseLoss) {
          state.acknowledgeResponseLoss = false;
          throw new Error('ack response lost');
        }
        return result;
      },
      async rollback() {
        state.calls.push(['rollback']);
        const result = transition('ROLLED_BACK');
        if (state.rollbackResponseLoss) {
          state.rollbackResponseLoss = false;
          throw new Error('rollback response lost');
        }
        return result;
      },
      async recover() {
        state.calls.push(['recover']);
        if (state.recoverResponseLoss) {
          state.recoverResponseLoss = false;
          throw new Error('recover response lost');
        }
        return {
          requestId: 'request-recover',
          transaction: state.transaction,
          replayedEventTxIds: [],
          cleanupPendingTxIds: [],
        };
      },
      async abort() {
        state.calls.push(['abort']);
        return transition('ABORTED');
      },
    },
    async getHistoryCurrent() {
      return {
        capability: 'gdevelop.project-history.v1',
        gameId: oldGameId,
        current: {
          version: {
            revision: 1,
            contentHash: 'd'.repeat(64),
          },
          projectFiles: sourceProjectFiles,
          resources: [],
        },
      };
    },
    async readConfig() {
      return {
        requestId: 'request-config',
        status: 'ready',
        config: configEvidence(oldGameId).config,
      };
    },
    async mirrorSource(source) {
      state.calls.push(['mirrorSource']);
      state.project = structuredClone(source.storedProject);
    },
    hashJson: async value => hashJson(value),
    hashBytes: async bytes =>
      createHash('sha256')
        .update(Buffer.from(bytes))
        .digest('hex'),
    mutationRunner: ({ operation }) => operation(),
    async createJournal({ transaction, sourceProject, targetProject }) {
      return {
        schemaVersion: 1,
        fileIdentifier,
        txId: transaction.txId,
        idempotencyKey: transaction.idempotencyKey,
        oldGameId,
        newGameId,
        phase: 'PREPARED_LOCAL',
        browserSource: transaction.browserSource,
        browserTarget: transaction.browserTarget,
        sourceEvidence: {
          projectFilesHash: sourceHash,
          resourceManifestHash: resourceHash,
        },
        targetEvidence: {
          projectFilesHash: targetHash,
          resourceManifestHash: resourceHash,
        },
        sourceProject: structuredClone(sourceProject),
        targetProject: structuredClone(targetProject),
        createdAt: timestamp,
        updatedAt: timestamp,
      };
    },
    async persistJournal(journal) {
      if (state.persistJournalFailure) {
        throw new Error('journal persist failed');
      }
      state.journal = structuredClone(journal);
    },
    async applyTarget({ journal }) {
      if (state.applyTargetFailure) throw new Error('target write failed');
      state.project = structuredClone(journal.targetProject);
      state.journal = {
        ...structuredClone(journal),
        phase: 'TARGET_APPLIED_PENDING_ACK',
      };
      return state.journal;
    },
    async restoreSource({ journal }) {
      if (state.restoreSourceFailure) throw new Error('reverse write failed');
      state.project = structuredClone(journal.sourceProject);
      state.journal = {
        ...structuredClone(journal),
        phase: 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK',
      };
      return state.journal;
    },
    async readBrowserState() {
      return {
        project: state.project ? structuredClone(state.project) : null,
        journal: state.journal ? structuredClone(state.journal) : null,
      };
    },
    async classifyBrowserState(project, journal) {
      const projectHash = hashJson(project.projectFiles);
      if (
        project.gameId === oldGameId &&
        projectHash === journal.sourceEvidence.projectFilesHash
      ) {
        return 'source';
      }
      if (
        project.gameId === newGameId &&
        projectHash === journal.targetEvidence.projectFilesHash
      ) {
        return 'target';
      }
      return 'third';
    },
    browserEvidence(journal, side) {
      const source = side === 'source';
      const gameId = source ? oldGameId : newGameId;
      return {
        fileMetadata: { fileIdentifier, gameId },
        packageName: gameId,
        projectFilesHash: source
          ? journal.sourceEvidence.projectFilesHash
          : journal.targetEvidence.projectFilesHash,
      };
    },
    async clearJournal() {
      state.journal = null;
    },
    idempotencyKeyFactory: () => 'rekey-fixed',
    clientIdFactory: () => 'client-fixed',
  };
  return { state, dependencies, transition };
};

const execute = harness =>
  coordinator.rekeyPlaymeshProjectLocalIdentity({
    oldGameId,
    newGameId,
    source: sourcePrepared,
    target: targetPrepared,
    dependencies: harness.dependencies,
  });

{
  const harness = makeHarness();
  const result = await execute(harness);
  assert.equal(result.outcome, 'committed');
  assert.equal(result.fileMetadata.gameId, newGameId);
  assert.equal(harness.state.project.gameId, newGameId);
  assert.equal(harness.state.journal, null);
}

{
  const harness = makeHarness();
  harness.state.prepareFailures = 1;
  const result = await execute(harness);
  assert.equal(result.outcome, 'committed');
  const prepares = harness.state.calls.filter(([name]) => name === 'prepare');
  assert.equal(prepares.length, 2);
  assert.equal(prepares[0][1].idempotencyKey, prepares[1][1].idempotencyKey);
}

{
  const harness = makeHarness();
  harness.state.commitResponseLoss = true;
  const result = await execute(harness);
  assert.equal(result.outcome, 'committed');
  assert.equal(harness.state.calls.some(([name]) => name === 'status'), true);
}

{
  const harness = makeHarness();
  harness.state.persistJournalFailure = true;
  await assert.rejects(
    execute(harness),
    error =>
      error instanceof coordinator.PlaymeshProjectRekeyCoordinatorError &&
      error.code === 'browser_journal_persist_failed' &&
      error.rollbackCompleted
  );
  assert.equal(harness.state.calls.some(([name]) => name === 'abort'), true);
  assert.equal(harness.state.calls.some(([name]) => name === 'commit'), false);
  assert.equal(harness.state.project.gameId, oldGameId);
  assert.equal(harness.state.journal, null);
}

{
  const harness = makeHarness();
  harness.state.acknowledgeResponseLoss = true;
  const result = await execute(harness);
  assert.equal(result.outcome, 'committed');
  assert.equal(harness.state.journal, null);
}

{
  const harness = makeHarness();
  harness.state.applyTargetFailure = true;
  await assert.rejects(
    execute(harness),
    error =>
      error instanceof coordinator.PlaymeshProjectRekeyCoordinatorError &&
      error.code === 'browser_target_write_failed' &&
      error.rollbackCompleted
  );
  assert.equal(harness.state.project.gameId, oldGameId);
  assert.equal(harness.state.journal, null);
}

{
  const harness = makeHarness();
  harness.dependencies.client.acknowledge = async () => {
    harness.state.transaction = makeTransaction('BROWSER_UPDATED');
    return {
      requestId: 'request-browser',
      transaction: harness.state.transaction,
    };
  };
  harness.dependencies.client.recover = async () => {
    harness.state.transaction = makeTransaction('ROLLBACK_REQUESTED');
    return {
      requestId: 'request-recover',
      transaction: harness.state.transaction,
      replayedEventTxIds: [],
      cleanupPendingTxIds: [],
    };
  };
  const result = await execute(harness);
  assert.equal(result.outcome, 'rolled_back');
  assert.equal(harness.state.project.gameId, oldGameId);
}

const journalFor = phase => ({
  schemaVersion: 1,
  fileIdentifier,
  txId: 'tx-a',
  idempotencyKey: 'rekey-fixed',
  oldGameId,
  newGameId,
  phase,
  browserSource: { fileIdentifier, projectFilesHash: sourceHash },
  browserTarget: { fileIdentifier, projectFilesHash: targetHash },
  sourceEvidence: {
    projectFilesHash: sourceHash,
    resourceManifestHash: resourceHash,
  },
  targetEvidence: {
    projectFilesHash: targetHash,
    resourceManifestHash: resourceHash,
  },
  sourceProject: sourceStored,
  targetProject: targetStored,
  createdAt: timestamp,
  updatedAt: timestamp,
});
const recover = harness =>
  coordinator.recoverPlaymeshProjectRekeyLocalIdentity({
    fileMetadata: targetPrepared.fileMetadata,
    dependencies: harness.dependencies,
  });

for (const phase of [
  'PREPARED',
  'COMMIT_REQUESTED',
  'NEW_PUBLISHED',
  'BROWSER_UPDATED',
  'ROLLBACK_REQUESTED',
  'ROLLED_BACK',
  'ABORTED',
]) {
  const targetSide =
    phase === 'NEW_PUBLISHED' ||
    phase === 'BROWSER_UPDATED' ||
    phase === 'ROLLBACK_REQUESTED';
  const harness = makeHarness({
    initialTransaction: makeTransaction(phase),
    initialProject: targetSide ? targetStored : sourceStored,
    initialJournal: journalFor(
      targetSide
        ? 'TARGET_APPLIED_PENDING_ACK'
        : 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK'
    ),
  });
  const result = await recover(harness);
  assert.equal(result.outcome, 'rolled_back', phase);
  assert.equal(harness.state.project.gameId, oldGameId, phase);
  assert.equal(harness.state.journal, null, phase);
}

{
  const committed = makeTransaction('OLD_CLEANED', {
    cleanupPending: true,
    cleanupError: 'tombstone cleanup failed',
  });
  const harness = makeHarness({
    initialTransaction: committed,
    initialProject: targetStored,
    initialJournal: journalFor('TARGET_APPLIED_PENDING_ACK'),
  });
  const result = await recover(harness);
  assert.equal(result.outcome, 'committed');
  assert.equal(result.transaction.cleanupPending, true);
  assert.equal(harness.state.journal, null);
}

{
  const harness = makeHarness({
    initialTransaction: makeTransaction('CONFLICT'),
    initialProject: sourceStored,
    initialJournal: journalFor('SOURCE_RESTORED_PENDING_ROLLBACK_ACK'),
  });
  await assert.rejects(
    recover(harness),
    error => error.code === 'backend_conflict' && error.blocked
  );
  assert.notEqual(harness.state.journal, null);
}

{
  const harness = makeHarness({
    initialTransaction: makeTransaction('ROLLBACK_REQUESTED'),
    initialProject: targetStored,
    initialJournal: journalFor('TARGET_APPLIED_PENDING_ACK'),
  });
  harness.state.restoreSourceFailure = true;
  await assert.rejects(
    recover(harness),
    error => error.code === 'browser_source_restore_failed' && error.blocked
  );
  assert.equal(harness.state.project.gameId, newGameId);
  assert.notEqual(harness.state.journal, null);
  harness.state.restoreSourceFailure = false;
  const retried = await recover(harness);
  assert.equal(retried.outcome, 'rolled_back');
  assert.equal(harness.state.project.gameId, oldGameId);
}

{
  const harness = makeHarness({
    initialTransaction: makeTransaction('ROLLBACK_REQUESTED'),
    initialProject: targetStored,
    initialJournal: journalFor('TARGET_APPLIED_PENDING_ACK'),
  });
  harness.state.rollbackResponseLoss = true;
  const result = await recover(harness);
  assert.equal(result.outcome, 'rolled_back');
  assert.equal(harness.state.calls.some(([name]) => name === 'status'), true);
}

{
  const harness = makeHarness({
    initialTransaction: makeTransaction('ROLLBACK_REQUESTED'),
    initialProject: targetStored,
    initialJournal: journalFor('TARGET_APPLIED_PENDING_ACK'),
  });
  harness.state.recoverResponseLoss = true;
  const result = await recover(harness);
  assert.equal(result.outcome, 'rolled_back');
}

{
  const thirdProject = {
    ...targetStored,
    projectFiles: [
      {
        path: 'game.json',
        content: { properties: { name: 'Third' } },
      },
    ],
  };
  const harness = makeHarness({
    initialTransaction: makeTransaction('ROLLBACK_REQUESTED'),
    initialProject: thirdProject,
    initialJournal: journalFor('TARGET_APPLIED_PENDING_ACK'),
  });
  await assert.rejects(
    recover(harness),
    error => error.code === 'browser_third_state' && error.blocked
  );
}

{
  const harness = makeHarness({
    initialTransaction: makeTransaction('PREPARED'),
  });
  harness.state.journal = null;
  const result = await coordinator.recoverPlaymeshProjectRekeyLocalIdentity({
    fileMetadata: sourcePrepared.fileMetadata,
    dependencies: harness.dependencies,
  });
  assert.equal(result.outcome, 'idle');
  assert.equal(harness.state.calls.some(([name]) => name === 'abort'), true);
}

process.stdout.write('GDevelop project rekey coordinator tests passed.\n');
