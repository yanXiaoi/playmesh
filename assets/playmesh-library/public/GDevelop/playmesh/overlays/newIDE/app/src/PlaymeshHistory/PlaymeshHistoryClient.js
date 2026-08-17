// @flow

import {
  assertPlaymeshProjectMutationLease,
  runPlaymeshProjectMutation,
} from '../PlaymeshProjectMutation/PlaymeshProjectMutationCoordinator';
import type { StoredProjectResource } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import {
  createPlaymeshHistoryResourceDto,
  encodePlaymeshHistoryCanonicalJson,
  hashPlaymeshHistoryBlob,
} from './PlaymeshHistoryEvidence';

type PlaymeshProjectMutationLease = $ReadOnly<{|
  gameId: string,
  owner: string,
  epoch: number,
|}>;

export type PlaymeshHistoryReason =
  | 'explicit_save'
  | 'important_change'
  | 'before_restore'
  | 'restore';

export type PlaymeshHistorySource = 'user' | 'system';

type PlaymeshHistorySnapshotReason =
  | 'explicit_save'
  | 'important_change';

export type PlaymeshHistoryJsonValue =
  | null
  | boolean
  | number
  | string
  | Array<PlaymeshHistoryJsonValue>
  | PlaymeshHistoryJsonObject;

export type PlaymeshHistoryJsonObject = {
  [string]: PlaymeshHistoryJsonValue,
};

type MixedRecord = { +[string]: mixed };

export type PlaymeshHistorySnapshotInput = $ReadOnly<{|
  +project: mixed,
  +resources: $ReadOnlyArray<mixed>,
|}>;

export type PlaymeshHistoryVersion = {|
  id: string,
  gameId: string,
  revision: number,
  timestamp: string,
  reason: PlaymeshHistoryReason,
  contentHash: string,
  source: PlaymeshHistorySource,
  contentBytes: number,
|};

export type PlaymeshHistoryResourceDto = {|
  logicalId: string,
  name?: string,
  contentHash: string,
  mime: string,
  size: number,
  metadata?: PlaymeshHistoryJsonObject,
|};

export type PlaymeshHistorySnapshot = {|
  version: PlaymeshHistoryVersion,
  project: PlaymeshHistoryJsonObject,
  resources: Array<PlaymeshHistoryResourceDto>,
|};

export type PlaymeshHistoryRetention = {|
  maxVersionsPerProject: number,
  maxUniqueBytesPerProject: number,
  maxObjectBytes: number,
  stagingTtlSeconds: number,
  maxProjectJsonBytes: number,
|};

export type PlaymeshHistoryListResponse = {|
  capability: 'gdevelop.history.v2',
  gameId: string,
  retention: PlaymeshHistoryRetention,
  versions: Array<PlaymeshHistoryVersion>,
|};

export type PlaymeshHistoryCurrentResponse = {|
  capability: 'gdevelop.history.v2',
  gameId: string,
  current: ?PlaymeshHistorySnapshot,
|};

export type PlaymeshHistoryMaterializedSnapshot = {|
  version: PlaymeshHistoryVersion,
  project: PlaymeshHistoryJsonObject,
  resources: Array<StoredProjectResource>,
|};

type PlaymeshHistoryMaterializeOptions = $ReadOnly<{|
  gameId: string,
  snapshot: mixed,
  signal?: AbortSignal,
  validateResources?: boolean,
  validateProject?: boolean,
|}>;

export type PlaymeshHistoryDiff = {|
  gameId: string,
  fromRevision: number,
  toRevision: number,
  changed: boolean,
  before: string,
  after: string,
  summary: {|
    addedLines: number,
    removedLines: number,
    resources: {|
      added: number,
      removed: number,
      changed: number,
    |},
  |},
  resourceEvidence: {|
    before: Array<PlaymeshHistoryResourceDto>,
    after: Array<PlaymeshHistoryResourceDto>,
  |},
|};

export type PlaymeshHistoryResourcePreviewKind = 'image' | 'audio' | 'video';

export type PlaymeshHistoryResourcePreview = {|
  side: 'before' | 'after',
  revision: number,
  logicalId: string,
  name: ?string,
  contentHash: string,
  mime: string,
  size: number,
  kind: PlaymeshHistoryResourcePreviewKind,
  url: string,
|};

export type PlaymeshHistoryRestoreResult = {|
  version: PlaymeshHistoryVersion,
  project: PlaymeshHistoryJsonObject,
  resources: Array<StoredProjectResource>,
  backupVersion: ?PlaymeshHistoryVersion,
|};

export type PreparedPlaymeshHistoryResource = {|
  ...PlaymeshHistoryResourceDto,
  blob: Blob,
|};

export type PreparedPlaymeshHistorySnapshot = {|
  project: PlaymeshHistoryJsonObject,
  resources: Array<PreparedPlaymeshHistoryResource>,
|};

type PlaymeshHistoryRequestOptions = {
  method?: string,
  headers?: { [string]: string },
  body?: string | Blob,
  signal?: AbortSignal,
};

type PlaymeshHistoryStatusError = {|
  code: string,
  message: string,
  details: mixed,
|};

type PlaymeshHistorySyncOptions = $ReadOnly<{|
  gameId: string,
  snapshot: PlaymeshHistorySnapshotInput,
  source: string,
  reason?: ?string,
  signal?: AbortSignal,
  mutationLease?: PlaymeshProjectMutationLease,
|}>;

export type PlaymeshHistoryRestoreOptions = $ReadOnly<{|
  gameId: string,
  targetRevision: number,
  source?: string,
  currentSnapshot: PlaymeshHistorySnapshotInput,
  signal?: AbortSignal,
  mutationLease?: PlaymeshProjectMutationLease,
|}>;

