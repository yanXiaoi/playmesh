// @flow

// 官方扩展和示例正文已经由 App 的 GDevelopCatalogArtifactService 写入
// playmesh-library/GDevelop/catalog-cache。WebIDE 不再建立第二份 IndexedDB
// 持久缓存；以下 Map 只承载当前页面生命周期内的解析结果和导入 staging。

export type PlaymeshCatalogCacheRecord = {|
  key: string,
  bytes: Blob,
  savedAt: number,
|};

export type PlaymeshArtifactCacheRecord = {|
  key: string,
  bytes: Blob,
  mediaType: string,
  contentHash: string,
  sourceIdentity: string,
  savedAt: number,
|};

export type PlaymeshCatalogStagedArtifactMetadata = {|
  artifact: mixed,
  contentHash: string,
  byteLength: number,
|};

export type PlaymeshCatalogStagedArtifactRecord = {|
  key: string,
  sessionId: string,
  artifactKey: string,
  blob: Blob,
  metadata: PlaymeshCatalogStagedArtifactMetadata,
  createdAt: number,
|};

type PlaymeshCatalogStagingSession = {|
  createdAt: number,
  artifacts: Map<string, PlaymeshCatalogStagedArtifactRecord>,
|};

const catalogRecords = new Map<string, PlaymeshCatalogCacheRecord>();
const artifactRecords = new Map<string, PlaymeshArtifactCacheRecord>();
const stagingSessions = new Map<string, PlaymeshCatalogStagingSession>();

export const getCatalogCache = async (
  key: string
): Promise<?PlaymeshCatalogCacheRecord> => catalogRecords.get(key) || null;

export const putCatalogCache = async (
  key: string,
  bytes: Blob
): Promise<void> => {
  catalogRecords.set(key, { key, bytes, savedAt: Date.now() });
};

export const removeCatalogCache = async (key: string): Promise<void> => {
  catalogRecords.delete(key);
};

export const getArtifactCache = async (
  key: string
): Promise<?PlaymeshArtifactCacheRecord> => artifactRecords.get(key) || null;

export const putArtifactCache = async (
  key: string,
  bytes: Blob,
  mediaType: string,
  contentHash: string,
  sourceIdentity: string
): Promise<void> => {
  artifactRecords.set(key, {
    key,
    bytes,
    mediaType,
    contentHash,
    sourceIdentity,
    savedAt: Date.now(),
  });
};

export const removeArtifactCache = async (key: string): Promise<void> => {
  artifactRecords.delete(key);
};

export const beginCatalogStaging = async (sessionId: string): Promise<void> => {
  stagingSessions.set(sessionId, {
    createdAt: Date.now(),
    artifacts: new Map(),
  });
};

export const putCatalogStagedArtifact = async ({
  sessionId,
  artifactKey,
  blob,
  metadata,
}: {|
  sessionId: string,
  artifactKey: string,
  blob: Blob,
  metadata: PlaymeshCatalogStagedArtifactMetadata,
|}): Promise<void> => {
  const session = stagingSessions.get(sessionId);
  if (!session) throw new Error('目录 staging 会话不存在。');
  const key = `${sessionId}:${artifactKey}`;
  session.artifacts.set(artifactKey, {
    key,
    sessionId,
    artifactKey,
    blob,
    metadata,
    createdAt: Date.now(),
  });
};

export const getCatalogStagedArtifact = async (
  sessionId: string,
  artifactKey: string
): Promise<?PlaymeshCatalogStagedArtifactRecord> => {
  const session = stagingSessions.get(sessionId);
  return session ? session.artifacts.get(artifactKey) || null : null;
};

export const clearCatalogStaging = async (
  sessionId: string
): Promise<void> => {
  stagingSessions.delete(sessionId);
};

export const cleanupExpiredCatalogStaging = async (
  maximumAgeMs: number = 24 * 60 * 60 * 1000
): Promise<void> => {
  const expiresBefore = Date.now() - maximumAgeMs;
  for (const [sessionId, session] of stagingSessions) {
    if (session.createdAt < expiresBefore) stagingSessions.delete(sessionId);
  }
};
