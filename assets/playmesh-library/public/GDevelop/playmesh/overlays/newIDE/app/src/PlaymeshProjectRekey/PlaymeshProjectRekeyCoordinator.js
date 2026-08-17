// @flow

import type { FileMetadata } from '../ProjectsStorage';
import {
  mirrorPreparedProject,
  type PreparedPlaymeshProjectPersistence,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
import { getPlaymeshHistoryCurrent } from '../PlaymeshHistory/PlaymeshHistoryClient';
import {
  hashPlaymeshHistoryBytes,
  hashPlaymeshHistoryJson,
} from '../PlaymeshHistory/PlaymeshHistoryEvidence';
import { PlaymeshProjectConfigClient } from '../PlaymeshProjectConfig/PlaymeshProjectConfigClient';
import type { PlaymeshProjectConfigReadResponse } from '../PlaymeshProjectConfig/PlaymeshProjectConfigProtocol';
import { runPlaymeshProjectMutation } from '../PlaymeshProjectMutation/PlaymeshProjectMutationCoordinator';
import {
  playmeshProjectRekeyClient,
  type PlaymeshProjectRekeyClient,
  type PlaymeshProjectRekeyPrepareInput,
} from './PlaymeshProjectRekeyClient';
import type {
  PlaymeshProjectRekeyConfigEvidence,
  PlaymeshProjectRekeyExpectedEvidence,
  PlaymeshProjectRekeyTransaction,
} from './PlaymeshProjectRekeyProtocol';
import {
  applyPlaymeshProjectRekeyTargetAtomically,
  classifyPlaymeshProjectRekeyBrowserState,
  clearPlaymeshProjectRekeyJournal,
  createPlaymeshProjectRekeyBrowserEvidence,
  createPlaymeshProjectRekeyJournalRecord,
  persistPreparedPlaymeshProjectRekeyJournal,
  readPlaymeshProjectRekeyBrowserState,
  restorePlaymeshProjectRekeySourceAtomically,
} from './PlaymeshProjectRekeyJournal';
import type {
  PlaymeshProjectRekeyBrowserState,
  PlaymeshProjectRekeyJournalRecord,
} from './PlaymeshProjectRekeyJournal';

/*::
export type PlaymeshProjectRekeyOutcome = 'committed' | 'rolled_back' | 'idle';
export type PlaymeshProjectRekeyStage =
  | 'persisting_source'
  | 'preparing'
  | 'committing'
  | 'switching_browser'
  | 'acknowledging'
  | 'recovering'
  | 'rolling_back';
export type PlaymeshProjectRekeyCoordinatorResult = {|
  outcome: PlaymeshProjectRekeyOutcome,
  fileMetadata: FileMetadata,
  transaction?: PlaymeshProjectRekeyTransaction,
|};
export type PlaymeshProjectRekeyDependencies = {|
  client: PlaymeshProjectRekeyClient,
  getHistoryCurrent: typeof getPlaymeshHistoryCurrent,
  readConfig: ({| gameId: string, signal?: ?AbortSignal |}) => Promise<PlaymeshProjectConfigReadResponse>,
  mirrorSource: PreparedPlaymeshProjectPersistence => Promise<void>,
  hashJson: mixed => Promise<string>,
  hashBytes: ArrayBuffer => Promise<string>,
  mutationRunner: typeof runPlaymeshProjectMutation,
  createJournal: typeof createPlaymeshProjectRekeyJournalRecord,
  persistJournal: typeof persistPreparedPlaymeshProjectRekeyJournal,
  applyTarget: typeof applyPlaymeshProjectRekeyTargetAtomically,
  restoreSource: typeof restorePlaymeshProjectRekeySourceAtomically,
  readBrowserState: typeof readPlaymeshProjectRekeyBrowserState,
  classifyBrowserState: typeof classifyPlaymeshProjectRekeyBrowserState,
  browserEvidence: typeof createPlaymeshProjectRekeyBrowserEvidence,
  clearJournal: typeof clearPlaymeshProjectRekeyJournal,
  idempotencyKeyFactory: () => string,
  clientIdFactory: () => string,
  notify: PlaymeshProjectRekeyStage => void,
|};
export type PlaymeshProjectRekeyCoordinatorOptions = {|
  oldGameId: string,
  newGameId: string,
  source: PreparedPlaymeshProjectPersistence,
  target: PreparedPlaymeshProjectPersistence,
  signal?: ?AbortSignal,
  dependencies?: Partial<PlaymeshProjectRekeyDependencies>,
|};
export type PlaymeshProjectRekeyRecoveryOptions = {|
  fileMetadata: FileMetadata,
  signal?: ?AbortSignal,
  dependencies?: Partial<PlaymeshProjectRekeyDependencies>,
|};
type PlaymeshProjectRekeyClassifiedBrowserState = {|
  state: PlaymeshProjectRekeyBrowserState,
  classification: 'source' | 'target' | 'third',
|};
*/

let sequence = 0;

export class PlaymeshProjectRekeyCoordinatorError extends Error {
  /*::
  code: string;
  rollbackCompleted: boolean;
  blocked: boolean;
  cause: mixed;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    {
      rollbackCompleted = false,
      blocked = false,
      cause = null,
    } /*: {|
      rollbackCompleted?: boolean,
      blocked?: boolean,
      cause?: mixed,
    |} */ = {}
  ) {
    super(message);
    this.name = 'PlaymeshProjectRekeyCoordinatorError';
    this.code = code;
    this.rollbackCompleted = rollbackCompleted;
    this.blocked = blocked;
    this.cause = cause;
  }
}

