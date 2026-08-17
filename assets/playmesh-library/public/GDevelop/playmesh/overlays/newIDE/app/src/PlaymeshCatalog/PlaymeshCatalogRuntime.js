// @flow
import {
  getArtifactCache,
  getCatalogCache,
  putArtifactCache,
  putCatalogCache,
  removeArtifactCache,
  removeCatalogCache,
} from './PlaymeshCatalogCache';
import type { PlaymeshArtifactCacheRecord } from './PlaymeshCatalogCache';
import { sha256Hex as computeSha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';
import { sanitizePlaymeshExternalUrl } from './PlaymeshExternalDownloadDiagnostic';

type MixedRecord = { +[string]: mixed };

export type PlaymeshCatalogRepository =
  | 'GDevelopApp/GDevelop-extensions'
  | 'GDevelopApp/GDevelop-examples';

export type PlaymeshCatalogArtifactKind =
  | 'extension'
  | 'example-project'
  | 'example-resource'
  | 'example-license'
  | 'example-preview';

export type PlaymeshCatalogEngine = {|
  version: string,
  tag?: string,
  commit?: string,
|};

export type PlaymeshCatalogSourceIdentity = {|
  repository: PlaymeshCatalogRepository,
  commit: string,
  rootTreeSha: string,
|};

export type PlaymeshCatalogLimits = {|
  catalogFileBytes: number,
  extensionBytes: number,
  exampleProjectBytes: number,
  exampleResourceBytes: number,
  exampleTotalBytes: number,
  exampleResourceCount: number,
  licenseFileBytes: number,
  licenseFileCount: number,
  downloadConcurrency: number,
  requestTimeoutMs: number,
  retryCount: number,
|};

export type PlaymeshCatalogDescriptor = {|
  path: string,
  sha256: string,
  bytes: number,
  mediaType?: string,
|};

export type PlaymeshCatalogManifest = {|
  schemaVersion: 1,
  catalogRevision: string,
  engine: PlaymeshCatalogEngine,
  sources: {|
    extensions: PlaymeshCatalogSourceIdentity,
    examples: PlaymeshCatalogSourceIdentity,
  |},
  limits: PlaymeshCatalogLimits,
  features: {|
    extensions: PlaymeshCatalogDescriptor,
    examples: PlaymeshCatalogDescriptor,
  |},
|};

export type PlaymeshCatalogFeatureManifest = {|
  schemaVersion: 1,
  kind: 'extensions' | 'examples',
  catalogRevision: string,
  engine: PlaymeshCatalogEngine,
  source: PlaymeshCatalogSourceIdentity,
  index: PlaymeshCatalogDescriptor,
|};

export type PlaymeshCatalogArtifact = {|
  id: string,
  kind: PlaymeshCatalogArtifactKind,
  repository: PlaymeshCatalogRepository,
  commit: string,
  rootTreeSha: string,
  path: string,
  url: string,
  declaredBytes: number,
  gitBlobOid?: string,
  sha256: string,
  mediaType: string,
|};

export type PlaymeshCatalogDownload = {|
  bytes: ArrayBuffer,
  contentHash: string,
  mediaType: string,
|};

export type PlaymeshCatalogJsonDownload = {|
  ...PlaymeshCatalogDownload,
  value: mixed,
|};

type CatalogBufferSource = ArrayBuffer | Uint8Array;
type CatalogFeature = 'extensions' | 'examples';

const asMixedRecord = (value: mixed): ?MixedRecord => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return (value: MixedRecord);
};

export class PlaymeshCatalogError extends Error {
  code: string;
  retryable: boolean;
  status: number;
  requestId: ?string;
  operation: ?string;
  stage: ?string;
  targetUrl: string;
  reason: ?string;

