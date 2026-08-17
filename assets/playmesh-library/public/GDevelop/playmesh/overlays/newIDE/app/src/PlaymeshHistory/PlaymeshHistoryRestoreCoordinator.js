// @flow

import {
  ensureKnownPlaymeshHistoryRevision,
  preparePlaymeshHistorySnapshot,
  toPlaymeshHistoryResourceDto,
  uploadMissingPlaymeshHistoryResources,
} from './PlaymeshHistoryClient';
import type {
  PlaymeshHistoryRestoreResult,
  PlaymeshHistorySnapshotInput,
  PreparedPlaymeshHistoryResource,
} from './PlaymeshHistoryClient';
import {
  createProjectSnapshot,
  createRestoredStoredProject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
import { runPlaymeshProjectMutation } from '../PlaymeshProjectMutation/PlaymeshProjectMutationCoordinator';
import type { FileMetadata } from '../ProjectsStorage';
import type {
  StoredProject,
  StoredProjectResource,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import { playmeshHistoryRestoreClient } from './PlaymeshHistoryRestoreClient';
import type { PlaymeshHistoryRestoreClient } from './PlaymeshHistoryRestoreClient';
import { materializePlaymeshHistoryTarget } from './PlaymeshHistoryRestoreMaterializer';
import type { PlaymeshHistoryMaterializedTarget } from './PlaymeshHistoryRestoreMaterializer';
import {
  applyPlaymeshHistoryRestoreAtomically,
  clearPlaymeshHistoryRestoreJournal,
  createPlaymeshHistoryRestoreJournalRecord,
  persistPreparedPlaymeshHistoryRestoreJournal,
  readPlaymeshHistoryRestoreBrowserState,
} from './PlaymeshHistoryRestoreJournal';
import type { PlaymeshHistoryRestoreJournalRecord } from './PlaymeshHistoryRestoreJournal';
import {
  assertPlaymeshHistoryBrowserEvidenceMatches,
  computePlaymeshHistoryBrowserEvidence,
  hashPlaymeshHistoryJson,
} from './PlaymeshHistoryEvidence';
import type {
  PlaymeshHistoryRestoreBrowserEvidence,
  PlaymeshHistoryRestoreHistoryEvidence,
  PlaymeshHistoryRestoreSource,
  PlaymeshHistoryRestoreTargetSnapshot,
  PlaymeshHistoryRestoreTransaction,
} from './PlaymeshHistoryRestoreProtocol';

/*::
type PlaymeshProjectMutationLease = $ReadOnly<{|
  gameId: string,
  owner: string,
  epoch: number,
|}>;
type PlaymeshHistorySnapshotFactory = (
  project: gdProject,
  fileMetadata: FileMetadata
) => Promise<PlaymeshHistorySnapshotInput>;
type PlaymeshHistoryMutationRunner = <T>({|
  gameId: string,
  owner: string,
  operation: (PlaymeshProjectMutationLease) => Promise<T>,
|}) => Promise<T>;
type PlaymeshHistoryStoredProjectResult = {|
  fileMetadata: FileMetadata,
  storedProject: StoredProject,
|};
type PlaymeshHistoryRestoreDependencies = {|
  snapshotFactory: PlaymeshHistorySnapshotFactory,
  prepareSnapshot: typeof preparePlaymeshHistorySnapshot,
  uploadResources: typeof uploadMissingPlaymeshHistoryResources,
  resolveRevision: typeof ensureKnownPlaymeshHistoryRevision,
  restoreClient: PlaymeshHistoryRestoreClient,
  materializeTarget: typeof materializePlaymeshHistoryTarget,
  createStoredProject: typeof createRestoredStoredProject,
  computeBrowserEvidence: typeof computePlaymeshHistoryBrowserEvidence,
  persistJournal: typeof persistPreparedPlaymeshHistoryRestoreJournal,
  applyAtomically: typeof applyPlaymeshHistoryRestoreAtomically,
  readBrowserState: typeof readPlaymeshHistoryRestoreBrowserState,
  clearJournal: typeof clearPlaymeshHistoryRestoreJournal,
  mutationRunner: PlaymeshHistoryMutationRunner,
  idempotencyKeyFactory: () => string,
  reload: () => void,
  dispatchRestored: (PlaymeshHistoryRestoreTransaction) => void,
|};
type PlaymeshHistoryRestoreCoordinatorOptions = {|
  gameId: string,
  targetRevision: number,
  fileMetadata: FileMetadata,
  project: gdProject,
  source?: PlaymeshHistoryRestoreSource,
  signal?: AbortSignal,
  dependencies?: Partial<PlaymeshHistoryRestoreDependencies>,
|};
type PlaymeshHistoryRestoreRecoveryOptions = {|
  gameId: string,
  fileMetadata: FileMetadata,
  signal?: AbortSignal,
  dependencies?: Partial<PlaymeshHistoryRestoreDependencies>,
|};
export type PlaymeshHistoryRestoreCoordinatorResult = {|
  restored: PlaymeshHistoryRestoreResult,
  fileMetadata: FileMetadata,
|};
export type PlaymeshHistoryRestoreRecoveryResult =
  | {| status: 'idle' |}
  | {|
      status: 'completed',
      transaction: PlaymeshHistoryRestoreTransaction,
      fileMetadata: FileMetadata,
    |};
export type PlaymeshHistoryBrowserClassification =
  | 'old'
  | 'target'
  | 'third';
*/

const RESTORED_EVENT_RECEIPTS_KEY =
  'playmesh.gdevelop.history.restored-event-tx-ids.v1';
const MAX_EVENT_RECEIPTS = 128;
const dispatchedEventTxIds: Set<string> = new Set();

export class PlaymeshHistoryRestoreCoordinatorError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshHistoryRestoreCoordinatorError';
    this.code = code;
  }
}

