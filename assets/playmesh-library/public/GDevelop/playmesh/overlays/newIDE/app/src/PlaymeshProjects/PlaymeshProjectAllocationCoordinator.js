// @flow

import { playmeshPortableImportAllocationClient } from '../PlaymeshProjectImport/PlaymeshPortableImportAllocationClient';
import { sha256Hex as computeSha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';

/*::
type AllocationSnapshotResource = {|
  logicalUrl: string,
  name?: string,
  blob: Blob,
  contentHash: string,
  metadata?: Object,
|};

type AllocationSnapshot = {|
  project: Object,
  resources: Array<AllocationSnapshotResource>,
|};

type PendingTransaction = {|
  idempotencyKey: string,
  transactionId: ?string,
|};
*/

const pendingTransactions /*: Map<string, PendingTransaction> */ = new Map();

export class PlaymeshProjectAllocationError extends Error {
  /*:: code: string; status: number; details: mixed; requestId: ?string; operation: ?string; */

  constructor(
    code /*: string */,
    message /*: string */,
    status /*: number */ = 0,
    details /*: mixed */ = null
  ) {
    super(message);
    this.name = 'PlaymeshProjectAllocationError';
    this.code = code;
    this.status = status;
    this.details = details;
    const envelope =
      details && typeof details === 'object' && !Array.isArray(details)
        ? details
        : null;
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

const fail = (
  code /*: string */,
  message /*: string */,
  details /*: mixed */ = null
) /*: empty */ => {
  throw new PlaymeshProjectAllocationError(code, message, 0, details);
};

const wrapError = (error /*: mixed */) /*: PlaymeshProjectAllocationError */ => {
  if (error instanceof PlaymeshProjectAllocationError) return error;
  const raw /*: any */ = error;
  const details = raw && raw.details ? raw.details : null;
  const envelope /*: any */ =
    details && typeof details === 'object' && !Array.isArray(details)
      ? details
      : null;
  const requestId =
    envelope && typeof envelope.requestId === 'string'
      ? envelope.requestId
      : null;
  const code = raw && typeof raw.code === 'string' ? raw.code : 'allocation_failed';
  const status = raw && Number.isSafeInteger(raw.status) ? raw.status : 0;
  const suffix = requestId ? `（请求 ${requestId}）` : '';
  const fallback =
    status === 401 || status === 403
      ? 'Playmesh 开发者会话已失效，请关闭并重新打开可视化工作区。'
      : status === 404
      ? '当前 Playmesh 不支持 GDevelop 工程分配接口，请更新 App。'
      : status === 409
      ? '这个游戏标识已被另一个本地工程占用，请更换游戏标识后重试。'
      : code === 'allocation_network_error'
      ? '无法连接 Playmesh 本地开发网关。'
      : code === 'allocation_request_timeout'
      ? 'Playmesh 本地开发网关响应超时。'
      : code === 'invalid_response'
      ? 'Playmesh 本地开发网关返回了不兼容的工程分配响应。'
      : raw && typeof raw.message === 'string' && raw.message
      ? raw.message
      : 'Playmesh 无法创建本地 GDevelop 工程。';
  return new PlaymeshProjectAllocationError(
    code,
    `${fallback}${suffix}`,
    status,
    details
  );
};

const sha256Hex = async (
  value /*: Blob | Uint8Array | string */,
  cryptoImplementation /*: any */ = window.crypto
) /*: Promise<string> */ => {
  let bytes;
  if (value instanceof Blob) bytes = await value.arrayBuffer();
  else if (typeof value === 'string') bytes = new TextEncoder().encode(value);
  else bytes = value;
  return computeSha256Hex(bytes, cryptoImplementation);
};

const canonicalizeJson = (value /*: any */) /*: any */ => {
  if (Array.isArray(value)) return value.map(canonicalizeJson);
  if (value && typeof value === 'object') {
    const result = {};
    Object.keys(value)
      .sort()
      .forEach(key => {
        result[key] = canonicalizeJson(value[key]);
      });
    return result;
  }
  return value;
};

const orderResourcePlanByProjectReferences = (
  projectJson /*: string */,
  resourcePlan /*: Array<Object> */
) /*: Array<Object> */ => {
  let project /*: any */ = null;
  try {
    project = JSON.parse(projectJson);
  } catch (error) {
    fail('invalid_allocation_snapshot', 'GDevelop 工程必须是有效的 JSON。');
  }
  if (!project || typeof project !== 'object' || Array.isArray(project)) {
    fail('invalid_allocation_snapshot', 'GDevelop 工程 JSON 根必须是对象。');
  }
  const resourcesContainer = project.resources;
  if (resourcesContainer == null) {
    if (resourcePlan.length > 0) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源计划不完整。');
    }
    return [];
  }
  if (
    typeof resourcesContainer !== 'object' ||
    Array.isArray(resourcesContainer)
  ) {
    fail('invalid_allocation_snapshot', 'GDevelop 工程 resources 无效。');
  }
  const officialResources = resourcesContainer.resources;
  if (officialResources == null) {
    if (resourcePlan.length > 0) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源计划不完整。');
    }
    return [];
  }
  if (!Array.isArray(officialResources)) {
    fail(
      'invalid_allocation_snapshot',
      'GDevelop 工程 resources.resources 无效。'
    );
  }

  const byLogicalId /*: Map<string, Object> */ = new Map(
    resourcePlan.map(resource => [resource.logicalId, resource])
  );
  const ordered /*: Array<Object> */ = [];
  const referencedLogicalIds /*: Set<string> */ = new Set();
  for (const entry of officialResources) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程 resource 无效。');
    }
    if (typeof entry.file !== 'string') {
      fail('invalid_allocation_snapshot', 'GDevelop 工程 resource.file 无效。');
    }
    if (!entry.file.startsWith('playmesh-local-resource://')) continue;
    if (
      typeof entry.name !== 'string' ||
      referencedLogicalIds.has(entry.file)
    ) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源引用无效或重复。');
    }
    const resource = byLogicalId.get(entry.file);
    if (!resource || resource.name !== entry.name) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源计划不完整。');
    }
    referencedLogicalIds.add(entry.file);
    ordered.push(resource);
  }
  if (ordered.length !== resourcePlan.length) {
    fail('invalid_allocation_snapshot', 'GDevelop 工程资源计划不完整。');
  }
  return ordered;
};