  constructor(
    code: string,
    message: string,
    retryable: boolean = false,
    diagnostic?: ?{|
      status?: number,
      requestId?: ?string,
      operation?: ?string,
      stage?: ?string,
      targetUrl?: ?string,
      reason?: ?string,
    |}
  ) {
    super(message);
    this.name = 'PlaymeshCatalogError';
    this.code = code;
    this.retryable = retryable;
    this.status = Number.isSafeInteger(diagnostic?.status)
      ? Number(diagnostic?.status)
      : 0;
    this.requestId =
      typeof diagnostic?.requestId === 'string' && diagnostic.requestId
        ? diagnostic.requestId
        : null;
    this.operation =
      typeof diagnostic?.operation === 'string' && diagnostic.operation
        ? diagnostic.operation
        : null;
    this.stage =
      typeof diagnostic?.stage === 'string' && diagnostic.stage
        ? diagnostic.stage
        : null;
    this.targetUrl = sanitizePlaymeshExternalUrl(diagnostic?.targetUrl);
    this.reason =
      typeof diagnostic?.reason === 'string' && diagnostic.reason
        ? diagnostic.reason
        : null;
  }
}

const textDecoder = new TextDecoder('utf-8', { fatal: true });

const mediaTypesByExtension: { [string]: string } = {
  '.json': 'application/json',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.xml': 'application/xml',
  '.atlas': 'text/plain',
  '.fnt': 'text/plain',
  '.piskel': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.mp3': 'audio/mpeg',
  '.ogg': 'audio/ogg',
  '.wav': 'audio/wav',
  '.aac': 'audio/aac',
  '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
};

export const mediaTypeForArtifactPath = (sourcePath: string): string => {
  const filename = sourcePath.split('/').pop() || '';
  const extensionIndex = filename.lastIndexOf('.');
  const extension =
    extensionIndex >= 0 ? filename.slice(extensionIndex).toLowerCase() : '';
  return mediaTypesByExtension[extension] || 'application/octet-stream';
};

export const sha256Hex = async (
  bytes: CatalogBufferSource
): Promise<string> => computeSha256Hex(bytes);

export const ensureSafeRelativePath = (value: mixed): string => {
  if (typeof value !== 'string' || !value || value.startsWith('/')) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录文件路径无效。');
  }
  const segments = value.split('/');
  if (segments.some(segment => !segment || segment === '.' || segment === '..')) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录文件路径越界。');
  }
  return value;
};

export const validateDescriptor = (
  descriptor: mixed,
  maximumBytes: number
): PlaymeshCatalogDescriptor => {
  const record = asMixedRecord(descriptor);
  if (!record) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录制品描述缺失。');
  }
  const path = ensureSafeRelativePath(record.path);
  const sha256 = record.sha256;
  const bytes = record.bytes;
  const mediaType = record.mediaType;
  if (typeof sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(sha256)) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录制品 SHA-256 无效。');
  }
  if (
    typeof bytes !== 'number' ||
    !Number.isSafeInteger(bytes) ||
    bytes < 1 ||
    bytes > maximumBytes
  ) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录制品大小越界。');
  }
  if (mediaType !== undefined && typeof mediaType !== 'string') {
    throw new PlaymeshCatalogError('invalid_manifest', '目录制品 MIME 类型无效。');
  }
  return { path, sha256, bytes, mediaType };
};

const decodeEngine = (value: mixed): ?PlaymeshCatalogEngine => {
  const record = asMixedRecord(value);
  const version = record ? record.version : null;
  const tag = record ? record.tag : undefined;
  const commit = record ? record.commit : undefined;
  if (
    typeof version !== 'string' ||
    (tag !== undefined && typeof tag !== 'string') ||
    (commit !== undefined && typeof commit !== 'string')
  ) {
    return null;
  }
  return { version, tag, commit };
};

const decodeSourceIdentity = (
  value: mixed,
  repository: PlaymeshCatalogRepository
): ?PlaymeshCatalogSourceIdentity => {
  const record = asMixedRecord(value);
  const storedRepository = record ? record.repository : null;
  const commit = record ? record.commit : null;
  const rootTreeSha = record ? record.rootTreeSha : null;
  if (
    storedRepository !== repository ||
    typeof commit !== 'string' ||
    !/^[a-f0-9]{40}$/.test(commit) ||
    typeof rootTreeSha !== 'string' ||
    !/^[a-f0-9]{40}$/.test(rootTreeSha)
  ) {
    return null;
  }
  return { repository, commit, rootTreeSha };
};

