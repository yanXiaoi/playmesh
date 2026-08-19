// @flow

import type { StoredProjectResource } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import {
  buildPlaymeshHistoryResourceUrl,
  validatePlaymeshHistoryRestoreRevision,
} from './PlaymeshHistoryRestoreProtocol';
import type {
  PlaymeshHistoryRestoreTargetSnapshot,
} from './PlaymeshHistoryRestoreProtocol';
import {
  hashPlaymeshHistoryBlob,
  hashPlaymeshHistoryBytes,
} from './PlaymeshHistoryEvidence';
import {
  formatPlaymeshProjectFile,
  unsplitPlaymeshProject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles';
import type {
  PlaymeshProjectFile,
  PlaymeshProjectJsonObject,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles';

/*::
type Fetch = (input: RequestInfo, init?: RequestOptions) => Promise<Response>;
type RequestOptions = { signal?: AbortSignal };
export type PlaymeshHistoryMaterializedTarget = {|
  projectFiles: Array<PlaymeshProjectFile>,
  resources: Array<StoredProjectResource>,
|};
type PlaymeshHistoryValidationDependencies = {|
  gd?: Object,
  urlApi?: Object,
|};
*/

export class PlaymeshHistoryRestoreMaterializerError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshHistoryRestoreMaterializerError';
    this.code = code;
  }
}

const fail = (code /*: string */, message /*: string */) /*: empty */ => {
  throw new PlaymeshHistoryRestoreMaterializerError(code, message);
};

export const verifyPlaymeshHistoryTargetProjectReference = async (
  targetSnapshot /*: PlaymeshHistoryRestoreTargetSnapshot */
) /*: Promise<void> */ => {
  if (
    targetSnapshot.projectFiles.length !==
    targetSnapshot.projectFilesReference.length
  ) {
    return fail('target_project_reference_mismatch', 'Playmesh 历史恢复项目快照校验失败。');
  }
  const references = new Map(
    targetSnapshot.projectFilesReference.map(reference => [
      reference.path,
      reference,
    ])
  );
  for (const file of targetSnapshot.projectFiles) {
    const reference = references.get(file.path);
    const bytes = new TextEncoder().encode(
      formatPlaymeshProjectFile(file.content)
    );
    if (
      !reference ||
      bytes.byteLength !== reference.size ||
      (await hashPlaymeshHistoryBytes(bytes.buffer)) !== reference.contentHash
    ) {
      return fail(
        'target_project_reference_mismatch',
        'Playmesh 历史恢复项目快照校验失败。'
      );
    }
  }
};

export const downloadPlaymeshHistoryTargetResources = async (
  {
    gameId,
    targetSnapshot,
    signal,
    fetchImpl = window.fetch.bind(window),
  } /*: {|
    gameId: string,
    targetSnapshot: PlaymeshHistoryRestoreTargetSnapshot,
    signal?: AbortSignal,
    fetchImpl?: Fetch,
  |} */
) /*: Promise<Array<StoredProjectResource>> */ => {
  const resources /*: Array<StoredProjectResource> */ = [];
  for (const resource of targetSnapshot.resources) {
    const response = await fetchImpl(
      buildPlaymeshHistoryResourceUrl(gameId, resource.contentHash),
      { signal }
    );
    if (!response.ok) {
      return fail(
        'resource_download_failed',
        `Playmesh 历史资源下载失败（HTTP ${response.status}）。`
      );
    }
    const downloaded = await response.blob();
    if (
      downloaded.size !== resource.size ||
      (await hashPlaymeshHistoryBlob(downloaded)) !== resource.contentHash
    ) {
      return fail(
        'resource_corrupt',
        `Playmesh 历史资源校验失败：${resource.logicalId}`
      );
    }
    const storedResource /*: StoredProjectResource */ = {
      logicalUrl: resource.logicalId,
      blob: new Blob([downloaded], { type: resource.mime }),
      contentHash: resource.contentHash,
    };
    if (resource.name !== undefined) storedResource.name = resource.name;
    if (resource.metadata !== undefined) {
      storedResource.metadata = resource.metadata;
    }
    resources.push(storedResource);
  }
  return resources;
};