type PlaymeshHistorySyncResult =
  | {| skipped: 'unsupported' |}
  | {|
      gameId: string,
      current: PlaymeshHistoryVersion,
      historyCreated: false,
      uploadedResources: number,
    |}
  | {|
      gameId: string,
      version: PlaymeshHistoryVersion,
      deduplicated: boolean,
      historyCreated: boolean,
      uploadedResources: number,
    |};

type ExecutePlaymeshHistorySyncOptions = {|
  projectId: string,
  snapshot: PlaymeshHistorySnapshotInput,
  source: PlaymeshHistorySource,
  reason: ?PlaymeshHistorySnapshotReason,
  signal?: AbortSignal,
|};

type ExecutePlaymeshHistoryRestoreOptions = {|
  gameId: string,
  targetRevision: number,
  source: PlaymeshHistorySource,
  currentSnapshot: PlaymeshHistorySnapshotInput,
  signal?: AbortSignal,
|};

const CAPABILITY = 'gdevelop.history.v2';
const REQUEST_TIMEOUT_MS = 30000;
const PRESENCE_BATCH_SIZE = 2048;
const RESOURCE_DOWNLOAD_CONCURRENCY = 4;
const knownRevisions: Map<string, number> = new Map();
const unsupportedProjects: Set<string> = new Set();

export class PlaymeshHistoryError extends Error {
  code: string;
  details: mixed;
  status: number;
  requestId: ?string;
  operation: ?string;
  stage: string;
  reason: string;
  errorType: string;

  constructor(
    code: string,
    message: string,
    details: mixed = null,
    diagnostics: {|
      status?: number,
      requestId?: ?string,
      operation?: ?string,
      stage?: ?string,
      reason?: ?string,
      errorType?: ?string,
    |} = {}
  ) {
    super(message);
    this.name = 'PlaymeshHistoryError';
    this.code = code;
    this.details = details;
    this.status = Number.isSafeInteger(diagnostics.status)
      ? diagnostics.status
      : 0;
    this.requestId =
      typeof diagnostics.requestId === 'string' && diagnostics.requestId
        ? diagnostics.requestId
        : null;
    this.operation =
      typeof diagnostics.operation === 'string' && diagnostics.operation
        ? diagnostics.operation
        : null;
    this.stage =
      typeof diagnostics.stage === 'string' && diagnostics.stage
        ? diagnostics.stage
        : this.status > 0
        ? 'response'
        : 'pre_request';
    this.reason =
      typeof diagnostics.reason === 'string' && diagnostics.reason
        ? diagnostics.reason
        : message;
    this.errorType =
      typeof diagnostics.errorType === 'string' && diagnostics.errorType
        ? diagnostics.errorType
        : 'PlaymeshHistoryError';
  }
}

const asMixedRecord = (value: mixed): ?MixedRecord => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return (value: MixedRecord);
};

const invalidResponse = (): PlaymeshHistoryError =>
  new PlaymeshHistoryError('invalid_response', '本地历史响应无效。');

const requireString = (value: mixed): string => {
  if (typeof value !== 'string') throw invalidResponse();
  return value;
};

const requireSafeInteger = (value: mixed): number => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw invalidResponse();
  }
  return value;
};

const requireBoolean = (value: mixed): boolean => {
  if (typeof value !== 'boolean') throw invalidResponse();
  return value;
};

const assertHistoryReason = (value: mixed): PlaymeshHistoryReason => {
  if (
    value !== 'explicit_save' &&
    value !== 'important_change' &&
    value !== 'before_restore' &&
    value !== 'restore'
  ) {
    throw invalidResponse();
  }
  return value;
};

const assertHistorySource = (value: mixed): PlaymeshHistorySource => {
  if (value !== 'user' && value !== 'system') {
    throw invalidResponse();
  }
  return value;
};

const validateRequestedHistorySource = (
  value: mixed
): PlaymeshHistorySource => {
  try {
    return assertHistorySource(value);
  } catch (_) {
    throw new PlaymeshHistoryError(
      'invalid_history_source',
      '本地历史来源无效。'
    );
  }
};

const validateSnapshotReason = (
  value: mixed
): ?PlaymeshHistorySnapshotReason => {
  if (value == null || value === '') return null;
  if (
    value !== 'explicit_save' &&
    value !== 'important_change'
  ) {
    throw new PlaymeshHistoryError(
      'invalid_history_reason',
      '本地历史修订原因无效。'
    );
  }
  return value;
};

const assertJsonValue = (value: mixed): PlaymeshHistoryJsonValue => {
  if (
    value === null ||
    typeof value === 'boolean' ||
    typeof value === 'string'
  ) {
    return value;
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw invalidResponse();
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(
      (item: mixed): PlaymeshHistoryJsonValue => assertJsonValue(item)
    );
  }
  const record = asMixedRecord(value);
  if (!record) throw invalidResponse();
  const result: PlaymeshHistoryJsonObject = {};
  Object.keys(record).forEach((key: string) => {
    result[key] = assertJsonValue(record[key]);
  });
  return result;
};

const assertJsonObject = (value: mixed): PlaymeshHistoryJsonObject => {
  const normalized = assertJsonValue(value);
  if (
    !normalized ||
    typeof normalized !== 'object' ||
    Array.isArray(normalized)
  ) {
    throw invalidResponse();
  }
  return normalized;
};

const assertHistoryVersion = (value: mixed): PlaymeshHistoryVersion => {
  const version = asMixedRecord(value);
  if (!version) throw invalidResponse();
  const id = requireString(version.id);
  const gameId = requireString(version.gameId);
  const timestamp = requireString(version.timestamp);
  const contentHash = requireString(version.contentHash);
  if (!id || !gameId || !timestamp || !/^[a-f0-9]{64}$/.test(contentHash)) {
    throw invalidResponse();
  }
  return {
    id,
    gameId,
    revision: requireSafeInteger(version.revision),
    timestamp,
    reason: assertHistoryReason(version.reason),
    contentHash,
    source: assertHistorySource(version.source),
    contentBytes: requireSafeInteger(version.contentBytes),
  };
};