const fail = (
  code /*: string */,
  message /*: string */,
  options /*: {|
    rollbackCompleted?: boolean,
    blocked?: boolean,
    cause?: mixed,
  |} */ = {}
) /*: empty */ => {
  throw new PlaymeshProjectRekeyCoordinatorError(code, message, options);
};

const defaultId = (prefix /*: string */) /*: string */ => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return `${prefix}-${window.crypto.randomUUID()}`;
  }
  sequence += 1;
  return `${prefix}-${Date.now().toString(36)}-${sequence.toString(36)}`;
};

const defaultDependencies /*: PlaymeshProjectRekeyDependencies */ = {
  client: playmeshProjectRekeyClient,
  getHistoryCurrent: getPlaymeshHistoryCurrent,
  readConfig: options => new PlaymeshProjectConfigClient().read(options),
  mirrorSource: mirrorPreparedProject,
  hashJson: hashPlaymeshHistoryJson,
  hashBytes: hashPlaymeshHistoryBytes,
  mutationRunner: runPlaymeshProjectMutation,
  createJournal: createPlaymeshProjectRekeyJournalRecord,
  persistJournal: persistPreparedPlaymeshProjectRekeyJournal,
  applyTarget: applyPlaymeshProjectRekeyTargetAtomically,
  restoreSource: restorePlaymeshProjectRekeySourceAtomically,
  readBrowserState: readPlaymeshProjectRekeyBrowserState,
  classifyBrowserState: classifyPlaymeshProjectRekeyBrowserState,
  browserEvidence: createPlaymeshProjectRekeyBrowserEvidence,
  clearJournal: clearPlaymeshProjectRekeyJournal,
  idempotencyKeyFactory: () => defaultId('rekey'),
  clientIdFactory: () => defaultId('gdevelop-webide'),
  notify: () => {},
};

const resolveDependencies = (
  overrides /*: ?Partial<PlaymeshProjectRekeyDependencies> */
) /*: PlaymeshProjectRekeyDependencies */ => ({
  ...defaultDependencies,
  ...(overrides || {}),
});