const fail = (code /*: string */, message /*: string */) /*: empty */ => {
  throw new PlaymeshHistoryRestoreCoordinatorError(code, message);
};

const createIdempotencyKey = () /*: string */ => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return `restore.${window.crypto.randomUUID()}`;
  }
  return `restore.${Date.now().toString(36)}.${Math.random()
    .toString(36)
    .slice(2)}`;
};

const readEventReceipts = () /*: Array<string> */ => {
  try {
    const value = window.sessionStorage.getItem(RESTORED_EVENT_RECEIPTS_KEY);
    if (!value) return [];
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed
          .filter(item => typeof item === 'string')
          .slice(-MAX_EVENT_RECEIPTS)
      : [];
  } catch (_) {
    return [];
  }
};

const dispatchRestoredEvent = (
  transaction /*: PlaymeshHistoryRestoreTransaction */
) /*: void */ => {
  const persistedReceipts = readEventReceipts();
  if (
    dispatchedEventTxIds.has(transaction.txId) ||
    persistedReceipts.includes(transaction.txId)
  ) {
    return;
  }
  dispatchedEventTxIds.add(transaction.txId);
  try {
    window.sessionStorage.setItem(
      RESTORED_EVENT_RECEIPTS_KEY,
      JSON.stringify(
        [...persistedReceipts, transaction.txId].slice(-MAX_EVENT_RECEIPTS)
      )
    );
  } catch (_) {}
  window.dispatchEvent(
    new CustomEvent('gdevelop.history.restored', {
      detail: {
        gameId: transaction.gameId,
        txId: transaction.txId,
        targetRevision: transaction.targetRevision,
        restoredRevision: transaction.targetEvidence.history.revision,
      },
    })
  );
};

