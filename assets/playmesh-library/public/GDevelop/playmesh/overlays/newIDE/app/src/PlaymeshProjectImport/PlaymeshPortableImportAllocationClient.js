// @flow

const BASE_URL = '/dev/api/gdevelop/project-allocation-transactions';
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_RESPONSE_BYTES = 256 * 1024;
const MAX_PREPARE_BYTES = 64 * 1024;
const MAX_RESOURCE_PLAN_BYTES = 2 * 1024 * 1024;
const MAX_FINALIZE_BYTES = 8 * 1024;
const MAX_EMPTY_BODY_BYTES = 1024;

const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const GAME_ID_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)+$/;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const PROJECT_CONFIG_SCHEMA_VERSION = 2;
const PROJECT_CONFIG_MAXIMUM_PLAYERS = 64;
const PROJECT_CONFIG_MAXIMUM_TAGS = 5;
const PROJECT_CONFIG_MAXIMUM_TAG_LENGTH = 64;
const PHASES = new Set([
  'PREPARED',
  'WORKSPACE_FINALIZED',
  'COMMIT_REQUESTED',
  'COMMITTED',
  'CONFLICT',
  'ABORTED',
]);
const ORIGINS = new Set(['create', 'import', 'copy']);
const PREPARE_CONFLICT_CODES = new Set([
  'project_id_conflict',
  'gdevelop_project_mutation_locked',
  'gdevelop_allocation_unavailable',
  'gdevelop_allocation_idempotency_conflict',
]);

export class PlaymeshPortableImportAllocationRequestError extends Error {
  /*:: code: string; status: number; details: mixed; requestId: ?string; operation: ?string; */

  constructor(
    code /*: string */,
    message /*: string */,
    status /*: number */,
    details /*: mixed */ = null
  ) {
    super(message);
    this.name = 'PlaymeshPortableImportAllocationRequestError';
    this.code = code;
    this.status = status;
    this.details = details;
    const envelope = asRecord(details);
    this.requestId =
      envelope && typeof envelope.requestId === 'string'
        ? envelope.requestId
        : null;
    this.operation =
      envelope && typeof envelope.operation === 'string'
        ? envelope.operation
        : null;
  }
}

const invalidResponse = () /*: empty */ => {
  throw new PlaymeshPortableImportAllocationRequestError(
    'invalid_response',
    'GDevelop allocation response is invalid.',
    0
  );
};

const asRecord = (value /*: mixed */) /*: ?Object */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const hasExactKeys = (
  value /*: Object */,
  keys /*: Array<string> */
) /*: boolean */ => {
  const actual = Object.keys(value);
  return (
    actual.length === keys.length && actual.every(key => keys.includes(key))
  );
};

const hasAllowedKeys = (
  value /*: Object */,
  required /*: Array<string> */,
  allowed /*: Array<string> */
) /*: boolean */ =>
  required.every(key => key in value) &&
  Object.keys(value).every(key => allowed.includes(key));

const requireToken = (value /*: mixed */) /*: string */ => {
  if (typeof value === 'string' && TOKEN_PATTERN.test(value)) {
    return value;
  }
  return invalidResponse();
};

const requireGameId = (value /*: mixed */) /*: string */ => {
  if (
    typeof value === 'string' &&
    value.length <= 180 &&
    GAME_ID_PATTERN.test(value)
  ) {
    return value;
  }
  return invalidResponse();
};

const requireHash = (value /*: mixed */) /*: string */ => {
  if (typeof value === 'string' && HASH_PATTERN.test(value)) {
    return value;
  }
  return invalidResponse();
};

const requireName = (value /*: mixed */) /*: string */ => {
  if (
    typeof value === 'string' &&
    value === value.trim() &&
    value.length >= 1 &&
    value.length <= 80 &&
    !/[\u0000-\u001f\u007f]/.test(value)
  ) {
    return value;
  }
  return invalidResponse();
};