export const createPlaymeshProjectAllocationEvidence = async ({
  projectJson,
  resources,
  cryptoImplementation = typeof window === 'undefined' ? null : window.crypto,
} /*: Object */) /*: Promise<Object> */ => {
  if (typeof projectJson !== 'string' || !projectJson || !Array.isArray(resources)) {
    fail('invalid_allocation_snapshot', 'GDevelop 工程分配快照无效。');
  }
  const logicalIds /*: Set<string> */ = new Set();
  const resourcePlan /*: Array<Object> */ = [];
  for (const resource of resources) {
    if (!resource || !(resource.blob instanceof Blob)) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源快照无效。');
    }
    const logicalId = String(resource.logicalUrl || '');
    const contentHash = String(resource.contentHash || '');
    if (!logicalId || logicalIds.has(logicalId) || !/^[a-f0-9]{64}$/.test(contentHash)) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源标识无效或重复。');
    }
    if ((await sha256Hex(resource.blob, cryptoImplementation)) !== contentHash) {
      fail('allocation_resource_hash_mismatch', 'GDevelop 工程资源内容哈希不一致。');
    }
    logicalIds.add(logicalId);
    resourcePlan.push({
      logicalId,
      name: String(resource.name || logicalId),
      contentHash,
      mime: resource.blob.type || 'application/octet-stream',
      size: resource.blob.size,
      ...(resource.metadata && typeof resource.metadata === 'object'
        ? { metadata: { ...resource.metadata } }
        : {}),
    });
    if (resource.blob.size < 1) {
      fail('invalid_allocation_snapshot', 'GDevelop 工程资源不能是空文件。');
    }
  }
  // App 会按 logicalId 规范化并持久化 resourcePlan，但 finalize 会按官方
  // project.resources.resources 的引用顺序重排资源，再计算 manifest。两个
  // 顺序承担不同合同，不能用 resourcePlan 的字典序替代官方引用顺序。
  resourcePlan.sort((left, right) =>
    left.logicalId.localeCompare(right.logicalId)
  );
  const resourceManifest = orderResourcePlanByProjectReferences(
    projectJson,
    resourcePlan
  );
  return {
    projectJsonHash: await sha256Hex(projectJson, cryptoImplementation),
    resourceManifestHash: await sha256Hex(
      JSON.stringify(canonicalizeJson(resourceManifest)),
      cryptoImplementation
    ),
    resourcePlan,
  };
};