const assertResourceDto = (value: mixed): PlaymeshHistoryResourceDto => {
  const resource = asMixedRecord(value);
  if (!resource) throw invalidResponse();
  const logicalId = requireString(resource.logicalId);
  const contentHash = requireString(resource.contentHash);
  const mime = requireString(resource.mime);
  const nameValue = resource.name;
  const metadataValue = resource.metadata;
  if (
    !logicalId ||
    !/^[a-f0-9]{64}$/.test(contentHash) ||
    !mime ||
    (nameValue != null && typeof nameValue !== 'string')
  ) {
    throw invalidResponse();
  }
  const size = requireSafeInteger(resource.size);
  if (size < 1) throw invalidResponse();
  const result: PlaymeshHistoryResourceDto = {
    logicalId,
    contentHash,
    mime,
    size,
  };
  if (typeof nameValue === 'string') result.name = nameValue;
  if (metadataValue !== undefined) {
    result.metadata = assertJsonObject(metadataValue);
  }
  return result;
};

const assertSnapshot = (value: mixed): PlaymeshHistorySnapshot => {
  const snapshot = asMixedRecord(value);
  const resourcesValue = snapshot ? snapshot.resources : null;
  if (!snapshot || !Array.isArray(resourcesValue)) throw invalidResponse();
  return {
    version: assertHistoryVersion(snapshot.version),
    project: assertJsonObject(snapshot.project),
    resources: resourcesValue.map((resource: mixed) =>
      assertResourceDto(resource)
    ),
  };
};

const validateProjectId = (projectId: ?string): string => {
  if (
    typeof projectId !== 'string' ||
    !/^[A-Za-z0-9._-]{1,128}$/.test(projectId)
  ) {
    throw new PlaymeshHistoryError('invalid_project_id', '本地项目标识无效。');
  }
  return projectId;
};