const requireString = (
  value /*: mixed */,
  maximumLength /*: number */
) /*: string */ => {
  if (
    typeof value === 'string' &&
    !!value &&
    value.length <= maximumLength &&
    !/[\u0000-\u001f\u007f]/.test(value)
  ) {
    return value;
  }
  return invalidResponse();
};

const requirePositiveInteger = (value /*: mixed */) /*: number */ => {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 1) {
    return value;
  }
  return invalidResponse();
};

const requireTimestamp = (value /*: mixed */) /*: string */ => {
  if (
    typeof value === 'string' &&
    !!value &&
    Number.isFinite(Date.parse(value))
  ) {
    return value;
  }
  return invalidResponse();
};

const assertWorkspaceTarget = (value /*: mixed */) /*: Object */ => {
  const target = asRecord(value);
  const keys = [
    'fileIdentifier',
    'gameId',
    'packageName',
    'projectUuid',
    'projectFilesHash',
    'resourceManifestHash',
  ];
  if (!target || !hasExactKeys(target, keys)) return invalidResponse();
  const gameId = requireGameId(target.gameId);
  const packageName = requireGameId(target.packageName);
  if (gameId !== packageName) return invalidResponse();
  return {
    fileIdentifier: requireToken(target.fileIdentifier),
    gameId,
    packageName,
    projectUuid: requireToken(target.projectUuid),
    projectFilesHash: requireHash(target.projectFilesHash),
    resourceManifestHash: requireHash(target.resourceManifestHash),
  };
};

const assertSameTarget = (
  actual /*: Object */,
  expected /*: Object */
) /*: void */ => {
  for (const key of [
    'fileIdentifier',
    'gameId',
    'packageName',
    'projectUuid',
    'projectFilesHash',
    'resourceManifestHash',
  ]) {
    if (actual[key] !== expected[key]) return invalidResponse();
  }
};

const assertResourceDescriptor = (value /*: mixed */) /*: Object */ => {
  const resource = asRecord(value);
  const required = ['logicalId', 'name', 'contentHash', 'mime', 'size'];
  const allowed = [...required, 'metadata'];
  if (!resource || !hasAllowedKeys(resource, required, allowed))
    return invalidResponse();
  const metadata =
    resource.metadata === undefined ? null : asRecord(resource.metadata);
  if (resource.metadata !== undefined && !metadata) return invalidResponse();
  return {
    logicalId: requireString(resource.logicalId, 1024),
    name: requireString(resource.name, 255),
    contentHash: requireHash(resource.contentHash),
    mime: requireString(resource.mime, 128),
    size: requirePositiveInteger(resource.size),
    ...(metadata ? { metadata: { ...metadata } } : {}),
  };
};

const assertResourcePlan = (value /*: mixed */) /*: Array<Object> */ => {
  if (!Array.isArray(value) || value.length > 2048) return invalidResponse();
  const resources = value.map(assertResourceDescriptor);
  const logicalIds = new Set(resources.map(resource => resource.logicalId));
  if (logicalIds.size !== resources.length) return invalidResponse();
  return resources;
};

const assertWorkspaceProject = (value /*: mixed */) /*: Object */ => {
  const project = asRecord(value);
  const keys = [
    'packageName',
    'projectUuid',
    'projectFilesHash',
    'projectFilesSize',
    'resourceReferences',
  ];
  if (!project || !hasExactKeys(project, keys)) return invalidResponse();
  if (!Array.isArray(project.resourceReferences)) return invalidResponse();
  const references = project.resourceReferences.map(raw => {
    const reference = asRecord(raw);
    if (!reference || !hasExactKeys(reference, ['logicalId', 'name']))
      return invalidResponse();
    return {
      logicalId: requireString(reference.logicalId, 1024),
      name: requireString(reference.name, 255),
    };
  });
  if (
    new Set(references.map(item => item.logicalId)).size !== references.length
  )
    return invalidResponse();
  return {
    packageName: requireGameId(project.packageName),
    projectUuid: requireToken(project.projectUuid),
    projectFilesHash: requireHash(project.projectFilesHash),
    projectFilesSize: requirePositiveInteger(project.projectFilesSize),
    resourceReferences: references,
  };
};

