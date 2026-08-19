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
  location: { reload() {} },
  sessionStorage: {
    getItem: () => null,
    setItem() {},
  },
  dispatchEvent() {},
};
globalThis.CustomEvent = class CustomEvent {
  constructor(type, init) {
    this.type = type;
    this.detail = init.detail;
  }
};

globalThis.__historyClient = {
  ensureKnownPlaymeshHistoryRevision: async () => 1,
  preparePlaymeshHistorySnapshot: async snapshot => snapshot,
  toPlaymeshHistoryResourceDto: resource => {
    const { blob, ...dto } = resource;
    return dto;
  },
  uploadMissingPlaymeshHistoryResources: async () => 0,
};
globalThis.__historySerializer = {
  createProjectSnapshot: async () => ({ projectFiles: [], resources: [] }),
  createRestoredStoredProject: () => {
    throw new Error('serializer dependency must be overridden');
  },
};
globalThis.__historyMutation = {
  runPlaymeshProjectMutation: async ({ gameId, owner, operation }) =>
    operation({ gameId, owner, epoch: 1 }),
};
globalThis.__historyRestoreClient = {
  playmeshHistoryRestoreClient: {},
};
globalThis.__historyMaterializer = {
  materializePlaymeshHistoryTarget: async () => {
    throw new Error('materializer dependency must be overridden');
  },
};
globalThis.__historyJournal = {
  applyPlaymeshHistoryRestoreAtomically: async () => {},
  clearPlaymeshHistoryRestoreJournal: async () => {},
  createPlaymeshHistoryRestoreJournalRecord: ({
    transaction,
    fileIdentifier,
    oldBrowserEvidence,
  }) => ({
    schemaVersion: 1,
    gameId: transaction.gameId,
    txId: transaction.txId,
    idempotencyKey: transaction.idempotencyKey,
    fileIdentifier,
    phase: 'PREPARED_LOCAL',
    baseRevision: transaction.baseRevision,
    targetRevision: transaction.targetRevision,
    source: transaction.source,
    oldEvidence: transaction.oldEvidence,
    targetEvidence: transaction.targetEvidence,
    oldBrowserEvidence,
    createdAt: '2026-08-05T01:02:03.000Z',
    updatedAt: '2026-08-05T01:02:03.000Z',
  }),
  persistPreparedPlaymeshHistoryRestoreJournal: async journal => journal,
  readPlaymeshHistoryRestoreBrowserState: async () => ({
    project: null,
    journal: null,
  }),
};
globalThis.__historyEvidence = {
  assertPlaymeshHistoryBrowserEvidenceMatches(actual, expected) {
    assert.deepEqual(actual, expected);
  },
  computePlaymeshHistoryBrowserEvidence: async project => project.evidence,
  hashPlaymeshHistoryJson: async value => JSON.stringify(value),
};

let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreCoordinator.js'
  ),
  'utf8'
);
source = source
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryClient';/,
    `const {
  ensureKnownPlaymeshHistoryRevision,
  preparePlaymeshHistorySnapshot,
  toPlaymeshHistoryResourceDto,
  uploadMissingPlaymeshHistoryResources,
} = globalThis.__historyClient;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/ProjectsStorage\/PlaymeshLocalStorageProvider\/PlaymeshProjectSerializer';/,
    `const {
  createProjectSnapshot,
  createRestoredStoredProject,
} = globalThis.__historySerializer;`
  )
  .replace(
    /import \{ runPlaymeshProjectMutation \} from '\.\.\/PlaymeshProjectMutation\/PlaymeshProjectMutationCoordinator';/,
    'const { runPlaymeshProjectMutation } = globalThis.__historyMutation;'
  )
  .replace(
    /import \{ playmeshHistoryRestoreClient \} from '\.\/PlaymeshHistoryRestoreClient';/,
    'const { playmeshHistoryRestoreClient } = globalThis.__historyRestoreClient;'
  )
  .replace(
    /import \{ materializePlaymeshHistoryTarget \} from '\.\/PlaymeshHistoryRestoreMaterializer';/,
    'const { materializePlaymeshHistoryTarget } = globalThis.__historyMaterializer;'
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreJournal';/,
    `const {
  applyPlaymeshHistoryRestoreAtomically,
  clearPlaymeshHistoryRestoreJournal,
  createPlaymeshHistoryRestoreJournalRecord,
  persistPreparedPlaymeshHistoryRestoreJournal,
  readPlaymeshHistoryRestoreBrowserState,
} = globalThis.__historyJournal;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryEvidence';/,
    `const {
  assertPlaymeshHistoryBrowserEvidenceMatches,
  computePlaymeshHistoryBrowserEvidence,
  hashPlaymeshHistoryJson,
} = globalThis.__historyEvidence;`
  );
