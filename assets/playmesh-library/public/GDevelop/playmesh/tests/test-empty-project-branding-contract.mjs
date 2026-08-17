import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const sourceIndex = process.argv.indexOf('--source');
if (sourceIndex < 0 || !process.argv[sourceIndex + 1]) {
  throw new Error(
    'Usage: node test-empty-project-branding-contract.mjs --source <patched GDevelop root>'
  );
}
const sourceRoot = path.resolve(process.argv[sourceIndex + 1]);
const readSource = relativePath =>
  readFile(path.join(sourceRoot, ...relativePath.split('/')), 'utf8');

const [
  createProject,
  useCreateProject,
  watermarkBinding,
  loadingScreenBinding,
  loadingScreenImplementation,
] = await Promise.all([
  readSource('newIDE/app/src/ProjectCreation/CreateProject.js'),
  readSource('newIDE/app/src/Utils/UseCreateProject.js'),
  readSource('GDevelop.js/types/gdwatermark.js'),
  readSource('GDevelop.js/types/gdloadingscreen.js'),
  readSource('Core/GDCore/Project/LoadingScreen.cpp'),
]);

assert.match(
  watermarkBinding,
  /showGDevelopWatermark\(show: boolean\): gdWatermark;/,
  'the generated JS/Flow binding must expose the lower-camel watermark method'
);
assert.match(
  loadingScreenBinding,
  /showGDevelopLogoDuringLoadingScreen\(show: boolean\): gdLoadingScreen;/,
  'the generated JS/Flow binding must expose the lower-camel splash method'
);
assert.match(
  loadingScreenImplementation,
  /showGDevelopLogoDuringLoadingScreen\(true\)/,
  'the official 5.6.276 loading-screen constructor must keep splash enabled'
);

const emptyProjectStart = createProject.indexOf(
  'export const createNewEmptyProject'
);
const nextExport = createProject.indexOf('\nexport ', emptyProjectStart + 1);
assert.ok(emptyProjectStart >= 0, 'createNewEmptyProject must exist');
const emptyProjectSource = createProject.slice(
  emptyProjectStart,
  nextExport < 0 ? createProject.length : nextExport
);
assert.match(
  emptyProjectSource,
  /project\.getWatermark\(\)\.showGDevelopWatermark\(false\);/
);
assert.doesNotMatch(
  emptyProjectSource,
  /ShowGDevelopWatermark|showGDevelopLogoDuringLoadingScreen\(false\)/
);

const createEmptyStart = useCreateProject.indexOf(
  'const createEmptyProject = React.useCallback'
);
const createFromExampleStart = useCreateProject.indexOf(
  'const createProjectFromExample = React.useCallback',
  createEmptyStart
);
assert.ok(createEmptyStart >= 0 && createFromExampleStart > createEmptyStart);
const createEmptySource = useCreateProject.slice(
  createEmptyStart,
  createFromExampleStart
);
assert.match(
  createEmptySource,
  /async \(newProjectSetup: NewProjectSetup\): Promise<CreateProjectResult>/,
  'the patched callback must remain valid Flow-annotated source'
);
assert.match(createEmptySource, /let creationDelegated = false;/);
assert.match(
  createEmptySource,
  /creationDelegated = true;\s*return await createProject\(/
);
assert.match(
  createEmptySource,
  /finally \{[\s\S]*if \(!creationDelegated\) onSuccessOrError\(\);[\s\S]*\}/
);
assert.match(
  createEmptySource,
  /\[beforeCreatingProject, createProject, onSuccessOrError\]/
);

process.stdout.write(
  'Empty project watermark, splash default, JS binding and loading cleanup contracts passed.\n'
);
