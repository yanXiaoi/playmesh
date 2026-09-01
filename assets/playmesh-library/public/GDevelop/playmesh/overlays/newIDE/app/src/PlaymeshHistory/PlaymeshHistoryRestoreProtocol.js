// @flow

import {
  assertPlaymeshProjectConfig,
  validatePlaymeshProjectConfigGameId,
} from '../PlaymeshProjectConfig/PlaymeshProjectConfigProtocol';

export const PLAYMESH_HISTORY_RESTORE_PROTOCOL = 'gdevelop.restore.v3';
export const PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES = 1024 * 1024 * 1024;

/*::
import type {
  PlaymeshProjectFile,
  PlaymeshProjectJsonObject,
  PlaymeshProjectJsonValue,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles';

export type PlaymeshHistoryRestorePhase =
  | 'PREPARED'
  | 'COMMIT_REQUESTED'
  | 'HISTORY_APPLIED'
  | 'BACKEND_COMMITTED'
  | 'BROWSER_PERSISTED'
  | 'CONFLICT'
  | 'ABORTED';
export type PlaymeshHistoryRestoreSource = 'user' | 'system';
export type PlaymeshHistoryRestoreReason =
  | 'explicit_save'
  | 'important_change'
  | 'autosave'
  | 'before_restore'
  | 'restore';
export type PlaymeshHistoryRestoreJsonValue = PlaymeshProjectJsonValue;
export type PlaymeshHistoryRestoreJsonObject = PlaymeshProjectJsonObject;
export type PlaymeshHistoryRestoreResource = {|
  logicalId: string,
  name?: string,
  contentHash: string,
  mime: string,
  size: number,
  metadata?: PlaymeshHistoryRestoreJsonObject,
|};
export type PlaymeshHistoryRestoreConfig = {|
  schemaVersion: 2,
  gameId: string,
  revision: number,
  gameType: 'single' | 'online',
  minPlayers: number,
  maxPlayers: number,
  tags: Array<string>,
  webRuntimeMultithreading: boolean,
  updatedAt: string,
|};
export type PlaymeshHistoryRestoreHistoryEvidence = {|
  revision: number,
  currentContentHash: string,
  projectFilesHash: string,
  resourceManifestHash: string,
|};
export type PlaymeshHistoryRestoreConfigEvidence =
  | {|
      semantics: 'ready' | 'legacy',
      status: 'ready',
      revision: number,
      contentHash: string,
      config: PlaymeshHistoryRestoreConfig,
    |}
  | {|
      semantics: 'missing' | 'legacy',
      status: 'missing',
    |};
export type PlaymeshHistoryRestoreProjectEvidence = {|
  history: PlaymeshHistoryRestoreHistoryEvidence,
  config: PlaymeshHistoryRestoreConfigEvidence,
|};
export type PlaymeshHistoryRestoreBrowserEvidence = {|
  projectFilesHash: string,
  resourceManifestHash: string,
|};
export type PlaymeshHistoryRestoreVersion = {|
  id: string,
  gameId: string,
  revision: number,
  timestamp: string,
  reason: PlaymeshHistoryRestoreReason,
  contentHash: string,
  source: PlaymeshHistoryRestoreSource,
  contentBytes: number,
|};
export type PlaymeshHistoryRestoreProjectReference = {|
  path: string,
  contentHash: string,
  size: number,
|};
export type PlaymeshHistoryRestoreProjectFile = PlaymeshProjectFile;
export type PlaymeshHistoryRestoreTargetSnapshot = {|
  sourceVersion: PlaymeshHistoryRestoreVersion,
  projectFilesReference: Array<PlaymeshHistoryRestoreProjectReference>,
  projectFiles: Array<PlaymeshHistoryRestoreProjectFile>,
  resources: Array<PlaymeshHistoryRestoreResource>,
  playmeshProjectConfig?: ?PlaymeshHistoryRestoreConfig,
|};
export type PlaymeshHistoryRestoredSnapshot = {|
  version: PlaymeshHistoryRestoreVersion,
  projectFiles: Array<PlaymeshHistoryRestoreProjectFile>,
  resources: Array<PlaymeshHistoryRestoreResource>,
  playmeshProjectConfig?: ?PlaymeshHistoryRestoreConfig,
|};
export type PlaymeshHistoryRestoreTransaction = {|
  txId: string,
  gameId: string,
  idempotencyKey: string,
  phase: PlaymeshHistoryRestorePhase,
  baseRevision: number,
  targetRevision: number,
  source: PlaymeshHistoryRestoreSource,
  clientId?: string,
  oldEvidence: PlaymeshHistoryRestoreProjectEvidence,
  targetEvidence: PlaymeshHistoryRestoreProjectEvidence,
  createdAt: string,
  updatedAt: string,
  expiresAt?: string,
  retainedUntil?: string,
  targetSnapshot?: PlaymeshHistoryRestoreTargetSnapshot,
  restored?: PlaymeshHistoryRestoredSnapshot,
  backupVersion?: PlaymeshHistoryRestoreVersion,
  browserEvidence?: PlaymeshHistoryRestoreBrowserEvidence,
  conflict?: PlaymeshHistoryRestoreJsonObject,
|};
export type PlaymeshHistoryRestoreEnvelope = {|
  requestId: string,
  transaction: PlaymeshHistoryRestoreTransaction,
|};
export type PlaymeshHistoryRestoreRecoveryEnvelope = {|
  requestId: string,
  transaction: ?PlaymeshHistoryRestoreTransaction,
  replayedEventTxIds: Array<string>,
|};
export type PlaymeshHistoryRestorePrepareBody = {|
  idempotencyKey: string,
  baseRevision: number,
  targetRevision: number,
  source: PlaymeshHistoryRestoreSource,
  currentProjectFiles: Array<PlaymeshHistoryRestoreProjectFile>,
  currentResources: Array<PlaymeshHistoryRestoreResource>,
  clientId?: string,
|};
type MixedRecord = { +[string]: mixed };
*/

