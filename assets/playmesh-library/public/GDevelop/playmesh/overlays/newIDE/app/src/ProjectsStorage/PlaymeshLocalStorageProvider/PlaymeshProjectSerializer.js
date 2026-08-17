// @flow
import { serializeToJSObject } from '../../Utils/Serializer';
import {
  type StoredProject,
  type StoredProjectResource,
  getStoredProject,
  putStoredProject,
} from './PlaymeshProjectStore';
import { type FileMetadata } from '..';
import {
  ensureGDevelopGameId,
  isUnassignedGDevelopGameId,
} from '../../PlaymeshManifest/PlaymeshGDevelopManifestController';
import PlaymeshGameManifest from '../../PlaymeshShared/GameManifest';
import { sha256Blob } from '../../PlaymeshCrypto/PlaymeshSha256';
import { playmeshResourceObjectUrlRegistry } from './PlaymeshResourceObjectUrlRegistry';

const RESOURCE_URL_PREFIX = 'playmesh-local-resource://';
const objectUrlToLogicalUrl = new Map<string, string>();
const objectUrlToStoredResource = new Map<string, StoredProjectResource>();

// Live gdProject resources use opaque blob: URLs. AI/persistence DTO builders
// may recover only the logical project reference through this narrow lookup;
// the Blob and the runtime URL itself never cross that boundary.
export const getPlaymeshLogicalResourceUrl = (
  objectUrl: mixed
): ?string =>
  typeof objectUrl === 'string'
    ? objectUrlToLogicalUrl.get(objectUrl) || null
    : null;

type PlaymeshSerializableValue =
  | null
  | boolean
  | number
  | string
  | Array<PlaymeshSerializableValue>
  | { [string]: PlaymeshSerializableValue };

type PlaymeshSerializableObject = {
  [string]: PlaymeshSerializableValue,
};

const requireSerializableValue = (value: mixed): PlaymeshSerializableValue => {
  if (
    value === null ||
    typeof value === 'boolean' ||
    typeof value === 'number' ||
    typeof value === 'string'
  ) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(requireSerializableValue);
  }
  if (typeof value === 'object') {
    const source: { +[string]: mixed } = value;
    const result: PlaymeshSerializableObject = {};
    Object.keys(source).forEach(key => {
      result[key] = requireSerializableValue(source[key]);
    });
    return result;
  }
  throw new Error('GDevelop project serialization produced a non-JSON value.');
};

const requireSerializableObject = (
  value: mixed
): PlaymeshSerializableObject => {
  const serializableValue = requireSerializableValue(value);
  if (
    !serializableValue ||
    typeof serializableValue !== 'object' ||
    Array.isArray(serializableValue)
  ) {
    throw new Error('GDevelop project serialization must produce an object.');
  }
  return serializableValue;
};

const createId = (): string => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return window.crypto.randomUUID();
  }
  return `${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2)}`;
};

const replaceStringsDeep = (
  value: PlaymeshSerializableValue,
  replacements: Map<string, string>
): PlaymeshSerializableValue => {
  if (typeof value === 'string') return replacements.get(value) || value;
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      value[index] = replaceStringsDeep(item, replacements);
    });
    return value;
  }
  if (value && typeof value === 'object') {
    Object.keys(value).forEach(key => {
      value[key] = replaceStringsDeep(value[key], replacements);
    });
  }
  return value;
};

export const restoreStoredResources = (
  content: Object,
  resources: Array<StoredProjectResource>
): Object => {
  const replacements = new Map<string, string>();
  resources.forEach(resource => {
    const objectUrl = playmeshResourceObjectUrlRegistry.acquire(resource);
    objectUrlToLogicalUrl.set(objectUrl, resource.logicalUrl);
    objectUrlToStoredResource.set(objectUrl, resource);
    replacements.set(resource.logicalUrl, objectUrl);
  });
  return requireSerializableObject(
    replaceStringsDeep(requireSerializableObject(content), replacements)
  );
};

export type PlaymeshProjectSnapshot = {|
  project: Object,
  resources: Array<StoredProjectResource>,
|};

export type PreparedPlaymeshProjectPersistence = {|
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
  storedProject: StoredProject,
|};

