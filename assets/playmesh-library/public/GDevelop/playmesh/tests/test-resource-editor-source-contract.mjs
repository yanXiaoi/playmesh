import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex === -1 || !process.argv[sourceArgumentIndex + 1]) {
  throw new Error(
    'Usage: node test-resource-editor-source-contract.mjs --source <patched GDevelop root>'
  );
}
const sourceRoot = path.resolve(process.argv[sourceArgumentIndex + 1]);
const readSource = relativePath =>
  readFile(path.join(sourceRoot, ...relativePath.split('/')), 'utf8');

const resourcesEditor = await readSource(
  'newIDE/app/src/ResourcesEditor/index.js'
);
assert.match(
  resourcesEditor,
  /onChooseResource\(\{[\s\S]*multiSelection: true,[\s\S]*resourceKind/
);
assert.match(resourcesEditor, /applyResourceDefaults\(project, resource\)/);
assert.match(
  resourcesEditor,
  /getResourcesManager\(\)\.addResource\(resource\)/
);
assert.match(
  resourcesEditor,
  /await resourceManagementProps\.onFetchNewlyAddedResources\(\)/
);
assert.match(
  resourcesEditor,
  /resourceManagementProps\.onNewResourcesAdded\(\)/
);
assert.doesNotMatch(resourcesEditor, /indexedDB|localStorage|FileList/);

const resourcesList = await readSource('newIDE/app/src/ResourcesList/index.js');
assert.match(resourcesList, /<Trans>Upload resources<\/Trans>/);
assert.match(
  resourcesList,
  /allResourceKindsAndMetadata\.map\(\(\{ kind, displayName \}\)/
);
assert.match(resourcesList, /click: \(\) => uploadResources\(kind\)/);
assert.doesNotMatch(resourcesList, /<input|type=["']file["']|accept=/);

const createProject = await readSource(
  'newIDE/app/src/ProjectCreation/CreateProject.js'
);
assert.equal(
  createProject.split('getWatermark().showGDevelopWatermark(false)').length - 1,
  1
);
const emptyProjectStart = createProject.indexOf(
  'export const createNewEmptyProject'
);
const nextExport = createProject.indexOf('\nexport ', emptyProjectStart + 1);
const emptyProjectSource = createProject.slice(
  emptyProjectStart,
  nextExport === -1 ? createProject.length : nextExport
);
assert.match(
  emptyProjectSource,
  /getWatermark\(\)\.showGDevelopWatermark\(false\)/
);
assert.doesNotMatch(
  createProject,
  /ShowGDevelopWatermark|showGDevelopLogoDuringLoadingScreen\(false\)/
);

const searchItem = await readSource(
  'newIDE/app/src/UI/Search/UseSearchItem.js'
);
assert.doesNotMatch(
  searchItem,
  /Filtered items by category\/filters in .*ms\./
);
assert.match(
  searchItem,
  /console\.error\('Error while indexing items: ', error\)/
);

const structuredSearchItem = await readSource(
  'newIDE/app/src/UI/Search/UseSearchStructuredItem.js'
);
assert.doesNotMatch(
  structuredSearchItem,
  /Filtered items by category\/filters\/tier in .*ms\./
);
assert.doesNotMatch(
  structuredSearchItem,
  /Indexed .*items in|Found .*items in/
);
assert.doesNotMatch(structuredSearchItem, /performance\.now\(\)/);
assert.match(
  structuredSearchItem,
  /Search for items skipped because items are not ready/
);
assert.match(
  structuredSearchItem,
  /Discarding search results as a new search was launched/
);
assert.match(
  structuredSearchItem,
  /console\.error\('Error while indexing items: ', error\)/
);

const sceneEditor = await readSource('newIDE/app/src/SceneEditor/index.js');
assert.doesNotMatch(sceneEditor, /PlaymeshSceneResourceReloadQueue/);
assert.match(sceneEditor, /reloadFromDisk = true/);
assert.match(sceneEditor, /reloadFromDisk: hasResourceChanged/);
assert.doesNotMatch(sceneEditor, /Platformer|PlatformBehavior|platform role/i);

process.stdout.write(
  'Resource editor, watermark, timing and official scene reload contracts passed.\n'
);