const HASH_PATTERN = /^[a-f0-9]{64}$/;
const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export class PlaymeshHistoryRestoreProtocolError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshHistoryRestoreProtocolError';
    this.code = code;
  }
}

const fail = (
  code /*: string */ = 'invalid_response',
  message /*: string */ = 'Playmesh 历史恢复响应无效。'
) /*: empty */ => {
  throw new PlaymeshHistoryRestoreProtocolError(code, message);
};

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const hasOwn = (record /*: MixedRecord */, key /*: string */) /*: boolean */ =>
  Object.hasOwn(record, key);

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

const hasAllowedKeys = (
  record /*: MixedRecord */,
  required /*: $ReadOnlyArray<string> */,
  optional /*: $ReadOnlyArray<string> */
) /*: boolean */ =>
  required.every(key => hasOwn(record, key)) &&
  Object.keys(record).every(
    key => required.includes(key) || optional.includes(key)
  );

const requireString = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !value) return fail();
  return value;
};

const requireToken = (value /*: mixed */) /*: string */ => {
  const token = requireString(value);
  if (!TOKEN_PATTERN.test(token)) return fail();
  return token;
};

const requireHash = (value /*: mixed */) /*: string */ => {
  const hash = requireString(value);
  if (!HASH_PATTERN.test(hash)) return fail();
  return hash;
};

const requirePositiveInteger = (value /*: mixed */) /*: number */ => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    return fail();
  }
  return value;
};

const requireNonNegativeInteger = (value /*: mixed */) /*: number */ => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    return fail();
  }
  return value;
};

const requireTimestamp = (value /*: mixed */) /*: string */ => {
  const timestamp = requireString(value);
  if (!Number.isFinite(Date.parse(timestamp))) return fail();
  return timestamp;
};

const assertJsonValue = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreJsonValue */ => {
  if (
    value === null ||
    typeof value === 'boolean' ||
    typeof value === 'string'
  ) {
    return value;
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return fail();
    return value;
  }
  if (Array.isArray(value)) return value.map(assertJsonValue);
  const record = asRecord(value);
  if (!record) return fail();
  const result /*: PlaymeshHistoryRestoreJsonObject */ = {};
  Object.keys(record).forEach(key => {
    result[key] = assertJsonValue(record[key]);
  });
  return result;
};

const assertJsonObject = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreJsonObject */ => {
  const result = assertJsonValue(value);
  if (result === null || Array.isArray(result) || typeof result !== 'object') {
    return fail();
  }
  return result;
};