const createId = () /*: string */ => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return window.crypto.randomUUID();
  }
  if (window.crypto && typeof window.crypto.getRandomValues === 'function') {
    const bytes = new Uint8Array(16);
    window.crypto.getRandomValues(bytes);
    return [...bytes]
      .map(value => value.toString(16).padStart(2, '0'))
      .join('');
  }
  return fail(
    'secure_random_unavailable',
    '当前浏览器无法生成安全的工程事务标识。'
  );
};

const requireState = (value /*: mixed */) /*: Object */ => {
  const state /*: any */ = value;
  if (
    !state ||
    typeof state !== 'object' ||
    ![
      'NOT_FOUND',
      'PREPARED',
      'WORKSPACE_FINALIZED',
      'COMMIT_REQUESTED',
      'COMMITTED',
      'CONFLICT',
      'ABORTED',
    ].includes(state.phase)
  ) {
    fail('invalid_response', 'Playmesh 返回了无效的工程事务状态。');
  }
  if (
    ['PREPARED', 'WORKSPACE_FINALIZED', 'COMMIT_REQUESTED', 'COMMITTED'].includes(
      state.phase
    ) &&
    !state.transactionId
  ) {
    fail('invalid_response', 'Playmesh 工程事务响应缺少 transactionId。');
  }
  return state;
};

const safeState = async (client /*: any */, input /*: Object */) => {
  try {
    return requireState(await client.getStatus(input));
  } catch (_) {
    return null;
  }
};

const abortBeforeCommit = async (client /*: any */, input /*: Object */) => {
  try {
    const state = requireState(await client.abort(input));
    if (state.phase === 'COMMIT_REQUESTED') await client.recover(input);
  } catch (_) {}
};

