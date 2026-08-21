// @flow

import {
  split,
  splitPaths,
  getSlugifiedUniqueNameFromProperty,
  unsplit,
} from '../../Utils/ObjectSplitter';

// Keep this list byte-for-byte aligned with GDevelop's
// LocalFileStorageProvider/LocalProjectWriter.splittedProjectFolderNames.
export const PLAYMESH_GDEVELOP_SPLIT_FOLDER_NAMES: $ReadOnlyArray<string> = Object.freeze(
  [
    'layouts',
    'externalLayouts',
    'externalEvents',
    'eventsFunctionsExtensions',
  ]
);

export const PLAYMESH_GDEVELOP_ROOT_PROJECT_FILE = 'game.json';
export const PLAYMESH_GDEVELOP_SPLIT_REFERENCE_PROPERTY =
  '__REFERENCE_TO_SPLIT_OBJECT';

export type PlaymeshProjectJsonValue =
  | null
  | boolean
  | number
  | string
  | Array<PlaymeshProjectJsonValue>
  | PlaymeshProjectJsonObject;

export type PlaymeshProjectJsonObject = {
  [string]: PlaymeshProjectJsonValue,
};

export type PlaymeshProjectFile = {|
  path: string,
  content: PlaymeshProjectJsonObject,
|};

const asProjectJsonObject = (
  value: PlaymeshProjectJsonValue
): ?PlaymeshProjectJsonObject =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const requireProjectJsonObject = (
  value: PlaymeshProjectJsonValue,
  message: string
): PlaymeshProjectJsonObject => {
  const object = asProjectJsonObject(value);
  if (!object) throw new Error(message);
  return object;
};

const decodeProjectJsonValue = (value: mixed): PlaymeshProjectJsonValue => {
  const serializedValue = JSON.stringify(value);
  if (serializedValue === undefined) {
    throw new Error('The Playmesh project value is not JSON serializable.');
  }
  // JSON.parse can only produce values represented by PlaymeshProjectJsonValue.
  return JSON.parse(serializedValue);
};

const cloneJsonObject = (
  value: PlaymeshProjectJsonObject
): PlaymeshProjectJsonObject => {
  return requireProjectJsonObject(
    decodeProjectJsonValue(value),
    'The Playmesh project file content must be a JSON object.'
  );
};

const projectFilePathFromReference = (referencePath: string): string =>
  `${referencePath.replace(/^\//, '')}.json`;

export const formatPlaymeshProjectFile = (
  content: PlaymeshProjectJsonObject
): string =>
  `${JSON.stringify(content, null, 2)}\n`;

/**
 * Apply the exact split rules used by GDevelop's LocalProjectWriter.
 * The serialized root is intentionally mutated, just like the upstream
 * implementation, and becomes the authoritative game.json document.
 */
export const splitPlaymeshProject = (
  serializedProject: PlaymeshProjectJsonObject
): Array<PlaymeshProjectFile> => {
  const root = serializedProject;
  const partialObjects = split(root, {
    pathSeparator: '/',
    getArrayItemReferenceName: getSlugifiedUniqueNameFromProperty('name'),
    shouldSplit: splitPaths(
      new Set(
        PLAYMESH_GDEVELOP_SPLIT_FOLDER_NAMES.map(
          folderName => `/${folderName}/*`
        )
      )
    ),
    isReferenceMagicPropertyName: PLAYMESH_GDEVELOP_SPLIT_REFERENCE_PROPERTY,
  });
  const partialFiles = partialObjects.map(partialObject => ({
    path: projectFilePathFromReference(partialObject.reference),
    content: requireProjectJsonObject(
      partialObject.object,
      'The split GDevelop project file content must be an object.'
    ),
  }));
  return [
    { path: PLAYMESH_GDEVELOP_ROOT_PROJECT_FILE, content: root },
    ...partialFiles,
  ];
};

const requireProjectFile = (
  value: PlaymeshProjectJsonValue
): PlaymeshProjectFile => {
  const file = asProjectJsonObject(value);
  if (!file || typeof file.path !== 'string') {
    throw new Error('The Playmesh project file entry is invalid.');
  }
  return {
    path: file.path,
    content: requireProjectJsonObject(
      file.content,
      'The Playmesh project file content must be an object.'
    ),
  };
};

const requireProjectFiles = (value: mixed): Array<PlaymeshProjectFile> => {
  const decodedValue = decodeProjectJsonValue(value);
  if (!Array.isArray(decodedValue)) {
    throw new Error('The Playmesh project files value must be an array.');
  }
  return decodedValue.map(requireProjectFile);
};

/** Recompose a project with the same ObjectSplitter contract as GDevelop. */
export const unsplitPlaymeshProject = async (
  projectFilesValue: mixed
): Promise<PlaymeshProjectJsonObject> => {
  const files: Map<string, PlaymeshProjectJsonObject> = new Map();
  const projectFiles = requireProjectFiles(projectFilesValue);
  projectFiles.forEach(fileValue => {
    files.set(fileValue.path, cloneJsonObject(fileValue.content));
  });
  const root = files.get(PLAYMESH_GDEVELOP_ROOT_PROJECT_FILE);
  if (!root) {
    throw new Error('The Playmesh project files are missing game.json.');
  }
  await unsplit(root, {
    getReferencePartialObject: referencePath => {
      const path = projectFilePathFromReference(referencePath);
      const content = files.get(path);
      if (!content) {
        throw new Error(
          `The Playmesh project files are missing referenced file "${path}".`
        );
      }
      return Promise.resolve(cloneJsonObject(content));
    },
    isReferenceMagicPropertyName: PLAYMESH_GDEVELOP_SPLIT_REFERENCE_PROPERTY,
    // This is the same bound used by LocalProjectOpener.
    maxUnsplitDepth: 3,
  });
  return root;
};