export const validatePlaymeshHistoryRestoreSource = (
  source /*: mixed */
) /*: PlaymeshHistoryRestoreSource */ => {
  if (source !== 'user' && source !== 'system') {
    return fail('invalid_source', 'Playmesh 历史恢复来源无效。');
  }
  return source;
};

const assertPlaymeshHistoryRestoreReason = (
  reason /*: mixed */
) /*: PlaymeshHistoryRestoreReason */ => {
  if (
    reason !== 'explicit_save' &&
    reason !== 'important_change' &&
    reason !== 'autosave' &&
    reason !== 'before_restore' &&
    reason !== 'restore'
  ) {
    return fail();
  }
  return reason;
};

const assertPlaymeshHistoryRestorePhase = (
  phase /*: mixed */
) /*: PlaymeshHistoryRestorePhase */ => {
  if (
    phase !== 'PREPARED' &&
    phase !== 'COMMIT_REQUESTED' &&
    phase !== 'HISTORY_APPLIED' &&
    phase !== 'BACKEND_COMMITTED' &&
    phase !== 'BROWSER_PERSISTED' &&
    phase !== 'CONFLICT' &&
    phase !== 'ABORTED'
  ) {
    return fail();
  }
  return phase;
};

export const validatePlaymeshHistoryRestoreRevision = (
  revision /*: mixed */
) /*: number */ => {
  try {
    return requirePositiveInteger(revision);
  } catch (_) {
    return fail('invalid_revision', 'Playmesh 历史恢复修订无效。');
  }
};

export const validatePlaymeshHistoryRestoreIdempotencyKey = (
  value /*: mixed */
) /*: string */ => {
  if (typeof value !== 'string' || !TOKEN_PATTERN.test(value)) {
    return fail('invalid_idempotency_key', 'Playmesh 历史恢复幂等键无效。');
  }
  return value;
};

export const validatePlaymeshHistoryRestoreClientId = (
  value /*: mixed */
) /*: string */ => {
  if (typeof value !== 'string') {
    return fail('invalid_client_id', 'Playmesh 历史恢复客户端标识无效。');
  }
  const normalized = value.trim();
  if (!normalized || normalized.length > 128) {
    return fail('invalid_client_id', 'Playmesh 历史恢复客户端标识无效。');
  }
  return normalized;
};

export const assertPlaymeshHistoryRestoreResource = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreResource */ => {
  const resource = asRecord(value);
  if (
    !resource ||
    !hasAllowedKeys(
      resource,
      ['logicalId', 'contentHash', 'mime', 'size'],
      ['name', 'metadata']
    )
  ) {
    return fail();
  }
  const logicalId = requireString(resource.logicalId);
  if (logicalId.includes('\\') || /[\u0000-\u001f\u007f]/.test(logicalId)) {
    return fail();
  }
  const result /*: PlaymeshHistoryRestoreResource */ = {
    logicalId,
    contentHash: requireHash(resource.contentHash),
    mime: requireString(resource.mime),
    size: requirePositiveInteger(resource.size),
  };
  if (resource.name !== undefined) {
    result.name = requireString(resource.name);
  }
  if (resource.metadata !== undefined) {
    result.metadata = assertJsonObject(resource.metadata);
  }
  return result;
};

export const assertPlaymeshHistoryRestoreConfig = (
  value /*: mixed */,
  gameId /*: string */
) /*: PlaymeshHistoryRestoreConfig */ => {
  try {
    return assertPlaymeshProjectConfig(value, gameId);
  } catch (_) {
    return fail();
  }
};

const assertHistoryEvidence = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreHistoryEvidence */ => {
  const evidence = asRecord(value);
  if (
    !evidence ||
    !hasExactKeys(evidence, [
      'revision',
      'currentContentHash',
      'projectFilesHash',
      'resourceManifestHash',
    ])
  ) {
    return fail();
  }
  return {
    revision: requirePositiveInteger(evidence.revision),
    currentContentHash: requireHash(evidence.currentContentHash),
    projectFilesHash: requireHash(evidence.projectFilesHash),
    resourceManifestHash: requireHash(evidence.resourceManifestHash),
  };
};