const readSafeInteger = (
  record: MixedRecord,
  key: string,
  allowZero: boolean = false
): ?number => {
  const value = record[key];
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value) ||
    (allowZero ? value < 0 : value < 1)
  ) {
    return null;
  }
  return value;
};

const decodeLimits = (value: mixed): ?PlaymeshCatalogLimits => {
  const record = asMixedRecord(value);
  if (!record) return null;
  const catalogFileBytes = readSafeInteger(record, 'catalogFileBytes');
  const extensionBytes = readSafeInteger(record, 'extensionBytes');
  const exampleProjectBytes = readSafeInteger(record, 'exampleProjectBytes');
  const exampleResourceBytes = readSafeInteger(record, 'exampleResourceBytes');
  const exampleTotalBytes = readSafeInteger(record, 'exampleTotalBytes');
  const exampleResourceCount = readSafeInteger(record, 'exampleResourceCount');
  const licenseFileBytes = readSafeInteger(record, 'licenseFileBytes');
  const licenseFileCount = readSafeInteger(record, 'licenseFileCount');
  const downloadConcurrency = readSafeInteger(record, 'downloadConcurrency');
  const requestTimeoutMs = readSafeInteger(record, 'requestTimeoutMs');
  const retryCount = readSafeInteger(record, 'retryCount', true);
  if (
    catalogFileBytes == null ||
    extensionBytes == null ||
    exampleProjectBytes == null ||
    exampleResourceBytes == null ||
    exampleTotalBytes == null ||
    exampleResourceCount == null ||
    licenseFileBytes == null ||
    licenseFileCount == null ||
    downloadConcurrency == null ||
    requestTimeoutMs == null ||
    retryCount == null
  ) {
    return null;
  }
  return {
    catalogFileBytes,
    extensionBytes,
    exampleProjectBytes,
    exampleResourceBytes,
    exampleTotalBytes,
    exampleResourceCount,
    licenseFileBytes,
    licenseFileCount,
    downloadConcurrency,
    requestTimeoutMs,
    retryCount,
  };
};

export const validateCatalogManifest = (
  manifest: mixed
): PlaymeshCatalogManifest => {
  const record = asMixedRecord(manifest);
  const catalogRevision = record ? record.catalogRevision : null;
  const engine = decodeEngine(record ? record.engine : null);
  const sources = asMixedRecord(record ? record.sources : null);
  const extensionsSource = decodeSourceIdentity(
    sources ? sources.extensions : null,
    'GDevelopApp/GDevelop-extensions'
  );
  const examplesSource = decodeSourceIdentity(
    sources ? sources.examples : null,
    'GDevelopApp/GDevelop-examples'
  );
  const limits = decodeLimits(record ? record.limits : null);
  const features = asMixedRecord(record ? record.features : null);
  if (
    !record ||
    record.schemaVersion !== 1 ||
    typeof catalogRevision !== 'string' ||
    !catalogRevision ||
    !engine ||
    engine.version !== '5.6.276' ||
    !extensionsSource ||
    !examplesSource ||
    !limits ||
    !features
  ) {
    throw new PlaymeshCatalogError(
      'incompatible_manifest',
      '本地目录与当前 GDevelop 内核不兼容。'
    );
  }
  const extensions = validateDescriptor(
    features.extensions,
    limits.catalogFileBytes
  );
  const examples = validateDescriptor(features.examples, limits.catalogFileBytes);
  return {
    schemaVersion: 1,
    catalogRevision,
    engine,
    sources: {
      extensions: extensionsSource,
      examples: examplesSource,
    },
    limits,
    features: { extensions, examples },
  };
};

type CatalogRequestSignal = {|
  signal: AbortSignal,
  didTimeOut: () => boolean,
  dispose: () => void,
|};

type CatalogFetchOptions = {|
  url: string,
  maximumBytes: number,
  timeoutMs: number,
  credentials?: 'omit' | 'same-origin',
  signal?: ?AbortSignal,
|};

type CatalogRetryFetchOptions = {|
  ...CatalogFetchOptions,
  retryCount: number,
|};

