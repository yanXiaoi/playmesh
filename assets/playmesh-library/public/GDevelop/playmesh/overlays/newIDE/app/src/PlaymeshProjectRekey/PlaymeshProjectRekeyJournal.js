// @flow

import {
  assertStoredProject,
  getStoredProject,
  putStoredProject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import type { StoredProject } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import {
  assertPlaymeshProjectRekeyBrowserTarget,
  assertPlaymeshProjectRekeyTransaction,
  validatePlaymeshProjectRekeyToken,
} from './PlaymeshProjectRekeyProtocol';
import type {
  PlaymeshProjectRekeyBrowserEvidence,
  PlaymeshProjectRekeyBrowserTarget,
  PlaymeshProjectRekeyTransaction,
} from './PlaymeshProjectRekeyProtocol';
import {
  assertPlaymeshHistoryBrowserEvidenceMatches,
  computePlaymeshHistoryBrowserEvidence,
} from '../PlaymeshHistory/PlaymeshHistoryEvidence';
import type { PlaymeshHistoryRestoreBrowserEvidence } from '../PlaymeshHistory/PlaymeshHistoryRestoreProtocol';
import { validatePlaymeshProjectConfigGameId } from '../PlaymeshProjectConfig/PlaymeshProjectConfigProtocol';

/*::
export type PlaymeshProjectRekeyJournalPhase =
  | 'PREPARED_LOCAL'
  | 'TARGET_APPLIED_PENDING_ACK'
  | 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK';
export type PlaymeshProjectRekeyJournalRecord = {|
  schemaVersion: 1,
  fileIdentifier: string,
  txId: string,
  idempotencyKey: string,
  oldGameId: string,
  newGameId: string,
  phase: PlaymeshProjectRekeyJournalPhase,
  browserSource: PlaymeshProjectRekeyBrowserTarget,
  browserTarget: PlaymeshProjectRekeyBrowserTarget,
  sourceEvidence: PlaymeshHistoryRestoreBrowserEvidence,
  targetEvidence: PlaymeshHistoryRestoreBrowserEvidence,
  sourceProject: StoredProject,
  targetProject: StoredProject,
  createdAt: string,
  updatedAt: string,
|};
export type PlaymeshProjectRekeyBrowserState = {|
  project: ?StoredProject,
  journal: ?PlaymeshProjectRekeyJournalRecord,
|};
export type PlaymeshProjectRekeyBrowserClassification =
  | 'source'
  | 'target'
  | 'third';
type MixedRecord = { +[string]: mixed };
*/

const JOURNAL_SCHEMA_VERSION = 1;

export class PlaymeshProjectRekeyJournalError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshProjectRekeyJournalError';
    this.code = code;
  }
}

const fail = (code /*: string */, message /*: string */) /*: empty */ => {
  throw new PlaymeshProjectRekeyJournalError(code, message);
};

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const hasExactKeys = (
  record /*: MixedRecord */,
  expected /*: $ReadOnlyArray<string> */
) /*: boolean */ => {
  const actual = Object.keys(record);
  return (
    actual.length === expected.length &&
    actual.every(key => expected.includes(key))
  );
};

const requireTimestamp = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  return value;
};

const requirePhase = (
  value /*: mixed */
) /*: PlaymeshProjectRekeyJournalPhase */ => {
  if (
    value !== 'PREPARED_LOCAL' &&
    value !== 'TARGET_APPLIED_PENDING_ACK' &&
    value !== 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK'
  ) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  return value;
};

const assertLocalEvidence = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreBrowserEvidence */ => {
  const evidence = asRecord(value);
  if (
    !evidence ||
    !hasExactKeys(evidence, ['projectJsonHash', 'resourceManifestHash']) ||
    typeof evidence.projectJsonHash !== 'string' ||
    !/^[a-f0-9]{64}$/.test(evidence.projectJsonHash) ||
    typeof evidence.resourceManifestHash !== 'string' ||
    !/^[a-f0-9]{64}$/.test(evidence.resourceManifestHash)
  ) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  return {
    projectJsonHash: evidence.projectJsonHash,
    resourceManifestHash: evidence.resourceManifestHash,
  };
};