const buildPlaymeshProjectRekeyExpectedOldEvidenceWithDependencies = async (
  {
    oldGameId,
    signal,
    dependencies,
  } /*: {|
  oldGameId: string,
  signal?: ?AbortSignal,
  dependencies: PlaymeshProjectRekeyDependencies,
|} */
) /*: Promise<PlaymeshProjectRekeyExpectedEvidence> */ => {
  const [history, config] = await Promise.all([
    dependencies.getHistoryCurrent(oldGameId, signal || undefined),
    dependencies.readConfig({ gameId: oldGameId, signal }),
  ]);
  if (history.gameId !== oldGameId || !history.current) {
    return fail(
      'history_current_missing',
      'Playmesh 项目尚无可用于身份迁移的本地历史基线。'
    );
  }
  const current = history.current;
  let configEvidence /*: PlaymeshProjectRekeyConfigEvidence */;
  if (config.status === 'ready') {
    const readyConfig = config.config;
    const configJson = JSON.stringify(readyConfig);
    if (typeof configJson !== 'string') {
      return fail(
        'project_config_invalid',
        'Playmesh 项目配置无法生成稳定校验值。'
      );
    }
    configEvidence = {
      status: 'ready',
      revision: readyConfig.revision,
      contentHash: await dependencies.hashBytes(
        new TextEncoder().encode(configJson).buffer
      ),
      config: readyConfig,
    };
  } else if (config.status === 'missing') {
    configEvidence = { status: 'missing' };
  } else {
    return fail(
      'project_config_invalid',
      'Playmesh 项目配置已损坏，无法安全迁移项目身份。'
    );
  }
  return {
    history: {
      revision: current.version.revision,
      currentContentHash: current.version.contentHash,
      projectJsonHash: await dependencies.hashJson(current.project),
      resourceManifestHash: await dependencies.hashJson(current.resources),
    },
    config: configEvidence,
  };
};

export const buildPlaymeshProjectRekeyExpectedOldEvidence = async (
  {
    oldGameId,
    signal,
    dependencies: dependencyOverrides,
  } /*: {|
  oldGameId: string,
  signal?: ?AbortSignal,
  dependencies?: Partial<PlaymeshProjectRekeyDependencies>,
|} */
) /*: Promise<PlaymeshProjectRekeyExpectedEvidence> */ =>
  buildPlaymeshProjectRekeyExpectedOldEvidenceWithDependencies({
    oldGameId,
    signal,
    dependencies: resolveDependencies(dependencyOverrides),
  });

const assertPreparedIdentity = (
  prepared /*: PreparedPlaymeshProjectPersistence */,
  expectedGameId /*: string */,
  expectedFileIdentifier /*: string */
) /*: void */ => {
  if (
    prepared.fileMetadata.fileIdentifier !== expectedFileIdentifier ||
    prepared.storedProject.id !== expectedFileIdentifier ||
    prepared.fileMetadata.gameId !== expectedGameId ||
    prepared.storedProject.gameId !== expectedGameId
  ) {
    return fail(
      'prepared_identity_mismatch',
      'Playmesh 项目身份迁移的浏览器快照身份不一致。'
    );
  }
};

const assertTransactionIdentity = (
  transaction /*: PlaymeshProjectRekeyTransaction */,
  journal /*: PlaymeshProjectRekeyJournalRecord */
) /*: void */ => {
  if (
    transaction.txId !== journal.txId ||
    transaction.idempotencyKey !== journal.idempotencyKey ||
    transaction.oldGameId !== journal.oldGameId ||
    transaction.newGameId !== journal.newGameId ||
    transaction.browserSource.fileIdentifier !== journal.fileIdentifier ||
    transaction.browserTarget.fileIdentifier !== journal.fileIdentifier ||
    transaction.browserSource.projectJsonHash !==
      journal.sourceEvidence.projectJsonHash ||
    transaction.browserTarget.projectJsonHash !==
      journal.targetEvidence.projectJsonHash
  ) {
    return fail(
      'transaction_identity_mismatch',
      'Playmesh 项目身份迁移日志与后端事务不一致。',
      { blocked: true }
    );
  }
};

