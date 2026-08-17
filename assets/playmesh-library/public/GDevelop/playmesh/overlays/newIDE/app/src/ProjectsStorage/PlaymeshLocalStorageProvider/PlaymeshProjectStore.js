// @flow

// 工程事实只存在 App 的 playmesh-library/GDevelop/packages。这里的 Map
// 仅保存当前 WebIDE 页面正在处理的快照，页面关闭后可直接丢弃。

export type StoredProjectResource = {|
  logicalUrl: string,
  name?: string,
  blob: Blob,
  contentHash?: string,
  metadata?: Object,
|};

export type StoredProject = {|
  id: string,
  name: string,
  gameId?: string,
  projectJson: string,
  resources: Array<StoredProjectResource>,
  savedAt: number,
|};

type PlaymeshMixedRecord = { +[string]: mixed };
const mixedRecord = (value: mixed): ?PlaymeshMixedRecord =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const requireStoredProjectResource = (value: mixed): StoredProjectResource => {
  const resource = mixedRecord(value);
  if (
    !resource ||
    typeof resource.logicalUrl !== 'string' ||
    (resource.name !== undefined && typeof resource.name !== 'string') ||
    !(resource.blob instanceof Blob) ||
    (resource.contentHash !== undefined &&
      typeof resource.contentHash !== 'string') ||
    (resource.metadata !== undefined &&
      (resource.metadata === null ||
        typeof resource.metadata !== 'object' ||
        Array.isArray(resource.metadata)))
  ) {
    throw new Error('The Playmesh session project contains an invalid resource.');
  }
  const storedResource /*: StoredProjectResource */ = {
    logicalUrl: resource.logicalUrl,
    blob: resource.blob,
  };
  if (typeof resource.name === 'string') storedResource.name = resource.name;
  if (typeof resource.contentHash === 'string') {
    storedResource.contentHash = resource.contentHash;
  }
  if (resource.metadata !== undefined) {
    storedResource.metadata = { ...resource.metadata };
  }
  return storedResource;
};

export const assertStoredProject = (value: mixed): StoredProject => {
  const project = mixedRecord(value);
  if (
    !project ||
    typeof project.id !== 'string' ||
    typeof project.name !== 'string' ||
    (project.gameId !== undefined && typeof project.gameId !== 'string') ||
    typeof project.projectJson !== 'string' ||
    !Array.isArray(project.resources) ||
    typeof project.savedAt !== 'number' ||
    !Number.isFinite(project.savedAt)
  ) {
    throw new Error('The Playmesh session project record is invalid.');
  }
  const savedAt = project.savedAt;
  if (typeof savedAt !== 'number') {
    throw new Error('The Playmesh session project record is invalid.');
  }
  return {
    id: project.id,
    name: project.name,
    ...(project.gameId !== undefined ? { gameId: project.gameId } : {}),
    projectJson: project.projectJson,
    resources: project.resources.map(requireStoredProjectResource),
    savedAt,
  };
};

const sessionProjects = new Map<string, StoredProject>();

export const getStoredProject = async (id: string): Promise<?StoredProject> =>
  sessionProjects.get(id) || null;

export const putStoredProject = async (
  projectValue: StoredProject
): Promise<void> => {
  const project = assertStoredProject(projectValue);
  sessionProjects.set(project.id, project);
};

export const listStoredProjects = async (): Promise<Array<StoredProject>> =>
  [...sessionProjects.values()].sort((left, right) =>
    right.savedAt - left.savedAt
  );

export const deleteStoredProject = async (id: string): Promise<void> => {
  sessionProjects.delete(id);
};