export const allocatePlaymeshProjectSnapshot = async ({
  fileIdentifier,
  gameId,
  name,
  origin,
  projectUuid,
  snapshot,
  allocationClient = playmeshPortableImportAllocationClient,
} /*: Object */) /*: Promise<Object> */ => {
  const projectJson = JSON.stringify(snapshot.project);
  const evidence = await createPlaymeshProjectAllocationEvidence({
    projectJson,
    resources: snapshot.resources,
  });
  const target = {
    fileIdentifier,
    gameId,
    packageName: gameId,
    projectUuid,
    projectJsonHash: evidence.projectJsonHash,
    resourceManifestHash: evidence.resourceManifestHash,
  };
  const pendingKey = `${gameId}\n${fileIdentifier}\n${evidence.projectJsonHash}\n${evidence.resourceManifestHash}`;
  const pending = pendingTransactions.get(pendingKey);
  const prepareInput = {
    idempotencyKey: (pending && pending.idempotencyKey) || createId(),
    origin: origin === 'duplicate' ? 'copy' : 'create',
    name,
    target,
  };
  pendingTransactions.set(pendingKey, {
    idempotencyKey: prepareInput.idempotencyKey,
    transactionId: pending ? pending.transactionId : null,
  });
  let state /*: any */;
  let input /*: Object */ = prepareInput;
  let commitAttempted = false;
  try {
    if (pending && pending.transactionId) {
      input = { ...prepareInput, transactionId: pending.transactionId };
      state = requireState(await allocationClient.getStatus(input));
    } else {
      try {
        state = requireState(await allocationClient.prepare(prepareInput));
      } catch (error) {
        state = await safeState(allocationClient, prepareInput);
        if (!state) throw error;
      }
    }
    if (state.phase === 'CONFLICT') {
      pendingTransactions.delete(pendingKey);
      throw new PlaymeshProjectAllocationError(
        'project_id_conflict',
        '这个游戏标识已被另一个本地工程占用，请更换游戏标识后重试。',
        409,
        state
      );
    }
    if (state.phase === 'ABORTED' || state.phase === 'NOT_FOUND') {
      pendingTransactions.delete(pendingKey);
      fail('allocation_prepare_failed', 'Playmesh 未能准备本地工程目录。', state);
    }
    input = { ...prepareInput, transactionId: state.transactionId };
    pendingTransactions.set(pendingKey, {
      idempotencyKey: prepareInput.idempotencyKey,
      transactionId: state.transactionId,
    });
    if (state.phase === 'PREPARED') {
      // 空白工程没有资源。Gateway 的 presence 批次契约只接受非空批次，
      // 直接上传 project/finalize 即可，不能把“没有旧 provider/资源”当成错误。
      if (evidence.resourcePlan.length > 0) {
        const presence = await allocationClient.resourcePresence(
          input,
          evidence.resourcePlan
        );
        state = requireState(presence);
        if (!Array.isArray(presence.missing)) {
          fail('invalid_response', 'Playmesh 资源检查响应无效。');
        }
        const resourcesByHash /*: Map<string, AllocationSnapshotResource> */ = new Map(
          snapshot.resources.map(resource => [resource.contentHash, resource])
        );
        for (const missing of presence.missing) {
          const resource = resourcesByHash.get(missing.hash);
          if (!resource) {
            return fail(
              'invalid_response',
              'Playmesh 缺失资源与本地工程快照不匹配。'
            );
          }
          if (resource.blob.size !== missing.bytes) {
            fail('invalid_response', 'Playmesh 缺失资源与本地工程快照不匹配。');
          }
          await allocationClient.uploadResource(input, {
            contentHash: missing.hash,
            blob: resource.blob,
          });
        }
      }
      await allocationClient.uploadProject(input, projectJson);
      state = requireState(
        await allocationClient.finalizeWorkspace(input, {
          packageName: gameId,
          projectUuid,
          projectJsonHash: evidence.projectJsonHash,
          projectJsonSize: new TextEncoder().encode(projectJson).byteLength,
          resourceManifestHash: evidence.resourceManifestHash,
        })
      );
    }
    if (state.phase === 'WORKSPACE_FINALIZED') {
      commitAttempted = true;
      try {
        state = requireState(await allocationClient.commit(input));
      } catch (error) {
        state = await safeState(allocationClient, input);
        if (!state) throw error;
      }
    }
    if (state.phase === 'COMMIT_REQUESTED') {
      state = requireState(await allocationClient.recover(input));
    }
    if (state.phase !== 'COMMITTED') {
      if (state.phase !== 'COMMIT_REQUESTED') await abortBeforeCommit(allocationClient, input);
      fail('allocation_commit_failed', 'Playmesh 未能原子提交本地 GDevelop 工程。', state);
    }
    pendingTransactions.delete(pendingKey);
    return state;
  } catch (error) {
    if (
      !commitAttempted &&
      state &&
      state.phase !== 'COMMIT_REQUESTED' &&
      state.phase !== 'COMMITTED'
    ) {
      await abortBeforeCommit(allocationClient, input);
    }
    throw wrapError(error);
  }
};