export const assertPlaymeshProjectRekeyJournalRecord = (
  value /*: mixed */
) /*: PlaymeshProjectRekeyJournalRecord */ => {
  const journal = asRecord(value);
  const keys = [
    'schemaVersion',
    'fileIdentifier',
    'txId',
    'idempotencyKey',
    'oldGameId',
    'newGameId',
    'phase',
    'browserSource',
    'browserTarget',
    'sourceEvidence',
    'targetEvidence',
    'sourceProject',
    'targetProject',
    'createdAt',
    'updatedAt',
  ];
  if (
    !journal ||
    journal.schemaVersion !== JOURNAL_SCHEMA_VERSION ||
    !hasExactKeys(journal, keys)
  ) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  const fileIdentifier = validatePlaymeshProjectRekeyToken(
    journal.fileIdentifier
  );
  const oldGameId = validatePlaymeshProjectConfigGameId(journal.oldGameId);
  const newGameId = validatePlaymeshProjectConfigGameId(journal.newGameId);
  if (oldGameId === newGameId) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  const browserSource = assertPlaymeshProjectRekeyBrowserTarget(
    journal.browserSource
  );
  const browserTarget = assertPlaymeshProjectRekeyBrowserTarget(
    journal.browserTarget
  );
  const sourceProject = assertStoredProject(journal.sourceProject);
  const targetProject = assertStoredProject(journal.targetProject);
  if (
    browserSource.fileIdentifier !== fileIdentifier ||
    browserTarget.fileIdentifier !== fileIdentifier ||
    sourceProject.id !== fileIdentifier ||
    targetProject.id !== fileIdentifier ||
    sourceProject.gameId !== oldGameId ||
    targetProject.gameId !== newGameId
  ) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  const sourceEvidence = assertLocalEvidence(journal.sourceEvidence);
  const targetEvidence = assertLocalEvidence(journal.targetEvidence);
  if (
    sourceEvidence.projectJsonHash !== browserSource.projectJsonHash ||
    targetEvidence.projectJsonHash !== browserTarget.projectJsonHash
  ) {
    return fail('journal_corrupt', 'Playmesh 项目身份迁移日志无效。');
  }
  return {
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    fileIdentifier,
    txId: validatePlaymeshProjectRekeyToken(journal.txId),
    idempotencyKey: validatePlaymeshProjectRekeyToken(journal.idempotencyKey),
    oldGameId,
    newGameId,
    phase: requirePhase(journal.phase),
    browserSource,
    browserTarget,
    sourceEvidence,
    targetEvidence,
    sourceProject,
    targetProject,
    createdAt: requireTimestamp(journal.createdAt),
    updatedAt: requireTimestamp(journal.updatedAt),
  };
};

// App 的 rekey transaction 持久化于项目目录；浏览器状态只服务当前页面。
const sessionRekeyJournals = new Map<
  string,
  PlaymeshProjectRekeyJournalRecord
>();