const coordinator = await importSource(transformFlow(source));

const gameId = 'com.playmesh.game.restore001';
const fileMetadata = {
  fileIdentifier: 'file-a',
  name: 'Current',
  gameId,
};
const oldEvidence = {
  projectFilesHash: '1'.repeat(64),
  resourceManifestHash: '2'.repeat(64),
};
const targetEvidence = {
  projectFilesHash: '3'.repeat(64),
  resourceManifestHash: '4'.repeat(64),
};
const projectConfigEvidence = {
  semantics: 'missing',
  status: 'missing',
};
const targetProject = { properties: { name: 'Target' } };
const targetProjectFiles = [
  { path: 'game.json', content: targetProject },
];
const targetResources = [];
const targetSnapshot = {
  sourceVersion: {
    id: 'version-4',
    gameId,
    revision: 4,
    timestamp: '2026-08-05T01:02:03.000Z',
    reason: 'explicit_save',
    contentHash: '5'.repeat(64),
    source: 'user',
    contentBytes: 1,
  },
  projectFilesReference: [
    { path: 'game.json', contentHash: '6'.repeat(64), size: 1 },
  ],
  projectFiles: targetProjectFiles,
  resources: targetResources,
  playmeshProjectConfig: null,
};
const baseTransaction = {
  txId: 'tx-a',
  gameId,
  idempotencyKey: 'restore.test',
  phase: 'PREPARED',
  baseRevision: 7,
  targetRevision: 4,
  source: 'user',
  oldEvidence: {
    history: {
      revision: 7,
      currentContentHash: '7'.repeat(64),
      ...oldEvidence,
    },
    config: projectConfigEvidence,
  },
  targetEvidence: {
    history: {
      revision: 8,
      currentContentHash: '8'.repeat(64),
      ...targetEvidence,
    },
    config: projectConfigEvidence,
  },
  createdAt: '2026-08-05T01:02:03.000Z',
  updatedAt: '2026-08-05T01:02:03.000Z',
  targetSnapshot,
};
const restoredSnapshot = {
  version: {
    ...targetSnapshot.sourceVersion,
    id: 'version-8',
    revision: 8,
  },
  projectFiles: targetProjectFiles,
  resources: targetResources,
  playmeshProjectConfig: null,
};
const committedTransaction = {
  ...baseTransaction,
  phase: 'BACKEND_COMMITTED',
  targetSnapshot: undefined,
  restored: restoredSnapshot,
};
const recoveryCommittedTransaction = {
  ...committedTransaction,
  targetSnapshot,
};
const acknowledgedTransaction = {
  ...committedTransaction,
  phase: 'BROWSER_PERSISTED',
  browserEvidence: targetEvidence,
};