const createRequestSignal = (
  externalSignal: ?AbortSignal,
  timeoutMs: number
): CatalogRequestSignal => {
  const controller = new AbortController();
  let timedOut = false;
  const abortFromExternal = () => controller.abort();
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort();
    else externalSignal.addEventListener('abort', abortFromExternal, { once: true });
  }
  const timeoutId = window.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  return {
    signal: controller.signal,
    didTimeOut: () => timedOut,
    dispose: () => {
      window.clearTimeout(timeoutId);
      if (externalSignal) {
        externalSignal.removeEventListener('abort', abortFromExternal);
      }
    },
  };
};

const readResponseBytes = async (
  response: Response,
  maximumBytes: number
): Promise<ArrayBuffer> => {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new PlaymeshCatalogError('too_large', '下载内容超过本地目录限制。');
  }
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength > maximumBytes) {
    throw new PlaymeshCatalogError('too_large', '下载内容超过本地目录限制。');
  }
  return bytes;
};

const fetchOnce = async ({
  url,
  maximumBytes,
  timeoutMs,
  credentials = 'omit',
  signal,
}: CatalogFetchOptions): Promise<ArrayBuffer> => {
  const requestSignal = createRequestSignal(signal, timeoutMs);
  try {
    const response = await fetch(url, {
      signal: requestSignal.signal,
      cache: 'no-store',
      credentials,
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    });
    if (!response.ok) {
      const retryable =
        response.status === 408 || response.status === 429 || response.status >= 500;
      throw new PlaymeshCatalogError(
        'http_error',
        `下载失败（HTTP ${response.status}）。`,
        retryable
      );
    }
    return await readResponseBytes(response, maximumBytes);
  } catch (error) {
    if (error instanceof PlaymeshCatalogError) throw error;
    if (signal && signal.aborted) {
      throw new PlaymeshCatalogError('cancelled', '下载已取消。');
    }
    if (requestSignal.didTimeOut()) {
      throw new PlaymeshCatalogError('timeout', '下载超时，请重试。', true);
    }
    throw new PlaymeshCatalogError(
      'network_error',
      '当前无法连接官方目录源，请检查网络后重试。',
      true
    );
  } finally {
    requestSignal.dispose();
  }
};

const waitForRetry = (
  milliseconds: number,
  signal?: ?AbortSignal
): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    if (signal && signal.aborted) {
      reject(new PlaymeshCatalogError('cancelled', '下载已取消。'));
      return;
    }
    const timeoutId = window.setTimeout(resolve, milliseconds);
    if (signal) {
      signal.addEventListener(
        'abort',
        () => {
          window.clearTimeout(timeoutId);
          reject(new PlaymeshCatalogError('cancelled', '下载已取消。'));
        },
        { once: true }
      );
    }
  });

const fetchWithRetry = async ({
  url,
  maximumBytes,
  timeoutMs,
  retryCount,
  credentials,
  signal,
}: CatalogRetryFetchOptions): Promise<ArrayBuffer> => {
  let lastError: ?PlaymeshCatalogError = null;
  for (let attempt = 0; attempt <= retryCount; attempt++) {
    try {
      return await fetchOnce({
        url,
        maximumBytes,
        timeoutMs,
        credentials,
        signal,
      });
    } catch (error) {
      if (!(error instanceof PlaymeshCatalogError)) throw error;
      lastError = error;
      if (!error.retryable || attempt >= retryCount) throw error;
      await waitForRetry(300 * 2 ** attempt, signal);
    }
  }
  if (lastError) throw lastError;
  throw new PlaymeshCatalogError('network_error', '目录下载未返回结果。');
};

const parseJsonBytes = (bytes: ArrayBuffer): mixed => {
  try {
    return JSON.parse(textDecoder.decode(bytes));
  } catch (_) {
    throw new PlaymeshCatalogError('invalid_json', '目录 JSON 已损坏。');
  }
};

const verifyBytes = async (
  bytes: ArrayBuffer,
  descriptor: PlaymeshCatalogDescriptor
): Promise<ArrayBuffer> => {
  if (bytes.byteLength !== descriptor.bytes) {
    throw new PlaymeshCatalogError('size_mismatch', '下载内容长度校验失败。');
  }
  const digest = await sha256Hex(bytes);
  if (digest !== descriptor.sha256) {
    throw new PlaymeshCatalogError('hash_mismatch', '下载内容 SHA-256 校验失败。');
  }
  return bytes;
};