const assertWorkspaceFinalization = (value /*: mixed */) /*: Object */ => {
  const evidence = asRecord(value);
  const keys = [
    'packageName',
    'projectUuid',
    'projectFilesHash',
    'projectFilesSize',
    'resourceManifestHash',
  ];
  if (!evidence || !hasExactKeys(evidence, keys)) return invalidResponse();
  return {
    packageName: requireGameId(evidence.packageName),
    projectUuid: requireToken(evidence.projectUuid),
    projectFilesHash: requireHash(evidence.projectFilesHash),
    projectFilesSize: requirePositiveInteger(evidence.projectFilesSize),
    resourceManifestHash: requireHash(evidence.resourceManifestHash),
  };
};

const assertReadyConfigEvidence = (
  value /*: mixed */,
  gameId /*: string */
) /*: Object */ => {
  const evidence = asRecord(value);
  if (
    !evidence ||
    !hasExactKeys(evidence, ['status', 'revision', 'contentHash', 'config']) ||
    evidence.status !== 'ready' ||
    evidence.revision !== 1
  ) {
    return invalidResponse();
  }
  const config = asRecord(evidence.config);
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
    config.schemaVersion !== PROJECT_CONFIG_SCHEMA_VERSION ||
    config.gameId !== gameId ||
    config.revision !== 1 ||
    (config.gameType !== 'single' && config.gameType !== 'online') ||
    !Number.isSafeInteger(config.minPlayers) ||
    !Number.isSafeInteger(config.maxPlayers) ||
    config.minPlayers < 1 ||
    config.maxPlayers < config.minPlayers ||
    config.maxPlayers > PROJECT_CONFIG_MAXIMUM_PLAYERS ||
    (config.gameType === 'single' &&
      (config.minPlayers !== 1 || config.maxPlayers !== 1)) ||
    !Array.isArray(config.tags) ||
    config.tags.length > PROJECT_CONFIG_MAXIMUM_TAGS
  ) {
    return invalidResponse();
  }
  const tags = config.tags.map(tag => {
    const normalized = requireString(tag, PROJECT_CONFIG_MAXIMUM_TAG_LENGTH);
    if (normalized !== normalized.trim()) return invalidResponse();
    return normalized;
  });
  if (new Set(tags).size !== tags.length) return invalidResponse();
  return {
    status: 'ready',
    revision: 1,
    contentHash: requireHash(evidence.contentHash),
    config: {
      schemaVersion: PROJECT_CONFIG_SCHEMA_VERSION,
      gameId,
      revision: 1,
      gameType: config.gameType,
      minPlayers: config.minPlayers,
      maxPlayers: config.maxPlayers,
      tags,
      updatedAt: requireTimestamp(config.updatedAt),
    },
  };
};

const assertAllocationEvidence = (
  value /*: mixed */,
  gameId /*: string */
) /*: Object */ => {
  const evidence = asRecord(value);
  if (!evidence || !hasExactKeys(evidence, ['projectMetadataHash', 'config'])) {
    return invalidResponse();
  }
  return {
    projectMetadataHash: requireHash(evidence.projectMetadataHash),
    config: assertReadyConfigEvidence(evidence.config, gameId),
  };
};

const assertConflict = (value /*: mixed */) /*: Object */ => {
  const conflict = asRecord(value);
  if (
    !conflict ||
    !hasExactKeys(conflict, ['reason', 'observedAt']) ||
    typeof conflict.reason !== 'string' ||
    !conflict.reason
  ) {
    return invalidResponse();
  }
  return {
    reason: conflict.reason,
    observedAt: requireTimestamp(conflict.observedAt),
  };
};