const historyBase = (projectId: string): string =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    validateProjectId(projectId)
  )}/history`;

const previewKindForMime = (
  mime: string
): ?PlaymeshHistoryResourcePreviewKind => {
  if (
    [
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
      'image/avif',
    ].includes(mime)
  ) {
    return 'image';
  }
  if (
    [
      'audio/mpeg',
      'audio/ogg',
      'audio/wav',
      'audio/x-wav',
      'audio/mp4',
      'audio/aac',
      'audio/flac',
      'audio/webm',
    ].includes(mime)
  ) {
    return 'audio';
  }
  if (['video/mp4', 'video/webm', 'video/ogg'].includes(mime)) {
    return 'video';
  }
  return null;
};

const dispatchStatus = (
  gameId: string,
  state: 'syncing' | 'synced' | 'error',
  error: ?PlaymeshHistoryStatusError = null
): void => {
  window.dispatchEvent(
    new CustomEvent('playmesh-gdevelop-history-status', {
      detail: {
        capability: CAPABILITY,
        gameId,
        state,
        error,
        timestamp: Date.now(),
      },
    })
  );
};

const request = async (
  url: string,
  options: PlaymeshHistoryRequestOptions = {}
): Promise<Response> => {
  const operation = `${options.method || 'GET'} ${url}`;
  const controller = new AbortController();
  const timeoutId = window.setTimeout(
    () => controller.abort(),
    REQUEST_TIMEOUT_MS
  );
  const externalSignal = options.signal;
  const abortFromExternal = (): void => controller.abort();
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort();
    else
      externalSignal.addEventListener('abort', abortFromExternal, {
        once: true,
      });
  }
  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
      credentials: 'same-origin',
      cache: 'no-store',
    });
    if (!response.ok) {
      let details: mixed = null;
      try {
        details = (await response.json(): mixed);
      } catch (_) {}
      const detailsRecord = asMixedRecord(details);
      const errorEnvelope = asMixedRecord(
        detailsRecord ? detailsRecord.error : null
      );
      const envelopeCode = errorEnvelope ? errorEnvelope.code : null;
      const code =
        typeof envelopeCode === 'string' && envelopeCode
          ? envelopeCode
          : response.status === 401
          ? 'unauthorized'
          : response.status === 404
          ? 'not_found'
          : response.status === 408
          ? 'upload_timeout'
          : response.status === 413
          ? 'history_quota_exceeded'
          : response.status === 409
          ? 'gdevelop_revision_conflict'
          : 'history_request_failed';
      const envelopeMessage = errorEnvelope ? errorEnvelope.message : null;
      const envelopeReason = errorEnvelope ? errorEnvelope.reason : null;
      const envelopeStage = errorEnvelope ? errorEnvelope.stage : null;
      const envelopeType = errorEnvelope ? errorEnvelope.type : null;
      const requestId =
        detailsRecord && typeof detailsRecord.requestId === 'string'
          ? detailsRecord.requestId
          : response.headers.get('x-request-id');
      const responseOperation =
        response.headers.get('x-playmesh-operation-id') || operation;
      const message =
        typeof envelopeMessage === 'string' && envelopeMessage
          ? envelopeMessage
          : `本地历史请求失败（HTTP ${response.status}）。`;
      throw new PlaymeshHistoryError(
        code,
        message,
        details,
        {
          status: response.status,
          requestId,
          operation: responseOperation,
          stage:
            typeof envelopeStage === 'string' && envelopeStage
              ? envelopeStage
              : 'response',
          reason:
            typeof envelopeReason === 'string' && envelopeReason
              ? envelopeReason
              : message,
          errorType:
            typeof envelopeType === 'string' && envelopeType
              ? envelopeType
              : 'PlaymeshHistoryError',
        }
      );
    }
    return response;
  } catch (error) {
    if (error instanceof PlaymeshHistoryError) throw error;
    if (externalSignal && externalSignal.aborted) {
      throw new PlaymeshHistoryError('cancelled', '历史操作已取消。', null, {
        operation,
      });
    }
    if (controller.signal.aborted) {
      throw new PlaymeshHistoryError(
        'upload_timeout',
        '本地历史请求超时。',
        null,
        { operation }
      );
    }
    throw new PlaymeshHistoryError(
      'history_unavailable',
      '当前无法连接 Playmesh 本地历史服务。',
      null,
      { operation }
    );
  } finally {
    window.clearTimeout(timeoutId);
    if (externalSignal) {
      externalSignal.removeEventListener('abort', abortFromExternal);
    }
  }
};

const requestJson = async (
  url: string,
  options: PlaymeshHistoryRequestOptions = {}
): Promise<mixed> => {
  const response = await request(url, options);
  try {
    return (await response.json(): mixed);
  } catch (_) {
    throw new PlaymeshHistoryError(
      'invalid_response',
      '本地历史响应不是 JSON。',
      null,
      { operation: `${options.method || 'GET'} ${url}` }
    );
  }
};

const jsonRequest = (
  method: string,
  body: mixed,
  signal?: AbortSignal
): PlaymeshHistoryRequestOptions => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
  signal,
});

const sameCanonicalJson = (left: mixed, right: mixed): boolean => {
  const leftBytes = encodePlaymeshHistoryCanonicalJson(left);
  const rightBytes = encodePlaymeshHistoryCanonicalJson(right);
  if (leftBytes.length !== rightBytes.length) return false;
  for (let index = 0; index < leftBytes.length; index++) {
    if (leftBytes[index] !== rightBytes[index]) return false;
  }
  return true;
};

/**
 * GDevelop/Pixi may legitimately converge two resource entries back to the
 * same live Blob URL after an editor reload. The project JSON then has one
 * byte identity, so sending the same logicalId twice only creates an invalid
 * history manifest. Collapse byte-identical aliases at this wire boundary;
 * the official project JSON still owns the individual GDevelop resource
 * names. A logicalId that points at different bytes or metadata remains a
 * hard error and is never silently overwritten.
 */
const canonicalizePreparedResources = (
  resources: Array<PreparedPlaymeshHistoryResource>
): Array<PreparedPlaymeshHistoryResource> => {
  const byLogicalId: Map<string, PreparedPlaymeshHistoryResource> = new Map();
  resources.forEach(resource => {
    const existing = byLogicalId.get(resource.logicalId);
    if (!existing) {
      byLogicalId.set(resource.logicalId, resource);
      return;
    }
    if (
      existing.contentHash !== resource.contentHash ||
      existing.mime !== resource.mime ||
      existing.size !== resource.size ||
      !sameCanonicalJson(existing.metadata || null, resource.metadata || null)
    ) {
      throw new PlaymeshHistoryError(
        'resource_logical_id_conflict',
        '同一本地资源标识对应了不同内容。',
        null,
        {
          operation: 'gdevelop.history.snapshot.prepare',
          stage: 'pre_request',
          reason: 'resource_logical_id_conflict',
        }
      );
    }
    if (
      resource.name &&
      (!existing.name || resource.name.localeCompare(existing.name) < 0)
    ) {
      existing.name = resource.name;
    }
  });
  return [...byLogicalId.values()].sort((left, right) =>
    left.logicalId.localeCompare(right.logicalId)
  );
};

export const preparePlaymeshHistorySnapshot = async (
  snapshot: mixed
): Promise<PreparedPlaymeshHistorySnapshot> => {
  const snapshotRecord = asMixedRecord(snapshot);
  if (!snapshotRecord || !Array.isArray(snapshotRecord.resources)) {
    throw new PlaymeshHistoryError('invalid_snapshot', '本地项目快照无效。');
  }
  const snapshotResources = snapshotRecord.resources;
  let project: PlaymeshHistoryJsonObject;
  try {
    project = assertJsonObject(snapshotRecord.project);
  } catch (_) {
    throw new PlaymeshHistoryError('invalid_snapshot', '本地项目快照无效。');
  }
  const resources: Array<PreparedPlaymeshHistoryResource> = [];
  for (const resourceValue of snapshotResources) {
    const resource = asMixedRecord(resourceValue);
    const logicalUrl = resource ? resource.logicalUrl : null;
    const blobValue = resource ? resource.blob : null;
    if (
      !resource ||
      typeof logicalUrl !== 'string' ||
      !logicalUrl.startsWith('playmesh-local-resource://') ||
      !(blobValue instanceof Blob) ||
      blobValue.size < 1
    ) {
      throw new PlaymeshHistoryError('invalid_snapshot', '本地项目资源无效。');
    }
    const nameValue = resource.name;
    if (nameValue != null && typeof nameValue !== 'string') {
      throw new PlaymeshHistoryError('invalid_snapshot', '本地项目资源无效。');
    }
    const hashValue = resource.contentHash;
    const metadataValue = resource.metadata;
    const storedResource: StoredProjectResource = {
      logicalUrl,
      blob: blobValue,
    };
    if (typeof nameValue === 'string') storedResource.name = nameValue;
    if (typeof hashValue === 'string' && /^[a-f0-9]{64}$/.test(hashValue)) {
      storedResource.contentHash = hashValue;
    }
    if (metadataValue !== undefined) {
      storedResource.metadata = assertJsonObject(metadataValue);
    }
    const resourceDto = await createPlaymeshHistoryResourceDto(storedResource);
    resources.push({
      ...resourceDto,
      blob: blobValue,
    });
  }
  return { project, resources: canonicalizePreparedResources(resources) };
};

export const toPlaymeshHistoryResourceDto = (
  resource: PreparedPlaymeshHistoryResource
): PlaymeshHistoryResourceDto => {
  const result: PlaymeshHistoryResourceDto = {
    logicalId: resource.logicalId,
    contentHash: resource.contentHash,
    mime: resource.mime,
    size: resource.size,
  };
  if (resource.name) result.name = resource.name;
  if (resource.metadata !== undefined) result.metadata = resource.metadata;
  return result;
};

const getPresence = async (
  projectId: string,
  resources: $ReadOnlyArray<PreparedPlaymeshHistoryResource>,
  signal?: AbortSignal
): Promise<Set<string>> => {
  const missing: Set<string> = new Set();
  for (
    let offset = 0;
    offset < resources.length;
    offset += PRESENCE_BATCH_SIZE
  ) {
    const batch = resources.slice(offset, offset + PRESENCE_BATCH_SIZE);
    const response = asMixedRecord(
      await requestJson(
        `${historyBase(projectId)}/resources/presence`,
        jsonRequest(
          'POST',
          {
            resources: batch.map(resource => ({
              contentHash: resource.contentHash,
              size: resource.size,
            })),
          },
          signal
        )
      )
    );
    if (!response || !Array.isArray(response.missing)) {
      throw new PlaymeshHistoryError('invalid_response', '资源去重响应无效。');
    }
    response.missing.forEach((resourceValue: mixed) => {
      const resource = asMixedRecord(resourceValue);
      const contentHash = resource ? resource.contentHash : null;
      const size = resource ? resource.size : null;
      if (
        !resource ||
        typeof contentHash !== 'string' ||
        !/^[a-f0-9]{64}$/.test(contentHash) ||
        typeof size !== 'number' ||
        !Number.isSafeInteger(size)
      ) {
        throw new PlaymeshHistoryError(
          'invalid_response',
          '资源去重响应无效。'
        );
      }
      missing.add(contentHash);
    });
  }
  return missing;
};

export const uploadMissingPlaymeshHistoryResources = async (
  projectId: string,
  resources: $ReadOnlyArray<PreparedPlaymeshHistoryResource>,
  signal?: AbortSignal
): Promise<number> => {
  if (!resources.length) return 0;
  const missing = await getPresence(projectId, resources, signal);
  let uploaded = 0;
  for (const resource of resources) {
    if (!missing.has(resource.contentHash)) continue;
    const response = await request(
      `${historyBase(projectId)}/resources/${resource.contentHash}`,
      {
        method: 'PUT',
        // The browser derives Content-Length from the Blob body. Setting this
        // forbidden request header manually would make the upload non-portable.
        headers: { 'Content-Type': resource.mime },
        body: resource.blob,
        signal,
      }
    );
    const result = asMixedRecord((await response.json(): mixed));
    if (
      !result ||
      result.contentHash !== resource.contentHash ||
      result.size !== resource.size ||
      result.staged !== true
    ) {
      throw new PlaymeshHistoryError('invalid_response', '资源上传响应无效。');
    }
    uploaded++;
  }
  return uploaded;
};

const assertCurrentResponse = (
  value: mixed
): PlaymeshHistoryCurrentResponse => {
  const response = asMixedRecord(value);
  if (
    !response ||
    response.capability !== CAPABILITY ||
    typeof response.gameId !== 'string'
  ) {
    throw invalidResponse();
  }
  return {
    capability: CAPABILITY,
    gameId: response.gameId,
    current:
      response.current === null ? null : assertSnapshot(response.current),
  };
};

const assertRetention = (value: mixed): PlaymeshHistoryRetention => {
  const retention = asMixedRecord(value);
  if (!retention) throw invalidResponse();
  return {
    maxVersionsPerProject: requireSafeInteger(retention.maxVersionsPerProject),
    maxUniqueBytesPerProject: requireSafeInteger(
      retention.maxUniqueBytesPerProject
    ),
    maxObjectBytes: requireSafeInteger(retention.maxObjectBytes),
    stagingTtlSeconds: requireSafeInteger(retention.stagingTtlSeconds),
    maxProjectJsonBytes: requireSafeInteger(retention.maxProjectJsonBytes),
  };
};

const assertListResponse = (value: mixed): PlaymeshHistoryListResponse => {
  const response = asMixedRecord(value);
  const versionsValue = response ? response.versions : null;
  if (
    !response ||
    response.capability !== CAPABILITY ||
    typeof response.gameId !== 'string' ||
    !Array.isArray(versionsValue)
  ) {
    throw invalidResponse();
  }
  return {
    capability: CAPABILITY,
    gameId: response.gameId,
    retention: assertRetention(response.retention),
    versions: versionsValue.map((version: mixed) =>
      assertHistoryVersion(version)
    ),
  };
};

const setKnownRevisionFromCurrent = (
  projectId: string,
  response: PlaymeshHistoryCurrentResponse
): void => {
  const revision =
    response && response.current ? response.current.version.revision : null;
  if (Number.isSafeInteger(revision)) knownRevisions.set(projectId, revision);
  else if (response && response.current === null)
    knownRevisions.set(projectId, 0);
};

export const getPlaymeshHistoryCurrent = async (
  projectId: string,
  signal?: AbortSignal
): Promise<PlaymeshHistoryCurrentResponse> => {
  const response = assertCurrentResponse(
    await requestJson(`${historyBase(projectId)}/current`, { signal })
  );
  setKnownRevisionFromCurrent(projectId, response);
  return response;
};

export const ensureKnownPlaymeshHistoryRevision = async (
  projectId: string,
  signal?: AbortSignal
): Promise<number> => {
  const knownRevision = knownRevisions.get(projectId);
  if (typeof knownRevision === 'number') return knownRevision;
  await getPlaymeshHistoryCurrent(projectId, signal);
  return knownRevisions.get(projectId) || 0;
};

export const listPlaymeshHistory = async (
  projectId: string,
  signal?: AbortSignal
): Promise<PlaymeshHistoryListResponse> => {
  try {
    const response = assertListResponse(
      await requestJson(historyBase(projectId), { signal })
    );
    const newest = response.versions[0];
    if (newest && Number.isSafeInteger(newest.revision)) {
      knownRevisions.set(projectId, newest.revision);
    }
    unsupportedProjects.delete(projectId);
    return response;
  } catch (error) {
    if (error instanceof PlaymeshHistoryError && error.code === 'not_found') {
      unsupportedProjects.add(projectId);
    }
    throw error;
  }
};

const assertCurrentWriteResponse = (
  value: mixed
): {|
  gameId: string,
  current: PlaymeshHistoryVersion,
  historyCreated: false,
|} => {
  const response = asMixedRecord(value);
  if (
    !response ||
    typeof response.gameId !== 'string' ||
    response.historyCreated !== false
  ) {
    throw invalidResponse();
  }
  return {
    gameId: response.gameId,
    current: assertHistoryVersion(response.current),
    historyCreated: false,
  };
};

const assertSnapshotWriteResponse = (
  value: mixed
): {|
  gameId: string,
  version: PlaymeshHistoryVersion,
  deduplicated: boolean,
  historyCreated: boolean,
|} => {
  const response = asMixedRecord(value);
  if (!response || typeof response.gameId !== 'string') {
    throw invalidResponse();
  }
  return {
    gameId: response.gameId,
    version: assertHistoryVersion(response.version),
    deduplicated: requireBoolean(response.deduplicated),
    historyCreated: requireBoolean(response.historyCreated),
  };
};

const executeSync = async ({
  projectId,
  snapshot,
  source,
  reason,
  signal,
}: ExecutePlaymeshHistorySyncOptions): Promise<PlaymeshHistorySyncResult> => {
  if (unsupportedProjects.has(projectId)) return { skipped: 'unsupported' };
  dispatchStatus(projectId, 'syncing');
  const prepared = await preparePlaymeshHistorySnapshot(snapshot);
  const uploadedResources = await uploadMissingPlaymeshHistoryResources(
    projectId,
    prepared.resources,
    signal
  );
  const createRequestBody = (baseRevision: number) => ({
    baseRevision,
    source,
    ...(reason ? { reason } : {}),
    project: prepared.project,
    resources: prepared.resources.map(toPlaymeshHistoryResourceDto),
  });
  const baseRevision = await ensureKnownPlaymeshHistoryRevision(
    projectId,
    signal
  );
  const endpoint = reason ? 'snapshots' : 'current';
  let rawResponse: mixed;
  try {
    rawResponse = await requestJson(
      `${historyBase(projectId)}/${endpoint}`,
      jsonRequest(
        reason ? 'POST' : 'PUT',
        createRequestBody(baseRevision),
        signal
      )
    );
  } catch (error) {
    // 冲突可能来自刚完成的 AI commit。这里只清缓存并交给下一次用户操作重新
    // 读取 current，禁止把旧快照在另一个事务之后自动重放。
    if (
      error instanceof PlaymeshHistoryError &&
      error.code === 'gdevelop_revision_conflict'
    ) {
      knownRevisions.delete(projectId);
    }
    throw error;
  }
  if (reason) {
    const response = assertSnapshotWriteResponse(rawResponse);
    if (response.gameId !== projectId) throw invalidResponse();
    knownRevisions.set(projectId, response.version.revision);
    dispatchStatus(projectId, 'synced');
    return { ...response, uploadedResources };
  }
  const response = assertCurrentWriteResponse(rawResponse);
  if (response.gameId !== projectId) throw invalidResponse();
  knownRevisions.set(projectId, response.current.revision);
  dispatchStatus(projectId, 'synced');
  return { ...response, uploadedResources };
};

export const syncPlaymeshHistory = (
  options: PlaymeshHistorySyncOptions
): Promise<PlaymeshHistorySyncResult> => {
  const gameId = validateProjectId(options.gameId);
  const source = validateRequestedHistorySource(options.source);
  const reason = validateSnapshotReason(options.reason);
  const execute = (): Promise<PlaymeshHistorySyncResult> =>
    executeSync({
      projectId: gameId,
      snapshot: options.snapshot,
      source,
      reason,
      signal: options.signal,
    }).catch((error: mixed) => {
      const historyError =
        error instanceof PlaymeshHistoryError
          ? error
          : new PlaymeshHistoryError(
              'history_unavailable',
              '当前无法连接 Playmesh 本地历史服务。'
            );
      if (historyError.code === 'not_found') unsupportedProjects.add(gameId);
      dispatchStatus(gameId, 'error', {
        code: historyError.code,
        message: historyError.message,
        details: historyError.details,
      });
      throw historyError;
    });
  if (options.mutationLease) {
    const lease = assertPlaymeshProjectMutationLease(options.mutationLease);
    if (lease.gameId !== gameId) {
      throw new PlaymeshHistoryError(
        'mutation_lease_mismatch',
        '历史事务与当前项目不匹配。'
      );
    }
    return execute();
  }
  return runPlaymeshProjectMutation({
    gameId,
    owner: 'history-sync',
    operation: execute,
  });
};

const replaceStringsDeep = (
  value: PlaymeshHistoryJsonValue,
  replacements: Map<string, string>
): PlaymeshHistoryJsonValue => {
  if (typeof value === 'string') return replacements.get(value) || value;
  if (Array.isArray(value)) {
    value.forEach((item: PlaymeshHistoryJsonValue, index: number) => {
      value[index] = replaceStringsDeep(item, replacements);
    });
  } else if (value && typeof value === 'object') {
    Object.keys(value).forEach((key: string) => {
      value[key] = replaceStringsDeep(value[key], replacements);
    });
  }
  return value;
};

const downloadRestoredResources = async (
  projectId: string,
  resourceDtos: $ReadOnlyArray<any>,
  signal?: AbortSignal,
  validateResources: boolean = true
): Promise<Array<StoredProjectResource>> => {
  const resources: Array<StoredProjectResource> = new Array(
    resourceDtos.length
  );
  let nextResourceIndex = 0;
  let downloadFailure: mixed = null;
  const downloadNextResource = async (): Promise<void> => {
    while (downloadFailure === null) {
      const resourceIndex = nextResourceIndex++;
      if (resourceIndex >= resourceDtos.length) return;
      const dto = resourceDtos[resourceIndex];
      try {
        if (
          validateResources &&
          (!dto ||
            !dto.logicalId ||
            !/^[a-f0-9]{64}$/.test(dto.contentHash || '') ||
            !Number.isSafeInteger(dto.size))
        ) {
          throw new PlaymeshHistoryError(
            'invalid_response',
            '恢复资源描述无效。'
          );
        }
        const response = await request(
          `${historyBase(projectId)}/resources/${encodeURIComponent(
            String(dto.contentHash)
          )}`,
          { signal }
        );
        const blob = await response.blob();
        if (
          validateResources &&
          (blob.size !== dto.size ||
            (await hashPlaymeshHistoryBlob(blob)) !== dto.contentHash)
        ) {
          throw new PlaymeshHistoryError(
            'resource_corrupt',
            '恢复资源校验失败。'
          );
        }
        resources[resourceIndex] = {
          logicalUrl: dto.logicalId,
          name: dto.name || dto.logicalId,
          blob: new Blob([blob], { type: dto.mime || blob.type }),
          contentHash: dto.contentHash,
          ...(dto.metadata !== undefined ? { metadata: dto.metadata } : {}),
        };
      } catch (error) {
        if (downloadFailure === null) downloadFailure = error;
        return;
      }
    }
  };
  await Promise.all(
    Array.from(
      {
        length: Math.min(
          RESOURCE_DOWNLOAD_CONCURRENCY,
          resourceDtos.length
        ),
      },
      downloadNextResource
    )
  );
  if (downloadFailure !== null) throw downloadFailure;
  return resources;
};

const validateRestoredProject = (
  project: PlaymeshHistoryJsonObject,
  resources: $ReadOnlyArray<StoredProjectResource>
): void => {
  const validationProject = assertJsonObject(
    (JSON.parse(JSON.stringify(project)): mixed)
  );
  const replacements: Map<string, string> = new Map();
  const objectUrls: Array<string> = [];
  resources.forEach((resource: StoredProjectResource) => {
    const objectUrl = URL.createObjectURL(resource.blob);
    objectUrls.push(objectUrl);
    replacements.set(resource.logicalUrl, objectUrl);
  });
  replaceStringsDeep(validationProject, replacements);
  const gd = global.gd;
  const temporaryProject = gd.ProjectHelper.createNewGDJSProject();
  const serializedProject = gd.Serializer.fromJSObject(validationProject);
  try {
    temporaryProject.unserializeFrom(serializedProject);
  } finally {
    serializedProject.delete();
    temporaryProject.delete();
    objectUrls.forEach((objectUrl: string) => URL.revokeObjectURL(objectUrl));
  }
};

export const materializePlaymeshHistorySnapshot = async (
  options: PlaymeshHistoryMaterializeOptions
): Promise<PlaymeshHistoryMaterializedSnapshot> => {
  const {
    gameId,
    snapshot,
    signal,
    validateResources = true,
    validateProject = true,
  } = options;
  const projectId = validateProjectId(gameId);
  const normalized = assertSnapshot(snapshot);
  if (normalized.version.gameId !== projectId) throw invalidResponse();
  const resources = await downloadRestoredResources(
    projectId,
    normalized.resources,
    signal,
    validateResources
  );
  if (validateProject) validateRestoredProject(normalized.project, resources);
  return {
    version: normalized.version,
    project: normalized.project,
    resources,
  };
};

export const loadPlaymeshHistoryCurrentProject = async (
  gameId: string,
  signal?: AbortSignal
): Promise<?PlaymeshHistoryMaterializedSnapshot> => {
  const projectId = validateProjectId(gameId);
  const response: any = await requestJson(
    `${historyBase(projectId)}/current`,
    { signal }
  );
  const current: any = response && response.current;
  if (current == null) return null;
  const revision = current.version && current.version.revision;
  if (Number.isSafeInteger(revision)) knownRevisions.set(projectId, revision);
  const resources = await downloadRestoredResources(
    projectId,
    current.resources,
    signal,
    false
  );
  // MainFrame owns normal-open validation: it creates a fresh gd.Project and
  // unserializes before replacing the current editor state. PlayMesh only
  // materializes the resource bytes and does not gate on current manifest
  // semantics, resource size/hash, or a duplicate temporary unserialization.
  return {
    version: current.version,
    project: current.project,
    resources,
  };
};

const validateTargetRevision = (value: mixed): number => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    throw new PlaymeshHistoryError(
      'invalid_target_revision',
      '本地历史目标修订无效。'
    );
  }
  return value;
};

const assertRestoreResponse = (
  value: mixed
): {|
  gameId: string,
  restored: PlaymeshHistorySnapshot,
  backupVersion: ?PlaymeshHistoryVersion,
|} => {
  const response = asMixedRecord(value);
  if (!response || typeof response.gameId !== 'string') {
    throw invalidResponse();
  }
  return {
    gameId: response.gameId,
    restored: assertSnapshot(response.restored),
    backupVersion:
      response.backupVersion == null
        ? null
        : assertHistoryVersion(response.backupVersion),
  };
};

const executeRestorePlaymeshHistory = async ({
  gameId,
  targetRevision,
  source,
  currentSnapshot,
  signal,
}: ExecutePlaymeshHistoryRestoreOptions): Promise<PlaymeshHistoryRestoreResult> => {
  const preparedCurrent = await preparePlaymeshHistorySnapshot(currentSnapshot);
  await uploadMissingPlaymeshHistoryResources(
    gameId,
    preparedCurrent.resources,
    signal
  );
  const baseRevision = await ensureKnownPlaymeshHistoryRevision(gameId, signal);
  const response = assertRestoreResponse(
    await requestJson(
      `${historyBase(gameId)}/restore`,
      jsonRequest(
        'POST',
        {
          baseRevision,
          targetRevision,
          source,
          currentProject: preparedCurrent.project,
          currentResources: preparedCurrent.resources.map(
            toPlaymeshHistoryResourceDto
          ),
        },
        signal
      )
    )
  );
  if (response.gameId !== gameId) throw invalidResponse();
  const restored = response.restored;
  const resources = await downloadRestoredResources(
    gameId,
    restored.resources,
    signal
  );
  validateRestoredProject(restored.project, resources);
  knownRevisions.set(gameId, restored.version.revision);
  return {
    version: restored.version,
    project: restored.project,
    resources,
    backupVersion: response.backupVersion,
  };
};

export const restorePlaymeshHistory = (
  options: PlaymeshHistoryRestoreOptions
): Promise<PlaymeshHistoryRestoreResult> => {
  const gameId = validateProjectId(options.gameId);
  const targetRevision = validateTargetRevision(options.targetRevision);
  const source = validateRequestedHistorySource(options.source || 'user');
  const execute = (): Promise<PlaymeshHistoryRestoreResult> =>
    executeRestorePlaymeshHistory({
      gameId,
      targetRevision,
      source,
      currentSnapshot: options.currentSnapshot,
      signal: options.signal,
    });
  if (options.mutationLease) {
    const lease = assertPlaymeshProjectMutationLease(options.mutationLease);
    if (lease.gameId !== gameId) {
      throw new PlaymeshHistoryError(
        'mutation_lease_mismatch',
        '历史恢复事务与当前项目不匹配。'
      );
    }
    return execute();
  }
  return runPlaymeshProjectMutation({
    gameId,
    owner: 'history-restore',
    operation: execute,
  });
};

const assertHistoryDiff = (value: mixed): PlaymeshHistoryDiff => {
  const response = asMixedRecord(value);
  const summary = response ? asMixedRecord(response.summary) : null;
  const resources = summary ? asMixedRecord(summary.resources) : null;
  const resourceEvidence = response
    ? asMixedRecord(response.resourceEvidence)
    : null;
  const beforeResources = resourceEvidence ? resourceEvidence.before : null;
  const afterResources = resourceEvidence ? resourceEvidence.after : null;
  if (
    !response ||
    typeof response.gameId !== 'string' ||
    !summary ||
    !resources ||
    !Array.isArray(beforeResources) ||
    !Array.isArray(afterResources)
  ) {
    throw invalidResponse();
  }
  return {
    gameId: response.gameId,
    fromRevision: requireSafeInteger(response.fromRevision),
    toRevision: requireSafeInteger(response.toRevision),
    changed: requireBoolean(response.changed),
    before: requireString(response.before),
    after: requireString(response.after),
    summary: {
      addedLines: requireSafeInteger(summary.addedLines),
      removedLines: requireSafeInteger(summary.removedLines),
      resources: {
        added: requireSafeInteger(resources.added),
        removed: requireSafeInteger(resources.removed),
        changed: requireSafeInteger(resources.changed),
      },
    },
    resourceEvidence: {
      before: beforeResources.map((resource: mixed) =>
        assertResourceDto(resource)
      ),
      after: afterResources.map((resource: mixed) =>
        assertResourceDto(resource)
      ),
    },
  };
};

export const getPlaymeshHistoryResourcePreview = (
  diff: PlaymeshHistoryDiff,
  side: 'before' | 'after',
  logicalId: ?string
): ?PlaymeshHistoryResourcePreview => {
  if (typeof logicalId !== 'string' || !logicalId) return null;
  const revision = side === 'before' ? diff.fromRevision : diff.toRevision;
  const resource = diff.resourceEvidence[side].find(
    item => item.logicalId === logicalId
  );
  if (!resource) return null;
  const kind = previewKindForMime(resource.mime);
  if (!kind) return null;
  return {
    side,
    revision,
    logicalId: resource.logicalId,
    name: resource.name || null,
    contentHash: resource.contentHash,
    mime: resource.mime,
    size: resource.size,
    kind,
    url: `${historyBase(diff.gameId)}/revisions/${encodeURIComponent(
      String(revision)
    )}/resources/${resource.contentHash}?logicalId=${encodeURIComponent(
      resource.logicalId
    )}`,
  };
};

export const getPlaymeshHistoryDiff = async (
  gameId: string,
  fromRevision: number,
  toRevision: number,
  signal?: AbortSignal
): Promise<PlaymeshHistoryDiff> => {
  const projectId = validateProjectId(gameId);
  const from = validateTargetRevision(fromRevision);
  const to = validateTargetRevision(toRevision);
  const response = assertHistoryDiff(
    await requestJson(
      `${historyBase(projectId)}/diff?fromRevision=${encodeURIComponent(
        String(from)
      )}&toRevision=${encodeURIComponent(String(to))}`,
      { signal }
    )
  );
  if (
    response.gameId !== projectId ||
    response.fromRevision !== from ||
    response.toRevision !== to
  ) {
    throw invalidResponse();
  }
  return response;
};