const createScenario = () => {
  const order = [];
  let recoveryTransaction = recoveryCommittedTransaction;
  let browserProject = {
    id: fileMetadata.fileIdentifier,
    gameId,
    evidence: oldEvidence,
  };
  let journal = null;
  const restoreClient = {
    prepare: async request => {
      order.push('prepare-remote');
      assert.equal(request.idempotencyKey, 'restore.test');
      return { requestId: 'prepare', transaction: baseTransaction };
    },
    commit: async () => {
      order.push('commit');
      return { requestId: 'commit', transaction: committedTransaction };
    },
    acknowledge: async request => {
      order.push('ack');
      assert.deepEqual(request.browserEvidence, targetEvidence);
      return { requestId: 'ack', transaction: acknowledgedTransaction };
    },
    recover: async () => {
      order.push('recover');
      return {
        requestId: 'recover',
        transaction: recoveryTransaction,
        replayedEventTxIds: [],
      };
    },
    abort: async () => {
      order.push('abort');
      return {
        requestId: 'abort',
        transaction: { ...baseTransaction, phase: 'ABORTED' },
      };
    },
    status: async () => ({ requestId: 'status', transaction: baseTransaction }),
  };
  const dependencies = {
    snapshotFactory: async () => {
      order.push('snapshot');
      return {
        projectFiles: [
          {
            path: 'game.json',
            content: { browserEvidence: oldEvidence },
          },
        ],
        resources: [],
      };
    },
    prepareSnapshot: async snapshot => {
      order.push('prepare-local');
      return snapshot;
    },
    uploadResources: async () => order.push('upload'),
    resolveRevision: async () => {
      order.push('revision');
      return 7;
    },
    restoreClient,
    materializeTarget: async () => {
      order.push('materialize');
      return {
        projectFiles: [
          {
            path: 'game.json',
            content: { ...targetProject, browserEvidence: targetEvidence },
          },
        ],
        resources: [],
      };
    },
    createStoredProject: ({ fileMetadata: metadata, projectFiles }) => ({
      fileMetadata: { ...metadata, name: 'Target', lastModifiedDate: 2 },
      storedProject: {
        id: metadata.fileIdentifier,
        gameId: metadata.gameId,
        projectFiles,
        resources: [],
        evidence: projectFiles[0].content.browserEvidence,
      },
    }),
    computeBrowserEvidence: async project => {
      order.push(
        project.evidence === oldEvidence ? 'old-evidence' : 'target-evidence'
      );
      return project.evidence;
    },
    persistJournal: async value => {
      order.push('persist-journal');
      journal = value;
      return value;
    },
    applyAtomically: async ({ project, journal: value }) => {
      order.push('apply-idb');
      browserProject = project;
      journal = {
        ...value,
        phase: 'BROWSER_APPLIED_PENDING_ACK',
        browserEvidence: targetEvidence,
      };
      return journal;
    },
    readBrowserState: async () => {
      order.push('readback');
      return { project: browserProject, journal };
    },
    clearJournal: async () => {
      order.push('clear-journal');
      journal = null;
    },
    mutationRunner: async ({ operation }) => operation(),
    idempotencyKeyFactory: () => 'restore.test',
    reload: () => order.push('reload'),
    dispatchRestored: () => order.push('event'),
  };
  return {
    dependencies,
    order,
    restoreClient,
    getBrowserProject: () => browserProject,
    setBrowserProject: value => {
      browserProject = value;
    },
    getJournal: () => journal,
    setJournal: value => {
      journal = value;
    },
    setRecoveryTransaction: value => {
      recoveryTransaction = value;
    },
  };
};

const happy = createScenario();
const result = await coordinator.restorePlaymeshHistoryToLocalStore({
  gameId,
  targetRevision: 4,
  fileMetadata,
  project: {},
  dependencies: happy.dependencies,
});
assert.deepEqual(happy.order, [
  'snapshot',
  'prepare-local',
  'old-evidence',
  'upload',
  'revision',
  'prepare-remote',
  'materialize',
  'target-evidence',
  'persist-journal',
  'commit',
  'apply-idb',
  'readback',
  'target-evidence',
  'ack',
  'clear-journal',
  'event',
  'reload',
]);
assert.equal(result.fileMetadata.gameId, gameId);
assert.equal(happy.getJournal(), null);
assert.ok(happy.order.indexOf('ack') < happy.order.indexOf('clear-journal'));

const materializeFailure = createScenario();
materializeFailure.dependencies.materializeTarget = async () => {
  materializeFailure.order.push('materialize');
  throw new Error('materialize failed');
};
await assert.rejects(
  coordinator.restorePlaymeshHistoryToLocalStore({
    gameId,
    targetRevision: 4,
    fileMetadata,
    project: {},
    dependencies: materializeFailure.dependencies,
  }),
  /materialize failed/
);
assert.equal(materializeFailure.order.includes('abort'), true);
assert.equal(materializeFailure.order.includes('commit'), false);
assert.equal(materializeFailure.order.includes('apply-idb'), false);

const conflict = createScenario();
conflict.restoreClient.commit = async () => {
  conflict.order.push('commit');
  return {
    requestId: 'commit',
    transaction: {
      ...baseTransaction,
      phase: 'CONFLICT',
      targetSnapshot: undefined,
      conflict: {
        reason: 'changed',
        observedAt: '2026-08-05T01:02:03.000Z',
        current: { history: null, config: projectConfigEvidence },
      },
    },
  };
};
await assert.rejects(
  coordinator.restorePlaymeshHistoryToLocalStore({
    gameId,
    targetRevision: 4,
    fileMetadata,
    project: {},
    dependencies: conflict.dependencies,
  }),
  error => error && error.code === 'restore_conflict'
);
assert.equal(conflict.order.includes('apply-idb'), false);
assert.equal(conflict.order.includes('ack'), false);
assert.notEqual(conflict.getJournal(), null);