const replaceStringsDeep = (
  value /*: mixed */,
  replacements /*: Map<string, string> */
) /*: mixed */ => {
  if (typeof value === 'string') return replacements.get(value) || value;
  if (Array.isArray(value)) {
    return value.map(item => replaceStringsDeep(item, replacements));
  }
  if (value !== null && typeof value === 'object') {
    const record /*: { +[string]: mixed } */ = value;
    const result /*: { [string]: mixed } */ = {};
    Object.keys(record).forEach(key => {
      result[key] = replaceStringsDeep(record[key], replacements);
    });
    return result;
  }
  return value;
};

export const validatePlaymeshHistoryTargetProject = (
  project /*: PlaymeshProjectJsonObject */,
  resources /*: $ReadOnlyArray<StoredProjectResource> */,
  dependencies /*: ?PlaymeshHistoryValidationDependencies */ = null
) /*: void */ => {
  const gd = dependencies && dependencies.gd ? dependencies.gd : global.gd;
  const urlApi =
    dependencies && dependencies.urlApi ? dependencies.urlApi : URL;
  if (!gd || !gd.ProjectHelper || !gd.Serializer) {
    return fail(
      'gdevelop_runtime_unavailable',
      'GDevelop 运行时尚未准备好，无法校验历史项目。'
    );
  }
  const validationProject = JSON.parse(JSON.stringify(project));
  const replacements /*: Map<string, string> */ = new Map();
  const objectUrls /*: Array<string> */ = [];
  let temporaryProject = null;
  let serializedProject = null;
  try {
    resources.forEach(resource => {
      const objectUrl = urlApi.createObjectURL(resource.blob);
      objectUrls.push(objectUrl);
      replacements.set(resource.logicalUrl, objectUrl);
    });
    const materializedValidationProject = replaceStringsDeep(
      validationProject,
      replacements
    );
    temporaryProject = gd.ProjectHelper.createNewGDJSProject();
    serializedProject = gd.Serializer.fromJSObject(
      materializedValidationProject
    );
    temporaryProject.unserializeFrom(serializedProject);
  } catch (error) {
    throw new PlaymeshHistoryRestoreMaterializerError(
      'invalid_target_project',
      error instanceof Error
        ? `GDevelop 历史项目无法反序列化：${error.message}`
        : 'GDevelop 历史项目无法反序列化。'
    );
  } finally {
    if (serializedProject) serializedProject.delete();
    if (temporaryProject) temporaryProject.delete();
    objectUrls.forEach(objectUrl => urlApi.revokeObjectURL(objectUrl));
  }
};

export const materializePlaymeshHistoryTarget = async (
  {
    gameId,
    targetRevision,
    targetSnapshot,
    signal,
    fetchImpl,
    gd,
    urlApi,
  } /*: {|
    gameId: string,
    targetRevision: number,
    targetSnapshot: PlaymeshHistoryRestoreTargetSnapshot,
    signal?: AbortSignal,
    fetchImpl?: Fetch,
    gd?: Object,
    urlApi?: Object,
  |} */
) /*: Promise<PlaymeshHistoryMaterializedTarget> */ => {
  const revision = validatePlaymeshHistoryRestoreRevision(targetRevision);
  if (targetSnapshot.sourceVersion.revision !== revision) {
    return fail(
      'target_revision_mismatch',
      'Playmesh 历史目标修订与不可变快照不匹配。'
    );
  }
  await verifyPlaymeshHistoryTargetProjectReference(targetSnapshot);
  const resources = await downloadPlaymeshHistoryTargetResources({
    gameId,
    targetSnapshot,
    signal,
    ...(fetchImpl ? { fetchImpl } : {}),
  });
  const validationDependencies /*: PlaymeshHistoryValidationDependencies */ = {};
  if (gd) validationDependencies.gd = gd;
  if (urlApi) validationDependencies.urlApi = urlApi;
  validatePlaymeshHistoryTargetProject(
    await unsplitPlaymeshProject(targetSnapshot.projectFiles),
    resources,
    validationDependencies
  );
  return { projectFiles: targetSnapshot.projectFiles, resources };
};