const assertTransaction = (
  value /*: mixed */,
  expected /*: Object */
) /*: Object */ => {
  const transaction = asRecord(value);
  const keys = [
    'txId',
    'idempotencyKey',
    'gameId',
    'origin',
    'phase',
    'name',
    'clientId',
    'workspaceTarget',
    'allocationEvidence',
    'resourcePlan',
    'createdAt',
    'updatedAt',
    'expiresAt',
    'retainedUntil',
    'workspaceProject',
    'workspaceFinalization',
    'conflict',
  ];
  if (!transaction || !hasExactKeys(transaction, keys))
    return invalidResponse();
  if (
    typeof transaction.phase !== 'string' ||
    !PHASES.has(transaction.phase) ||
    transaction.idempotencyKey !== expected.idempotencyKey ||
    transaction.origin !== expected.origin ||
    transaction.name !== expected.name ||
    transaction.clientId !== expected.clientId
  ) {
    return invalidResponse();
  }
  const gameId = requireGameId(transaction.gameId);
  if (gameId !== expected.target.gameId) return invalidResponse();
  const workspaceTarget = assertWorkspaceTarget(transaction.workspaceTarget);
  assertSameTarget(workspaceTarget, expected.target);
  const workspaceProject =
    transaction.workspaceProject === null
      ? null
      : assertWorkspaceProject(transaction.workspaceProject);
  const workspaceFinalization =
    transaction.workspaceFinalization === null
      ? null
      : assertWorkspaceFinalization(transaction.workspaceFinalization);
  if (workspaceProject) {
    if (
      workspaceProject.packageName !== workspaceTarget.packageName ||
      workspaceProject.projectUuid !== workspaceTarget.projectUuid ||
      workspaceProject.projectFilesHash !== workspaceTarget.projectFilesHash
    ) {
      return invalidResponse();
    }
  }
  if (workspaceFinalization) {
    if (
      !workspaceProject ||
      workspaceFinalization.packageName !== workspaceTarget.packageName ||
      workspaceFinalization.projectUuid !== workspaceTarget.projectUuid ||
      workspaceFinalization.projectFilesHash !==
        workspaceTarget.projectFilesHash ||
      workspaceFinalization.resourceManifestHash !==
        workspaceTarget.resourceManifestHash
    ) {
      return invalidResponse();
    }
  }
  return {
    txId: requireToken(transaction.txId),
    idempotencyKey: transaction.idempotencyKey,
    gameId,
    origin: transaction.origin,
    phase: transaction.phase,
    name: transaction.name,
    clientId: transaction.clientId,
    workspaceTarget,
    allocationEvidence: assertAllocationEvidence(
      transaction.allocationEvidence,
      gameId
    ),
    resourcePlan: assertResourcePlan(transaction.resourcePlan),
    createdAt: requireTimestamp(transaction.createdAt),
    updatedAt: requireTimestamp(transaction.updatedAt),
    expiresAt:
      transaction.expiresAt === null
        ? null
        : requireTimestamp(transaction.expiresAt),
    retainedUntil:
      transaction.retainedUntil === null
        ? null
        : requireTimestamp(transaction.retainedUntil),
    workspaceProject,
    workspaceFinalization,
    conflict:
      transaction.conflict === null
        ? null
        : assertConflict(transaction.conflict),
  };
};

const assertEnvelope = (
  value /*: mixed */,
  expected /*: Object */
) /*: Object */ => {
  const envelope = asRecord(value);
  if (!envelope || !hasExactKeys(envelope, ['requestId', 'transaction'])) {
    return invalidResponse();
  }
  return {
    requestId: requireToken(envelope.requestId),
    transaction: assertTransaction(envelope.transaction, expected),
  };
};

const assertCasReference = (value /*: mixed */) /*: Object */ => {
  const reference = asRecord(value);
  if (!reference || !hasExactKeys(reference, ['hash', 'bytes'])) {
    return invalidResponse();
  }
  return {
    hash: requireHash(reference.hash),
    bytes: requirePositiveInteger(reference.bytes),
  };
};

