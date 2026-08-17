// @flow

import {
  assertStoredProject,
  getStoredProject,
  putStoredProject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import type { StoredProject } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import {
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreProjectEvidence,
  validatePlaymeshHistoryRestoreIdempotencyKey,
  validatePlaymeshHistoryRestoreRevision,
  validatePlaymeshHistoryRestoreSource,
} from './PlaymeshHistoryRestoreProtocol';
import type {
  PlaymeshHistoryRestoreBrowserEvidence,
  PlaymeshHistoryRestoreProjectEvidence,
  PlaymeshHistoryRestoreSource,
  PlaymeshHistoryRestoreTransaction,
} from './PlaymeshHistoryRestoreProtocol';
import { validatePlaymeshProjectConfigGameId } from '../PlaymeshProjectConfig/PlaymeshProjectConfigProtocol';
import { computePlaymeshHistoryBrowserEvidence } from './PlaymeshHistoryEvidence';
export {
  assertPlaymeshHistoryBrowserEvidenceMatches,
  computePlaymeshHistoryBrowserEvidence,
  encodePlaymeshHistoryCanonicalJson,
  hashPlaymeshHistoryBlob,
  hashPlaymeshHistoryBytes,
  hashPlaymeshHistoryJson,
} from './PlaymeshHistoryEvidence';

/*::
export type PlaymeshHistoryRestoreJournalPhase =
  | 'PREPARED_LOCAL'
  | 'BROWSER_APPLIED_PENDING_ACK';
export type PlaymeshHistoryRestoreJournalRecord = {|
  schemaVersion: 1,
  gameId: string,
  txId: string,
  idempotencyKey: string,
  fileIdentifier: string,
  phase: PlaymeshHistoryRestoreJournalPhase,
  baseRevision: number,
  targetRevision: number,
  source: PlaymeshHistoryRestoreSource,
  oldEvidence: PlaymeshHistoryRestoreProjectEvidence,
  targetEvidence: PlaymeshHistoryRestoreProjectEvidence,
  oldBrowserEvidence: PlaymeshHistoryRestoreBrowserEvidence,
  browserEvidence?: PlaymeshHistoryRestoreBrowserEvidence,
  createdAt: string,
  updatedAt: string,
|};
export type PlaymeshHistoryRestoreBrowserState = {|
  project: ?StoredProject,
  journal: ?PlaymeshHistoryRestoreJournalRecord,
|};
type MixedRecord = { +[string]: mixed };
*/

const JOURNAL_SCHEMA_VERSION = 1;
const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export class PlaymeshHistoryRestoreJournalError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshHistoryRestoreJournalError';
    this.code = code;
  }
}

const fail = (code /*: string */, message /*: string */) /*: empty */ => {
  throw new PlaymeshHistoryRestoreJournalError(code, message);
};

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const hasAllowedKeys = (
  record /*: MixedRecord */,
  required /*: $ReadOnlyArray<string> */,
  optional /*: $ReadOnlyArray<string> */
) /*: boolean */ =>
  required.every(key => Object.hasOwn(record, key)) &&
  Object.keys(record).every(
    key => required.includes(key) || optional.includes(key)
  );

const requireString = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !value) {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  return value;
};