const defaultDependencies = () /*: PlaymeshHistoryRestoreDependencies */ => ({
  snapshotFactory: createProjectSnapshot,
  prepareSnapshot: preparePlaymeshHistorySnapshot,
  uploadResources: uploadMissingPlaymeshHistoryResources,
  resolveRevision: ensureKnownPlaymeshHistoryRevision,
  restoreClient: playmeshHistoryRestoreClient,
  materializeTarget: materializePlaymeshHistoryTarget,
  createStoredProject: createRestoredStoredProject,
  computeBrowserEvidence: computePlaymeshHistoryBrowserEvidence,
  persistJournal: persistPreparedPlaymeshHistoryRestoreJournal,
  applyAtomically: applyPlaymeshHistoryRestoreAtomically,
  readBrowserState: readPlaymeshHistoryRestoreBrowserState,
  clearJournal: clearPlaymeshHistoryRestoreJournal,
  mutationRunner: runPlaymeshProjectMutation,
  idempotencyKeyFactory: createIdempotencyKey,
  reload: () => window.location.reload(),
  dispatchRestored: dispatchRestoredEvent,
});

const resolveDependencies = (
  overrides /*: ?Partial<PlaymeshHistoryRestoreDependencies> */
) /*: PlaymeshHistoryRestoreDependencies */ => ({
  ...defaultDependencies(),
  ...(overrides || {}),
});

export const toPlaymeshHistoryBrowserEvidence = (
  historyEvidence /*: PlaymeshHistoryRestoreHistoryEvidence */
) /*: PlaymeshHistoryRestoreBrowserEvidence */ => ({
  projectJsonHash: historyEvidence.projectJsonHash,
  resourceManifestHash: historyEvidence.resourceManifestHash,
});

const sameBrowserEvidence = (
  left /*: PlaymeshHistoryRestoreBrowserEvidence */,
  right /*: PlaymeshHistoryRestoreBrowserEvidence */
) /*: boolean */ =>
  left.projectJsonHash === right.projectJsonHash &&
  left.resourceManifestHash === right.resourceManifestHash;

export const classifyPlaymeshHistoryBrowserEvidence = (
  actual /*: PlaymeshHistoryRestoreBrowserEvidence */,
  oldEvidence /*: PlaymeshHistoryRestoreBrowserEvidence */,
  targetEvidence /*: PlaymeshHistoryRestoreBrowserEvidence */
) /*: PlaymeshHistoryBrowserClassification */ => {
  if (sameBrowserEvidence(actual, oldEvidence)) return 'old';
  if (sameBrowserEvidence(actual, targetEvidence)) return 'target';
  return 'third';
};

const preparedResourceToStored = (
  resource /*: PreparedPlaymeshHistoryResource */
) /*: StoredProjectResource */ => {
  const storedResource /*: StoredProjectResource */ = {
    logicalUrl: resource.logicalId,
    blob: resource.blob,
    contentHash: resource.contentHash,
  };
  if (resource.name !== undefined) storedResource.name = resource.name;
  if (resource.metadata !== undefined) {
    storedResource.metadata = resource.metadata;
  }
  return storedResource;
};

const assertTransactionIdentity = (
  expected /*: PlaymeshHistoryRestoreTransaction */,
  actual /*: PlaymeshHistoryRestoreTransaction */
) /*: void */ => {
  if (
    actual.txId !== expected.txId ||
    actual.gameId !== expected.gameId ||
    actual.idempotencyKey !== expected.idempotencyKey ||
    actual.baseRevision !== expected.baseRevision ||
    actual.targetRevision !== expected.targetRevision ||
    actual.source !== expected.source ||
    JSON.stringify(actual.oldEvidence) !==
      JSON.stringify(expected.oldEvidence) ||
    JSON.stringify(actual.targetEvidence) !==
      JSON.stringify(expected.targetEvidence)
  ) {
    return fail(
      'restore_transaction_changed',
      'Playmesh 历史恢复事务在执行期间发生了变化。'
    );
  }
};