const statusAfterFailure = async (
  dependencies /*: PlaymeshProjectRekeyDependencies */,
  journal /*: PlaymeshProjectRekeyJournalRecord */,
  signal /*: ?AbortSignal */
) /*: Promise<PlaymeshProjectRekeyTransaction> */ => {
  try {
    const envelope = await dependencies.client.status({
      oldGameId: journal.oldGameId,
      txId: journal.txId,
      signal,
    });
    assertTransactionIdentity(envelope.transaction, journal);
    return envelope.transaction;
  } catch (statusError) {
    try {
      const recovery = await dependencies.client.recover({
        oldGameId: journal.oldGameId,
        signal,
      });
      const transaction = recovery.transaction;
      if (!transaction) throw statusError;
      assertTransactionIdentity(transaction, journal);
      return transaction;
    } catch (recoveryError) {
      return fail(
        'transaction_status_uncertain',
        '无法确认项目身份迁移是否越过提交点；本地状态已锁定，请恢复连接后重试。',
        { blocked: true, cause: recoveryError }
      );
    }
  }
};

const readAndClassify = async (
  dependencies /*: PlaymeshProjectRekeyDependencies */,
  journal /*: PlaymeshProjectRekeyJournalRecord */
) /*: Promise<PlaymeshProjectRekeyClassifiedBrowserState> */ => {
  const state = await dependencies.readBrowserState(journal.fileIdentifier);
  if (!state.project || !state.journal) {
    return fail(
      'browser_state_missing',
      'Playmesh 项目身份迁移本地日志或项目快照缺失。',
      { blocked: true }
    );
  }
  if (state.journal.txId !== journal.txId) {
    return fail(
      'browser_journal_mismatch',
      'Playmesh 项目身份迁移本地日志已被其他事务替换。',
      { blocked: true }
    );
  }
  return {
    state,
    classification: await dependencies.classifyBrowserState(
      state.project,
      state.journal
    ),
  };
};

const completeCommitted = async (
  dependencies /*: PlaymeshProjectRekeyDependencies */,
  journal /*: PlaymeshProjectRekeyJournalRecord */,
  transaction /*: PlaymeshProjectRekeyTransaction */
) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ => {
  assertTransactionIdentity(transaction, journal);
  if (transaction.phase !== 'OLD_CLEANED') {
    return fail(
      'logical_commit_incomplete',
      'Playmesh 项目身份迁移尚未越过逻辑提交点。',
      { blocked: true }
    );
  }
  const { classification } = await readAndClassify(dependencies, journal);
  if (classification !== 'target') {
    return fail(
      'committed_browser_mismatch',
      '后端已完成项目身份迁移，但浏览器项目不是目标状态。',
      { blocked: true }
    );
  }
  await dependencies.clearJournal({
    fileIdentifier: journal.fileIdentifier,
    txId: journal.txId,
  });
  return {
    outcome: 'committed',
    fileMetadata: {
      fileIdentifier: journal.fileIdentifier,
      name: journal.targetProject.name,
      gameId: journal.newGameId,
      lastModifiedDate: journal.targetProject.savedAt,
    },
    transaction,
  };
};