const assertProjectReference = (value /*: mixed */) /*: Object */ => {
  const reference = asRecord(value);
  if (!reference || !hasExactKeys(reference, ['contentHash', 'size'])) {
    return invalidResponse();
  }
  return {
    contentHash: requireHash(reference.contentHash),
    size: requirePositiveInteger(reference.size),
  };
};

const readBoundedJson = async (
  response /*: Response */
) /*: Promise<mixed> */ => {
  const declared = response.headers.get('content-length');
  if (declared !== null) {
    const parsed = Number(declared);
    if (
      !Number.isSafeInteger(parsed) ||
      parsed < 0 ||
      parsed > MAX_RESPONSE_BYTES
    ) {
      return invalidResponse();
    }
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > MAX_RESPONSE_BYTES) return invalidResponse();
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (_) {
    return invalidResponse();
  }
};

const explicitErrorCode = (payload /*: mixed */) /*: ?string */ => {
  const envelope = asRecord(payload);
  const error = envelope && asRecord(envelope.error);
  return error && typeof error.code === 'string' && error.code
    ? error.code
    : null;
};

const requestError = (
  status /*: number */,
  payload /*: mixed */,
  response /*: ?Response */ = null,
  fallbackOperation /*: ?string */ = null
) /*: PlaymeshPortableImportAllocationRequestError */ => {
  const envelope = asRecord(payload);
  const error = envelope && asRecord(envelope.error);
  const code =
    error && typeof error.code === 'string' && error.code
      ? error.code
      : status === 0
      ? 'allocation_network_error'
      : 'allocation_request_failed';
  const message =
    error && typeof error.message === 'string' && error.message
      ? error.message
      : 'GDevelop allocation request failed.';
  const requestId =
    (response && response.headers.get('X-Request-ID')) ||
    (envelope && typeof envelope.requestId === 'string'
      ? envelope.requestId
      : null);
  const operation =
    (response && response.headers.get('X-Playmesh-Operation-ID')) ||
    fallbackOperation;
  const details /*: any */ = error ? { ...error } : {};
  if (envelope && typeof envelope.requestId === 'string') {
    details.requestId = envelope.requestId;
  }
  if (requestId) details.requestId = requestId;
  if (operation) details.operation = operation;
  return new PlaymeshPortableImportAllocationRequestError(
    code,
    message,
    status,
    details
  );
};

const operationForRequest = (
  method /*: string */,
  url /*: string */
) /*: string */ => {
  if (url === BASE_URL && method === 'POST') {
    return 'gdevelop.project.allocation.prepare';
  }
  if (url.endsWith('/resources/presence')) {
    return 'gdevelop.project.allocation.resources.presence';
  }
  if (/\/resources\/[a-f0-9]{64}$/.test(url) && method === 'PUT') {
    return 'gdevelop.project.allocation.resource.put';
  }
  if (url.endsWith('/workspace/project-files')) {
    return 'gdevelop.project.allocation.workspace.project-files.put';
  }
  if (url.endsWith('/workspace/finalize')) {
    return 'gdevelop.project.allocation.workspace.finalize';
  }
  if (url.endsWith('/commit')) return 'gdevelop.project.allocation.commit';
  if (url.endsWith('/recover')) return 'gdevelop.project.allocation.recover';
  if (url.endsWith('/abort')) return 'gdevelop.project.allocation.abort';
  return 'gdevelop.project.allocation.status';
};

const encodeBody = (
  value /*: Object */,
  maximumBytes /*: number */
) /*: string */ => {
  const body = JSON.stringify(value);
  if (new TextEncoder().encode(body).byteLength > maximumBytes) {
    throw new PlaymeshPortableImportAllocationRequestError(
      'request_too_large',
      'GDevelop allocation request is too large.',
      0
    );
  }
  return body;
};