const assertRestoredMatchesTarget = async (
  transaction /*: PlaymeshHistoryRestoreTransaction */,
  targetSnapshot /*: PlaymeshHistoryRestoreTargetSnapshot */
) /*: Promise<void> */ => {
  const restored = transaction.restored;
  if (!restored) {
    return fail(
      'restore_snapshot_missing',
      'Playmesh 历史恢复提交缺少已恢复快照。'
    );
  }
  if (
    (await hashPlaymeshHistoryJson(restored.project)) !==
      (await hashPlaymeshHistoryJson(targetSnapshot.project)) ||
    (await hashPlaymeshHistoryJson(restored.resources)) !==
      (await hashPlaymeshHistoryJson(targetSnapshot.resources))
  ) {
    return fail(
      'restore_snapshot_changed',
      'Playmesh 历史恢复提交结果与不可变目标快照不一致。'
    );
  }
};

const requireBackendCommitted = (
  transaction /*: PlaymeshHistoryRestoreTransaction */
) /*: void */ => {
  if (transaction.phase === 'CONFLICT') {
    return fail('restore_conflict', 'Playmesh 历史恢复发生冲突。');
  }
  if (transaction.phase !== 'BACKEND_COMMITTED') {
    return fail(
      'restore_not_committed',
      `Playmesh 历史恢复尚未提交（${transaction.phase}）。`
    );
  }
};

const createTargetStoredProject = (
  dependencies /*: PlaymeshHistoryRestoreDependencies */,
  fileMetadata /*: FileMetadata */,
  gameId /*: string */,
  materialized /*: PlaymeshHistoryMaterializedTarget */
) /*: PlaymeshHistoryStoredProjectResult */ =>
  dependencies.createStoredProject({
    fileMetadata: { ...fileMetadata, gameId },
    project: materialized.project,
    resources: materialized.resources,
  });

const finalizeCommittedRestore = async (
  {
    dependencies,
    preparedTransaction,
    committedTransaction,
    targetSnapshot,
    materialized,
    storedProjectResult,
    journal,
    signal,
  } /*: {|
    dependencies: PlaymeshHistoryRestoreDependencies,
    preparedTransaction: PlaymeshHistoryRestoreTransaction,
    committedTransaction: PlaymeshHistoryRestoreTransaction,
    targetSnapshot: PlaymeshHistoryRestoreTargetSnapshot,
    materialized: PlaymeshHistoryMaterializedTarget,
    storedProjectResult: PlaymeshHistoryStoredProjectResult,
    journal: PlaymeshHistoryRestoreJournalRecord,
    signal?: AbortSignal,
  |} */
) /*: Promise<PlaymeshHistoryRestoreCoordinatorResult> */ => {
  assertTransactionIdentity(preparedTransaction, committedTransaction);
  requireBackendCommitted(committedTransaction);
  await assertRestoredMatchesTarget(committedTransaction, targetSnapshot);
  if (journal.phase === 'PREPARED_LOCAL') {
    await dependencies.applyAtomically({
      project: storedProjectResult.storedProject,
      journal,
    });
  }
  const browserState = await dependencies.readBrowserState({
    gameId: committedTransaction.gameId,
    fileIdentifier: storedProjectResult.fileMetadata.fileIdentifier,
  });
  if (!browserState.project || !browserState.journal) {
    return fail(
      'restore_readback_missing',
      'Playmesh 历史恢复的浏览器写入无法读回。'
    );
  }
  const browserEvidence = await dependencies.computeBrowserEvidence(
    browserState.project
  );
  assertPlaymeshHistoryBrowserEvidenceMatches(
    browserEvidence,
    toPlaymeshHistoryBrowserEvidence(
      committedTransaction.targetEvidence.history
    )
  );
  const acknowledged = await dependencies.restoreClient.acknowledge({
    gameId: committedTransaction.gameId,
    txId: committedTransaction.txId,
    browserEvidence,
    signal,
  });
  assertTransactionIdentity(committedTransaction, acknowledged.transaction);
  if (acknowledged.transaction.phase !== 'BROWSER_PERSISTED') {
    if (acknowledged.transaction.phase === 'CONFLICT') {
      return fail('restore_ack_conflict', 'Playmesh 历史恢复确认发生冲突。');
    }
    return fail(
      'restore_ack_incomplete',
      'Playmesh 历史恢复尚未完成浏览器确认。'
    );
  }
  await dependencies.clearJournal({
    gameId: committedTransaction.gameId,
    txId: committedTransaction.txId,
  });
  dependencies.dispatchRestored(acknowledged.transaction);
  dependencies.reload();
  const restored = committedTransaction.restored;
  if (!restored) {
    return fail(
      'restore_snapshot_missing',
      'Playmesh 历史恢复提交缺少已恢复快照。'
    );
  }
  return {
    restored: {
      version: restored.version,
      project: materialized.project,
      resources: materialized.resources,
      backupVersion: committedTransaction.backupVersion || null,
    },
    fileMetadata: storedProjectResult.fileMetadata,
  };
};

