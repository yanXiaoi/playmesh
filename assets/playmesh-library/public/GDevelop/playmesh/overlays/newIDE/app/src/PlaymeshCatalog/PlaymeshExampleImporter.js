// @flow
import type { StoredProjectResource } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import type { FileMetadata } from '../ProjectsStorage';
import {
  beginCatalogStaging,
  cleanupExpiredCatalogStaging,
  clearCatalogStaging,
  getCatalogStagedArtifact,
  putCatalogStagedArtifact,
} from './PlaymeshCatalogCache';
import { PlaymeshCatalogError, sha256Hex } from './PlaymeshCatalogRuntime';
import type { PlaymeshCatalogLimits } from './PlaymeshCatalogRuntime';
import {
  fetchPlaymeshArtifact,
  getPlaymeshExampleManifest,
} from './PlaymeshCatalogSource';
import type {
  PlaymeshCatalogJsonObject,
  PlaymeshCatalogJsonValue,
  PlaymeshExampleHeader,
  PlaymeshExampleProjectResource,
  PlaymeshRuntimeExampleManifest,
} from './PlaymeshCatalogSource';
import { generateCopiedGDevelopGameId } from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import { allocatePlaymeshProjectSnapshot } from '../PlaymeshProjects/PlaymeshProjectAllocationCoordinator';
import { ensureGDevelopJsPlatformIsRegistered as ensurePlaymeshGDevelopJsPlatformIsRegistered } from '../PlaymeshShared/PlaymeshGDevelopPlatform';
import { sanitizePlaymeshExternalUrl } from './PlaymeshExternalDownloadDiagnostic';
import {
  splitPlaymeshProject,
  type PlaymeshProjectFile,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles';

const textDecoder = new TextDecoder('utf-8', { fatal: true });

export type PlaymeshExampleImportProgress = {|
  completed: number,
  total: number,
|};

export type StagePlaymeshExampleOptions = {|
  header: PlaymeshExampleHeader,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshExampleImportProgress => void,
  licenseEvidenceKey?: string,
|};

export type StagedPlaymeshExample = {|
  fileIdentifier: string,
  projectUuid: string,
  gameId: string,
  name: string,
  projectFiles: Array<PlaymeshProjectFile>,
  projectFilesJson: string,
  normalizedProjectHash: string,
  resources: Array<StoredProjectResource>,
  releaseStaging: () => Promise<void>,
|};

export class PlaymeshExampleImportError extends Error {
  /*:: code: string; stage: string; operation: string; status: number; requestId: ?string; retryable: boolean; targetUrl: string; reason: ?string; */

  constructor({
    code,
    message,
    stage,
    operation,
    status = 0,
    requestId = null,
    retryable = false,
    targetUrl = '',
    reason = null,
  }: {|
    code: string,
    message: string,
    stage: string,
    operation: string,
    status?: number,
    requestId?: ?string,
    retryable?: boolean,
    targetUrl?: mixed,
    reason?: ?string,
  |}) {
    super(message);
    this.name = 'PlaymeshExampleImportError';
    this.code = code;
    this.stage = stage;
    this.operation = operation;
    this.status = Number.isSafeInteger(status) ? status : 0;
    this.requestId =
      typeof requestId === 'string' && requestId ? requestId : null;
    this.retryable = retryable === true;
    this.targetUrl = sanitizePlaymeshExternalUrl(targetUrl);
    this.reason = typeof reason === 'string' && reason ? reason : null;
  }
}

const recordOf = (value: mixed): ?{ [string]: mixed } =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value: any)
    : null;

