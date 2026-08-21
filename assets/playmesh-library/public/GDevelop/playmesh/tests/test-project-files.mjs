import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles.js'
);

// Faithful executable translation of the official GDevelop 5.6.276
// ObjectSplitter traversal used by LocalProjectWriter/LocalProjectOpener.
const split = (
  object,
  {
    pathSeparator,
    getArrayItemReferenceName,
    shouldSplit,
    isReferenceMagicPropertyName,
  }
) => {
  const partialObjects = [];
  const createReference = (reference, partialObject) => {
    partialObjects.push({ reference, object: partialObject });
    return {
      [isReferenceMagicPropertyName]: true,
      referenceTo: reference,
    };
  };
  const splitObject = (currentObject, currentPath, currentReference) => {
    if (currentObject === null || typeof currentObject !== 'object') return;
    if (Array.isArray(currentObject)) {
      for (const index in currentObject) {
        const itemPath = `${currentPath}${pathSeparator}*`;
        if (shouldSplit(itemPath)) {
          const partialObject = currentObject[index];
          const name = getArrayItemReferenceName(
            partialObject,
            currentReference
          );
          const itemReference = `${currentReference}${pathSeparator}${name}`;
          currentObject[index] = createReference(itemReference, partialObject);
          splitObject(partialObject, itemPath, itemReference);
        } else {
          splitObject(
            currentObject[index],
            itemPath,
            `${currentReference}${pathSeparator}${index}`
          );
        }
      }
      return;
    }
    for (const propertyName in currentObject) {
      const propertyPath = `${currentPath}${pathSeparator}${propertyName}`;
      const propertyReference = `${currentReference}${pathSeparator}${propertyName}`;
      if (shouldSplit(propertyPath)) {
        const partialObject = currentObject[propertyName];
        currentObject[propertyName] = createReference(
          propertyReference,
          partialObject
        );
        splitObject(partialObject, propertyPath, propertyReference);
      } else {
        splitObject(
          currentObject[propertyName],
          propertyPath,
          propertyReference
        );
      }
    }
  };
  splitObject(object, '', '');
  return partialObjects;
};

let observedMaxUnsplitDepth = null;
const unsplit = (
  object,
  {
    isReferenceMagicPropertyName,
    getReferencePartialObject,
    maxUnsplitDepth,
  }
) => {
  observedMaxUnsplitDepth = maxUnsplitDepth;
  const unsplitObject = async (currentObject, depth) => {
    if (maxUnsplitDepth !== undefined && depth >= maxUnsplitDepth) return;
    if (currentObject === null || typeof currentObject !== 'object') return;
    await Promise.all(
      Object.keys(currentObject).map(async indexOrPropertyName => {
        const child = currentObject[indexOrPropertyName];
        if (
          child &&
          typeof child === 'object' &&
          child[isReferenceMagicPropertyName] === true
        ) {
          currentObject[indexOrPropertyName] = await getReferencePartialObject(
            child.referenceTo
          );
          await unsplitObject(currentObject[indexOrPropertyName], depth + 1);
          return;
        }
        await unsplitObject(child, depth + 1);
      })
    );
  };
  return unsplitObject(object, 0);
};

const splitPaths = paths => candidatePath => paths.has(candidatePath);
const slugs = value =>
  value
    .toLowerCase()
    .replace(/ü/g, 'ue')
    .replace(/ä/g, 'ae')
    .replace(/ö/g, 'oe')
    .replace(/ß/g, 'ss')
    .replace(/[.=-]/g, ' ')
    .replace(/-{2,}/g, ' ')
    .replace(/^\s\s*/, '')
    .replace(/\s\s*$/, '')
    .replace(/[^\w ]/gi, '')
    .replace(/[ ]/gi, '-');
const splitNameAndNumberSuffix = value => {
  for (let index = 0; index < value.length; index++) {
    const suffix = value.slice(index);
    if (suffix.startsWith('0')) continue;
    const numberSuffix = Number(suffix);
    if (numberSuffix === Math.floor(numberSuffix)) {
      return [value.slice(0, index), numberSuffix];
    }
  }
  return [value, null];
};
const newNameGenerator = (name, exists, prefix = '') => {
  if (!exists(name)) return name;
  if (prefix && !exists(prefix + name)) return prefix + name;
  const [radix, numberSuffix] = splitNameAndNumberSuffix(prefix + name);
  const startingNumberSuffix = numberSuffix === null ? 2 : numberSuffix + 1;
  let potentialName = radix + startingNumberSuffix;
  for (
    let index = startingNumberSuffix + 1;
    exists(potentialName);
    index++
  ) {
    potentialName = radix + index;
  }
  return potentialName;
};
const getSlugifiedUniqueNameFromProperty = propertyName => {
  const existingNamesForReference = {};
  return (object, currentReference) => {
    const property = object[propertyName];
    if (typeof property !== 'string') {
      throw new Error(`Property ${propertyName} is not a string`);
    }
    existingNamesForReference[currentReference] =
      existingNamesForReference[currentReference] || {};
    const newName = newNameGenerator(
      slugs(property),
      name => !!existingNamesForReference[currentReference][name]
    );
    existingNamesForReference[currentReference][newName] = true;
    return newName;
  };
};