const assertConfigEvidence = (
  value /*: mixed */,
  gameId /*: string */
) /*: PlaymeshHistoryRestoreConfigEvidence */ => {
  const evidence = asRecord(value);
  if (!evidence) return fail();
  const semantics = evidence.semantics;
  if (
    semantics !== 'ready' &&
    semantics !== 'missing' &&
    semantics !== 'legacy'
  ) {
    return fail();
  }
  if (evidence.status === 'ready') {
    if (
      semantics === 'missing' ||
      !hasExactKeys(evidence, [
        'semantics',
        'status',
        'revision',
        'contentHash',
        'config',
      ])
    ) {
      return fail();
    }
    return {
      semantics,
      status: 'ready',
      revision: requirePositiveInteger(evidence.revision),
      contentHash: requireHash(evidence.contentHash),
      config: assertPlaymeshHistoryRestoreConfig(evidence.config, gameId),
    };
  }
  if (evidence.status === 'missing') {
    if (
      semantics === 'ready' ||
      !hasExactKeys(evidence, ['semantics', 'status'])
    ) {
      return fail();
    }
    return { semantics, status: 'missing' };
  }
  return fail();
};

export const assertPlaymeshHistoryRestoreProjectEvidence = (
  value /*: mixed */,
  gameId /*: string */
) /*: PlaymeshHistoryRestoreProjectEvidence */ => {
  const evidence = asRecord(value);
  if (!evidence || !hasExactKeys(evidence, ['history', 'config'])) {
    return fail();
  }
  return {
    history: assertHistoryEvidence(evidence.history),
    config: assertConfigEvidence(evidence.config, gameId),
  };
};

export const assertPlaymeshHistoryRestoreBrowserEvidence = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreBrowserEvidence */ => {
  const evidence = asRecord(value);
  if (
    !evidence ||
    !hasExactKeys(evidence, ['projectFilesHash', 'resourceManifestHash'])
  ) {
    return fail();
  }
  return {
    projectFilesHash: requireHash(evidence.projectFilesHash),
    resourceManifestHash: requireHash(evidence.resourceManifestHash),
  };
};

const assertVersion = (
  value /*: mixed */,
  gameId /*: string */
) /*: PlaymeshHistoryRestoreVersion */ => {
  const version = asRecord(value);
  if (
    !version ||
    !hasExactKeys(version, [
      'id',
      'gameId',
      'revision',
      'timestamp',
      'reason',
      'contentHash',
      'source',
      'contentBytes',
    ]) ||
    version.gameId !== gameId
  ) {
    return fail();
  }
  return {
    id: requireString(version.id),
    gameId,
    revision: requirePositiveInteger(version.revision),
    timestamp: requireTimestamp(version.timestamp),
    reason: assertPlaymeshHistoryRestoreReason(version.reason),
    contentHash: requireHash(version.contentHash),
    source: validatePlaymeshHistoryRestoreSource(version.source),
    contentBytes: requireNonNegativeInteger(version.contentBytes),
  };
};

const sameJson = (left /*: mixed */, right /*: mixed */) /*: boolean */ => {
  const canonicalize = (
    value /*: mixed */
  ) /*: PlaymeshHistoryRestoreJsonValue */ => {
    const normalized = assertJsonValue(value);
    if (Array.isArray(normalized)) return normalized.map(canonicalize);
    if (normalized === null || typeof normalized !== 'object') {
      return normalized;
    }
    const result /*: PlaymeshHistoryRestoreJsonObject */ = {};
    Object.keys(normalized)
      .sort()
      .forEach(key => {
        result[key] = canonicalize(normalized[key]);
      });
    return result;
  };
  return (
    JSON.stringify(canonicalize(left)) === JSON.stringify(canonicalize(right))
  );
};

const assertProjectReference = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreProjectReference */ => {
  const reference = asRecord(value);
  if (
    !reference ||
    !hasExactKeys(reference, ['path', 'contentHash', 'size'])
  ) {
    return fail();
  }
  return {
    path: requireString(reference.path),
    contentHash: requireHash(reference.contentHash),
    size: requirePositiveInteger(reference.size),
  };
};