const requireToken = (value /*: mixed */) /*: string */ => {
  const result = requireString(value);
  if (!TOKEN_PATTERN.test(result)) {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  return result;
};

const requireTimestamp = (value /*: mixed */) /*: string */ => {
  const result = requireString(value);
  if (!Number.isFinite(Date.parse(result))) {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  return result;
};

const requireJournalPhase = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreJournalPhase */ => {
  if (value !== 'PREPARED_LOCAL' && value !== 'BROWSER_APPLIED_PENDING_ACK') {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  return value;
};

export const assertPlaymeshHistoryRestoreJournalRecord = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreJournalRecord */ => {
  const journal = asRecord(value);
  if (
    !journal ||
    journal.schemaVersion !== JOURNAL_SCHEMA_VERSION ||
    !hasAllowedKeys(
      journal,
      [
        'schemaVersion',
        'gameId',
        'txId',
        'idempotencyKey',
        'fileIdentifier',
        'phase',
        'baseRevision',
        'targetRevision',
        'source',
        'oldEvidence',
        'targetEvidence',
        'oldBrowserEvidence',
        'createdAt',
        'updatedAt',
      ],
      ['browserEvidence']
    )
  ) {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  const gameId = validatePlaymeshProjectConfigGameId(journal.gameId);
  const result /*: PlaymeshHistoryRestoreJournalRecord */ = {
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    gameId,
    txId: requireToken(journal.txId),
    idempotencyKey: validatePlaymeshHistoryRestoreIdempotencyKey(
      journal.idempotencyKey
    ),
    fileIdentifier: requireString(journal.fileIdentifier),
    phase: requireJournalPhase(journal.phase),
    baseRevision: validatePlaymeshHistoryRestoreRevision(journal.baseRevision),
    targetRevision: validatePlaymeshHistoryRestoreRevision(
      journal.targetRevision
    ),
    source: validatePlaymeshHistoryRestoreSource(journal.source),
    oldEvidence: assertPlaymeshHistoryRestoreProjectEvidence(
      journal.oldEvidence,
      gameId
    ),
    targetEvidence: assertPlaymeshHistoryRestoreProjectEvidence(
      journal.targetEvidence,
      gameId
    ),
    oldBrowserEvidence: assertPlaymeshHistoryRestoreBrowserEvidence(
      journal.oldBrowserEvidence
    ),
    createdAt: requireTimestamp(journal.createdAt),
    updatedAt: requireTimestamp(journal.updatedAt),
  };
  if (journal.browserEvidence !== undefined) {
    result.browserEvidence = assertPlaymeshHistoryRestoreBrowserEvidence(
      journal.browserEvidence
    );
  }
  if (
    result.phase === 'BROWSER_APPLIED_PENDING_ACK' &&
    !result.browserEvidence
  ) {
    return fail('journal_corrupt', 'Playmesh 历史恢复日志无效。');
  }
  return result;
};

// App 的恢复事务是持久化事实；浏览器只保留当前页面协调状态。
const sessionRestoreJournals = new Map<
  string,
  PlaymeshHistoryRestoreJournalRecord
>();

export const createPlaymeshHistoryRestoreJournalRecord = (
  {
    transaction,
    fileIdentifier,
    oldBrowserEvidence,
    now = new Date().toISOString(),
  } /*: {|
  transaction: PlaymeshHistoryRestoreTransaction,
  fileIdentifier: string,
  oldBrowserEvidence: PlaymeshHistoryRestoreBrowserEvidence,
  now?: string,
|} */
) /*: PlaymeshHistoryRestoreJournalRecord */ =>
  assertPlaymeshHistoryRestoreJournalRecord({
    schemaVersion: JOURNAL_SCHEMA_VERSION,
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
    createdAt: now,
    updatedAt: now,
  });

export const persistPreparedPlaymeshHistoryRestoreJournal = async (
  journalValue /*: PlaymeshHistoryRestoreJournalRecord */
) /*: Promise<PlaymeshHistoryRestoreJournalRecord> */ => {
  const journal = assertPlaymeshHistoryRestoreJournalRecord(journalValue);
  if (journal.phase !== 'PREPARED_LOCAL') {
    return fail(
      'invalid_journal_transition',
      '只能持久化 PREPARED_LOCAL 恢复日志。'
    );
  }
  sessionRestoreJournals.set(journal.gameId, journal);
  return journal;
};

export const applyPlaymeshHistoryRestoreAtomically = async (
  {
    project,
    journal: journalValue,
    now = new Date().toISOString(),
  } /*: {|
  project: StoredProject,
  journal: PlaymeshHistoryRestoreJournalRecord,
  now?: string,
|} */
) /*: Promise<PlaymeshHistoryRestoreJournalRecord> */ => {
  const journal = assertPlaymeshHistoryRestoreJournalRecord(journalValue);
  if (
    journal.phase !== 'PREPARED_LOCAL' ||
    project.id !== journal.fileIdentifier ||
    project.gameId !== journal.gameId
  ) {
    return fail(
      'invalid_journal_transition',
      'Playmesh 历史恢复原子写入状态无效。'
    );
  }
  const browserEvidence = await computePlaymeshHistoryBrowserEvidence(project);
  const updatedJournal = assertPlaymeshHistoryRestoreJournalRecord({
    ...journal,
    phase: 'BROWSER_APPLIED_PENDING_ACK',
    browserEvidence,
    updatedAt: now,
  });
  await putStoredProject(project);
  sessionRestoreJournals.set(updatedJournal.gameId, updatedJournal);
  return updatedJournal;
};

export const readPlaymeshHistoryRestoreBrowserState = async (
  {
    gameId: gameIdValue,
    fileIdentifier,
  } /*: {|
  gameId: string,
  fileIdentifier: string,
|} */
) /*: Promise<PlaymeshHistoryRestoreBrowserState> */ => {
  const gameId = validatePlaymeshProjectConfigGameId(gameIdValue);
  if (!fileIdentifier) {
    return fail('invalid_file_identifier', 'Playmesh 本地项目标识无效。');
  }
  const projectValue = await getStoredProject(fileIdentifier);
  const journalValue = sessionRestoreJournals.get(gameId) || null;
  return {
    project:
      projectValue === undefined || projectValue === null
        ? null
        : assertStoredProject(projectValue),
    journal:
      journalValue === undefined || journalValue === null
        ? null
        : assertPlaymeshHistoryRestoreJournalRecord(journalValue),
  };
};

export const clearPlaymeshHistoryRestoreJournal = async (
  { gameId: gameIdValue, txId } /*: {|
  gameId: string,
  txId: string,
|} */
) /*: Promise<void> */ => {
  const gameId = validatePlaymeshProjectConfigGameId(gameIdValue);
  const normalizedTxId = requireToken(txId);
  const currentValue = sessionRestoreJournals.get(gameId) || null;
  if (currentValue !== undefined && currentValue !== null) {
    const current = assertPlaymeshHistoryRestoreJournalRecord(currentValue);
    if (current.txId !== normalizedTxId) {
      return fail(
        'journal_transaction_mismatch',
        'Playmesh 历史恢复日志事务不匹配。'
      );
    }
    sessionRestoreJournals.delete(gameId);
  }
};