type LoadRootCatalogManifestOptions = {|
  url: string,
  cacheKey: string,
  signal?: ?AbortSignal,
|};

export const loadRootCatalogManifest = async ({
  url,
  cacheKey,
  signal,
}: LoadRootCatalogManifestOptions): Promise<PlaymeshCatalogManifest> => {
  try {
    const bytes = await fetchWithRetry({
      url,
      maximumBytes: 1024 * 1024,
      timeoutMs: 10000,
      retryCount: 0,
      credentials: 'same-origin',
      signal,
    });
    const manifest = validateCatalogManifest(parseJsonBytes(bytes));
    await putCatalogCache(cacheKey, new Blob([bytes], { type: 'application/json' }));
    return manifest;
  } catch (networkError) {
    const cached = await getCatalogCache(cacheKey);
    if (cached && cached.bytes instanceof Blob) {
      try {
        return validateCatalogManifest(
          parseJsonBytes(await cached.bytes.arrayBuffer())
        );
      } catch (_) {
        await removeCatalogCache(cacheKey);
      }
    }
    throw networkError;
  }
};

type LoadCatalogJsonOptions = {|
  baseUrl: string,
  descriptor: PlaymeshCatalogDescriptor,
  cacheKey: string,
  limits: PlaymeshCatalogLimits,
  signal?: ?AbortSignal,
|};

export const loadCatalogJson = async ({
  baseUrl,
  descriptor,
  cacheKey,
  limits,
  signal,
}: LoadCatalogJsonOptions): Promise<mixed> => {
  validateDescriptor(descriptor, limits.catalogFileBytes);
  const localUrl = new URL(ensureSafeRelativePath(descriptor.path), baseUrl);
  if (localUrl.origin !== new URL(baseUrl).origin) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录文件必须来自当前内核。');
  }
  try {
    const bytes = await fetchWithRetry({
      url: localUrl.href,
      maximumBytes: descriptor.bytes,
      timeoutMs: 10000,
      retryCount: 0,
      credentials: 'same-origin',
      signal,
    });
    await verifyBytes(bytes, descriptor);
    const value = parseJsonBytes(bytes);
    await putCatalogCache(cacheKey, new Blob([bytes], { type: 'application/json' }));
    return value;
  } catch (networkError) {
    const cached = await getCatalogCache(cacheKey);
    if (cached && cached.bytes instanceof Blob) {
      try {
        const bytes = await cached.bytes.arrayBuffer();
        await verifyBytes(bytes, descriptor);
        return parseJsonBytes(bytes);
      } catch (_) {
        await removeCatalogCache(cacheKey);
      }
    }
    throw networkError;
  }
};

const decodeRepository = (value: mixed): ?PlaymeshCatalogRepository => {
  if (value === 'GDevelopApp/GDevelop-extensions') {
    return 'GDevelopApp/GDevelop-extensions';
  }
  if (value === 'GDevelopApp/GDevelop-examples') {
    return 'GDevelopApp/GDevelop-examples';
  }
  return null;
};

const decodeArtifactKind = (value: mixed): ?PlaymeshCatalogArtifactKind => {
  switch (value) {
    case 'extension':
    case 'example-project':
    case 'example-resource':
    case 'example-license':
    case 'example-preview':
      return value;
    default:
      return null;
  }
};

