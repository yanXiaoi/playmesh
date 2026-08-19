// @flow

import { openPlaymeshPortableZip } from './PlaymeshPortableZipReader';
import { openPlaymeshRawProjectJson } from './PlaymeshRawProjectJsonReader';
import {
  getPortableResourceMimeType,
  parsePortableProjectJson,
  parsePortableProjectPartialJson,
  planPortableProjectResources,
  PlaymeshProjectImportError,
  resolvePortableImportLimits,
} from './PlaymeshPortableProjectFormat';
import { playmeshPortableImportAllocationClient } from './PlaymeshPortableImportAllocationClient';
import { createPlaymeshProjectAllocationEvidence } from '../PlaymeshProjects/PlaymeshProjectAllocationCoordinator';
import {
  createProjectSnapshot,
  persistRestoredProject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
import { unsplitPlaymeshProject } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles';
import {
  ensureGDevelopGameId,
  generateCopiedGDevelopGameId,
  isUnassignedGDevelopGameId,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';

const ALLOCATION_PHASES = new Set([
  'NOT_FOUND',
  'PREPARED',
  'WORKSPACE_FINALIZED',
  'COMMIT_REQUESTED',
  'COMMITTED',
  'CONFLICT',
  'ABORTED',
]);
const ALLOCATION_CONFLICT_REASONS = new Set([
  'target_became_occupied',
  'staging_changed',
]);

const fail = (
  code /*: string */,
  message /*: string */,
  details /*: mixed */ = null
) /*: empty */ => {
  throw new PlaymeshProjectImportError(code, message, details);
};

const asError = (
  rawError /*: mixed */,
  code /*: string */,
  message /*: string */
) /*: PlaymeshProjectImportError */ =>
  rawError instanceof PlaymeshProjectImportError
    ? rawError
    : new PlaymeshProjectImportError(code, message, rawError);

const assertAllocationClient = (client /*: mixed */) /*: any */ => {
  if (!client || typeof client !== 'object') {
    return fail(
      'allocation_client_required',
      'GDevelop 导入缺少 allocation transaction port。'
    );
  }
  const allocationClient /*: any */ = client;
  for (const method of [
    'prepare',
    'getStatus',
    'resourcePresence',
    'uploadResource',
    'uploadProjectFiles',
    'finalizeWorkspace',
    'commit',
    'recover',
    'abort',
  ]) {
    if (typeof allocationClient[method] !== 'function') {
      return fail(
        'invalid_allocation_client',
        `GDevelop allocation transaction port 缺少 ${method}。`
      );
    }
  }
  return allocationClient;
};

export const assertPortableImportAllocationState = (
  value /*: mixed */
) /*: Object */ => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return fail(
      'invalid_allocation_response',
      'GDevelop allocation 响应无效。'
    );
  }
  const state /*: any */ = value;
  const phase = state.phase;
  if (!ALLOCATION_PHASES.has(phase)) {
    return fail(
      'invalid_allocation_response',
      'GDevelop allocation phase 无效。'
    );
  }
  const transactionId =
    state.transactionId === undefined || state.transactionId === null
      ? null
      : String(state.transactionId);
  if (
    (phase === 'PREPARED' ||
      phase === 'WORKSPACE_FINALIZED' ||
      phase === 'COMMIT_REQUESTED' ||
      phase === 'COMMITTED') &&
    !transactionId
  ) {
    return fail(
      'invalid_allocation_response',
      'GDevelop allocation 缺少 transactionId。'
    );
  }
  const conflictValue /*: any */ = state.conflict;
  let conflict = null;
  if (conflictValue !== undefined && conflictValue !== null) {
    const conflictReason = conflictValue.reason;
    const conflictObservedAt = conflictValue.observedAt;
    if (
      typeof conflictValue !== 'object' ||
      Array.isArray(conflictValue) ||
      Object.keys(conflictValue).length !== 2 ||
      typeof conflictReason !== 'string' ||
      !ALLOCATION_CONFLICT_REASONS.has(conflictReason) ||
      typeof conflictObservedAt !== 'string' ||
      !Number.isFinite(Date.parse(conflictObservedAt)) ||
      (phase !== 'CONFLICT' && phase !== 'ABORTED')
    ) {
      return fail(
        'invalid_allocation_response',
        'GDevelop allocation conflict 无效。'
      );
    }
    conflict = {
      reason: conflictReason,
      observedAt: conflictObservedAt,
    };
  }
  return {
    phase,
    transactionId,
    ...(conflict ? { conflict } : {}),
  };
};