export const normalizePlaymeshExampleImportError = (
  error: mixed,
  stage: string,
  fallbackOperation: string
): PlaymeshExampleImportError => {
  if (error instanceof PlaymeshExampleImportError) return error;
  const raw = recordOf(error);
  const details = raw && recordOf(raw.details);
  const code =
    raw && typeof raw.code === 'string' && raw.code
      ? raw.code
      : raw && typeof raw.name === 'string' && raw.name !== 'Error'
      ? raw.name
      : 'example_import_failed';
  const message =
    raw && typeof raw.message === 'string' && raw.message
      ? raw.message
      : 'GDevelop official example import failed.';
  const operation =
    raw && typeof raw.operation === 'string' && raw.operation
      ? raw.operation
      : details && typeof details.operation === 'string' && details.operation
      ? details.operation
      : fallbackOperation;
  const requestId =
    raw && typeof raw.requestId === 'string' && raw.requestId
      ? raw.requestId
      : details && typeof details.requestId === 'string' && details.requestId
      ? details.requestId
      : null;
  return new PlaymeshExampleImportError({
    code,
    message,
    stage:
      raw && typeof raw.stage === 'string' && raw.stage ? raw.stage : stage,
    operation,
    status:
      raw && Number.isSafeInteger(raw.status) ? Number(raw.status) : 0,
    requestId,
    retryable: !!(raw && raw.retryable === true),
    targetUrl:
      (raw && raw.targetUrl) || (details && details.targetUrl) || '',
    reason:
      raw && typeof raw.reason === 'string' && raw.reason
        ? raw.reason
        : details && typeof details.reason === 'string' && details.reason
        ? details.reason
        : null,
  });
};

const boundedDiagnosticField = (
  value: mixed,
  fallback: string
): string => {
  if (typeof value !== 'string' || !value) return fallback;
  const normalized = value.replace(/[^A-Za-z0-9._:-]/g, '_');
  return normalized.slice(0, 160) || fallback;
};

export const reportPlaymeshExampleImportFailure = (
  error: PlaymeshExampleImportError
): void => {
  console.error(
    '[PlayMesh Examples] ' +
      `requestId=${boundedDiagnosticField(error.requestId, 'unavailable')} ` +
      `stage=${boundedDiagnosticField(error.stage, 'unknown')} ` +
      `operation=${boundedDiagnosticField(error.operation, 'gdevelop.example.unknown')} ` +
      `status=${error.status || 0} ` +
      `code=${boundedDiagnosticField(error.code, 'example_import_failed')} ` +
      `reason=${boundedDiagnosticField(error.reason, error.code)} ` +
      `target=${error.targetUrl || 'unavailable'}`
  );
};

const createId = (): string => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return window.crypto.randomUUID();
  }
  return `${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2)}`;
};

const decodeCatalogJsonValue = (
  value: mixed,
  depth: number = 0
): PlaymeshCatalogJsonValue => {
  if (depth > 512) {
    throw new PlaymeshCatalogError(
      'invalid_project',
      '示例项目 JSON 嵌套过深。'
    );
  }
  if (
    value === null ||
    typeof value === 'boolean' ||
    typeof value === 'string'
  ) {
    return value;
  }
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (Array.isArray(value)) {
    return value.map((item: mixed) => decodeCatalogJsonValue(item, depth + 1));
  }
  if (!value || typeof value !== 'object') {
    throw new PlaymeshCatalogError(
      'invalid_project',
      '示例项目 JSON 字段无效。'
    );
  }
  const source: { +[string]: mixed } = value;
  const result: PlaymeshCatalogJsonObject = {};
  Object.keys(source).forEach((key: string) => {
    result[key] = decodeCatalogJsonValue(source[key], depth + 1);
  });
  return result;
};

const replaceStringsDeep = (
  value: PlaymeshCatalogJsonValue,
  replacements: Map<string, string>
): PlaymeshCatalogJsonValue => {
  if (typeof value === 'string') return replacements.get(value) || value;
  if (Array.isArray(value)) {
    value.forEach((item: PlaymeshCatalogJsonValue, index: number) => {
      value[index] = replaceStringsDeep(item, replacements);
    });
    return value;
  }
  if (value && typeof value === 'object') {
    Object.keys(value).forEach((key: string) => {
      value[key] = replaceStringsDeep(value[key], replacements);
    });
  }
  return value;
};

/**
 * The catalog downloads one Blob per distinct source file, while a valid
 * GDevelop project may contain several resource entries pointing at that same
 * file. Allocation evidence is intentionally keyed by the official resource
 * entries, so these aliases must keep distinct logical URLs even though they
 * share the same verified Blob and content hash.
 */