export const createPlaymeshProjectRekeyJournalRecord = async (
  {
    transaction: transactionValue,
    sourceProject: sourceProjectValue,
    targetProject: targetProjectValue,
    now = new Date().toISOString(),
  } /*: {|
  transaction: PlaymeshProjectRekeyTransaction,
  sourceProject: StoredProject,
  targetProject: StoredProject,
  now?: string,
|} */
) /*: Promise<PlaymeshProjectRekeyJournalRecord> */ => {
  const transaction = assertPlaymeshProjectRekeyTransaction(
    transactionValue,
    transactionValue.oldGameId
  );
  if (transaction.phase !== 'PREPARED') {
    return fail(
      'invalid_journal_transition',
      '只能从 PREPARED 创建 Playmesh 项目身份迁移日志。'
    );
  }
  const sourceProject = assertStoredProject(sourceProjectValue);
  const targetProject = assertStoredProject(targetProjectValue);
  const [sourceEvidence, targetEvidence] = await Promise.all([
    computePlaymeshHistoryBrowserEvidence(sourceProject),
    computePlaymeshHistoryBrowserEvidence(targetProject),
  ]);
  if (
    sourceEvidence.projectJsonHash !==
      transaction.browserSource.projectJsonHash ||
    targetEvidence.projectJsonHash !== transaction.browserTarget.projectJsonHash
  ) {
    return fail(
      'browser_target_mismatch',
      'Playmesh 项目身份迁移本地快照与 PREPARE 目标不一致。'
    );
  }
  return assertPlaymeshProjectRekeyJournalRecord({
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    fileIdentifier: transaction.browserSource.fileIdentifier,
    txId: transaction.txId,
    idempotencyKey: transaction.idempotencyKey,
    oldGameId: transaction.oldGameId,
    newGameId: transaction.newGameId,
    phase: 'PREPARED_LOCAL',
    browserSource: transaction.browserSource,
    browserTarget: transaction.browserTarget,
    sourceEvidence,
    targetEvidence,
    sourceProject,
    targetProject,
    createdAt: now,
    updatedAt: now,
  });
};

export const persistPreparedPlaymeshProjectRekeyJournal = async (
  journalValue /*: PlaymeshProjectRekeyJournalRecord */
) /*: Promise<PlaymeshProjectRekeyJournalRecord> */ => {
  const journal = assertPlaymeshProjectRekeyJournalRecord(journalValue);
  if (journal.phase !== 'PREPARED_LOCAL') {
    return fail(
      'invalid_journal_transition',
      '只能持久化 PREPARED_LOCAL 项目身份迁移日志。'
    );
  }
  const currentValue =
    sessionRekeyJournals.get(journal.fileIdentifier) || null;
  if (currentValue !== undefined && currentValue !== null) {
    const current = assertPlaymeshProjectRekeyJournalRecord(currentValue);
    if (current.txId !== journal.txId) {
      return fail(
        'journal_project_locked',
        '当前本地项目已有未完成的身份迁移。'
      );
    }
  }
  sessionRekeyJournals.set(journal.fileIdentifier, journal);
  return journal;
};

const writeProjectAndJournalAtomically = async (
  project /*: StoredProject */,
  journal /*: PlaymeshProjectRekeyJournalRecord */
) /*: Promise<void> */ => {
  await putStoredProject(project);
  sessionRekeyJournals.set(journal.fileIdentifier, journal);
};

export const applyPlaymeshProjectRekeyTargetAtomically = async (
  {
    journal: journalValue,
    now = new Date().toISOString(),
  } /*: {|
  journal: PlaymeshProjectRekeyJournalRecord,
  now?: string,
|} */
) /*: Promise<PlaymeshProjectRekeyJournalRecord> */ => {
  const journal = assertPlaymeshProjectRekeyJournalRecord(journalValue);
  if (journal.phase !== 'PREPARED_LOCAL') {
    return fail(
      'invalid_journal_transition',
      'Playmesh 项目身份迁移目标写入状态无效。'
    );
  }
  const evidence = await computePlaymeshHistoryBrowserEvidence(
    journal.targetProject
  );
  assertPlaymeshHistoryBrowserEvidenceMatches(evidence, journal.targetEvidence);
  const updated = assertPlaymeshProjectRekeyJournalRecord({
    ...journal,
    phase: 'TARGET_APPLIED_PENDING_ACK',
    updatedAt: now,
  });
  await writeProjectAndJournalAtomically(journal.targetProject, updated);
  return updated;
};

