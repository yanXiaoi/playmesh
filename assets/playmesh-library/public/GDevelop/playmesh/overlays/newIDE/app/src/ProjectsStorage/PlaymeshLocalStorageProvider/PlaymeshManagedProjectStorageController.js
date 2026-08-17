// @flow

/*::
type PlaymeshManagedProjectStorageDependencies = {|
  listAuthoritativeProjects: () => Promise<{|
    activeGameId: ?string,
    projects: Array<Object>,
    diagnostics: Array<Object>,
  |}>,
  openAuthoritativeProject: (fileMetadata: Object) => Promise<Object>,
  prepareProject: (input: Object) => Promise<Object>,
  commitAuthoritativeProject: (prepared: Object, input: Object) => Promise<mixed>,
  reportStatus?: (status: Object) => void,
|};

export type PlaymeshManagedProjectStorageList = {|
  activeGameId: ?string,
  projects: Array<Object>,
  diagnostics: Array<Object>,
  source: 'authoritative',
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

export const createPlaymeshManagedProjectStorageController = (
  dependencies /*: PlaymeshManagedProjectStorageDependencies */
) /*: Object */ => {
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
    fileMetadata /*: Object */
  ) /*: Promise<Object> */ => {
    const gameId =
      fileMetadata && typeof fileMetadata.gameId === 'string'
        ? fileMetadata.gameId
        : null;
    const project = await dependencies.openAuthoritativeProject(fileMetadata);
    reportAuthoritative('open', gameId);
    return project;
  };

  const saveProject = async (input /*: Object */) /*: Promise<Object> */ => {
    const prepared = await dependencies.prepareProject(input);
    const fileMetadata = prepared && prepared.fileMetadata;
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