const assertProjectFile = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreProjectFile */ => {
  const file = asRecord(value);
  if (!file || !hasExactKeys(file, ['path', 'content'])) return fail();
  return {
    path: requireString(file.path),
    content: assertJsonObject(file.content),
  };
};

const assertTargetSnapshot = (
  value /*: mixed */,
  gameId /*: string */,
  targetRevision /*: number */,
  targetConfigEvidence /*: PlaymeshHistoryRestoreConfigEvidence */
) /*: PlaymeshHistoryRestoreTargetSnapshot */ => {
  const snapshot = asRecord(value);
  const resourcesValue = snapshot ? snapshot.resources : null;
  const projectFilesValue = snapshot ? snapshot.projectFiles : null;
  const projectFilesReferenceValue = snapshot
    ? snapshot.projectFilesReference
    : null;
  if (
    !snapshot ||
    !hasAllowedKeys(
      snapshot,
      [
        'sourceVersion',
        'projectFilesReference',
        'projectFiles',
        'resources',
      ],
      ['playmeshProjectConfig']
    ) ||
    !Array.isArray(projectFilesReferenceValue) ||
    !Array.isArray(projectFilesValue) ||
    !Array.isArray(resourcesValue)
  ) {
    return fail();
  }
  const sourceVersion = assertVersion(snapshot.sourceVersion, gameId);
  if (sourceVersion.revision !== targetRevision) return fail();
  const result /*: PlaymeshHistoryRestoreTargetSnapshot */ = {
    sourceVersion,
    projectFilesReference: projectFilesReferenceValue.map(
      assertProjectReference
    ),
    projectFiles: projectFilesValue.map(assertProjectFile),
    resources: resourcesValue.map(assertPlaymeshHistoryRestoreResource),
  };
  if (hasOwn(snapshot, 'playmeshProjectConfig')) {
    if (snapshot.playmeshProjectConfig === null) {
      if (targetConfigEvidence.semantics !== 'missing') return fail();
      result.playmeshProjectConfig = null;
    } else {
      if (targetConfigEvidence.semantics !== 'ready') return fail();
      const config = assertPlaymeshHistoryRestoreConfig(
        snapshot.playmeshProjectConfig,
        gameId
      );
      if (
        targetConfigEvidence.status !== 'ready' ||
        !sameJson(config, targetConfigEvidence.config)
      ) {
        return fail();
      }
      result.playmeshProjectConfig = config;
    }
  } else if (targetConfigEvidence.semantics !== 'legacy') {
    return fail();
  }
  return result;
};

const assertRestoredSnapshot = (
  value /*: mixed */,
  gameId /*: string */,
  targetConfigEvidence /*: PlaymeshHistoryRestoreConfigEvidence */
) /*: PlaymeshHistoryRestoredSnapshot */ => {
  const restored = asRecord(value);
  const resourcesValue = restored ? restored.resources : null;
  const projectFilesValue = restored ? restored.projectFiles : null;
  if (
    !restored ||
    !hasAllowedKeys(
      restored,
      ['version', 'projectFiles', 'resources'],
      ['playmeshProjectConfig']
    ) ||
    !Array.isArray(projectFilesValue) ||
    !Array.isArray(resourcesValue)
  ) {
    return fail();
  }
  const result /*: PlaymeshHistoryRestoredSnapshot */ = {
    version: assertVersion(restored.version, gameId),
    projectFiles: projectFilesValue.map(assertProjectFile),
    resources: resourcesValue.map(assertPlaymeshHistoryRestoreResource),
  };
  if (hasOwn(restored, 'playmeshProjectConfig')) {
    if (restored.playmeshProjectConfig === null) {
      if (targetConfigEvidence.semantics !== 'missing') return fail();
      result.playmeshProjectConfig = null;
    } else {
      if (targetConfigEvidence.semantics !== 'ready') return fail();
      const config = assertPlaymeshHistoryRestoreConfig(
        restored.playmeshProjectConfig,
        gameId
      );
      if (
        targetConfigEvidence.status !== 'ready' ||
        !sameJson(config, targetConfigEvidence.config)
      ) {
        return fail();
      }
      result.playmeshProjectConfig = config;
    }
  } else if (targetConfigEvidence.semantics !== 'legacy') {
    return fail();
  }
  return result;
};

