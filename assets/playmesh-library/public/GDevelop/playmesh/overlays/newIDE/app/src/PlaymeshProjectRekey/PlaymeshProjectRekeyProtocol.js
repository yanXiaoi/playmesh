// @flow

import {
  PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS,
  normalizePlaymeshProjectTags,
  validatePlaymeshProjectConfigGameId,
  validatePlaymeshProjectGameType,
} from '../PlaymeshProjectConfig/PlaymeshProjectConfigProtocol';

export const PLAYMESH_PROJECT_REKEY_PROTOCOL = 'gdevelop.rekey.v2';
export const PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES = 1024 * 1024;

/*::
export type PlaymeshProjectRekeyPhase =
  | 'PREPARED'
  | 'COMMIT_REQUESTED'
  | 'NEW_PUBLISHED'
  | 'BROWSER_UPDATED'
  | 'ROLLBACK_REQUESTED'
  | 'OLD_CLEANED'
  | 'ROLLED_BACK'
  | 'CONFLICT'
  | 'ABORTED';
export type PlaymeshProjectRekeyBrowserTarget = {|
  fileIdentifier: string,
  projectFilesHash: string,
|};
export type PlaymeshProjectRekeyBrowserEvidence = {|
  fileMetadata: {|
    fileIdentifier: string,
    gameId: string,
  |},
  packageName: string,
  projectFilesHash: string,
|};
export type PlaymeshProjectRekeyHistoryEvidence = {|
  revision: number,
  currentContentHash: string,
  projectFilesHash: string,
  resourceManifestHash: string,
|};
export type PlaymeshProjectRekeyConfig = {|
  schemaVersion: 2,
  gameId: string,
  revision: number,
  gameType: 'single' | 'online',
  minPlayers: number,
  maxPlayers: number,
  tags: Array<string>,
  updatedAt: string,
|};
export type PlaymeshProjectRekeyConfigEvidence =
  | {| status: 'missing' |}
  | {|
      status: 'ready',
      revision: number,
      contentHash: string,
      config: PlaymeshProjectRekeyConfig,
    |};
export type PlaymeshProjectRekeyExpectedEvidence = {|
  history: PlaymeshProjectRekeyHistoryEvidence,
  config: PlaymeshProjectRekeyConfigEvidence,
|};
export type PlaymeshProjectRekeyBackendEvidence = {|
  projectMetadataHash: string,
  rootManifestHash: string,
  history: PlaymeshProjectRekeyHistoryEvidence,
  config: PlaymeshProjectRekeyConfigEvidence,
  mainJsonHash: ?string,
|};
export type PlaymeshProjectRekeyJsonValue =
  | null
  | boolean
  | number
  | string
  | Array<PlaymeshProjectRekeyJsonValue>
  | { [string]: PlaymeshProjectRekeyJsonValue };
export type PlaymeshProjectRekeyTransaction = {|
  txId: string,
  idempotencyKey: string,
  oldGameId: string,
  newGameId: string,
  phase: PlaymeshProjectRekeyPhase,
  clientId: ?string,
  browserSource: PlaymeshProjectRekeyBrowserTarget,
  browserTarget: PlaymeshProjectRekeyBrowserTarget,
  oldEvidence: PlaymeshProjectRekeyBackendEvidence,
  targetEvidence: PlaymeshProjectRekeyBackendEvidence,
  createdAt: string,
  updatedAt: string,
  expiresAt: ?string,
  retainedUntil: ?string,
  browserEvidence: ?PlaymeshProjectRekeyBrowserEvidence,
  rollbackBrowserEvidence: ?PlaymeshProjectRekeyBrowserEvidence,
  cleanupPending: boolean,
  cleanupError: ?string,
  conflict: ?{ [string]: PlaymeshProjectRekeyJsonValue },
|};
export type PlaymeshProjectRekeyEnvelope = {|
  requestId: string,
  transaction: PlaymeshProjectRekeyTransaction,
|};
export type PlaymeshProjectRekeyRecoveryEnvelope = {|
  requestId: string,
  transaction: ?PlaymeshProjectRekeyTransaction,
  replayedEventTxIds: Array<string>,
  cleanupPendingTxIds: Array<string>,
|};
export type PlaymeshProjectRekeyPrepareBody = {|
  idempotencyKey: string,
  newGameId: string,
  expectedOldEvidence: PlaymeshProjectRekeyExpectedEvidence,
  browserSource: PlaymeshProjectRekeyBrowserTarget,
  browserTarget: PlaymeshProjectRekeyBrowserTarget,
  clientId?: string,
|};
type MixedRecord = { +[string]: mixed };
*/