globalThis.__officialObjectSplitter = {
  split,
  splitPaths,
  getSlugifiedUniqueNameFromProperty,
  unsplit,
};
let source = await readFile(sourcePath, 'utf8');
source = source.replace(
  /import \{[\s\S]*?\} from '\.\.\/\.\.\/Utils\/ObjectSplitter';/,
  `const {
  split,
  splitPaths,
  getSlugifiedUniqueNameFromProperty,
  unsplit,
} = globalThis.__officialObjectSplitter;`
);
const projectFilesModule = await import(
  `data:text/javascript;base64,${Buffer.from(
    transformFlow(source),
    'utf8'
  ).toString('base64')}`
);
delete globalThis.__officialObjectSplitter;

const project = {
  gdVersion: { major: 5, minor: 6, build: 276, revision: 0 },
  properties: { name: 'Folder project', folderProject: true },
  layouts: [{ name: 'Main Scene', objects: [] }],
  externalLayouts: [{ name: 'HUD Layout', objects: [] }],
  externalEvents: [{ name: 'Shared Events', events: [] }],
  eventsFunctionsExtensions: [
    { name: 'My Extension', eventsFunctions: [] },
  ],
};
const originalProject = JSON.parse(JSON.stringify(project));
const projectFiles = projectFilesModule.splitPlaymeshProject(project);

assert.deepEqual(
  projectFiles.map(file => file.path),
  [
    'game.json',
    'layouts/main-scene.json',
    'externalLayouts/hud-layout.json',
    'externalEvents/shared-events.json',
    'eventsFunctionsExtensions/my-extension.json',
  ]
);
for (const [propertyName, referenceTo] of [
  ['layouts', '/layouts/main-scene'],
  ['externalLayouts', '/externalLayouts/hud-layout'],
  ['externalEvents', '/externalEvents/shared-events'],
  ['eventsFunctionsExtensions', '/eventsFunctionsExtensions/my-extension'],
]) {
  assert.deepEqual(projectFiles[0].content[propertyName][0], {
    __REFERENCE_TO_SPLIT_OBJECT: true,
    referenceTo,
  });
}
assert.equal(projectFiles[0].content.properties.folderProject, true);
assert.equal(
  projectFilesModule.formatPlaymeshProjectFile({ name: 'Scene' }),
  '{\n  "name": "Scene"\n}\n'
);

const unsplitProject = await projectFilesModule.unsplitPlaymeshProject(
  projectFiles
);
assert.equal(observedMaxUnsplitDepth, 3);
assert.deepEqual(unsplitProject, originalProject);

await assert.rejects(
  projectFilesModule.unsplitPlaymeshProject(null),
  /project files value must be an array/,
  'the unsplit boundary rejects a non-array DTO without walking it'
);
await assert.rejects(
  projectFilesModule.unsplitPlaymeshProject([null]),
  /project file entry is invalid/,
  'the unsplit boundary rejects a malformed shallow file entry'
);
await assert.rejects(
  projectFilesModule.unsplitPlaymeshProject([
    { path: 'game.json', content: [] },
  ]),
  /project file content must be an object/,
  'the unsplit boundary rejects non-object file content'
);
await assert.rejects(
  projectFilesModule.unsplitPlaymeshProject([
    { path: 'layouts/orphan.json', content: {} },
  ]),
  /missing game\.json/,
  'the unsplit boundary requires the official root file'
);
await assert.rejects(
  projectFilesModule.unsplitPlaymeshProject([
    {
      path: 'game.json',
      content: {
        layouts: [
          {
            __REFERENCE_TO_SPLIT_OBJECT: true,
            referenceTo: '/layouts/missing-scene',
          },
        ],
      },
    },
  ]),
  /missing referenced file "layouts\/missing-scene\.json"/,
  'the unsplit boundary reports a missing directly referenced partial file'
);

process.stdout.write('GDevelop project files tests passed.\n');