const thirdState = createScenario();
thirdState.setBrowserProject({
  id: fileMetadata.fileIdentifier,
  gameId,
  evidence: {
    projectFilesHash: 'a'.repeat(64),
    resourceManifestHash: 'b'.repeat(64),
  },
});
thirdState.setJournal({
  ...globalThis.__historyJournal.createPlaymeshHistoryRestoreJournalRecord({
    transaction: committedTransaction,
    fileIdentifier: fileMetadata.fileIdentifier,
    oldBrowserEvidence: oldEvidence,
  }),
  phase: 'BROWSER_APPLIED_PENDING_ACK',
  browserEvidence: targetEvidence,
});
await assert.rejects(
  coordinator.recoverPlaymeshHistoryRestoreToLocalStore({
    gameId,
    fileMetadata,
    dependencies: thirdState.dependencies,
  }),
  error => error && error.code === 'restore_browser_third_state'
);
assert.equal(thirdState.order.includes('ack'), false);
assert.equal(thirdState.order.includes('apply-idb'), false);

const pendingAck = createScenario();
pendingAck.setBrowserProject({
  id: fileMetadata.fileIdentifier,
  gameId,
  evidence: targetEvidence,
});
pendingAck.setJournal({
  ...globalThis.__historyJournal.createPlaymeshHistoryRestoreJournalRecord({
    transaction: committedTransaction,
    fileIdentifier: fileMetadata.fileIdentifier,
    oldBrowserEvidence: oldEvidence,
  }),
  phase: 'BROWSER_APPLIED_PENDING_ACK',
  browserEvidence: targetEvidence,
});
pendingAck.dependencies.materializeTarget = async () => {
  throw new Error('target browser state must not redownload resources');
};
const recoveryResult = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
  {
    gameId,
    fileMetadata,
    dependencies: pendingAck.dependencies,
  }
);
assert.equal(recoveryResult.status, 'completed');
assert.equal(pendingAck.order.includes('apply-idb'), false);
assert.ok(
  pendingAck.order.indexOf('ack') < pendingAck.order.indexOf('clear-journal')
);

const prepareResponseLoss = createScenario();
prepareResponseLoss.restoreClient.prepare = async () => {
  prepareResponseLoss.order.push('prepare-remote');
  throw new Error('prepare response lost');
};
prepareResponseLoss.setRecoveryTransaction(baseTransaction);
const recoveredPrepareLoss = await coordinator.restorePlaymeshHistoryToLocalStore({
  gameId,
  targetRevision: 4,
  fileMetadata,
  project: {},
  dependencies: prepareResponseLoss.dependencies,
});
assert.equal(recoveredPrepareLoss.fileMetadata.gameId, gameId);
assert.ok(
  prepareResponseLoss.order.indexOf('prepare-remote') <
    prepareResponseLoss.order.indexOf('recover')
);
assert.equal(prepareResponseLoss.order.includes('apply-idb'), true);
assert.equal(prepareResponseLoss.order.includes('ack'), true);
assert.equal(prepareResponseLoss.getJournal(), null);

const commitResponseLoss = createScenario();
commitResponseLoss.restoreClient.commit = async () => {
  commitResponseLoss.order.push('commit');
  throw new Error('commit response lost');
};
await assert.rejects(
  coordinator.restorePlaymeshHistoryToLocalStore({
    gameId,
    targetRevision: 4,
    fileMetadata,
    project: {},
    dependencies: commitResponseLoss.dependencies,
  }),
  /commit response lost/
);
assert.notEqual(commitResponseLoss.getJournal(), null);
assert.equal(commitResponseLoss.order.includes('abort'), false);
commitResponseLoss.restoreClient.commit = async () => {
  throw new Error('committed recovery must not replay commit');
};
const recoveredCommitLoss = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
  {
    gameId,
    fileMetadata,
    dependencies: commitResponseLoss.dependencies,
  }
);
assert.equal(recoveredCommitLoss.status, 'completed');
assert.equal(commitResponseLoss.getJournal(), null);

const browserPersistedRecoveryTransaction = {
  ...acknowledgedTransaction,
  targetSnapshot,
};
const acknowledgeResponseLoss = createScenario();
acknowledgeResponseLoss.restoreClient.acknowledge = async () => {
  acknowledgeResponseLoss.order.push('ack');
  throw new Error('ack response lost');
};
await assert.rejects(
  coordinator.restorePlaymeshHistoryToLocalStore({
    gameId,
    targetRevision: 4,
    fileMetadata,
    project: {},
    dependencies: acknowledgeResponseLoss.dependencies,
  }),
  /ack response lost/
);
assert.notEqual(acknowledgeResponseLoss.getJournal(), null);
assert.deepEqual(
  acknowledgeResponseLoss.getBrowserProject().evidence,
  targetEvidence
);
acknowledgeResponseLoss.setRecoveryTransaction(
  browserPersistedRecoveryTransaction
);
acknowledgeResponseLoss.restoreClient.acknowledge = async () => {
  throw new Error('persisted recovery must not replay acknowledge');
};
const recoveredAcknowledgeLoss = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
  {
    gameId,
    fileMetadata,
    dependencies: acknowledgeResponseLoss.dependencies,
  }
);
assert.equal(recoveredAcknowledgeLoss.status, 'completed');
assert.equal(acknowledgeResponseLoss.getJournal(), null);
assert.equal(
  acknowledgeResponseLoss.order.filter(item => item === 'apply-idb').length,
  1
);