const normalizePortInput = (
  value /*: mixed */,
  configuredClientId /*: ?string */
) /*: Object */ => {
  const input = asRecord(value);
  if (!input || typeof input.origin !== 'string' || !ORIGINS.has(input.origin))
    return invalidResponse();
  const target = assertWorkspaceTarget(input.target);
  const requestName = input.name === undefined ? null : requireName(input.name);
  const clientId =
    configuredClientId === null || configuredClientId === undefined
      ? null
      : requireToken(configuredClientId);
  return {
    idempotencyKey: requireToken(input.idempotencyKey),
    transactionId:
      input.transactionId === null || input.transactionId === undefined
        ? null
        : requireToken(input.transactionId),
    origin: input.origin,
    name: requestName === null ? target.gameId : requestName,
    requestName,
    clientId,
    target,
  };
};

const toPortState = (transaction /*: Object */) /*: Object */ => ({
  phase: transaction.phase,
  transactionId: transaction.txId,
  ...(transaction.conflict ? { conflict: transaction.conflict } : {}),
});

const fetchFromWindow = () /*: any */ => {
  if (typeof window === 'undefined' || typeof window.fetch !== 'function') {
    throw new PlaymeshPortableImportAllocationRequestError(
      'fetch_unavailable',
      'Fetch is unavailable.',
      0
    );
  }
  return window.fetch.bind(window);
};