const abortPreparedBestEffort = async (
  client /*: PlaymeshHistoryRestoreClient */,
  transaction /*: PlaymeshHistoryRestoreTransaction */,
  signal /*: ?AbortSignal */
) /*: Promise<void> */ => {
  try {
    await client.abort({
      gameId: transaction.gameId,
      txId: transaction.txId,
      ...(signal ? { signal } : {}),
    });
  } catch (_) {}
};

const acknowledgeRecoveredBrowserTarget = async (
  {
    dependencies,
    transaction,
    targetSnapshot,
    browserEvidence,
    hasJournal,
    fileMetadata,
    signal,
  } /*: {|
    dependencies: PlaymeshHistoryRestoreDependencies,
    transaction: PlaymeshHistoryRestoreTransaction,
    targetSnapshot: PlaymeshHistoryRestoreTargetSnapshot,
    browserEvidence: PlaymeshHistoryRestoreBrowserEvidence,
    hasJournal: boolean,
    fileMetadata: FileMetadata,
    signal?: AbortSignal,
  |} */
) /*: Promise<PlaymeshHistoryRestoreRecoveryResult> */ => {
  requireBackendCommitted(transaction);
  await assertRestoredMatchesTarget(transaction, targetSnapshot);
  const acknowledged = await dependencies.restoreClient.acknowledge({
    gameId: transaction.gameId,
    txId: transaction.txId,
    browserEvidence,
    signal,
  });
  assertTransactionIdentity(transaction, acknowledged.transaction);
  if (acknowledged.transaction.phase !== 'BROWSER_PERSISTED') {
    if (acknowledged.transaction.phase === 'CONFLICT') {
      return fail('restore_ack_conflict', 'Playmesh 历史恢复确认发生冲突。');
    }
    return fail(
      'restore_ack_incomplete',
      'Playmesh 历史恢复尚未完成浏览器确认。'
    );
  }
  if (hasJournal) {
    await dependencies.clearJournal({
      gameId: transaction.gameId,
      txId: transaction.txId,
    });
  }
  dependencies.dispatchRestored(acknowledged.transaction);
  dependencies.reload();
  return {
    status: 'completed',
    transaction: acknowledged.transaction,
    fileMetadata,
  };
};