const preserveOfficialResourceAliases = ({
  project,
  resources,
}: {|
  project: PlaymeshCatalogJsonObject,
  resources: Array<StoredProjectResource>,
|}): Array<StoredProjectResource> => {
  const resourcesContainer = recordOf(project.resources);
  const officialResources =
    resourcesContainer && Array.isArray(resourcesContainer.resources)
      ? resourcesContainer.resources
      : null;
  if (!officialResources) {
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例项目 resources.resources 无效。'
    );
  }
  const downloadedByLogicalUrl: Map<string, StoredProjectResource> = new Map(
    resources.map(resource => [resource.logicalUrl, resource])
  );
  const referencedLogicalUrls: Set<string> = new Set();
  const result: Array<StoredProjectResource> = [];
  officialResources.forEach((value: mixed, index: number) => {
    const entry = recordOf(value);
    if (!entry || typeof entry.file !== 'string') {
      throw new PlaymeshCatalogError(
        'invalid_project_schema',
        '示例项目 resource.file 无效。'
      );
    }
    if (!entry.file.startsWith('playmesh-local-resource://')) return;
    if (typeof entry.name !== 'string') {
      throw new PlaymeshCatalogError(
        'invalid_project_schema',
        '示例项目 resource.name 无效。'
      );
    }
    const file = entry.file;
    const name = entry.name;
    const downloaded = downloadedByLogicalUrl.get(file);
    if (!downloaded) {
      throw new PlaymeshCatalogError(
        'invalid_project_schema',
        '示例项目资源引用不在已验证下载清单中。'
      );
    }
    if (!referencedLogicalUrls.has(file)) {
      referencedLogicalUrls.add(file);
      result.push({
        ...downloaded,
        name,
      });
      return;
    }
    const logicalUrl = `${file}/reference-${index.toString(36)}`;
    if (
      referencedLogicalUrls.has(logicalUrl) ||
      downloadedByLogicalUrl.has(logicalUrl)
    ) {
      throw new PlaymeshCatalogError(
        'invalid_project_schema',
        '示例项目资源别名冲突。'
      );
    }
    entry.file = logicalUrl;
    referencedLogicalUrls.add(logicalUrl);
    result.push({
      ...downloaded,
      logicalUrl,
      name,
    });
  });
  if (
    resources.some(resource => !referencedLogicalUrls.has(resource.logicalUrl))
  ) {
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例下载清单包含未被工程引用的资源。'
    );
  }
  return result;
};

const parseProject = (bytes: ArrayBuffer): PlaymeshCatalogJsonObject => {
  try {
    const parsed: mixed = JSON.parse(textDecoder.decode(bytes));
    const value = decodeCatalogJsonValue(parsed);
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('项目正文不是对象。');
    }
    return value;
  } catch (_) {
    throw new PlaymeshCatalogError('invalid_project', '示例项目 JSON 已损坏。');
  }
};

const ensureGDevelopJsPlatformIsRegistered = (gd: libGDevelop): void => {
  try {
    ensurePlaymeshGDevelopJsPlatformIsRegistered(gd);
  } catch (_) {
    throw new PlaymeshCatalogError(
      'engine_platform_unavailable',
      '当前 GDevelop 内核没有提供 JS 平台初始化能力。'
    );
  }
};

const validateProjectWithGDevelop = (
  project: PlaymeshCatalogJsonObject
): void => {
  const gd = global.gd;
  if (!gd || !gd.ProjectHelper || !gd.Serializer) {
    throw new PlaymeshCatalogError(
      'engine_unavailable',
      '当前 GDevelop 内核无法验证示例项目。'
    );
  }
  // Project::UnserializeFrom resolves serialized platform names through the
  // process-wide PlatformManager. createNewGDJSProject only attaches the JS
  // platform to the new project and does not perform this registration.
  ensureGDevelopJsPlatformIsRegistered(gd);
  const temporaryProject = gd.ProjectHelper.createNewGDJSProject();
  const serializedProject = gd.Serializer.fromJSObject(project);
  try {
    temporaryProject.unserializeFrom(serializedProject);
    const platform = temporaryProject.getCurrentPlatform();
    if (!platform || platform.getName() !== 'GDevelop JS platform') {
      throw new PlaymeshCatalogError(
        'engine_platform_unavailable',
        'GDevelop JS 平台未在示例反序列化前完成注册。'
      );
    }
  } catch (error) {
    if (error instanceof PlaymeshCatalogError) throw error;
    throw new PlaymeshCatalogError(
      'invalid_project_schema',
      '示例项目无法由当前 GDevelop 内核读取。'
    );
  } finally {
    serializedProject.delete();
    temporaryProject.delete();
  }
};