export const createPlaymeshPortableImportAllocationClient = ({
  fetchImpl = null,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  clientId = null,
} /*: Object */ = {}) /*: Object */ => {
  // 默认实例会在模块加载时创建；延迟解析 window.fetch，保证 Node 测试和
  // 服务端静态分析不会因为没有浏览器全局对象而失败。
  const fetchImplementation = fetchImpl;
  if (
    (fetchImplementation !== null &&
      typeof fetchImplementation !== 'function') ||
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1
  ) {
    throw new TypeError('Invalid GDevelop allocation client configuration.');
  }
  const configuredClientId = clientId === null ? null : requireToken(clientId);

  const send = async (
    { url, method, body, contentType } /*: Object */
  ) /*: Promise<Object> */ => {
    const actualFetch = fetchImplementation || fetchFromWindow();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const operation = operationForRequest(method, url);
    try {
      let response;
      try {
        const requestOptions /*: any */ = {
          method,
          credentials: 'same-origin',
          cache: 'no-store',
          signal: controller.signal,
        };
        if (body !== null && body !== undefined) requestOptions.body = body;
        if (contentType) {
          requestOptions.headers = { 'Content-Type': contentType };
        }
        response = await actualFetch(url, requestOptions);
      } catch (error) {
        throw new PlaymeshPortableImportAllocationRequestError(
          controller.signal.aborted
            ? 'allocation_request_timeout'
            : 'allocation_network_error',
          controller.signal.aborted
            ? 'GDevelop allocation request timed out.'
            : 'GDevelop allocation request failed.',
          0,
          { operation }
        );
      }
      return {
        response,
        payload: await readBoundedJson(response),
        operation,
      };
    } finally {
      clearTimeout(timeout);
    }
  };

  const prepareBody = (input /*: Object */) /*: Object */ => {
    const body /*: Object */ = {
      idempotencyKey: input.idempotencyKey,
      gameId: input.target.gameId,
      origin: input.origin,
      workspaceTarget: input.target,
    };
    if (input.requestName !== null) body.name = input.requestName;
    if (input.clientId !== null) body.clientId = input.clientId;
    return body;
  };

  const parseTransactionResponse = (
    response /*: Response */,
    payload /*: mixed */,
    input /*: Object */,
    allowedStatuses /*: Array<number> */,
    operation /*: ?string */ = null
  ) /*: Object */ => {
    if (!allowedStatuses.includes(response.status)) {
      throw requestError(response.status, payload, response, operation);
    }
    // 错误信封不能伪装成成功的事务信封；稳定错误码优先返回给调用方。
    if (response.status === 409 && explicitErrorCode(payload) !== null) {
      throw requestError(response.status, payload, response, operation);
    }
    const transaction = assertEnvelope(payload, input).transaction;
    if (
      (response.status === 202 && transaction.phase !== 'COMMIT_REQUESTED') ||
      (response.status === 409 && transaction.phase !== 'CONFLICT')
    ) {
      return invalidResponse();
    }
    return transaction;
  };

  const prepareNormalized = async (
    input /*: Object */
  ) /*: Promise<Object> */ => {
    const { response, payload, operation } = await send({
      url: BASE_URL,
      method: 'POST',
      body: encodeBody(prepareBody(input), MAX_PREPARE_BYTES),
      contentType: 'application/json; charset=utf-8',
    });
    if (response.status === 409) {
      const envelope = asRecord(payload);
      if (envelope && 'transaction' in envelope) {
        return toPortState(
          parseTransactionResponse(response, payload, input, [409], operation)
        );
      }
      const code = explicitErrorCode(payload);
      if (code && PREPARE_CONFLICT_CODES.has(code)) {
        return { phase: 'CONFLICT', transactionId: null };
      }
      throw requestError(response.status, payload, response, operation);
    }
    if (response.status !== 201) {
      throw requestError(response.status, payload, response, operation);
    }
    return toPortState(assertEnvelope(payload, input).transaction);
  };

  const requireTransactionInput = (value /*: mixed */) /*: Object */ => {
    const input = normalizePortInput(value, configuredClientId);
    if (!input.transactionId) return invalidResponse();
    return input;
  };

  const transactionPost = async (
    value /*: mixed */,
    suffix /*: string */,
    bodyValue /*: Object */,
    maximumBytes /*: number */,
    allowedStatuses /*: Array<number> */ = [200, 202, 409]
  ) /*: Promise<Object> */ => {
    const input = requireTransactionInput(value);
    const { response, payload, operation } = await send({
      url: `${BASE_URL}/${encodeURIComponent(input.transactionId)}/${suffix}`,
      method: 'POST',
      body: encodeBody(bodyValue, maximumBytes),
      contentType: 'application/json; charset=utf-8',
    });
    return toPortState(
      parseTransactionResponse(
        response,
        payload,
        input,
        allowedStatuses,
        operation
      )
    );
  };

  return {
    prepare: value =>
      prepareNormalized(normalizePortInput(value, configuredClientId)),

    getStatus: async value => {
      const input = normalizePortInput(value, configuredClientId);
      if (!input.transactionId) return prepareNormalized(input);
      const { response, payload, operation } = await send({
        url: `${BASE_URL}/${encodeURIComponent(input.transactionId)}`,
        method: 'GET',
        body: null,
        contentType: null,
      });
      if (
        response.status === 404 &&
        explicitErrorCode(payload) === 'gdevelop_allocation_not_found'
      ) {
        const envelope = asRecord(payload);
        if (!envelope || typeof envelope.requestId !== 'string') {
          throw requestError(response.status, payload, response, operation);
        }
        return { phase: 'NOT_FOUND', transactionId: null };
      }
      if (response.status !== 200) {
        throw requestError(response.status, payload, response, operation);
      }
      return toPortState(assertEnvelope(payload, input).transaction);
    },

    resourcePresence: async (value, resources) => {
      const input = requireTransactionInput(value);
      const normalizedResources = assertResourcePlan(resources);
      const { response, payload, operation } = await send({
        url: `${BASE_URL}/${encodeURIComponent(
          input.transactionId
        )}/resources/presence`,
        method: 'POST',
        body: encodeBody(
          { resources: normalizedResources },
          MAX_RESOURCE_PLAN_BYTES
        ),
        contentType: 'application/json; charset=utf-8',
      });
      if (response.status !== 200) {
        throw requestError(response.status, payload, response, operation);
      }
      const envelope = asRecord(payload);
      if (
        !envelope ||
        !hasExactKeys(envelope, [
          'requestId',
          'transaction',
          'missing',
          'available',
        ]) ||
        !Array.isArray(envelope.missing) ||
        !Array.isArray(envelope.available)
      ) {
        return invalidResponse();
      }
      requireToken(envelope.requestId);
      const transaction = assertTransaction(envelope.transaction, input);
      return {
        ...toPortState(transaction),
        missing: envelope.missing.map(assertCasReference),
        available: envelope.available.map(assertCasReference),
      };
    },

    uploadResource: async (value, upload) => {
      const input = requireTransactionInput(value);
      const body = asRecord(upload);
      if (!body || !hasExactKeys(body, ['contentHash', 'blob']))
        return invalidResponse();
      const contentHash = requireHash(body.contentHash);
      if (!(body.blob instanceof Blob) || body.blob.size < 1)
        return invalidResponse();
      const { response, payload, operation } = await send({
        url: `${BASE_URL}/${encodeURIComponent(
          input.transactionId
        )}/resources/${contentHash}`,
        method: 'PUT',
        body: body.blob,
        contentType: body.blob.type || 'application/octet-stream',
      });
      if (response.status !== 200) {
        throw requestError(response.status, payload, response, operation);
      }
      const envelope = asRecord(payload);
      if (!envelope || !hasExactKeys(envelope, ['requestId', 'resource'])) {
        return invalidResponse();
      }
      requireToken(envelope.requestId);
      const reference = assertCasReference(envelope.resource);
      if (
        reference.hash !== contentHash ||
        reference.bytes !== body.blob.size
      ) {
        return invalidResponse();
      }
      return reference;
    },

    uploadProjectFiles: async (value, projectFilesJson) => {
      const input = requireTransactionInput(value);
      if (typeof projectFilesJson !== 'string' || !projectFilesJson)
        return invalidResponse();
      const blob = new Blob([projectFilesJson], {
        type: 'application/json; charset=utf-8',
      });
      const { response, payload, operation } = await send({
        url: `${BASE_URL}/${encodeURIComponent(
          input.transactionId
        )}/workspace/project-files`,
        method: 'PUT',
        body: blob,
        contentType: 'application/json; charset=utf-8',
      });
      if (response.status !== 200) {
        throw requestError(response.status, payload, response, operation);
      }
      const envelope = asRecord(payload);
      if (!envelope || !hasExactKeys(envelope, ['requestId', 'project'])) {
        return invalidResponse();
      }
      requireToken(envelope.requestId);
      const reference = assertProjectReference(envelope.project);
      if (
        reference.contentHash !== input.target.projectFilesHash ||
        reference.size !== blob.size
      ) {
        return invalidResponse();
      }
      return reference;
    },

    finalizeWorkspace: (value, evidence) => {
      const input = requireTransactionInput(value);
      const normalizedEvidence = assertWorkspaceFinalization(evidence);
      if (
        normalizedEvidence.packageName !== input.target.packageName ||
        normalizedEvidence.projectUuid !== input.target.projectUuid ||
        normalizedEvidence.projectFilesHash !== input.target.projectFilesHash ||
        normalizedEvidence.resourceManifestHash !==
          input.target.resourceManifestHash
      ) {
        return invalidResponse();
      }
      return transactionPost(
        input,
        'workspace/finalize',
        normalizedEvidence,
        MAX_FINALIZE_BYTES
      );
    },

    commit: value => transactionPost(value, 'commit', {}, MAX_EMPTY_BODY_BYTES),
    recover: value =>
      transactionPost(value, 'recover', {}, MAX_EMPTY_BODY_BYTES),
    abort: value =>
      transactionPost(value, 'abort', {}, MAX_EMPTY_BODY_BYTES, [200]),
  };
};

export const playmeshPortableImportAllocationClient /*: Object */ = createPlaymeshPortableImportAllocationClient();