export const validateArtifactUrl = (
  artifact: mixed
): PlaymeshCatalogArtifact => {
  const record = asMixedRecord(artifact);
  const id = record ? record.id : null;
  const kind = decodeArtifactKind(record ? record.kind : null);
  const repository = decodeRepository(record ? record.repository : null);
  const commit = record ? record.commit : null;
  const rootTreeSha = record ? record.rootTreeSha : null;
  if (
    typeof id !== 'string' ||
    !id ||
    !kind ||
    !repository ||
    typeof commit !== 'string' ||
    !/^[a-f0-9]{40}$/.test(commit) ||
    typeof rootTreeSha !== 'string' ||
    !/^[a-f0-9]{40}$/.test(rootTreeSha)
  ) {
    throw new PlaymeshCatalogError('invalid_artifact', '目录正文来源无效。');
  }
  const path = ensureSafeRelativePath(record ? record.path : null);
  const declaredValue = record ? record.declaredBytes : undefined;
  if (
    typeof declaredValue !== 'number' ||
    !Number.isSafeInteger(declaredValue) ||
    declaredValue < 1
  ) {
    throw new PlaymeshCatalogError('invalid_artifact', '目录正文大小元数据无效。');
  }
  const gitBlobValue = record ? record.gitBlobOid : undefined;
  let gitBlobOid: void | string;
  if (
    gitBlobValue !== undefined &&
    (typeof gitBlobValue !== 'string' ||
      !/^[a-f0-9]{40}$/.test(gitBlobValue))
  ) {
    throw new PlaymeshCatalogError('invalid_artifact', '目录 Git blob 标识无效。');
  }
  if (typeof gitBlobValue === 'string') gitBlobOid = gitBlobValue;
  const mediaType = record ? record.mediaType : null;
  const expectedSha256 = record ? record.sha256 : null;
  if (
    typeof expectedSha256 !== 'string' ||
    !/^[a-f0-9]{64}$/.test(expectedSha256) ||
    typeof mediaType !== 'string' ||
    !mediaType ||
    mediaType !== mediaTypeForArtifactPath(path) ||
    ((kind === 'extension' || kind === 'example-project') &&
      mediaType !== 'application/json') ||
    (kind === 'example-license' &&
      !mediaType.startsWith('text/') &&
      mediaType !== 'application/json' &&
      mediaType !== 'application/xml')
  ) {
    throw new PlaymeshCatalogError('invalid_artifact', '目录正文 MIME 类型无效。');
  }
  const expected = `https://raw.githubusercontent.com/${repository}/${
    commit
  }/${path
    .split('/')
    .map(segment => encodeURIComponent(segment))
    .join('/')}`;
  const url = record ? record.url : null;
  if (url !== expected) {
    throw new PlaymeshCatalogError('invalid_artifact', '目录正文 URL 不匹配固定来源。');
  }
  return {
    id,
    kind,
    repository,
    commit,
    rootTreeSha,
    path,
    url: expected,
    declaredBytes: declaredValue,
    gitBlobOid,
    sha256: expectedSha256,
    mediaType,
  };
};

export const validateCatalogFeatureManifest = ({
  value,
  feature,
  rootManifest,
}: {|
  value: mixed,
  feature: 'extensions' | 'examples',
  rootManifest: PlaymeshCatalogManifest,
|}): PlaymeshCatalogFeatureManifest => {
  const record = asMixedRecord(value);
  const engine = asMixedRecord(record ? record.engine : null);
  const source = asMixedRecord(record ? record.source : null);
  const expectedSource = rootManifest.sources[feature];
  if (
    !record ||
    record.schemaVersion !== 1 ||
    record.kind !== feature ||
    record.catalogRevision !== rootManifest.catalogRevision ||
    !engine ||
    engine.version !== rootManifest.engine.version ||
    !source ||
    source.repository !== expectedSource.repository ||
    source.commit !== expectedSource.commit ||
    source.rootTreeSha !== expectedSource.rootTreeSha
  ) {
    throw new PlaymeshCatalogError(
      'invalid_catalog',
      `${feature} 版本化清单与根清单不一致。`
    );
  }
  const index = validateDescriptor(record.index, rootManifest.limits.catalogFileBytes);
  return {
    schemaVersion: 1,
    kind: feature,
    catalogRevision: rootManifest.catalogRevision,
    engine: rootManifest.engine,
    source: expectedSource,
    index,
  };
};

const artifactMaximumBytes = (
  artifact: PlaymeshCatalogArtifact,
  limits: PlaymeshCatalogLimits
): number => {
  if (artifact.kind === 'extension') return limits.extensionBytes;
  if (artifact.kind === 'example-project') return limits.exampleProjectBytes;
  if (artifact.kind === 'example-license') return limits.licenseFileBytes;
  return limits.exampleResourceBytes;
};