const HASH_PATTERN = /^[a-f0-9]{64}$/;
const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export class PlaymeshProjectRekeyProtocolError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshProjectRekeyProtocolError';
    this.code = code;
  }
}

const fail = (
  code /*: string */ = 'invalid_response',
  message /*: string */ = 'Playmesh 项目身份迁移响应无效。'
) /*: empty */ => {
  throw new PlaymeshProjectRekeyProtocolError(code, message);
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
  if (typeof value !== 'string' || !value) return fail();
  return value;
};

const requireToken = (value /*: mixed */) /*: string */ => {
  const result = requireString(value);
  if (!TOKEN_PATTERN.test(result)) return fail();
  return result;
};

const requireHash = (value /*: mixed */) /*: string */ => {
  const result = requireString(value);
  if (!HASH_PATTERN.test(result)) return fail();
  return result;
};

const requirePositiveInteger = (value /*: mixed */) /*: number */ => {
  if (!Number.isSafeInteger(value) || Number(value) < 1) return fail();
  return Number(value);
};

const requireTimestamp = (value /*: mixed */) /*: string */ => {
  const result = requireString(value);
  if (!Number.isFinite(Date.parse(result))) return fail();
  return result;
};

const requireNullableTimestamp = (value /*: mixed */) /*: ?string */ =>
  value === null ? null : requireTimestamp(value);

const requireNullableString = (value /*: mixed */) /*: ?string */ =>
  value === null ? null : requireString(value);

const assertJsonValue = (
  value /*: mixed */
) /*: PlaymeshProjectRekeyJsonValue */ => {
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
  const result /*: { [string]: PlaymeshProjectRekeyJsonValue } */ = {};
  Object.keys(record).forEach(key => {
    result[key] = assertJsonValue(record[key]);
  });
  return result;
};

const assertJsonObject = (
  value /*: mixed */
) /*: { [string]: PlaymeshProjectRekeyJsonValue } */ => {
  const result = assertJsonValue(value);
  if (result === null || Array.isArray(result) || typeof result !== 'object') {
    return fail();
  }
  return result;
};

export const validatePlaymeshProjectRekeyToken = (
  value /*: mixed */
) /*: string */ => {
  try {
    return requireToken(value);
  } catch (_) {
    return fail('invalid_token', 'Playmesh 项目身份迁移标识无效。');
  }
};

export const assertPlaymeshProjectRekeyBrowserTarget = (
  value /*: mixed */
) /*: PlaymeshProjectRekeyBrowserTarget */ => {
  const target = asRecord(value);
  if (!target || !hasExactKeys(target, ['fileIdentifier', 'projectFilesHash'])) {
    return fail();
  }
  return {
    fileIdentifier: requireToken(target.fileIdentifier),
    projectFilesHash: requireHash(target.projectFilesHash),
  };
};

export const assertPlaymeshProjectRekeyBrowserEvidence = (
  value /*: mixed */,
  expectedGameIdValue /*: ?mixed */
) /*: PlaymeshProjectRekeyBrowserEvidence */ => {
  const evidence = asRecord(value);
  const metadata = evidence ? asRecord(evidence.fileMetadata) : null;
  if (
    !evidence ||
    !hasExactKeys(evidence, [
      'fileMetadata',
      'packageName',
      'projectFilesHash',
    ]) ||
    !metadata ||
    !hasExactKeys(metadata, ['fileIdentifier', 'gameId'])
  ) {
    return fail();
  }
  const gameId = validatePlaymeshProjectConfigGameId(metadata.gameId);
  if (
    expectedGameIdValue !== null &&
    expectedGameIdValue !== undefined &&
    gameId !== validatePlaymeshProjectConfigGameId(expectedGameIdValue)
  ) {
    return fail();
  }
  const packageName = validatePlaymeshProjectConfigGameId(evidence.packageName);
  if (packageName !== gameId) return fail();
  return {
    fileMetadata: {
      fileIdentifier: requireToken(metadata.fileIdentifier),
      gameId,
    },
    packageName,
    projectFilesHash: requireHash(evidence.projectFilesHash),
  };
};