const ensureSourceAndFinishRollback = async (
  dependencies /*: PlaymeshProjectRekeyDependencies */,
  journalValue /*: PlaymeshProjectRekeyJournalRecord */,
  transactionValue /*: PlaymeshProjectRekeyTransaction */,
  signal /*: ?AbortSignal */
) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ => {
  let journal = journalValue;
  let transaction = transactionValue;
  dependencies.notify('rolling_back');
  assertTransactionIdentity(transaction, journal);
  if (transaction.phase === 'OLD_CLEANED') {
    return completeCommitted(dependencies, journal, transaction);
  }
  if (transaction.phase === 'CONFLICT') {
    return fail(
      'backend_conflict',
      'Playmesh 项目身份迁移发生证据冲突；为避免覆盖数据，本地状态保持锁定。',
      { blocked: true }
    );
  }

  const browser = await readAndClassify(dependencies, journal);
  if (browser.classification === 'third') {
    return fail(
      'browser_third_state',
      '浏览器项目既不是迁移前状态，也不是迁移目标状态。',
      { blocked: true }
    );
  }
  if (
    browser.classification === 'target' ||
    journal.phase !== 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK'
  ) {
    try {
      journal = await dependencies.restoreSource({ journal });
    } catch (error) {
      return fail(
        'browser_source_restore_failed',
        '无法原子恢复迁移前浏览器项目；后端回滚保持待确认状态，请重试恢复。',
        { blocked: true, cause: error }
      );
    }
  }

  if (transaction.phase === 'PREPARED') {
    try {
      transaction = (await dependencies.client.abort({
        oldGameId: journal.oldGameId,
        txId: journal.txId,
        signal,
      })).transaction;
    } catch (_) {
      transaction = await statusAfterFailure(dependencies, journal, signal);
    }
  } else if (
    transaction.phase !== 'ROLLED_BACK' &&
    transaction.phase !== 'ABORTED'
  ) {
    const browserEvidence = dependencies.browserEvidence(journal, 'source');
    try {
      transaction = (await dependencies.client.rollback({
        oldGameId: journal.oldGameId,
        txId: journal.txId,
        browserEvidence,
        signal,
      })).transaction;
    } catch (_) {
      transaction = await statusAfterFailure(dependencies, journal, signal);
    }
  }
  assertTransactionIdentity(transaction, journal);
  if (transaction.phase === 'OLD_CLEANED') {
    return completeCommitted(dependencies, journal, transaction);
  }
  if (transaction.phase !== 'ROLLED_BACK' && transaction.phase !== 'ABORTED') {
    return fail(
      'rollback_incomplete',
      '项目身份迁移回滚尚未完成；本地源状态已保留，请重试恢复。',
      { blocked: true }
    );
  }
  await dependencies.clearJournal({
    fileIdentifier: journal.fileIdentifier,
    txId: journal.txId,
  });
  return {
    outcome: 'rolled_back',
    fileMetadata: {
      fileIdentifier: journal.fileIdentifier,
      name: journal.sourceProject.name,
      gameId: journal.oldGameId,
      lastModifiedDate: journal.sourceProject.savedAt,
    },
    transaction,
  };
};

const settleAfterTargetAck = async (
  dependencies /*: PlaymeshProjectRekeyDependencies */,
  journal /*: PlaymeshProjectRekeyJournalRecord */,
  transactionValue /*: PlaymeshProjectRekeyTransaction */,
  signal /*: ?AbortSignal */
) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ => {
  let transaction = transactionValue;
  assertTransactionIdentity(transaction, journal);
  if (transaction.phase === 'OLD_CLEANED') {
    return completeCommitted(dependencies, journal, transaction);
  }
  if (transaction.phase === 'BROWSER_UPDATED') {
    try {
      const recovery = await dependencies.client.recover({
        oldGameId: journal.oldGameId,
        signal,
      });
      if (!recovery.transaction) {
        return fail(
          'transaction_recovery_missing',
          'Playmesh 项目身份迁移恢复响应缺少事务。',
          { blocked: true }
        );
      }
      transaction = recovery.transaction;
      assertTransactionIdentity(transaction, journal);
      if (transaction.phase === 'OLD_CLEANED') {
        return completeCommitted(dependencies, journal, transaction);
      }
    } catch (_) {
      transaction = await statusAfterFailure(dependencies, journal, signal);
      if (transaction.phase === 'OLD_CLEANED') {
        return completeCommitted(dependencies, journal, transaction);
      }
    }
  }
  return ensureSourceAndFinishRollback(
    dependencies,
    journal,
    transaction,
    signal
  );
};