const artifactSourceIdentity = (artifact: PlaymeshCatalogArtifact): string =>
  `${artifact.repository}@${artifact.commit}:${artifact.path}`;

type VerifyLocalCacheRecordOptions = {|
  record: PlaymeshArtifactCacheRecord,
  artifact: PlaymeshCatalogArtifact,
|};

const verifyLocalCacheRecord = async ({
  record,
  artifact,
}: VerifyLocalCacheRecordOptions): Promise<PlaymeshCatalogDownload> => {
  const sourceIdentity = artifactSourceIdentity(artifact);
  if (
    !(record.bytes instanceof Blob) ||
    record.sourceIdentity !== sourceIdentity ||
    !/^[a-f0-9]{64}$/.test(record.contentHash || '') ||
    record.contentHash !== artifact.sha256 ||
    record.bytes.size !== artifact.declaredBytes
  ) {
    throw new PlaymeshCatalogError('cache_invalid', '本地目录缓存元数据无效。');
  }
  const bytes = await record.bytes.arrayBuffer();
  const contentHash = await sha256Hex(bytes);
  if (contentHash !== record.contentHash) {
    throw new PlaymeshCatalogError('cache_corrupt', '本地目录缓存已损坏。');
  }
  return {
    bytes,
    contentHash,
    mediaType: record.mediaType || artifact.mediaType || 'application/octet-stream',
  };
};

const fetchArtifactThroughGateway = async ({
  artifact,
  maximumBytes,
  timeoutMs,
  signal,
}: {|
  artifact: PlaymeshCatalogArtifact,
  maximumBytes: number,
  timeoutMs: number,
  signal?: ?AbortSignal,
|}): Promise<ArrayBuffer> => {
  const requestSignal = createRequestSignal(signal, timeoutMs);
  const fallbackOperation = 'gdevelop.catalog.artifact.acquire';
  try {
    const response = await fetch('/dev/api/gdevelop/catalog/artifact', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: artifact.id,
        kind: artifact.kind,
        repository: artifact.repository,
        commit: artifact.commit,
        rootTreeSha: artifact.rootTreeSha,
        path: artifact.path,
        declaredBytes: artifact.declaredBytes,
        gitBlobOid: artifact.gitBlobOid,
        sha256: artifact.sha256,
        mediaType: artifact.mediaType,
      }),
      signal: requestSignal.signal,
      cache: 'no-store',
      credentials: 'same-origin',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    });
    if (!response.ok) {
      const requestId =
        response.headers.get('X-Request-ID') ||
        response.headers.get('x-request-id');
      const operation =
        response.headers.get('X-Playmesh-Operation-ID') ||
        response.headers.get('x-playmesh-operation-id') ||
        fallbackOperation;
      let responseCode = 'gateway_download_failed';
      let responseReason = responseCode;
      try {
        const errorBytes = await readResponseBytes(response, 32 * 1024);
        const envelope: mixed = JSON.parse(textDecoder.decode(errorBytes));
        const record = asMixedRecord(envelope);
        const errorRecord = record && asMixedRecord(record.error);
        if (errorRecord && typeof errorRecord.code === 'string') {
          responseCode = errorRecord.code;
        }
        if (errorRecord && typeof errorRecord.reason === 'string') {
          responseReason = errorRecord.reason;
        } else {
          responseReason = responseCode;
        }
      } catch (_) {
        // The stable response headers still identify the failed request when
        // an old or truncated Gateway cannot provide the JSON error envelope.
      }
      throw new PlaymeshCatalogError(
        responseCode,
        `App 目录下载失败（HTTP ${response.status}）。`,
        response.status === 408 ||
          response.status === 429 ||
          response.status >= 500,
        {
          status: response.status,
          requestId,
          operation,
          stage: 'artifact_download',
          targetUrl: artifact.url,
          reason: responseReason,
        }
      );
    }
    return await readResponseBytes(response, maximumBytes);
  } catch (error) {
    if (error instanceof PlaymeshCatalogError) {
      if (!error.targetUrl) {
        error.targetUrl = sanitizePlaymeshExternalUrl(artifact.url);
      }
      if (!error.stage) error.stage = 'artifact_download';
      if (!error.operation) error.operation = fallbackOperation;
      if (!error.reason) error.reason = error.code;
      throw error;
    }
    if (signal && signal.aborted) {
      throw new PlaymeshCatalogError('cancelled', '下载已取消。');
    }
    throw new PlaymeshCatalogError(
      requestSignal.didTimeOut() ? 'timeout' : 'gateway_unavailable',
      requestSignal.didTimeOut()
        ? 'App 目录下载超时，请重试。'
        : 'App 目录下载通道不可用，请稍后重试。',
      true,
      {
        operation: fallbackOperation,
        stage: 'artifact_download',
        targetUrl: artifact.url,
        reason: requestSignal.didTimeOut() ? 'timeout' : 'gateway_unavailable',
      }
    );
  } finally {
    requestSignal.dispose();
  }
};