const setProjectStringProperty = (
  properties: PlaymeshCatalogJsonObject,
  key: string,
  value: string
): void => {
  properties[key] = value;
};

const validateExampleManifest = (
  exampleManifest: PlaymeshRuntimeExampleManifest,
  limits: PlaymeshCatalogLimits
): void => {
  if (
    !Number.isSafeInteger(exampleManifest.totalBytes) ||
    exampleManifest.totalBytes > limits.exampleTotalBytes
  ) {
    throw new PlaymeshCatalogError('invalid_example', '示例分片字段无效。');
  }
  const expectedBytes = exampleManifest.resources.reduce(
    (total: number, resource: PlaymeshExampleProjectResource) => {
      const declaredBytes = resource.artifact.declaredBytes;
      if (typeof declaredBytes !== 'number') {
        throw new PlaymeshCatalogError('invalid_example', '示例资源大小缺失。');
      }
      return total + declaredBytes;
    },
    exampleManifest.projectDownload.bytes.byteLength
  );
  if (
    !Number.isSafeInteger(expectedBytes) ||
    expectedBytes !== exampleManifest.totalBytes ||
    exampleManifest.requestCount !== exampleManifest.resources.length + 1
  ) {
    throw new PlaymeshCatalogError('invalid_example', '示例分片总量校验失败。');
  }
  const files: Set<string> = new Set();
  for (const resource of exampleManifest.resources) {
    if (!resource.file || files.has(resource.file)) {
      throw new PlaymeshCatalogError('invalid_example', '示例资源清单无效。');
    }
    files.add(resource.file);
  }
};

type DownloadResourcesOptions = {|
  stagingSessionId: string,
  resources: Array<PlaymeshExampleProjectResource>,
  limits: PlaymeshCatalogLimits,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshExampleImportProgress => void,
|};

const downloadResources = async ({
  stagingSessionId,
  resources,
  limits,
  signal,
  onProgress,
}: DownloadResourcesOptions): Promise<void> => {
  let nextIndex = 0;
  let completed = 0;
  let firstError: ?Error = null;
  const worker = async (): Promise<void> => {
    while (true) {
      if (firstError) return;
      const index = nextIndex++;
      if (index >= resources.length) return;
      const resource = resources[index];
      if (!resource) return;
      if (signal && signal.aborted) {
        throw new PlaymeshCatalogError('cancelled', '示例导入已取消。');
      }
      const bytes = await fetchPlaymeshArtifact({
        artifact: resource.artifact,
        limits,
        signal,
      });
      // 其他 worker 失败后不再写入新 staging；仍等待当前请求自然收敛，
      // 确保 finally 清理之后不会出现迟到写入的孤儿记录。
      if (firstError) return;
      await putCatalogStagedArtifact({
        sessionId: stagingSessionId,
        artifactKey: `resource:${index}`,
        blob: new Blob([bytes.bytes], {
          type: resource.artifact.mediaType || 'application/octet-stream',
        }),
        metadata: {
          artifact: resource.artifact,
          contentHash: bytes.contentHash,
          byteLength: bytes.bytes.byteLength,
        },
      });
      completed++;
      if (onProgress) onProgress({ completed, total: resources.length + 1 });
    }
  };
  const workerCount = Math.max(
    1,
    Math.min(limits.downloadConcurrency, resources.length || 1)
  );
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      try {
        await worker();
      } catch (error) {
        if (!firstError) {
          firstError =
            error instanceof Error ? error : new Error('示例资源下载失败。');
        }
      }
    })
  );
  if (firstError) throw firstError;
};