const assertConflict = (
  value /*: mixed */,
  gameId /*: string */
) /*: PlaymeshHistoryRestoreJsonObject */ => {
  const conflict = asRecord(value);
  if (
    !conflict ||
    !hasExactKeys(conflict, ['reason', 'observedAt', 'current'])
  ) {
    return fail();
  }
  const current = asRecord(conflict.current);
  if (!current || !hasExactKeys(current, ['history', 'config'])) return fail();
  const history =
    current.history === null ? null : assertHistoryEvidence(current.history);
  return assertJsonObject({
    reason: requireString(conflict.reason),
    observedAt: requireTimestamp(conflict.observedAt),
    current: {
      history,
      config: assertConfigEvidence(current.config, gameId),
    },
  });
};

export const assertPlaymeshHistoryRestoreTransaction = (
  value /*: mixed */,
  expectedGameIdValue /*: mixed */
) /*: PlaymeshHistoryRestoreTransaction */ => {
  const expectedGameId = validatePlaymeshProjectConfigGameId(
    expectedGameIdValue
  );
  const transaction = asRecord(value);
  if (
    !transaction ||
    !hasAllowedKeys(
      transaction,
      [
        'txId',
        'gameId',
        'idempotencyKey',
        'phase',
        'baseRevision',
        'targetRevision',
        'source',
        'oldEvidence',
        'targetEvidence',
        'createdAt',
        'updatedAt',
      ],
      [
        'clientId',
        'expiresAt',
        'retainedUntil',
        'targetSnapshot',
        'restored',
        'backupVersion',
        'browserEvidence',
        'conflict',
      ]
    ) ||
    transaction.gameId !== expectedGameId
  ) {
    return fail();
  }
  const phase = assertPlaymeshHistoryRestorePhase(transaction.phase);
  const oldEvidence = assertPlaymeshHistoryRestoreProjectEvidence(
    transaction.oldEvidence,
    expectedGameId
  );
  const targetEvidence = assertPlaymeshHistoryRestoreProjectEvidence(
    transaction.targetEvidence,
    expectedGameId
  );
  const baseRevision = requirePositiveInteger(transaction.baseRevision);
  const targetRevision = requirePositiveInteger(transaction.targetRevision);
  if (
    oldEvidence.history.revision !== baseRevision ||
    targetEvidence.history.revision !== baseRevision + 1
  ) {
    return fail();
  }
  const result /*: PlaymeshHistoryRestoreTransaction */ = {
    txId: requireToken(transaction.txId),
    gameId: expectedGameId,
    idempotencyKey: requireToken(transaction.idempotencyKey),
    phase,
    baseRevision,
    targetRevision,
    source: validatePlaymeshHistoryRestoreSource(transaction.source),
    oldEvidence,
    targetEvidence,
    createdAt: requireTimestamp(transaction.createdAt),
    updatedAt: requireTimestamp(transaction.updatedAt),
  };
  if (transaction.clientId !== undefined) {
    result.clientId = validatePlaymeshHistoryRestoreClientId(
      transaction.clientId
    );
  }
  if (transaction.expiresAt !== undefined) {
    result.expiresAt = requireTimestamp(transaction.expiresAt);
  }
  if (transaction.retainedUntil !== undefined) {
    result.retainedUntil = requireTimestamp(transaction.retainedUntil);
  }
  if (transaction.targetSnapshot !== undefined) {
    result.targetSnapshot = assertTargetSnapshot(
      transaction.targetSnapshot,
      expectedGameId,
      targetRevision,
      targetEvidence.config
    );
  }
  if (transaction.restored !== undefined) {
    result.restored = assertRestoredSnapshot(
      transaction.restored,
      expectedGameId,
      targetEvidence.config
    );
    if (result.restored.version.revision !== baseRevision + 1) return fail();
  }
  if (transaction.backupVersion !== undefined) {
    result.backupVersion = assertVersion(
      transaction.backupVersion,
      expectedGameId
    );
  }
  if (transaction.browserEvidence !== undefined) {
    result.browserEvidence = assertPlaymeshHistoryRestoreBrowserEvidence(
      transaction.browserEvidence
    );
  }
  if (transaction.conflict !== undefined) {
    result.conflict = assertConflict(transaction.conflict, expectedGameId);
  }
  if (result.phase === 'CONFLICT' && !result.conflict) return fail();
  if (
    result.phase === 'PREPARED' &&
    (!result.targetSnapshot || result.restored)
  ) {
    return fail();
  }
  if (result.phase === 'BROWSER_PERSISTED' && !result.browserEvidence) {
    return fail();
  }
  return result;
};