export const restorePlaymeshHistoryToLocalStore = async (
  {
    gameId,
    targetRevision,
    fileMetadata,
    project,
    source = 'user',
    signal,
    dependencies: dependencyOverrides,
  } /*: PlaymeshHistoryRestoreCoordinatorOptions */
) /*: Promise<PlaymeshHistoryRestoreCoordinatorResult> */ => {
  const dependencies = resolveDependencies(dependencyOverrides);
  return dependencies.mutationRunner({
    gameId,
    owner: 'history-restore',
    operation: async () => {
      const currentSnapshot = await dependencies.snapshotFactory(
        project,
        fileMetadata
      );
      const preparedCurrent = await dependencies.prepareSnapshot(
        currentSnapshot
      );
      const currentStoredProject = dependencies.createStoredProject({
        fileMetadata: { ...fileMetadata, gameId },
        project: preparedCurrent.project,
        resources: preparedCurrent.resources.map(preparedResourceToStored),
      }).storedProject;
      const oldBrowserEvidence = await dependencies.computeBrowserEvidence(
        currentStoredProject
      );
      await dependencies.uploadResources(
        gameId,
        preparedCurrent.resources,
        signal
      );
      const baseRevision = await dependencies.resolveRevision(gameId, signal);
      const preparedEnvelope = await dependencies.restoreClient.prepare({
        gameId,
        idempotencyKey: dependencies.idempotencyKeyFactory(),
        baseRevision,
        targetRevision,
        source,
        currentProject: preparedCurrent.project,
        currentResources: preparedCurrent.resources.map(
          toPlaymeshHistoryResourceDto
        ),
        signal,
      });
      const preparedTransaction = preparedEnvelope.transaction;
      const targetSnapshot = preparedTransaction.targetSnapshot;
      if (preparedTransaction.phase !== 'PREPARED' || !targetSnapshot) {
        return fail(
          'restore_prepare_incomplete',
          'Playmesh 历史恢复 PREPARE 响应不完整。'
        );
      }
      try {
        assertPlaymeshHistoryBrowserEvidenceMatches(
          oldBrowserEvidence,
          toPlaymeshHistoryBrowserEvidence(
            preparedTransaction.oldEvidence.history
          )
        );
        const materialized = await dependencies.materializeTarget({
          gameId,
          targetRevision,
          targetSnapshot,
          signal,
        });
        const storedProjectResult = createTargetStoredProject(
          dependencies,
          fileMetadata,
          gameId,
          materialized
        );
        const targetBrowserEvidence = await dependencies.computeBrowserEvidence(
          storedProjectResult.storedProject
        );
        assertPlaymeshHistoryBrowserEvidenceMatches(
          targetBrowserEvidence,
          toPlaymeshHistoryBrowserEvidence(
            preparedTransaction.targetEvidence.history
          )
        );
        const journal = createPlaymeshHistoryRestoreJournalRecord({
          transaction: preparedTransaction,
          fileIdentifier: fileMetadata.fileIdentifier,
          oldBrowserEvidence,
        });
        await dependencies.persistJournal(journal);
        const committedEnvelope = await dependencies.restoreClient.commit({
          gameId,
          txId: preparedTransaction.txId,
          signal,
        });
        return finalizeCommittedRestore({
          dependencies,
          preparedTransaction,
          committedTransaction: committedEnvelope.transaction,
          targetSnapshot,
          materialized,
          storedProjectResult,
          journal,
          signal,
        });
      } catch (error) {
        const browserState = await dependencies.readBrowserState({
          gameId,
          fileIdentifier: fileMetadata.fileIdentifier,
        });
        if (!browserState.journal) {
          await abortPreparedBestEffort(
            dependencies.restoreClient,
            preparedTransaction,
            signal
          );
        }
        throw error;
      }
    },
  });
};