export const rekeyPlaymeshProjectLocalIdentity = async (
  {
    oldGameId,
    newGameId,
    source,
    target,
    signal,
    dependencies: dependencyOverrides,
  } /*: PlaymeshProjectRekeyCoordinatorOptions */
) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ => {
  const dependencies = resolveDependencies(dependencyOverrides);
  return dependencies.mutationRunner({
    gameId: oldGameId,
    owner: 'project-rekey',
    operation: async () => {
      const fileIdentifier = source.fileMetadata.fileIdentifier;
      assertPreparedIdentity(source, oldGameId, fileIdentifier);
      assertPreparedIdentity(target, newGameId, fileIdentifier);
      dependencies.notify('persisting_source');
      await dependencies.mirrorSource(source);
      dependencies.notify('preparing');
      const [sourceHash, targetHash, expectedOldEvidence] = await Promise.all([
        dependencies.hashJson(JSON.parse(source.storedProject.projectJson)),
        dependencies.hashJson(JSON.parse(target.storedProject.projectJson)),
        buildPlaymeshProjectRekeyExpectedOldEvidenceWithDependencies({
          oldGameId,
          signal,
          dependencies,
        }),
      ]);
      const prepareInput /*: PlaymeshProjectRekeyPrepareInput */ = {
        oldGameId,
        newGameId,
        idempotencyKey: dependencies.idempotencyKeyFactory(),
        expectedOldEvidence,
        browserSource: { fileIdentifier, projectJsonHash: sourceHash },
        browserTarget: { fileIdentifier, projectJsonHash: targetHash },
        clientId: dependencies.clientIdFactory(),
        signal,
      };
      let preparedEnvelope;
      try {
        preparedEnvelope = await dependencies.client.prepare(prepareInput);
      } catch (firstError) {
        // PREPARE 响应丢失时只能用同一幂等键重放，不能生成第二个事务。
        try {
          preparedEnvelope = await dependencies.client.prepare(prepareInput);
        } catch (secondError) {
          return fail(
            'prepare_unavailable',
            '无法确认项目身份迁移 PREPARE 是否成功。',
            { rollbackCompleted: true, cause: secondError }
          );
        }
      }
      const prepared = preparedEnvelope.transaction;
      if (
        prepared.phase !== 'PREPARED' ||
        prepared.oldGameId !== oldGameId ||
        prepared.newGameId !== newGameId
      ) {
        return fail(
          'prepare_incomplete',
          'Playmesh 项目身份迁移 PREPARE 响应不完整。',
          { blocked: prepared.phase === 'CONFLICT' }
        );
      }
      let journal;
      try {
        journal = await dependencies.createJournal({
          transaction: prepared,
          sourceProject: source.storedProject,
          targetProject: target.storedProject,
        });
        await dependencies.persistJournal(journal);
      } catch (error) {
        // 没有耐久浏览器日志就绝不能进入 COMMIT。尽力终止 PREPARED；
        // 即使终止响应丢失，本地源项目仍未切换，后端也只能等待过期清理。
        try {
          await dependencies.client.abort({
            oldGameId,
            txId: prepared.txId,
            signal,
          });
        } catch (_) {}
        return fail(
          'browser_journal_persist_failed',
          '无法保存项目身份迁移日志，迁移已在提交前停止。',
          { rollbackCompleted: true, cause: error }
        );
      }
      let transaction;
      dependencies.notify('committing');
      try {
        transaction = (await dependencies.client.commit({
          oldGameId,
          txId: prepared.txId,
          signal,
        })).transaction;
      } catch (_) {
        transaction = await statusAfterFailure(dependencies, journal, signal);
      }
      assertTransactionIdentity(transaction, journal);
      if (transaction.phase === 'OLD_CLEANED') {
        return completeCommitted(dependencies, journal, transaction);
      }
      if (
        transaction.phase !== 'NEW_PUBLISHED' &&
        transaction.phase !== 'BROWSER_UPDATED'
      ) {
        const rolledBack = await ensureSourceAndFinishRollback(
          dependencies,
          journal,
          transaction,
          signal
        );
        return fail(
          'commit_not_published',
          '项目身份迁移未能发布目标状态，已恢复迁移前项目。',
          { rollbackCompleted: rolledBack.outcome === 'rolled_back' }
        );
      }
      dependencies.notify('switching_browser');
      try {
        journal = await dependencies.applyTarget({ journal });
      } catch (error) {
        const current = await statusAfterFailure(dependencies, journal, signal);
        const rolledBack = await ensureSourceAndFinishRollback(
          dependencies,
          journal,
          current,
          signal
        );
        return fail(
          'browser_target_write_failed',
          '浏览器项目身份切换失败，已恢复迁移前项目。',
          {
            rollbackCompleted: rolledBack.outcome === 'rolled_back',
            cause: error,
          }
        );
      }
      const browserEvidence = dependencies.browserEvidence(journal, 'target');
      dependencies.notify('acknowledging');
      try {
        transaction = (await dependencies.client.acknowledge({
          oldGameId,
          txId: journal.txId,
          browserEvidence,
          signal,
        })).transaction;
      } catch (_) {
        transaction = await statusAfterFailure(dependencies, journal, signal);
      }
      return settleAfterTargetAck(dependencies, journal, transaction, signal);
    },
  });
};