const assertHistoryEvidence = (
  value /*: mixed */
) /*: PlaymeshProjectRekeyHistoryEvidence */ => {
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

const assertConfig = (
  value /*: mixed */,
  expectedGameId /*: string */
) /*: PlaymeshProjectRekeyConfig */ => {
  const config = asRecord(value);
  if (
    !config ||
    !hasExactKeys(config, [
      'schemaVersion',
      'gameId',
      'revision',
      'gameType',
      'minPlayers',
      'maxPlayers',
      'tags',
      'updatedAt',
    ]) ||
    config.schemaVersion !== 2 ||
    validatePlaymeshProjectConfigGameId(config.gameId) !== expectedGameId
  ) {
    return fail();
  }
  const gameType = validatePlaymeshProjectGameType(config.gameType);
  const minPlayers = config.minPlayers;
  const maxPlayers = config.maxPlayers;
  if (
    typeof minPlayers !== 'number' ||
    !Number.isSafeInteger(minPlayers) ||
    typeof maxPlayers !== 'number' ||
    !Number.isSafeInteger(maxPlayers) ||
    minPlayers < 1 ||
    maxPlayers < minPlayers ||
    maxPlayers > PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS ||
    (gameType === 'single' &&
      (minPlayers !== 1 || maxPlayers !== 1))
  ) {
    return fail();
  }
  return {
    schemaVersion: 2,
    gameId: expectedGameId,
    revision: requirePositiveInteger(config.revision),
    gameType,
    minPlayers,
    maxPlayers,
    tags: normalizePlaymeshProjectTags(config.tags),
    updatedAt: requireTimestamp(config.updatedAt),
  };
};

export const assertPlaymeshProjectRekeyConfigEvidence = (
  value /*: mixed */,
  expectedGameIdValue /*: mixed */
) /*: PlaymeshProjectRekeyConfigEvidence */ => {
  const expectedGameId = validatePlaymeshProjectConfigGameId(
    expectedGameIdValue
  );
  const evidence = asRecord(value);
  if (!evidence) return fail();
  if (evidence.status === 'missing') {
    if (!hasExactKeys(evidence, ['status'])) return fail();
    return { status: 'missing' };
  }
  if (
    evidence.status !== 'ready' ||
    !hasExactKeys(evidence, ['status', 'revision', 'contentHash', 'config'])
  ) {
    return fail();
  }
  const config = assertConfig(evidence.config, expectedGameId);
  const revision = requirePositiveInteger(evidence.revision);
  if (config.revision !== revision) return fail();
  return {
    status: 'ready',
    revision,
    contentHash: requireHash(evidence.contentHash),
    config,
  };
};

export const assertPlaymeshProjectRekeyExpectedEvidence = (
  value /*: mixed */,
  expectedGameIdValue /*: mixed */
) /*: PlaymeshProjectRekeyExpectedEvidence */ => {
  const evidence = asRecord(value);
  if (!evidence || !hasExactKeys(evidence, ['history', 'config'])) {
    return fail();
  }
  const expectedGameId = validatePlaymeshProjectConfigGameId(
    expectedGameIdValue
  );
  return {
    history: assertHistoryEvidence(evidence.history),
    config: assertPlaymeshProjectRekeyConfigEvidence(
      evidence.config,
      expectedGameId
    ),
  };
};

export const assertPlaymeshProjectRekeyBackendEvidence = (
  value /*: mixed */,
  expectedGameIdValue /*: mixed */
) /*: PlaymeshProjectRekeyBackendEvidence */ => {
  const evidence = asRecord(value);
  if (
    !evidence ||
    !hasExactKeys(evidence, [
      'projectMetadataHash',
      'rootManifestHash',
      'history',
      'config',
      'mainJsonHash',
    ])
  ) {
    return fail();
  }
  const expectedGameId = validatePlaymeshProjectConfigGameId(
    expectedGameIdValue
  );
  return {
    projectMetadataHash: requireHash(evidence.projectMetadataHash),
    rootManifestHash: requireHash(evidence.rootManifestHash),
    history: assertHistoryEvidence(evidence.history),
    config: assertPlaymeshProjectRekeyConfigEvidence(
      evidence.config,
      expectedGameId
    ),
    mainJsonHash:
      evidence.mainJsonHash === null
        ? null
        : requireHash(evidence.mainJsonHash),
  };
};

const assertPhase = (value /*: mixed */) /*: PlaymeshProjectRekeyPhase */ => {
  if (
    value !== 'PREPARED' &&
    value !== 'COMMIT_REQUESTED' &&
    value !== 'NEW_PUBLISHED' &&
    value !== 'BROWSER_UPDATED' &&
    value !== 'ROLLBACK_REQUESTED' &&
    value !== 'OLD_CLEANED' &&
    value !== 'ROLLED_BACK' &&
    value !== 'CONFLICT' &&
    value !== 'ABORTED'
  ) {
    return fail();
  }
  return value;
};

export const assertPlaymeshProjectRekeyTransaction = (
  value /*: mixed */,
  expectedOldGameIdValue /*: mixed */
) /*: PlaymeshProjectRekeyTransaction */ => {
  const transaction = asRecord(value);
  const expectedOldGameId = validatePlaymeshProjectConfigGameId(
    expectedOldGameIdValue
  );
  const expectedKeys = [
    'txId',
    'idempotencyKey',
    'oldGameId',
    'newGameId',
    'phase',
    'clientId',
    'browserSource',
    'browserTarget',
    'oldEvidence',
    'targetEvidence',
    'createdAt',
    'updatedAt',
    'expiresAt',
    'retainedUntil',
    'browserEvidence',
    'rollbackBrowserEvidence',
    'cleanupPending',
    'cleanupError',
    'conflict',
  ];
  if (!transaction || !hasExactKeys(transaction, expectedKeys)) return fail();
  const oldGameId = validatePlaymeshProjectConfigGameId(transaction.oldGameId);
  const newGameId = validatePlaymeshProjectConfigGameId(transaction.newGameId);
  if (oldGameId !== expectedOldGameId || oldGameId === newGameId) return fail();
  const browserSource = assertPlaymeshProjectRekeyBrowserTarget(
    transaction.browserSource
  );
  const browserTarget = assertPlaymeshProjectRekeyBrowserTarget(
    transaction.browserTarget
  );
  if (browserSource.fileIdentifier !== browserTarget.fileIdentifier) {
    return fail();
  }
  const browserEvidence =
    transaction.browserEvidence === null
      ? null
      : assertPlaymeshProjectRekeyBrowserEvidence(
          transaction.browserEvidence,
          newGameId
        );
  const rollbackBrowserEvidence =
    transaction.rollbackBrowserEvidence === null
      ? null
      : assertPlaymeshProjectRekeyBrowserEvidence(
          transaction.rollbackBrowserEvidence,
          oldGameId
        );
  const cleanupPending = transaction.cleanupPending;
  if (typeof cleanupPending !== 'boolean') return fail();
  const conflict =
    transaction.conflict === null
      ? null
      : assertJsonObject(transaction.conflict);
  const phase = assertPhase(transaction.phase);
  if (phase === 'CONFLICT' && !conflict) return fail();
  return {
    txId: requireToken(transaction.txId),
    idempotencyKey: requireToken(transaction.idempotencyKey),
    oldGameId,
    newGameId,
    phase,
    clientId: requireNullableString(transaction.clientId),
    browserSource,
    browserTarget,
    oldEvidence: assertPlaymeshProjectRekeyBackendEvidence(
      transaction.oldEvidence,
      oldGameId
    ),
    targetEvidence: assertPlaymeshProjectRekeyBackendEvidence(
      transaction.targetEvidence,
      newGameId
    ),
    createdAt: requireTimestamp(transaction.createdAt),
    updatedAt: requireTimestamp(transaction.updatedAt),
    expiresAt: requireNullableTimestamp(transaction.expiresAt),
    retainedUntil: requireNullableTimestamp(transaction.retainedUntil),
    browserEvidence,
    rollbackBrowserEvidence,
    cleanupPending,
    cleanupError: requireNullableString(transaction.cleanupError),
    conflict,
  };
};

export const assertPlaymeshProjectRekeyEnvelope = (
  value /*: mixed */,
  expectedOldGameId /*: mixed */
) /*: PlaymeshProjectRekeyEnvelope */ => {
  const envelope = asRecord(value);
  if (!envelope || !hasExactKeys(envelope, ['requestId', 'transaction'])) {
    return fail();
  }
  return {
    requestId: requireString(envelope.requestId),
    transaction: assertPlaymeshProjectRekeyTransaction(
      envelope.transaction,
      expectedOldGameId
    ),
  };
};

export const assertPlaymeshProjectRekeyRecoveryEnvelope = (
  value /*: mixed */,
  expectedOldGameId /*: mixed */
) /*: PlaymeshProjectRekeyRecoveryEnvelope */ => {
  const envelope = asRecord(value);
  const replayedEventTxIds = envelope ? envelope.replayedEventTxIds : null;
  const cleanupPendingTxIds = envelope ? envelope.cleanupPendingTxIds : null;
  if (
    !envelope ||
    !hasExactKeys(envelope, [
      'requestId',
      'transaction',
      'replayedEventTxIds',
      'cleanupPendingTxIds',
    ]) ||
    !Array.isArray(replayedEventTxIds) ||
    !Array.isArray(cleanupPendingTxIds)
  ) {
    return fail();
  }
  return {
    requestId: requireString(envelope.requestId),
    transaction:
      envelope.transaction === null
        ? null
        : assertPlaymeshProjectRekeyTransaction(
            envelope.transaction,
            expectedOldGameId
          ),
    replayedEventTxIds: replayedEventTxIds.map(requireToken),
    cleanupPendingTxIds: cleanupPendingTxIds.map(requireToken),
  };
};

export const createPlaymeshProjectRekeyPrepareBodyForGame = (
  value /*: mixed */,
  oldGameIdValue /*: mixed */
) /*: PlaymeshProjectRekeyPrepareBody */ => {
  const input = asRecord(value);
  if (
    !input ||
    !hasAllowedKeys(
      input,
      [
        'idempotencyKey',
        'newGameId',
        'expectedOldEvidence',
        'browserSource',
        'browserTarget',
      ],
      ['clientId']
    )
  ) {
    return fail('invalid_request', 'Playmesh 项目身份迁移请求无效。');
  }
  const oldGameId = validatePlaymeshProjectConfigGameId(oldGameIdValue);
  const allowed = {
    idempotencyKey: input.idempotencyKey,
    newGameId: input.newGameId,
    expectedOldEvidence: input.expectedOldEvidence,
    browserSource: input.browserSource,
    browserTarget: input.browserTarget,
    ...(input.clientId === undefined ? {} : { clientId: input.clientId }),
  };
  const newGameId = validatePlaymeshProjectConfigGameId(allowed.newGameId);
  if (newGameId === oldGameId) return fail('invalid_request');
  const browserSource = assertPlaymeshProjectRekeyBrowserTarget(
    allowed.browserSource
  );
  const browserTarget = assertPlaymeshProjectRekeyBrowserTarget(
    allowed.browserTarget
  );
  if (browserSource.fileIdentifier !== browserTarget.fileIdentifier) {
    return fail('invalid_request');
  }
  const result /*: PlaymeshProjectRekeyPrepareBody */ = {
    idempotencyKey: requireToken(allowed.idempotencyKey),
    newGameId,
    expectedOldEvidence: assertPlaymeshProjectRekeyExpectedEvidence(
      allowed.expectedOldEvidence,
      oldGameId
    ),
    browserSource,
    browserTarget,
  };
  if (allowed.clientId !== undefined) {
    const clientId = requireString(allowed.clientId).trim();
    if (!clientId || clientId.length > 128) return fail('invalid_request');
    result.clientId = clientId;
  }
  return result;
};

export const buildPlaymeshProjectRekeyBaseUrl = (
  oldGameIdValue /*: mixed */
) /*: string */ => {
  const oldGameId = validatePlaymeshProjectConfigGameId(oldGameIdValue);
  return `/dev/api/gdevelop/projects/${encodeURIComponent(
    oldGameId
  )}/rekey-transactions`;
};

export const buildPlaymeshProjectRekeyTransactionUrl = (
  oldGameId /*: mixed */,
  txIdValue /*: mixed */
) /*: string */ =>
  `${buildPlaymeshProjectRekeyBaseUrl(oldGameId)}/${encodeURIComponent(
    requireToken(txIdValue)
  )}`;