type VerifiedStagedBlob = {|
  blob: Blob,
  contentHash: string,
|};

const readVerifiedStagedBlob = async ({
  stagingSessionId,
  artifactKey,
}: {|
  stagingSessionId: string,
  artifactKey: string,
|}): Promise<VerifiedStagedBlob> => {
  const staged = await getCatalogStagedArtifact(stagingSessionId, artifactKey);
  if (
    !staged ||
    !(staged.blob instanceof Blob) ||
    !staged.metadata ||
    !/^[a-f0-9]{64}$/.test(staged.metadata.contentHash || '') ||
    !Number.isSafeInteger(staged.metadata.byteLength)
  ) {
    throw new PlaymeshCatalogError(
      'staging_missing',
      '示例 staging 文件缺失。'
    );
  }
  if (staged.blob.size !== staged.metadata.byteLength) {
    throw new PlaymeshCatalogError(
      'size_mismatch',
      '示例 staging 长度校验失败。'
    );
  }
  // 每次只读取一个 Blob 做二次校验，不聚合整个示例的 ArrayBuffer。
  const digest = await sha256Hex(await staged.blob.arrayBuffer());
  if (digest !== staged.metadata.contentHash) {
    throw new PlaymeshCatalogError(
      'hash_mismatch',
      '示例 staging SHA-256 校验失败。'
    );
  }
  return { blob: staged.blob, contentHash: staged.metadata.contentHash };
};