for (const intermediatePhase of ['COMMIT_REQUESTED', 'HISTORY_APPLIED']) {
  const intermediate = createScenario();
  let recoverCalls = 0;
  intermediate.restoreClient.recover = async () => {
    intermediate.order.push('recover');
    recoverCalls++;
    return {
      requestId: `recover-${recoverCalls}`,
      transaction:
        recoverCalls === 1
          ? {
              ...baseTransaction,
              phase: intermediatePhase,
            }
          : recoveryCommittedTransaction,
      replayedEventTxIds: [],
    };
  };
  const recoveredIntermediate = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
    {
      gameId,
      fileMetadata,
      dependencies: intermediate.dependencies,
    }
  );
  assert.equal(recoveredIntermediate.status, 'completed');
  assert.equal(recoverCalls, 2);
  assert.equal(intermediate.order.includes('apply-idb'), true);
}

const persistedWithoutJournal = createScenario();
persistedWithoutJournal.setBrowserProject({
  id: fileMetadata.fileIdentifier,
  gameId,
  evidence: targetEvidence,
});
persistedWithoutJournal.setRecoveryTransaction(
  browserPersistedRecoveryTransaction
);
persistedWithoutJournal.dependencies.materializeTarget = async () => {
  throw new Error('persisted target must not materialize');
};
const recoveredAfterJournalClear = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
  {
    gameId,
    fileMetadata,
    dependencies: persistedWithoutJournal.dependencies,
  }
);
assert.equal(recoveredAfterJournalClear.status, 'completed');
assert.equal(persistedWithoutJournal.order.includes('ack'), false);
assert.equal(persistedWithoutJournal.order.includes('clear-journal'), false);
assert.equal(persistedWithoutJournal.order.includes('event'), true);
assert.equal(persistedWithoutJournal.order.includes('reload'), true);

for (const partialTargetEvidence of [
  {
    projectFilesHash: targetEvidence.projectFilesHash,
    resourceManifestHash: 'd'.repeat(64),
  },
  {
    projectFilesHash: 'e'.repeat(64),
    resourceManifestHash: targetEvidence.resourceManifestHash,
  },
]) {
  const partialTarget = createScenario();
  partialTarget.setBrowserProject({
    id: fileMetadata.fileIdentifier,
    gameId,
    evidence: partialTargetEvidence,
  });
  partialTarget.setJournal({
    ...globalThis.__historyJournal.createPlaymeshHistoryRestoreJournalRecord({
      transaction: committedTransaction,
      fileIdentifier: fileMetadata.fileIdentifier,
      oldBrowserEvidence: oldEvidence,
    }),
    phase: 'BROWSER_APPLIED_PENDING_ACK',
    browserEvidence: targetEvidence,
  });
  await assert.rejects(
    coordinator.recoverPlaymeshHistoryRestoreToLocalStore({
      gameId,
      fileMetadata,
      dependencies: partialTarget.dependencies,
    }),
    error => error && error.code === 'restore_browser_third_state'
  );
  assert.notEqual(partialTarget.getJournal(), null);
  assert.equal(partialTarget.order.includes('ack'), false);
  assert.equal(partialTarget.order.includes('materialize'), false);
}

const preparedTarget = createScenario();
preparedTarget.setRecoveryTransaction(baseTransaction);
preparedTarget.setBrowserProject({
  id: fileMetadata.fileIdentifier,
  gameId,
  evidence: targetEvidence,
});
const recoveredPreparedTarget = await coordinator.recoverPlaymeshHistoryRestoreToLocalStore(
  {
    gameId,
    fileMetadata,
    dependencies: preparedTarget.dependencies,
  }
);
assert.equal(recoveredPreparedTarget.status, 'completed');
assert.equal(preparedTarget.order.includes('materialize'), true);
assert.equal(preparedTarget.order.includes('commit'), true);
assert.equal(preparedTarget.order.includes('apply-idb'), true);

process.stdout.write('GDevelop history restore coordinator tests passed.\n');