export const recoverPlaymeshHistoryRestoreToLocalStore = async (
  {
    gameId,
    fileMetadata,
    signal,
    dependencies: dependencyOverrides,
  } /*: PlaymeshHistoryRestoreRecoveryOptions */
) /*: Promise<PlaymeshHistoryRestoreRecoveryResult> */ => {
  const dependencies = resolveDependencies(dependencyOverrides);
  return dependencies.mutationRunner({
    gameId,
    owner: 'history-restore-recovery',
    operation: async () => {
      let recovery = await dependencies.restoreClient.recover({
        gameId,
        signal,
      });
      const recoveredTransaction = recovery.transaction;
      if (!recoveredTransaction) return { status: 'idle' };
      let transaction /*: PlaymeshHistoryRestoreTransaction */ = recoveredTransaction;
      if (transaction.phase === 'CONFLICT' || transaction.phase === 'ABORTED') {
        return fail(
          'restore_recovery_terminal',
          `Playmesh 历史恢复无法继续（${transaction.phase}）。`
        );
      }
      const targetSnapshot = transaction.targetSnapshot;
      if (!targetSnapshot) {
        return fail(
          'restore_snapshot_missing',
          'Playmesh 历史恢复缺少不可变目标快照。'
        );
      }
      const browserState = await dependencies.readBrowserState({
        gameId,
        fileIdentifier: fileMetadata.fileIdentifier,
      });
      if (!browserState.project) {
        return fail(
          'restore_browser_project_missing',
          'Playmesh 历史恢复找不到浏览器项目。'
        );
      }
      if (
        browserState.journal &&
        browserState.journal.txId !== transaction.txId
      ) {
        return fail(
          'restore_journal_transaction_mismatch',
          'Playmesh 历史恢复日志与后端事务不匹配。'
        );
      }
      const actualEvidence = await dependencies.computeBrowserEvidence(
        browserState.project
      );
      const oldEvidence = toPlaymeshHistoryBrowserEvidence(
        transaction.oldEvidence.history
      );
      const targetEvidence = toPlaymeshHistoryBrowserEvidence(
        transaction.targetEvidence.history
      );
      const classification = classifyPlaymeshHistoryBrowserEvidence(
        actualEvidence,
        oldEvidence,
        targetEvidence
      );
      if (classification === 'third') {
        return fail(
          'restore_browser_third_state',
          '浏览器项目既不是恢复前状态，也不是恢复目标状态。'
        );
      }
      if (transaction.phase === 'BROWSER_PERSISTED') {
        if (classification !== 'target') {
          return fail(
            'restore_browser_evidence_mismatch',
            '浏览器项目与已确认的恢复结果不一致。'
          );
        }
        if (browserState.journal) {
          await dependencies.clearJournal({ gameId, txId: transaction.txId });
        }
        dependencies.dispatchRestored(transaction);
        dependencies.reload();
        return {
          status: 'completed',
          transaction,
          fileMetadata,
        };
      }
      if (
        transaction.phase === 'BACKEND_COMMITTED' &&
        classification === 'target'
      ) {
        return acknowledgeRecoveredBrowserTarget({
          dependencies,
          transaction,
          targetSnapshot,
          browserEvidence: actualEvidence,
          hasJournal: !!browserState.journal,
          fileMetadata,
          signal,
        });
      }
      const materialized = await dependencies.materializeTarget({
        gameId,
        targetRevision: transaction.targetRevision,
        targetSnapshot,
        signal,
      });
      const storedProjectResult = createTargetStoredProject(
        dependencies,
        fileMetadata,
        gameId,
        materialized
      );
      let journal = browserState.journal;
      if (!journal) {
        journal = createPlaymeshHistoryRestoreJournalRecord({
          transaction,
          fileIdentifier: fileMetadata.fileIdentifier,
          oldBrowserEvidence: oldEvidence,
        });
        await dependencies.persistJournal(journal);
      }
      if (transaction.phase === 'PREPARED') {
        const committed = await dependencies.restoreClient.commit({
          gameId,
          txId: transaction.txId,
          signal,
        });
        assertTransactionIdentity(transaction, committed.transaction);
        transaction = committed.transaction;
      } else if (
        transaction.phase === 'COMMIT_REQUESTED' ||
        transaction.phase === 'HISTORY_APPLIED'
      ) {
        recovery = await dependencies.restoreClient.recover({ gameId, signal });
        const continuedTransaction = recovery.transaction;
        if (!continuedTransaction) {
          return fail(
            'restore_recovery_lost',
            'Playmesh 历史恢复事务在恢复过程中丢失。'
          );
        }
        assertTransactionIdentity(transaction, continuedTransaction);
        transaction = continuedTransaction;
      }
      requireBackendCommitted(transaction);
      const result = await finalizeCommittedRestore({
        dependencies,
        preparedTransaction: transaction,
        committedTransaction: transaction,
        targetSnapshot,
        materialized,
        storedProjectResult,
        journal,
        signal,
      });
      return {
        status: 'completed',
        transaction,
        fileMetadata: result.fileMetadata,
      };
    },
  });
};