const requireRequestId = (value /*: mixed */) /*: string */ => {
  const requestId = requireString(value);
  if (requestId.length > 512) return fail();
  return requestId;
};

export const assertPlaymeshHistoryRestoreEnvelope = (
  value /*: mixed */,
  expectedGameId /*: mixed */
) /*: PlaymeshHistoryRestoreEnvelope */ => {
  const envelope = asRecord(value);
  if (!envelope || !hasExactKeys(envelope, ['requestId', 'transaction'])) {
    return fail();
  }
  return {
    requestId: requireRequestId(envelope.requestId),
    transaction: assertPlaymeshHistoryRestoreTransaction(
      envelope.transaction,
      expectedGameId
    ),
  };
};

export const assertPlaymeshHistoryRestoreRecoveryEnvelope = (
  value /*: mixed */,
  expectedGameId /*: mixed */
) /*: PlaymeshHistoryRestoreRecoveryEnvelope */ => {
  const envelope = asRecord(value);
  if (
    !envelope ||
    !hasExactKeys(envelope, [
      'requestId',
      'transaction',
      'replayedEventTxIds',
    ]) ||
    !Array.isArray(envelope.replayedEventTxIds)
  ) {
    return fail();
  }
  const replayedEventTxIds = envelope.replayedEventTxIds;
  return {
    requestId: requireRequestId(envelope.requestId),
    transaction:
      envelope.transaction === null
        ? null
        : assertPlaymeshHistoryRestoreTransaction(
            envelope.transaction,
            expectedGameId
          ),
    replayedEventTxIds: replayedEventTxIds.map(requireToken),
  };
};

export const createPlaymeshHistoryRestorePrepareBody = (
  {
    idempotencyKey,
    baseRevision,
    targetRevision,
    source,
    currentProjectFiles,
    currentResources,
    clientId,
  } /*: {|
    +idempotencyKey: mixed,
    +baseRevision: mixed,
    +targetRevision: mixed,
    +source: mixed,
    +currentProjectFiles: mixed,
    +currentResources: mixed,
    +clientId?: mixed,
  |} */
) /*: PlaymeshHistoryRestorePrepareBody */ => {
  if (
    !Array.isArray(currentProjectFiles) ||
    !Array.isArray(currentResources)
  ) {
    return fail('invalid_snapshot', 'Playmesh 当前项目资源无效。');
  }
  const body /*: PlaymeshHistoryRestorePrepareBody */ = {
    idempotencyKey: validatePlaymeshHistoryRestoreIdempotencyKey(
      idempotencyKey
    ),
    baseRevision: validatePlaymeshHistoryRestoreRevision(baseRevision),
    targetRevision: validatePlaymeshHistoryRestoreRevision(targetRevision),
    source: validatePlaymeshHistoryRestoreSource(source),
    currentProjectFiles: currentProjectFiles.map(assertProjectFile),
    currentResources: currentResources.map(
      assertPlaymeshHistoryRestoreResource
    ),
  };
  if (clientId !== undefined) {
    body.clientId = validatePlaymeshHistoryRestoreClientId(clientId);
  }
  return body;
};

export const buildPlaymeshHistoryRestoreBaseUrl = (
  gameId /*: mixed */
) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    validatePlaymeshProjectConfigGameId(gameId)
  )}/history/restore-transactions`;

export const buildPlaymeshHistoryResourceUrl = (
  gameId /*: mixed */,
  contentHash /*: mixed */
) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    validatePlaymeshProjectConfigGameId(gameId)
  )}/history/resources/${requireHash(contentHash)}`;

export const buildPlaymeshHistoryRestoreTransactionUrl = (
  gameId /*: mixed */,
  txId /*: mixed */
) /*: string */ =>
  `${buildPlaymeshHistoryRestoreBaseUrl(gameId)}/${encodeURIComponent(
    requireToken(txId)
  )}`;