export const stagePlaymeshExample = async ({
  header,
  signal,
  onProgress,
  licenseEvidenceKey,
}: StagePlaymeshExampleOptions): Promise<StagedPlaymeshExample> => {
  let manifestResult;
  try {
    manifestResult = await getPlaymeshExampleManifest({ header, signal });
  } catch (error) {
    throw normalizePlaymeshExampleImportError(
      error,
      'manifest_download',
      'gdevelop.catalog.example.manifest'
    );
  }
  const { manifest, exampleManifest } = manifestResult;
  validateExampleManifest(exampleManifest, manifest.limits);
  if (
    exampleManifest.license.status !== 'open' &&
    licenseEvidenceKey !== exampleManifest.license.evidenceKey
  ) {
    throw new PlaymeshExampleImportError({
      code: 'license_acknowledgement_required',
      message: '示例许可未确认，请先查看并确认当前许可证据。',
      stage: 'license_acknowledgement',
      operation: 'gdevelop.catalog.example.license.acknowledge',
      reason: exampleManifest.license.status,
    });
  }
  await cleanupExpiredCatalogStaging();
  const stagingSessionId = createId();
  await beginCatalogStaging(stagingSessionId);
  let stagingHandedOff = false;
  try {
    if (onProgress) {
      onProgress({ completed: 0, total: exampleManifest.requestCount });
    }
    const projectBytes = exampleManifest.projectDownload;
    await putCatalogStagedArtifact({
      sessionId: stagingSessionId,
      artifactKey: 'project',
      blob: new Blob([projectBytes.bytes], { type: 'application/json' }),
      metadata: {
        artifact: exampleManifest.project,
        contentHash: projectBytes.contentHash,
        byteLength: projectBytes.bytes.byteLength,
      },
    });
    if (onProgress) {
      onProgress({ completed: 1, total: exampleManifest.requestCount });
    }
    try {
      await downloadResources({
        stagingSessionId,
        resources: exampleManifest.resources,
        limits: manifest.limits,
        signal,
        onProgress: (progress: PlaymeshExampleImportProgress) =>
          onProgress &&
          onProgress({
            completed: progress.completed + 1,
            total: progress.total,
          }),
      });
    } catch (error) {
      throw normalizePlaymeshExampleImportError(
        error,
        'resource_download',
        'gdevelop.catalog.artifact.acquire'
      );
    }
    if (signal && signal.aborted) {
      throw new PlaymeshCatalogError('cancelled', '示例导入已取消。');
    }

    // 到这里所有正文均已完成长度和 SHA-256 校验并写入持久化 staging。
    let stagedProject;
    let project;
    try {
      stagedProject = await readVerifiedStagedBlob({
        stagingSessionId,
        artifactKey: 'project',
      });
      project = parseProject(await stagedProject.blob.arrayBuffer());
      validateProjectWithGDevelop(project);
    } catch (error) {
      throw normalizePlaymeshExampleImportError(
        error,
        'project_validation',
        'gdevelop.catalog.example.validate'
      );
    }
    const fileIdentifier = createId();
    const projectUuid = createId();
    const gameId = generateCopiedGDevelopGameId();
    const propertiesValue = project.properties;
    let properties: PlaymeshCatalogJsonObject;
    if (
      propertiesValue &&
      typeof propertiesValue === 'object' &&
      !Array.isArray(propertiesValue)
    ) {
      properties = propertiesValue;
    } else {
      properties = ({}: PlaymeshCatalogJsonObject);
      project.properties = properties;
    }
    const projectName = exampleManifest.name || header.name;
    setProjectStringProperty(properties, 'projectUuid', projectUuid);
    setProjectStringProperty(properties, 'packageName', gameId);
    setProjectStringProperty(properties, 'name', projectName);
    properties.folderProject = true;

    const replacements: Map<string, string> = new Map();
    const resources: Array<StoredProjectResource> = [];
    for (let index = 0; index < exampleManifest.resources.length; index++) {
      const resource = exampleManifest.resources[index];
      const stagedResource = await readVerifiedStagedBlob({
        stagingSessionId,
        artifactKey: `resource:${index}`,
      });
      const logicalUrl = `playmesh-local-resource://${encodeURIComponent(
        fileIdentifier
      )}/${stagedResource.contentHash}/${encodeURIComponent(resource.file)}`;
      replacements.set(resource.file, logicalUrl);
      replacements.set(`./${resource.file}`, logicalUrl);
      replacements.set(resource.file.replaceAll('/', '\\'), logicalUrl);
      resources.push({
        logicalUrl,
        name: resource.name || resource.file,
        blob: stagedResource.blob,
        contentHash: stagedResource.contentHash,
      });
    }
    replaceStringsDeep(project, replacements);
    const projectResources = preserveOfficialResourceAliases({
      project,
      resources,
    });

    // 二次检查内存中的 project bytes，避免 JSON 解析器或替换流程产生非确定内容。
    const projectFiles = splitPlaymeshProject(project);
    const normalizedProjectText = JSON.stringify(projectFiles);
    const normalizedProjectHash = await sha256Hex(
      new TextEncoder().encode(normalizedProjectText)
    );
    stagingHandedOff = true;
    return {
      fileIdentifier,
      projectUuid,
      gameId,
      name: projectName,
      projectFiles,
      projectFilesJson: normalizedProjectText,
      normalizedProjectHash,
      resources: projectResources,
      releaseStaging: (): Promise<void> =>
        clearCatalogStaging(stagingSessionId),
    };
  } finally {
    if (!stagingHandedOff) {
      await clearCatalogStaging(stagingSessionId).catch(() => {});
    }
  }
};

export const importPlaymeshExample = async (
  options: StagePlaymeshExampleOptions
): Promise<FileMetadata> => {
  const staged = await stagePlaymeshExample(options);
  try {
    const savedAt = Date.now();
    // 示例正文直接进入 App 权威 allocation 事务；浏览器不再建立工程副本。
    try {
      await allocatePlaymeshProjectSnapshot({
        fileIdentifier: staged.fileIdentifier,
        gameId: staged.gameId,
        name: staged.name,
        origin: 'create',
        projectUuid: staged.projectUuid,
        snapshot: {
          projectFiles: staged.projectFiles,
          resources: staged.resources,
        },
      });
    } catch (error) {
      throw normalizePlaymeshExampleImportError(
        error,
        'project_allocation',
        'gdevelop.project.allocation.prepare'
      );
    }
    const fileMetadata: FileMetadata = {
      fileIdentifier: staged.fileIdentifier,
      name: staged.name,
      gameId: staged.gameId,
      lastModifiedDate: savedAt,
    };
    return fileMetadata;
  } finally {
    await staged.releaseStaging().catch(() => {});
  }
};