export const recoverPlaymeshProjectRekeyLocalIdentity = async (
  {
    fileMetadata,
    signal,
    dependencies: dependencyOverrides,
  } /*: PlaymeshProjectRekeyRecoveryOptions */
) /*: Promise<PlaymeshProjectRekeyCoordinatorResult> */ => {
  const dependencies = resolveDependencies(dependencyOverrides);
  const browserState = await dependencies.readBrowserState(
    fileMetadata.fileIdentifier
  );
  const journal = browserState.journal;
  if (!journal) {
    const oldGameId = fileMetadata.gameId;
    if (!oldGameId) return { outcome: 'idle', fileMetadata };
    const recovery = await dependencies.client.recover({ oldGameId, signal });
    if (!recovery.transaction) return { outcome: 'idle', fileMetadata };
    if (recovery.transaction.phase === 'PREPARED') {
      await dependencies.client.abort({
        oldGameId,
        txId: recovery.transaction.txId,
        signal,
      });
      return { outcome: 'idle', fileMetadata };
    }
    if (
      recovery.transaction.phase === 'ROLLED_BACK' ||
      recovery.transaction.phase === 'ABORTED'
    ) {
      return { outcome: 'idle', fileMetadata };
    }
    return fail(
      'backend_transaction_without_browser_journal',
      '发现无浏览器日志的项目身份迁移事务；为避免覆盖数据，已停止自动恢复。',
      { blocked: true }
    );
  }
  return dependencies.mutationRunner({
    gameId: journal.oldGameId,
    owner: 'project-rekey-recovery',
    operation: async () => {
      dependencies.notify('recovering');
      let transaction;
      try {
        const recovery = await dependencies.client.recover({
          oldGameId: journal.oldGameId,
          signal,
        });
        if (!recovery.transaction) {
          return fail(
            'backend_transaction_missing',
            'Playmesh 项目身份迁移后端事务已丢失。',
            { blocked: true }
          );
        }
        transaction = recovery.transaction;
      } catch (_) {
        transaction = await statusAfterFailure(dependencies, journal, signal);
      }
      assertTransactionIdentity(transaction, journal);
      if (transaction.phase === 'OLD_CLEANED') {
        return completeCommitted(dependencies, journal, transaction);
      }
      return ensureSourceAndFinishRollback(
        dependencies,
        journal,
        transaction,
        signal
      );
    },
  });
};