export const restorePlaymeshProjectRekeySourceAtomically = async (
  {
    journal: journalValue,
    now = new Date().toISOString(),
  } /*: {|
  journal: PlaymeshProjectRekeyJournalRecord,
  now?: string,
|} */
) /*: Promise<PlaymeshProjectRekeyJournalRecord> */ => {
  const journal = assertPlaymeshProjectRekeyJournalRecord(journalValue);
  if (journal.phase === 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK') return journal;
  const evidence = await computePlaymeshHistoryBrowserEvidence(
    journal.sourceProject
  );
  assertPlaymeshHistoryBrowserEvidenceMatches(evidence, journal.sourceEvidence);
  const updated = assertPlaymeshProjectRekeyJournalRecord({
    ...journal,
    phase: 'SOURCE_RESTORED_PENDING_ROLLBACK_ACK',
    updatedAt: now,
  });
  await writeProjectAndJournalAtomically(journal.sourceProject, updated);
  return updated;
};

export const readPlaymeshProjectRekeyBrowserState = async (
  fileIdentifierValue /*: mixed */
) /*: Promise<PlaymeshProjectRekeyBrowserState> */ => {
  const fileIdentifier = validatePlaymeshProjectRekeyToken(fileIdentifierValue);
  const projectValue = await getStoredProject(fileIdentifier);
  const journalValue = sessionRekeyJournals.get(fileIdentifier) || null;
  return {
    project:
      projectValue === undefined || projectValue === null
        ? null
        : assertStoredProject(projectValue),
    journal:
      journalValue === undefined || journalValue === null
        ? null
        : assertPlaymeshProjectRekeyJournalRecord(journalValue),
  };
};

export const classifyPlaymeshProjectRekeyBrowserState = async (
  project /*: StoredProject */,
  journalValue /*: PlaymeshProjectRekeyJournalRecord */
) /*: Promise<PlaymeshProjectRekeyBrowserClassification> */ => {
  const journal = assertPlaymeshProjectRekeyJournalRecord(journalValue);
  const evidence = await computePlaymeshHistoryBrowserEvidence(project);
  const matches = (
    expected /*: PlaymeshHistoryRestoreBrowserEvidence */
  ) /*: boolean */ =>
    evidence.projectJsonHash === expected.projectJsonHash &&
    evidence.resourceManifestHash === expected.resourceManifestHash;
  if (project.gameId === journal.oldGameId && matches(journal.sourceEvidence)) {
    return 'source';
  }
  if (project.gameId === journal.newGameId && matches(journal.targetEvidence)) {
    return 'target';
  }
  return 'third';
};

export const createPlaymeshProjectRekeyBrowserEvidence = (
  journalValue /*: PlaymeshProjectRekeyJournalRecord */,
  side /*: 'source' | 'target' */
) /*: PlaymeshProjectRekeyBrowserEvidence */ => {
  const journal = assertPlaymeshProjectRekeyJournalRecord(journalValue);
  const isSource = side === 'source';
  if (!isSource && side !== 'target') {
    return fail(
      'invalid_browser_side',
      'Playmesh 项目身份迁移浏览器状态无效。'
    );
  }
  const project = isSource ? journal.sourceProject : journal.targetProject;
  const evidence = isSource ? journal.sourceEvidence : journal.targetEvidence;
  const gameId = isSource ? journal.oldGameId : journal.newGameId;
  return {
    fileMetadata: {
      fileIdentifier: journal.fileIdentifier,
      gameId,
    },
    packageName: gameId,
    projectJsonHash: evidence.projectJsonHash,
  };
};

export const clearPlaymeshProjectRekeyJournal = async (
  {
    fileIdentifier: fileIdentifierValue,
    txId: txIdValue,
  } /*: {|
  fileIdentifier: string,
  txId: string,
|} */
) /*: Promise<void> */ => {
  const fileIdentifier = validatePlaymeshProjectRekeyToken(fileIdentifierValue);
  const txId = validatePlaymeshProjectRekeyToken(txIdValue);
  const currentValue = sessionRekeyJournals.get(fileIdentifier) || null;
  if (currentValue !== undefined && currentValue !== null) {
    const current = assertPlaymeshProjectRekeyJournalRecord(currentValue);
    if (current.txId !== txId) {
      return fail(
        'journal_transaction_mismatch',
        'Playmesh 项目身份迁移日志事务不匹配。'
      );
    }
    sessionRekeyJournals.delete(fileIdentifier);
  }
};