export const createProjectSnapshot = async (
  project: gdProject,
  fileMetadata: FileMetadata
): Promise<PlaymeshProjectSnapshot> => {
  const serializedProject = requireSerializableObject(
    serializeToJSObject(project)
  );
  const replacements = new Map<string, string>();
  const resources: Array<StoredProjectResource> = [];
  const resourcesManager = project.getResourcesManager();
  const resourceNames = resourcesManager.getAllResourceNames().toJSArray();

  for (const resourceName of resourceNames) {
    const resource = resourcesManager.getResource(resourceName);
    const resourceUrl = resource.getFile();
    if (!resourceUrl.startsWith('blob:')) continue;

    const knownResource = objectUrlToStoredResource.get(resourceUrl);
    let blob: Blob;
    if (knownResource) {
      // An object URL is bound to one immutable Blob for its lifetime. Reuse
      // the registered Blob instead of reading the same local resource again
      // on every save.
      blob = knownResource.blob;
    } else {
      const response = await fetch(resourceUrl);
      if (!response.ok) {
        throw new Error(`Unable to read local resource "${resourceName}".`);
      }
      blob = await response.blob();
    }
    const logicalUrl =
      (knownResource && knownResource.logicalUrl) ||
      objectUrlToLogicalUrl.get(resourceUrl) ||
      `${RESOURCE_URL_PREFIX}${encodeURIComponent(
        fileMetadata.fileIdentifier
      )}/${createId()}/${encodeURIComponent(resourceName)}`;
    replacements.set(resourceUrl, logicalUrl);
    const storedResource: StoredProjectResource = {
      logicalUrl,
      name: resourceName,
      blob,
      contentHash:
        knownResource && knownResource.contentHash
          ? knownResource.contentHash
          : await sha256Blob(blob),
    };
    // A resource added during the current editor lifetime has not passed
    // through restoreStoredResources yet. Register the same narrow reverse
    // mapping now so subsequent AI/context snapshots see its logical identity.
    objectUrlToLogicalUrl.set(resourceUrl, logicalUrl);
    objectUrlToStoredResource.set(resourceUrl, storedResource);
    resources.push(storedResource);
  }

  const projectWithLogicalResourceUrls = replaceStringsDeep(
    serializedProject,
    replacements
  );
  return {
    project: requireSerializableObject(projectWithLogicalResourceUrls),
    resources,
  };
};

export const persistProject = async (
  project: gdProject,
  fileMetadata: FileMetadata
): Promise<FileMetadata> => {
  const result = await persistProjectWithSnapshot(project, fileMetadata);
  return result.fileMetadata;
};

export const persistProjectWithSnapshot = async (
  project: gdProject,
  fileMetadata: FileMetadata
): Promise<{|
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
|}> => {
  const prepared = await prepareProjectPersistence(project, fileMetadata);
  await mirrorPreparedProject(prepared);
  return {
    fileMetadata: prepared.fileMetadata,
    snapshot: prepared.snapshot,
  };
};

export const prepareProjectPersistence = async (
  project: gdProject,
  fileMetadata: FileMetadata
): Promise<PreparedPlaymeshProjectPersistence> => {
  const existingGameId = fileMetadata.gameId;
  if (
    isUnassignedGDevelopGameId(project.getPackageName()) &&
    existingGameId &&
    PlaymeshGameManifest.isAndroidPackageName(existingGameId)
  ) {
    project.setPackageName(existingGameId);
  }
  const gameId = ensureGDevelopGameId(project);
  const snapshot = await createProjectSnapshot(project, fileMetadata);
  const savedAt = Date.now();
  const newFileMetadata: FileMetadata = {
    ...fileMetadata,
    name: project.getName(),
    gameId,
    lastModifiedDate: savedAt,
  };
  const storedProject: StoredProject = {
    id: fileMetadata.fileIdentifier,
    name: project.getName(),
    gameId,
    projectJson: JSON.stringify(snapshot.project),
    resources: snapshot.resources,
    savedAt,
  };
  return { fileMetadata: newFileMetadata, snapshot, storedProject };
};

export const mirrorPreparedProject = (
  prepared: PreparedPlaymeshProjectPersistence
): Promise<void> => putStoredProject(prepared.storedProject);

export const persistRestoredProject = async ({
  fileMetadata,
  project,
  resources,
}: {|
  fileMetadata: FileMetadata,
  project: Object,
  resources: Array<StoredProjectResource>,
|}): Promise<FileMetadata> => {
  const result = createRestoredStoredProject({
    fileMetadata,
    project,
    resources,
  });
  await putStoredProject(result.storedProject);
  return result.fileMetadata;
};

export const createRestoredStoredProject = ({
  fileMetadata,
  project,
  resources,
  savedAt = Date.now(),
}: {|
  fileMetadata: FileMetadata,
  project: Object,
  resources: Array<StoredProjectResource>,
  savedAt?: number,
|}): {|
  fileMetadata: FileMetadata,
  storedProject: StoredProject,
|} => {
  const name =
    project && project.properties && project.properties.name
      ? String(project.properties.name)
      : fileMetadata.name || 'GDevelop project';
  const storedProject: StoredProject = {
    id: fileMetadata.fileIdentifier,
    name,
    ...(fileMetadata.gameId ? { gameId: fileMetadata.gameId } : {}),
    projectJson: JSON.stringify(project),
    resources,
    savedAt,
  };
  return {
    fileMetadata: { ...fileMetadata, name, lastModifiedDate: savedAt },
    storedProject,
  };
};

export const readProjectContent = async (
  fileIdentifier: string
): Promise<Object> => {
  const storedProject = await getStoredProject(fileIdentifier);
  if (!storedProject)
    throw new Error('The Playmesh local project does not exist.');
  const content = JSON.parse(storedProject.projectJson);
  return restoreStoredResources(content, storedProject.resources || []);
};