type FetchCatalogArtifactOptions = {|
  artifact: mixed,
  limits: PlaymeshCatalogLimits,
  signal?: ?AbortSignal,
|};

export const fetchCatalogArtifact = async ({
  artifact,
  limits,
  signal,
}: FetchCatalogArtifactOptions): Promise<PlaymeshCatalogDownload> => {
  const validatedArtifact = validateArtifactUrl(artifact);
  const maximumBytes = artifactMaximumBytes(validatedArtifact, limits);
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1) {
    throw new PlaymeshCatalogError('invalid_limits', '目录正文大小限制无效。');
  }
  if (validatedArtifact.declaredBytes > maximumBytes) {
    throw new PlaymeshCatalogError('too_large', '目录正文超过当前设备限制。');
  }
  const sourceIdentity = artifactSourceIdentity(validatedArtifact);
  const cacheKey = `${validatedArtifact.kind}:${sourceIdentity}`;
  const cached = await getArtifactCache(cacheKey);
  if (cached) {
    try {
      return await verifyLocalCacheRecord({
        record: cached,
        artifact: validatedArtifact,
      });
    } catch (_) {
      await removeArtifactCache(cacheKey);
    }
  }
  let bytes: ?ArrayBuffer = null;
  let lastError: ?PlaymeshCatalogError = null;
  for (let attempt = 0; attempt <= limits.retryCount; attempt++) {
    try {
      bytes = await fetchArtifactThroughGateway({
        artifact: validatedArtifact,
        maximumBytes,
        timeoutMs: limits.requestTimeoutMs,
        signal,
      });
      lastError = null;
      break;
    } catch (error) {
      if (!(error instanceof PlaymeshCatalogError)) throw error;
      lastError = error;
      if (!error.retryable || attempt >= limits.retryCount) throw error;
      await waitForRetry(300 * 2 ** attempt, signal);
    }
  }
  if (lastError || !bytes) throw lastError || new Error('目录下载未返回正文。');
  if (bytes.byteLength !== validatedArtifact.declaredBytes) {
    throw new PlaymeshCatalogError(
      'declared_size_mismatch',
      '下载内容与固定 Git tree 的大小不一致。',
      false,
      {
        operation: 'gdevelop.catalog.artifact.acquire',
        stage: 'artifact_verify',
        targetUrl: validatedArtifact.url,
        reason: 'declared_size_mismatch',
      }
    );
  }
  const contentHash = await sha256Hex(bytes);
  if (contentHash !== validatedArtifact.sha256) {
    throw new PlaymeshCatalogError(
      'hash_mismatch',
      'App 返回内容与固定 SHA-256 不一致。',
      false,
      {
        operation: 'gdevelop.catalog.artifact.acquire',
        stage: 'artifact_verify',
        targetUrl: validatedArtifact.url,
        reason: 'hash_mismatch',
      }
    );
  }
  const mediaType = validatedArtifact.mediaType;
  await putArtifactCache(
    cacheKey,
    new Blob([bytes], { type: mediaType }),
    mediaType,
    contentHash,
    sourceIdentity
  );
  return { bytes, contentHash, mediaType };
};

export const parseCatalogJsonArtifact = async (
  options: FetchCatalogArtifactOptions
): Promise<PlaymeshCatalogJsonDownload> => {
  const result = await fetchCatalogArtifact(options);
  return { ...result, value: parseJsonBytes(result.bytes) };
};