const createId = (cryptoImplementation /*: any */) /*: string */ => {
  if (
    cryptoImplementation &&
    typeof cryptoImplementation.randomUUID === 'function'
  ) {
    return cryptoImplementation.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (
    cryptoImplementation &&
    typeof cryptoImplementation.getRandomValues === 'function'
  ) {
    cryptoImplementation.getRandomValues(bytes);
    return [...bytes]
      .map(value => value.toString(16).padStart(2, '0'))
      .join('');
  }
  return fail(
    'secure_random_unavailable',
    '当前浏览器无法生成安全的导入事务标识。'
  );
};

export const createPortableImportEvidence = async (
  {
    projectFilesJson,
    resources,
    cryptoImplementation = typeof window === 'undefined' ? null : window.crypto,
  } /*: Object */
) /*: Promise<Object> */ => {
  try {
    return await createPlaymeshProjectAllocationEvidence({
      projectFilesJson,
      resources,
      cryptoImplementation,
    });
  } catch (error) {
    throw asError(
      error,
      'invalid_import_snapshot',
      'GDevelop 导入快照无效。'
    );
  }
};

const needsNewPackageName = (
  { reason, packageName, sourcePackageName, sourceProjectUuid } /*: Object */
) /*: Object */ => ({
  status: 'needsNewPackageName',
  reason,
  packageName,
  sourcePackageName,
  sourceProjectUuid,
  requiredIdentityMode: 'copy',
});

const allocationDisplayName = (
  value /*: mixed */,
  fallback /*: string */
) /*: string */ => {
  const normalized = String(value || '').trim();
  return normalized &&
    normalized.length <= 80 &&
    !/[\u0000-\u001f\u007f]/.test(normalized)
    ? normalized
    : fallback;
};

const safeStatus = async (
  allocationClient /*: any */,
  input /*: Object */
) /*: Promise<?Object> */ => {
  try {
    return assertPortableImportAllocationState(
      await allocationClient.getStatus(input)
    );
  } catch (_) {
    return null;
  }
};

const recoveringResult = (
  input /*: Object */,
  state /*: ?Object */,
  reason /*: string */
) /*: Object */ => ({
  status: 'recovering',
  reason,
  idempotencyKey: input.idempotencyKey,
  transactionId: (state && state.transactionId) || input.transactionId || null,
  fileIdentifier: input.target.fileIdentifier,
  gameId: input.target.gameId,
  phase: state ? state.phase : 'UNKNOWN',
});

const abortBeforeDecision = async (
  { allocationClient, input, cause, conflictResult = null } /*: Object */
) /*: Promise<any> */ => {
  let state = null;
  try {
    state = assertPortableImportAllocationState(
      await allocationClient.abort(input)
    );
  } catch (_) {
    state = await safeStatus(allocationClient, input);
  }
  if (state && state.phase === 'COMMIT_REQUESTED') {
    try {
      state = assertPortableImportAllocationState(
        await allocationClient.recover(input)
      );
    } catch (_) {
      state = await safeStatus(allocationClient, input);
    }
  }
  if (state && state.phase === 'COMMITTED') return state;
  if (state && (state.phase === 'ABORTED' || state.phase === 'NOT_FOUND')) {
    if (conflictResult) return conflictResult;
    throw cause;
  }
  throw new PlaymeshProjectImportError(
    'import_recovery_required',
    'GDevelop 导入回滚结果暂时无法确认；App 将按项目事务状态继续恢复。',
    {
      cause,
      recovery: recoveringResult(input, state, 'rollback_unconfirmed'),
    }
  );
};

const conflictResultFor = (prepared /*: Object */) /*: Object */ =>
  needsNewPackageName({
    reason: 'allocation_conflict',
    packageName: prepared.identity.packageName,
    sourcePackageName: prepared.identity.sourcePackageName,
    sourceProjectUuid: prepared.identity.sourceProjectUuid,
  });

const uploadWorkspace = async (
  { allocationClient, input, prepared } /*: Object */
) /*: Promise<Object> */ => {
  try {
    const rawPresence = await allocationClient.resourcePresence(
      input,
      prepared.evidence.resourcePlan
    );
    const presenceState = assertPortableImportAllocationState(rawPresence);
    if (
      presenceState.phase !== 'PREPARED' ||
      !Array.isArray(rawPresence.missing)
    ) {
      fail(
        'invalid_allocation_response',
        'GDevelop allocation 资源 presence 响应无效。'
      );
    }
    const resourcesByHash /*: Map<string, any> */ = new Map();
    prepared.snapshot.resources.forEach(resource => {
      if (!resourcesByHash.has(resource.contentHash)) {
        resourcesByHash.set(resource.contentHash, resource);
      }
    });
    const uploaded /*: Set<string> */ = new Set();
    for (const missing of rawPresence.missing) {
      if (
        !missing ||
        typeof missing.hash !== 'string' ||
        !Number.isSafeInteger(missing.bytes)
      ) {
        fail(
          'invalid_allocation_response',
          'GDevelop allocation 缺失资源无效。'
        );
      }
      if (uploaded.has(missing.hash)) continue;
      const resource = resourcesByHash.get(missing.hash);
      if (!resource || resource.blob.size !== missing.bytes) {
        return fail(
          'invalid_allocation_response',
          'GDevelop allocation 缺失资源与本地快照不匹配。'
        );
      }
      await allocationClient.uploadResource(input, {
        contentHash: missing.hash,
        blob: resource.blob,
      });
      uploaded.add(missing.hash);
    }
    await allocationClient.uploadProjectFiles(
      input,
      prepared.projectFilesJson
    );
    return assertPortableImportAllocationState(
      await allocationClient.finalizeWorkspace(input, {
        packageName: prepared.target.packageName,
        projectUuid: prepared.target.projectUuid,
        projectFilesHash: prepared.target.projectFilesHash,
        projectFilesSize: new TextEncoder().encode(prepared.projectFilesJson)
          .byteLength,
        resourceManifestHash: prepared.target.resourceManifestHash,
      })
    );
  } catch (error) {
    const observed = await safeStatus(allocationClient, input);
    if (
      observed &&
      (observed.phase === 'WORKSPACE_FINALIZED' ||
        observed.phase === 'COMMIT_REQUESTED' ||
        observed.phase === 'COMMITTED')
    ) {
      return observed;
    }
    return abortBeforeDecision({
      allocationClient,
      input,
      cause: asError(
        error,
        'allocation_workspace_failed',
        'GDevelop 导入工作区上传失败。'
      ),
      ...(observed && observed.phase === 'CONFLICT'
        ? { conflictResult: conflictResultFor(prepared) }
        : {}),
    });
  }
};

const commitWorkspace = async (
  { allocationClient, input, prepared, state } /*: Object */
) /*: Promise<Object> */ => {
  let current = state;
  if (current.phase === 'PREPARED') {
    current = await uploadWorkspace({ allocationClient, input, prepared });
  }
  if (current.status === 'needsNewPackageName') return current;
  if (current.phase === 'CONFLICT') {
    return abortBeforeDecision({
      allocationClient,
      input,
      cause: new PlaymeshProjectImportError(
        'allocation_conflict',
        'GDevelop 导入目标在提交前发生冲突。'
      ),
      conflictResult: conflictResultFor(prepared),
    });
  }
  if (current.phase === 'WORKSPACE_FINALIZED') {
    try {
      current = assertPortableImportAllocationState(
        await allocationClient.commit(input)
      );
    } catch (error) {
      const observed = await safeStatus(allocationClient, input);
      if (!observed) return recoveringResult(input, null, 'status_unavailable');
      if (observed.phase === 'WORKSPACE_FINALIZED') {
        return abortBeforeDecision({
          allocationClient,
          input,
          cause: asError(
            error,
            'allocation_commit_failed',
            'GDevelop 导入提交失败。'
          ),
        });
      }
      current = observed;
    }
  }
  if (current.phase === 'COMMIT_REQUESTED') {
    try {
      current = assertPortableImportAllocationState(
        await allocationClient.recover(input)
      );
    } catch (_) {
      const observed = await safeStatus(allocationClient, input);
      if (!observed) return recoveringResult(input, null, 'status_unavailable');
      current = observed;
    }
  }
  if (current.phase === 'COMMIT_REQUESTED') {
    return recoveringResult(input, current, 'commit_in_progress');
  }
  if (current.phase === 'CONFLICT') {
    return abortBeforeDecision({
      allocationClient,
      input,
      cause: new PlaymeshProjectImportError(
        'allocation_conflict',
        'GDevelop 导入目标在提交前发生冲突。'
      ),
      conflictResult: conflictResultFor(prepared),
    });
  }
  if (current.phase !== 'COMMITTED') {
    fail(
      'post_decision_recovery_conflict',
      'GDevelop allocation 已进入决策阶段，但恢复状态不一致。'
    );
  }
  return { status: 'committed', state: current };
};

export const createPlaymeshPortableProjectImporter = (
  dependencyOverrides /*: ?Object */ = null
) /*: Object */ => {
  const defaultCrypto = typeof window === 'undefined' ? null : window.crypto;
  const dependencies /*: any */ = {
    openArchive: openPlaymeshPortableZip,
    openRawProjectJson: openPlaymeshRawProjectJson,
    parseProjectJson: parsePortableProjectJson,
    parsePartialProjectJson: parsePortableProjectPartialJson,
    unsplitProjectFiles: unsplitPlaymeshProject,
    planResources: planPortableProjectResources,
    resolveLimits: resolvePortableImportLimits,
    mimeTypeForPath: getPortableResourceMimeType,
    createSnapshot: createProjectSnapshot,
    persistSnapshot: persistRestoredProject,
    ensureGameId: ensureGDevelopGameId,
    generateGameId: generateCopiedGDevelopGameId,
    isUnassignedGameId: isUnassignedGDevelopGameId,
    allocationClient: playmeshPortableImportAllocationClient,
    cryptoImplementation: defaultCrypto,
    gdImplementation: typeof global.gd === 'undefined' ? null : global.gd,
    createObjectURL: blob => URL.createObjectURL(blob),
    revokeObjectURL: url => URL.revokeObjectURL(url),
    ...(dependencyOverrides || {}),
  };

  const deserializeProject = (projectObject /*: Object */) /*: Object */ => {
    if (!dependencies.gdImplementation) {
      fail('gdevelop_runtime_unavailable', 'GDevelop 运行时尚未加载。');
    }
    let serializerElement = null;
    const project = dependencies.gdImplementation.ProjectHelper.createNewGDJSProject();
    try {
      serializerElement = dependencies.gdImplementation.Serializer.fromJSObject(
        projectObject
      );
      project.unserializeFrom(serializerElement);
      return project;
    } catch (error) {
      if (project && typeof project.delete === 'function') project.delete();
      throw asError(
        error,
        'invalid_project_schema',
        'game.json 无法反序列化为 GDevelop 5 工程。'
      );
    } finally {
      if (serializerElement && typeof serializerElement.delete === 'function') {
        serializerElement.delete();
      }
    }
  };

  const collectProjectResources = (project /*: any */) /*: Object */ => {
    const manager = project.getResourcesManager();
    const names = manager.getAllResourceNames().toJSArray();
    const descriptions = [];
    const instances /*: Map<string, any> */ = new Map();
    for (const nameValue of names) {
      const name = String(nameValue);
      const resource = manager.getResource(nameValue);
      if (!resource) {
        fail('invalid_project_resources', `GDevelop 资源不存在：${name}`);
      }
      descriptions.push({
        name,
        file: String(resource.getFile()),
        kind:
          typeof resource.getKind === 'function'
            ? String(resource.getKind())
            : '',
      });
      instances.set(name, resource);
    }
    return { descriptions, instances };
  };

  const resolveIdentity = (
    {
      project,
      requestedPackageName,
      requestedIdentityMode,
      sourcePackageName,
      sourceProjectUuid,
    } /*: Object */
  ) /*: Object */ => {
    const sourceUnassigned = dependencies.isUnassignedGameId(sourcePackageName);
    const hasExplicitPackageName =
      requestedPackageName !== undefined && requestedPackageName !== null;
    const explicitPackageName = hasExplicitPackageName
      ? String(requestedPackageName).trim()
      : null;
    if (hasExplicitPackageName && !explicitPackageName) {
      return needsNewPackageName({
        reason: 'invalid',
        packageName: explicitPackageName,
        sourcePackageName,
        sourceProjectUuid,
      });
    }
    let packageName = explicitPackageName;
    let identityMode =
      requestedIdentityMode === undefined || requestedIdentityMode === null
        ? 'preserve'
        : requestedIdentityMode;
    if (identityMode !== 'preserve' && identityMode !== 'copy') {
      fail('invalid_identity_mode', 'GDevelop 导入 identityMode 无效。');
    }
    if (!packageName) {
      packageName = sourceUnassigned
        ? dependencies.generateGameId()
        : sourcePackageName;
    }
    project.setPackageName(packageName);
    try {
      packageName = dependencies.ensureGameId(project);
    } catch (_) {
      return needsNewPackageName({
        reason: 'invalid',
        packageName,
        sourcePackageName,
        sourceProjectUuid,
      });
    }
    const packageNameChanged = packageName !== sourcePackageName;
    if (!sourceUnassigned && packageNameChanged && identityMode !== 'copy') {
      fail(
        'project_uuid_decision_required',
        '修改 packageName 后必须显式选择 copy，不能静默复用 projectUuid。'
      );
    }
    if (
      identityMode === 'copy' &&
      (!hasExplicitPackageName || !packageNameChanged)
    ) {
      fail(
        'invalid_copy_identity',
        '只有显式修改 packageName 时才能创建 GDevelop 工程副本。'
      );
    }
    if (identityMode === 'copy') project.resetProjectUuid();
    else identityMode = 'preserve';
    const projectUuid = String(project.getProjectUuid() || '').trim();
    if (!projectUuid) {
      fail('missing_project_uuid', 'GDevelop 工程缺少 projectUuid。');
    }
    if (
      (identityMode === 'preserve' && projectUuid !== sourceProjectUuid) ||
      (identityMode === 'copy' && projectUuid === sourceProjectUuid)
    ) {
      fail(
        'project_uuid_invariant_failed',
        'GDevelop projectUuid 迁入规则校验失败。'
      );
    }
    return { status: 'ready', packageName, identityMode, projectUuid };
  };

  const prepareArchiveSnapshot = async (
    {
      archiveBlob,
      projectJsonBlob,
      packageName,
      identityMode,
      limits: limitOverrides,
      zipJs,
    } /*: Object */
  ) /*: Promise<Object> */ => {
    const limits = dependencies.resolveLimits(limitOverrides);
    const archive = projectJsonBlob
      ? await dependencies.openRawProjectJson(projectJsonBlob, { limits })
      : await dependencies.openArchive(archiveBlob, {
          limits,
          zipJs,
        });
    let project = null;
    const objectUrls = [];
    try {
      const projectBlob = await archive.readBlob({
        path: 'game.json',
        contentType: 'application/json',
        maxBytes: limits.maxProjectFileBytes,
      });
      const rootProjectObject = dependencies.parseProjectJson(
        new Uint8Array(await projectBlob.arrayBuffer()),
        limits
      );
      const projectFiles = [
        { path: 'game.json', content: rootProjectObject },
      ];
      const projectFilesByPath = new Map([
        ['game.json', rootProjectObject],
      ]);
      const preloadReferencedProjectFiles = async (
        currentObject /*: mixed */,
        depth /*: number */
      ) /*: Promise<void> */ => {
        if (
          depth >= 3 ||
          currentObject === null ||
          typeof currentObject !== 'object'
        ) {
          return;
        }
        for (const key of Object.keys(currentObject)) {
          const child = currentObject[key];
          if (
            child &&
            typeof child === 'object' &&
            child.__REFERENCE_TO_SPLIT_OBJECT === true
          ) {
            const referencePath = child.referenceTo;
            const filePath = `${String(referencePath).replace(/^\//, '')}.json`;
            let partial = projectFilesByPath.get(filePath);
            if (!partial) {
              const partialBlob = await archive.readBlob({
                path: filePath,
                contentType: 'application/json',
                maxBytes: limits.maxProjectFileBytes,
              });
              partial = dependencies.parsePartialProjectJson(
                new Uint8Array(await partialBlob.arrayBuffer()),
                limits
              );
              projectFilesByPath.set(filePath, partial);
              projectFiles.push({ path: filePath, content: partial });
            }
            await preloadReferencedProjectFiles(partial, depth + 1);
          } else {
            await preloadReferencedProjectFiles(child, depth + 1);
          }
        }
      };
      await preloadReferencedProjectFiles(rootProjectObject, 0);
      const projectObject = await dependencies.unsplitProjectFiles(
        projectFiles
      );
      project = deserializeProject(projectObject);
      let sourceProjectUuid = String(project.getProjectUuid() || '').trim();
      if (!sourceProjectUuid) {
        project.resetProjectUuid();
        sourceProjectUuid = String(project.getProjectUuid() || '').trim();
      }
      if (!sourceProjectUuid) {
        fail('missing_project_uuid', 'GDevelop 工程缺少 projectUuid。');
      }
      const sourcePackageName = String(project.getPackageName() || '').trim();
      const projectResources = collectProjectResources(project);
      const archivePlan = dependencies.planResources({
        inspectedArchive: archive.inspectedArchive,
        projectResources: projectResources.descriptions,
        projectFilePaths: new Set(projectFilesByPath.keys()),
        limits,
      });
      const identity = resolveIdentity({
        project,
        requestedPackageName: packageName,
        requestedIdentityMode: identityMode,
        sourcePackageName,
        sourceProjectUuid,
      });
      if (identity.status !== 'ready') return identity;
      const fileIdentifier = createId(dependencies.cryptoImplementation);
      const fileMetadata = {
        fileIdentifier,
        name: String(project.getName() || 'GDevelop project'),
        gameId: identity.packageName,
      };
      for (const localFile of archivePlan.localFiles) {
        const blob = await archive.readBlob({
          path: localFile.path,
          contentType: dependencies.mimeTypeForPath(localFile.path),
          maxBytes: limits.maxSingleResourceBytes,
        });
        for (const description of localFile.resources) {
          const resource = projectResources.instances.get(description.name);
          if (!resource) {
            fail(
              'invalid_project_resources',
              `GDevelop 资源不存在：${description.name}`
            );
          }
          const objectUrl = dependencies.createObjectURL(blob);
          objectUrls.push(objectUrl);
          resource.setFile(objectUrl);
        }
      }
      const snapshot = await dependencies.createSnapshot(project, fileMetadata);
      const projectFilesJson = JSON.stringify(snapshot.projectFiles);
      const evidence = await createPortableImportEvidence({
        projectFilesJson,
        resources: snapshot.resources,
        cryptoImplementation: dependencies.cryptoImplementation,
      });
      const target = {
        fileIdentifier,
        gameId: identity.packageName,
        packageName: identity.packageName,
        projectUuid: identity.projectUuid,
        projectFilesHash: evidence.projectFilesHash,
        resourceManifestHash: evidence.resourceManifestHash,
      };
      return {
        status: 'ready',
        fileMetadata,
        snapshot,
        projectFilesJson,
        evidence,
        target,
        name: allocationDisplayName(project.getName(), identity.packageName),
        identity: {
          mode: identity.identityMode,
          sourcePackageName,
          sourceProjectUuid,
          packageName: identity.packageName,
          projectUuid: identity.projectUuid,
        },
      };
    } finally {
      objectUrls.forEach(url => {
        try {
          dependencies.revokeObjectURL(url);
        } catch (_) {}
      });
      if (project && typeof project.delete === 'function') project.delete();
      try {
        await archive.close();
      } catch (_) {}
    }
  };

  const importProject = async (
    options /*: Object */
  ) /*: Promise<Object> */ => {
    const allocationClient = assertAllocationClient(
      options.allocationClient || dependencies.allocationClient
    );
    const prepared = await prepareArchiveSnapshot(options);
    if (prepared.status !== 'ready') return prepared;
    const idempotencyKey = createId(dependencies.cryptoImplementation);
    const prepareInput = {
      idempotencyKey,
      origin: prepared.identity.mode === 'copy' ? 'copy' : 'import',
      name: prepared.name,
      target: prepared.target,
    };
    let state;
    let prepareError = null;
    try {
      state = assertPortableImportAllocationState(
        await allocationClient.prepare(prepareInput)
      );
    } catch (error) {
      prepareError = error;
      state = await safeStatus(allocationClient, prepareInput);
      if (!state) {
        return recoveringResult(prepareInput, null, 'status_unavailable');
      }
    }
    if (state.phase === 'CONFLICT') return conflictResultFor(prepared);
    if (state.phase !== 'PREPARED') {
      if (state.phase === 'NOT_FOUND' || state.phase === 'ABORTED') {
        throw asError(
          prepareError,
          'allocation_prepare_failed',
          'GDevelop 导入预分配失败。'
        );
      }
      return recoveringResult(prepareInput, state, 'unexpected_prepare_state');
    }
    const input = { ...prepareInput, transactionId: state.transactionId };
    const committed = await commitWorkspace({
      allocationClient,
      input,
      prepared,
      state,
    });
    if (committed.status !== 'committed') return committed;

    let cacheStatus = 'mirrored';
    try {
      await dependencies.persistSnapshot({
        fileMetadata: prepared.fileMetadata,
        projectFiles: prepared.snapshot.projectFiles,
        resources: prepared.snapshot.resources,
      });
    } catch (_) {
      // App current 已提交。页面会话镜像可直接丢弃，后续 open 会从 App
      // current 重建；这里绝不回滚或覆盖权威项目。
      cacheStatus = 'stale';
    }
    return {
      status: 'imported',
      cacheStatus,
      fileMetadata: prepared.fileMetadata,
      identityMode: prepared.identity.mode,
      sourcePackageName: prepared.identity.sourcePackageName,
      packageName: prepared.identity.packageName,
      sourceProjectUuid: prepared.identity.sourceProjectUuid,
      projectUuid: prepared.identity.projectUuid,
    };
  };

  return { importProject };
};

export const importPlaymeshPortableProject = (
  options /*: Object */
) /*: Promise<Object> */ =>
  createPlaymeshPortableProjectImporter().importProject(options);
