// @flow

/*::
import type { FileMetadata } from '..';
import type { PreparedPlaymeshProjectPersistence } from './PlaymeshProjectSerializer';
import type {
  PlaymeshAuthoritativeHistoryResult,
  PlaymeshAuthoritativeProjectCommit,
  PlaymeshManagedSaveInput,
} from './PlaymeshAuthoritativeProjectCommit';

type PlaymeshManagedProjectStorageDependencies = {|
  listAuthoritativeProjects: () => Promise<{|
    activeGameId: ?string,
    projects: Array<Object>,
    diagnostics: Array<Object>,
  |}>,
  openAuthoritativeProject: (fileMetadata: FileMetadata) => Promise<Object>,
  prepareProject: (
    input: PlaymeshManagedSaveInput
  ) => Promise<PreparedPlaymeshProjectPersistence>,
  commitAuthoritativeProject: PlaymeshAuthoritativeProjectCommit,
  reportStatus?: (status: Object) => void,
|};

export type PlaymeshManagedProjectStorageList = {|
  activeGameId: ?string,
  projects: Array<Object>,
  diagnostics: Array<Object>,
  source: 'authoritative',
|};
type PlaymeshRecoverableProjectOpenOptions = {|
  openProject: () => Promise<Object>,
  recoverPreparedRestore: () => Promise<boolean>,
|};

type PlaymeshManagedProjectSaveResult = {|
  prepared: PreparedPlaymeshProjectPersistence,
  authoritativeResult: void | PlaymeshAuthoritativeHistoryResult,
|};

type PlaymeshManagedProjectStorageController = {|
  listProjects: () => Promise<PlaymeshManagedProjectStorageList>,
  openProject: (fileMetadata: FileMetadata) => Promise<Object>,
  saveProject: (
    input: PlaymeshManagedSaveInput
  ) => Promise<PlaymeshManagedProjectSaveResult>,
|};
*/

const dispatchStatus = (status /*: Object */) /*: void */ => {
  if (
    typeof window === 'undefined' ||
    typeof window.dispatchEvent !== 'function' ||
    typeof CustomEvent !== 'function'
  ) {
    return;
  }
  window.dispatchEvent(
    new CustomEvent('playmesh-gdevelop-storage-status', {
      detail: { ...status, timestamp: Date.now() },
    })
  );
};

export const openPlaymeshProjectWithPreparedRestoreRecovery = async ({
  openProject,
  recoverPreparedRestore,
} /*: PlaymeshRecoverableProjectOpenOptions */) /*: Promise<Object> */ => {
  try {
    return await openProject();
  } catch (error) {
    const candidate /*: any */ = error;
    if (candidate?.code !== 'gdevelop_project_mutation_locked') throw error;
    if (!(await recoverPreparedRestore())) throw error;
    return openProject();
  }
};

export const createPlaymeshManagedProjectStorageController = (
  dependencies /*: PlaymeshManagedProjectStorageDependencies */
) /*: PlaymeshManagedProjectStorageController */ => {
  if (
    !dependencies ||
    typeof dependencies.listAuthoritativeProjects !== 'function' ||
    typeof dependencies.openAuthoritativeProject !== 'function' ||
    typeof dependencies.prepareProject !== 'function' ||
    typeof dependencies.commitAuthoritativeProject !== 'function'
  ) {
    throw new Error('GDevelop managed storage 依赖不完整。');
  }
  const report =
    typeof dependencies.reportStatus === 'function'
      ? dependencies.reportStatus
      : dispatchStatus;

  const reportAuthoritative = (
    operation /*: string */,
    gameId /*: ?string */ = null
  ) /*: void */ => report({ operation, state: 'authoritative', gameId });

  const listProjects = async () /*: Promise<PlaymeshManagedProjectStorageList> */ => {
    const result = await dependencies.listAuthoritativeProjects();
    if (
      !result ||
      !Array.isArray(result.projects) ||
      !Array.isArray(result.diagnostics)
    ) {
      throw new Error('GDevelop App 工程列表响应无效。');
    }
    reportAuthoritative('list');
    return {
      projects: result.projects,
      diagnostics: result.diagnostics,
      activeGameId:
        typeof result.activeGameId === 'string' ? result.activeGameId : null,
      source: 'authoritative',
    };
  };

  const openProject = async (
    fileMetadata /*: FileMetadata */
  ) /*: Promise<Object> */ => {
    const gameId =
      fileMetadata && typeof fileMetadata.gameId === 'string'
        ? fileMetadata.gameId
        : null;
    const project = await dependencies.openAuthoritativeProject(fileMetadata);
    reportAuthoritative('open', gameId);
    return project;
  };

  const saveProject = async (
    input /*: PlaymeshManagedSaveInput */
  ) /*: Promise<PlaymeshManagedProjectSaveResult> */ => {
    const prepared = await dependencies.prepareProject(input);
    const fileMetadata = prepared.fileMetadata;
    const gameId =
      fileMetadata && typeof fileMetadata.gameId === 'string'
        ? fileMetadata.gameId
        : null;
    // commit 未成功前绝不更新页面会话镜像，持久工程只允许由 App Gateway 提交。
    const authoritativeResult = await dependencies.commitAuthoritativeProject(
      prepared,
      input
    );
    reportAuthoritative('save', gameId);
    return { prepared, authoritativeResult };
  };

  return { listProjects, openProject, saveProject };
};
